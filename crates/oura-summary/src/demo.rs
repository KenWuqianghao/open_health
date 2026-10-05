//! A demo database: days of plausible ring data, made without a ring.
//!
//! It gives the dashboard and the iOS app something to show before the first
//! sync, and it gives the tests a complete history. The data follows one fixed
//! story so that every screen has content: nights after a day with the `alcohol`
//! tag have a lower HRV and a higher heart rate, working hours are tense, evenings
//! are calm, every third day has a run, and some days have a nap.
//!
//! The events carry decoded JSON with the keys of the real decoders. Their bodies
//! are counters, not ring bytes: do not feed this database to `redecode`.

use std::path::Path;

use anyhow::Result;
use oura_protocol::device::DeviceInfo;
use oura_protocol::events::{event_name, RingEvent};
use oura_store::storage::Store;
use serde_json::{json, Value};

use crate::{civil, external, journal};

pub const DEMO_SERIAL: &str = "DEMO00000001";

#[derive(Clone, Copy, Debug)]
pub struct DemoOptions {
    /// Days of history, ending on the local day of `end_unix`.
    pub days: u32,
    pub end_unix: i64,
    /// Hours from UTC of the wearer's clock.
    pub tz: i64,
    pub seed: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DemoReport {
    pub events: usize,
    pub nights: usize,
    pub days: u32,
}

/// xorshift64*: small, fast, and the same on every platform.
struct Rng(u64);

impl Rng {
    fn unit(&mut self) -> f64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        (self.0.wrapping_mul(0x2545_f491_4f6c_dd1d) >> 11) as f64 / (1u64 << 53) as f64
    }
    /// About normal (the sum of 4 uniform values), mean 0, the given SD.
    fn gauss(&mut self, sd: f64) -> f64 {
        let sum: f64 = (0..4).map(|_| self.unit()).sum();
        (sum - 2.0) * 1.732 * sd
    }
}

struct Writer<'a> {
    store: &'a Store,
    base_unix: i64,
    end_unix: i64,
    tz: i64,
    counter: u64,
    pending: Vec<(i64, u8, Value)>,
}

impl Writer<'_> {
    fn ds(&self, unix: i64) -> u32 {
        ((unix - self.base_unix).max(0) * 10) as u32
    }
    fn push(&mut self, unix: i64, tag: u8, decoded: Value) {
        if unix <= self.end_unix {
            self.pending.push((unix, tag, decoded));
        }
    }
    /// Store the pending events in time order. The phone captures the events of a
    /// local day at the end of that day.
    fn flush(&mut self) -> Result<usize> {
        self.pending.sort_by_key(|e| e.0);
        let pending = std::mem::take(&mut self.pending);
        let mut rows = Vec::with_capacity(pending.len());
        for (unix, tag, decoded) in pending {
            self.counter += 1;
            let local_day = (unix + self.tz * 3600).div_euclid(86_400);
            let captured = ((local_day + 1) * 86_400 - self.tz * 3600).min(self.end_unix);
            let event = RingEvent {
                tag,
                name: event_name(tag),
                timestamp: self.ds(unix),
                body: self.counter.to_le_bytes().to_vec(),
                decoded: Some(decoded),
            };
            rows.push((event, captured.max(unix)));
        }
        Ok(self.store.insert_events_at(DEMO_SERIAL, &rows)?)
    }
}

/// The plan of one local day.
struct Day {
    index: i64,
    weekend: bool,
    alcohol: bool,
    run: bool,
    nap: bool,
    strained: bool,
}

fn plan(n: i64, first_day: i64, days: i64) -> Day {
    let index = first_day + n;
    Day {
        index,
        weekend: (index + 3).rem_euclid(7) >= 5,
        alcohol: n.rem_euclid(6) == 4,
        run: n.rem_euclid(3) == 0,
        nap: n.rem_euclid(8) == 5,
        // three days of strain, which the illness check shows in the history
        strained: (days - 13..days - 10).contains(&n),
    }
}

