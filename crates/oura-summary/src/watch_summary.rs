use std::collections::BTreeMap;
use std::path::Path;

use anyhow::Result;
use oura_analysis::scores;
use serde_json::{json, Value};

use crate::external::{read_external, ExternalSleep, ExternalSleepStage, ExternalWorkout, SleepStage};
use crate::extras::{self, Workout};
use crate::{now_unix_s, read_profile, score_json, sleep_balance, sleep_debt_summary, sleep_metrics, trailing_baseline};

pub const EPOCH_S: i64 = 30;
const SAME_NIGHT_GAP_S: i64 = 3600;
const MIN_ASLEEP_S: i64 = 3600;

#[derive(Debug, Clone, PartialEq)]
pub struct WatchNight {
    pub start_unix: i64,
    pub end_unix: i64,
    pub stages: Vec<i64>,
    pub min_hr: Option<f64>,
    pub mean_hrv_sdnn_ms: Option<f64>,
}

pub fn nights(sleep: &ExternalSleep) -> Vec<WatchNight> {
    let mut stages: Vec<_> = sleep.stages.iter().filter(|s| s.end_unix > s.start_unix).collect();
    stages.sort_by_key(|s| s.start_unix);

    let mut sessions: Vec<(i64, Vec<&ExternalSleepStage>)> = Vec::new();
    for stage in stages {
        match sessions.last_mut() {
            Some((end, session)) if stage.start_unix - *end <= SAME_NIGHT_GAP_S => {
                *end = (*end).max(stage.end_unix);
                session.push(stage);
            }
            _ => sessions.push((stage.end_unix, vec![stage])),
        }
    }

    sessions
        .into_iter()
        .filter_map(|(_, session)| {
            let start_unix = session.iter().map(|s| s.start_unix).min()?;
            let end_unix = session.iter().map(|s| s.end_unix).max()?;
            let awake = SleepStage::Awake.code();
            let mut codes = vec![awake; ((end_unix - start_unix + EPOCH_S - 1) / EPOCH_S) as usize];
            for s in &session {
                let first = ((s.start_unix - start_unix) / EPOCH_S) as usize;
                let last = (((s.end_unix - start_unix + EPOCH_S - 1) / EPOCH_S) as usize).min(codes.len());
                for code in &mut codes[first..last] {
                    if *code == awake {
                        *code = s.stage.code();
                    }
                }
            }
            let asleep_s = codes.iter().filter(|&&c| c != awake).count() as i64 * EPOCH_S;
            if asleep_s < MIN_ASLEEP_S {
                return None;
            }
            let during = |samples: &[(i64, f64)]| -> Vec<f64> {
                samples
                    .iter()
                    .filter(|(t, _)| (start_unix..=end_unix).contains(t))
                    .map(|&(_, v)| v)
                    .collect()
            };
            let hr = during(&sleep.hr);
            let hrv = during(&sleep.hrv_sdnn);
            Some(WatchNight {
                start_unix,
                end_unix,
                stages: codes,
                min_hr: hr.iter().cloned().reduce(f64::min),
                mean_hrv_sdnn_ms: (!hrv.is_empty()).then(|| hrv.iter().sum::<f64>() / hrv.len() as f64),
            })
        })
        .collect()
}

struct ScoredNight<'a> {
    night: &'a WatchNight,
    wake_day: i64,
    asleep_s: i32,
    sleep: Option<scores::Score>,
    rhr_baseline: Option<scores::Stats>,
    hrv_baseline: Option<scores::Stats>,
}

impl ScoredNight<'_> {
    fn in_bed_s(&self) -> i64 {
        self.night.end_unix - self.night.start_unix
    }

    fn stage_min(&self, code: i64) -> f64 {
        (self.night.stages.iter().filter(|&&c| c == code).count() as f64 * EPOCH_S as f64 / 60.0).round()
    }

    fn to_json(&self) -> Value {
        json!({
            "ymd": extras::ymd(self.wake_day),
            "start_unix": self.night.start_unix,
            "end_unix": self.night.end_unix,
            "in_bed_min": (self.in_bed_s() as f64 / 60.0).round(),
            "asleep_min": (self.asleep_s as f64 / 60.0).round(),
            "deep_min": self.stage_min(SleepStage::Deep.code()),
            "core_min": self.stage_min(SleepStage::Core.code()),
            "rem_min": self.stage_min(SleepStage::Rem.code()),
            "awake_min": self.stage_min(SleepStage::Awake.code()),
            "min_hr": self.night.min_hr,
            "hrv_sdnn_ms": self.night.mean_hrv_sdnn_ms.map(|x| (x * 10.0).round() / 10.0),
            "sleep_score": self.sleep.as_ref().map(|s| s.score),
        })
    }
}

