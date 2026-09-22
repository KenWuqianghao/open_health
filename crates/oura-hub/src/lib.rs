//! The always-on health hub.
//!
//! Clients push a `build_summary` JSON to `POST /ingest/summary`. Agents read it
//! through MCP at `POST /mcp/<token>` (or `POST /mcp` with a bearer token). The
//! process holds no state outside the SQLite file, so it restarts cleanly.

pub mod mcp;
pub mod store;

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{json, Value};

use mcp::{Reply, Server, Tool};
use store::Store;

/// Snapshots kept after each push.
pub const KEEP_SNAPSHOTS: i64 = 500;
/// A summary with per-night series is a few MB. Allow more before it hurts.
pub const MAX_BODY_BYTES: usize = 64 * 1024 * 1024;

pub struct AppState {
    pub store: Arc<Store>,
    pub token: String,
    pub mcp: Server,
}

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
            name: "get_activity",
            description: "Recent days, newest first: steps, active kcal, total kcal, walking distance.",
            input_schema: json!({ "type": "object", "properties": {
                "days": { "type": "integer", "minimum": 1, "maximum": 90, "default": 7 }
            }, "additionalProperties": false }),
        },
    ];
    let handler: mcp::Handler = Arc::new(move |name, args| {
        let snap = store_for_handler
            .latest()
            .map_err(|e| format!("store error: {e}"))?
            .ok_or_else(|| "no health data yet: nothing has been pushed to this hub".to_string())?;
        let days = |default: u64| args["days"].as_u64().unwrap_or(default).clamp(1, 365) as usize;
        let s = &snap.body;
        match name {
            "get_status_now" => Ok(oura_summary::agent::status_now(s, now_unix())),
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

pub fn app_state(store: Store, token: String) -> Arc<AppState> {
    let store = Arc::new(store);
    let (tools, handler) = tools(store.clone());
    Arc::new(AppState {
        store,
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
        .route("/mcp", post(mcp_bearer).get(mcp_no_stream).delete(mcp_no_stream))
        .route("/mcp/{token}", post(mcp_path).get(mcp_no_stream).delete(mcp_no_stream))
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
        .with_state(state)
}

async fn health(State(st): State<Arc<AppState>>) -> Response {
    let latest = st.store.latest().ok().flatten();
    Json(json!({
        "ok": true,
        "snapshots": st.store.count().unwrap_or(0),
        "latest_received_at": latest.as_ref().map(|s| s.received_at),
        "latest_generated_at": latest.as_ref().and_then(|s| s.generated_at),
    }))
    .into_response()
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
