//! Results on top of the core summary: battery history, daytime stress,
//! resilience, guidance, the rule-based illness check, workouts from all sources,
//! reports, tag correlations and the cycle estimate.
//!
//! `build_summary` collects the facts (`NightFact`, the MET minutes, the scores)
//! and calls the builders here. Each builder takes values and returns JSON, so a
//! test can call it without a database. The algorithms are in
//! `oura_analysis::insights`; this file only prepares their inputs and formats
//! their results.

use std::collections::{BTreeMap, BTreeSet};

use oura_analysis::beats::{beats_from_record, window_stats, Beat};
use oura_analysis::insights::{bedtime, cycle, illness, nightsignal, regularity, resilience, stress};
use oura_analysis::scores::Stats;
use serde_json::{json, Map, Value};

use crate::civil;
use crate::external::External;
use crate::journal::{parse_day, Journal};
use crate::nights::EventRow;

pub(crate) const BASIS: &str = "estimate — see docs/algorithms/insights.md in open_oura";

/// Days of beats that the stress estimate and the workout heart rates read.
pub(crate) const BEAT_WINDOW_DAYS: f64 = 35.0;
const STRESS_WINDOW_S: i64 = 300;
const STRESS_MIN_BEATS: usize = 20;
const STRESS_DAYS: i64 = 14;

pub(crate) fn ymd(day: i64) -> String {
    let (y, m, d) = civil(day);
    format!("{y:04}-{m:02}-{d:02}")
}

pub(crate) fn local_day(unix: f64, tz: i64) -> i64 {
    ((unix + tz as f64 * 3600.0) / 86_400.0).floor() as i64
}

/// Minutes after local midnight for a UTC time.
fn clock_min(unix: f64, tz: i64) -> f64 {
    ((unix + tz as f64 * 3600.0) / 60.0).rem_euclid(1440.0)
}

fn hm(minutes: f64) -> String {
    let m = minutes.rem_euclid(1440.0).round() as i64 % 1440;
    format!("{:02}:{:02}", m / 60, m % 60)
}

fn r1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

fn mean(values: &[f64]) -> Option<f64> {
    (!values.is_empty()).then(|| values.iter().sum::<f64>() / values.len() as f64)
}

/// What the summary knows about one sleep period.
#[derive(Clone, Debug, Default)]
pub(crate) struct NightFact {
    pub start_unix: f64,
    pub end_unix: f64,
    /// Local day of the wake time (days since 1970).
    pub wake_day: i64,
    pub in_bed_min: f64,
    pub asleep_min: Option<f64>,
    pub efficiency: Option<f64>,
    pub hrv: Option<f64>,
    pub rhr: Option<f64>,
    pub temp_dev: Option<f64>,
    pub spo2: Option<f64>,
    pub breath: Option<f64>,
    pub deep_min: Option<f64>,
    pub rem_min: Option<f64>,
    pub sleep_score: Option<f64>,
    /// Night HRV as a z-score against the nights before.
    pub hrv_z: Option<f64>,
    /// The longest sleep of its wake day, 3 hours or more. Other periods are naps.
    pub main: bool,
}

/// Mark the main sleep of each wake day. Call once after all facts exist.
pub(crate) fn mark_main(nights: &mut [NightFact]) {
    let mut longest: BTreeMap<i64, (usize, f64)> = BTreeMap::new();
    for (i, n) in nights.iter().enumerate() {
        if n.in_bed_min < 180.0 {
            continue;
        }
        if longest.get(&n.wake_day).is_none_or(|l| n.in_bed_min > l.1) {
            longest.insert(n.wake_day, (i, n.in_bed_min));
        }
    }
    for (i, _) in longest.values() {
        nights[*i].main = true;
    }
}

// ── battery ──────────────────────────────────────────────────────────────────

/// Battery history, the charge state and an estimate of the days left.
/// `points` is `(unix, percent)` in any order.
pub(crate) fn battery(points: &[(f64, f64)], charging_progress: Option<f64>, now: f64) -> Value {
    let mut pts: Vec<(f64, f64)> = points
        .iter()
        .copied()
        .filter(|p| p.0.is_finite() && (0.0..=100.0).contains(&p.1))
        .collect();
    pts.sort_by(|a, b| a.0.total_cmp(&b.0));
    pts.dedup_by(|b, a| (b.0 - a.0).abs() < 60.0);
    let Some(&latest) = pts.last() else {
        return Value::Null;
    };
    // the last run without a charge: go back while the level does not rise
    let mut first = pts.len() - 1;
    while first > 0 && pts[first - 1].1 + 1.0 >= pts[first].1 {
        first -= 1;
    }
    let run = &pts[first..];
    let span_days = (latest.0 - run[0].0) / 86_400.0;
    let drop = run[0].1 - latest.1;
    let rising = pts.len() >= 2 && latest.1 > pts[pts.len() - 2].1 + 1.0;
    let charging = charging_progress.is_some_and(|p| p > 0.0) || rising;
    let rate = (span_days >= 0.25 && drop >= 3.0).then(|| drop / span_days);
    let days_left = rate.filter(|_| !charging).map(|r| r1(latest.1 / r));

    let recent: Vec<&(f64, f64)> = pts.iter().filter(|p| p.0 >= now - 14.0 * 86_400.0).collect();
    let step = recent.len().div_ceil(240).max(1);
    let history: Vec<Value> = recent
        .iter()
        .enumerate()
        .filter(|(i, _)| i % step == 0 || *i == recent.len() - 1)
        .map(|(_, p)| json!({ "t": p.0.round() as i64, "pct": p.1 }))
        .collect();
    json!({
        "latest": { "t": latest.0.round() as i64, "pct": latest.1 },
        "history": history,
        "charging": charging,
        "rate_pct_per_day": rate.map(r1),
        "days_left": days_left,
    })
}

// ── beats ────────────────────────────────────────────────────────────────────

