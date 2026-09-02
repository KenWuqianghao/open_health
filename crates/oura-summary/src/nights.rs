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

/// Collect and normalize the sleep windows from `events` (capture order).
pub(crate) fn collect_bed_periods(
    events: &[EventRow],
    unix_s_at: impl Fn(i64, i64) -> f64 + Copy,
) -> Vec<BedPeriod> {
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
    normalize_bed_periods(raw_beds, &sleep_support, &pulse_support, unix_s_at)
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
