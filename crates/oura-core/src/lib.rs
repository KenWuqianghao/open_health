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

/// Raw rows after the given ids, for replication to an always-on hub:
/// `{ schema_version, devices, events, readings, next_event_id, next_reading_id, more }`
/// (see `oura_store::replication`), or `{ "error": "…" }`.
#[uniffi::export]
pub fn export_batch_json(db_path: String, after_event_id: i64, after_reading_id: i64, limit: u32) -> String {
    match oura_store::storage::Store::open(&db_path)
        .and_then(|s| s.export_after(after_event_id, after_reading_id, limit as usize))
    {
        Ok(batch) => serde_json::to_string(&batch).unwrap_or_else(|e| json!({ "error": e.to_string() }).to_string()),
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

// ── the wearer's entries, export and restore ─────────────────────────────────

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum DataError {
    #[error("{0}")]
    Failed(String),
}

fn data_err(e: impl std::fmt::Display) -> DataError {
    DataError::Failed(e.to_string())
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// The journal next to the DB (tags, manual workouts, period days, rest mode) as
/// JSON. See `oura_summary::journal`.
#[uniffi::export]
pub fn journal_json(db_path: String) -> String {
    let journal = oura_summary::journal::read_journal(std::path::Path::new(&db_path));
    serde_json::to_string(&journal).unwrap_or_else(|_| "{}".into())
}

/// Apply one journal operation (JSON, see `oura_summary::journal::apply`) and
/// return the new journal as JSON.
#[uniffi::export]
pub fn journal_apply(db_path: String, op_json: String) -> Result<String, DataError> {
    let op: serde_json::Value = serde_json::from_str(&op_json).map_err(data_err)?;
    let journal = oura_summary::journal::apply(std::path::Path::new(&db_path), &op, now_unix())
        .map_err(data_err)?;
    serde_json::to_string(&journal).map_err(data_err)
}

/// Replace the data from other sources (Apple Health workouts, measured VO2 max)
/// that the summary reads. `json` has the shape of `oura_summary::external::External`.
#[uniffi::export]
pub fn external_write(db_path: String, json: String) -> Result<(), DataError> {
    let v: serde_json::Value = serde_json::from_str(&json).map_err(data_err)?;
    oura_summary::external::write_external(std::path::Path::new(&db_path), &v)
        .map(|_| ())
        .map_err(data_err)
}

/// The daily table as CSV: one row per local day with every metric.
#[uniffi::export]
pub fn export_daily_csv(db_path: String, tz_offset: i64) -> Result<String, DataError> {
    oura_summary::export_daily_csv(
        std::path::Path::new(&db_path),
        tz_offset,
        &oura_summary::NoModelRunner,
    )
    .map_err(data_err)
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ImportReport {
    pub events_seen: u32,
    pub events_inserted: u32,
    pub events_rejected: u32,
    pub readings_inserted: u32,
}

/// Import one page of raw rows (the JSON of `export_batch_json`, which is also
/// what the hub serves at `/export/events`) into the DB at `db_path`. Rows that are
/// in the DB already are skipped, so a restore can run again.
#[uniffi::export]
pub fn import_batch_json(db_path: String, batch_json: String) -> Result<ImportReport, DataError> {
    let batch: oura_store::replication::ExportBatch =
        serde_json::from_str(&batch_json).map_err(data_err)?;
    if batch.schema_version > oura_store::replication::BATCH_VERSION {
        return Err(DataError::Failed(format!(
            "the backup has batch version {}, this app reads version {}",
            batch.schema_version,
            oura_store::replication::BATCH_VERSION
        )));
    }
    let store = oura_store::storage::Store::open(&db_path).map_err(data_err)?;
    let out = store.import_batch(&batch).map_err(data_err)?;
    Ok(ImportReport {
        events_seen: out.events_seen as u32,
        events_inserted: out.events_inserted as u32,
        events_rejected: out.events_rejected as u32,
        readings_inserted: out.readings_inserted as u32,
    })
}

/// Write a demo database (no ring needed) with `days` of history that end now.
/// The file at `db_path` must not exist.
#[uniffi::export]
pub fn write_demo_db(db_path: String, days: u32, tz_offset: i64) -> Result<(), DataError> {
    let path = std::path::Path::new(&db_path);
    if path.exists() {
        return Err(DataError::Failed("a database exists already".into()));
    }
    let options = oura_summary::demo::DemoOptions { days, end_unix: now_unix(), tz: tz_offset, seed: 7 };
    oura_summary::demo::write_demo(path, &options).map(|_| ()).map_err(data_err)
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

/// Swift implements this to receive the beats of a live heart rate stream.
#[uniffi::export(callback_interface)]
pub trait LiveBeatListener: Send + Sync {
    /// One valid beat: the heart rate from its interval, and the interval (ms).
    fn on_beat(&self, bpm: u16, ibi_ms: u16);
}

#[derive(uniffi::Record, Clone, Copy, Debug)]
pub struct LiveReport {
    pub beats: u32,
    pub seconds: f64,
}

/// The ring's latest stored readings (not a live stream).
#[derive(uniffi::Record, Clone, Copy, Debug)]
pub struct LatestReading {
    pub bpm: Option<u16>,
    pub spo2_percent: Option<u8>,
}

/// One measurement feature of the ring as it is now.
#[derive(uniffi::Record, Clone, Debug)]
pub struct FeatureState {
    /// `daytime_hr` | `spo2` | `exercise_hr` | `real_steps` | `cva_ppg`
    pub feature: String,
    /// `off` | `automatic` | `requested` | `connected_live`
    pub mode: String,
    /// False when the ring gave no status for the feature (not supported).
    pub supported: bool,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct RingStatus {
    pub battery_pct: Option<u8>,
    /// Charge progress in percent; 0 when the ring is not on its charger.
    pub charging_progress: Option<u8>,
    pub features: Vec<FeatureState>,
}

fn mode_name(mode: u8) -> &'static str {
    match mode {
        0 => "off",
        1 => "automatic",
        2 => "requested",
        3 => "connected_live",
        _ => "?",
    }
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct SyncReport {
    pub serial: String,
    pub events_synced: u32,
    pub inserted: u32,
    pub next_cursor: u32,
    /// At least one of the two clock writes at the end of the sync went out without
    /// a link error. The ring does not answer them; the proof is its `time_sync`
    /// event in the next drain.
    pub clock_written: bool,
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

/// True only for the Ring 5 reply to a cursor that it does not accept (extended
/// result code `0xff`). Each other result code, such as the legacy `0x11` of a
/// Gen3 ring, is a refused request: the ring can hold the history and the saved
/// cursor can be correct. Such an error must fail the sync and keep the cursor.
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

        // Write the phone's clock to the ring on every sync. The ring logs each
        // write as a `time_sync` event, and that event is the only link from its
        // tick counter to UTC. Without a fresh one, a flat battery (the counter
        // stops while the ring is off) moves every later night hours earlier.
        // This runs after the drain is saved because a Gen3 ring can drop the
        // link soon after a write. Best effort, like pairing: both message forms.
        // Each write waits out the 1.5 s quiet window, so this adds about 3 s.
        let clock_written =
            client.sync_time().await.is_ok() | client.sync_time_app().await.is_ok();

        Ok(SyncReport {
            serial,
            events_synced: outcome.events_synced,
            inserted: inserted.into_inner(),
            next_cursor: outcome.next_cursor,
            clock_written,
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

    /// Stream live heart rate until [`Self::cancel`] is called. `listener` gets
    /// every valid beat. The ring goes back to automatic measurement before this
    /// returns. The ring must be on a finger.
    pub async fn live_heart_rate(
        &self,
        key_hex: String,
        listener: Box<dyn LiveBeatListener>,
    ) -> Result<LiveReport, SyncError> {
        let fail = |e: String| SyncError::Failed(e);
        let key =
            parse_key(&key_hex).ok_or_else(|| fail("auth key must be 32 hex chars".into()))?;
        let client = self.client(SyncOptions::default());
        let cancel = self.arm_cancel();
        client
            .authenticate(&key)
            .await
            .map_err(|e| fail(e.to_string()))?;
        let started = std::time::Instant::now();
        let mut beats = 0u32;
        // `cancel` is the stop signal, not a `select!` arm: the stream must end
        // with its own teardown, which sets the ring back to automatic.
        let result = client
            .live_heart_rate_until(
                async {
                    let _ = cancel.await;
                },
                false,
                |sample| {
                    beats += 1;
                    listener.on_beat(sample.bpm, sample.ibi_ms);
                },
            )
            .await;
        self.disarm_cancel();
        result.map_err(|e| fail(e.to_string()))?;
        Ok(LiveReport { beats, seconds: started.elapsed().as_secs_f64() })
    }

    /// Read the heart rate and the blood oxygen that the ring measured last. This
    /// changes no setting on the ring, so it also works on a ring that drops the
    /// link after a mode change.
    pub async fn latest_reading(&self, key_hex: String) -> Result<LatestReading, SyncError> {
        let fail = |e: String| SyncError::Failed(e);
        let key =
            parse_key(&key_hex).ok_or_else(|| fail("auth key must be 32 hex chars".into()))?;
        let client = self.client(SyncOptions::default());
        let cancel = self.arm_cancel();
        let body = async {
            client.authenticate(&key).await.map_err(|e| fail(e.to_string()))?;
            let hr = client.feature_latest(0x02).await.map_err(|e| fail(e.to_string()))?;
            let spo2 = client.feature_latest(0x04).await.ok();
            Ok::<_, SyncError>(LatestReading {
                bpm: hr.bpm.or(spo2.and_then(|s| s.bpm)),
                spo2_percent: spo2.and_then(|s| s.spo2_percent),
            })
        };
        let result = tokio::select! {
            biased;
            _ = cancel => Err(SyncError::Cancelled("latest reading".into())),
            r = body => r,
        };
        self.disarm_cancel();
        result
    }

    /// Read the battery and the mode of each user feature. The battery read is
    /// stored in the DB at `db_path` for the battery history.
    pub async fn ring_status(&self, db_path: String, key_hex: String) -> Result<RingStatus, SyncError> {
        let fail = |e: String| SyncError::Failed(e);
        let key =
            parse_key(&key_hex).ok_or_else(|| fail("auth key must be 32 hex chars".into()))?;
        let client = self.client(SyncOptions::default());
        let cancel = self.arm_cancel();
        let body = async {
            client.authenticate(&key).await.map_err(|e| fail(e.to_string()))?;
            let battery = client.battery().await.ok();
            let mut features = Vec::new();
            for id in pair::USER_FEATURES {
                let status = client.feature_status(id).await.ok();
                features.push(FeatureState {
                    feature: pair::feature_name(id).to_string(),
                    mode: status.map_or("?", |s| mode_name(s.mode)).to_string(),
                    supported: status.is_some(),
                });
            }
            let serial = client.serial().await.ok();
            Ok::<_, SyncError>((battery, features, serial))
        };
        let result = tokio::select! {
            biased;
            _ = cancel => Err(SyncError::Cancelled("ring status".into())),
            r = body => r,
        };
        self.disarm_cancel();
        let (battery, features, serial) = result?;
        if let (Some(battery), Some(serial)) = (battery.as_ref(), serial.as_deref()) {
            // best effort: the status is still correct when the DB is busy
            if let Ok(store) = Store::open(&db_path) {
                let _ = store.insert_battery(serial, battery);
            }
        }
        let db = std::path::Path::new(&db_path);
        for f in features.iter().filter(|f| f.supported) {
            let mode = ["off", "automatic", "requested", "connected_live"]
                .iter()
                .position(|m| *m == f.mode)
                .unwrap_or(0);
            oura_summary::write_feature_mode(db, &f.feature, mode as i64);
        }
        Ok(RingStatus {
            battery_pct: battery.map(|b| b.percent),
            charging_progress: battery.map(|b| b.charging_progress),
            features,
        })
    }

    /// Turn a measurement feature on (automatic) or off. A Gen3 ring can drop
    /// the link about 2 s after it accepts the change; the change is kept.
    pub async fn set_feature(
        &self,
        db_path: String,
        key_hex: String,
        feature: String,
        on: bool,
    ) -> Result<FeatureState, SyncError> {
        let fail = |e: String| SyncError::Failed(e);
        let key =
            parse_key(&key_hex).ok_or_else(|| fail("auth key must be 32 hex chars".into()))?;
        let id = pair::feature_id(&feature)
            .filter(|id| pair::USER_FEATURES.contains(id))
            .ok_or_else(|| fail(format!("unknown feature {feature}")))?;
        let mode = if on { 1u8 } else { 0u8 };
        let client = self.client(SyncOptions::default());
        let cancel = self.arm_cancel();
        let body = async {
            client.authenticate(&key).await.map_err(|e| fail(e.to_string()))?;
            client
                .set_feature_mode(id, mode)
                .await
                .map_err(|e| fail(e.to_string()))
        };
        let result = tokio::select! {
            biased;
            _ = cancel => Err(SyncError::Cancelled("set feature".into())),
            r = body => r,
        };
        self.disarm_cancel();
        result?;
        oura_summary::write_feature_mode(std::path::Path::new(&db_path), &feature, mode as i64);
        Ok(FeatureState { feature, mode: mode_name(mode).to_string(), supported: true })
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

    #[test]
    fn refused_history_request_is_not_a_rejected_cursor() {
        // The oura-link error for the summary tail `03 11` of a Gen3 ring. Only
        // the Ring 5 code 0xff of the extended API starts a drain from cursor 0.
        assert!(!is_rejected_history_cursor(
            "legacy history request failed with result code 0x11"
        ));
        assert!(!is_rejected_history_cursor(
            "extended history request failed with result code 0x11"
        ));
    }

    /// A scripted ring. It answers a request with the frames of the longest
    /// request prefix (hex) that matches, and it records each request.
    struct ScriptedRing {
        tx: broadcast::Sender<Vec<u8>>,
        replies: Vec<(&'static str, &'static str)>,
        requests: Arc<Mutex<Vec<String>>>,
    }
    impl BleWriter for ScriptedRing {
        fn write(&self, data: Vec<u8>) {
            let request: String = data.iter().map(|b| format!("{b:02x}")).collect();
            let reply = self
                .replies
                .iter()
                .filter(|(prefix, _)| request.starts_with(prefix))
                .max_by_key(|(prefix, _)| prefix.len());
            if let Some((_, frame)) = reply {
                let bytes = (0..frame.len())
                    .step_by(2)
                    .map(|i| u8::from_str_radix(&frame[i..i + 2], 16).unwrap())
                    .collect();
                let _ = self.tx.send(bytes);
            }
            self.requests.lock().unwrap().push(request);
        }
    }

    #[tokio::test]
    async fn refused_history_request_fails_the_sync_and_keeps_the_cursor() {
        // Gen3 BLB_03 fw 3.4.3, 2026-09-29 02:47: the ring answered each GetEvent,
        // also at cursor 0, with 0 events, 0 bytes left and result code 0x11. It
        // held 6.4 MB of history. The old code set the saved cursor to 0.
        const SERIAL: &str = "XXXXXXXXXXXXXX";
        const CURSOR: u32 = 5_418_433;
        let dir = std::env::temp_dir().join(format!("oura-core-refused-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("refused.db").to_string_lossy().into_owned();
        {
            let store = Store::open(&db).unwrap();
            store.upsert_device(SERIAL, None, None).unwrap();
            store.set_cursor(SERIAL, CURSOR).unwrap();
        }

        let (tx, _) = broadcast::channel(1024);
        let requests = Arc::new(Mutex::new(Vec::new()));
        let ring = ScriptedRing {
            tx: tx.clone(),
            replies: vec![
                ("2f012b", "2f102c0e2d6a0a08c99b4365f458e6e97382"),
                ("2f112d", "2f022e00"),
                ("1803180010", "191100424c425f303300000000000000000000"),
                ("1803080010", "19110058585858585858585858585858580000"),
                ("0803000000", "091202000003040301000105000cffeeddccbbaa"),
                ("280100", "290100"),
                // A Gen3 ring does not have the extended API.
                ("2f0c41", "2f020041"),
                ("1009c1ad5200", "11080007000000000311"),
                ("1009", "1108001f000000000311"),
            ],
            requests: requests.clone(),
        };
        let session = RingSession {
            tx,
            writer: Arc::new(ring),
            cancel_tx: Mutex::new(None),
        };
        let err = session
            .sync_with(
                db.clone(),
                "4431967d8bacc2659743142b68391d9a".into(),
                SyncOptions { batch_events: 512 },
                Box::new(NullProgress),
            )
            .await
            .unwrap_err();

        assert!(
            matches!(&err, SyncError::Failed(m)
                if m.contains("legacy history request failed with result code 0x11")),
            "{err}"
        );
        assert_eq!(Store::open(&db).unwrap().cursor(SERIAL).unwrap(), CURSOR);
        // One GetEvent only: no marker probe and no drain from cursor 0.
        let get_events: Vec<String> = requests
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.starts_with("10"))
            .cloned()
            .collect();
        assert_eq!(get_events, ["1009c1ad5200ffffffffff"]);
        std::fs::remove_dir_all(&dir).ok();
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
    fn journal_and_restore_round_trip_over_the_ffi() {
        let dir = std::env::temp_dir().join(format!("oura-core-data-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("source.db").to_string_lossy().into_owned();
        write_demo_db(source.clone(), 3, 0).unwrap();
        assert!(write_demo_db(source.clone(), 3, 0).is_err());

        let added = journal_apply(
            source.clone(),
            r#"{"op":"add_tag","day":"2026-09-27","tag":"sauna"}"#.into(),
        )
        .unwrap();
        assert!(added.contains("sauna"));
        assert_eq!(journal_json(source.clone()), added);
        assert!(journal_apply(source.clone(), r#"{"op":"nothing"}"#.into()).is_err());

        // restore: every row of the source arrives in an empty DB, once
        let restored = dir.join("restored.db").to_string_lossy().into_owned();
        let batch = export_batch_json(source.clone(), 0, 0, 100_000);
        let first = import_batch_json(restored.clone(), batch.clone()).unwrap();
        assert!(first.events_inserted > 1000);
        assert_eq!(first.events_inserted, first.events_seen);
        assert_eq!(import_batch_json(restored.clone(), batch).unwrap().events_inserted, 0);

        let csv = export_daily_csv(restored, 0).unwrap();
        assert!(csv.starts_with("date,bedtime,wake,"));
        assert!(csv.lines().count() >= 3);
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
