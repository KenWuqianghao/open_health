//! The agent-facing view of a summary.
//!
//! An LLM planner does not need the full dashboard JSON. It needs a short status
//! document with the last night, the sleep debt, the vitals against their
//! baselines, the illness flag, the activity so far, and how fresh all of that is.
//! Every function here is pure over the `build_summary` JSON, so the hub and the
//! iOS app compute the same document.

use serde_json::{json, Map, Value};

use crate::civil;

/// Metrics that [`trends`] can extract, with their unit.
pub const TREND_METRICS: &[(&str, &str)] = &[
    ("hrv_ms", "ms"),
    ("rhr", "bpm"),
    ("skin_temp", "deg_c"),
    ("efficiency", "pct"),
    ("in_bed_h", "h"),
    ("asleep_min", "min"),
    ("deep_pct", "pct"),
    ("rem_pct", "pct"),
    ("light_pct", "pct"),
    ("wake_pct", "pct"),
    ("awakenings", "count"),
    ("waso_min", "min"),
    ("sol_min", "min"),
    ("steps", "count"),
    ("active_kcal", "kcal"),
    ("total_kcal", "kcal"),
];

fn ymd_at(unix: i64, tz: i64) -> String {
    let local = unix + tz * 3600;
    let (y, m, d) = civil(local.div_euclid(86400));
    format!("{y:04}-{m:02}-{d:02}")
}

fn num(v: &Value) -> Option<f64> {
    v.as_f64()
}

/// Nights sorted by `ymd` ascending. The summary does not promise an order.
fn nights_sorted(summary: &Value) -> Vec<&Value> {
    let mut nights: Vec<&Value> = summary["nights"].as_array().map(|a| a.iter().collect()).unwrap_or_default();
    nights.sort_by(|a, b| a["ymd"].as_str().unwrap_or("").cmp(b["ymd"].as_str().unwrap_or("")));
    nights
}

/// One night without the per-epoch series and stage cells.
fn night_compact(n: &Value) -> Value {
    let m = &n["metrics"];
    json!({
        "ymd": n["ymd"],
        "start": n["start"],
        "end": n["end"],
        "in_bed_h": n["in_bed_h"],
        "asleep_min": m["asleep_min"],
        "efficiency_pct": n["efficiency"],
        "deep_pct": n["deep_pct"],
        "rem_pct": n["rem_pct"],
        "light_pct": n["light_pct"],
        "wake_pct": n["wake_pct"],
        "hrv_ms": n["hrv_ms"],
        "rhr": n["rhr"],
        "skin_temp_c": n["skin_temp"],
        "sleep_onset_min": m["sol_min"],
        "waso_min": m["waso_min"],
        "awakenings": m["awakenings"],
        "cycles": m["cycles"],
    })
}

fn night_metric(n: &Value, metric: &str) -> Option<f64> {
    match metric {
        "asleep_min" | "awakenings" | "waso_min" | "sol_min" => num(&n["metrics"][metric]),
        _ => num(&n[metric]),
    }
}

fn activity_day(summary: &Value, ymd: &str) -> Option<Value> {
    let d = summary["activity_daily"].get(ymd)?;
    Some(json!({
        "ymd": ymd,
        "steps": d["steps"],
        "active_kcal": d["active_kcal"],
        "total_kcal": d["total_kcal"],
        "distance_m": d["distance_m"],
    }))
}

