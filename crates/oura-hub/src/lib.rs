//! The always-on health hub.
//!
//! Clients push a `build_summary` JSON to `POST /ingest/summary` and the raw ring
//! rows to `POST /ingest/events`. Agents read the summary through MCP at
//! `POST /mcp/<token>` (or `POST /mcp` with a bearer token). The raw rows live in a
//! second SQLite file with the `oura-store` schema, so the hub is a full replica of
//! the ring data: `oura dashboard --db` runs on it, and `GET /export/events` gives
//! the rows back. The process holds no state outside the two files.

pub mod health;
pub mod mcp;
pub mod store;

use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{json, Value};

use health::HealthBatch;
use mcp::{Reply, Server, Tool};
use oura_store::replication::ExportBatch;
use store::Store;

/// Snapshots kept after each push.
pub const KEEP_SNAPSHOTS: i64 = 500;
/// A summary with per-night series is a few MB. Allow more before it hurts.
pub const MAX_BODY_BYTES: usize = 64 * 1024 * 1024;

pub struct AppState {
    pub store: Arc<Store>,
    /// The ring replica: raw events, readings, devices in the `oura-store` schema.
    pub ring: Mutex<oura_store::Store>,
    pub token: String,
    pub mcp: Server,
}

/// Rows per page on `GET /export/events`.
pub const EXPORT_PAGE: usize = 2000;

pub fn now_unix() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// Constant-time comparison so a timing side channel does not leak the token.
pub fn token_matches(given: &str, expected: &str) -> bool {
    let (a, b) = (given.as_bytes(), expected.as_bytes());
    if a.len() != b.len() || a.is_empty() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(str::trim)
}

fn unauthorized() -> Response {
    (StatusCode::UNAUTHORIZED, Json(json!({ "error": "unauthorized" }))).into_response()
}

/// The MCP tool table over the latest snapshot.
pub fn tools(store_for_handler: Arc<Store>) -> (Vec<Tool>, mcp::Handler) {
    let metrics: Vec<&str> = oura_summary::agent::TREND_METRICS.iter().map(|(m, _)| *m).collect();
    let tools = vec![
        Tool {
            name: "get_status_now",
            description: "The current health status for planning today: last night's sleep, sleep debt, HRV and resting heart rate against baseline, illness signs, today's activity so far, and how fresh the data is. Call this first.",
            input_schema: json!({ "type": "object", "properties": {}, "additionalProperties": false }),
        },
        Tool {
            name: "get_sleep",
            description: "Recent nights, newest first: bed and wake time, time asleep, efficiency, stage percentages, HRV, resting heart rate, skin temperature deviation, awakenings.",
            input_schema: json!({ "type": "object", "properties": {
                "days": { "type": "integer", "minimum": 1, "maximum": 90, "default": 7, "description": "How many nights to return." }
            }, "additionalProperties": false }),
        },
        Tool {
            name: "get_trends",
            description: "One metric per day over a window, oldest first, with the latest value, the window mean, and the personal baseline when one exists.",
            input_schema: json!({ "type": "object", "properties": {
                "metric": { "type": "string", "enum": metrics, "description": "Which metric to return." },
                "days": { "type": "integer", "minimum": 1, "maximum": 365, "default": 14 }
            }, "required": ["metric"], "additionalProperties": false }),
        },
        Tool {
            name: "get_watch",
            description: "Apple Health data pushed from the iPhone, mostly from the Apple Watch: today's and yesterday's steps, active energy, exercise and stand minutes, stand hours; latest heart rate, resting heart rate, HRV (SDNN), VO2 max, respiratory rate, blood oxygen, wrist temperature; the last sleep with stages; workouts in the last 48 h; freshness.",
            input_schema: json!({ "type": "object", "properties": {}, "additionalProperties": false }),
        },
        Tool {
            name: "get_health_samples",
            description: "Raw Apple Health samples of one kind, newest first. Kinds: heart_rate, resting_heart_rate, hrv_sdnn, walking_heart_rate_average, vo2_max, step_count, active_energy, basal_energy, exercise_time, stand_time, stand_hour, distance_walking_running, respiratory_rate, oxygen_saturation, wrist_temperature, sleep_analysis, workout.",
            input_schema: json!({ "type": "object", "properties": {
                "kind": { "type": "string", "description": "Which kind to return." },
                "days": { "type": "integer", "minimum": 1, "maximum": 365, "default": 7 },
                "limit": { "type": "integer", "minimum": 1, "maximum": 5000, "default": 500 }
            }, "required": ["kind"], "additionalProperties": false }),
        },
        Tool {
            name: "get_activity",
            description: "Recent days, newest first: steps, active kcal, total kcal, walking distance.",
            input_schema: json!({ "type": "object", "properties": {
                "days": { "type": "integer", "minimum": 1, "maximum": 90, "default": 7 }
            }, "additionalProperties": false }),
        },
    ];
    let handler: mcp::Handler = Arc::new(move |name, args| {
        let days = |default: u64| args["days"].as_u64().unwrap_or(default).clamp(1, 365) as usize;
        let now = now_unix();
        // Apple Health tools do not need a ring summary.
        let tz_s = |snap: Option<&Value>| snap.and_then(|s| s["tz"].as_i64()).unwrap_or(0) * 3600;
        let watch = |snap: Option<&Value>| -> Result<Value, String> {
            // The last 7 days for totals and means, plus the newest row of every kind
            // so a sparse vital (VO2 max is weekly at best) still has a "latest".
            let mut rows = store_for_handler
                .health_rows(None, now as f64 - 7.0 * 86400.0, 200_000)
                .map_err(|e| format!("store error: {e}"))?;
            let latest = store_for_handler.health_latest_per_kind().map_err(|e| format!("store error: {e}"))?;
            for r in latest {
                if !rows.iter().any(|x| x.uuid == r.uuid) {
                    rows.push(r);
                }
            }
            Ok(health::watch_status(&rows, now, tz_s(snap)))
        };
        if name == "get_watch" {
            let snap = store_for_handler.latest().map_err(|e| format!("store error: {e}"))?;
            return watch(snap.as_ref().map(|s| &s.body));
        }
        if name == "get_health_samples" {
            let kind = args["kind"].as_str().ok_or("kind is required")?;
            let limit = args["limit"].as_u64().unwrap_or(500).clamp(1, 5000) as usize;
            let rows = store_for_handler
                .health_rows(Some(kind), now as f64 - days(7) as f64 * 86400.0, limit)
                .map_err(|e| format!("store error: {e}"))?;
            return Ok(json!({ "kind": kind, "count": rows.len(), "samples": rows }));
        }
        let snap = store_for_handler
            .latest()
            .map_err(|e| format!("store error: {e}"))?
            .ok_or_else(|| "no health data yet: nothing has been pushed to this hub".to_string())?;
        let s = &snap.body;
        match name {
            "get_status_now" => {
                let mut status = oura_summary::agent::status_now(s, now);
                status["watch"] = watch(Some(s))?;
                Ok(status)
            }
            "get_sleep" => Ok(oura_summary::agent::sleep_nights(s, days(7))),
            "get_trends" => {
                let metric = args["metric"].as_str().ok_or("metric is required")?;
                oura_summary::agent::trends(s, metric, days(14))
            }
            "get_activity" => Ok(oura_summary::agent::activity_days(s, days(7))),
            other => Err(format!("unknown tool {other}")),
        }
    });
    (tools, handler)
}

