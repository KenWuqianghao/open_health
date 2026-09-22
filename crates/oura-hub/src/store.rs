//! Snapshot storage. Every pushed summary is one row. The latest row feeds the
//! MCP tools; the history keeps the freshness honest and lets a later step diff.

use std::path::Path;
use std::sync::Mutex;

use anyhow::{Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::Value;
use sha2::{Digest, Sha256};

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
