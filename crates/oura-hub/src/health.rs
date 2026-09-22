//! Apple Health samples pushed by the phone (Apple Watch and every other source
//! except this app's own export), and the compact "watch" summary the agent tools
//! return. Rows are stored as they come; the summary is pure over the rows.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HealthSample {
    pub uuid: String,
    /// snake_case kind: heart_rate, step_count, sleep_analysis, workout, …
    pub kind: String,
    pub start_unix: f64,
    pub end_unix: f64,
    #[serde(default)]
    pub value: Option<f64>,
    #[serde(default)]
    pub unit: Option<String>,
    /// Category label (sleep stage, stand hour) or the workout activity.
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub source_bundle: Option<String>,
    #[serde(default)]
    pub source_name: Option<String>,
    #[serde(default)]
    pub device: Option<String>,
    #[serde(default)]
    pub metadata: Option<Value>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct HealthBatch {
    #[serde(default)]
    pub tz_offset_s: Option<i64>,
    #[serde(default)]
    pub samples: Vec<HealthSample>,
    /// UUIDs HealthKit reported as deleted since the last anchor.
    #[serde(default)]
    pub deleted: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct HealthOutcome {
    pub samples_seen: usize,
    pub stored: usize,
    pub deleted: usize,
    pub total: i64,
}

/// Kinds summed per day. iPhone and Watch both record these, so the day total is
/// the best single source, not the sum of all sources (HealthKit does the same).
const DAILY_KINDS: &[(&str, &str)] = &[
    ("step_count", "steps"),
    ("active_energy", "active_kcal"),
    ("exercise_time", "exercise_min"),
    ("stand_time", "stand_min"),
    ("distance_walking_running", "distance_m"),
];

fn ymd_at(unix: f64, tz_s: i64) -> String {
    let local = unix as i64 + tz_s;
    let (y, m, d) = oura_summary::civil(local.div_euclid(86400));
    format!("{y:04}-{m:02}-{d:02}")
}

fn round1(x: f64) -> f64 {
    (x * 10.0).round() / 10.0
}

fn latest<'a>(rows: &'a [HealthSample], kind: &str) -> Option<&'a HealthSample> {
    rows.iter().filter(|r| r.kind == kind).max_by(|a, b| a.end_unix.total_cmp(&b.end_unix))
}

fn latest_json(rows: &[HealthSample], kind: &str) -> Value {
    match latest(rows, kind) {
        Some(r) => json!({ "value": r.value.map(round1), "unit": r.unit, "at_unix": r.end_unix as i64, "source": r.source_name }),
        None => Value::Null,
    }
}

/// Per-day totals for one kind: the best source wins.
fn day_total(rows: &[HealthSample], kind: &str, ymd: &str, tz_s: i64) -> Option<f64> {
    let mut by_source: BTreeMap<String, f64> = BTreeMap::new();
    for r in rows.iter().filter(|r| r.kind == kind && ymd_at(r.start_unix, tz_s) == ymd) {
        *by_source.entry(r.source_bundle.clone().unwrap_or_default()).or_insert(0.0) += r.value.unwrap_or(0.0);
    }
    by_source.values().cloned().fold(None, |acc, v| Some(acc.map_or(v, |a: f64| a.max(v))))
}

fn stand_hours(rows: &[HealthSample], ymd: &str, tz_s: i64) -> Option<i64> {
    let mut by_source: BTreeMap<String, i64> = BTreeMap::new();
    for r in rows.iter().filter(|r| r.kind == "stand_hour" && ymd_at(r.start_unix, tz_s) == ymd) {
        let e = by_source.entry(r.source_bundle.clone().unwrap_or_default()).or_insert(0);
        if r.category.as_deref() == Some("stood") {
            *e += 1;
        }
    }
    by_source.values().cloned().max()
}

fn day_json(rows: &[HealthSample], ymd: &str, tz_s: i64) -> Value {
    let mut day = serde_json::Map::new();
    day.insert("ymd".into(), json!(ymd));
    for (kind, key) in DAILY_KINDS {
        day.insert((*key).into(), json!(day_total(rows, kind, ymd, tz_s).map(|v| v.round())));
    }
    day.insert("stand_hours".into(), json!(stand_hours(rows, ymd, tz_s)));
    Value::Object(day)
}

/// A gap longer than this between two sleep rows starts a new sleep session.
const SLEEP_SESSION_GAP_S: f64 = 3.0 * 3600.0;