pub fn app_state(store: Store, ring: oura_store::Store, token: String) -> Arc<AppState> {
    let store = Arc::new(store);
    let (tools, handler) = tools(store.clone());
    Arc::new(AppState {
        store,
        ring: Mutex::new(ring),
        token,
        mcp: Server {
            name: "oura-hub",
            version: env!("CARGO_PKG_VERSION"),
            instructions: "Personal health data from an Oura ring. Start with get_status_now. Values carry a freshness block: ring data is as of the last sync, not live.",
            tools,
            handler,
        },
    })
}

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/ingest/summary", post(ingest))
        .route("/ingest/events", post(ingest_events))
        .route("/ingest/health", post(ingest_health))
        .route("/export/events", get(export_events))
        .route("/mcp", post(mcp_bearer).get(mcp_no_stream).delete(mcp_no_stream))
        .route("/mcp/{token}", post(mcp_path).get(mcp_no_stream).delete(mcp_no_stream))
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .with_state(state)
}

/// Liveness for everyone; the details only with the token, because a public tunnel
/// may sit in front and the serials and counts are personal.
async fn health(State(st): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    if !bearer(&headers).is_some_and(|t| token_matches(t, &st.token)) {
        return Json(json!({ "ok": true })).into_response();
    }
    let latest = st.store.latest().ok().flatten();
    let (ring_ids, serials) = {
        let ring = st.ring.lock().unwrap();
        (ring.max_ids().unwrap_or((0, 0)), ring.device_serials().unwrap_or_default())
    };
    Json(json!({
        "ok": true,
        "snapshots": st.store.count().unwrap_or(0),
        "latest_received_at": latest.as_ref().map(|s| s.received_at),
        "latest_generated_at": latest.as_ref().and_then(|s| s.generated_at),
        "ring": {
            "serials": serials,
            "max_event_id": ring_ids.0,
            "max_reading_id": ring_ids.1,
        },
        "health": st.store.health_kinds().unwrap_or_default().iter().map(|(k, n, newest)| {
            json!({ "kind": k, "count": n, "newest_end_unix": *newest as i64 })
        }).collect::<Vec<_>>(),
    }))
    .into_response()
}