fn score_nights(nights: &[WatchNight], tz: i64, age: f64) -> Vec<ScoredNight<'_>> {
    let wake_day = |n: &WatchNight| extras::local_day(n.end_unix as f64, tz);
    let main = extras::main_sleeps(
        &nights.iter().map(|n| (wake_day(n), (n.end_unix - n.start_unix) as f64 / 60.0)).collect::<Vec<_>>(),
    );
    let main_nights = || nights.iter().zip(&main).filter(|(_, &m)| m).map(|(n, _)| n);
    let rhr: Vec<Option<f64>> = main_nights().map(|n| n.min_hr).collect();
    let hrv: Vec<Option<f64>> = main_nights().map(|n| n.mean_hrv_sdnn_ms).collect();
    let mut mains_before = 0;
    nights
        .iter()
        .enumerate()
        .map(|(i, night)| {
            let in_bed_s = (night.end_unix - night.start_unix) as f64;
            let (metrics, asleep_s) = sleep_metrics(&night.stages, in_bed_s);
            let share = |code: i64| {
                let n = night.stages.iter().filter(|&&c| c == code).count();
                (n as f64 / night.stages.len() as f64 * 1000.0).round() / 10.0
            };
            let rhr_baseline = trailing_baseline(&rhr, mains_before);
            let hrv_baseline = trailing_baseline(&hrv, mains_before);
            mains_before += main[i] as usize;
            let sleep = scores::sleep::score_night(scores::sleep::NightInput {
                asleep_min: Some(asleep_s as f64 / 60.0),
                in_bed_min: None,
                efficiency_pct: None,
                onset_latency_min: None,
                waso_min: metrics["waso_min"].as_f64(),
                awakenings: metrics["awakenings"].as_f64(),
                deep_pct: Some(share(SleepStage::Deep.code())),
                rem_pct: Some(share(SleepStage::Rem.code())),
                rhr: night.min_hr,
                rhr_baseline,
                hrv_ms: night.mean_hrv_sdnn_ms,
                hrv_baseline,
                age,
            });
            ScoredNight {
                night,
                wake_day: wake_day(night),
                asleep_s,
                sleep,
                rhr_baseline,
                hrv_baseline,
            }
        })
        .collect()
}

fn health_workouts(workouts: &[ExternalWorkout]) -> Vec<Workout> {
    let mut out: Vec<Workout> = workouts
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
    out.sort_by(|a, b| b.start_unix.total_cmp(&a.start_unix));
    out
}

/// The watch summary JSON. Without Apple Watch data, it has no nights, scores, workouts
/// or VO2 max, so a reader that keeps the last summary shows that the data stopped.
/// `tz` is hours from UTC. The only other input is the age in
/// `profile.json`, which the sleep score needs.
pub fn build_watch_summary(db: &Path, tz: i64) -> Result<Value> {
    build(db, tz, now_unix_s())
}

