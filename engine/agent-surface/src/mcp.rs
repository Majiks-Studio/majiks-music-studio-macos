//! The one MCP server for the app: an rmcp localhost streamable-HTTP server on
//! a FIXED FREE PORT (8478, distinct from Majik's DJ's 8471), bearer PAT, OFF
//! by default. Tools come straight from the generated registry, so the surface
//! can never drift from the command bus. Dispatch order mirrors the DJ server:
//! validate args (in `dispatch_tool`) -> tier confirm gate -> write rate limit
//! -> route to the host instance.
//!
//! Boot honors the persisted enable flag and fails closed: `start` refuses
//! unless `enabled` is set and a non-empty PAT is present.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use rmcp::model::{
    CallToolResult, ContentBlock, ErrorCode, ErrorData, JsonObject, ListToolsResult,
    ServerCapabilities, ServerInfo, Tool, ToolAnnotations,
};
use rmcp::service::{RequestContext, RoleServer};
use rmcp::transport::streamable_http_server::{
    session::local::LocalSessionManager, StreamableHttpServerConfig, StreamableHttpService,
};
use rmcp::ServerHandler;
use serde_json::{json, Value};
use tokio::net::TcpListener;
use tokio::runtime::Runtime;
use tokio::sync::oneshot;

use timeline_core::envelope::ActorKind;
use timeline_core::Actor;

use crate::error::StudioError;
use crate::host::StudioHost;
use crate::registry::{self, ToolDef, ToolTier};

/// The fixed, free MCP port for Majik's Music Studio. Chosen distinct from the
/// DJ server (8471) so both apps' servers can run side by side on one machine.
pub const DEFAULT_MCP_PORT: u16 = 8478;
pub const MCP_HTTP_PATH: &str = "/mcp";

/// Minimum spacing between write (Perform/Manage) tool calls. Reads are free.
const WRITE_RATE_LIMIT_MS: u64 = 10;

#[derive(Debug, Clone)]
pub struct McpConfig {
    /// Persisted enable flag (Settings). Boot fails closed when false.
    pub enabled: bool,
    pub port: u16,
}

impl Default for McpConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            port: DEFAULT_MCP_PORT,
        }
    }
}

/// The rmcp handler. One instance per session (cloned by the service factory);
/// all clones share the single host instance and the one rate-limit clock.
#[derive(Clone)]
pub struct McpServer {
    host: Arc<Mutex<StudioHost>>,
    last_write: Arc<Mutex<Option<Instant>>>,
}

impl McpServer {
    pub fn new(host: Arc<Mutex<StudioHost>>) -> Self {
        Self {
            host,
            last_write: Arc::new(Mutex::new(None)),
        }
    }

    /// The generated tool specs as rmcp `Tool`s (schemas verbatim from the
    /// registry; annotations follow the tier: read_only<=>Read, destructive<=>
    /// Manage).
    pub fn tool_specs(&self) -> Vec<Tool> {
        registry::tool_defs().iter().map(tool_spec).collect()
    }

    fn check_write_rate_limit(&self, tier: ToolTier) -> Result<(), StudioError> {
        if tier == ToolTier::Read {
            return Ok(());
        }
        let mut last = self
            .last_write
            .lock()
            .map_err(|_| StudioError::invalid("rate limiter poisoned"))?;
        let now = Instant::now();
        if let Some(prev) = *last {
            if now.duration_since(prev) < Duration::from_millis(WRITE_RATE_LIMIT_MS) {
                return Err(StudioError::RateLimited(format!(
                    "write tools are rate limited to one per {WRITE_RATE_LIMIT_MS}ms"
                )));
            }
        }
        *last = Some(now);
        Ok(())
    }

    /// The synchronous core of a tool call: rate limit, then dispatch to the
    /// host under the lock (no `.await` while locked, so the future stays Send).
    fn run_tool(&self, name: &str, args: Value) -> Result<Value, StudioError> {
        let def = registry::tool_by_name(name)
            .ok_or_else(|| StudioError::invalid(format!("unknown tool: {name}")))?;
        self.check_write_rate_limit(def.tier)?;
        let actor = Actor {
            kind: ActorKind::Agent,
            name: "mcp".to_string(),
        };
        let mut host = self
            .host
            .lock()
            .map_err(|_| StudioError::invalid("host lock poisoned"))?;
        crate::dispatch::dispatch_def(&mut host, actor, &def, args)
    }
}

fn tool_spec(def: &ToolDef) -> Tool {
    let schema: JsonObject = def
        .input_schema
        .as_object()
        .cloned()
        .unwrap_or_default();
    let mut ann = ToolAnnotations::default();
    if def.tier == ToolTier::Read {
        ann = ann.read_only(true);
    }
    if def.tier == ToolTier::Manage {
        ann = ann.destructive(true);
    }
    Tool::new(def.name.clone(), def.description.clone(), schema).with_annotations(ann)
}