/// The status document for "what should I do today".
///
/// `now_unix` is the caller's clock. The ring data is as fresh as the last sync,
/// and the summary is as fresh as its `generated_at`, so both ages are reported.
pub fn status_now(summary: &Value, now_unix: i64) -> Value {
    let tz = summary["tz"].as_i64().unwrap_or(0);
    let generated_at = num(&summary["generated_at"]).map(|g| g as i64);
    let summary_age_min = generated_at.map(|g| ((now_unix - g).max(0) as f64 / 60.0).round());
    let ring_age_h = num(&summary["device"]["fresh_hours"])
        .zip(summary_age_min)
        .map(|(f, a)| ((f + a / 60.0) * 10.0).round() / 10.0);

    let nights = nights_sorted(summary);
    let last_night = nights.last().map(|n| night_compact(n));

    let today = ymd_at(now_unix, tz);
    let yesterday = ymd_at(now_unix - 86400, tz);

    let sd = &summary["sleep_debt"];
    let illness = summary["illness"].as_object().map(|i| {
        json!({
            "available": i.get("available").cloned().unwrap_or(Value::Bool(false)),
            "status": i.get("status").cloned().unwrap_or(Value::Null),
            "traffic_light": i.get("traffic_light").cloned().unwrap_or(Value::Null),
            "risk_level": i.get("risk_level").cloned().unwrap_or(Value::Null),
            "date": i.get("date").cloned().unwrap_or(Value::Null),
        })
    });
    let cardio = summary["cardio"].as_object().map(|c| {
        json!({
            "vascular_age": c.get("vascular_age").cloned().unwrap_or(Value::Null),
            "chronological_age": c.get("chronological_age").cloned().unwrap_or(Value::Null),
            "quality": c.get("quality").cloned().unwrap_or(Value::Null),
        })
    });
    let vitals = &summary["vitals"];
    let vital = |k: &str| {
        json!({
            "latest": vitals[k]["latest"],
            "baseline": vitals[k]["baseline"],
            "delta_pct": vitals[k]["delta_pct"],
        })
    };
    let hr = &vitals["hr"];

    json!({
        "as_of": { "unix": now_unix, "ymd": today, "tz_hours": tz },
        "freshness": {
            "summary_generated_at": generated_at,
            "summary_age_min": summary_age_min,
            "ring_last_sync_age_h": ring_age_h,
            "note": "Ring data arrives at sync time, not live. Treat values older than 12 h as stale.",
        },
        "last_night": last_night,
        "sleep_debt": {
            "state": sd["state"],
            "debt_min": sd["debt_min"],
            "recent_shortfall_min": sd["recent_shortfall_min"],
            "need_h": sd["need_h"],
            "valid": sd["valid"],
        },
        "vitals": {
            "hrv_ms": vital("hrv"),
            "rhr_bpm": vital("rhr"),
            "hr_latest": if hr.is_null() { Value::Null } else { json!({ "bpm": hr["latest"], "at_unix": hr["at_unix"] }) },
        },
        "illness": illness,
        "cardio": cardio,
        "fitness": summary["fitness"],
        "activity": {
            "today": activity_day(summary, &today),
            "yesterday": activity_day(summary, &yesterday),
        },
        "device": {
            "battery_pct": summary["device"]["battery_pct"],
            "nights_of_data": summary["device"]["nights"],
        },
    })
}

/// The last `days` nights, newest first, without series.
pub fn sleep_nights(summary: &Value, days: usize) -> Value {
    let nights = nights_sorted(summary);
    let take = days.max(1);
    let out: Vec<Value> = nights.iter().rev().take(take).map(|n| night_compact(n)).collect();
    json!({ "count": out.len(), "nights": out })
}