fn build(db: &Path, tz: i64, now_unix_s: f64) -> Result<Value> {
    let external = read_external(db)?;
    let watch_nights = nights(&external.sleep);
    let workouts = health_workouts(&external.workouts);
    let fitness = external.vo2max.filter(|m| m.value > 0.0).map(|m| {
        json!({
            "vo2max": (m.value * 10.0).round() / 10.0,
            "date": extras::ymd(extras::local_day(m.at_unix as f64, tz)),
            "source_name": m.source,
        })
    });
    let scored = score_nights(&watch_nights, tz, read_profile(db).age);

    let mut asleep_by_day: BTreeMap<i64, i32> = BTreeMap::new();
    for n in &scored {
        *asleep_by_day.entry(n.wake_day).or_default() += n.asleep_s;
    }
    let longest_by_day: BTreeMap<i64, &ScoredNight> =
        extras::longest_per_wake_day(scored.iter().map(|n| (n.wake_day, n.in_bed_s() as f64)))
            .into_iter()
            .map(|(day, i)| (day, &scored[i]))
            .collect();

    let days: serde_json::Map<String, Value> = longest_by_day
        .iter()
        .map(|(&day, n)| {
            let (sleep_balance_ratio, sleep_balance_days) = sleep_balance(&asleep_by_day, day);
            let readiness = scores::readiness::score(scores::readiness::Input {
                sleep_score: n.sleep.as_ref().map(|s| s.score),
                rhr: n.night.min_hr,
                rhr_baseline: n.rhr_baseline,
                hrv_ms: n.night.mean_hrv_sdnn_ms,
                hrv_baseline: n.hrv_baseline,
                sleep_balance_ratio,
                sleep_balance_days,
                ..Default::default()
            });
            (
                extras::ymd(day),
                json!({ "sleep": score_json(&n.sleep), "readiness": score_json(&readiness) }),
            )
        })
        .collect();

    Ok(json!({
        "kind": "watch",
        "generated_at": now_unix_s as i64,
        "tz": tz,
        "nights": scored.iter().rev().map(ScoredNight::to_json).collect::<Vec<_>>(),
        "scores": {
            "latest": longest_by_day.keys().next_back().map(|&d| extras::ymd(d)),
            "days": days,
        },
        "sleep_debt": sleep_debt_summary(&asleep_by_day),
        "fitness": fitness,
        "workouts": extras::workouts_json(&workouts, tz),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::external::SleepStage;

    fn stage(start: i64, end: i64, stage: SleepStage) -> ExternalSleepStage {
        ExternalSleepStage { start_unix: start, end_unix: end, stage }
    }

    #[test]
    fn groups_stages_into_nights_with_their_vitals() {
        let h = 3600;
        let sleep = ExternalSleep {
            stages: vec![
                stage(2 * h, 5 * h, SleepStage::Core),
                stage(0, h, SleepStage::Deep),
                stage(h + 1800, 2 * h, SleepStage::Rem),
                stage(12 * h, 12 * h + 1200, SleepStage::Core),
                stage(24 * h, 31 * h, SleepStage::Core),
                stage(26 * h, 26 * h + 600, SleepStage::Awake),
            ],
            hr: vec![(600, 52.0), (4 * h, 48.0), (20 * h, 40.0), (25 * h, 55.0)],
            hrv_sdnn: vec![(h, 40.0), (3 * h, 60.0)],
        };
        let n = nights(&sleep);
        assert_eq!(n.len(), 2);

        let one = &n[0];
        assert_eq!((one.start_unix, one.end_unix), (0, 5 * h));
        assert_eq!(one.stages.len(), 600);
        assert_eq!(one.stages.iter().filter(|&&c| c == 4).count(), 60, "the 30 min gap is awake");
        assert_eq!(one.stages[0], 1);
        assert_eq!(one.stages[599], 2);
        assert_eq!(one.min_hr, Some(48.0), "the 40 bpm sample is outside every night");
        assert_eq!(one.mean_hrv_sdnn_ms, Some(50.0));

        let two = &n[1];
        assert_eq!(two.stages.iter().filter(|&&c| c == 2).count(), 840, "a sleep stage wins over an overlapping awake one");
        assert_eq!(two.min_hr, Some(55.0));
        assert_eq!(two.mean_hrv_sdnn_ms, None);
    }

    #[test]
    fn naps_stay_out_of_the_resting_hr_baseline() {
        let h = 3600;
        let mut sleep = ExternalSleep::default();
        for (day, hr) in [(0, 50.0), (1, 52.0), (2, 54.0), (4, 50.0), (5, 50.0)] {
            let bed = day * 24 * h - h;
            sleep.stages.push(stage(bed, bed + 8 * h, SleepStage::Core));
            sleep.hr.push((bed + 4 * h, hr));
        }
        let nap_after_a_night = 2 * 24 * h + 14 * h;
        let nap_without_a_night = 3 * 24 * h + 14 * h;
        for nap in [nap_after_a_night, nap_without_a_night] {
            sleep.stages.push(stage(nap, nap + 90 * 60, SleepStage::Core));
            sleep.hr.push((nap + 1800, 90.0));
        }

        let n = nights(&sleep);
        let scored = score_nights(&n, 0, 35.0);
        assert_eq!(scored.len(), 7);
        let baseline = |i: usize| scored[i].rhr_baseline.map(|b| b.mean);
        assert_eq!(baseline(5), Some(52.0), "neither 90 bpm nap is in the baseline of the night after them");
        assert_eq!(baseline(6), Some(51.5), "the baseline after that has the four nights only");
    }
}