/// A night of 30-second stages: about 90-minute cycles, more deep sleep early
/// and more REM late, with short wake periods.
fn hypnogram(rng: &mut Rng, minutes: i64, restless: bool) -> Vec<&'static str> {
    let epochs = (minutes * 2) as usize;
    let mut stages = Vec::with_capacity(epochs);
    let latency = 16 + (rng.unit() * 24.0) as usize;
    stages.resize(latency.min(epochs), "awake");
    let mut cycle = 0;
    while stages.len() < epochs {
        let deep = (50.0 - 9.0 * cycle as f64).max(8.0) + rng.gauss(6.0);
        let rem = 22.0 + 9.0 * cycle as f64 - if restless { 12.0 } else { 0.0 } + rng.gauss(5.0);
        let plan: [(&'static str, f64); 5] = [
            ("light", 34.0 + rng.gauss(6.0)),
            ("deep", deep),
            ("light", 40.0 + rng.gauss(8.0)),
            ("rem", rem.max(6.0)),
            ("awake", if restless { 9.0 } else { 3.0 } + rng.unit() * 5.0),
        ];
        for (stage, length) in plan {
            let n = length.max(2.0) as usize;
            stages.extend(std::iter::repeat_n(stage, n));
        }
        cycle += 1;
    }
    stages.truncate(epochs);
    stages
}

fn write_sleep(w: &mut Writer, rng: &mut Rng, start: i64, minutes: i64, day: &Day, after_alcohol: bool) {
    let end = start + minutes * 60;
    let strain = if day.strained { 1.0 } else { 0.0 };
    let drink = if after_alcohol { 1.0 } else { 0.0 };
    let hrv = 46.0 + rng.gauss(3.0) - 9.0 * drink - 10.0 * strain;
    let rhr = 51.0 + rng.gauss(1.2) + 5.0 * drink + 6.0 * strain;
    let breath = 14.3 + rng.gauss(0.25) + 1.3 * strain;
    let temp = 35.4 + rng.gauss(0.08) + 0.6 * strain + 0.15 * drink;
    let spo2 = 96.6 + rng.gauss(0.4);

    for slot in 0..minutes / 5 {
        let at = start + slot * 300;
        // heart rate falls to its lowest two thirds into the night
        let phase = slot as f64 * 5.0 / minutes as f64;
        let dip = 1.0 - (phase - 0.66).abs() / 0.66;
        let hr_now = rhr + 9.0 * (1.0 - dip) + rng.gauss(0.8);
        if slot % 6 == 0 {
            let n = (6).min(minutes / 5 - slot) as usize;
            let hr: Vec<i64> = (0..n).map(|i| (hr_now + 0.3 * i as f64 + rng.gauss(0.7)).round() as i64).collect();
            let rm: Vec<i64> = (0..n).map(|_| (hrv + 6.0 * dip + rng.gauss(4.0)).max(8.0).round() as i64).collect();
            w.push(at, 0x5d, json!({ "hr_bpm": hr, "rmssd_ms": rm, "interval_min": 5 }));
        }
        if slot % 3 == 0 {
            let temps: Vec<f64> = (0..30)
                .map(|_| ((temp + 0.2 * dip + rng.gauss(0.03)) * 100.0).round() / 100.0)
                .collect();
            w.push(at + 1, 0x75, json!({ "temps_c": temps }));
        }
        let oxygen: Vec<i64> = (0..10).map(|_| (spo2 + rng.gauss(0.8)).clamp(90.0, 100.0).round() as i64).collect();
        w.push(at + 2, 0x6f, json!({ "spo2_percent": oxygen }));
        w.push(at + 3, 0x47, json!({ "orientation": 1, "motion_seconds": (rng.unit() * 3.0) as i64,
                                    "avg_x": 0, "avg_y": 0, "avg_z": 64 }));
        w.push(at + 4, 0x6a, json!({ "average_hr": hr_now.round(), "breath": ((breath + rng.gauss(0.3)) * 8.0).round() / 8.0,
                                    "breath_v": 0.5, "motion_count": 1, "sleep_state": 1 }));
        if slot % 2 == 0 {
            w.push(at + 5, 0x72, json!({ "acm_mad": [0.01, 0.01, 0.02, 0.01, 0.01, 0.02] }));
            let ibi = 60_000.0 / hr_now;
            let beats: Vec<i64> = (0..6).map(|_| (ibi + rng.gauss(hrv / 1.41)).round() as i64).collect();
            w.push(at + 6, 0x60, json!({ "ibi_ms": beats, "amplitude": [900, 900, 900, 900, 900, 900],
                                        "hr_bpm": [hr_now.round()] }));
        }
    }
    if minutes >= 180 {
        let stages = hypnogram(rng, minutes, after_alcohol || day.strained);
        for (page, chunk) in stages.chunks(52).enumerate() {
            w.push(end + 10 + page as i64, 0x5a, json!({ "header": page, "phases": chunk }));
        }
    }
    w.push(end + 5, 0x76, json!({
        "bedtime_start_ds": w.ds(start), "bedtime_end_ds": w.ds(end),
        "duration_hours": (minutes as f64 / 60.0 * 100.0).round() / 100.0,
    }));
}

