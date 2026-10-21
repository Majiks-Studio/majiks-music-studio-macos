//! Sterling, the in-app copilot: an OpenAI-compatible chat-completions
//! tool-calling loop that runs IN-PROCESS and drives the Studio for real.
//!
//! Tool surface: enumerated from the SAME generated registry the MCP server
//! serves (`crate::registry::tool_defs()`), so Sterling's tools can never drift
//! from the command bus. Dispatch goes through the SAME choke point every
//! transport uses (`crate::dispatch::dispatch_tool`), so a Sterling action is a
//! journaled command identical to a human click or an external MCP client. That
//! is agent parity: no private paths.
//!
//! Concurrency: one turn at a time on a background `std::thread` with a BLOCKING
//! HTTP client (no tokio). Swift polls `poll(turn_id)` for cumulative, seq'd
//! events. The render callback is never touched: every engine interaction is a
//! control-side command-bus submit, and the host mutex is held only for the
//! single dispatch call, never the whole turn, so the UI keeps reading snapshots
//! and you watch the timeline edit itself.
//!
//! Safety rails, enforced HERE (not just prompted):
//! - per-turn tool-call budget (`TOOL_CALL_BUDGET`): over-budget calls are
//!   answered with a refusal the model must wrap up around;
//! - a model-call cap (`MAX_MODEL_CALLS`) so a looping model cannot spin
//!   forever;
//! - a blocklist (`blocked_reason`): credential-shaped and self-configuration
//!   calls are refused outright and VISIBLY (a failed tool row), before
//!   dispatch. Name-shaped and args-shaped so registry growth cannot open a
//!   hole silently (the DJ P9 discipline);
//! - the Manage confirm gate lives in `dispatch_tool` already; Sterling surfaces
//!   its refusal as a visible failed row;
//! - the API key is read from the Keychain by Swift, passed only as the
//!   Authorization header, and scrubbed from every event/error string.

use std::io::{BufRead, BufReader};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Map, Value};

use timeline_core::envelope::ActorKind;
use timeline_core::Actor;

use crate::host::StudioHost;
use crate::registry::{tool_by_name, tool_defs, ToolTier};

/// Hard per-turn ceiling on tool calls the model may spend.
pub const TOOL_CALL_BUDGET: usize = 25;
/// Hard per-turn ceiling on chat-completions round trips (a tool-free reply ends
/// the turn well before this; the cap only stops a pathological loop).
const MAX_MODEL_CALLS: usize = 30;
/// Completed turns kept for late polls.
const KEPT_TURNS: usize = 8;
/// Cross-turn memory kept (user/assistant text only; intra-turn tool traffic is
/// not carried forward, so Sterling re-reads the snapshot for truth each turn).
const HISTORY_MAX_MESSAGES: usize = 40;
/// Whole-request ceiling per model call (SSE included). Generous on purpose:
/// this bounds a hung server, not a long agent run.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(300);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// Sterling's committed system prompt (embedded so the app needs no resource
/// plumbing). Grounded in docs/CONCEPTS.md + docs/AGENT_API.md + the command
/// reference.
const SYSTEM_PROMPT: &str = include_str!("../assets/sterling-system.md");

/// The actor stamped on Sterling's journaled commands, so provenance names him.
fn sterling_actor() -> Actor {
    Actor {
        kind: ActorKind::Agent,
        name: "sterling".into(),
    }
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// Resolved backend for one turn. The key is optional: local OpenAI-compatible
/// endpoints (llama.cpp, the UC gateway direct) commonly need none, and
/// BYO-endpoint-without-account is the public story. Swift resolves this from
/// its settings (endpoint/model) plus the Keychain (key) and passes it per send;
/// nothing here is persisted, so the key never lives in Rust past the turn.
#[derive(Clone)]
pub struct CopilotConfig {
    pub endpoint: String,
    pub model: String,
    pub api_key: Option<String>,
    pub system_prompt_override: Option<String>,
}

impl CopilotConfig {
    fn completions_url(&self) -> String {
        let base = self.endpoint.trim().trim_end_matches('/');
        if base.ends_with("/chat/completions") {
            base.to_string()
        } else {
            format!("{base}/chat/completions")
        }
    }
}

// ---------------------------------------------------------------------------
// Turn registry (poll-based)
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    Running,
    Done,
    Cancelled,
    Failed,
}

impl Phase {
    fn as_str(self) -> &'static str {
        match self {
            Phase::Running => "running",
            Phase::Done => "done",
            Phase::Cancelled => "cancelled",
            Phase::Failed => "failed",
        }
    }
}

struct TurnShared {
    phase: Phase,
    /// Cumulative, append-only; Swift applies by `seq` and may poll as late or
    /// as often as it likes.
    events: Vec<Value>,
    next_seq: u64,
}

pub struct TurnHandle {
    shared: Mutex<TurnShared>,
    cancel: AtomicBool,
    /// The turn's bearer key, kept ONLY so `push_event` can scrub it out of
    /// every event string at the single choke point. Never serialized.
    scrub_key: Mutex<Option<String>>,
}

impl TurnHandle {
    fn new() -> Self {
        Self {
            shared: Mutex::new(TurnShared {
                phase: Phase::Running,
                events: Vec::new(),
                next_seq: 0,
            }),
            cancel: AtomicBool::new(false),
            scrub_key: Mutex::new(None),
        }
    }

    fn set_scrub_key(&self, key: Option<String>) {
        if let Ok(mut slot) = self.scrub_key.lock() {
            *slot = key.filter(|k| k.len() >= 6);
        }
    }

    /// Recursively scrub the key from every string in the event payload.
    fn scrub_value(value: &mut Value, key: &str) {
        match value {
            Value::String(text) => {
                if text.contains(key) {
                    *text = text.replace(key, "•••");
                }
            }
            Value::Array(items) => items.iter_mut().for_each(|i| Self::scrub_value(i, key)),
            Value::Object(map) => map.iter_mut().for_each(|(_, i)| Self::scrub_value(i, key)),
            _ => {}
        }
    }

    fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }

    fn push_event(&self, mut event: Value) {
        if let Ok(slot) = self.scrub_key.lock() {
            if let Some(key) = slot.as_deref() {
                Self::scrub_value(&mut event, key);
            }
        }
        let mut shared = self.shared.lock().expect("turn lock");
        let seq = shared.next_seq;
        shared.next_seq += 1;
        if let Value::Object(ref mut map) = event {
            map.insert("seq".to_string(), json!(seq));
        }
        shared.events.push(event);
    }

    fn set_phase(&self, phase: Phase) {
        let mut shared = self.shared.lock().expect("turn lock");
        // Terminal phases never regress (the poll contract is monotonic).
        if shared.phase == Phase::Running {
            shared.phase = phase;
        }
    }

    fn phase(&self) -> Phase {
        self.shared.lock().expect("turn lock").phase
    }
}

/// If the turn thread dies without a terminal state (a panic in a dispatch arm,
/// say), fail the turn instead of leaving it "running" forever, which would also
/// brick `send` (one turn at a time).
struct PhaseGuard(Arc<TurnHandle>);

impl Drop for PhaseGuard {
    fn drop(&mut self) {
        if self.0.phase() == Phase::Running {
            self.0.push_event(json!({
                "type": "turn_error",
                "message": "Sterling's turn ended unexpectedly",
            }));
            self.0.set_phase(Phase::Failed);
        }
    }
}

// ---------------------------------------------------------------------------
// Copilot: one instance per engine (never a process global, per the crate rule)
// ---------------------------------------------------------------------------

/// Sterling, bound to ONE engine instance. Holds the same `Arc<Mutex<StudioHost>>`
/// the app UI and MCP server drive, plus this copilot's turn registry and
/// cross-turn memory. The FFI object (`MajiksEngine`) owns one of these.
pub struct Copilot {
    host: Arc<Mutex<StudioHost>>,
    turns: Mutex<Vec<(u64, Arc<TurnHandle>)>>,
    next_turn_id: AtomicU64,
    history: Arc<Mutex<Vec<Value>>>,
}