/// Apple Health samples from the phone. Upsert by UUID; deletions applied.
async fn ingest_health(State(st): State<Arc<AppState>>, headers: HeaderMap, body: Bytes) -> Response {
    if !bearer(&headers).is_some_and(|t| token_matches(t, &st.token)) {
        return unauthorized();
    }
    let batch: HealthBatch = match serde_json::from_slice(&body) {
        Ok(b) => b,
        Err(e) => return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("invalid health batch: {e}") }))).into_response(),
    };
    match st.store.put_health(&batch, now_unix()) {
        Ok(out) => Json(serde_json::to_value(out).unwrap_or(Value::Null)).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e.to_string() }))).into_response(),
    }
}

/// Raw rows from a phone or desktop store. Idempotent: the replica keeps its own
/// ids and ignores rows it already holds.
async fn ingest_events(State(st): State<Arc<AppState>>, headers: HeaderMap, body: Bytes) -> Response {
    if !bearer(&headers).is_some_and(|t| token_matches(t, &st.token)) {
        return unauthorized();
    }
    let batch: ExportBatch = match serde_json::from_slice(&body) {
        Ok(b) => b,
        Err(e) => return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("invalid batch: {e}") }))).into_response(),
    };
    if batch.schema_version > oura_store::storage::SCHEMA_VERSION {
        return (StatusCode::UNPROCESSABLE_ENTITY, Json(json!({
            "error": format!("batch schema {} is newer than this hub's {}; update the hub",
                             batch.schema_version, oura_store::storage::SCHEMA_VERSION)
        }))).into_response();
    }
    let outcome = {
        let ring = st.ring.lock().unwrap();
        ring.import_batch(&batch)
    };
    match outcome {
        Ok(out) => Json(serde_json::to_value(out).unwrap_or(Value::Null)).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e.to_string() }))).into_response(),
    }
}

#[derive(serde::Deserialize, Default)]
struct ExportQuery {
    after_event_id: Option<i64>,
    after_reading_id: Option<i64>,
    limit: Option<usize>,
}

/// The replica's rows back out, in pages: restore a phone or a desktop from the hub.
async fn export_events(State(st): State<Arc<AppState>>, headers: HeaderMap, Query(q): Query<ExportQuery>) -> Response {
    if !bearer(&headers).is_some_and(|t| token_matches(t, &st.token)) {
        return unauthorized();
    }
    let batch = {
        let ring = st.ring.lock().unwrap();
        ring.export_after(q.after_event_id.unwrap_or(0), q.after_reading_id.unwrap_or(0),
                          q.limit.unwrap_or(EXPORT_PAGE).min(EXPORT_PAGE))
    };
    match batch {
        Ok(b) => Json(serde_json::to_value(b).unwrap_or(Value::Null)).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e.to_string() }))).into_response(),
    }
}

async fn ingest(State(st): State<Arc<AppState>>, headers: HeaderMap, body: Bytes) -> Response {
    if !bearer(&headers).is_some_and(|t| token_matches(t, &st.token)) {
        return unauthorized();
    }
    let value: Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(e) => return (StatusCode::BAD_REQUEST, Json(json!({ "error": format!("invalid JSON: {e}") }))).into_response(),
    };
    if !value.is_object() || value.get("nights").is_none() {
        return (StatusCode::UNPROCESSABLE_ENTITY, Json(json!({ "error": "expected a build_summary object with a nights field" }))).into_response();
    }
    let received_at = now_unix();
    match st.store.put(&value, received_at) {
        Ok(out) => {
            let _ = st.store.prune(KEEP_SNAPSHOTS);
            Json(json!({
                "stored": out.stored,
                "sha256": out.sha256,
                "received_at": received_at,
                "generated_at": value.get("generated_at"),
                "snapshots": out.snapshots.min(KEEP_SNAPSHOTS),
            }))
            .into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e.to_string() }))).into_response(),
    }
}

fn mcp_reply(st: &AppState, body: &[u8]) -> Response {
    match st.mcp.handle_bytes(body) {
        Reply::Json(v) => Json(v).into_response(),
        Reply::Accepted => StatusCode::ACCEPTED.into_response(),
    }
}

async fn mcp_bearer(State(st): State<Arc<AppState>>, headers: HeaderMap, body: Bytes) -> Response {
    if !bearer(&headers).is_some_and(|t| token_matches(t, &st.token)) {
        return unauthorized();
    }
    mcp_reply(&st, &body)
}

async fn mcp_path(State(st): State<Arc<AppState>>, Path(token): Path<String>, body: Bytes) -> Response {
    if !token_matches(&token, &st.token) {
        return unauthorized();
    }
    mcp_reply(&st, &body)
}

/// No server-initiated stream and no sessions to terminate.
async fn mcp_no_stream() -> Response {
    StatusCode::METHOD_NOT_ALLOWED.into_response()
}