/// MET and the heart state at a local minute of a waking day.
fn waking_state(day: &Day, minute: i64, run_at: i64) -> (f64, f64, f64) {
    let between = |a: i64, b: i64| (a..b).contains(&minute);
    if day.run && between(run_at, run_at + 38) {
        return (9.2, 152.0, 6.0);
    }
    if between(8 * 60 + 35, 8 * 60 + 55) || between(12 * 60 + 30, 12 * 60 + 46) {
        return (3.6, 96.0, 12.0);
    }
    let tense = !day.weekend && (between(10 * 60, 12 * 60) || between(14 * 60, 16 * 60 + 30));
    if tense {
        return (1.2, 83.0, 11.0);
    }
    if between(20 * 60, 22 * 60 + 30) {
        return (1.1, 60.0, 44.0);
    }
    (1.25, 70.0, 26.0)
}

fn write_waking(w: &mut Writer, rng: &mut Rng, day: &Day, wake: i64, bed: i64, nap: Option<(i64, i64)>) {
    let midnight = day.index * 86_400 - w.tz * 3600;
    let run_at = 18 * 60 + 10;
    let mut minute = (wake - midnight) / 60;
    let last = (bed - midnight) / 60;
    while minute < last {
        let n = (15).min(last - minute);
        let met: Vec<f64> = (minute..minute + n)
            .map(|m| {
                let (met, _, _) = waking_state(day, m, run_at);
                ((met + rng.gauss(0.06 * met)).max(0.9) * 10.0).round() / 10.0
            })
            .collect();
        w.push(midnight + minute * 60, 0x50, json!({ "state": 1, "met": met }));
        minute += n;
    }
    let mut at = wake + 120;
    while at < bed {
        let asleep = nap.is_some_and(|(a, b)| at >= a && at <= b);
        if !asleep {
            let (_, hr, spread) = waking_state(day, (at - midnight) / 60, run_at);
            let hr = hr + rng.gauss(2.0);
            for record in 0..3 {
                let beats: Vec<i64> = (0..10)
                    .map(|_| (60_000.0 / hr + rng.gauss(spread / 1.41)).round() as i64)
                    .collect();
                w.push(at + record * 12, 0x80, json!({
                    "ibi_ms": beats, "quality": [1, 1, 1, 1, 1, 1, 1, 1, 1, 1], "hr_bpm": [hr.round()],
                }));
            }
        }
        at += 300;
    }
    w.push(midnight + 12 * 3600, 0x85, json!({ "unix_time": midnight + 12 * 3600, "trailer": 0 }));
}