/// One metric over the last `days` days, oldest first.
pub fn trends(summary: &Value, metric: &str, days: usize) -> Result<Value, String> {
    let Some((_, unit)) = TREND_METRICS.iter().find(|(m, _)| *m == metric) else {
        let names: Vec<&str> = TREND_METRICS.iter().map(|(m, _)| *m).collect();
        return Err(format!("unknown metric {metric:?}; use one of {}", names.join(", ")));
    };
    let take = days.max(1);
    let mut points: Vec<Value> = Vec::new();
    if matches!(metric, "steps" | "active_kcal" | "total_kcal") {
        let empty = Map::new();
        let daily = summary["activity_daily"].as_object().unwrap_or(&empty);
        let mut keys: Vec<&String> = daily.keys().collect();
        keys.sort();
        for k in keys.iter().rev().take(take).rev() {
            if let Some(v) = num(&daily[*k][metric]) {
                points.push(json!({ "ymd": k, "value": v }));
            }
        }
    } else {
        let nights = nights_sorted(summary);
        for n in nights.iter().rev().take(take).rev() {
            if let Some(v) = night_metric(n, metric) {
                points.push(json!({ "ymd": n["ymd"], "value": v }));
            }
        }
    }
    let values: Vec<f64> = points.iter().filter_map(|p| num(&p["value"])).collect();
    let mean = (!values.is_empty()).then(|| {
        let m = values.iter().sum::<f64>() / values.len() as f64;
        (m * 10.0).round() / 10.0
    });
    let baseline = match metric {
        "hrv_ms" => summary["vitals"]["hrv"]["baseline"].clone(),
        "rhr" => summary["vitals"]["rhr"]["baseline"].clone(),
        _ => Value::Null,
    };
    Ok(json!({
        "metric": metric,
        "unit": unit,
        "days_requested": take,
        "points": points,
        "latest": values.last(),
        "mean": mean,
        "baseline": baseline,
    }))
}

