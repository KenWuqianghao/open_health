//! A stateless MCP server over JSON-RPC 2.0 (Streamable HTTP transport, JSON
//! replies only). One request in, one reply out. No sessions, no SSE stream, no
//! batching: the 2025-06-18 revision removed JSON-RPC batching.

use std::sync::Arc;

use serde_json::{json, Value};

pub const PROTOCOL_VERSIONS: &[&str] = &["2025-06-18", "2025-03-26", "2024-11-05"];

pub struct Tool {
    pub name: &'static str,
    pub description: &'static str,
    pub input_schema: Value,
}

/// Runs a tool by name. `Err(text)` becomes an `isError` tool result, not a
/// JSON-RPC error: the model should see the message.
pub type Handler = Arc<dyn Fn(&str, &Value) -> Result<Value, String> + Send + Sync>;

pub struct Server {
    pub name: &'static str,
    pub version: &'static str,
    pub instructions: &'static str,
    pub tools: Vec<Tool>,
    pub handler: Handler,
}

/// What the transport sends back.
#[derive(Debug, PartialEq)]
pub enum Reply {
    /// A JSON-RPC response (result or error). HTTP 200.
    Json(Value),
    /// A notification was accepted. HTTP 202, no body.
    Accepted,
}

fn error(id: Value, code: i64, message: impl Into<String>) -> Reply {
    Reply::Json(json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message.into() } }))
}

fn result(id: Value, result: Value) -> Reply {
    Reply::Json(json!({ "jsonrpc": "2.0", "id": id, "result": result }))
}

impl Server {
    /// Handle one HTTP body.
    pub fn handle_bytes(&self, body: &[u8]) -> Reply {
        match serde_json::from_slice::<Value>(body) {
            Ok(v) => self.handle(&v),
            Err(e) => error(Value::Null, -32700, format!("parse error: {e}")),
        }
    }

    pub fn handle(&self, msg: &Value) -> Reply {
        let Some(obj) = msg.as_object() else {
            return error(Value::Null, -32600, "invalid request: expected a JSON-RPC object (batches are not supported)");
        };
        let id = obj.get("id").cloned().unwrap_or(Value::Null);
        let Some(method) = obj.get("method").and_then(Value::as_str) else {
            return error(id, -32600, "invalid request: missing method");
        };
        let params = obj.get("params").cloned().unwrap_or(Value::Null);
        let is_notification = obj.get("id").is_none();

        if method.starts_with("notifications/") {
            return Reply::Accepted;
        }
        if is_notification {
            // A request without an id gets no reply by the JSON-RPC rules.
            return Reply::Accepted;
        }
        match method {
            "initialize" => {
                let asked = params["protocolVersion"].as_str().unwrap_or("");
                let version = if PROTOCOL_VERSIONS.contains(&asked) { asked } else { PROTOCOL_VERSIONS[0] };
                result(
                    id,
                    json!({
                        "protocolVersion": version,
                        "capabilities": { "tools": { "listChanged": false } },
                        "serverInfo": { "name": self.name, "version": self.version },
                        "instructions": self.instructions,
                    }),
                )
            }
            "ping" => result(id, json!({})),
            "tools/list" => result(
                id,
                json!({
                    "tools": self.tools.iter().map(|t| json!({
                        "name": t.name,
                        "description": t.description,
                        "inputSchema": t.input_schema,
                    })).collect::<Vec<_>>()
                }),
            ),
            "tools/call" => {
                let Some(name) = params["name"].as_str() else {
                    return error(id, -32602, "invalid params: missing tool name");
                };
                if !self.tools.iter().any(|t| t.name == name) {
                    return error(id, -32602, format!("unknown tool {name:?}"));
                }
                let args = params.get("arguments").cloned().unwrap_or(json!({}));
                match (self.handler)(name, &args) {
                    Ok(value) => result(
                        id,
                        json!({
                            "content": [{ "type": "text", "text": value.to_string() }],
                            "structuredContent": value,
                            "isError": false,
                        }),
                    ),
                    Err(text) => result(
                        id,
                        json!({ "content": [{ "type": "text", "text": text }], "isError": true }),
                    ),
                }
            }
            "resources/list" | "prompts/list" => {
                // Not advertised, but some clients probe anyway. An empty list is
                // friendlier than -32601.
                let key = if method == "resources/list" { "resources" } else { "prompts" };
                result(id, json!({ key: [] }))
            }
            other => error(id, -32601, format!("method not found: {other}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server() -> Server {
        Server {
            name: "test",
            version: "0",
            instructions: "hi",
            tools: vec![Tool {
                name: "echo",
                description: "echoes",
                input_schema: json!({ "type": "object", "properties": { "x": { "type": "number" } } }),
            }],
            handler: Arc::new(|name, args| match name {
                "echo" if args["x"].is_null() => Err("x is required".into()),
                "echo" => Ok(json!({ "x": args["x"] })),
                _ => unreachable!(),
            }),
        }
    }

    fn json(reply: Reply) -> Value {
        match reply {
            Reply::Json(v) => v,
            Reply::Accepted => panic!("expected a JSON reply"),
        }
    }

    #[test]
    fn initialize_negotiates_the_version() {
        let s = server();
        let r = json(s.handle(&json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": { "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": { "name": "c", "version": "1" } } })));
        assert_eq!(r["id"], 1);
        assert_eq!(r["result"]["protocolVersion"], "2025-03-26");
        assert_eq!(r["result"]["serverInfo"]["name"], "test");
        let r = json(s.handle(&json!({ "jsonrpc": "2.0", "id": 2, "method": "initialize", "params": { "protocolVersion": "1999-01-01" } })));
        assert_eq!(r["result"]["protocolVersion"], "2025-06-18");
    }

    #[test]
    fn notifications_are_accepted_without_a_body() {
        let s = server();
        assert_eq!(s.handle(&json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })), Reply::Accepted);
    }

    #[test]
    fn tools_list_and_call() {
        let s = server();
        let r = json(s.handle(&json!({ "jsonrpc": "2.0", "id": "a", "method": "tools/list" })));
        assert_eq!(r["result"]["tools"][0]["name"], "echo");
        assert_eq!(r["result"]["tools"][0]["inputSchema"]["type"], "object");

        let r = json(s.handle(&json!({ "jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": { "name": "echo", "arguments": { "x": 4 } } })));
        assert_eq!(r["result"]["isError"], false);
        assert_eq!(r["result"]["structuredContent"]["x"], 4);
        assert_eq!(r["result"]["content"][0]["text"], "{\"x\":4}");

        let r = json(s.handle(&json!({ "jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": { "name": "echo" } })));
        assert_eq!(r["result"]["isError"], true);
        assert_eq!(r["result"]["content"][0]["text"], "x is required");

        let r = json(s.handle(&json!({ "jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": { "name": "nope" } })));
        assert_eq!(r["error"]["code"], -32602);
    }

    #[test]
    fn bad_input_maps_to_jsonrpc_errors() {
        let s = server();
        assert_eq!(json(s.handle_bytes(b"{not json"))["error"]["code"], -32700);
        assert_eq!(json(s.handle(&json!([1, 2])))["error"]["code"], -32600);
        assert_eq!(json(s.handle(&json!({ "jsonrpc": "2.0", "id": 9, "method": "nope" })))["error"]["code"], -32601);
        assert_eq!(json(s.handle(&json!({ "jsonrpc": "2.0", "id": 9, "method": "ping" })))["result"], json!({}));
    }
}
