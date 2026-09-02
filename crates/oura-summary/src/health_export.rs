//! The Apple Health sample brain: what the ring **measured**, bucketed the way a
//! health store wants it, keyed by local day, with the bookkeeping an idempotent
//! exporter needs (`updated_unix`, `finalized`, `fingerprint`).
//!
//! Honesty rule (shared with OpenStrap): only measured signals or values computed
//! from them with a published method. No scores. Sleep **stages** are not here:
//! they come from the on-device SleepNet model, so this file only supplies the
//! `stage_window` the model must be run on.
//!
//! One rule per signal, in one place, so the web dashboard and the iOS app can
//! never disagree about what a day's heart rate or steps are:
//!
//! | field | source | rule |
//! | --- | --- | --- |
//! | `heart_rate[]` | 0x60 night beats, 0x80 day beats (`quality == 1`) | 1-min means, ≥ 3 beats; a 0x5d 5-min bpm fills windows without beats |
//! | `hrv[]` | 0x60/0x80 beats; 0x5d RMSSD | 5-min windows; SDNN needs ≥ 30 beats |
//! | `resting_hr` | 0x5d `hr_bpm` inside the night | min of the 5-min averages, stamped at wake |
//! | `spo2[]` | 0x6f firmware %, else 0x8b R calibrated per generation | 1-min means, `r` in 0.3..1.2, 85..100 |
//! | `respiratory_rate[]` | 0x6a `breath` inside the night | whole night gated: ≥ 80 % in 6..30 brpm, `average_hr` within ±15 bpm of 0x5d |
//! | `steps[]`, `active_energy[]`, `basal_energy[]` | 0x50 MET per minute; Schofield BMR | local-hour buckets |
//! | `night`, `in_bed[]`, `stage_window` | `bedtime_period` via `nights.rs` | keyed by WAKE date; longest in-bed wins |
//!
//! Point samples are keyed by the local date of their own timestamp. All times in
//! the JSON are UTC seconds; `tz_offset_s` only decides day and hour boundaries.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Map, Value};

use oura_analysis::beats::{beats_from_record, window_stats, Beat};
use oura_analysis::ported::metabolic::{bmr_kcal_per_hour, bmr_schofield, met_active_kcal_per_min};
use oura_analysis::ported::spo2::spo2_simple;
use oura_protocol::device::RingGeneration;
use oura_store::storage::Store;

use crate::nights::{collect_bed_periods, find_night, EventRow};
use crate::ring_time::RingClock;
use crate::{civil, read_profile, BedPeriod, Demographics};

/// Bump when the JSON contract or a bucketing rule changes; exporters re-export.
pub const HEALTH_SAMPLES_VERSION: u32 = 1;
/// A day is final once the ring's own clock has moved this far past its end:
/// the drain is cursor-ordered, so no event for that day can still arrive.
pub const FINALIZE_GRACE_S: i64 = 6 * 3600;

const HR_WINDOW_S: i64 = 60;
const HR_MIN_BEATS: usize = 3;
const HRV_WINDOW_S: i64 = 300;
const HRV_MIN_BEATS: usize = 30;
const RESP_MIN_PLAUSIBLE_FRACTION: f64 = 0.8;
const RESP_HR_TOLERANCE_BPM: f64 = 15.0;

/// SpO2 quadratic `a + b·r + c·r²` per hardware family (`docs/spo2-calibration.md`).
/// Returns `(name, a, b, c)`.
fn spo2_calibration(generation: RingGeneration) -> (&'static str, f64, f64, f64) {
    match generation {
        RingGeneration::Gen5 => ("cooper", 106.3, -6.9, -12.1),
        _ => ("gen4", 105.2, -5.1, -13.4),
    }
}

fn spo2_pct(r: f64, cal: (&'static str, f64, f64, f64)) -> Option<f64> {
    if !(0.3..=1.2).contains(&r) {
        return None;
    }
    Some(spo2_simple(r, cal.1, cal.2, cal.3).clamp(85.0, 100.0))
}

/// MET → steps per minute, the summary's heuristic (not an ecore port).
fn met_step_rate(met: f64) -> f64 {
    if met >= 7.0 {
        150.0
    } else if met >= 2.5 {
        105.0
    } else {
        0.0
    }
}

fn day_index(unix: f64, tz: i64) -> i64 {
    ((unix + tz as f64) / 86_400.0).floor() as i64
}

fn ymd(day_idx: i64) -> String {
    let (y, m, d) = civil(day_idx);
    format!("{y:04}-{m:02}-{d:02}")
}

fn hour_start_unix(unix: f64, tz: i64) -> i64 {
    ((unix + tz as f64) / 3600.0).floor() as i64 * 3600 - tz
}

/// FNV-1a 64-bit over bytes, as lowercase hex.
fn fnv1a_64(bytes: &[u8]) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{h:016x}")
}