/// Daytime beats of the last [`BEAT_WINDOW_DAYS`], sorted by time. Beats in a
/// sleep period are left out.
pub(crate) fn daytime_beats(
    events: &[EventRow],
    unix_s_at: impl Fn(i64, i64) -> f64,
    nights: &[NightFact],
    newest_unix: f64,
) -> Vec<Beat> {
    let cutoff = newest_unix - BEAT_WINDOW_DAYS * 86_400.0;
    let mut beats = Vec::new();
    for (ds, tag, jstr, cu) in events {
        let name = oura_protocol::events::event_name(*tag);
        if name != "green_ibi_quality_event" && name != "ibi_and_amplitude_event" {
            continue;
        }
        let t0 = unix_s_at(*ds, *cu);
        if t0 < cutoff || nights.iter().any(|n| t0 >= n.start_unix && t0 <= n.end_unix) {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(jstr) else { continue };
        let ibis: Vec<u16> = v["ibi_ms"]
            .as_array()
            .map(|a| a.iter().filter_map(Value::as_u64).map(|x| x.min(u16::MAX as u64) as u16).collect())
            .unwrap_or_default();
        let quality: Vec<u64> = v["quality"]
            .as_array()
            .map(|a| a.iter().filter_map(Value::as_u64).collect())
            .unwrap_or_default();
        let gated = name == "green_ibi_quality_event";
        beats.extend(beats_from_record(t0, &ibis, |i| !gated || quality.get(i).copied() == Some(1)));
    }
    beats.sort_by(|a, b| a.t_s.total_cmp(&b.t_s));
    beats
}

/// Mean and highest 1-minute heart rate in `start..=end`. `beats` is sorted.
fn heart_rate_in(beats: &[Beat], start: f64, end: f64) -> Option<(f64, f64)> {
    let from = beats.partition_point(|b| b.t_s < start);
    let to = beats.partition_point(|b| b.t_s <= end);
    let minutes = window_stats(&beats[from..to], 60, 3);
    let bpm: Vec<f64> = minutes.iter().map(|m| m.mean_bpm).collect();
    Some((mean(&bpm)?.round(), bpm.iter().cloned().fold(f64::MIN, f64::max).round()))
}

// ── daytime stress and resilience ────────────────────────────────────────────

pub(crate) struct StressResult {
    pub json: Value,
    pub days: BTreeMap<i64, stress::DayStress>,
}

/// Stress zones per local day for the last 14 days with daytime beats.
/// `met_min` maps a local minute to the MET above rest.
pub(crate) fn daytime_stress(beats: &[Beat], met_min: &BTreeMap<i64, f64>, tz: i64) -> StressResult {
    let empty = StressResult { json: Value::Null, days: BTreeMap::new() };
    let Some(newest) = beats.last() else { return empty };
    let first_day = local_day(newest.t_s, tz) - STRESS_DAYS;
    let windows: Vec<stress::DayWindow> = window_stats(beats, STRESS_WINDOW_S, STRESS_MIN_BEATS)
        .into_iter()
        .filter(|w| local_day(w.start_s as f64, tz) >= first_day)
        .map(|w| {
            let minute = (w.start_s + tz * 3600).div_euclid(60);
            let mets: Vec<f64> = (minute..minute + STRESS_WINDOW_S / 60)
                .filter_map(|m| met_min.get(&m).map(|above| 1.0 + above))
                .collect();
            stress::DayWindow {
                start_s: w.start_s,
                mean_bpm: w.mean_bpm,
                rmssd_ms: w.rmssd_ms,
                met: mean(&mets),
            }
        })
        .collect();
    let Some(reference) = stress::reference(&windows) else { return empty };

    let mut by_day: BTreeMap<i64, Vec<stress::DayWindow>> = BTreeMap::new();
    for w in &windows {
        by_day.entry(local_day(w.start_s as f64, tz)).or_default().push(*w);
    }
    let window_min = STRESS_WINDOW_S as f64 / 60.0;
    let days: BTreeMap<i64, stress::DayStress> = by_day
        .iter()
        .map(|(day, ws)| (*day, stress::day_stress(ws, &reference, window_min)))
        .collect();
    let timeline: Vec<Value> = windows
        .iter()
        .filter(|w| w.start_s as f64 >= newest.t_s - 48.0 * 3600.0)
        .filter_map(|w| {
            let index = stress::stress_index(w, &reference)?;
            Some(json!({ "t": w.start_s, "index": (index * 100.0).round() / 100.0,
                         "zone": stress::zone(index) }))
        })
        .collect();
    let json = json!({
        "basis": BASIS,
        "reference": {
            "bpm": r1(reference.bpm_median),
            "rmssd_ms": reference.ln_rmssd_median.map(|m| r1(m.exp())),
            "windows": reference.windows,
        },
        "latest": days.keys().next_back().map(|d| ymd(*d)),
        "days": days.iter().map(|(d, s)| (ymd(*d), json!(s))).collect::<Map<_, _>>(),
        "timeline": timeline,
    });
    StressResult { json, days }
}

/// Resilience from the last 14 days of stress and sleep.
pub(crate) fn resilience_json(
    stress_days: &BTreeMap<i64, stress::DayStress>,
    nights: &[NightFact],
    today: i64,
) -> Value {
    let loads: Vec<resilience::DayLoad> = (today - 13..=today)
        .map(|day| {
            let night = nights.iter().find(|n| n.main && n.wake_day == day);
            let s = stress_days.get(&day);
            resilience::DayLoad {
                stressed_min: s.map_or(0.0, |s| s.stressed_min),
                restored_min: s.map_or(0.0, |s| s.restored_min),
                measured_min: s.map_or(0.0, |s| s.measured_min),
                sleep_score: night.and_then(|n| n.sleep_score),
                hrv_z: night.and_then(|n| n.hrv_z),
            }
        })
        .collect();
    match resilience::resilience(&loads) {
        Some(r) => {
            let mut v = json!(r);
            v["basis"] = json!(BASIS);
            v
        }
        None => Value::Null,
    }
}

// ── guidance ─────────────────────────────────────────────────────────────────

/// Bedtime window, sleep regularity and chronotype from the last 30 days.
pub(crate) fn guidance(nights: &[NightFact], need_min: f64, tz: i64, today: i64) -> Value {
    let recent: Vec<&NightFact> = nights.iter().filter(|n| n.wake_day > today - 30).collect();
    let qualities: Vec<bedtime::NightQuality> = recent
        .iter()
        .filter(|n| n.main)
        .map(|n| bedtime::NightQuality {
            bedtime_min: clock_min(n.start_unix, tz),
            wake_min: clock_min(n.end_unix, tz),
            quality: n.sleep_score,
        })
        .collect();
    let window = bedtime::ideal_bedtime(&qualities, need_min).map(|w| {
        json!({
            "start": hm(w.start_min), "end": hm(w.end_min),
            "start_min": w.start_min, "end_min": w.end_min,
            "usual_wake": hm(w.usual_wake_min),
            "nights_used": w.nights_used, "basis": w.basis,
            "need_h": (need_min / 60.0 * 100.0).round() / 100.0,
        })
    });
    let spans: Vec<regularity::SleepSpan> = recent
        .iter()
        .map(|n| regularity::SleepSpan {
            start_min: ((n.start_unix + tz as f64 * 3600.0) / 60.0).floor() as i64,
            end_min: ((n.end_unix + tz as f64 * 3600.0) / 60.0).ceil() as i64,
        })
        .collect();
    let regular = regularity::sleep_regularity(&spans).map(|r| {
        json!({
            "sri": r.sri, "day_pairs": r.day_pairs, "days": r.days,
            "bedtime": hm(r.bedtime_min), "bedtime_sd_min": r.bedtime_sd_min,
            "wake": hm(r.wake_min), "wake_sd_min": r.wake_sd_min,
            "midpoint": hm(r.midpoint_min), "midpoint_sd_min": r.midpoint_sd_min,
            "chronotype": r.chronotype,
        })
    });
    json!({ "basis": BASIS, "bedtime": window, "regularity": regular })
}

// ── illness (rules) ──────────────────────────────────────────────────────────

/// The rule-based illness check for the newest main sleep. A sleep that ended
/// before yesterday counts as missing.
pub(crate) fn illness_rules(nights: &[NightFact], today: i64) -> Value {
    let mut main: Vec<&NightFact> = nights.iter().filter(|n| n.main).collect();
    main.sort_by(|a, b| a.end_unix.total_cmp(&b.end_unix));
    let vitals = |n: &NightFact| illness::NightVitals {
        breath: n.breath,
        lowest_hr: n.rhr,
        hrv: n.hrv,
        temp_deviation: n.temp_dev,
    };
    let last = main.last().filter(|n| n.wake_day >= today - 1);
    let history: Vec<illness::NightVitals> = main
        .iter()
        .rev()
        .skip(usize::from(last.is_some()))
        .take(28)
        .map(|n| vitals(n))
        .collect();
    let check = illness::illness_check(last.map(|n| vitals(n)).as_ref(), &history);
    let mut v = json!(check);
    v["date"] = json!(last.map(|n| ymd(n.wake_day)));
    v
}

/// NightSignal (Mishra 2022) over the resting heart rate of each date: the newest
/// date's alert, and the last 14 dates for a chart. `current` is false when the
/// newest date is older than yesterday. Null without data.
pub(crate) fn nightsignal_json(days: &[(i64, Vec<f64>)], today: i64) -> Value {
    let signal = nightsignal::nightsignal(days);
    let Some(last) = signal.last() else { return Value::Null };
    let recent: Vec<Value> = signal
        .iter()
        .rev()
        .take(14)
        .rev()
        .map(|d| json!({ "date": ymd(d.day), "rhr": d.rhr, "baseline": d.baseline, "alert": d.alert, "imputed": d.imputed }))
        .collect();
    json!({
        "alert": last.alert,
        "date": ymd(last.day),
        "rhr": last.rhr,
        "baseline": last.baseline,
        "current": last.day >= today - 1,
        "days_with_data": signal.iter().filter(|d| !d.imputed).count(),
        "recent": recent,
    })
}

// ── workouts ─────────────────────────────────────────────────────────────────

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Workout {
    pub id: String,
    pub start_unix: f64,
    pub end_unix: f64,
    pub label: String,
    /// `ring` (model), `ring_met` (rule), `health` (Apple Health), `manual`
    pub source: &'static str,
    pub source_name: String,
    pub active_kcal: Option<f64>,
    pub distance_m: Option<f64>,
    pub avg_hr: Option<f64>,
    pub max_hr: Option<f64>,
    pub note: String,
}

impl Workout {
    fn minutes(&self) -> f64 {
        ((self.end_unix - self.start_unix) / 60.0).max(0.0)
    }
    fn overlap(&self, other: &Workout) -> f64 {
        (self.end_unix.min(other.end_unix) - self.start_unix.max(other.start_unix)).max(0.0) / 60.0
    }
}

/// Activity bouts from the MET minutes, for a build without the activity model:
/// 15 minutes or more at 3 MET or more, with gaps of 3 minutes or less.
pub(crate) fn met_workouts(
    met_min: &BTreeMap<i64, f64>,
    sleep_windows: &[(i64, i64)],
    weight_kg: f64,
    tz: i64,
) -> Vec<Workout> {
    const MODERATE_ABOVE: f64 = 2.0;
    const MAX_GAP_MIN: i64 = 3;
    const MIN_BOUT_MIN: i64 = 15;
    let mut out = Vec::new();
    let mut bout: Option<(i64, i64, f64, usize)> = None; // start, last, sum above rest, minutes
    let mut flush = |bout: &mut Option<(i64, i64, f64, usize)>| {
        let Some((start, last, sum, n)) = bout.take() else { return };
        if last - start + 1 < MIN_BOUT_MIN {
            return;
        }
        let mean_met = 1.0 + sum / n as f64;
        let start_unix = (start * 60 - tz * 3600) as f64;
        out.push(Workout {
            id: format!("met-{start}"),
            start_unix,
            end_unix: start_unix + ((last - start + 1) * 60) as f64,
            label: if mean_met >= 6.0 { "Vigorous activity" } else { "Moderate activity" }.into(),
            source: "ring_met",
            source_name: "Ring".into(),
            active_kcal: Some((sum * weight_kg / 60.0).round()),
            distance_m: None,
            avg_hr: None,
            max_hr: None,
            note: String::new(),
        });
    };
    for (&minute, &above) in met_min {
        let asleep = sleep_windows.iter().any(|&(a, b)| minute >= a && minute < b);
        if asleep || above < MODERATE_ABOVE {
            if bout.is_some_and(|b| minute - b.1 > MAX_GAP_MIN) || asleep {
                flush(&mut bout);
            }
            continue;
        }
        match bout.as_mut() {
            Some(b) if minute - b.1 <= MAX_GAP_MIN + 1 => {
                b.1 = minute;
                b.2 += above;
                b.3 += 1;
            }
            _ => {
                flush(&mut bout);
                bout = Some((minute, minute, above, 1));
            }
        }
    }
    flush(&mut bout);
    out
}

/// The activity model's sessions (`start` is local `YYYY-MM-DD HH:MM`).
pub(crate) fn model_workouts(sessions: &[Value], tz: i64) -> Vec<Workout> {
    sessions
        .iter()
        .filter(|s| s["is_workout"].as_f64().is_none_or(|w| w >= 0.5))
        .filter_map(|s| {
            let start = s["start"].as_str()?;
            let (date, time) = start.split_once(' ')?;
            let day = parse_day(date)?;
            let (h, m) = time.split_once(':')?;
            let minute = h.parse::<i64>().ok()? * 60 + m.get(..2)?.parse::<i64>().ok()?;
            let start_unix = (day * 86_400 + minute * 60 - tz * 3600) as f64;
            let duration = s["duration_min"].as_f64()?;
            Some(Workout {
                id: format!("ring-{}", start_unix as i64),
                start_unix,
                end_unix: start_unix + duration * 60.0,
                label: s["label"].as_str().unwrap_or("activity").to_string(),
                source: "ring",
                source_name: "Ring".into(),
                active_kcal: s["active_kcal"].as_f64(),
                distance_m: None,
                avg_hr: None,
                max_hr: None,
                note: String::new(),
            })
        })
        .collect()
}

/// MET of an activity by its name, from the Compendium of Physical Activities
/// (Ainsworth 2011), for a manual workout without an energy value.
fn label_met(label: &str) -> f64 {
    let l = label.to_lowercase();
    let table: [(&str, f64); 14] = [
        ("run", 9.0), ("hiit", 8.0), ("interval", 8.0), ("cycl", 7.0), ("bik", 7.0),
        ("swim", 7.0), ("row", 7.0), ("hik", 6.0), ("tennis", 7.0), ("danc", 5.0),
        ("strength", 4.0), ("walk", 3.5), ("pilates", 3.0), ("yoga", 2.5),
    ];
    table.iter().find(|(k, _)| l.contains(k)).map_or(5.0, |(_, met)| *met)
}

pub(crate) struct WorkoutResult {
    pub workouts: Vec<Workout>,
    /// Active energy per local day that the ring did not measure.
    pub credited_kcal: BTreeMap<i64, f64>,
    /// Minutes at moderate effort per local day that the ring did not measure.
    pub credited_min: BTreeMap<i64, f64>,
}

/// One list of workouts from the ring, Apple Health and the journal.
///
/// A ring session that overlaps an entry from Apple Health or the journal by half
/// or more is dropped: the entry names the same activity. When an entry reports
/// more active energy than the ring measured in its time, the day gets the
/// difference (the ring was off the finger, or on a bicycle handlebar).
pub(crate) fn merge_workouts(
    ring: Vec<Workout>,
    external: &External,
    journal: &Journal,
    met_min: &BTreeMap<i64, f64>,
    beats: &[Beat],
    weight_kg: f64,
    tz: i64,
) -> WorkoutResult {
    let mut entries: Vec<Workout> = external
        .workouts
        .iter()
        .filter(|w| w.end_unix > w.start_unix)
        .map(|w| Workout {
            id: format!("health-{}", w.id),
            start_unix: w.start_unix as f64,
            end_unix: w.end_unix as f64,
            label: w.label.clone(),
            source: "health",
            source_name: if w.source.is_empty() { "Apple Health".into() } else { w.source.clone() },
            active_kcal: w.active_kcal,
            distance_m: w.distance_m,
            avg_hr: w.avg_hr,
            max_hr: w.max_hr,
            note: String::new(),
        })
        .collect();
    for w in &journal.workouts {
        let manual = Workout {
            id: format!("manual-{}", w.id),
            start_unix: w.start_unix as f64,
            end_unix: w.start_unix as f64 + w.duration_min * 60.0,
            label: w.label.clone(),
            source: "manual",
            source_name: "Added by you".into(),
            active_kcal: w.active_kcal,
            distance_m: None,
            avg_hr: None,
            max_hr: None,
            note: w.note.clone(),
        };
        // an Apple Health entry of the same activity wins over the manual one
        if !entries.iter().any(|e| e.overlap(&manual) >= 0.5 * manual.minutes()) {
            entries.push(manual);
        }
    }

    let mut credited_kcal: BTreeMap<i64, f64> = BTreeMap::new();
    let mut credited_min: BTreeMap<i64, f64> = BTreeMap::new();
    for e in entries.iter_mut() {
        let first = ((e.start_unix + tz as f64 * 3600.0) / 60.0).floor() as i64;
        let last = ((e.end_unix + tz as f64 * 3600.0) / 60.0).ceil() as i64;
        let measured: Vec<f64> = (first..last).filter_map(|m| met_min.get(&m).copied()).collect();
        let ring_kcal: f64 = measured.iter().map(|above| above * weight_kg / 60.0).sum();
        let ring_moderate = measured.iter().filter(|above| **above >= 2.0).count() as f64;
        let stated = e.active_kcal.unwrap_or_else(|| {
            (label_met(&e.label) - 1.0) * weight_kg * e.minutes() / 60.0
        });
        if e.active_kcal.is_none() {
            e.active_kcal = Some(stated.max(ring_kcal).round());
        }
        let day = local_day(e.start_unix, tz);
        if stated > ring_kcal {
            *credited_kcal.entry(day).or_default() += stated - ring_kcal;
        }
        if label_met(&e.label) >= 3.0 && e.minutes() > ring_moderate {
            *credited_min.entry(day).or_default() += e.minutes() - ring_moderate;
        }
    }

    let mut workouts: Vec<Workout> = ring
        .into_iter()
        .filter(|r| !entries.iter().any(|e| e.overlap(r) >= 0.5 * r.minutes()))
        .collect();
    workouts.extend(entries);
    for w in workouts.iter_mut().filter(|w| w.avg_hr.is_none()) {
        if let Some((avg, max)) = heart_rate_in(beats, w.start_unix, w.end_unix) {
            w.avg_hr = Some(avg);
            w.max_hr = Some(max);
        }
    }
    workouts.sort_by(|a, b| b.start_unix.total_cmp(&a.start_unix));
    WorkoutResult { workouts, credited_kcal, credited_min }
}

pub(crate) fn workouts_json(workouts: &[Workout], tz: i64) -> Value {
    workouts
        .iter()
        .map(|w| {
            let day = local_day(w.start_unix, tz);
            json!({
                "id": w.id,
                "day": ymd(day),
                "start": format!("{} {}", ymd(day), hm(clock_min(w.start_unix, tz))),
                "end": format!("{} {}", ymd(local_day(w.end_unix, tz)), hm(clock_min(w.end_unix, tz))),
                "start_unix": w.start_unix.round() as i64,
                "end_unix": w.end_unix.round() as i64,
                "duration_min": w.minutes().round(),
                "label": w.label,
                "source": w.source,
                "source_name": w.source_name,
                "active_kcal": w.active_kcal,
                "distance_m": w.distance_m,
                "avg_hr": w.avg_hr,
                "max_hr": w.max_hr,
                "note": w.note,
            })
        })
        .collect()
}

// ── day facts, reports, correlations, export ─────────────────────────────────

/// One local day with all its results, the unit of reports and export.
#[derive(Clone, Debug, Default)]
pub(crate) struct DayFact {
    pub day: i64,
    pub sleep_score: Option<f64>,
    pub readiness: Option<f64>,
    pub activity_score: Option<f64>,
    pub bedtime: Option<String>,
    pub wake: Option<String>,
    pub in_bed_min: Option<f64>,
    pub asleep_min: Option<f64>,
    pub nap_min: Option<f64>,
    pub efficiency: Option<f64>,
    pub deep_min: Option<f64>,
    pub rem_min: Option<f64>,
    pub hrv: Option<f64>,
    pub rhr: Option<f64>,
    pub temp_dev: Option<f64>,
    pub spo2: Option<f64>,
    pub breath: Option<f64>,
    pub steps: Option<f64>,
    pub active_kcal: Option<f64>,
    pub total_kcal: Option<f64>,
    pub distance_m: Option<f64>,
    pub stressed_min: Option<f64>,
    pub restored_min: Option<f64>,
    pub workouts: usize,
    pub workout_min: f64,
    pub rest_mode: bool,
    pub tags: Vec<String>,
}

type Metric = (&'static str, &'static str, &'static str, fn(&DayFact) -> Option<f64>);

/// `(key, name, unit, value)` of every numeric metric of a day.
pub(crate) const METRICS: [Metric; 21] = [
    ("sleep_score", "Sleep score", "", |d| d.sleep_score),
    ("readiness", "Readiness", "", |d| d.readiness),
    ("activity_score", "Activity score", "", |d| d.activity_score),
    ("in_bed_min", "Time in bed", "min", |d| d.in_bed_min),
    ("asleep_min", "Time asleep", "min", |d| d.asleep_min),
    ("nap_min", "Naps", "min", |d| d.nap_min),
    ("efficiency", "Sleep efficiency", "%", |d| d.efficiency),
    ("deep_min", "Deep sleep", "min", |d| d.deep_min),
    ("rem_min", "REM sleep", "min", |d| d.rem_min),
    ("hrv", "HRV", "ms", |d| d.hrv),
    ("rhr", "Resting heart rate", "bpm", |d| d.rhr),
    ("temp_dev", "Temperature deviation", "°C", |d| d.temp_dev),
    ("spo2", "Blood oxygen", "%", |d| d.spo2),
    ("breath", "Respiratory rate", "brpm", |d| d.breath),
    ("steps", "Steps", "", |d| d.steps),
    ("active_kcal", "Active energy", "kcal", |d| d.active_kcal),
    ("total_kcal", "Total energy", "kcal", |d| d.total_kcal),
    ("distance_m", "Distance", "m", |d| d.distance_m),
    ("stressed_min", "Stressed time", "min", |d| d.stressed_min),
    ("restored_min", "Restored time", "min", |d| d.restored_min),
    ("workout_min", "Workout time", "min", |d| (d.workouts > 0).then_some(d.workout_min)),
];

fn metric(key: &str) -> &'static Metric {
    METRICS.iter().find(|m| m.0 == key).expect("a metric key from this file")
}

/// Join every source into one fact per local day.
#[allow(clippy::too_many_arguments)]
pub(crate) fn day_facts(
    nights: &[NightFact],
    scores: &BTreeMap<i64, Map<String, Value>>,
    activity_daily: &Value,
    stress_days: &BTreeMap<i64, stress::DayStress>,
    workouts: &[Workout],
    journal: &Journal,
    rest_days: &BTreeSet<i64>,
    tz: i64,
) -> Vec<DayFact> {
    fn at(days: &mut BTreeMap<i64, DayFact>, day: i64) -> &mut DayFact {
        let fact = days.entry(day).or_default();
        fact.day = day;
        fact
    }
    let mut days: BTreeMap<i64, DayFact> = BTreeMap::new();
    for n in nights {
        let f = at(&mut days, n.wake_day);
        if n.main {
            f.bedtime = Some(hm(clock_min(n.start_unix, tz)));
            f.wake = Some(hm(clock_min(n.end_unix, tz)));
            f.in_bed_min = Some(n.in_bed_min.round());
            f.asleep_min = n.asleep_min.map(f64::round);
            f.efficiency = n.efficiency;
            f.deep_min = n.deep_min.map(f64::round);
            f.rem_min = n.rem_min.map(f64::round);
            f.hrv = n.hrv.map(f64::round);
            f.rhr = n.rhr.map(f64::round);
            f.temp_dev = n.temp_dev.map(|t| (t * 100.0).round() / 100.0);
            f.spo2 = n.spo2.map(r1);
            f.breath = n.breath.map(r1);
        } else {
            *f.nap_min.get_or_insert(0.0) += n.asleep_min.unwrap_or(n.in_bed_min).round();
        }
    }
    for (day, s) in scores {
        let f = at(&mut days, *day);
        f.sleep_score = s.get("sleep").and_then(|v| v["score"].as_f64());
        f.readiness = s.get("readiness").and_then(|v| v["score"].as_f64());
        f.activity_score = s.get("activity").and_then(|v| v["score"].as_f64());
    }
    if let Some(map) = activity_daily.as_object() {
        for (key, v) in map {
            let Some(day) = parse_day(key) else { continue };
            let f = at(&mut days, day);
            f.steps = v["steps"].as_f64();
            f.active_kcal = v["active_kcal"].as_f64();
            f.total_kcal = v["total_kcal"].as_f64();
            f.distance_m = v["distance_m"].as_f64();
        }
    }
    for (day, s) in stress_days {
        let f = at(&mut days, *day);
        f.stressed_min = Some(s.stressed_min);
        f.restored_min = Some(s.restored_min);
    }
    for w in workouts {
        let f = at(&mut days, local_day(w.start_unix, tz));
        f.workouts += 1;
        f.workout_min += w.minutes().round();
    }
    for tag in &journal.tags {
        if let Some(day) = parse_day(&tag.day) {
            at(&mut days, day).tags.push(tag.tag.clone());
        }
    }
    for day in rest_days {
        if let Some(f) = days.get_mut(day) {
            f.rest_mode = true;
        }
    }
    days.into_values().collect()
}

/// The Monday of the ISO week of `day`, and the week id `YYYY-Www`.
fn iso_week(day: i64) -> (i64, String) {
    let monday = day - (day + 3).rem_euclid(7);
    let thursday = monday + 3;
    let (year, _, _) = civil(thursday);
    let jan1 = crate::days_from_civil(year, 1, 1);
    (monday, format!("{year:04}-W{:02}", (thursday - jan1) / 7 + 1))
}

fn month_bounds(day: i64) -> (i64, i64, String) {
    let (y, m, _) = civil(day);
    let first = crate::days_from_civil(y, m, 1);
    let (ny, nm) = if m == 12 { (y + 1, 1) } else { (y, m + 1) };
    (first, crate::days_from_civil(ny, nm, 1) - 1, format!("{y:04}-{m:02}"))
}

const REPORT_KEYS: [&str; 13] = [
    "sleep_score", "readiness", "activity_score", "asleep_min", "efficiency", "hrv", "rhr",
    "temp_dev", "spo2", "breath", "steps", "active_kcal", "stressed_min",
];

fn period_report(id: &str, first: i64, last: i64, facts: &[DayFact], previous: &[&DayFact], today: i64, what: &str) -> Option<Value> {
    let days: Vec<&DayFact> = facts.iter().filter(|f| (first..=last).contains(&f.day)).collect();
    if days.is_empty() {
        return None;
    }
    let average = |set: &[&DayFact], key: &str| -> Option<(f64, usize)> {
        let values: Vec<f64> = set.iter().filter_map(|d| (metric(key).3)(d)).collect();
        mean(&values).map(|m| (m, values.len()))
    };
    let mut metrics = Map::new();
    for key in REPORT_KEYS {
        let Some((avg, n)) = average(&days, key) else { continue };
        let prev = average(previous, key).map(|p| p.0);
        let decimals = if matches!(key, "temp_dev") { 100.0 } else { 10.0 };
        let round = |v: f64| (v * decimals).round() / decimals;
        metrics.insert(key.into(), json!({
            "name": metric(key).1, "unit": metric(key).2,
            "avg": round(avg), "n": n,
            "prev": prev.map(round),
            "delta": prev.map(|p| round(avg - p)),
        }));
    }
    let by_readiness = |pick: fn(f64, f64) -> bool| -> Option<Value> {
        let mut best: Option<(&DayFact, f64)> = None;
        for d in &days {
            let Some(score) = d.readiness.or(d.sleep_score) else { continue };
            if best.is_none_or(|b| pick(score, b.1)) {
                best = Some((d, score));
            }
        }
        best.map(|(d, score)| json!({ "day": ymd(d.day), "score": score }))
    };
    let total = |key: &str| -> f64 { days.iter().filter_map(|d| (metric(key).3)(d)).sum::<f64>().round() };

    let mut highlights: Vec<String> = Vec::new();
    let mut say = |key: &str, label: &str, unit: &str, percent: bool| {
        let Some(m) = metrics.get(key) else { return };
        let avg = m["avg"].as_f64().unwrap_or(0.0);
        let mut line = format!("Your average {label} was {}{unit}", avg.round());
        if let (Some(delta), Some(prev)) = (m["delta"].as_f64(), m["prev"].as_f64()) {
            let change = if percent && prev != 0.0 { delta / prev * 100.0 } else { delta };
            let amount = format!("{}{}", change.abs().round(), if percent { " %" } else { "" });
            if change.abs().round() >= 1.0 {
                let direction = if change > 0.0 { "higher" } else { "lower" };
                line.push_str(&format!(", {amount} {direction} than the {what} before"));
            } else {
                line.push_str(&format!(", the same as the {what} before"));
            }
        }
        highlights.push(line + ".");
    };
    say("readiness", "readiness", "", false);
    say("sleep_score", "sleep score", "", false);
    say("hrv", "HRV", " ms", true);
    say("steps", "step count", "", true);
    let workouts: usize = days.iter().map(|d| d.workouts).sum();
    if workouts > 0 {
        let minutes: f64 = days.iter().map(|d| d.workout_min).sum();
        highlights.push(format!(
            "You had {workouts} activity session{} for a total of {} minutes.",
            if workouts == 1 { "" } else { "s" },
            minutes.round()
        ));
    }
    let mut tag_counts: BTreeMap<&str, usize> = BTreeMap::new();
    for d in &days {
        for t in &d.tags {
            *tag_counts.entry(t).or_default() += 1;
        }
    }
    Some(json!({
        "id": id,
        "start": ymd(first),
        "end": ymd(last),
        "days": days.len(),
        "complete": last < today,
        "metrics": metrics,
        "best_day": by_readiness(|a, b| a > b),
        "worst_day": by_readiness(|a, b| a < b),
        "totals": {
            "steps": total("steps"),
            "active_kcal": total("active_kcal"),
            "distance_m": total("distance_m"),
            "workouts": workouts,
            "workout_min": days.iter().map(|d| d.workout_min).sum::<f64>().round(),
            "rest_days": days.iter().filter(|d| d.rest_mode).count(),
        },
        "tags": tag_counts,
        "highlights": highlights,
    }))
}

/// Reports for the last 8 weeks and the last 6 months that have data, newest first.
pub(crate) fn reports(facts: &[DayFact], today: i64) -> Value {
    let in_range = |first: i64, last: i64| -> Vec<&DayFact> {
        facts.iter().filter(|f| (first..=last).contains(&f.day)).collect()
    };
    let (this_monday, _) = iso_week(today);
    let weeks: Vec<Value> = (0..8)
        .filter_map(|back| {
            let monday = this_monday - 7 * back;
            let (_, id) = iso_week(monday);
            period_report(&id, monday, monday + 6, facts, &in_range(monday - 7, monday - 1), today, "week")
        })
        .collect();
    let mut months = Vec::new();
    let mut cursor = today;
    for _ in 0..6 {
        let (first, last, id) = month_bounds(cursor);
        let (prev_first, prev_last, _) = month_bounds(first - 1);
        if let Some(r) = period_report(&id, first, last, facts, &in_range(prev_first, prev_last), today, "month") {
            months.push(r);
        }
        cursor = first - 1;
    }
    json!({ "weeks": weeks, "months": months })
}

/// A tag needs this many nights before it gets a result.
pub(crate) const MIN_TAG_NIGHTS: usize = 3;

/// For each tag: the night after a day with the tag against the other nights.
pub(crate) fn correlations(facts: &[DayFact]) -> Value {
    const NIGHT_KEYS: [&str; 7] =
        ["sleep_score", "readiness", "hrv", "rhr", "efficiency", "asleep_min", "temp_dev"];
    let by_day: BTreeMap<i64, &DayFact> = facts.iter().map(|f| (f.day, f)).collect();
    let tags: BTreeSet<&str> = facts.iter().flat_map(|f| f.tags.iter().map(String::as_str)).collect();
    let mut out = Vec::new();
    for tag in tags {
        // the night after the tagged day has its wake day one day later
        let tagged_days: BTreeSet<i64> = facts
            .iter()
            .filter(|f| f.tags.iter().any(|t| t == tag))
            .map(|f| f.day + 1)
            .collect();
        let nights_with: Vec<&DayFact> = tagged_days
            .iter()
            .filter_map(|d| by_day.get(d).copied())
            .filter(|f| f.in_bed_min.is_some())
            .collect();
        let nights_without: Vec<&DayFact> = facts
            .iter()
            .filter(|f| f.in_bed_min.is_some() && !tagged_days.contains(&f.day))
            .collect();
        let mut effects = Vec::new();
        if nights_with.len() >= MIN_TAG_NIGHTS && nights_without.len() >= MIN_TAG_NIGHTS {
            for key in NIGHT_KEYS {
                let pick = metric(key).3;
                let with: Vec<f64> = nights_with.iter().filter_map(|f| pick(f)).collect();
                let without: Vec<f64> = nights_without.iter().filter_map(|f| pick(f)).collect();
                let (Some(a), Some(b)) = (Stats::of(&with), Stats::of(&without)) else { continue };
                let delta = a.mean - b.mean;
                let pooled = ((a.sd.powi(2) + b.sd.powi(2)) / 2.0).sqrt();
                let size = if pooled > 1e-9 { delta / pooled } else { 0.0 };
                // Welch's t: a large difference from few nights is not a finding
                let error = (a.sd.powi(2) / a.n as f64 + b.sd.powi(2) / b.n as f64).sqrt();
                let t = if error > 1e-9 { (delta / error).abs() } else { 0.0 };
                let strength = match (size.abs(), t) {
                    (s, t) if s >= 0.5 && t >= 2.5 => "clear",
                    (s, t) if s >= 0.2 && t >= 1.5 => "weak",
                    _ => "none",
                };
                effects.push(json!({
                    "metric": key, "name": metric(key).1, "unit": metric(key).2,
                    "with": (a.mean * 100.0).round() / 100.0,
                    "without": (b.mean * 100.0).round() / 100.0,
                    "delta": (delta * 100.0).round() / 100.0,
                    "delta_pct": (b.mean.abs() > 1e-9).then(|| r1(delta / b.mean * 100.0)),
                    "effect_size": (size * 100.0).round() / 100.0,
                    "strength": strength,
                    "nights": a.n,
                }));
            }
        }
        out.push(json!({
            "tag": tag,
            "days": facts.iter().filter(|f| f.tags.iter().any(|t| t == tag)).count(),
            "nights": nights_with.len(),
            "other_nights": nights_without.len(),
            "ready": nights_with.len() >= MIN_TAG_NIGHTS,
            "effects": effects,
        }));
    }
    json!({ "basis": BASIS, "min_nights": MIN_TAG_NIGHTS, "tags": out })
}

/// The cycle estimate, or null when the journal has no period.
pub(crate) fn cycle_json(journal: &Journal, nights: &[NightFact], today: i64) -> Value {
    let starts: Vec<i64> = journal.periods.iter().filter_map(|d| parse_day(d)).collect();
    let temps: Vec<(i64, f64)> = nights
        .iter()
        .filter(|n| n.main)
        .filter_map(|n| n.temp_dev.map(|t| (n.wake_day, t)))
        .collect();
    match cycle::cycle_estimate(&starts, today, &temps) {
        Some(e) => json!({
            "basis": BASIS,
            "cycle_day": e.cycle_day,
            "phase": e.phase,
            "mean_cycle_days": e.mean_cycle_days,
            "cycles_used": e.cycles_used,
            "last_period": ymd(e.last_period_day),
            "next_period": ymd(e.next_period_day),
            "days_to_next_period": e.next_period_day - today,
            "ovulation": ymd(e.ovulation_day),
            "ovulation_confirmed": e.ovulation_confirmed,
            "fertile_start": ymd(e.fertile_start_day),
            "fertile_end": ymd(e.fertile_end_day),
        }),
        None => Value::Null,
    }
}

/// One row per day with every metric, newest day last.
pub(crate) fn export_csv(facts: &[DayFact]) -> String {
    let mut csv = String::from("date,bedtime,wake");
    for m in METRICS {
        csv.push(',');
        csv.push_str(m.0);
    }
    csv.push_str(",workouts,rest_mode,tags\n");
    for f in facts {
        csv.push_str(&format!(
            "{},{},{}",
            ymd(f.day),
            f.bedtime.as_deref().unwrap_or(""),
            f.wake.as_deref().unwrap_or("")
        ));
        for m in METRICS {
            csv.push(',');
            if let Some(v) = (m.3)(f) {
                csv.push_str(&format!("{}", (v * 100.0).round() / 100.0));
            }
        }
        // a tag is lower case text without a comma or a quote by construction
        csv.push_str(&format!(",{},{},{}\n", f.workouts, u8::from(f.rest_mode), f.tags.join(";")));
    }
    csv
}

/// The rows for the store's `daily_summary` table.
pub(crate) fn daily_rows(facts: &[DayFact]) -> Vec<(String, &'static str, f64)> {
    facts
        .iter()
        .flat_map(|f| {
            METRICS
                .iter()
                .filter_map(move |m| (m.3)(f).map(|v| (ymd(f.day), m.0, v)))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::journal::parse_day;

    fn night(wake_day: i64, hours: f64, hrv: f64, score: f64) -> NightFact {
        let end = (wake_day * 86_400 + 7 * 3600) as f64;
        NightFact {
            start_unix: end - hours * 3600.0,
            end_unix: end,
            wake_day,
            in_bed_min: hours * 60.0,
            asleep_min: Some(hours * 54.0),
            hrv: Some(hrv),
            rhr: Some(52.0),
            sleep_score: Some(score),
            ..Default::default()
        }
    }

    #[test]
    fn battery_estimates_the_days_left_from_the_last_run() {
        let day = 86_400.0;
        // charged to 100 at day 1, then 15 % per day for 3 days
        let points = [(0.0, 40.0), (day, 100.0), (2.0 * day, 85.0), (3.0 * day, 70.0), (4.0 * day, 55.0)];
        let b = battery(&points, Some(0.0), 4.0 * day);
        assert_eq!(b["rate_pct_per_day"], 15.0);
        assert_eq!(b["days_left"], 3.7);
        assert_eq!(b["charging"], false);
        assert_eq!(b["history"].as_array().unwrap().len(), 5);
        let charging = battery(&[(0.0, 40.0), (3600.0, 60.0)], Some(35.0), 3600.0);
        assert_eq!(charging["charging"], true);
        assert!(charging["days_left"].is_null());
        assert!(battery(&[], None, 0.0).is_null());
    }

    #[test]
    fn the_longest_sleep_of_a_day_is_the_main_sleep() {
        let mut nights = vec![night(10, 7.5, 40.0, 80.0), night(10, 1.0, 40.0, 0.0), night(11, 2.0, 40.0, 0.0)];
        mark_main(&mut nights);
        assert_eq!(nights.iter().map(|n| n.main).collect::<Vec<_>>(), [true, false, false]);
    }

    #[test]
    fn met_bouts_become_workouts() {
        let mut met = BTreeMap::new();
        for m in 600..625 {
            met.insert(m, if m == 610 { 0.2 } else { 3.0 }); // 25 min at 4 MET, 1 min pause
        }
        for m in 700..705 {
            met.insert(m, 4.0); // too short
        }
        for m in 100..130 {
            met.insert(m, 3.0); // in a sleep period
        }
        let w = met_workouts(&met, &[(0, 200)], 70.0, 0);
        assert_eq!(w.len(), 1);
        assert_eq!(w[0].minutes(), 25.0);
        assert_eq!(w[0].label, "Moderate activity");
        assert_eq!(w[0].start_unix, 600.0 * 60.0);
    }

    #[test]
    fn an_entry_replaces_the_ring_session_and_credits_missing_energy() {
        let ring = vec![Workout {
            id: "ring-1".into(),
            start_unix: 36_000.0,
            end_unix: 36_000.0 + 1800.0,
            label: "running".into(),
            source: "ring",
            source_name: "Ring".into(),
            active_kcal: Some(250.0),
            distance_m: None,
            avg_hr: None,
            max_hr: None,
            note: String::new(),
        }];
        let external: External = serde_json::from_value(json!({ "workouts": [
            { "id": "a", "start_unix": 36_000, "end_unix": 37_800, "label": "Run",
              "active_kcal": 300.0, "avg_hr": 150.0, "source": "Apple Watch" },
            { "id": "b", "start_unix": 50_000, "end_unix": 53_600, "label": "Swim",
              "active_kcal": 400.0 },
        ]}))
        .unwrap();
        // the ring measured 5 MET above rest during the run, nothing during the swim
        let met: BTreeMap<i64, f64> = (600..630).map(|m| (m, 5.0)).collect();
        let r = merge_workouts(ring, &external, &Journal::default(), &met, &[], 70.0, 0);
        assert_eq!(r.workouts.len(), 2);
        assert!(r.workouts.iter().all(|w| w.source == "health"));
        // run: ring 5 × 70 / 60 × 30 = 175 kcal, entry 300 → 125; swim: 400
        assert_eq!(r.credited_kcal[&0].round(), 525.0);
        assert_eq!(r.credited_min[&0], 60.0);
    }

    #[test]
    fn a_tag_compares_the_night_after_it() {
        let mut facts: Vec<DayFact> = (0..12)
            .map(|d| DayFact {
                day: d,
                in_bed_min: Some(450.0),
                hrv: Some(if d % 3 == 1 { 35.0 + (d % 2) as f64 } else { 45.0 + (d % 2) as f64 }),
                ..Default::default()
            })
            .collect();
        for d in [0, 3, 6, 9] {
            facts[d].tags.push("alcohol".into());
        }
        let c = correlations(&facts);
        let tag = &c["tags"][0];
        assert_eq!(tag["tag"], "alcohol");
        assert_eq!(tag["nights"], 4);
        let hrv = tag["effects"].as_array().unwrap().iter().find(|e| e["metric"] == "hrv").unwrap();
        assert_eq!(hrv["delta"], -10.0);
        assert_eq!(hrv["strength"], "clear");
    }

    #[test]
    fn weekly_report_compares_with_the_week_before() {
        let monday = parse_day("2026-09-21").unwrap();
        let facts: Vec<DayFact> = (monday - 7..monday + 7)
            .map(|d| DayFact {
                day: d,
                readiness: Some(if d < monday { 70.0 } else { 80.0 }),
                steps: Some(8000.0),
                workouts: usize::from(d == monday),
                workout_min: if d == monday { 40.0 } else { 0.0 },
                ..Default::default()
            })
            .collect();
        let r = reports(&facts, monday + 8);
        let week = r["weeks"].as_array().unwrap().iter().find(|w| w["id"] == "2026-W39").unwrap();
        assert_eq!(week["start"], "2026-09-21");
        assert_eq!(week["complete"], true);
        assert_eq!(week["metrics"]["readiness"]["delta"], 10.0);
        assert_eq!(week["totals"]["steps"], 56_000.0);
        assert_eq!(
            week["highlights"][0],
            "Your average readiness was 80, 10 higher than the week before."
        );
        assert_eq!(r["months"][0]["id"], "2026-09");
    }

    #[test]
    fn csv_has_one_row_per_day() {
        let facts = vec![DayFact {
            day: parse_day("2026-09-27").unwrap(),
            hrv: Some(41.0),
            bedtime: Some("23:10".into()),
            tags: vec!["alcohol".into(), "late meal".into()],
            ..Default::default()
        }];
        let csv = export_csv(&facts);
        let mut lines = csv.lines();
        assert!(lines.next().unwrap().starts_with("date,bedtime,wake,sleep_score,"));
        let row = lines.next().unwrap();
        assert!(row.starts_with("2026-09-27,23:10,,"));
        assert!(row.ends_with(",0,0,alcohol;late meal"));
        assert_eq!(daily_rows(&facts), vec![("2026-09-27".to_string(), "hrv", 41.0)]);
    }
}