/// What an MCP client is told at `initialize`, before it has called anything.
///
/// A tool list is a vocabulary, not a briefing. Every tool here carries a good
/// description — they are generated from the catalog, which documents the WHY of
/// each command heavily — but a client meeting this server sees a flat wall of
/// `studio_*` names with no way to tell which four of them are the ones you need
/// first, that ids are minted by the CALLER, or that there is a read half at
/// all. The three things below are exactly the ones that cost an agent a failed
/// call each to discover, and MCP has a field for saying them once.
const SERVER_INSTRUCTIONS: &str = "\
Majik's Music Studio: a digital audio workstation driven entirely through a journalled command bus, \
so a human gesture and a tool call are the same act — one call is one undo step, every mutation is \
recorded with its actor, and everything you do here is invertible and shows up in the app's own \
history and provenance manifest.

START HERE. Open or create a project first (studio_project_open / studio_project_new); the other \
tools act on whatever project is currently open. Then call studio_capabilities once: it lists the \
CLOSED vocabularies — instrument and effect kinds, the parameter keys device.param.set and \
fx.param.set will accept (they refuse anything else), the named instrument presets a person picks \
from, and the grammars for addressing an effect host or an automation lane. Guessing a parameter \
key is the most common way a call fails here, and that tool is the answer.

YOU MINT THE IDS. Track, clip, note, device, fx, routing-node, edge and automation-point ids are \
supplied by YOU and must be unique; the engine never invents one, because a minted id would make \
replay diverge from the live model. Reuse an id and the call is refused as a duplicate.

READ AFTER YOU WRITE. studio_snapshot is the whole project — tracks, clips, notes, instruments and \
their parameters, effect chains, the routing graph, automation lanes, transport position, undo \
depth — and takes an optional sinceSeq to get only what changed. studio_meters is the levels, \
studio_waveform the peaks of a clip's audio, studio_journal and studio_lineage the provenance, \
studio_manifest the disclosure summary. A write tool that answers ok has been applied, journalled \
and made undoable; if it also reports liveRenderError, the edit landed but live playback did not \
take it.

TOOLS THAT DELETE OR WRITE OUTSIDE THE PROJECT require confirm: true. Nothing opens an audio input \
or a speaker unless you ask for it: arming a track does not open the mic (record.inputListen or \
record.start does), and the metronome is monitor-only and can never appear in an export.";

impl ServerHandler for McpServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            // `Implementation::from_build_env()` names the CRATE, so a client
            // connecting to the studio was told it had reached "agent-surface".
            .with_server_info(rmcp::model::Implementation::new(
                "majiks-studio",
                env!("CARGO_PKG_VERSION"),
            ))
            .with_instructions(SERVER_INSTRUCTIONS)
    }

    async fn list_tools(
        &self,
        _request: Option<rmcp::model::PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        Ok(ListToolsResult::with_all_items(self.tool_specs()))
    }

    async fn call_tool(
        &self,
        request: rmcp::model::CallToolRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResult, ErrorData> {
        let name = request.name.to_string();
        let args = request
            .arguments
            .map(Value::Object)
            .unwrap_or_else(|| json!({}));

        // Unknown tool is a protocol error; a tool that ran and failed (bad
        // params, confirm/rate-limit, bus rejection) is a readable isError
        // result the agent can reason about.
        if registry::tool_by_name(&name).is_none() {
            let mut data = serde_json::Map::new();
            data.insert("code".into(), json!("unknown_tool"));
            data.insert("tool".into(), json!(name));
            return Err(ErrorData::new(
                ErrorCode::INVALID_PARAMS,
                format!("unknown tool: {name}"),
                Some(Value::Object(data)),
            ));
        }

        match self.run_tool(&name, args) {
            Ok(value) => Ok(CallToolResult::structured(value)),
            Err(err) => Ok(CallToolResult::error(vec![ContentBlock::text(format!(
                "[{}] {}",
                err.code(),
                err.message()
            ))])),
        }
    }
}

// ---------------------------------------------------------------------------
// Server lifecycle (bind localhost, bearer auth, graceful shutdown).
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub struct McpHandle {
    shutdown: Option<oneshot::Sender<()>>,
    runtime: Option<Runtime>,
    pub port: u16,
    pat: String,
}

impl McpHandle {
    /// The `claude mcp add` connection snippet. The PAT is redacted unless the
    /// UI explicitly reveals it (secrets never leak into logs by default).
    pub fn connection_snippet(&self, revealed: bool) -> String {
        let token = if revealed {
            self.pat.clone()
        } else {
            crate::secret::redact(&self.pat)
        };
        format!(
            "claude mcp add majiks-studio --transport http --url http://127.0.0.1:{}{MCP_HTTP_PATH} --header \"Authorization: Bearer {token}\"",
            self.port
        )
    }

