
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use tower::ServiceExt;

use oura_hub::store::Store;

const TOKEN: &str = "0123456789abcdef0123456789abcdef";

fn app() -> axum::Router {
    oura_hub::router(oura_hub::app_state(Store::in_memory().unwrap(), TOKEN.into()))
}

fn summary() -> Value {
    json!({
        "generated_at": 1_700_000_000.0,
        "tz": 8,
        "device": { "fresh_hours": 1.0, "battery_pct": 70, "nights": 1 },
        "nights": [{ "ymd": "2023-11-14", "start": "23:00", "end": "07:00", "in_bed_h": 8.0, "efficiency": 90.0,
                     "hrv_ms": 50.0, "rhr": 50.0, "metrics": { "asleep_min": 420.0 } }],
        "sleep_debt": { "state": "none", "debt_min": 0.0, "valid": true },
        "vitals": { "hrv": { "latest": 50.0, "baseline": 48.0, "delta_pct": 4.0 }, "rhr": { "latest": 50.0 } },
        "activity_daily": { "2023-11-14": { "steps": 5000.0, "active_kcal": 300.0, "total_kcal": 2000.0, "distance_m": 3810.0 } }
    })
}

async fn send(app: &axum::Router, req: Request<Body>) -> (StatusCode, Value) {
    let res = app.clone().oneshot(req).await.unwrap();
    let status = res.status();
    let bytes = res.into_body().collect().await.unwrap().to_bytes();
    let body = if bytes.is_empty() { Value::Null } else { serde_json::from_slice(&bytes).unwrap() };
    (status, body)
}

fn post(uri: &str, auth: Option<&str>, body: Value) -> Request<Body> {
    let mut b = Request::post(uri).header("content-type", "application/json");
    if let Some(a) = auth {
        b = b.header("authorization", format!("Bearer {a}"));
    }
    b.body(Body::from(body.to_string())).unwrap()
}

fn rpc(id: u64, method: &str, params: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
}

#[tokio::test]
async fn ingest_needs_the_bearer_token() {
    let app = app();
    let (s, _) = send(&app, post("/ingest/summary", None, summary())).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, _) = send(&app, post("/ingest/summary", Some("wrong"), summary())).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, body) = send(&app, post("/ingest/summary", Some(TOKEN), json!({ "hello": 1 }))).await;
    assert_eq!(s, StatusCode::UNPROCESSABLE_ENTITY);
    assert!(body["error"].as_str().unwrap().contains("nights"));
}

#[tokio::test]
async fn ingest_then_health_then_tools() {
    let app = app();
    let (s, h) = send(&app, Request::get("/health").body(Body::empty()).unwrap()).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(h["snapshots"], 0);

    let (s, out) = send(&app, post("/ingest/summary", Some(TOKEN), summary())).await;
    assert_eq!(s, StatusCode::OK, "{out}");
    assert_eq!(out["stored"], true);
    assert_eq!(out["generated_at"], 1_700_000_000.0);
    let (_, again) = send(&app, post("/ingest/summary", Some(TOKEN), summary())).await;
    assert_eq!(again["stored"], false);

    let (_, h) = send(&app, Request::get("/health").body(Body::empty()).unwrap()).await;
    assert_eq!(h["snapshots"], 1);
    assert_eq!(h["latest_generated_at"], 1_700_000_000.0);

    // token in the path, as Grok Bot's url-only config needs
    let uri = format!("/mcp/{TOKEN}");
    let (s, r) = send(&app, post(&uri, None, rpc(1, "initialize", json!({ "protocolVersion": "2025-06-18" })))).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(r["result"]["serverInfo"]["name"], "oura-hub");

    let (s, _) = send(&app, post(&uri, None, json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }))).await;
    assert_eq!(s, StatusCode::ACCEPTED);

    let (_, r) = send(&app, post(&uri, None, rpc(2, "tools/list", json!({})))).await;
    let names: Vec<&str> = r["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["get_status_now", "get_sleep", "get_trends", "get_activity"]);

    let (_, r) = send(&app, post(&uri, None, rpc(3, "tools/call", json!({ "name": "get_status_now", "arguments": {} })))).await;
    assert_eq!(r["result"]["isError"], false, "{r}");
    let status = &r["result"]["structuredContent"];
    assert_eq!(status["last_night"]["ymd"], "2023-11-14");
    assert_eq!(status["vitals"]["hrv_ms"]["baseline"], 48.0);
    assert!(status["freshness"]["summary_age_min"].as_f64().unwrap() > 0.0);

    let (_, r) = send(&app, post(&uri, None, rpc(4, "tools/call", json!({ "name": "get_trends", "arguments": { "metric": "steps", "days": 3 } })))).await;
    assert_eq!(r["result"]["structuredContent"]["points"][0]["value"], 5000.0);

    let (_, r) = send(&app, post(&uri, None, rpc(5, "tools/call", json!({ "name": "get_trends", "arguments": { "metric": "mood" } })))).await;
    assert_eq!(r["result"]["isError"], true);
}

#[tokio::test]
async fn mcp_auth_paths_and_methods() {
    let app = app();
    let init = rpc(1, "tools/call", json!({ "name": "get_status_now" }));
    let (s, _) = send(&app, post("/mcp", None, init.clone())).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    let (s, _) = send(&app, post("/mcp/not-the-token", None, init.clone())).await;
    assert_eq!(s, StatusCode::UNAUTHORIZED);
    // bearer on /mcp works, and an empty hub answers with a tool error, not a crash
    let (s, r) = send(&app, post("/mcp", Some(TOKEN), init)).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(r["result"]["isError"], true);
    assert!(r["result"]["content"][0]["text"].as_str().unwrap().contains("no health data yet"));
    // no SSE stream, no session delete
    let (s, _) = send(&app, Request::get(format!("/mcp/{TOKEN}")).body(Body::empty()).unwrap()).await;
    assert_eq!(s, StatusCode::METHOD_NOT_ALLOWED);
    let (s, _) = send(&app, Request::delete("/mcp").body(Body::empty()).unwrap()).await;
    assert_eq!(s, StatusCode::METHOD_NOT_ALLOWED);
    // a broken body is a JSON-RPC parse error with HTTP 200
    let req = Request::post(format!("/mcp/{TOKEN}")).body(Body::from("{oops")).unwrap();
    let (s, r) = send(&app, req).await;
    assert_eq!(s, StatusCode::OK);
    assert_eq!(r["error"]["code"], -32700);
}

#[test]
fn token_compare_is_strict() {
    assert!(oura_hub::token_matches("abc", "abc"));
    assert!(!oura_hub::token_matches("ab", "abc"));
    assert!(!oura_hub::token_matches("abd", "abc"));
    assert!(!oura_hub::token_matches("", ""));
}