impl Copilot {
    pub fn new(host: Arc<Mutex<StudioHost>>) -> Self {
        Self {
            host,
            turns: Mutex::new(Vec::new()),
            next_turn_id: AtomicU64::new(1),
            history: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Start a turn for the user's message. One at a time: a second send while a
    /// turn runs is an error (the dock disables send while running; this is the
    /// backstop). Returns a turn id to poll.
    pub fn send(&self, config: CopilotConfig, text: String) -> Result<u64, String> {
        let text = text.trim().to_string();
        if text.is_empty() {
            return Err("message is empty".to_string());
        }
        if config.endpoint.trim().is_empty() {
            return Err("no endpoint configured. Set one in Sterling's settings.".to_string());
        }
        if config.model.trim().is_empty() {
            return Err("no model configured. Set one in Sterling's settings.".to_string());
        }

        let (turn_id, handle) = {
            let mut turns = self.turns.lock().map_err(|_| "turns lock".to_string())?;
            if turns.iter().any(|(_, t)| t.phase() == Phase::Running) {
                return Err("Sterling is already working on a turn".to_string());
            }
            let handle = Arc::new(TurnHandle::new());
            let id = self.next_turn_id.fetch_add(1, Ordering::Relaxed);
            turns.push((id, handle.clone()));
            while turns.len() > KEPT_TURNS {
                turns.remove(0);
            }
            (id, handle)
        };

        let host = Arc::clone(&self.host);
        let history = Arc::clone(&self.history);
        let prior: Vec<Value> = history.lock().map(|h| h.clone()).unwrap_or_default();

        std::thread::Builder::new()
            .name("sterling-copilot-turn".to_string())
            .spawn(move || {
                let _guard = PhaseGuard(handle.clone());
                run_turn(&host, &history, &handle, &config, prior, &text);
            })
            .map_err(|e| format!("could not start Sterling thread: {e}"))?;

        Ok(turn_id)
    }

    /// Cumulative turn state: `{turn_id, state, events: [...]}`. `None` for an
    /// unknown/pruned id.
    pub fn poll(&self, turn_id: u64) -> Option<Value> {
        let turns = self.turns.lock().ok()?;
        let handle = turns.iter().find(|(id, _)| *id == turn_id)?.1.clone();
        drop(turns);
        let shared = handle.shared.lock().expect("turn lock");
        Some(json!({
            "turn_id": turn_id,
            "state": shared.phase.as_str(),
            "events": shared.events,
        }))
    }

    /// Request cancellation; the loop checks between stream lines, tool calls,
    /// and model calls, so the turn winds down as "cancelled" shortly after.
    pub fn cancel(&self, turn_id: u64) -> bool {
        let turns = self.turns.lock().expect("turns lock");
        match turns.iter().find(|(id, _)| *id == turn_id) {
            Some((_, handle)) => {
                handle.cancel.store(true, Ordering::Relaxed);
                true
            }
            None => false,
        }
    }

    /// Clear cross-turn memory (the dock's "clear chat"). Refused mid-turn.
    pub fn reset_history(&self) -> Result<(), String> {
        let turns = self.turns.lock().map_err(|_| "turns lock".to_string())?;
        if turns.iter().any(|(_, t)| t.phase() == Phase::Running) {
            return Err("cannot clear while a turn is running".to_string());
        }
        self.history.lock().map_err(|_| "history lock".to_string())?.clear();
        Ok(())
    }
}

/// The tool surface as the model sees it (name + tier + description), for the
/// dock's trust panel. Follows the generated registry.
pub fn tool_manifest() -> Value {
    let tools: Vec<Value> = tool_defs()
        .iter()
        .map(|d| {
            json!({
                "name": d.name,
                "tier": d.tier.as_str(),
                "description": d.description,
            })
        })
        .collect();
    json!({ "count": tools.len(), "tools": tools })
}

fn tier_str(tier: Option<ToolTier>) -> &'static str {
    match tier {
        Some(t) => t.as_str(),
        None => "unknown",
    }
}

// ---------------------------------------------------------------------------
// Safety rails
// ---------------------------------------------------------------------------

/// Agent-blocked operations, checked BEFORE dispatch. Matching is name-shaped
/// and args-shaped (contains-checks) so registry growth cannot silently open a
/// hole: any future credential/settings tool is caught without an edit here.
/// Today the tool surface carries NO settings or key tool at all, so this is
/// defense-in-depth, exactly like the DJ P9 rail.
fn blocked_reason(tool: &str, args: &Value) -> Option<String> {
    let t = tool.to_ascii_lowercase();

    // Credentials are human-only, whatever a future tool is named.
    const CREDENTIAL_MARKERS: [&str; 7] =
        ["api_key", "apikey", "secret", "password", "bearer", "credential", "keychain"];
    if CREDENTIAL_MARKERS.iter().any(|m| t.contains(m)) {
        return Some(format!(
            "blocked: {tool} looks credential-shaped; Sterling never reads or writes keys"
        ));
    }

    // Settings/config writes are human-only; the copilot's own namespace most of
    // all (it decides where the NEXT turn sends the stored key, so a
    // prompt-injected rewrite is key exfiltration). Gate the arg checks on a
    // settings-shaped tool, so a legitimate track/clip NAMED "copilot.x" is not
    // caught: only a real settings write is. No such tool exists today; this is
    // the rail for when one is added.
    let settings_shaped =
        t.contains("setting") || t.contains("config") || t.contains("preference") || t.contains("_pref");
    if settings_shaped {
        if let Value::Object(map) = args {
            for (k, v) in map {
                if !matches!(k.as_str(), "key" | "name" | "setting" | "namespace" | "value") {
                    continue;
                }
                let Some(s) = v.as_str() else { continue };
                let sl = s.to_ascii_lowercase();
                if sl.starts_with("copilot.") {
                    return Some(format!(
                        "blocked: '{s}' configures Sterling itself; change it in Sterling's settings"
                    ));
                }
                if CREDENTIAL_MARKERS.iter().chain(["token"].iter()).any(|m| sl.contains(m)) {
                    return Some(format!(
                        "blocked: setting '{s}' looks credential-shaped; Sterling never touches keys"
                    ));
                }
            }
        }
    }
    None
}

/// A structured region hint for the dock chip, derived from the tool's args, so
/// clicking the chip can flash the affected timeline span. Empty when the tool
/// has no spatial locus (a mixer or transport op).
fn region_hint(args: &Value) -> Value {
    let obj = args.as_object();
    let get = |k: &str| obj.and_then(|m| m.get(k)).and_then(Value::as_i64);
    let mut hint = Map::new();
    if let (Some(s), Some(e)) = (get("regionStartTicks"), get("regionEndTicks")) {
        hint.insert("startTicks".into(), json!(s));
        hint.insert("endTicks".into(), json!(e));
    } else if let (Some(s), Some(l)) = (get("startTicks"), get("lengthTicks")) {
        hint.insert("startTicks".into(), json!(s));
        hint.insert("endTicks".into(), json!(s + l));
    } else if let (Some(s), Some(e)) = (get("startTicks"), get("endTicks")) {
        hint.insert("startTicks".into(), json!(s));
        hint.insert("endTicks".into(), json!(e));
    } else if let Some(s) = get("startTicks").or_else(|| get("atTicks")).or_else(|| get("positionTicks")) {
        hint.insert("startTicks".into(), json!(s));
    }
    for k in ["clipId", "newClipId", "trackId", "targetTrackId", "sectionId"] {
        if let Some(v) = obj.and_then(|m| m.get(k)).and_then(Value::as_str) {
            hint.insert(k.into(), json!(v));
        }
    }
    Value::Object(hint)
}

// ---------------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------------

enum TurnFailure {
    Cancelled,
    Fail(String),
}

/// One accumulating tool call from the stream (OpenAI indexes fragments).
#[derive(Default, Clone, Debug)]
struct PendingCall {
    id: String,
    name: String,
    arguments: String,
}

/// What one chat-completions call produced.
#[derive(Default)]
struct ModelReply {
    content: String,
    tool_calls: Vec<PendingCall>,
}

fn run_turn(
    host: &Arc<Mutex<StudioHost>>,
    history: &Arc<Mutex<Vec<Value>>>,
    handle: &Arc<TurnHandle>,
    config: &CopilotConfig,
    prior: Vec<Value>,
    text: &str,
) {
    handle.set_scrub_key(config.api_key.clone());

    let client = match reqwest::blocking::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(REQUEST_TIMEOUT)
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            handle.push_event(json!({ "type": "turn_error", "message": format!("http client: {e}") }));
            handle.set_phase(Phase::Failed);
            return;
        }
    };

    let mut messages: Vec<Value> = Vec::with_capacity(prior.len() + 2);
    let system_prompt = config
        .system_prompt_override
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(SYSTEM_PROMPT);
    messages.push(json!({ "role": "system", "content": system_prompt }));
    messages.extend(prior);
    messages.push(json!({ "role": "user", "content": text }));

    let tools = openai_tools();
    let mut calls_spent: usize = 0;

    let outcome: Result<String, TurnFailure> = (|| {
        for _ in 0..MAX_MODEL_CALLS {
            if handle.cancelled() {
                return Err(TurnFailure::Cancelled);
            }
            let reply = chat_completion(&client, handle, config, &messages, &tools)?;
            if reply.tool_calls.is_empty() {
                return Ok(reply.content);
            }
            // Echo the assistant turn (with its tool calls) back into context.
            let call_json: Vec<Value> = reply
                .tool_calls
                .iter()
                .map(|c| {
                    json!({
                        "id": c.id,
                        "type": "function",
                        "function": { "name": c.name, "arguments": c.arguments },
                    })
                })
                .collect();
            let mut assistant = json!({ "role": "assistant", "tool_calls": call_json });
            if !reply.content.is_empty() {
                assistant["content"] = json!(reply.content);
            }
            messages.push(assistant);

            for call in &reply.tool_calls {
                if handle.cancelled() {
                    return Err(TurnFailure::Cancelled);
                }
                let result_text = execute_tool_call(host, handle, call, &mut calls_spent);
                messages.push(json!({
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": scrub_secret(&result_text, config.api_key.as_deref()),
                }));
            }
        }
        Err(TurnFailure::Fail(format!(
            "model call limit reached ({MAX_MODEL_CALLS} completions in one turn)"
        )))
    })();

    match outcome {
        Ok(final_text) => {
            if let Ok(mut h) = history.lock() {
                h.push(json!({ "role": "user", "content": text }));
                h.push(json!({ "role": "assistant", "content": final_text }));
                while h.len() > HISTORY_MAX_MESSAGES {
                    h.remove(0);
                }
            }
            handle.set_phase(Phase::Done);
        }
        Err(TurnFailure::Cancelled) => handle.set_phase(Phase::Cancelled),
        Err(TurnFailure::Fail(message)) => {
            handle.push_event(json!({
                "type": "turn_error",
                "message": scrub_secret(&message, config.api_key.as_deref()),
            }));
            handle.set_phase(Phase::Failed);
        }
    }
}

