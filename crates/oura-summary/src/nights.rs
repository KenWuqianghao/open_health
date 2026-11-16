//! The per-night model shared by `build_summary` and `health_export`: turn the
//! ring's raw `bedtime_period` markers plus the sleep-only sensor streams into
//! normalized sleep windows, and locate the night a timestamp belongs to.
//!
//! Keeping this in one place means the summary JSON and the Apple Health export
//! agree on every night boundary by construction.

use serde_json::Value;

use crate::{normalize_bed_periods, BedPeriod};

/// One decoded event row as `Store::decoded_events` returns it:
/// `(ring_timestamp_ds, tag, decoded_json, captured_unix)`.
pub(crate) type EventRow = (i64, u8, String, i64);

pub(crate) const RING_STAGE_EPOCH_DS: i64 = 30 * 10;
const MAX_BEDTIME_TO_PAGE_0_DS: i64 = 60 * 10;

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct RingRun {
    pub start_ds: i64,
    pub end_ds: i64,
    pub codes: Vec<i64>,
}

fn stage_code(phase: &str) -> i64 {
    match phase {
        "deep" => 1,
        "light" => 2,
        "rem" => 3,
        _ => 4,
    }
}

/// Each time the ring analyses a sleep it writes, in one burst, a `bedtime_period`,
/// the `sleep_phase_data` pages numbered from 0 (52 epochs each, from the bedtime
/// start) and then a `sleep_summary_2` with the REM, light and deep epoch counts.
/// The pages are padded with zero bytes, and a zero epoch decodes as deep. On short
/// runs the ring stops analysing before the bedtime end, and `sleep_summary_2` does
/// not count that padding. Its layout is confirmed only where its REM and light
/// counts equal the pages' counts (279 of 279 Gen3 runs).
pub(crate) fn ring_runs(events: &[EventRow]) -> Vec<RingRun> {
    let mut runs = Vec::new();
    let mut open: Option<(RingRun, Option<[usize; 3]>)> = None;
    let mut last_bedtime: Option<(i64, i64, i64)> = None;
    let mut previous_page = -1i64;
    let close = |open: Option<(RingRun, Option<[usize; 3]>)>, runs: &mut Vec<RingRun>| {
        let Some((mut run, counts)) = open else {
            return;
        };
        let cells = (run.end_ds - run.start_ds + RING_STAGE_EPOCH_DS - 1) / RING_STAGE_EPOCH_DS;
        run.codes.truncate(cells.max(0) as usize);
        let count = |code: i64| run.codes.iter().filter(|&&c| c == code).count();
        if let Some([rem, light, deep]) = counts {
            let padding = count(1).saturating_sub(deep);
            let trailing_deep = run.codes.iter().rev().take_while(|&&c| c == 1).count();
            if rem == count(3) && light == count(2) && padding <= trailing_deep {
                run.codes.truncate(run.codes.len() - padding);
            }
        }
        runs.push(run);
    };
    for (ds, tag, jstr, _) in events {
        let name = oura_protocol::events::event_name(*tag);
        if !matches!(
            name,
            "bedtime_period" | "sleep_phase_data" | "sleep_summary_2"
        ) {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(jstr) else {
            continue;
        };
        match name {
            "bedtime_period" => {
                if let (Some(start), Some(end)) =
                    (v["bedtime_start_ds"].as_i64(), v["bedtime_end_ds"].as_i64())
                {
                    last_bedtime = Some((*ds, start, end));
                }
            }
            "sleep_summary_2" => {
                let count = |key: &str| v[key].as_u64().map(|n| n as usize);
                if let (Some((_, counts)), Some(rem), Some(light), Some(deep)) = (
                    open.as_mut(),
                    count("rem_epochs"),
                    count("light_epochs"),
                    count("deep_epochs"),
                ) {
                    *counts = Some([rem, light, deep]);
                }
                close(open.take(), &mut runs);
            }
            _ => {
                let (Some(page), Some(phases)) = (v["header"].as_i64(), v["phases"].as_array())
                else {
                    continue;
                };
                let codes = phases.iter().filter_map(|p| p.as_str().map(stage_code));
                if page == previous_page + 1 && page > 0 {
                    if let Some((run, _)) = open.as_mut() {
                        run.codes.extend(codes);
                    }
                } else {
                    close(open.take(), &mut runs);
                    open = last_bedtime
                        .filter(|(emitted, _, _)| {
                            page == 0 && (0..=MAX_BEDTIME_TO_PAGE_0_DS).contains(&(*ds - emitted))
                        })
                        .map(|(_, start_ds, end_ds)| {
                            (
                                RingRun {
                                    start_ds,
                                    end_ds,
                                    codes: codes.collect(),
                                },
                                None,
                            )
                        });
                }
                previous_page = page;
            }
        }
    }
    close(open.take(), &mut runs);
    runs
}

pub(crate) fn collect_bed_periods(
    events: &[EventRow],
    unix_s_at: impl Fn(i64, i64) -> f64 + Copy,
) -> (Vec<BedPeriod>, Vec<RingRun>) {
    let ring_runs = ring_runs(events);
    let mut raw_beds: Vec<BedPeriod> = Vec::new();
    let mut sleep_support: Vec<(i64, i64)> = Vec::new();
    let mut pulse_support: Vec<(i64, i64, usize)> = Vec::new();
    for (ds, tag, jstr, cu) in events {
        let n = oura_protocol::events::event_name(*tag);
        if n == "bedtime_period" {
            if let Ok(v) = serde_json::from_str::<Value>(jstr) {
                if let (Some(s), Some(e)) =
                    (v["bedtime_start_ds"].as_i64(), v["bedtime_end_ds"].as_i64())
                {
                    match raw_beds.iter_mut().find(|bed| {
                        bed.start_ds == s
                            && (unix_s_at(bed.start_ds, bed.captured_unix) - unix_s_at(s, *cu))
                                .abs()
                                <= 5.0 * 60.0
                    }) {
                        Some(bed) => {
                            bed.end_ds = bed.end_ds.max(e);
                            bed.raw_end_ds = bed.raw_end_ds.max(e);
                            bed.captured_unix = bed.captured_unix.max(*cu);
                        }
                        None => raw_beds.push(BedPeriod {
                            start_ds: s,
                            end_ds: e,
                            raw_start_ds: s,
                            raw_end_ds: e,
                            captured_unix: *cu,
                            ring_ended_awake: false,
                        }),
                    }
                }
            }
        }
        if matches!(
            n,
            "sleep_acm_period" | "sleep_temp_event" | "spo2_r_pi_event"
        ) {
            sleep_support.push((*ds, *cu));
        }
        // `hr_bpm` is populated only when the firmware accepted a pulse estimate,
        // so it is a stronger continuation signal than raw/invalid IBI values.
        if matches!(n, "ibi_and_amplitude_event" | "green_ibi_quality_event") {
            if let Ok(v) = serde_json::from_str::<Value>(jstr) {
                if let Some(accepted) = v["hr_bpm"].as_array().map(Vec::len).filter(|&n| n > 0) {
                    pulse_support.push((*ds, *cu, accepted));
                }
            }
        }
    }
    for bed in &mut raw_beds {
        bed.ring_ended_awake = ring_runs
            .iter()
            .rev()
            .find(|run| run.start_ds == bed.start_ds && run.end_ds == bed.raw_end_ds)
            .and_then(|run| run.codes.last())
            == Some(&4);
    }
    (
        normalize_bed_periods(raw_beds, &sleep_support, &pulse_support, unix_s_at),
        ring_runs,
    )
}

/// Slack (deciseconds) around a night window when assigning a sample to it.
pub(crate) const NIGHT_SLACK_DS: i64 = 600;

/// Index of the night a sample at `ds` (captured at `captured_unix`) belongs to:
/// the window containing it (± one minute), nearest in capture time when the
/// ring clock restarted and two nights share raw timestamps.
pub(crate) fn find_night(beds: &[BedPeriod], ds: i64, captured_unix: i64) -> Option<usize> {
    beds.iter()
        .enumerate()
        .filter(|(_, b)| b.start_ds - NIGHT_SLACK_DS <= ds && ds <= b.end_ds + NIGHT_SLACK_DS)
        .min_by_key(|(_, b)| (b.captured_unix - captured_unix).abs())
        .map(|(idx, _)| idx)
}
