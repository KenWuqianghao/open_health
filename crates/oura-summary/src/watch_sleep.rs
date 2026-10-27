use crate::external::{ExternalSleep, ExternalSleepStage, SleepStage};

pub const EPOCH_S: i64 = 30;
const SAME_NIGHT_GAP_S: i64 = 3600;
const MIN_ASLEEP_S: i64 = 3600;
const RING_COVER_SHARE: f64 = 0.5;

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

pub fn ring_recorded(night: &WatchNight, ring_nights: impl IntoIterator<Item = (f64, f64)>) -> bool {
    let (start, end) = (night.start_unix as f64, night.end_unix as f64);
    ring_nights
        .into_iter()
        .any(|(a, b)| b.min(end) - a.max(start) >= RING_COVER_SHARE * (end - start))
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

        let ring = |a: i64, b: i64| [(a as f64, b as f64)];
        assert!(ring_recorded(one, ring(-h, 4 * h)), "a ring night that covers most of it");
        assert!(!ring_recorded(one, ring(4 * h, 5 * h)), "a one-hour ring fragment");
        assert!(!ring_recorded(one, ring(12 * h, 13 * h)), "a ring nap at another time");

        let two = &n[1];
        assert_eq!(two.stages.iter().filter(|&&c| c == 2).count(), 840, "a sleep stage wins over an overlapping awake one");
        assert_eq!(two.min_hr, Some(55.0));
        assert_eq!(two.mean_hrv_sdnn_ms, None);
    }
}