/// Budget -> block -> dispatch, with the started/finished event pair that
/// renders as a tool row in the dock. Returns the tool message content for the
/// model. The host mutex is taken ONLY for the single dispatch call.
fn execute_tool_call(
    host: &Arc<Mutex<StudioHost>>,
    handle: &Arc<TurnHandle>,
    call: &PendingCall,
    calls_spent: &mut usize,
) -> String {
    let args: Value = if call.arguments.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str(&call.arguments).unwrap_or(Value::Null)
    };
    let tier = tier_str(tool_by_name(&call.name).map(|d| d.tier));

    handle.push_event(json!({
        "type": "tool_call_started",
        "call_id": call.id,
        "tool": call.name,
        "tier": tier,
        "args_summary": truncate(&compact(&args), 140),
        "region": region_hint(&args),
    }));

    let outcome: Result<Value, String> = (|| {
        if *calls_spent >= TOOL_CALL_BUDGET {
            return Err(format!(
                "tool budget exhausted ({TOOL_CALL_BUDGET} calls this turn). Answer with what you have."
            ));
        }
        *calls_spent += 1;

        if args.is_null() {
            return Err(format!("arguments for {} were not valid JSON", call.name));
        }
        if let Some(reason) = blocked_reason(&call.name, &args) {
            return Err(reason);
        }
        // The SAME choke point MCP + the FFI tool path use: schema validation,
        // the Manage confirm gate, and command-bus journaling all happen inside
        // dispatch_tool. Parity by construction.
        let mut host = host.lock().map_err(|_| "engine lock poisoned".to_string())?;
        crate::dispatch::dispatch_tool(&mut host, sterling_actor(), &call.name, args.clone())
            .map_err(|e| e.message())
    })();

    let (ok, result_text) = match &outcome {
        Ok(value) => (true, compact(value)),
        Err(message) => (false, format!("error: {message}")),
    };

    handle.push_event(json!({
        "type": "tool_call_finished",
        "call_id": call.id,
        "tool": call.name,
        "ok": ok,
        "result_summary": truncate(&result_text, 200),
    }));

    result_text
}

// ---------------------------------------------------------------------------
// Chat-completions client (blocking SSE with a JSON fallback)
// ---------------------------------------------------------------------------

fn chat_completion(
    client: &reqwest::blocking::Client,
    handle: &Arc<TurnHandle>,
    config: &CopilotConfig,
    messages: &[Value],
    tools: &[Value],
) -> Result<ModelReply, TurnFailure> {
    let body = json!({
        "model": config.model,
        "messages": messages,
        "tools": tools,
        "stream": true,
    });

    let mut request = client.post(config.completions_url()).json(&body);
    if let Some(key) = config.api_key.as_deref() {
        if !key.is_empty() {
            request = request.bearer_auth(key);
        }
    }

    let response = request
        .send()
        .map_err(|e| TurnFailure::Fail(format!("request failed: {e}")))?;

    let status = response.status();
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();

    if !status.is_success() {
        let body = response.text().unwrap_or_default();
        return Err(TurnFailure::Fail(format!(
            "endpoint returned {status}: {}",
            truncate(body.trim(), 300)
        )));
    }

    // Some gateways answer stream:true with a plain JSON completion. Accept it.
    if content_type.starts_with("application/json") {
        let value: Value = response
            .json()
            .map_err(|e| TurnFailure::Fail(format!("bad JSON completion: {e}")))?;
        let reply = parse_full_completion(&value);
        if !reply.content.is_empty() {
            handle.push_event(json!({ "type": "text_delta", "text": reply.content }));
        }
        return Ok(reply);
    }

    let mut sse = SseAccumulator::default();
    let mut reader = BufReader::new(response);
    let mut line = String::new();
    loop {
        if handle.cancelled() {
            return Err(TurnFailure::Cancelled);
        }
        line.clear();
        let n = reader
            .read_line(&mut line)
            .map_err(|e| TurnFailure::Fail(format!("stream read failed: {e}")))?;
        if n == 0 {
            break;
        }
        if let Some(text) = sse.push_line(line.trim_end()) {
            handle.push_event(json!({ "type": "text_delta", "text": text }));
        }
    }
    Ok(sse.finish())
}

/// Incremental OpenAI SSE accumulator. `push_line` returns any text delta the
/// line carried; tool-call fragments accumulate by index until `finish`.
#[derive(Default)]
struct SseAccumulator {
    content: String,
    calls: Vec<PendingCall>,
}

impl SseAccumulator {
    fn push_line(&mut self, line: &str) -> Option<String> {
        let data = line.strip_prefix("data:")?.trim();
        if data.is_empty() || data == "[DONE]" {
            return None;
        }
        let value: Value = serde_json::from_str(data).ok()?;
        let delta = value.get("choices")?.get(0)?.get("delta")?;

        if let Some(fragments) = delta.get("tool_calls").and_then(Value::as_array) {
            for fragment in fragments {
                let index = fragment.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
                // A hostile/buggy server controls `index`. Clamp so a huge value
                // cannot balloon the vec (64 parallel calls is beyond any real
                // completion).
                if index >= 64 {
                    continue;
                }
                while self.calls.len() <= index {
                    self.calls.push(PendingCall::default());
                }
                let call = &mut self.calls[index];
                if let Some(id) = fragment.get("id").and_then(Value::as_str) {
                    call.id = id.to_string();
                }
                if let Some(function) = fragment.get("function") {
                    if let Some(name) = function.get("name").and_then(Value::as_str) {
                        call.name.push_str(name);
                    }
                    if let Some(arguments) = function.get("arguments").and_then(Value::as_str) {
                        call.arguments.push_str(arguments);
                    }
                }
            }
        }

        let text = delta.get("content").and_then(Value::as_str)?;
        if text.is_empty() {
            return None;
        }
        self.content.push_str(text);
        Some(text.to_string())
    }

    fn finish(mut self) -> ModelReply {
        for (index, call) in self.calls.iter_mut().enumerate() {
            if call.id.is_empty() {
                call.id = format!("call_{index}");
            }
        }
        self.calls.retain(|call| !call.name.is_empty());
        ModelReply {
            content: self.content,
            tool_calls: self.calls,
        }
    }
}

