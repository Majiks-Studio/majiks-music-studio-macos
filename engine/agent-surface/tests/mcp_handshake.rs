//! Live MCP handshake proof over real HTTP (the "curl-proven initialize +
//! tools/list showing all tool inputSchemas" acceptance). Starts the server on
//! a free port, then: health, auth rejection, initialize, tools/list (count +
//! every inputSchema), a read tool, a write tool, and the Manage confirm gate.
//!
//! Only built with `--features mcp`.
#![cfg(feature = "mcp")]

use std::sync::{Arc, Mutex};

use serde_json::{json, Value};

use agent_surface::mcp::{start, McpConfig, McpServer};
use agent_surface::registry;
use agent_surface::StudioHost;

/// Pick a free localhost port by binding :0 and reading it back.
fn free_port() -> u16 {
    std::net::TcpListener::bind(("127.0.0.1", 0))
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// Streamable-HTTP responses may be a raw JSON body or SSE (`data: {...}`);
/// return the last JSON object found either way.
fn extract_json(body: &str) -> Value {
    let trimmed = body.trim_start();
    if trimmed.starts_with('{') {
        if let Ok(v) = serde_json::from_str::<Value>(trimmed) {
            return v;
        }
    }
    let mut last = Value::Null;
    for line in body.lines() {
        if let Some(rest) = line.strip_prefix("data:") {
            if let Ok(v) = serde_json::from_str::<Value>(rest.trim()) {
                last = v;
            }
        }
    }
    last
}

struct Client {
    http: reqwest::blocking::Client,
    base: String,
    pat: String,
    session: Option<String>,
}

impl Client {
    fn post(&mut self, body: Value) -> (reqwest::StatusCode, String) {
        let mut req = self
            .http
            .post(format!("{}/mcp", self.base))
            .header("Authorization", format!("Bearer {}", self.pat))
            .header("Accept", "application/json, text/event-stream")
            .header("Content-Type", "application/json");
        if let Some(sid) = &self.session {
            req = req.header("Mcp-Session-Id", sid);
        }
        let resp = req.json(&body).send().expect("post");
        let status = resp.status();
        if self.session.is_none() {
            if let Some(sid) = resp.headers().get("mcp-session-id") {
                self.session = Some(sid.to_str().unwrap().to_string());
            }
        }
        (status, resp.text().unwrap_or_default())
    }
}

#[test]
fn mcp_server_handshake_and_tools_list() {
    let host = Arc::new(Mutex::new(StudioHost::in_memory()));
    let port = free_port();
    let pat = "mms_test_pat_l6".to_string();
    let handle = start(
        Arc::clone(&host),
        McpConfig { enabled: true, port },
        pat.clone(),
    )
    .expect("server starts");
    // Give the tokio task a moment to bind/serve.
    std::thread::sleep(std::time::Duration::from_millis(250));

    let base = format!("http://127.0.0.1:{port}");
    let http = reqwest::blocking::Client::new();

    // 1. health is open; the MCP path demands a bearer.
    let health = http.get(format!("{base}/health")).send().unwrap();
    assert!(health.status().is_success());
    assert_eq!(health.text().unwrap(), "ok");

    let unauth = http
        .post(format!("{base}/mcp"))
        .header("Accept", "application/json, text/event-stream")
        .json(&json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize" }))
        .send()
        .unwrap();
    assert_eq!(unauth.status(), reqwest::StatusCode::UNAUTHORIZED, "missing bearer must 401");

    let mut client = Client { http, base, pat, session: None };

    // 2. initialize
    let (st, body) = client.post(json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": { "name": "l6-handshake", "version": "0" }
        }
    }));
    assert!(st.is_success(), "initialize status {st}: {body}");
    let init = extract_json(&body);
    assert!(
        init.pointer("/result/serverInfo").is_some() || init.pointer("/result/capabilities").is_some(),
        "initialize result missing: {init}"
    );
    assert!(client.session.is_some(), "server assigned no session id");

    // The handshake is the ONLY place a client is told anything before it has
    // to start guessing, and both of these fields were left at the rmcp
    // defaults: `serverInfo.name` came from `Implementation::from_build_env()`,
    // so a client that reached the studio was told it had reached
    // "agent-surface", and `instructions` was absent, so a client meeting 146
    // flat `studio_*` names got no hint that a project has to be open first or
    // that a read half exists at all.
    assert_eq!(
        init.pointer("/result/serverInfo/name").and_then(Value::as_str),
        Some("majiks-studio"),
        "serverInfo names something other than this app: {init}"
    );
    let instructions = init
        .pointer("/result/instructions")
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("initialize carries no instructions: {init}"));
    // Assert the CONTENT, not merely that a string is present: an empty or
    // placeholder briefing would satisfy "has instructions" and orient nobody.
    for expected in [
        "studio_capabilities",
        "studio_snapshot",
        "studio_project_open",
        "confirm: true",
    ] {
        assert!(
            instructions.contains(expected),
            "server instructions never mention {expected}"
        );
    }

    // 3. notifications/initialized (no id).
    let _ = client.post(json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }));

    // 4. tools/list must expose every generated tool WITH an inputSchema.
    let (st, body) = client.post(json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list" }));
    assert!(st.is_success(), "tools/list status {st}");
    let listed = extract_json(&body);
    let tools = listed
        .pointer("/result/tools")
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("no tools array in {listed}"));
    assert_eq!(
        tools.len(),
        registry::tool_defs().len(),
        "tools/list count != registry"
    );
    let names: std::collections::HashSet<&str> =
        tools.iter().filter_map(|t| t["name"].as_str()).collect();
    for def in registry::tool_defs() {
        assert!(names.contains(def.name.as_str()), "tools/list missing {}", def.name);
    }
    for t in tools {
        assert_eq!(
            t.pointer("/inputSchema/type").and_then(Value::as_str),
            Some("object"),
            "tool {} has no object inputSchema",
            t["name"]
        );
        // A schema says what is LEGAL; the description is the only part that
        // says what the tool DOES. A tool that arrives with an empty one is
        // unusable without reading this repository, which is the failure the
        // whole generated-from-the-catalog design exists to avoid.
        //
        // The bar is a SENTENCE, not a length. The shortest description in the
        // catalog is "Stop playback." (14 chars) and it is a completely adequate
        // one — a character threshold generous enough to reject a placeholder
        // also rejects the terse verbs, so it would measure verbosity rather
        // than presence. Median is 123 characters; the floor here is only
        // guarding against empty, one-word, and TODO-shaped strings.
        let desc = t["description"].as_str().unwrap_or("");
        assert!(
            desc.contains(' ') && desc.trim_end().ends_with('.'),
            "tool {} arrives with no usable description: {desc:?}",
            t["name"]
        );
    }

    // 5. a read tool round-trips (studio_snapshot).
    let (st, body) = client.post(json!({
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": { "name": "studio_snapshot", "arguments": {} }
    }));
    assert!(st.is_success());
    let snap = extract_json(&body);
    assert!(snap.pointer("/result").is_some(), "snapshot call result: {snap}");

    // 6. a write tool mutates through the bus (studio_track_add).
    let (_st, body) = client.post(json!({
        "jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": { "name": "studio_track_add", "arguments": { "trackId": "t1", "name": "Drums" } }
    }));
    let added = extract_json(&body);
    let is_error = added.pointer("/result/isError").and_then(Value::as_bool).unwrap_or(false);
    assert!(!is_error, "track.add should succeed: {added}");
    assert_eq!(host.lock().unwrap().project().tracks.len(), 1, "bus mutated via MCP");

    // 7. Manage confirm gate: track.remove without confirm is rejected.
    let (_st, body) = client.post(json!({
        "jsonrpc": "2.0", "id": 5, "method": "tools/call",
        "params": { "name": "studio_track_remove", "arguments": { "trackId": "t1" } }
    }));
    let removed = extract_json(&body);
    let is_error = removed.pointer("/result/isError").and_then(Value::as_bool).unwrap_or(false);
    assert!(is_error, "track.remove without confirm must be rejected: {removed}");
    assert_eq!(host.lock().unwrap().project().tracks.len(), 1, "no delete without confirm");

    drop(handle);
}

#[test]
fn tool_specs_all_have_object_schemas() {
    let server = McpServer::new(Arc::new(Mutex::new(StudioHost::in_memory())));
    for t in server.tool_specs() {
        assert_eq!(
            t.input_schema.get("type").and_then(Value::as_str),
            Some("object"),
            "{}",
            t.name
        );
    }
}
