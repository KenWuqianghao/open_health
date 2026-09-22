//! Snapshot storage. Every pushed summary is one row. The latest row feeds the
//! MCP tools; the history keeps the freshness honest and lets a later step diff.

use std::path::Path;
use std::sync::Mutex;

use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::health::{HealthBatch, HealthOutcome, HealthSample};

pub struct Store {
    conn: Mutex<Connection>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Snapshot {
    pub id: i64,
    pub received_at: i64,
    pub generated_at: Option<f64>,
    pub body: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PutOutcome {
    /// False when an identical body was already stored.
    pub stored: bool,
    pub sha256: String,
    pub snapshots: i64,
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS snapshots (
    id INTEGER PRIMARY KEY,
    received_at INTEGER NOT NULL,
    generated_at REAL,
    sha256 TEXT NOT NULL UNIQUE,
    body TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS snapshots_received ON snapshots(received_at);
CREATE TABLE IF NOT EXISTS health_samples (
    uuid TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    start_unix REAL NOT NULL,
    end_unix REAL NOT NULL,
    value REAL,
    unit TEXT,
    category TEXT,
    source_bundle TEXT,
    source_name TEXT,
    device TEXT,
    metadata TEXT,
    received_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS health_kind_start ON health_samples(kind, start_unix);
CREATE INDEX IF NOT EXISTS health_end ON health_samples(end_unix);
";

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path).with_context(|| format!("opening {}", path.display()))?;
        Self::init(conn)
    }

    pub fn in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.execute_batch("PRAGMA journal_mode=WAL;")?;
        conn.execute_batch(SCHEMA)?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    /// Store one summary. An identical body (same SHA-256) is not stored twice.
    pub fn put(&self, body: &Value, received_at: i64) -> Result<PutOutcome> {
        let text = serde_json::to_string(body)?;
        let sha256 = hex::encode(Sha256::digest(text.as_bytes()));
        let generated_at = body.get("generated_at").and_then(Value::as_f64);
        let conn = self.conn.lock().unwrap();
        let inserted = conn.execute(
            "INSERT OR IGNORE INTO snapshots(received_at, generated_at, sha256, body) VALUES (?1, ?2, ?3, ?4)",
            params![received_at, generated_at, sha256, text],
        )?;
        let snapshots: i64 = conn.query_row("SELECT COUNT(*) FROM snapshots", [], |r| r.get(0))?;
        Ok(PutOutcome { stored: inserted == 1, sha256, snapshots })
    }

    /// The most recently received snapshot.
    pub fn latest(&self) -> Result<Option<Snapshot>> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT id, received_at, generated_at, body FROM snapshots ORDER BY received_at DESC, id DESC LIMIT 1",
            [],
            |r| {
                let text: String = r.get(3)?;
                Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, Option<f64>>(2)?, text))
            },
        )
        .optional()?
        .map(|(id, received_at, generated_at, text)| {
            Ok(Snapshot { id, received_at, generated_at, body: serde_json::from_str(&text)? })
        })
        .transpose()
    }

    pub fn count(&self) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        Ok(conn.query_row("SELECT COUNT(*) FROM snapshots", [], |r| r.get(0))?)
    }

    /// Upsert Apple Health samples by UUID and apply the deletions.
    pub fn put_health(&self, batch: &HealthBatch, received_at: i64) -> Result<HealthOutcome> {
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        let mut out = HealthOutcome { samples_seen: batch.samples.len(), ..Default::default() };
        for s in &batch.samples {
            let metadata = s.metadata.as_ref().map(|m| m.to_string());
            out.stored += tx.execute(
                "INSERT OR REPLACE INTO health_samples
                   (uuid, kind, start_unix, end_unix, value, unit, category, source_bundle, source_name, device, metadata, received_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                params![s.uuid, s.kind, s.start_unix, s.end_unix, s.value, s.unit, s.category,
                        s.source_bundle, s.source_name, s.device, metadata, received_at],
            )?;
        }
        for uuid in &batch.deleted {
            out.deleted += tx.execute("DELETE FROM health_samples WHERE uuid = ?1", params![uuid])?;
        }
        tx.commit()?;
        out.total = conn.query_row("SELECT COUNT(*) FROM health_samples", [], |r| r.get(0))?;
        Ok(out)
    }

    /// Samples of one kind (or all kinds) that end at or after `since_unix`, newest first.
    pub fn health_rows(&self, kind: Option<&str>, since_unix: f64, limit: usize) -> Result<Vec<HealthSample>> {
        let conn = self.conn.lock().unwrap();
        let sql = format!(
            "SELECT uuid, kind, start_unix, end_unix, value, unit, category, source_bundle, source_name, device, metadata
             FROM health_samples WHERE end_unix >= ?1 {} ORDER BY end_unix DESC LIMIT ?2",
            if kind.is_some() { "AND kind = ?3" } else { "" }
        );
        let mut stmt = conn.prepare(&sql)?;
        let map = |r: &rusqlite::Row| -> rusqlite::Result<HealthSample> {
            let metadata: Option<String> = r.get(10)?;
            Ok(HealthSample {
                uuid: r.get(0)?, kind: r.get(1)?, start_unix: r.get(2)?, end_unix: r.get(3)?,
                value: r.get(4)?, unit: r.get(5)?, category: r.get(6)?, source_bundle: r.get(7)?,
                source_name: r.get(8)?, device: r.get(9)?,
                metadata: metadata.and_then(|m| serde_json::from_str(&m).ok()),
            })
        };
        let rows = match kind {
            Some(k) => stmt.query_map(params![since_unix, limit as i64, k], map)?.collect::<std::result::Result<Vec<_>, _>>()?,
            None => stmt.query_map(params![since_unix, limit as i64], map)?.collect::<std::result::Result<Vec<_>, _>>()?,
        };
        Ok(rows)
    }

    /// The newest sample of every kind. Sparse kinds (VO2 max, resting heart rate)
    /// may be older than any window the caller uses.
    pub fn health_latest_per_kind(&self) -> Result<Vec<HealthSample>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(
            "SELECT h.uuid, h.kind, h.start_unix, h.end_unix, h.value, h.unit, h.category, h.source_bundle, h.source_name, h.device, h.metadata
             FROM health_samples h
             JOIN (SELECT kind, MAX(end_unix) AS newest FROM health_samples GROUP BY kind) n
               ON n.kind = h.kind AND n.newest = h.end_unix
             GROUP BY h.kind",
        )?;
        let rows = stmt
            .query_map([], |r| {
                let metadata: Option<String> = r.get(10)?;
                Ok(HealthSample {
                    uuid: r.get(0)?, kind: r.get(1)?, start_unix: r.get(2)?, end_unix: r.get(3)?,
                    value: r.get(4)?, unit: r.get(5)?, category: r.get(6)?, source_bundle: r.get(7)?,
                    source_name: r.get(8)?, device: r.get(9)?,
                    metadata: metadata.and_then(|m| serde_json::from_str(&m).ok()),
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// `(kind, count, newest end_unix)` per kind.
    pub fn health_kinds(&self) -> Result<Vec<(String, i64, f64)>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT kind, COUNT(*), MAX(end_unix) FROM health_samples GROUP BY kind ORDER BY kind")?;
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Keep only the newest `keep` snapshots. Returns the number removed.
    pub fn prune(&self, keep: i64) -> Result<usize> {
        let conn = self.conn.lock().unwrap();
        Ok(conn.execute(
            "DELETE FROM snapshots WHERE id NOT IN (SELECT id FROM snapshots ORDER BY received_at DESC, id DESC LIMIT ?1)",
            params![keep],
        )?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use crate::health::{HealthBatch, HealthSample};

    #[test]
    fn put_latest_and_dedup() {
        let s = Store::in_memory().unwrap();
        assert!(s.latest().unwrap().is_none());
        let a = s.put(&json!({ "generated_at": 10.0, "nights": [] }), 100).unwrap();
        assert!(a.stored);
        assert_eq!(a.snapshots, 1);
        let again = s.put(&json!({ "generated_at": 10.0, "nights": [] }), 101).unwrap();
        assert!(!again.stored);
        assert_eq!(again.snapshots, 1);
        let b = s.put(&json!({ "generated_at": 20.0, "nights": [] }), 102).unwrap();
        assert!(b.stored);
        let latest = s.latest().unwrap().unwrap();
        assert_eq!(latest.received_at, 102);
        assert_eq!(latest.generated_at, Some(20.0));
        assert_eq!(latest.body["generated_at"], 20.0);
    }

    #[test]
    fn health_upsert_query_and_delete() {
        let s = Store::in_memory().unwrap();
        let sample = |uuid: &str, kind: &str, end: f64| HealthSample {
            uuid: uuid.into(), kind: kind.into(), start_unix: end - 60.0, end_unix: end, value: Some(1.0),
            unit: None, category: None, source_bundle: None, source_name: None, device: None,
            metadata: Some(json!({ "k": 1 })),
        };
        let batch = HealthBatch { tz_offset_s: None, samples: vec![sample("a", "heart_rate", 100.0), sample("b", "step_count", 200.0)], deleted: vec![] };
        let out = s.put_health(&batch, 1).unwrap();
        assert_eq!((out.samples_seen, out.stored, out.total), (2, 2, 2));
        let again = HealthBatch { tz_offset_s: None, samples: vec![sample("a", "heart_rate", 100.0)], deleted: vec!["b".into(), "zzz".into()] };
        let out = s.put_health(&again, 2).unwrap();
        assert_eq!((out.stored, out.deleted, out.total), (1, 1, 1));
        let rows = s.health_rows(Some("heart_rate"), 0.0, 10).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].metadata, Some(json!({ "k": 1 })));
        assert!(s.health_rows(None, 150.0, 10).unwrap().is_empty());
        let latest = s.health_latest_per_kind().unwrap();
        assert_eq!(latest.len(), 1);
        assert_eq!(latest[0].uuid, "a");
        assert_eq!(s.health_kinds().unwrap(), vec![("heart_rate".to_string(), 1, 100.0)]);
    }

    #[test]
    fn prune_keeps_the_newest() {
        let s = Store::in_memory().unwrap();
        for i in 0..5 {
            s.put(&json!({ "generated_at": i }), 1000 + i).unwrap();
        }
        assert_eq!(s.prune(2).unwrap(), 3);
        assert_eq!(s.count().unwrap(), 2);
        assert_eq!(s.latest().unwrap().unwrap().received_at, 1004);
    }
}