fn r1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

#[derive(Default)]
struct HourAcc {
    steps: f64,
    active_kcal: f64,
    bins: u32,
}

#[derive(Default)]
struct DayAcc {
    updated_unix: i64,
    beats: Vec<Beat>,
    /// 0x5d samples keyed by 5-min window start: (bpm, rmssd)
    ring5: BTreeMap<i64, (Option<f64>, Option<f64>)>,
    spo2_fw: BTreeMap<i64, (f64, usize)>,
    spo2_r: BTreeMap<i64, (f64, usize)>,
    hours: BTreeMap<i64, HourAcc>,
}

impl DayAcc {
    fn touch(&mut self, captured_unix: i64) {
        self.updated_unix = self.updated_unix.max(captured_unix);
    }
}

#[derive(Default)]
struct NightAcc {
    /// 0x5d 5-min HR values inside the window (the resting-HR input).
    hr5: Vec<f64>,
    /// 0x6a samples: (t_unix, brpm, average_hr)
    resp: Vec<(i64, f64, f64)>,
    updated_unix: i64,
}

/// Read the profile next to `db` and build the sample bundles.
pub fn health_samples(db: &Path, tz_offset_s: i64, since_unix: Option<i64>) -> Result<Value> {
    let demo = read_profile(db);
    let store = Store::open(db).context("opening DB")?;
    health_samples_from_store(&store, tz_offset_s, since_unix, &demo)
}

