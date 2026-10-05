//! The wearer's own entries: tags, manual workouts, period days and rest mode.
//!
//! They live in `journal.json` next to the DB, like the profile. Every change goes
//! through [`apply`], so the web client and the iOS app write the same file in the
//! same way. The ring knows nothing about these entries.

use std::path::{Path, PathBuf};

use anyhow::{anyhow, bail, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::days_from_civil;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct TagEntry {
    pub id: String,
    /// The local day the tag belongs to, `YYYY-MM-DD`.
    pub day: String,
    pub tag: String,
    #[serde(default)]
    pub note: String,
    pub created_unix: i64,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ManualWorkout {
    pub id: String,
    pub start_unix: i64,
    pub duration_min: f64,
    pub label: String,
    #[serde(default)]
    pub active_kcal: Option<f64>,
    #[serde(default)]
    pub note: String,
}

/// Rest mode from `start` to `end` (both included). An open period has no end.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct RestPeriod {
    pub start: String,
    #[serde(default)]
    pub end: Option<String>,
}

#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct Journal {
    #[serde(default)]
    pub tags: Vec<TagEntry>,
    #[serde(default)]
    pub workouts: Vec<ManualWorkout>,
    /// The first day of each period, `YYYY-MM-DD`.
    #[serde(default)]
    pub periods: Vec<String>,
    #[serde(default)]
    pub rest_mode: Vec<RestPeriod>,
}

pub fn journal_path(db: &Path) -> PathBuf {
    db.parent().unwrap_or(Path::new(".")).join("journal.json")
}

/// Read the journal (empty when the file is absent or malformed).
pub fn read_journal(db: &Path) -> Journal {
    std::fs::read_to_string(journal_path(db))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn write_journal(db: &Path, journal: &Journal) -> Result<()> {
    let path = journal_path(db);
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(journal)?)?;
    std::fs::rename(&tmp, &path)?;
    Ok(())
}

/// Days since 1970-01-01 for a `YYYY-MM-DD` string.
pub fn parse_day(day: &str) -> Option<i64> {
    let mut parts = day.split('-');
    let y: i64 = parts.next()?.parse().ok()?;
    let m: u32 = parts.next()?.parse().ok()?;
    let d: u32 = parts.next()?.parse().ok()?;
    if parts.next().is_some() || day.len() != 10 || !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    Some(days_from_civil(y, m, d))
}

fn day_field(op: &Value) -> Result<String> {
    let day = op["day"].as_str().ok_or_else(|| anyhow!("`day` is missing"))?;
    parse_day(day).ok_or_else(|| anyhow!("`day` must be YYYY-MM-DD"))?;
    Ok(day.to_string())
}

fn text_field(op: &Value, key: &str, max: usize) -> Result<String> {
    let text = op[key].as_str().unwrap_or("").trim();
    if text.is_empty() {
        bail!("`{key}` is missing");
    }
    Ok(text.chars().take(max).collect())
}

impl Journal {
    fn new_id(&self, now_unix: i64) -> String {
        let n = self.tags.len() + self.workouts.len();
        format!("{now_unix:x}-{n:x}")
    }

    /// The local days (days since 1970) that are in rest mode, up to `today`.
    pub fn rest_days(&self, today: i64) -> std::collections::BTreeSet<i64> {
        let mut days = std::collections::BTreeSet::new();
        for period in &self.rest_mode {
            let Some(start) = parse_day(&period.start) else { continue };
            let end = period.end.as_deref().and_then(parse_day).unwrap_or(today);
            // a period of more than a year is a mistake in the file
            days.extend(start..=end.min(start + 366));
        }
        days
    }

    /// True when a rest period has no end.
    pub fn rest_mode_on(&self) -> bool {
        self.rest_mode.iter().any(|p| p.end.is_none())
    }