    pub fn stop(&mut self) {
        if let Some(tx) = self.shutdown.take() {
            let _ = tx.send(());
        }
        // Dropping the runtime joins the server task.
        self.runtime.take();
    }
}

impl Drop for McpHandle {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Start the MCP server sharing `host`. Fails closed: refuses unless
/// `cfg.enabled` and a non-empty PAT. Binds 127.0.0.1 only.
pub fn start(
    host: Arc<Mutex<StudioHost>>,
    cfg: McpConfig,
    pat: String,
) -> Result<McpHandle, StudioError> {
    if let Err(e) = crate::midi::start_pump(&host) {
        eprintln!("MIDI pump unavailable: {e}");
    }
    if !cfg.enabled {
        return Err(StudioError::Unsupported(
            "MCP server is disabled in Settings (enable it to start; boot fails closed)".into(),
        ));
    }
    if pat.trim().is_empty() {
        return Err(StudioError::invalid("MCP PAT is empty; store one in the Keychain first"));
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(2)
        .thread_name("majiks-studio-mcp")
        .build()
        .map_err(|e| StudioError::io(format!("tokio runtime: {e}")))?;

    let addr = SocketAddr::from(([127, 0, 0, 1], cfg.port));
    let listener = runtime
        .block_on(async { TcpListener::bind(addr).await })
        .map_err(|e| StudioError::io(format!("bind {addr}: {e}")))?;

    let server = McpServer::new(host);
    let service = StreamableHttpService::new(
        move || Ok(server.clone()),
        Arc::new(LocalSessionManager::default()),
        StreamableHttpServerConfig::default(),
    );
    let auth = AuthState { token: pat.clone() };
    let router = Router::new()
        .route("/health", get(|| async { "ok" }))
        .nest_service(MCP_HTTP_PATH, service)
        .layer(middleware::from_fn_with_state(auth, auth_middleware));

    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
    runtime.spawn(async move {
        let served = axum::serve(listener, router).with_graceful_shutdown(async move {
            let _ = shutdown_rx.await;
        });
        if let Err(e) = served.await {
            eprintln!("majiks-studio MCP server exited: {e}");
        }
    });

    Ok(McpHandle {
        shutdown: Some(shutdown_tx),
        runtime: Some(runtime),
        port: cfg.port,
        pat,
    })
}

#[derive(Clone)]
struct AuthState {
    token: String,
}

async fn auth_middleware(State(state): State<AuthState>, req: Request<Body>, next: Next) -> Response {
    if req.uri().path() == "/health" {
        return next.run(req).await;
    }
    match authorize(req.headers(), &state.token) {
        Ok(()) => next.run(req).await,
        Err(message) => (StatusCode::UNAUTHORIZED, message).into_response(),
    }
}

fn authorize(headers: &HeaderMap, token: &str) -> Result<(), String> {
    let value = headers
        .get(header::AUTHORIZATION)
        .ok_or_else(|| "missing bearer token".to_string())?;
    let auth = value
        .to_str()
        .map_err(|_| "invalid authorization header".to_string())?;
    if auth != format!("Bearer {token}") {
        return Err("bearer token rejected".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_specs_cover_the_whole_registry_with_schemas() {
        let host = Arc::new(Mutex::new(StudioHost::in_memory()));
        let server = McpServer::new(host);
        let specs = server.tool_specs();
        assert_eq!(specs.len(), registry::tool_defs().len());
        // Every tool advertises a non-empty object inputSchema.
        for t in &specs {
            let schema = &t.input_schema;
            assert_eq!(
                schema.get("type").and_then(Value::as_str),
                Some("object"),
                "{} inputSchema",
                t.name
            );
        }
    }

    #[test]
    fn start_fails_closed_when_disabled() {
        let host = Arc::new(Mutex::new(StudioHost::in_memory()));
        let err = start(host, McpConfig { enabled: false, port: 0 }, "pat".into()).unwrap_err();
        assert_eq!(err.code(), "unsupported");
    }

    #[test]
    fn manage_tools_carry_a_confirm_gate() {
        // The clip.remove / export / publish tools are Manage tier and their
        // schema demands confirm (the rmcp annotations mirror the same tier).
        let del = registry::tool_by_name("studio_clip_remove").expect("clip.remove tool");
        assert_eq!(del.tier, ToolTier::Manage);
        assert!(del.confirm_required);
        let specs_have_it = McpServer::new(Arc::new(Mutex::new(StudioHost::in_memory())))
            .tool_specs()
            .into_iter()
            .any(|t| t.name == "studio_clip_remove");
        assert!(specs_have_it);
    }
}