/// Build the sample bundles from an open store (tests use `open_in_memory`).
pub fn health_samples_from_store(
    store: &Store,
    tz_offset_s: i64,
    since_unix: Option<i64>,
    demo: &Demographics,
) -> Result<Value> {
    let tz = tz_offset_s;
    let events: Vec<EventRow> = store.decoded_events().context("reading events")?;
    if events.is_empty() {
        return Err(anyhow!("no decoded events in the database — sync first"));
    }
    let clock = RingClock::from_events(&events);
    let unix_s_at = |ds: i64, cu: i64| clock.unix_s(ds, cu);
    let name_of = |tag: u8| oura_protocol::events::event_name(tag);

    let dev = store.device_info().ok().flatten();
    let hardware_id = dev
        .as_ref()
        .map(|d| d.1.clone())
        .filter(|s| !s.is_empty());
    let generation = hardware_id
        .as_deref()
        .map(RingGeneration::from_hardware_id)
        .unwrap_or(RingGeneration::Unknown);
    let cal = spo2_calibration(generation);

    let beds: Vec<BedPeriod> = collect_bed_periods(&events, unix_s_at);
    let mut night_accs: Vec<NightAcc> = beds.iter().map(|_| NightAcc::default()).collect();

    let sex_code = match demo.sex {
        'F' => 1u8,
        'M' => 0,
        _ => 2,
    };
    let bmr_day = bmr_schofield(demo.age, sex_code, demo.weight_kg);
    let bmr_hour = bmr_kcal_per_hour(bmr_day);

    let mut days: BTreeMap<i64, DayAcc> = BTreeMap::new();
    let mut newest_event_unix: f64 = f64::MIN;
    let mut newest_captured: i64 = 0;

    for (ds, tag, jstr, cu) in &events {
        let t0 = unix_s_at(*ds, *cu);
        newest_event_unix = newest_event_unix.max(t0);
        newest_captured = newest_captured.max(*cu);
        let n = name_of(*tag);
        match n {
            "ibi_and_amplitude_event" | "green_ibi_quality_event" => {
                let Ok(v) = serde_json::from_str::<Value>(jstr) else {
                    continue;
                };
                let ibis: Vec<u16> = v["ibi_ms"]
                    .as_array()
                    .map(|a| {
                        a.iter()
                            .filter_map(|x| x.as_u64())
                            .map(|x| x.min(u16::MAX as u64) as u16)
                            .collect()
                    })
                    .unwrap_or_default();
                if ibis.is_empty() {
                    continue;
                }
                let quality: Vec<u64> = v["quality"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|x| x.as_u64()).collect())
                    .unwrap_or_default();
                let daytime = n == "green_ibi_quality_event";
                let good = |i: usize| !daytime || quality.get(i).copied() == Some(1);
                for beat in beats_from_record(t0, &ibis, good) {
                    let day = days.entry(day_index(beat.t_s, tz)).or_default();
                    day.beats.push(beat);
                    day.touch(*cu);
                }
            }
            "hrv_event" => {
                let Ok(v) = serde_json::from_str::<Value>(jstr) else {
                    continue;
                };
                let step_s = v["interval_min"].as_f64().unwrap_or(5.0).max(1.0) * 60.0;
                let hr = v["hr_bpm"].as_array().cloned().unwrap_or_default();
                let rm = v["rmssd_ms"].as_array().cloned().unwrap_or_default();
                let count = hr.len().max(rm.len());
                for i in 0..count {
                    let t = t0 + i as f64 * step_s;
                    let bpm = hr.get(i).and_then(Value::as_f64).filter(|&x| x > 0.0);
                    let rmssd = rm.get(i).and_then(Value::as_f64).filter(|&x| x > 0.0);
                    if bpm.is_none() && rmssd.is_none() {
                        continue;
                    }
                    let wstart = (t / HRV_WINDOW_S as f64).floor() as i64 * HRV_WINDOW_S;
                    let day = days.entry(day_index(t, tz)).or_default();
                    let slot = day.ring5.entry(wstart).or_insert((None, None));
                    if bpm.is_some() {
                        slot.0 = bpm;
                    }
                    if rmssd.is_some() {
                        slot.1 = rmssd;
                    }
                    day.touch(*cu);
                    if let Some(bpm) = bpm {
                        if let Some(idx) = find_night(&beds, *ds + (i as i64) * (step_s as i64) * 10, *cu)
                        {
                            night_accs[idx].hr5.push(bpm);
                            night_accs[idx].updated_unix = night_accs[idx].updated_unix.max(*cu);
                        }
                    }
                }
            }
            "spo2_event" => {
                let Ok(v) = serde_json::from_str::<Value>(jstr) else {
                    continue;
                };
                let Some(a) = v["spo2_percent"].as_array() else {
                    continue;
                };
                for (i, x) in a.iter().enumerate() {
                    let Some(pct) = x.as_f64().filter(|p| (50.0..=100.0).contains(p)) else {
                        continue;
                    };
                    let t = t0 + i as f64; // 1 Hz
                    let minute = (t / 60.0).floor() as i64 * 60;
                    let day = days.entry(day_index(t, tz)).or_default();
                    let e = day.spo2_fw.entry(minute).or_insert((0.0, 0));
                    e.0 += pct;
                    e.1 += 1;
                    day.touch(*cu);
                }
            }
            "spo2_r_pi_event" => {
                let Ok(v) = serde_json::from_str::<Value>(jstr) else {
                    continue;
                };
                let Some(a) = v["r"].as_array() else {
                    continue;
                };
                for (i, x) in a.iter().enumerate() {
                    let Some(pct) = x.as_f64().and_then(|r| spo2_pct(r, cal)) else {
                        continue;
                    };
                    let t = t0 + i as f64; // ~1 Hz
                    let minute = (t / 60.0).floor() as i64 * 60;
                    let day = days.entry(day_index(t, tz)).or_default();
                    let e = day.spo2_r.entry(minute).or_insert((0.0, 0));
                    e.0 += pct;
                    e.1 += 1;
                    day.touch(*cu);
                }
            }
            "activity_information" => {
                if !jstr.contains("\"met\"") {
                    continue;
                }
                let Ok(v) = serde_json::from_str::<Value>(jstr) else {
                    continue;
                };
                let Some(met) = v["met"].as_array() else {
                    continue;
                };
                for (i, m) in met.iter().enumerate() {
                    let mv = m.as_f64().unwrap_or(1.0);
                    let t = t0 + i as f64 * 60.0;
                    let hour = hour_start_unix(t, tz);
                    let day = days.entry(day_index(t, tz)).or_default();
                    let h = day.hours.entry(hour).or_default();
                    h.steps += met_step_rate(mv);
                    h.active_kcal += met_active_kcal_per_min(mv, demo.weight_kg);
                    h.bins += 1;
                    day.touch(*cu);
                }
            }
            "sleep_period_information_2" => {
                let Ok(v) = serde_json::from_str::<Value>(jstr) else {
                    continue;
                };
                let (Some(brpm), Some(avg_hr)) = (v["breath"].as_f64(), v["average_hr"].as_f64())
                else {
                    continue;
                };
                if let Some(idx) = find_night(&beds, *ds, *cu) {
                    night_accs[idx].resp.push((t0.round() as i64, brpm, avg_hr));
                    night_accs[idx].updated_unix = night_accs[idx].updated_unix.max(*cu);
                }
            }
            _ => {}
        }
    }

    // Nights → wake-date keyed objects. Longest in-bed window wins the day;
    // every window whose wake date is that day is listed in `in_bed`.
    struct NightOut {
        start_unix: i64,
        end_unix: i64,
        start_ds: i64,
        end_ds: i64,
        idx: usize,
    }
    let mut nights_by_day: BTreeMap<i64, Vec<NightOut>> = BTreeMap::new();
    for (idx, bed) in beds.iter().enumerate() {
        let start_unix = unix_s_at(bed.start_ds, bed.captured_unix).round() as i64;
        let end_unix = unix_s_at(bed.end_ds, bed.captured_unix).round() as i64;
        if end_unix <= start_unix {
            continue;
        }
        nights_by_day
            .entry(day_index(end_unix as f64, tz))
            .or_default()
            .push(NightOut {
                start_unix,
                end_unix,
                start_ds: bed.start_ds,
                end_ds: bed.end_ds,
                idx,
            });
        days.entry(day_index(end_unix as f64, tz))
            .or_default()
            .touch(night_accs[idx].updated_unix.max(bed.captured_unix));
    }

    let mut out_days = Vec::new();
    for (day_idx, acc) in &days {
        let day_start = day_idx * 86_400 - tz;
        let day_end = day_start + 86_400;

        // Heart rate: 1-min means from beats, 0x5d fill where no beats.
        let hr_windows = window_stats(&acc.beats, HR_WINDOW_S, HR_MIN_BEATS);
        let mut heart_rate: Vec<Value> = hr_windows
            .iter()
            .map(|w| json!({ "t_unix": w.start_s, "bpm": r1(w.mean_bpm), "n": w.n, "src": "beats" }))
            .collect();
        for (&wstart, &(bpm, _)) in &acc.ring5 {
            let Some(bpm) = bpm else { continue };
            let covered = hr_windows
                .iter()
                .any(|w| w.start_s >= wstart && w.start_s < wstart + HRV_WINDOW_S);
            if !covered {
                heart_rate.push(json!({ "t_unix": wstart, "bpm": bpm, "n": 0, "src": "hrv_event" }));
            }
        }
        heart_rate.sort_by_key(|v| v["t_unix"].as_i64().unwrap_or(0));

        // HRV: 5-min windows; SDNN only with enough beats; RMSSD prefers the ring.
        let hrv_windows = window_stats(&acc.beats, HRV_WINDOW_S, 1);
        let mut hrv: BTreeMap<i64, Value> = BTreeMap::new();
        for w in &hrv_windows {
            let ring = acc.ring5.get(&w.start_s).and_then(|s| s.1);
            let (rmssd, src) = match ring {
                Some(r) => (Some(r), "ring"),
                None => (w.rmssd_ms.filter(|_| w.n >= HRV_MIN_BEATS), "beats"),
            };
            let sdnn = if w.n >= HRV_MIN_BEATS { w.sdnn_ms } else { None };
            if rmssd.is_none() && sdnn.is_none() {
                continue;
            }
            hrv.insert(
                w.start_s,
                json!({
                    "t_unix": w.start_s, "window_s": HRV_WINDOW_S,
                    "rmssd_ms": rmssd.map(r1), "sdnn_ms": sdnn.map(r1),
                    "n_beats": w.n, "rmssd_src": src,
                }),
            );
        }
        for (&wstart, &(_, rmssd)) in &acc.ring5 {
            let Some(r) = rmssd else { continue };
            hrv.entry(wstart).or_insert_with(|| {
                json!({
                    "t_unix": wstart, "window_s": HRV_WINDOW_S,
                    "rmssd_ms": r1(r), "sdnn_ms": Value::Null,
                    "n_beats": 0, "rmssd_src": "ring",
                })
            });
        }
        let hrv: Vec<Value> = hrv.into_values().collect();

        // SpO2: firmware percentages win the minute; R-derived fill the rest.
        let mut spo2: BTreeMap<i64, Value> = BTreeMap::new();
        for (&minute, &(sum, n)) in &acc.spo2_fw {
            spo2.insert(minute, json!({ "t_unix": minute, "pct": r1(sum / n as f64), "n": n, "src": "firmware" }));
        }
        for (&minute, &(sum, n)) in &acc.spo2_r {
            spo2.entry(minute).or_insert_with(|| {
                json!({ "t_unix": minute, "pct": r1(sum / n as f64), "n": n, "src": "r_pi" })
            });
        }
        let spo2: Vec<Value> = spo2.into_values().collect();

        // Steps / energy: local-hour buckets.
        let mut steps = Vec::new();
        let mut active_energy = Vec::new();
        let mut basal_energy = Vec::new();
        for (&hour, h) in &acc.hours {
            let end = hour + 3600;
            let count = h.steps.round() as i64;
            if count > 0 {
                steps.push(json!({ "start_unix": hour, "end_unix": end, "count": count, "method": "met_estimate" }));
            }
            if h.active_kcal > 0.0 {
                active_energy.push(json!({ "start_unix": hour, "end_unix": end, "kcal": r1(h.active_kcal) }));
            }
            let coverage = (h.bins.min(60)) as f64 / 60.0;
            let basal = bmr_hour * coverage;
            if basal > 0.0 {
                basal_energy.push(json!({ "start_unix": hour, "end_unix": end, "kcal": r1(basal), "method": "schofield" }));
            }
        }

        // Night objects.
        let mut warnings: Vec<String> = Vec::new();
        let mut night_v = Value::Null;
        let mut in_bed = Vec::new();
        let mut stage_window = Value::Null;
        let mut resting_hr = Value::Null;
        let mut respiratory_rate: Vec<Value> = Vec::new();
        if let Some(list) = nights_by_day.get(day_idx) {
            let mut sorted: Vec<&NightOut> = list.iter().collect();
            sorted.sort_by_key(|n| n.start_unix);
            for n in &sorted {
                in_bed.push(json!({ "start_unix": n.start_unix, "end_unix": n.end_unix }));
            }
            if let Some(main) = sorted
                .iter()
                .max_by_key(|n| (n.end_unix - n.start_unix, -n.start_unix))
            {
                night_v = json!({
                    "start_unix": main.start_unix, "end_unix": main.end_unix,
                    "start_ds": main.start_ds, "end_ds": main.end_ds,
                });
                stage_window = night_v.clone();
                let nacc = &night_accs[main.idx];
                if let Some(min) = nacc.hr5.iter().cloned().reduce(f64::min) {
                    resting_hr = json!({ "t_unix": main.end_unix, "bpm": min.round(), "method": "min_5min_avg" });
                }
                // Respiratory rate: gate the whole night on plausibility.
                let samples = &nacc.resp;
                if !samples.is_empty() {
                    let plausible = samples
                        .iter()
                        .filter(|(_, b, _)| (6.0..=30.0).contains(b))
                        .count() as f64
                        / samples.len() as f64;
                    let hr_ok = match (
                        nacc.hr5.iter().cloned().reduce(|a, b| a + b).map(|s| s / nacc.hr5.len() as f64),
                        samples.iter().map(|(_, _, h)| *h).reduce(|a, b| a + b).map(|s| s / samples.len() as f64),
                    ) {
                        (Some(ring_hr), Some(resp_hr)) => (ring_hr - resp_hr).abs() <= RESP_HR_TOLERANCE_BPM,
                        _ => true,
                    };
                    if plausible >= RESP_MIN_PLAUSIBLE_FRACTION && hr_ok {
                        respiratory_rate = samples
                            .iter()
                            .filter(|(_, b, _)| (6.0..=30.0).contains(b))
                            .map(|(t, b, _)| json!({ "t_unix": t, "brpm": r1(*b) }))
                            .collect();
                    } else {
                        warnings.push(format!(
                            "respiratory_rate dropped: plausibility {:.0}% (need ≥ {:.0}%), hr match {}",
                            plausible * 100.0,
                            RESP_MIN_PLAUSIBLE_FRACTION * 100.0,
                            if hr_ok { "ok" } else { "failed" }
                        ));
                    }
                }
            }
        }

        let mut day = Map::new();
        day.insert("ymd".into(), json!(ymd(*day_idx)));
        day.insert("day_start_unix".into(), json!(day_start));
        day.insert("day_end_unix".into(), json!(day_end));
        day.insert("night".into(), night_v);
        day.insert("in_bed".into(), json!(in_bed));
        day.insert("stage_window".into(), stage_window);
        day.insert("resting_hr".into(), resting_hr);
        day.insert("heart_rate".into(), json!(heart_rate));
        day.insert("hrv".into(), json!(hrv));
        day.insert("spo2".into(), json!(spo2));
        day.insert("respiratory_rate".into(), json!(respiratory_rate));
        day.insert("steps".into(), json!(steps));
        day.insert("active_energy".into(), json!(active_energy));
        day.insert("basal_energy".into(), json!(basal_energy));
        day.insert("warnings".into(), json!(warnings));
        let fingerprint = fnv1a_64(Value::Object(day.clone()).to_string().as_bytes());
        let finalized = newest_event_unix as i64 >= day_end + FINALIZE_GRACE_S;
        day.insert("updated_unix".into(), json!(acc.updated_unix));
        day.insert("finalized".into(), json!(finalized));
        day.insert("fingerprint".into(), json!(fingerprint));
        out_days.push((acc.updated_unix, Value::Object(day)));
    }

    let days_json: Vec<Value> = out_days
        .into_iter()
        .filter(|(updated, _)| since_unix.is_none_or(|s| *updated > s))
        .map(|(_, v)| v)
        .collect();

    Ok(json!({
        "version": HEALTH_SAMPLES_VERSION,
        "generated_at": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0),
        "tz_offset_s": tz,
        "serial": dev.as_ref().map(|d| d.0.clone()),
        "hardware_id": hardware_id,
        "firmware": dev.as_ref().map(|d| d.2.clone()).filter(|s| !s.is_empty()),
        "generation": generation.number(),
        "spo2_calibration": cal.0,
        "newest_event_unix": newest_event_unix.round() as i64,
        "newest_captured_unix": newest_captured,
        "profile": demo.to_json(),
        "days": days_json,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use oura_protocol::events::RingEvent;

    /// 2026-01-01 12:00:00 UTC — the ring's ds 0 in these fixtures.
    const ANCHOR_UNIX: i64 = 1_767_268_800;
    const CAPTURED: i64 = ANCHOR_UNIX + 3 * 86_400;

    fn ev(tag: u8, ds: u32, decoded: Value) -> RingEvent {
        RingEvent {
            tag,
            name: oura_protocol::events::event_name(tag),
            timestamp: ds,
            body: serde_json::to_vec(&json!({"ds": ds, "tag": tag, "d": decoded})).unwrap(),
            decoded: Some(decoded),
        }
    }

    fn store_with(events: &[RingEvent]) -> Store {
        let store = Store::open_in_memory().unwrap();
        // ds 0 ↔ ANCHOR_UNIX via an rtc_beacon; everything is captured 3 days later.
        store
            .insert_event_at("S1", &ev(0x85, 0, json!({"unix_time": ANCHOR_UNIX, "trailer": 0})), CAPTURED)
            .unwrap();
        for e in events {
            store.insert_event_at("S1", e, CAPTURED).unwrap();
        }
        store
    }

    fn samples(store: &Store, tz: i64) -> Value {
        health_samples_from_store(store, tz, None, &Demographics::default()).unwrap()
    }

    fn day<'a>(v: &'a Value, ymd: &str) -> &'a Value {
        v["days"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["ymd"] == ymd)
            .unwrap_or_else(|| panic!("no day {ymd} in {}", v["days"]))
    }

    fn ds(seconds_after_anchor: i64) -> u32 {
        (seconds_after_anchor * 10) as u32
    }

    #[test]
    fn heart_rate_minutes_gate_on_quality_and_fill_from_hrv_event() {
        // 60 good beats at 1000 ms from 13:00:00 → one 1-min window at 13:00.
        let good_ibis: Vec<u16> = vec![1000; 60];
        let quality: Vec<u8> = vec![1; 60];
        let bad_quality: Vec<u8> = vec![0; 60];
        let store = store_with(&[
            ev(0x80, ds(3600), json!({"ibi_ms": good_ibis, "quality": quality, "hr_bpm": [60]})),
            // same shape at 14:00 but every interval rejected by the firmware
            ev(0x80, ds(7200), json!({"ibi_ms": vec![1000u16; 60], "quality": bad_quality, "hr_bpm": []})),
            // 0x5d 5-min bpm at 15:00 (no beats there) and at 13:00 (beats cover it)
            ev(0x5d, ds(3600), json!({"hr_bpm": [61], "rmssd_ms": [40], "interval_min": 5})),
            ev(0x5d, ds(10800), json!({"hr_bpm": [55], "rmssd_ms": [48], "interval_min": 5})),
        ]);
        let v = samples(&store, 0);
        let d = day(&v, "2026-01-01");
        let hr = d["heart_rate"].as_array().unwrap();
        assert_eq!(hr.len(), 2, "{hr:?}");
        assert_eq!(hr[0]["t_unix"], json!(ANCHOR_UNIX + 3600));
        assert_eq!(hr[0]["bpm"], json!(60.0));
        assert_eq!(hr[0]["src"], json!("beats"));
        assert_eq!(hr[1]["t_unix"], json!(ANCHOR_UNIX + 10800));
        assert_eq!(hr[1]["src"], json!("hrv_event"));
        // HRV: the 13:00 window has 60 beats (≥ 30) → SDNN 0 for constant IBI, RMSSD from the ring.
        let hrv = d["hrv"].as_array().unwrap();
        let w = hrv.iter().find(|w| w["t_unix"] == json!(ANCHOR_UNIX + 3600)).unwrap();
        assert_eq!(w["sdnn_ms"], json!(0.0));
        assert_eq!(w["rmssd_ms"], json!(40.0));
        assert_eq!(w["rmssd_src"], json!("ring"));
        // the ring-only 15:00 window carries RMSSD but no SDNN
        let w2 = hrv.iter().find(|w| w["t_unix"] == json!(ANCHOR_UNIX + 10800)).unwrap();
        assert!(w2["sdnn_ms"].is_null());
        assert_eq!(w2["n_beats"], json!(0));
    }

    #[test]
    fn sdnn_needs_thirty_beats() {
        let ibis: Vec<u16> = (0..20).map(|i| 800 + (i % 4) * 10).collect();
        let store = store_with(&[ev(0x60, ds(3600), json!({"ibi_ms": ibis, "amplitude": [], "hr_bpm": []}))]);
        let v = samples(&store, 0);
        let d = day(&v, "2026-01-01");
        // 20 beats → HR minute exists, HRV window has no SDNN and no RMSSD (no ring value).
        assert_eq!(d["heart_rate"].as_array().unwrap().len(), 1);
        assert!(d["hrv"].as_array().unwrap().is_empty());
    }

    #[test]
    fn steps_and_energy_bucket_by_local_hour() {
        // 60 MET bins at 3.0 starting 12:30 UTC; with tz +1800 the local hour
        // boundary falls at 12:30 UTC, so one full local hour: 6300 steps.
        let met: Vec<f64> = vec![3.0; 60];
        let store = store_with(&[ev(0x50, ds(1800), json!({"state": 1, "met": met}))]);
        let v = samples(&store, 1800);
        let d = day(&v, "2026-01-01");
        let steps = d["steps"].as_array().unwrap();
        assert_eq!(steps.len(), 1, "{steps:?}");
        assert_eq!(steps[0]["count"], json!(6300));
        assert_eq!(steps[0]["start_unix"], json!(ANCHOR_UNIX + 1800));
        let kcal = d["active_energy"][0]["kcal"].as_f64().unwrap();
        assert!((kcal - 150.0).abs() < 0.11, "{kcal}"); // 60 × (3−1)·75/60
        let basal = d["basal_energy"][0]["kcal"].as_f64().unwrap();
        let bmr = bmr_schofield(30.0, 0, 75.0) / 24.0;
        assert!((basal - r1(bmr)).abs() < 0.11, "{basal} vs {bmr}");
        // The same bins straddle two UTC hours when tz is 0.
        let v0 = samples(&store, 0);
        assert_eq!(day(&v0, "2026-01-01")["steps"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn spo2_prefers_firmware_percent_and_calibrates_r() {
        let store = store_with(&[
            ev(0x8b, ds(60), json!({"r": [0.5, 0.5, 5.0], "perfusion_index": [0.04, 0.04, 0.04]})),
            ev(0x6f, ds(120), json!({"spo2_percent": [97, 97]})),
        ]);
        let v = samples(&store, 0);
        let d = day(&v, "2026-01-01");
        let spo2 = d["spo2"].as_array().unwrap();
        assert_eq!(spo2.len(), 2);
        // gen4 default: 105.2 − 5.1·0.5 − 13.4·0.25 = 99.3
        assert_eq!(spo2[0]["pct"], json!(99.3));
        assert_eq!(spo2[0]["n"], json!(2)); // r = 5.0 dropped
        assert_eq!(spo2[1]["src"], json!("firmware"));
        assert_eq!(spo2[1]["pct"], json!(97.0));
    }

    #[test]
    fn nights_key_by_wake_date_and_longest_wins() {
        // Night A: 23:00 Jan 1 → 07:00 Jan 2 (8 h). Nap B: 13:00 → 14:00 Jan 2.
        let a_start = 11 * 3600; // 23:00 UTC Jan 1
        let a_end = 19 * 3600; // 07:00 UTC Jan 2
        let b_start = 25 * 3600;
        let b_end = 26 * 3600;
        let store = store_with(&[
            ev(0x76, ds(a_end), json!({"bedtime_start_ds": ds(a_start), "bedtime_end_ds": ds(a_end), "duration_hours": 8.0})),
            ev(0x76, ds(b_end), json!({"bedtime_start_ds": ds(b_start), "bedtime_end_ds": ds(b_end), "duration_hours": 1.0})),
            // 5-min HR inside night A → resting HR 48
            ev(0x5d, ds(a_start + 3600), json!({"hr_bpm": [52, 48, 50], "rmssd_ms": [60, 70, 65], "interval_min": 5})),
            // breathing inside night A
            ev(0x6a, ds(a_start + 7200), json!({"average_hr": 50.0, "breath": 14.0, "breath_v": 1.0, "sleep_state": 1, "hr_trend": 0, "mzci": 0, "dzci": 0, "motion_count": 3, "cv": 0.1})),
        ]);
        let v = samples(&store, 0);
        let d = day(&v, "2026-01-02");
        assert_eq!(d["night"]["start_unix"], json!(ANCHOR_UNIX + a_start));
        assert_eq!(d["night"]["end_unix"], json!(ANCHOR_UNIX + a_end));
        assert_eq!(d["in_bed"].as_array().unwrap().len(), 2);
        assert_eq!(d["stage_window"]["start_ds"], json!(ds(a_start)));
        assert_eq!(d["resting_hr"]["bpm"], json!(48.0));
        assert_eq!(d["resting_hr"]["t_unix"], json!(ANCHOR_UNIX + a_end));
        let resp = d["respiratory_rate"].as_array().unwrap();
        assert_eq!(resp.len(), 1);
        assert_eq!(resp[0]["brpm"], json!(14.0));
        // Jan 1 gets no day object at all: every sample belongs to Jan 2.
        assert!(v["days"].as_array().unwrap().iter().all(|d| d["ymd"] != "2026-01-01"));
        // 23:30 local sample belongs to the previous local day.
        let vt = samples(&store, -3600);
        assert_eq!(day(&vt, "2026-01-02")["night"]["start_unix"], json!(ANCHOR_UNIX + a_start));
    }

    #[test]
    fn respiratory_rate_is_dropped_when_implausible() {
        let a_start = 11 * 3600;
        let a_end = 19 * 3600;
        let mut events = vec![
            ev(0x76, ds(a_end), json!({"bedtime_start_ds": ds(a_start), "bedtime_end_ds": ds(a_end), "duration_hours": 8.0})),
            ev(0x5d, ds(a_start + 3600), json!({"hr_bpm": [50], "rmssd_ms": [60], "interval_min": 5})),
        ];
        // 3 of 5 samples out of range → 40 % plausible
        for (i, b) in [14.0, 45.0, 2.0, 60.0, 15.0].iter().enumerate() {
            events.push(ev(0x6a, ds(a_start + 3600 + i as i64 * 300), json!({"average_hr": 50.0, "breath": b, "breath_v": 1.0, "sleep_state": 1, "hr_trend": 0, "mzci": 0, "dzci": 0, "motion_count": 3, "cv": 0.1})));
        }
        let store = store_with(&events);
        let v = samples(&store, 0);
        let d = day(&v, "2026-01-02");
        assert!(d["respiratory_rate"].as_array().unwrap().is_empty());
        assert!(d["warnings"][0].as_str().unwrap().contains("respiratory_rate dropped"));
    }

    #[test]
    fn finalization_follows_the_ring_clock_not_the_phone() {
        let store = store_with(&[
            ev(0x50, ds(3600), json!({"state": 1, "met": [3.0]})),
            // the newest event sits 5 h after the end of Jan 1 → not final
            ev(0x50, ds(12 * 3600 + 5 * 3600), json!({"state": 1, "met": [1.0]})),
        ]);
        let v = samples(&store, 0);
        assert_eq!(day(&v, "2026-01-01")["finalized"], json!(false));
        let store2 = store_with(&[
            ev(0x50, ds(3600), json!({"state": 1, "met": [3.0]})),
            ev(0x50, ds(12 * 3600 + 7 * 3600), json!({"state": 1, "met": [1.0]})),
        ]);
        let v2 = samples(&store2, 0);
        assert_eq!(day(&v2, "2026-01-01")["finalized"], json!(true));
        assert_eq!(day(&v2, "2026-01-02")["finalized"], json!(false));
    }

    #[test]
    fn fingerprint_is_stable_and_since_filters_by_update_time() {
        let store = store_with(&[ev(0x50, ds(3600), json!({"state": 1, "met": [3.0, 3.0]}))]);
        let a = samples(&store, 0);
        let b = samples(&store, 0);
        let fa = day(&a, "2026-01-01")["fingerprint"].clone();
        assert_eq!(fa, day(&b, "2026-01-01")["fingerprint"]);
        assert_eq!(fa.as_str().unwrap().len(), 16);
        // a new event changes the day's fingerprint
        store
            .insert_event_at("S1", &ev(0x50, ds(7200), json!({"state": 1, "met": [4.0]})), CAPTURED + 10)
            .unwrap();
        let c = samples(&store, 0);
        assert_ne!(fa, day(&c, "2026-01-01")["fingerprint"]);
        assert_eq!(day(&c, "2026-01-01")["updated_unix"], json!(CAPTURED + 10));
        // since filters on updated_unix
        let filtered = health_samples_from_store(&store, 0, Some(CAPTURED + 10), &Demographics::default()).unwrap();
        assert!(filtered["days"].as_array().unwrap().is_empty());
        let filtered = health_samples_from_store(&store, 0, Some(CAPTURED), &Demographics::default()).unwrap();
        assert_eq!(filtered["days"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn top_level_carries_device_and_version() {
        let store = store_with(&[ev(0x50, ds(3600), json!({"state": 1, "met": [3.0]}))]);
        let v = samples(&store, 0);
        assert_eq!(v["version"], json!(HEALTH_SAMPLES_VERSION));
        assert_eq!(v["spo2_calibration"], json!("gen4"));
        assert!(v["serial"].is_null()); // no device row in the fixture
        assert_eq!(v["newest_event_unix"], json!(ANCHOR_UNIX + 3600));
    }
}