/// Non-streaming completion body -> ModelReply.
fn parse_full_completion(value: &Value) -> ModelReply {
    let message = value
        .get("choices")
        .and_then(|c| c.get(0))
        .and_then(|c| c.get("message"))
        .cloned()
        .unwrap_or(Value::Null);
    let content = message
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let tool_calls = message
        .get("tool_calls")
        .and_then(Value::as_array)
        .map(|calls| {
            calls
                .iter()
                .enumerate()
                .filter_map(|(index, call)| {
                    let function = call.get("function")?;
                    let id = match call.get("id").and_then(Value::as_str) {
                        Some(id) => id.to_string(),
                        None => format!("call_{index}"),
                    };
                    Some(PendingCall {
                        id,
                        name: function.get("name")?.as_str()?.to_string(),
                        arguments: function
                            .get("arguments")
                            .and_then(Value::as_str)
                            .unwrap_or("{}")
                            .to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    ModelReply { content, tool_calls }
}

/// Registry tool defs -> OpenAI function-tool definitions (names, descriptions,
/// and JSON schemas pass through untouched, so registry growth reaches the model
/// with zero edits here).
fn openai_tools() -> Vec<Value> {
    tool_defs()
        .iter()
        .map(|d| {
            json!({
                "type": "function",
                "function": {
                    "name": d.name,
                    "description": d.description,
                    "parameters": d.input_schema,
                },
            })
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn compact(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| value.to_string())
}

fn truncate(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        text.to_string()
    } else {
        let cut: String = text.chars().take(max_chars).collect();
        format!("{cut}…")
    }
}

/// Belt-and-braces: no event/message text ever carries the API key, even if a
/// misbehaving gateway echoes it back in an error body.
fn scrub_secret(text: &str, key: Option<&str>) -> String {
    match key {
        Some(key) if key.len() >= 6 && text.contains(key) => text.replace(key, "•••"),
        _ => text.to_string(),
    }
}

// ---------------------------------------------------------------------------
// Tests: a fake OpenAI-compatible server (127.0.0.1, no network) scripts
// tool_calls; the round-trips assert REAL command-bus effects on the host.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    #[test]
    fn sterling_system_prompt_does_not_claim_the_engineer() {
        // The app ships a SEPARATE built-in agent literally named "The
        // Engineer" (BPM/key detection, mixing advice, parameter extraction).
        // Sterling is The Producer. If this prompt reintroduces Sterling as
        // The Engineer, the collision is back in the one place no UI test can
        // see it: the model's own self-description. Asserted as an ABSENCE,
        // because a "contains The Producer" check cannot see a leftover title.
        assert!(
            !SYSTEM_PROMPT.contains("Sterling, the Engineer"),
            "engine system prompt reintroduces Sterling as The Engineer"
        );
        assert!(
            !SYSTEM_PROMPT.contains("You are Sterling, the in-house producer and engineer"),
            "engine system prompt still gives Sterling the engineer title"
        );
        assert!(
            SYSTEM_PROMPT.contains("Sterling, the Producer"),
            "engine system prompt no longer names Sterling as the producer"
        );
        assert!(
            SYSTEM_PROMPT.contains("Your\ntitle is The Producer")
                || SYSTEM_PROMPT.contains("title is The Producer"),
            "engine system prompt does not state Sterling's title"
        );
    }

    #[test]
    fn sterling_actor_is_the_spec_agent() {
        // Spec 8.2: a Sterling turn's journaled commands are attributed to the
        // agent named "sterling" (dispatch_tool is called with this actor at the
        // tool-dispatch site). The MIDI-trigger provenance test in tests/midi.rs
        // asserts the journal echoes this exact actor; this pins it so a rename of
        // sterling_actor() cannot silently diverge production provenance from that
        // assertion.
        let a = sterling_actor();
        assert!(matches!(a.kind, ActorKind::Agent));
        assert_eq!(a.name, "sterling");
    }

    // --- fake chat-completions server -----------------------------------

    /// SSE body: one assistant message calling one tool, arguments split across
    /// two frames to exercise fragment reassembly.
    fn sse_tool_call(call_id: &str, name: &str, args: &str) -> String {
        let split = args.len() / 2;
        let (head, tail) = args.split_at(split);
        let mut body = String::new();
        body.push_str(&format!(
            "data: {}\n\n",
            json!({ "choices": [{ "delta": { "tool_calls": [{
                "index": 0, "id": call_id, "type": "function",
                "function": { "name": name, "arguments": head }
            }] } }] })
        ));
        body.push_str(&format!(
            "data: {}\n\n",
            json!({ "choices": [{ "delta": { "tool_calls": [{
                "index": 0, "function": { "arguments": tail }
            }] } }] })
        ));
        body.push_str("data: [DONE]\n\n");
        body
    }

    /// SSE body: a plain-text assistant reply, split into two deltas.
    fn sse_text(text: &str) -> String {
        let split = (text.len() / 2).max(1).min(text.len());
        let (head, tail) = text.split_at(split);
        let mut body = String::new();
        for part in [head, tail] {
            if part.is_empty() {
                continue;
            }
            body.push_str(&format!(
                "data: {}\n\n",
                json!({ "choices": [{ "delta": { "content": part } }] })
            ));
        }
        body.push_str("data: [DONE]\n\n");
        body
    }

    /// One assistant message with N identical tool calls (budget test).
    fn sse_many_tool_calls(count: usize, name: &str, args: &str) -> String {
        let mut body = String::new();
        for index in 0..count {
            body.push_str(&format!(
                "data: {}\n\n",
                json!({ "choices": [{ "delta": { "tool_calls": [{
                    "index": index, "id": format!("call_{index}"), "type": "function",
                    "function": { "name": name, "arguments": args }
                }] } }] })
            ));
        }
        body.push_str("data: [DONE]\n\n");
        body
    }

    /// A minimal blocking HTTP/1.1 server on 127.0.0.1:0. Each POST pops the
    /// next scripted SSE body. No axum, no tokio, no network. Returns the base
    /// endpoint URL. `Connection: close` so reqwest uses one connection per
    /// completion, matching one script entry per model call.
    fn start_fake_server(script: Vec<String>) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind fake server");
        let port = listener.local_addr().expect("addr").port();
        let script = Arc::new(Mutex::new(VecDeque::from(script)));
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = match stream {
                    Ok(s) => s,
                    Err(_) => continue,
                };
                let mut reader = BufReader::new(stream.try_clone().expect("clone"));
                let mut content_length = 0usize;
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap_or(0) == 0 {
                        break;
                    }
                    let trimmed = header.trim_end();
                    if trimmed.is_empty() {
                        break; // end of headers
                    }
                    if let Some(v) = trimmed.to_ascii_lowercase().strip_prefix("content-length:") {
                        content_length = v.trim().parse().unwrap_or(0);
                    }
                }
                if content_length > 0 {
                    let mut buf = vec![0u8; content_length];
                    let _ = reader.read_exact(&mut buf);
                }
                let sse = script
                    .lock()
                    .expect("script lock")
                    .pop_front()
                    .unwrap_or_else(|| sse_text("script exhausted"));
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    sse.len(),
                    sse
                );
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            }
        });
        format!("http://127.0.0.1:{port}/v1")
    }

    /// A server that returns a fixed non-200 status + plain body for every POST
    /// (the hostile-gateway scrub test).
    fn start_fake_error_server(status: &str, body: &str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().unwrap().port();
        let response = format!(
            "HTTP/1.1 {status}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut stream = match stream {
                    Ok(s) => s,
                    Err(_) => continue,
                };
                let mut reader = BufReader::new(stream.try_clone().expect("clone"));
                let mut content_length = 0usize;
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap_or(0) == 0 {
                        break;
                    }
                    let trimmed = header.trim_end();
                    if trimmed.is_empty() {
                        break;
                    }
                    if let Some(v) = trimmed.to_ascii_lowercase().strip_prefix("content-length:") {
                        content_length = v.trim().parse().unwrap_or(0);
                    }
                }
                if content_length > 0 {
                    let mut buf = vec![0u8; content_length];
                    let _ = reader.read_exact(&mut buf);
                }
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            }
        });
        format!("http://127.0.0.1:{port}/v1")
    }

    fn test_config(endpoint: String) -> CopilotConfig {
        CopilotConfig {
            endpoint,
            model: "fake-model".to_string(),
            api_key: Some("test-key-000000".to_string()),
            system_prompt_override: None,
        }
    }

    /// Returns the host plus the TempDir; the caller binds the dir (`_dir`) so
    /// the `.mstudio` package outlives the test.
    fn fresh_host() -> (Arc<Mutex<StudioHost>>, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("Sterling.mstudio");
        let host = StudioHost::open_or_create(&path, "Sterling").expect("host");
        (Arc::new(Mutex::new(host)), dir)
    }

    fn poll_until_done(copilot: &Copilot, turn_id: u64) -> Value {
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        loop {
            let state = copilot.poll(turn_id).expect("turn exists");
            if state["state"] != "running" {
                return state;
            }
            assert!(std::time::Instant::now() < deadline, "turn timed out: {state}");
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    fn events_of_type<'a>(state: &'a Value, kind: &str) -> Vec<&'a Value> {
        state["events"]
            .as_array()
            .expect("events array")
            .iter()
            .filter(|e| e["type"] == kind)
            .collect()
    }

    fn assistant_text(state: &Value) -> String {
        events_of_type(state, "text_delta")
            .iter()
            .map(|e| e["text"].as_str().unwrap_or_default())
            .collect()
    }

    fn snapshot(host: &Arc<Mutex<StudioHost>>) -> Value {
        host.lock().unwrap().snapshot(None)
    }

    fn clip_count(host: &Arc<Mutex<StudioHost>>) -> u64 {
        snapshot(host)["project"]["clipCount"].as_u64().unwrap_or(0)
    }

    fn seq(host: &Arc<Mutex<StudioHost>>) -> u64 {
        host.lock().unwrap().seq()
    }

    // --- rail: a scripted tool call moves the REAL host -----------------

    #[test]
    fn fake_server_round_trip_moves_the_host() {
        let (host, _dir) = fresh_host();
        let copilot = Copilot::new(Arc::clone(&host));

        let script = vec![
            sse_tool_call("call_rt", "studio_track_add", r#"{"trackId":"t1","name":"Drums"}"#),
            sse_text("Added a Drums track."),
        ];
        let endpoint = start_fake_server(script);
        let turn_id = copilot
            .send(test_config(endpoint), "add a drums track".to_string())
            .expect("send starts a turn");

        let state = poll_until_done(&copilot, turn_id);
        assert_eq!(state["state"], "done", "{state}");

        let started = events_of_type(&state, "tool_call_started");
        assert_eq!(started.len(), 1, "{state}");
        assert_eq!(started[0]["tool"], "studio_track_add");
        assert_eq!(started[0]["tier"], "perform");
        let finished = events_of_type(&state, "tool_call_finished");
        assert_eq!(finished.len(), 1, "{state}");
        assert_eq!(finished[0]["ok"], true, "{state}");
        assert_eq!(assistant_text(&state), "Added a Drums track.");

        // THE HOST EFFECT: the scripted call actually added a track via the bus.
        assert_eq!(snapshot(&host)["project"]["trackCount"], json!(1), "track landed");
        assert_eq!(seq(&host), 1, "one journaled command");
    }

    #[test]
    fn tool_budget_caps_a_runaway_turn() {
        let (host, _dir) = fresh_host();
        let copilot = Copilot::new(Arc::clone(&host));

        let over = TOOL_CALL_BUDGET + 5;
        let script = vec![
            sse_many_tool_calls(over, "studio_snapshot", "{}"),
            sse_text("Wrapping up."),
        ];
        let endpoint = start_fake_server(script);
        let turn_id = copilot
            .send(test_config(endpoint), "read the project many times".to_string())
            .expect("send");

        let state = poll_until_done(&copilot, turn_id);
        assert_eq!(state["state"], "done", "{state}");
        let finished = events_of_type(&state, "tool_call_finished");
        assert_eq!(finished.len(), over, "every call gets a row: {state}");
        let refused: Vec<_> = finished
            .iter()
            .filter(|e| {
                e["ok"] == json!(false)
                    && e["result_summary"].as_str().unwrap_or_default().contains("budget exhausted")
            })
            .collect();
        assert_eq!(refused.len(), 5, "exactly the over-budget tail is refused: {state}");
    }

    #[test]
    fn blocklist_refuses_credential_and_self_config_calls() {
        // Direct unit coverage of the rail (name-shaped + args-shaped).
        assert!(blocked_reason("studio_set_api_key", &json!({})).is_some());
        assert!(blocked_reason("copilot_set_secret", &json!({})).is_some());
        assert!(blocked_reason(
            "studio_settings_set",
            &json!({ "key": "copilot.endpoint", "value": "http://evil" })
        )
        .is_some());
        assert!(blocked_reason(
            "studio_config_set",
            &json!({ "key": "openai_api_key", "value": "sk-x" })
        )
        .is_some());
        // Real Studio tools are never blocked.
        assert!(blocked_reason("studio_mix_gain", &json!({ "trackId": "t1", "gainDb": -6 })).is_none());
        assert!(blocked_reason("studio_snapshot", &json!({})).is_none());
        assert!(blocked_reason("studio_export_master", &json!({ "outputPath": "x.wav", "format": "wav", "confirm": true })).is_none());
        // No false positives: a legitimate track/clip/section NAMED "copilot.x"
        // (a non-settings tool) is not caught by the self-config rail.
        assert!(blocked_reason("studio_track_add", &json!({ "trackId": "t1", "name": "copilot.mix" })).is_none());
        assert!(blocked_reason("studio_section_set", &json!({ "sectionId": "s", "name": "copilot.outro", "startTicks": 0 })).is_none());
        assert!(blocked_reason("studio_track_rename", &json!({ "trackId": "t1", "name": "secret sauce" })).is_none());
    }

    #[test]
    fn blocked_call_is_refused_but_turn_survives() {
        let (host, _dir) = fresh_host();
        let copilot = Copilot::new(Arc::clone(&host));

        let script = vec![
            sse_tool_call(
                "call_blocked",
                "studio_settings_set",
                r#"{"key":"copilot.endpoint","value":"http://evil"}"#,
            ),
            sse_text("I can't touch Sterling's own settings."),
        ];
        let endpoint = start_fake_server(script);
        let turn_id = copilot
            .send(test_config(endpoint), "point yourself at my server".to_string())
            .expect("send");

        let state = poll_until_done(&copilot, turn_id);
        assert_eq!(state["state"], "done", "{state}");
        let finished = events_of_type(&state, "tool_call_finished");
        assert_eq!(finished.len(), 1, "{state}");
        assert_eq!(finished[0]["ok"], false, "refusal must be visible: {state}");
        assert!(
            finished[0]["result_summary"]
                .as_str()
                .unwrap_or_default()
                .to_lowercase()
                .contains("configures sterling"),
            "refusal names the reason: {state}"
        );
        assert_eq!(seq(&host), 0, "nothing was journaled");
    }

    #[test]
    fn manage_tool_requires_confirm_then_executes() {
        let (host, _dir) = fresh_host();
        {
            let mut h = host.lock().unwrap();
            h.submit(Actor::user("setup"), "track.add", json!({ "trackId": "t1", "name": "Drums" }))
                .unwrap();
        }
        let copilot = Copilot::new(Arc::clone(&host));

        // Turn 1: remove without confirm -> refused (the Manage gate in dispatch).
        let script1 = vec![
            sse_tool_call("call_noconfirm", "studio_track_remove", r#"{"trackId":"t1"}"#),
            sse_text("That needs your confirmation."),
        ];
        let ep1 = start_fake_server(script1);
        let t1 = copilot.send(test_config(ep1), "delete the drums track".to_string()).unwrap();
        let s1 = poll_until_done(&copilot, t1);
        let f1 = events_of_type(&s1, "tool_call_finished");
        assert_eq!(f1[0]["ok"], false, "manage without confirm is refused: {s1}");
        assert!(
            f1[0]["result_summary"].as_str().unwrap_or_default().to_lowercase().contains("confirm"),
            "refusal mentions confirm: {s1}"
        );
        assert_eq!(snapshot(&host)["project"]["trackCount"], json!(1), "track still there");

        // Turn 2: with confirm -> executes.
        let script2 = vec![
            sse_tool_call("call_confirm", "studio_track_remove", r#"{"trackId":"t1","confirm":true}"#),
            sse_text("Removed the drums track."),
        ];
        let ep2 = start_fake_server(script2);
        let t2 = copilot.send(test_config(ep2), "yes, delete it".to_string()).unwrap();
        let s2 = poll_until_done(&copilot, t2);
        let f2 = events_of_type(&s2, "tool_call_finished");
        assert_eq!(f2[0]["ok"], true, "manage with confirm executes: {s2}");
        assert_eq!(snapshot(&host)["project"]["trackCount"], json!(0), "track removed");
    }

    #[test]
    fn key_is_scrubbed_from_error_events() {
        // The realistic echo vector: the model never SEES the key (it is only the
        // Authorization header, never a message), so it cannot emit it. The one
        // way a key can come back is an endpoint or tool body echoing it, and
        // those are scrubbed as whole strings. Here a hostile gateway 400s with
        // the key in the error body; it must never reach an event.
        let (host, _dir) = fresh_host();
        let copilot = Copilot::new(Arc::clone(&host));
        let key = "sk-supersecret-123456";
        let mut config =
            test_config(start_fake_error_server("400 Bad Request", &format!("invalid key {key}")));
        config.api_key = Some(key.to_string());
        let turn_id = copilot.send(config, "hello".to_string()).unwrap();
        let state = poll_until_done(&copilot, turn_id);
        assert_eq!(state["state"], "failed", "{state}");
        let errors = events_of_type(&state, "turn_error");
        assert_eq!(errors.len(), 1, "{state}");
        let message = errors[0]["message"].as_str().unwrap_or_default();
        assert!(!message.contains(key), "key must be scrubbed from the error: {message}");
        assert!(message.contains("•••"), "scrubbed marker present: {message}");
    }

    // --- THE DEMO (acceptance): hands-free arrangement over the bus -------

    #[test]
    fn scripted_arrangement_demo_drives_the_command_bus() {
        // Fixture: a lo-fi bed track with audio, and a VO track with audio.
        let fixtures = render::fixtures::repo_fixtures_dir();
        render::fixtures::ensure(&fixtures).expect("fixtures");
        let bed_wav = fixtures.join("click_120bpm_48k_stereo.wav");
        let vo_wav = fixtures.join("tone_440_48k_mono.wav");

        let (host, _dir) = fresh_host();
        let bed_end;
        let clips_before;
        let seq_before;
        {
            let mut h = host.lock().unwrap();
            let user = Actor::user("setup");
            h.submit(user.clone(), "project.setTempo", json!({ "bpm": 120 })).unwrap();
            h.submit(user.clone(), "track.add", json!({ "trackId": "tbed", "name": "Lo-fi Bed" })).unwrap();
            h.submit(user.clone(), "track.add", json!({ "trackId": "tvo", "name": "VO" })).unwrap();
            let bed = h
                .submit(
                    user.clone(),
                    "import.audio",
                    json!({ "sourcePath": bed_wav.display().to_string(), "targetTrackId": "tbed", "startTicks": 0, "clipId": "bed1" }),
                )
                .unwrap();
            h.submit(
                user,
                "import.audio",
                json!({ "sourcePath": vo_wav.display().to_string(), "targetTrackId": "tvo", "startTicks": 3840, "clipId": "vo1" }),
            )
            .unwrap();
            bed_end = bed["startTicks"].as_i64().unwrap() + bed["lengthTicks"].as_i64().unwrap();
            drop(bed);
            clips_before = h.snapshot(None)["project"]["clipCount"].as_u64().unwrap();
            seq_before = h.seq();
        }

        let copilot = Copilot::new(Arc::clone(&host));

        // The model plan for "make the outro 16 bars longer, keep the mood, and
        // duck the bed under my VO track": read the session, mark the outro,
        // extend the bed audio into it, crossfade the seam, and duck the bed.
        let script = vec![
            sse_tool_call("c1", "studio_snapshot", "{}"),
            sse_tool_call(
                "c2",
                "studio_section_set",
                &json!({ "sectionId": "outro", "name": "OUTRO", "startTicks": bed_end }).to_string(),
            ),
            sse_tool_call(
                "c3",
                "studio_clip_duplicate",
                &json!({ "clipId": "bed1", "newClipId": "bed_outro", "startTicks": bed_end }).to_string(),
            ),
            sse_tool_call(
                "c4",
                "studio_clip_crossfade_set",
                &json!({ "clipIdA": "bed1", "clipIdB": "bed_outro", "lengthTicks": 960, "shape": "equalPower" }).to_string(),
            ),
            sse_tool_call(
                "c5",
                "studio_mix_gain",
                &json!({ "trackId": "tbed", "gainDb": -6.0 }).to_string(),
            ),
            sse_text(
                "Done. Extended the outro past the old ending, crossfaded the seam, and ducked the bed 6 dB under the VO. Say the word and I'll undo it.",
            ),
        ];
        let endpoint = start_fake_server(script);
        let turn_id = copilot
            .send(
                test_config(endpoint),
                "make the outro 16 bars longer, keep the mood, and duck the bed under my VO track".to_string(),
            )
            .expect("send");

        let state = poll_until_done(&copilot, turn_id);
        print_transcript(&state);
        assert_eq!(state["state"], "done", "demo turn completes: {state}");

        // Five visible chips, in order, tier-tagged; all succeeded.
        let started = events_of_type(&state, "tool_call_started");
        let tools: Vec<&str> = started.iter().map(|e| e["tool"].as_str().unwrap()).collect();
        assert_eq!(
            tools,
            vec![
                "studio_snapshot",
                "studio_section_set",
                "studio_clip_duplicate",
                "studio_clip_crossfade_set",
                "studio_mix_gain"
            ],
            "the arrangement steps, in order: {state}"
        );
        assert_eq!(started[0]["tier"], "read");
        assert!(started[1..].iter().all(|e| e["tier"] == "perform"), "edits are perform tier");
        let finished = events_of_type(&state, "tool_call_finished");
        assert!(finished.iter().all(|e| e["ok"] == json!(true)), "every step ok: {state}");
        // The section chip carries a region hint the dock can flash.
        assert_eq!(started[1]["region"]["startTicks"], json!(bed_end), "chip flashes the outro");

        let text = assistant_text(&state).to_lowercase();
        assert!(text.contains("outro") && (text.contains("duck") || text.contains("vo")), "summary: {text}");

        // REAL command-bus effects: four journaled mutations, one new clip, an
        // OUTRO section.
        assert_eq!(seq(&host), seq_before + 4, "four journaled perform commands");
        assert_eq!(clip_count(&host), clips_before + 1, "the extension clip landed");
        assert!(
            serde_json::to_string(&snapshot(&host)).unwrap().contains("OUTRO"),
            "the outro section exists"
        );

        // UNDOABLE: Sterling's actions unwind LIFO (per-chip undo in the dock).
        {
            let mut h = host.lock().unwrap();
            assert!(h.undo(Actor::user("app")).unwrap(), "the last action (duck) is undoable");
            let mut guard = 0;
            while h.snapshot(None)["project"]["clipCount"].as_u64().unwrap() != clips_before && guard < 5 {
                assert!(h.undo(Actor::user("app")).unwrap(), "each action undoes");
                guard += 1;
            }
            assert_eq!(
                h.snapshot(None)["project"]["clipCount"].as_u64().unwrap(),
                clips_before,
                "undo removed the extension clip: the arrangement is reversible"
            );
        }
    }

    /// Print the demo transcript for the evidence doc (visible under
    /// `cargo test ... -- --nocapture`).
    fn print_transcript(state: &Value) {
        println!("\n===== STERLING DEMO TRANSCRIPT =====");
        for event in state["events"].as_array().unwrap() {
            match event["type"].as_str().unwrap_or("") {
                "text_delta" => print!("{}", event["text"].as_str().unwrap_or("")),
                "tool_call_started" => println!(
                    "\n  [{}] {} {}",
                    event["tier"].as_str().unwrap_or("?"),
                    event["tool"].as_str().unwrap_or("?"),
                    event["args_summary"].as_str().unwrap_or("")
                ),
                "tool_call_finished" => println!(
                    "    -> {} {}",
                    if event["ok"] == json!(true) { "ok" } else { "REFUSED" },
                    event["result_summary"].as_str().unwrap_or("")
                ),
                "turn_error" => println!("\n  ERROR: {}", event["message"].as_str().unwrap_or("")),
                _ => {}
            }
        }
        println!("\n====================================\n");
    }
}
