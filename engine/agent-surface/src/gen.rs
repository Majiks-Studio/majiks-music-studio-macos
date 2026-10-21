//! Gen proxy tools: forward to L4's Gen Protocol service. PROXY ONLY - this
//! lane implements no generation. The one endpoint agents configure is this
//! MCP server; gen requests hop to the Gen Protocol RPC (the Python backend /
//! Majiks Gen Node) named by `MAJIKS_GEN_RPC_URL`.
//!
//! When the endpoint is not configured, every gen tool returns a clear,
//! honest `not configured` result rather than inventing a job id, so an agent
//! knows the difference between "queued" and "no backend here". The forwarder
//! is std-only (a tiny HTTP/1.1 POST) so it compiles in the CLI build too.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use serde_json::{json, Value};

use crate::error::StudioError;

const GEN_RPC_ENV: &str = "MAJIKS_GEN_RPC_URL";

/// Route a gen_* tool to the Gen Protocol service.
pub fn dispatch(tool: &str, args: &Value) -> Result<Value, StudioError> {
    let method = match tool {
        "gen_submit" => "gen.submit",
        "gen_status" => "gen.status",
        "gen_cancel" => "gen.cancel",
        "gen_capabilities" => "gen.capabilities",
        other => return Err(StudioError::Gen(format!("unknown gen tool: {other}"))),
    };
    match std::env::var(GEN_RPC_ENV) {
        Ok(url) if !url.trim().is_empty() => forward(&url, method, args.clone()),
        _ => Ok(json!({
            "ok": false,
            "configured": false,
            "note": format!(
                "gen backend not configured (set {GEN_RPC_ENV}); the engine surface proxies generation to L4's Gen Protocol, it does not generate"
            ),
        })),
    }
}

/// Minimal JSON-RPC-over-HTTP POST to the gen endpoint (std only, no async).
fn forward(url: &str, method: &str, params: Value) -> Result<Value, StudioError> {
    let (host, port, path) = parse_http_url(url)?;
    let body = json!({
        "jsonrpc": "2.0",
        "id": crate::ulid::new_ulid(),
        "method": method,
        "params": params,
    })
    .to_string();

    let addr = format!("{host}:{port}");
    let mut stream = TcpStream::connect(&addr)
        .map_err(|e| StudioError::Gen(format!("connect {addr}: {e}")))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(30)))
        .ok();
    let request = format!(
        "POST {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(request.as_bytes())
        .map_err(|e| StudioError::Gen(format!("send: {e}")))?;

    let mut raw = Vec::new();
    stream
        .read_to_end(&mut raw)
        .map_err(|e| StudioError::Gen(format!("read: {e}")))?;
    let text = String::from_utf8_lossy(&raw);
    let body = text
        .split_once("\r\n\r\n")
        .map(|(_, b)| b)
        .unwrap_or(&text);
    let value: Value = serde_json::from_str(body.trim())
        .map_err(|e| StudioError::Gen(format!("bad gen response: {e}")))?;
    Ok(value)
}

/// Parse `http://host:port/path` into (host, port, path). https and other
/// schemes are rejected here (localhost/tailnet plaintext is the deployment).
fn parse_http_url(url: &str) -> Result<(String, u16, String), StudioError> {
    let rest = url
        .strip_prefix("http://")
        .ok_or_else(|| StudioError::Gen(format!("gen url must be http://: {url}")))?;
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) => (
            h.to_string(),
            p.parse::<u16>().map_err(|_| StudioError::Gen(format!("bad port in {url}")))?,
        ),
        None => (authority.to_string(), 80),
    };
    Ok((host, port, path.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unconfigured_gen_is_honest_not_a_fake_job() {
        // Ensure the env is unset for this test.
        std::env::remove_var(GEN_RPC_ENV);
        let out = dispatch("gen_submit", &json!({ "op": "generate", "request": {} })).unwrap();
        assert_eq!(out["ok"], json!(false));
        assert_eq!(out["configured"], json!(false));
    }

    #[test]
    fn url_parsing() {
        assert_eq!(
            parse_http_url("http://127.0.0.1:8199/rpc").unwrap(),
            ("127.0.0.1".to_string(), 8199, "/rpc".to_string())
        );
        assert!(parse_http_url("https://x/y").is_err());
    }
}