/// Write the demo database to `db`, with `journal.json` and `external.json` next
/// to it. The file at `db` must not exist.
pub fn write_demo(db: &Path, opts: &DemoOptions) -> Result<DemoReport> {
    let store = Store::open(db)?;
    let days = opts.days.max(2) as i64;
    let today = (opts.end_unix + opts.tz * 3600).div_euclid(86_400);
    let first_day = today - days + 1;
    let base_unix = (first_day - 1) * 86_400 - opts.tz * 3600;
    let info = DeviceInfo {
        api_version: "2.0.0".into(),
        firmware_version: "3.4.3".into(),
        bootloader_version: "1.0.5".into(),
        bt_stack_version: "1.0.0".into(),
        mac: "aa:bb:cc:dd:ee:ff".into(),
    };
    store.upsert_device(DEMO_SERIAL, Some("BLB_03"), Some(&info))?;

    let mut rng = Rng(opts.seed | 1);
    let mut w = Writer {
        store: &store,
        base_unix,
        end_unix: opts.end_unix,
        tz: opts.tz,
        counter: 0,
        pending: Vec::new(),
    };
    w.push(base_unix + 60, 0x85, json!({ "unix_time": base_unix + 60, "trailer": 0 }));

    let mut battery = 78.0f64;
    let mut events = 0;
    let mut nights = 0;
    let mut tags = Vec::new();
    let mut manual = Vec::new();
    let mut watch = Vec::new();
    for n in 0..days {
        let day = plan(n, first_day, days);
        let before = plan(n - 1, first_day, days);
        let midnight = day.index * 86_400 - opts.tz * 3600;
        // the night that ends this morning
        let late = if before.weekend { 50.0 } else { 0.0 } + if before.alcohol { 40.0 } else { 0.0 };
        let bed = midnight - 50 * 60 + ((late + rng.gauss(22.0)) * 60.0) as i64;
        let minutes = (444.0 + rng.gauss(28.0) - if before.alcohol { 30.0 } else { 0.0 }) as i64;
        write_sleep(&mut w, &mut rng, bed, minutes, &day, before.alcohol);
        nights += 1;
        let wake = bed + minutes * 60;
        // tonight's bedtime ends the waking day
        let tonight = midnight + 86_400 - 50 * 60 + if day.weekend || day.alcohol { 45 * 60 } else { 0 };
        let nap = day.nap.then(|| (midnight + 14 * 3600 + 600, midnight + 14 * 3600 + 600 + 42 * 60));
        if let Some((start, end)) = nap {
            write_sleep(&mut w, &mut rng, start, (end - start) / 60, &day, false);
            nights += 1;
        }
        write_waking(&mut w, &mut rng, &day, wake, tonight, nap);

        for hour in (0..24).step_by(2) {
            let at = midnight + hour * 3600;
            battery -= 0.62 * 2.0 + rng.unit() * 0.2;
            if battery < 24.0 {
                battery = 100.0;
            }
            w.push(at, 0x61, json!({ "kind": "battery_level_changed", "battery_pct": battery.round() as i64,
                                     "voltage_mv": (3600.0 + 7.5 * battery).round() as i64 }));
        }
        events += w.flush()?;

        let (y, m, d) = civil(day.index);
        let ymd = format!("{y:04}-{m:02}-{d:02}");
        if day.alcohol {
            tags.push(json!({ "op": "add_tag", "day": ymd, "tag": "alcohol" }));
        }
        if n.rem_euclid(9) == 2 {
            tags.push(json!({ "op": "add_tag", "day": ymd, "tag": "late meal" }));
        }
        if n.rem_euclid(5) == 1 {
            tags.push(json!({ "op": "add_tag", "day": ymd, "tag": "caffeine" }));
        }
        if n.rem_euclid(7) == 6 && midnight + 8 * 3600 <= opts.end_unix {
            manual.push(json!({ "op": "add_workout", "start_unix": midnight + 7 * 3600 + 900,
                                "duration_min": 30, "label": "Yoga" }));
        }
        let run_start = midnight + 18 * 3600 + 600;
        if day.run && n % 2 == 0 && run_start + 38 * 60 <= opts.end_unix {
            watch.push(json!({
                "id": format!("demo-run-{n}"), "start_unix": run_start, "end_unix": run_start + 38 * 60,
                "label": "Running", "active_kcal": 410.0, "distance_m": 6200.0,
                "avg_hr": 151.0, "max_hr": 171.0, "source": "Apple Watch",
            }));
        }
    }
    store.set_cursor(DEMO_SERIAL, w.ds(opts.end_unix))?;

    let mut book = journal::Journal::default();
    for op in tags.iter().chain(&manual) {
        book.apply_op(op, opts.end_unix)?;
    }
    std::fs::write(journal::journal_path(db), serde_json::to_vec_pretty(&book)?)?;
    external::write_external(
        db,
        &json!({
            "workouts": watch,
            "vo2max": { "value": 44.6, "at_unix": opts.end_unix - 2 * 86_400, "source": "Apple Watch" },
        }),
    )?;
    Ok(DemoReport { events, nights, days: days as u32 })
}
