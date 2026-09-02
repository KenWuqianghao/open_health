//! `oura-core` — the UniFFI surface the iOS (and any native) client links against.
//!
//! Everything here delegates to the shared Rust crates that already power the web
//! dashboard (`oura-analysis`, `oura-store`, …). The contract returned to Swift is
//! the same JSON the web client renders, so the two clients never diverge. Bindings
//! are generated with UniFFI (`uniffi-bindgen`), packaged as an `.xcframework`.

use serde_json::json;

uniffi::setup_scaffolding!();

/// Build/version string — a trivial call to validate the FFI round-trip.
#[uniffi::export]
pub fn core_version() -> String {
    format!("oura-core {}", env!("CARGO_PKG_VERSION"))
}

/// HRV RMSSD (ms) over inter-beat intervals — the shared `oura-analysis` algorithm,
/// reachable natively. Returns -1 when the input is too short.
#[uniffi::export]
pub fn rmssd(ibi_ms: Vec<u16>) -> f64 {
    oura_analysis::ported::hrv::rmssd(&ibi_ms).unwrap_or(-1.0)
}

/// The full dashboard summary — the SAME `build_summary()` JSON the web client
/// renders, computed from the synced SQLite DB. `tz_offset` is hours from UTC.
///
/// Models (sleep hypnogram / cardiovascular age / activity sessions) use a
/// [`oura_summary::ModelRunner`]; on-device we'll pass the `.ptl` torch runner.
/// For now [`oura_summary::NoModelRunner`] yields the signal-derived panels
/// (vitals, cardio trend, activity profile, device & data-health, digest) — most
/// of the dashboard — with model fields null until the torch runner is wired.
///
/// Returns the summary JSON string, or `{ "error": "…" }`.
#[uniffi::export]
pub fn summary_json(db_path: String, tz_offset: i64) -> String {
    match oura_summary::build_summary(
        std::path::Path::new(&db_path),
        tz_offset,
        &oura_summary::NoModelRunner,
    ) {
        Ok(v) => v.to_string(),
        Err(e) => json!({ "error": e.to_string() }).to_string(),
    }
}

/// A lightweight, model-free summary (device + data-health only) — kept as a fast
/// path / fallback. Returns `{ serials, device, event_counts, decoded_events }`.
#[uniffi::export]
pub fn quick_summary_json(db_path: String) -> String {
    match quick_summary(&db_path) {
        Ok(v) => v.to_string(),
        Err(e) => json!({ "error": e }).to_string(),
    }
}

fn quick_summary(db_path: &str) -> Result<serde_json::Value, String> {
    let store = oura_store::storage::Store::open(db_path).map_err(|e| e.to_string())?;
    let serials = store.device_serials().map_err(|e| e.to_string())?;
    let primary = serials.first().cloned().unwrap_or_default();

    let device = store.device_info().map_err(|e| e.to_string())?.map(
        |(
            serial,
            hardware_id,
            firmware,
            api_version,
            mac,
            updated_unix,
            last_sync_unix,
            cursor,
        )| {
            json!({ "serial": serial, "hardware_id": hardware_id, "firmware": firmware,
                    "api_version": api_version, "mac": mac, "updated_unix": updated_unix,
                    "last_sync_unix": last_sync_unix, "next_cursor": cursor })
        },
    );

    let event_counts: Vec<_> = store
        .event_counts(&primary)
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|(kind, n)| json!({ "kind": kind, "count": n }))
        .collect();

    let decoded = store.decoded_events().map_err(|e| e.to_string())?.len();

    Ok(json!({
        "serials": serials,
        "device": device,
        "event_counts": event_counts,
        "decoded_events": decoded,
    }))
}

/// The Apple Health sample bundles — `oura_summary::health_export::health_samples`
/// JSON (see that module for the contract). `tz_offset_s` is seconds from UTC and
/// only decides day/hour boundaries; `since_unix` keeps only days whose data
/// changed after that capture time. Returns `{ "error": "…" }` on failure.
#[uniffi::export]
pub fn health_samples_json(db_path: String, tz_offset_s: i64, since_unix: Option<i64>) -> String {
    match oura_summary::health_export::health_samples(
        std::path::Path::new(&db_path),
        tz_offset_s,
        since_unix,
    ) {
        Ok(v) => v.to_string(),
        Err(e) => json!({ "error": e.to_string() }).to_string(),
    }
}