/// Split one source's sleep rows (any order) into sessions and return the latest.
fn latest_session<'a>(mut rs: Vec<&'a HealthSample>) -> Vec<&'a HealthSample> {
    rs.sort_by(|a, b| a.start_unix.total_cmp(&b.start_unix));
    let mut sessions: Vec<Vec<&HealthSample>> = Vec::new();
    let mut session_end = f64::NEG_INFINITY;
    for r in rs {
        if sessions.is_empty() || r.start_unix - session_end > SLEEP_SESSION_GAP_S {
            sessions.push(Vec::new());
        }
        sessions.last_mut().unwrap().push(r);
        session_end = session_end.max(r.end_unix);
    }
    sessions.pop().unwrap_or_default()
}

/// The last sleep session: per source, rows in the last 48 h are split into sessions
/// (a gap over three hours starts a new one) and the latest session is kept; the
/// source whose latest session has the most asleep time wins.
fn last_sleep(rows: &[HealthSample], now_unix: i64) -> Value {
    let floor = now_unix as f64 - 48.0 * 3600.0;
    let mut by_source: BTreeMap<String, Vec<&HealthSample>> = BTreeMap::new();
    for r in rows.iter().filter(|r| r.kind == "sleep_analysis" && r.end_unix >= floor) {
        by_source.entry(r.source_bundle.clone().unwrap_or_default()).or_default().push(r);
    }
    let score = |rs: &[&HealthSample]| -> f64 {
        rs.iter()
            .filter(|r| r.category.as_deref().is_some_and(|c| c.starts_with("asleep")))
            .map(|r| r.end_unix - r.start_unix)
            .sum()
    };
    let sessions: Vec<Vec<&HealthSample>> = by_source.into_values().map(latest_session).collect();
    let Some(rs) = sessions.iter().max_by(|a, b| score(a).total_cmp(&score(b))) else {
        return Value::Null;
    };
    let rs = rs.as_slice();
    let start = rs.iter().map(|r| r.start_unix).fold(f64::INFINITY, f64::min);
    let end = rs.iter().map(|r| r.end_unix).fold(f64::NEG_INFINITY, f64::max);
    let minutes = |cat: &str| -> f64 {
        round1(rs.iter().filter(|r| r.category.as_deref() == Some(cat)).map(|r| r.end_unix - r.start_unix).sum::<f64>() / 60.0)
    };
    let asleep_min = round1(score(rs) / 60.0);
    json!({
        "source": rs[0].source_name,
        "start_unix": start as i64,
        "end_unix": end as i64,
        "in_bed_min": round1((end - start) / 60.0),
        "asleep_min": asleep_min,
        "deep_min": minutes("asleep_deep"),
        "core_min": minutes("asleep_core"),
        "rem_min": minutes("asleep_rem"),
        "awake_min": minutes("awake"),
    })
}

fn workouts(rows: &[HealthSample], now_unix: i64) -> Vec<Value> {
    let floor = now_unix as f64 - 48.0 * 3600.0;
    let mut ws: Vec<&HealthSample> = rows.iter().filter(|r| r.kind == "workout" && r.end_unix >= floor).collect();
    ws.sort_by(|a, b| b.start_unix.total_cmp(&a.start_unix));
    ws.iter()
        .map(|r| {
            let md = r.metadata.clone().unwrap_or(Value::Null);
            json!({
                "activity": r.category,
                "start_unix": r.start_unix as i64,
                "end_unix": r.end_unix as i64,
                "duration_min": r.value.map(round1),
                "kcal": md["total_energy_kcal"].as_f64().map(|x| x.round()),
                "distance_m": md["total_distance_m"].as_f64().map(|x| x.round()),
                "source": r.source_name,
            })
        })
        .collect()
}