/// The last `days` activity days, newest first.
pub fn activity_days(summary: &Value, days: usize) -> Value {
    let empty = Map::new();
    let daily = summary["activity_daily"].as_object().unwrap_or(&empty);
    let mut keys: Vec<&String> = daily.keys().collect();
    keys.sort();
    let out: Vec<Value> = keys
        .iter()
        .rev()
        .take(days.max(1))
        .filter_map(|k| activity_day(summary, k))
        .collect();
    json!({ "count": out.len(), "days": out })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Value {
        json!({
            "generated_at": 1_700_000_000.0,
            "tz": 8,
            "device": { "fresh_hours": 2.0, "battery_pct": 61, "nights": 2 },
            "nights": [
                { "ymd": "2023-11-14", "start": "23:10", "end": "07:05", "in_bed_h": 7.9,
                  "efficiency": 91.0, "deep_pct": 18.0, "rem_pct": 22.0, "light_pct": 52.0, "wake_pct": 8.0,
                  "hrv_ms": 48.0, "rhr": 52.0, "skin_temp": 0.1,
                  "metrics": { "asleep_min": 430.0, "sol_min": 9.0, "waso_min": 30.0, "awakenings": 3, "cycles": 4 },
                  "series": { "hr": [1, 2, 3] }, "stages": [[0, 1]] },
                { "ymd": "2023-11-13", "start": "00:30", "end": "06:40", "in_bed_h": 6.2,
                  "efficiency": 85.0, "deep_pct": 15.0, "rem_pct": 20.0, "light_pct": 55.0, "wake_pct": 10.0,
                  "hrv_ms": 40.0, "rhr": 55.0, "skin_temp": -0.2,
                  "metrics": { "asleep_min": 316.0, "sol_min": 12.0, "waso_min": 40.0, "awakenings": 5, "cycles": 3 } }
            ],
            "sleep_debt": { "state": "low", "debt_min": 200.0, "recent_shortfall_min": 60.0, "need_h": 7.5, "valid": true },
            "vitals": {
                "hrv": { "series": [40.0, 48.0], "latest": 48.0, "baseline": 44.0, "delta_pct": 9.0 },
                "rhr": { "series": [55.0, 52.0], "latest": 52.0, "baseline": 53.5, "delta_pct": -3.0 },
                "hr": { "latest": 71.0, "at_unix": 1_699_999_000 }
            },
            "illness": { "available": true, "status": "NO_SIGNS", "traffic_light": "green", "risk_level": "low", "date": "2023-11-14", "biomarkers": [] },
            "cardio": { "vascular_age": 27.5, "chronological_age": 30, "quality": 88.0, "pwv_ms": 6.1 },
            "fitness": { "vo2max": 45.2 },
            "activity_daily": {
                "2023-11-13": { "steps": 8200.0, "active_kcal": 410.0, "total_kcal": 2100.0, "distance_m": 6248.0 },
                "2023-11-14": { "steps": 3100.0, "active_kcal": 150.0, "total_kcal": 1840.0, "distance_m": 2362.0 },
                "2023-11-15": { "steps": 900.0, "active_kcal": 40.0, "total_kcal": 1730.0, "distance_m": 685.0 }
            }
        })
    }

    #[test]
    fn status_picks_the_latest_night_and_todays_activity() {
        // 2023-11-15 02:00 UTC → 10:00 local at UTC+8
        let now = 1_700_013_600;
        let s = status_now(&fixture(), now);
        assert_eq!(s["as_of"]["ymd"], "2023-11-15");
        assert_eq!(s["last_night"]["ymd"], "2023-11-14");
        assert_eq!(s["last_night"]["asleep_min"], 430.0);
        assert!(s["last_night"].get("series").is_none());
        assert_eq!(s["activity"]["today"]["steps"], 900.0);
        assert_eq!(s["activity"]["yesterday"]["steps"], 3100.0);
        assert_eq!(s["sleep_debt"]["state"], "low");
        assert_eq!(s["vitals"]["hrv_ms"]["delta_pct"], 9.0);
        assert_eq!(s["illness"]["status"], "NO_SIGNS");
        assert!(s["illness"].get("biomarkers").is_none());
        assert_eq!(s["cardio"]["vascular_age"], 27.5);
        assert_eq!(s["device"]["battery_pct"], 61);
    }

    #[test]
    fn freshness_adds_the_summary_age_to_the_ring_age() {
        let now = 1_700_000_000 + 3 * 3600; // summary is 3 h old, ring was 2 h old then
        let s = status_now(&fixture(), now);
        assert_eq!(s["freshness"]["summary_age_min"], 180.0);
        assert_eq!(s["freshness"]["ring_last_sync_age_h"], 5.0);
    }

    #[test]
    fn status_survives_a_model_free_summary() {
        let s = status_now(&json!({ "tz": 0, "nights": [] }), 0);
        assert!(s["last_night"].is_null());
        assert!(s["illness"].is_null());
        assert!(s["cardio"].is_null());
        assert!(s["activity"]["today"].is_null());
    }

    #[test]
    fn sleep_nights_is_newest_first_and_capped() {
        let s = sleep_nights(&fixture(), 1);
        assert_eq!(s["count"], 1);
        assert_eq!(s["nights"][0]["ymd"], "2023-11-14");
        let all = sleep_nights(&fixture(), 30);
        assert_eq!(all["count"], 2);
        assert_eq!(all["nights"][1]["ymd"], "2023-11-13");
    }

    #[test]
    fn trends_reads_night_metrics_and_activity_days() {
        let t = trends(&fixture(), "hrv_ms", 7).unwrap();
        assert_eq!(t["unit"], "ms");
        assert_eq!(t["points"][0]["ymd"], "2023-11-13");
        assert_eq!(t["latest"], 48.0);
        assert_eq!(t["mean"], 44.0);
        assert_eq!(t["baseline"], 44.0);

        let w = trends(&fixture(), "waso_min", 7).unwrap();
        assert_eq!(w["points"][1]["value"], 30.0);

        let a = trends(&fixture(), "steps", 2).unwrap();
        assert_eq!(a["points"].as_array().unwrap().len(), 2);
        assert_eq!(a["points"][0]["ymd"], "2023-11-14");
        assert_eq!(a["latest"], 900.0);

        assert!(trends(&fixture(), "mood", 7).is_err());
    }

    #[test]
    fn activity_days_is_newest_first() {
        let a = activity_days(&fixture(), 2);
        assert_eq!(a["count"], 2);
        assert_eq!(a["days"][0]["ymd"], "2023-11-15");
        assert_eq!(a["days"][1]["total_kcal"], 1840.0);
    }
}