/// The store's `PRAGMA user_version` (migrating an older file in place), or -1
/// when the file cannot be opened — including when it is NEWER than this build.
#[uniffi::export]
pub fn store_schema_version(db_path: String) -> i64 {
    oura_store::storage::Store::open(&db_path)
        .and_then(|s| s.schema_version())
        .unwrap_or(-1)
}

// ── on-device BLE sync over a Swift-provided transport ────────────────────────
// The iOS app does CoreBluetooth; this drives the SAME oura-link OuraClient<T>
// (auth → app stream → drain → store) over a transport that bridges to Swift, so
// the device builds its own DB from a real ring — no btleplug, no cloud.
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use oura_link::pair::{self, FeaturePlan, FeatureResult, Ownership, PairOptions};
use oura_link::transport::Transport;
use oura_link::OuraClient;
use oura_store::storage::Store;
use tokio::sync::{broadcast, oneshot};

/// Swift implements this to send one request frame over CoreBluetooth. Fire-and-
/// forget: the ring's responses come back asynchronously via `push_frame`.
#[uniffi::export(callback_interface)]
pub trait BleWriter: Send + Sync {
    fn write(&self, data: Vec<u8>);
}

/// Swift implements this to receive sync progress. `stage` is a short machine
/// tag ("auth" / "setup" / "sync"); during "sync", `bytes_left` is the ring's
/// own count of event bytes still to transfer (0 = unknown/finished) and
/// `events_synced` the events pulled so far this session.
#[uniffi::export(callback_interface)]
pub trait SyncProgressListener: Send + Sync {
    fn on_progress(&self, stage: String, bytes_left: u64, events_synced: u32);
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct SyncReport {
    pub serial: String,
    pub events_synced: u32,
    pub inserted: u32,
    pub next_cursor: u32,
}

/// Options for [`RingSession::sync_with`].
#[derive(uniffi::Record, Clone, Copy, Debug, Default)]
pub struct SyncOptions {
    /// Events per extended-drain batch (the cursor is checkpointed per batch).
    /// `0` = the library default (4096 ≈ one minute of transfer). A background
    /// refresh task with a ~25 s budget should use a few hundred.
    pub batch_events: u16,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SyncError {
    #[error("{0}")]
    Failed(String),
    /// [`RingSession::cancel`] was called. The message carries the stage and the
    /// last checkpointed cursor; nothing is lost — call again to resume.
    #[error("cancelled: {0}")]
    Cancelled(String),
}

/// Which measurement features [`RingSession::pair`] turns on afterwards.
#[derive(uniffi::Enum, Clone, Copy, Debug)]
pub enum FeaturePlanFfi {
    None,
    Core,
    Full,
}

impl From<FeaturePlanFfi> for FeaturePlan {
    fn from(p: FeaturePlanFfi) -> Self {
        match p {
            FeaturePlanFfi::None => FeaturePlan::None,
            FeaturePlanFfi::Core => FeaturePlan::Core,
            FeaturePlanFfi::Full => FeaturePlan::Full,
        }
    }
}

/// Who holds the ring, as told by the auth verdict (`RingSession::probe`).
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum RingOwnership {
    /// No key installed: pairing will be accepted.
    FactoryReset,
    /// The key we hold authenticates: already paired with this app.
    PairedWithThisKey,
    /// Another key is installed (the official app or another host). Reset first.
    OwnedElsewhere,
    /// Unexpected auth answer, or no answer to the nonce request.
    Unknown,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ProbeReport {
    pub serial: String,
    pub hardware_id: Option<String>,
    /// Ring generation number (3/4/5), `None` when unknown.
    pub generation: Option<u8>,
    pub firmware: Option<String>,
    pub ownership: RingOwnership,
    /// Raw auth state byte (0x00 ok, 0x01 rejected, 0x02 factory reset, 0x03
    /// other onboarding, 0xff = no nonce answer).
    pub auth_state: u8,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FeatureOutcomeFfi {
    pub feature: String,
    pub mode: String,
    /// `set` | `already_set` | `rejected: …` | `skipped: …`
    pub result: String,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct PairReport {
    pub serial: String,
    pub hardware_id: Option<String>,
    pub generation: Option<u8>,
    pub firmware: Option<String>,
    pub battery_pct: Option<u8>,
    /// Always `success` when `pair` returns; kept for the diagnostics log.
    pub auth_result: String,
    /// `true` when the ring was factory-reset and the key was installed now.
    pub key_installed: bool,
    /// `true` when the store's sync cursor was reset to zero (a new key means the
    /// ring clock restarted).
    pub cursor_reset: bool,
    pub features: Vec<FeatureOutcomeFfi>,
}

/// A live sync session bound to a connected ring: Swift creates it with a writer,
/// feeds inbound BLE frames via `push_frame`, then awaits `sync`/`pair`/`probe`.
#[derive(uniffi::Object)]
pub struct RingSession {
    tx: broadcast::Sender<Vec<u8>>,
    writer: Arc<dyn BleWriter>,
    /// Sender for the in-flight operation's cancel signal; taken by `cancel`.
    cancel_tx: Mutex<Option<oneshot::Sender<()>>>,
}

/// Bridges oura-link's `Transport` onto the Swift writer + the inbound frame channel.
struct FfiTransport {
    tx: broadcast::Sender<Vec<u8>>,
    writer: Arc<dyn BleWriter>,
}

#[async_trait::async_trait]
impl Transport for FfiTransport {
    async fn write(&self, data: &[u8]) -> oura_link::Result<()> {
        self.writer.write(data.to_vec());
        Ok(())
    }
    fn subscribe(&self) -> broadcast::Receiver<Vec<u8>> {
        self.tx.subscribe()
    }
}

/// Drain one incremental range, inserting each event before checkpointing its batch.
/// Returning `false` from either callback makes oura-link withhold the ring ACK, so a
/// database failure can never advance the cursor past data that was not persisted.
async fn drain_into_store(
    client: &OuraClient<FfiTransport>,
    cursor: u32,
    serial: &str,
    store: &Mutex<Store>,
    inserted: &AtomicU32,
    db_err: &Mutex<Option<String>>,
    progress: &dyn SyncProgressListener,
) -> Result<oura_link::client::SyncOutcome, String> {
    let outcome = client
        .drain_events(
            cursor,
            |ev| {
                if db_err.lock().unwrap().is_some() {
                    return false;
                }
                match store.lock().unwrap().insert_event(serial, ev) {
                    Ok(true) => {
                        inserted.fetch_add(1, Ordering::Relaxed);
                    }
                    Ok(false) => {}
                    Err(e) => *db_err.lock().unwrap() = Some(e.to_string()),
                }
                db_err.lock().unwrap().is_none()
            },
            |p| {
                progress.on_progress("sync".into(), p.bytes_left as u64, p.events_synced);
                if db_err.lock().unwrap().is_some() {
                    return false;
                }
                if let Err(e) = store.lock().unwrap().set_cursor(serial, p.next_cursor) {
                    *db_err.lock().unwrap() = Some(e.to_string());
                }
                db_err.lock().unwrap().is_none()
            },
        )
        .await
        .map_err(|e| e.to_string())?;

    if let Some(msg) = db_err.lock().unwrap().clone() {
        return Err(msg);
    }
    Ok(outcome)
}

/// An empty incremental fetch is normally legitimate. Verify it cheaply by asking
/// for the event immediately before the saved cursor: a healthy cursor points one
/// past that retained event. If the marker is absent, the ring clock rebooted below
/// the cursor (or an older parser persisted an impossible cursor), so a from-zero
/// drain is required. The probe deliberately does not write to SQLite.
async fn cursor_marker_present(
    client: &OuraClient<FfiTransport>,
    cursor: u32,
) -> Result<bool, String> {
    if cursor == 0 {
        return Ok(true);
    }
    let outcome = client
        .drain_events(cursor - 1, |_| true, |_| true)
        .await
        .map_err(|e| e.to_string())?;
    Ok(outcome.events_synced > 0 && outcome.next_cursor >= cursor)
}

fn should_rebase_cursor(cursor: u32, events_synced: u32, marker_present: bool) -> bool {
    cursor > 0 && events_synced == 0 && !marker_present
}

fn is_rejected_history_cursor(error: &str) -> bool {
    error.contains("extended history request failed with result code 0xff")
}

/// Internal helpers (not exported over FFI).
impl RingSession {
    fn arm_cancel(&self) -> oneshot::Receiver<()> {
        let (tx, rx) = oneshot::channel();
        *self.cancel_tx.lock().unwrap() = Some(tx);
        rx
    }

    fn disarm_cancel(&self) {
        *self.cancel_tx.lock().unwrap() = None;
    }

    fn client(&self, options: SyncOptions) -> OuraClient<FfiTransport> {
        let transport = FfiTransport {
            tx: self.tx.clone(),
            writer: self.writer.clone(),
        };
        OuraClient::new(transport).with_batch_events(options.batch_events)
    }

    async fn sync_body(
        &self,
        db_path: String,
        key_hex: String,
        options: SyncOptions,
        progress: Box<dyn SyncProgressListener>,
    ) -> Result<SyncReport, SyncError> {
        let fail = |e: String| SyncError::Failed(e);
        let key =
            parse_key(&key_hex).ok_or_else(|| fail("auth key must be 32 hex chars".into()))?;
        let client = self.client(options);

        progress.on_progress("auth".into(), 0, 0);
        client
            .authenticate(&key)
            .await
            .map_err(|e| fail(e.to_string()))?;
        progress.on_progress("setup".into(), 0, 0);
        client
            .setup_app_stream()
            .await
            .map_err(|e| fail(e.to_string()))?;
        let serial = client.serial().await.unwrap_or_else(|_| "unknown".into());
        let info = client.firmware().await.ok();

        // Mutex<Store> keeps the future Send across the drain's awaits (rusqlite's
        // Connection is !Sync), while still writing incrementally (no buffering).
        let store = Mutex::new(Store::open(&db_path).map_err(|e| fail(e.to_string()))?);
        store
            .lock()
            .unwrap()
            .upsert_device(&serial, None, info.as_ref())
            .map_err(|e| fail(e.to_string()))?;
        let cursor = store
            .lock()
            .unwrap()
            .cursor(&serial)
            .map_err(|e| fail(e.to_string()))?;

        let inserted = AtomicU32::new(0);
        let db_err: Mutex<Option<String>> = Mutex::new(None);
        progress.on_progress("sync".into(), 0, 0);
        let first_drain = drain_into_store(
            &client,
            cursor,
            &serial,
            &store,
            &inserted,
            &db_err,
            progress.as_ref(),
        )
        .await;
        let mut rejected_cursor_rebased = false;
        let mut outcome = match first_drain {
            Ok(outcome) => outcome,
            Err(error) if cursor > 0 && is_rejected_history_cursor(&error) => {
                // Ring 5 rejects a stale/end cursor with ExtGetEvent result 0xff. Older
                // builds incorrectly treated that as a successful empty terminal batch,
                // leaving retained history unseen. Rebase transactionally; inserts are
                // deduplicated, and checkpoint zero makes a reconnect resume recovery.
                store
                    .lock()
                    .unwrap()
                    .set_cursor(&serial, 0)
                    .map_err(|e| fail(e.to_string()))?;
                progress.on_progress("rebase".into(), 0, 0);
                rejected_cursor_rebased = true;
                drain_into_store(
                    &client,
                    0,
                    &serial,
                    &store,
                    &inserted,
                    &db_err,
                    progress.as_ref(),
                )
                .await
                .map_err(&fail)?
            }
            Err(error) => return Err(fail(error)),
        };

        if outcome.events_synced == 0 && cursor > 0 && !rejected_cursor_rebased {
            let marker_present = cursor_marker_present(&client, cursor)
                .await
                .map_err(&fail)?;
            if should_rebase_cursor(cursor, outcome.events_synced, marker_present) {
                // Checkpoint zero before the recovery drain: if BLE drops midway, the
                // existing reconnect loop resumes the new epoch instead of retrying the
                // stale/poisoned cursor and reporting another false success.
                store
                    .lock()
                    .unwrap()
                    .set_cursor(&serial, 0)
                    .map_err(|e| fail(e.to_string()))?;
                progress.on_progress("rebase".into(), 0, 0);
                outcome = drain_into_store(
                    &client,
                    0,
                    &serial,
                    &store,
                    &inserted,
                    &db_err,
                    progress.as_ref(),
                )
                .await
                .map_err(&fail)?;
            }
        }
        Ok(SyncReport {
            serial,
            events_synced: outcome.events_synced,
            inserted: inserted.into_inner(),
            next_cursor: outcome.next_cursor,
        })
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl RingSession {
    #[uniffi::constructor]
    pub fn new(writer: Box<dyn BleWriter>) -> Arc<Self> {
        // 1024 slots: Ring 5 history frames are coalesced to 32 KB on the Swift
        // side, so the worst case is 32 MB of buffered frames, not 256 MB — a
        // background app on iOS does not get that much. A lagged receiver now
        // fails the batch loudly (oura-link) and resumes from the checkpoint.
        let (tx, _) = broadcast::channel(1024);
        Arc::new(Self {
            tx,
            writer: Arc::from(writer),
            cancel_tx: Mutex::new(None),
        })
    }

    /// Swift pushes each inbound BLE notification frame here.
    pub fn push_frame(&self, data: Vec<u8>) {
        let _ = self.tx.send(data);
    }

    /// Cancel the operation in flight (`sync`, `sync_with`, `pair`). Idempotent;
    /// a no-op when nothing runs. Safe mid-drain: every batch is inserted and
    /// checkpointed before the next request, so the next call resumes.
    pub fn cancel(&self) {
        if let Some(tx) = self.cancel_tx.lock().unwrap().take() {
            let _ = tx.send(());
        }
    }

    /// Identify the ring and classify who owns it, without changing anything.
    /// `key_hex` is the stored key to test (or `None` for an all-zero probe key).
    pub async fn probe(&self, key_hex: Option<String>) -> Result<ProbeReport, SyncError> {
        let fail = |e: String| SyncError::Failed(e);
        let key = match key_hex {
            Some(h) => Some(parse_key(&h).ok_or_else(|| fail("auth key must be 32 hex chars".into()))?),
            None => None,
        };
        let client = self.client(SyncOptions::default());
        let cancel = self.arm_cancel();
        let result = tokio::select! {
            biased;
            _ = cancel => Err(SyncError::Cancelled("probe".into())),
            r = pair::probe(&client, key.as_ref()) => r.map_err(|e| fail(e.to_string())),
        };
        self.disarm_cancel();
        let report = result?;
        let (ownership, auth_state) = match report.ownership {
            Ownership::FactoryReset => (RingOwnership::FactoryReset, 0x02),
            Ownership::PairedWithThisKey => (RingOwnership::PairedWithThisKey, 0x00),
            Ownership::OwnedElsewhere(r) => {
                (RingOwnership::OwnedElsewhere, oura_link::client::auth_state_byte(r))
            }
            Ownership::Unknown(b) => (RingOwnership::Unknown, b),
        };
        Ok(ProbeReport {
            serial: report.serial,
            hardware_id: report.hardware_id,
            generation: report.generation.number(),
            firmware: report.firmware.map(|f| f.firmware_version),
            ownership,
            auth_state,
        })
    }

    /// Install `key_hex` on a factory-reset ring (or confirm it on a ring that
    /// already holds it), set the clock, read the battery, turn on the features in
    /// `plan`, and record the device in the DB at `db_path`. When a key was
    /// installed the sync cursor is reset (the ring clock restarted).
    ///
    /// Swift MUST save `key_hex` to the Keychain BEFORE calling this: a crash
    /// mid-install must never lose the only copy of a key that is live on the ring.
    /// `progress` receives the pairing stages as `stage` tags.
    pub async fn pair(
        &self,
        db_path: String,
        key_hex: String,
        plan: FeaturePlanFfi,
        progress: Box<dyn SyncProgressListener>,
    ) -> Result<PairReport, SyncError> {
        let fail = |e: String| SyncError::Failed(e);
        let key =
            parse_key(&key_hex).ok_or_else(|| fail("auth key must be 32 hex chars".into()))?;
        let client = self.client(SyncOptions::default());
        let opts = PairOptions {
            key,
            plan: plan.into(),
            sync_time: true,
        };
        let cancel = self.arm_cancel();
        let result = tokio::select! {
            biased;
            _ = cancel => Err(SyncError::Cancelled("pair".into())),
            r = pair::pair(&client, &opts, |stage| progress.on_progress(stage.tag().into(), 0, 0)) => {
                r.map_err(|e| fail(e.to_string()))
            }
        };
        self.disarm_cancel();
        let report = result?;

        progress.on_progress("store".into(), 0, 0);
        let store = Store::open(&db_path).map_err(|e| fail(e.to_string()))?;
        store
            .upsert_device(
                &report.serial,
                report.hardware_id.as_deref(),
                report.firmware.as_ref(),
            )
            .map_err(|e| fail(e.to_string()))?;
        let cursor_reset = report.key_installed;
        if cursor_reset {
            store
                .reset_cursor(&report.serial)
                .map_err(|e| fail(e.to_string()))?;
        }
        Ok(PairReport {
            serial: report.serial,
            hardware_id: report.hardware_id,
            generation: report.generation.number(),
            firmware: report.firmware.map(|f| f.firmware_version),
            battery_pct: report.battery_pct,
            auth_result: format!("{:?}", report.auth).to_ascii_lowercase(),
            key_installed: report.key_installed,
            cursor_reset,
            features: report
                .features
                .into_iter()
                .map(|f| FeatureOutcomeFfi {
                    feature: f.name.to_string(),
                    mode: match f.mode {
                        0 => "off",
                        1 => "automatic",
                        2 => "requested",
                        3 => "connected_live",
                        _ => "?",
                    }
                    .to_string(),
                    result: match f.result {
                        FeatureResult::Set => "set".to_string(),
                        FeatureResult::AlreadySet => "already_set".to_string(),
                        FeatureResult::Rejected(e) => format!("rejected: {e}"),
                        FeatureResult::Skipped(why) => format!("skipped: {why}"),
                    },
                })
                .collect(),
        })
    }

    /// [`Self::sync_with`] with the default options.
    pub async fn sync(
        &self,
        db_path: String,
        key_hex: String,
        progress: Box<dyn SyncProgressListener>,
    ) -> Result<SyncReport, SyncError> {
        self.sync_with(db_path, key_hex, SyncOptions::default(), progress)
            .await
    }

    /// Authenticate, set up the app stream, and drain history events into the DB at
    /// `db_path`. `key_hex` is the 32-char ring auth key. `progress` receives stage
    /// changes and per-batch drain progress. Returns the sync counts.
    ///
    /// The drain checkpoints its cursor after every batch, so a failed or
    /// cancelled call can be retried (reconnect + call again) and resumes where
    /// it left off.
    pub async fn sync_with(
        &self,
        db_path: String,
        key_hex: String,
        options: SyncOptions,
        progress: Box<dyn SyncProgressListener>,
    ) -> Result<SyncReport, SyncError> {
        let cancel = self.arm_cancel();
        let result = tokio::select! {
            biased;
            _ = cancel => Err(SyncError::Cancelled(
                "sync interrupted; the last checkpointed batch is kept".into(),
            )),
            r = self.sync_body(db_path, key_hex, options, progress) => r,
        };
        self.disarm_cancel();
        result
    }
}

fn parse_key(hex: &str) -> Option<[u8; 16]> {
    let hex = hex.trim();
    if hex.len() != 32 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let mut key = [0u8; 16];
    for i in 0..16 {
        key[i] = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rebases_empty_sync_when_saved_cursor_marker_is_missing() {
        assert!(should_rebase_cursor(184_190_174, 0, false));
    }

    #[test]
    fn keeps_healthy_or_progressing_cursor() {
        assert!(!should_rebase_cursor(5_586_831, 0, true));
        assert!(!should_rebase_cursor(5_586_831, 12, false));
        assert!(!should_rebase_cursor(0, 0, false));
    }

    struct NullWriter;
    impl BleWriter for NullWriter {
        fn write(&self, _data: Vec<u8>) {}
    }
    struct NullProgress;
    impl SyncProgressListener for NullProgress {
        fn on_progress(&self, _stage: String, _bytes_left: u64, _events_synced: u32) {}
    }

    #[tokio::test]
    async fn cancel_interrupts_a_sync_that_gets_no_answers() {
        // The ring never answers (NullWriter), so auth would wait out the quiet
        // window; cancel() must return first with Cancelled.
        let session = RingSession::new(Box::new(NullWriter));
        let dir = std::env::temp_dir().join(format!("oura-core-cancel-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("cancel.db");
        let s2 = session.clone();
        let canceller = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            s2.cancel();
        });
        let started = std::time::Instant::now();
        let err = session
            .sync_with(
                db.to_string_lossy().into_owned(),
                "4431967d8bacc2659743142b68391d9a".into(),
                SyncOptions { batch_events: 512 },
                Box::new(NullProgress),
            )
            .await
            .unwrap_err();
        canceller.await.unwrap();
        assert!(matches!(err, SyncError::Cancelled(_)), "{err}");
        assert!(started.elapsed() < std::time::Duration::from_millis(1400));
        // cancel with nothing running is a no-op
        session.cancel();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn recognizes_ring5_rejected_cursor_result() {
        assert!(is_rejected_history_cursor(
            "protocol error: extended history request failed with result code 0xff"
        ));
        assert!(!is_rejected_history_cursor("BLE link lost mid-batch"));
    }
}