    /// Apply one operation. See [`apply`].
    pub fn apply_op(&mut self, op: &Value, now_unix: i64) -> Result<()> {
        match op["op"].as_str().unwrap_or("") {
            "add_tag" => {
                let day = day_field(op)?;
                let tag = text_field(op, "tag", 40)?.to_lowercase();
                if self.tags.iter().any(|t| t.day == day && t.tag == tag) {
                    return Ok(());
                }
                self.tags.push(TagEntry {
                    id: self.new_id(now_unix),
                    day,
                    tag,
                    note: op["note"].as_str().unwrap_or("").chars().take(280).collect(),
                    created_unix: now_unix,
                });
            }
            "remove_tag" => {
                let id = text_field(op, "id", 64)?;
                self.tags.retain(|t| t.id != id);
            }
            "add_workout" => {
                let start_unix = op["start_unix"]
                    .as_i64()
                    .ok_or_else(|| anyhow!("`start_unix` is missing"))?;
                let duration_min = op["duration_min"]
                    .as_f64()
                    .filter(|d| (1.0..=24.0 * 60.0).contains(d))
                    .ok_or_else(|| anyhow!("`duration_min` must be 1 to 1440"))?;
                self.workouts.push(ManualWorkout {
                    id: self.new_id(now_unix),
                    start_unix,
                    duration_min,
                    label: text_field(op, "label", 40)?,
                    active_kcal: op["active_kcal"].as_f64().filter(|k| *k > 0.0),
                    note: op["note"].as_str().unwrap_or("").chars().take(280).collect(),
                });
            }
            "remove_workout" => {
                let id = text_field(op, "id", 64)?;
                self.workouts.retain(|w| w.id != id);
            }
            "add_period" => {
                let day = day_field(op)?;
                if !self.periods.contains(&day) {
                    self.periods.push(day);
                    self.periods.sort();
                }
            }
            "remove_period" => {
                let day = day_field(op)?;
                self.periods.retain(|d| *d != day);
            }
            "set_rest_mode" => {
                let day = day_field(op)?;
                let on = op["on"].as_bool().ok_or_else(|| anyhow!("`on` is missing"))?;
                let open = self.rest_mode.iter().position(|p| p.end.is_none());
                match (on, open) {
                    (true, None) => self.rest_mode.push(RestPeriod { start: day, end: None }),
                    (false, Some(i)) => {
                        if day < self.rest_mode[i].start {
                            self.rest_mode.remove(i);
                        } else {
                            self.rest_mode[i].end = Some(day);
                        }
                    }
                    _ => {}
                }
            }
            other => bail!("unknown journal operation `{other}`"),
        }
        Ok(())
    }
}

/// Apply one operation to the journal next to `db` and return the new journal.
///
/// | `op` | fields |
/// | --- | --- |
/// | `add_tag` | `day`, `tag`, `note` (optional) |
/// | `remove_tag` | `id` |
/// | `add_workout` | `start_unix`, `duration_min`, `label`, `active_kcal` and `note` (optional) |
/// | `remove_workout` | `id` |
/// | `add_period`, `remove_period` | `day` (the first day of the period) |
/// | `set_rest_mode` | `on`, `day` (the day the change starts) |
pub fn apply(db: &Path, op: &Value, now_unix: i64) -> Result<Journal> {
    let mut journal = read_journal(db);
    journal.apply_op(op, now_unix)?;
    write_journal(db, &journal)?;
    Ok(journal)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn tags_are_added_once_and_removed_by_id() {
        let mut j = Journal::default();
        j.apply_op(&json!({"op": "add_tag", "day": "2026-09-27", "tag": " Alcohol "}), 100).unwrap();
        j.apply_op(&json!({"op": "add_tag", "day": "2026-09-27", "tag": "alcohol"}), 101).unwrap();
        assert_eq!(j.tags.len(), 1);
        assert_eq!(j.tags[0].tag, "alcohol");
        let id = j.tags[0].id.clone();
        j.apply_op(&json!({"op": "remove_tag", "id": id}), 102).unwrap();
        assert!(j.tags.is_empty());
        assert!(j.apply_op(&json!({"op": "add_tag", "day": "27-09-2026", "tag": "x"}), 1).is_err());
        assert!(j.apply_op(&json!({"op": "add_tag", "day": "2026-09-27", "tag": " "}), 1).is_err());
        assert!(j.apply_op(&json!({"op": "fly"}), 1).is_err());
    }

    #[test]
    fn rest_mode_opens_and_closes_a_period() {
        let mut j = Journal::default();
        j.apply_op(&json!({"op": "set_rest_mode", "on": true, "day": "2026-09-20"}), 1).unwrap();
        assert!(j.rest_mode_on());
        let today = parse_day("2026-09-22").unwrap();
        assert_eq!(j.rest_days(today).len(), 3);
        j.apply_op(&json!({"op": "set_rest_mode", "on": false, "day": "2026-09-21"}), 2).unwrap();
        assert!(!j.rest_mode_on());
        assert_eq!(j.rest_days(today).len(), 2);
    }

    #[test]
    fn the_file_round_trips() {
        let dir = std::env::temp_dir().join(format!("oura-journal-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("oura.db");
        let op = json!({"op": "add_workout", "start_unix": 1_790_000_000i64,
                        "duration_min": 45, "label": "Yoga"});
        let written = apply(&db, &op, 5).unwrap();
        assert_eq!(read_journal(&db), written);
        assert_eq!(written.workouts[0].label, "Yoga");
        std::fs::remove_dir_all(&dir).ok();
    }
}