/// The compact Apple Health picture for planning: today and yesterday totals,
/// latest vitals, the last sleep, recent workouts, and how fresh it all is.
pub fn watch_status(rows: &[HealthSample], now_unix: i64, tz_s: i64) -> Value {
    if rows.is_empty() {
        return json!({ "available": false, "note": "no Apple Health samples have been pushed" });
    }
    let today = ymd_at(now_unix as f64, tz_s);
    let yesterday = ymd_at(now_unix as f64 - 86400.0, tz_s);
    let newest = rows.iter().map(|r| r.end_unix).fold(f64::NEG_INFINITY, f64::max);
    let week = now_unix as f64 - 7.0 * 86400.0;
    let hrv: Vec<f64> = rows.iter().filter(|r| r.kind == "hrv_sdnn" && r.end_unix >= week).filter_map(|r| r.value).collect();
    let hrv_mean = (!hrv.is_empty()).then(|| round1(hrv.iter().sum::<f64>() / hrv.len() as f64));
    let mut sources: Vec<String> = rows.iter().filter_map(|r| r.source_name.clone()).collect();
    sources.sort();
    sources.dedup();
    json!({
        "available": true,
        "freshness": {
            "newest_sample_unix": newest as i64,
            "age_min": ((now_unix as f64 - newest).max(0.0) / 60.0).round(),
        },
        "sources": sources,
        "today": day_json(rows, &today, tz_s),
        "yesterday": day_json(rows, &yesterday, tz_s),
        "heart_rate_latest": latest_json(rows, "heart_rate"),
        "resting_heart_rate": latest_json(rows, "resting_heart_rate"),
        "hrv_sdnn": { "latest": latest_json(rows, "hrv_sdnn"), "mean_7d_ms": hrv_mean },
        "vo2_max": latest_json(rows, "vo2_max"),
        "respiratory_rate": latest_json(rows, "respiratory_rate"),
        "oxygen_saturation": latest_json(rows, "oxygen_saturation"),
        "wrist_temperature": latest_json(rows, "wrist_temperature"),
        "last_sleep": last_sleep(rows, now_unix),
        "workouts_48h": workouts(rows, now_unix),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(uuid: &str, kind: &str, start: f64, end: f64, value: f64, bundle: &str) -> HealthSample {
        HealthSample {
            uuid: uuid.into(), kind: kind.into(), start_unix: start, end_unix: end, value: Some(value),
            unit: Some("u".into()), category: None, source_bundle: Some(bundle.into()),
            source_name: Some(bundle.rsplit('.').next().unwrap().into()), device: None, metadata: None,
        }
    }

    // 2024-01-10 12:00 UTC
    const NOW: i64 = 1_704_888_000;
    const DAY: f64 = 86400.0;

    fn rows() -> Vec<HealthSample> {
        let t = NOW as f64;
        let mut v = vec![
            // steps today from two sources: the watch has more, so 6000 wins (not 9000)
            s("s1", "step_count", t - 3600.0, t - 3500.0, 4000.0, "com.apple.watch"),
            s("s2", "step_count", t - 1800.0, t - 1700.0, 2000.0, "com.apple.watch"),
            s("s3", "step_count", t - 3600.0, t - 3500.0, 3000.0, "com.apple.phone"),
            // yesterday
            s("s4", "step_count", t - DAY, t - DAY + 60.0, 8000.0, "com.apple.watch"),
            s("s5", "active_energy", t - DAY, t - DAY + 60.0, 350.0, "com.apple.watch"),
            s("h1", "heart_rate", t - 7200.0, t - 7200.0, 70.0, "com.apple.watch"),
            s("h2", "heart_rate", t - 600.0, t - 600.0, 64.0, "com.apple.watch"),
            s("r1", "resting_heart_rate", t - DAY, t - DAY, 52.0, "com.apple.watch"),
            s("v1", "hrv_sdnn", t - 2.0 * DAY, t - 2.0 * DAY, 40.0, "com.apple.watch"),
            s("v2", "hrv_sdnn", t - 3600.0, t - 3600.0, 60.0, "com.apple.watch"),
            s("v3", "hrv_sdnn", t - 20.0 * DAY, t - 20.0 * DAY, 999.0, "com.apple.watch"), // outside 7 d
            s("o1", "vo2_max", t - 5.0 * DAY, t - 5.0 * DAY, 44.2, "com.apple.watch"),
        ];
        // sleep: the watch has stages, the oura app only in_bed → the watch wins
        let bed = t - 12.0 * 3600.0;
        let mut sl = |uuid: &str, off: f64, len: f64, cat: &str, bundle: &str| {
            let mut r = s(uuid, "sleep_analysis", bed + off, bed + off + len, 0.0, bundle);
            r.value = None;
            r.category = Some(cat.into());
            v.push(r);
        };
        sl("z1", 0.0, 600.0, "in_bed", "com.ouraring.app");
        sl("z2", 0.0, 1800.0, "awake", "com.apple.watch");
        sl("z3", 1800.0, 3600.0, "asleep_core", "com.apple.watch");
        sl("z4", 5400.0, 1800.0, "asleep_deep", "com.apple.watch");
        sl("z5", 7200.0, 1800.0, "asleep_rem", "com.apple.watch");
        let mut w = s("w1", "workout", t - 5.0 * 3600.0, t - 4.0 * 3600.0, 60.0, "com.apple.watch");
        w.category = Some("running".into());
        w.metadata = Some(json!({ "total_energy_kcal": 512.4, "total_distance_m": 8012.0 }));
        v.push(w);
        let mut st = s("st1", "stand_hour", t - 3600.0, t, 0.0, "com.apple.watch");
        st.category = Some("stood".into());
        v.push(st);
        v
    }

    #[test]
    fn totals_take_the_best_source_per_day() {
        let w = watch_status(&rows(), NOW, 0);
        assert_eq!(w["available"], true);
        assert_eq!(w["today"]["steps"], 6000.0);
        assert_eq!(w["yesterday"]["steps"], 8000.0);
        assert_eq!(w["yesterday"]["active_kcal"], 350.0);
        assert!(w["today"]["active_kcal"].is_null());
        assert_eq!(w["today"]["stand_hours"], 1);
        assert_eq!(w["sources"], json!(["app", "phone", "watch"]));
    }

    #[test]
    fn vitals_are_the_latest_and_hrv_mean_is_seven_days() {
        let w = watch_status(&rows(), NOW, 0);
        assert_eq!(w["heart_rate_latest"]["value"], 64.0);
        assert_eq!(w["heart_rate_latest"]["at_unix"], NOW - 600);
        assert_eq!(w["resting_heart_rate"]["value"], 52.0);
        assert_eq!(w["hrv_sdnn"]["latest"]["value"], 60.0);
        assert_eq!(w["hrv_sdnn"]["mean_7d_ms"], 50.0);
        assert_eq!(w["vo2_max"]["value"], 44.2);
        assert!(w["oxygen_saturation"].is_null());
        assert_eq!(w["freshness"]["age_min"], 0.0);
    }

    #[test]
    fn sleep_picks_the_source_with_stages_and_workouts_carry_metadata() {
        let w = watch_status(&rows(), NOW, 0);
        let sl = &w["last_sleep"];
        assert_eq!(sl["source"], "watch");
        assert_eq!(sl["asleep_min"], 120.0);
        assert_eq!(sl["deep_min"], 30.0);
        assert_eq!(sl["awake_min"], 30.0);
        assert_eq!(sl["in_bed_min"], 150.0);
        let wk = &w["workouts_48h"][0];
        assert_eq!(wk["activity"], "running");
        assert_eq!(wk["kcal"], 512.0);
        assert_eq!(wk["distance_m"], 8012.0);
        assert_eq!(wk["duration_min"], 60.0);
    }

    #[test]
    fn last_sleep_is_the_latest_session_not_two_nights_added_up() {
        let t = NOW as f64;
        let mut v = Vec::new();
        let mut sl = |uuid: &str, start: f64, len: f64, cat: &str| {
            let mut r = s(uuid, "sleep_analysis", start, start + len, 0.0, "com.apple.watch");
            r.value = None;
            r.category = Some(cat.into());
            v.push(r);
        };
        // the night before: 8 h asleep, ended 30 h ago
        sl("a1", t - 38.0 * 3600.0, 8.0 * 3600.0, "asleep_core");
        // last night: 6 h asleep in two rows, ended 6 h ago
        sl("b1", t - 12.0 * 3600.0, 3.0 * 3600.0, "asleep_core");
        sl("b2", t - 9.0 * 3600.0, 3.0 * 3600.0, "asleep_rem");
        let w = watch_status(&v, NOW, 0);
        assert_eq!(w["last_sleep"]["asleep_min"], 360.0);
        assert_eq!(w["last_sleep"]["in_bed_min"], 360.0);
        assert_eq!(w["last_sleep"]["end_unix"], NOW - 6 * 3600);
    }

    #[test]
    fn empty_rows_say_so_and_tz_moves_the_day() {
        assert_eq!(watch_status(&[], NOW, 0)["available"], false);
        // at UTC+14 the "today" of NOW (12:00 UTC) is the next calendar day
        let w = watch_status(&rows(), NOW, 14 * 3600);
        assert_eq!(w["today"]["ymd"], "2024-01-11");
    }
}
