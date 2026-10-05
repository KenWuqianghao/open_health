//! Data from other sources that the client gives to the summary: workouts and
//! measured values from Apple Health (an Apple Watch, other apps).
//!
//! The client writes `external.json` next to the DB. The summary only reads it.

use std::path::{Path, PathBuf};

use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ExternalWorkout {
    pub id: String,
    pub start_unix: i64,
    pub end_unix: i64,
    pub label: String,
    #[serde(default)]
    pub active_kcal: Option<f64>,
    #[serde(default)]
    pub distance_m: Option<f64>,
    #[serde(default)]
    pub avg_hr: Option<f64>,
    #[serde(default)]
    pub max_hr: Option<f64>,
    /// The name of the source, for example `Apple Watch`.
    #[serde(default)]
    pub source: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ExternalValue {
    pub value: f64,
    pub at_unix: i64,
    #[serde(default)]
    pub source: String,
}

#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct External {
    #[serde(default)]
    pub workouts: Vec<ExternalWorkout>,
    /// Measured VO2 max in ml/kg/min.
    #[serde(default)]
    pub vo2max: Option<ExternalValue>,
}

pub fn external_path(db: &Path) -> PathBuf {
    db.parent().unwrap_or(Path::new(".")).join("external.json")
}

/// Read the external data (empty when the file is absent or malformed).
pub fn read_external(db: &Path) -> External {
    std::fs::read_to_string(external_path(db))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

/// Replace the external data. `v` must have the shape of [`External`].
pub fn write_external(db: &Path, v: &Value) -> Result<External> {
    let external: External = serde_json::from_value(v.clone())?;
    let path = external_path(db);
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec(&external)?)?;
    std::fs::rename(&tmp, &path)?;
    Ok(external)
}
