//! Swift <-> Rust FFI (UniFFI 0.29 proc-macro): a `MajiksEngine` OBJECT the app
//! holds, not a process global. Each handle owns one `StudioHost` instance
//! (the DJ singleton hazard, fixed by rule). Binding style is the DJ idiom:
//! scalars in, JSON snapshots out, one typed `FfiError`.
//!
//! Everything routes through the same command bus the MCP server and CLI use,
//! so the app's UI, the in-process copilot, and remote agents all get identical
//! undo / provenance / results.

use std::sync::{Arc, Mutex, MutexGuard};

use serde_json::{json, Value};

use timeline_core::envelope::ActorKind;
use timeline_core::Actor;

use crate::error::StudioError;
use crate::host::StudioHost;

/// The typed error Swift sees. Mirrors `StudioError` (each variant carries a
/// machine `code` via its name plus a readable message). Secrets are never in
/// a message (PATs live in the Keychain and are redacted in any snippet).
#[derive(Debug, Clone, PartialEq, uniffi::Error)]
pub enum FfiError {
    NotInitialized { message: String },
    InvalidArgument { message: String },
    Command { code: String, message: String },
    Io { message: String },
    Audio { message: String },
    Gen { message: String },
    RateLimited { message: String },
    ConfirmationRequired { message: String },
    Unsupported { message: String },
}

impl std::fmt::Display for FfiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FfiError::Command { code, message } => write!(f, "[{code}] {message}"),
            FfiError::NotInitialized { message } => write!(f, "[not_initialized] {message}"),
            FfiError::InvalidArgument { message } => write!(f, "[invalid_argument] {message}"),
            FfiError::Io { message } => write!(f, "[io_error] {message}"),
            FfiError::Audio { message } => write!(f, "[audio_error] {message}"),
            FfiError::Gen { message } => write!(f, "[gen_error] {message}"),
            FfiError::RateLimited { message } => write!(f, "[rate_limited] {message}"),
            FfiError::ConfirmationRequired { message } => {
                write!(f, "[confirmation_required] {message}")
            }
            FfiError::Unsupported { message } => write!(f, "[unsupported] {message}"),
        }
    }
}

impl std::error::Error for FfiError {}

impl From<StudioError> for FfiError {
    fn from(e: StudioError) -> Self {
        let message = e.message();
        match e {
            StudioError::NotInitialized(_) => FfiError::NotInitialized { message },
            StudioError::InvalidArgument(_) => FfiError::InvalidArgument { message },
            StudioError::Command { code, message } => FfiError::Command { code, message },
            StudioError::Io(_) => FfiError::Io { message },
            StudioError::Audio(_) => FfiError::Audio { message },
            StudioError::Gen(_) => FfiError::Gen { message },
            StudioError::RateLimited(_) => FfiError::RateLimited { message },
            StudioError::ConfirmationRequired(_) => FfiError::ConfirmationRequired { message },
            StudioError::Unsupported(_) => FfiError::Unsupported { message },
        }
    }
}

fn to_json_string(v: &Value) -> String {
    serde_json::to_string(v).unwrap_or_else(|_| "{}".to_string())
}

fn parse_args(args_json: &str) -> Result<Value, FfiError> {
    serde_json::from_str(args_json)
        .map_err(|e| FfiError::InvalidArgument { message: format!("bad args json: {e}") })
}

/// One engine instance behind the FFI. Swift constructs it with
/// `MajiksEngine.initialize(dataDir:)` and holds the handle.
#[derive(uniffi::Object)]
pub struct MajiksEngine {
    host: Arc<Mutex<StudioHost>>,
    /// Sterling, the in-app copilot: shares THIS engine's host, so every Sterling
    /// action is a journaled command on the same session the UI and MCP drive.
    copilot: crate::copilot::Copilot,
    #[cfg(feature = "mcp")]
    mcp: Mutex<Option<crate::mcp::McpHandle>>,
}

impl MajiksEngine {
    fn host(&self) -> Result<MutexGuard<'_, StudioHost>, FfiError> {
        self.host.lock().map_err(|_| FfiError::Unsupported {
            message: "engine lock poisoned".into(),
        })
    }

    /// Route a revise/extend/layer workflow tool by name (user actor), through
    /// the same validate + dispatch path the MCP server uses.
    fn revise_dispatch(&self, tool: &str, args_json: String) -> Result<String, FfiError> {
        let args = parse_args(&args_json)?;
        let mut host = self.host()?;
        let out = crate::dispatch::dispatch_tool(&mut host, Actor::user("app"), tool, args)?;
        Ok(to_json_string(&out))
    }
}

#[uniffi::export]
impl MajiksEngine {
    /// `ffi_studio_initialize(data_dir)`: create/hold the engine and open (or
    /// create) the `.mstudio` package at `data_dir`. `data_dir` is the package
    /// directory path; a non-existent one is created.
    #[uniffi::constructor]
    pub fn initialize(data_dir: String) -> Result<Arc<Self>, FfiError> {
        let name = std::path::Path::new(&data_dir)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("Studio")
            .to_string();
        let host = Arc::new(Mutex::new(StudioHost::open_or_create(&data_dir, &name)?));
        // MIDI is input-only and owns all OS connections on its dedicated pump.
        // Boot failure is non-fatal so the engine remains usable without MIDI.
        if let Err(e) = crate::midi::start_pump(&host) {
            eprintln!("MIDI pump unavailable: {e}");
        }
        Ok(Arc::new(Self {
            copilot: crate::copilot::Copilot::new(Arc::clone(&host)),
            host,
            #[cfg(feature = "mcp")]
            mcp: Mutex::new(None),
        }))
    }

    /// `ffi_studio_command(json-envelope)`: submit `{name, params}` through the
    /// command bus (UI actor) and return the result JSON.
    pub fn command(&self, envelope_json: String) -> Result<String, FfiError> {
        let env: Value = serde_json::from_str(&envelope_json)
            .map_err(|e| FfiError::InvalidArgument { message: format!("bad envelope json: {e}") })?;
        let name = env
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| FfiError::InvalidArgument { message: "envelope has no name".into() })?
            .to_string();
        let params = env.get("params").cloned().unwrap_or_else(|| json!({}));
        let out = self.host()?.submit(Actor::user("app"), &name, params)?;
        Ok(to_json_string(&out))
    }

    /// Call a registry TOOL by name (the in-process copilot path; agent actor).
    /// Same validation + tier gate + routing the MCP server uses.
    pub fn tool(&self, name: String, args_json: String) -> Result<String, FfiError> {
        let args: Value = serde_json::from_str(&args_json)
            .map_err(|e| FfiError::InvalidArgument { message: format!("bad args json: {e}") })?;
        let actor = Actor { kind: ActorKind::Agent, name: "copilot".into() };
        let mut host = self.host()?;
        let out = crate::dispatch::dispatch_tool(&mut host, actor, &name, args)?;
        Ok(to_json_string(&out))
    }

    /// `ffi_studio_snapshot(sinceSeq)`: full project state, or a change delta.
    pub fn snapshot(&self, since_seq: Option<u64>) -> Result<String, FfiError> {
        Ok(to_json_string(&self.host()?.snapshot(since_seq)))
    }

    /// `ffi_studio_transport`: transport fast paths (play/stop/seek).
    pub fn transport(&self, action: String, position_ticks: Option<u64>) -> Result<String, FfiError> {
        let (name, params) = match action.as_str() {
            "play" => ("transport.play", json!({})),
            "stop" => ("transport.stop", json!({})),
            "seek" => (
                "transport.seek",
                json!({ "positionTicks": position_ticks.unwrap_or(0) }),
            ),
            other => {
                return Err(FfiError::InvalidArgument {
                    message: format!("transport action must be play|stop|seek, got {other}"),
                })
            }
        };
        let out = self.host()?.submit(Actor::user("app"), name, params)?;
        Ok(to_json_string(&out))
    }

    /// `ffi_studio_set_audible_output`: enable (or disable) AUDIBLE live output.
    /// The Swift GUI app calls this ONCE at launch (before the first Play builds
    /// the live stream) so playback is heard by default. Nothing else calls it:
    /// the CLI, headless runs, and XCTest leave the device silent, so the
    /// automated-blast safety never regresses. Idempotent; takes effect on the
    /// next `start_live`.
    pub fn set_audible_output(&self, audible: bool) -> Result<(), FfiError> {
        self.host()?.set_audible_output(audible);
        Ok(())
    }

    /// `ffi_studio_start_live`: open a live audio session on the default output
    /// device and prime it with the current project + transport. Idempotent.
    ///
    /// AUDIO SAFETY: the stream is SILENCE-GATED by default. The graph renders
    /// for real (position, meters, and stats become live) but the device hears
    /// zeros unless the GUI opted in via `set_audible_output` (the shipping app
    /// does, at launch) or `MAJIKS_TEST_AUDIBLE=1` is set. This is the app's
    /// explicit "go live" (a user pressing play); it never auto-runs.
    pub fn start_live(&self) -> Result<String, FfiError> {
        Ok(to_json_string(&self.host()?.start_live()?))
    }

    /// `ffi_studio_stop_live`: close the live audio session (releases the
    /// device). Returns whether a session was actually running.
    pub fn stop_live(&self) -> Result<bool, FfiError> {
        Ok(self.host()?.stop_live())
    }

    /// Whether a live audio session is currently open.
    pub fn live_running(&self) -> Result<bool, FfiError> {
        Ok(self.host()?.is_live())
    }

    /// `ffi_studio_meters`: per-track meters. Silence floor offline; real dBFS
    /// peaks once a live session is open.
    pub fn meters(&self) -> Result<String, FfiError> {
        Ok(to_json_string(&self.host()?.meters()))
    }

    /// `ffi_studio_tiles`: capped peak tiles for a clip's window.
    pub fn tiles(
        &self,
        clip_id: String,
        zoom: u32,
        start_bin: u64,
        max_bins: u32,
    ) -> Result<String, FfiError> {
        let v = self.host()?.waveform(&clip_id, zoom, start_bin, max_bins as usize)?;
        Ok(to_json_string(&v))
    }

    /// Render engine health.
    pub fn engine_stats(&self) -> Result<String, FfiError> {
        Ok(to_json_string(&self.host()?.engine_stats()))
    }

    /// Bounce the master mix to a WAV path (offline; silent at any device).
    pub fn bounce_master(&self, output_path: String) -> Result<String, FfiError> {
        let report = self.host()?.bounce_master(std::path::Path::new(&output_path))?;
        Ok(to_json_string(&report.to_json()))
    }

    pub fn undo(&self) -> Result<bool, FfiError> {
        Ok(self.host()?.undo(Actor::user("app"))?)
    }

    pub fn redo(&self) -> Result<bool, FfiError> {
        Ok(self.host()?.redo(Actor::user("app"))?)
    }

    pub fn save(&self) -> Result<(), FfiError> {
        self.host()?.save()?;
        Ok(())
    }

    pub fn seq(&self) -> Result<u64, FfiError> {
        Ok(self.host()?.seq())
    }

    /// `ffi_studio_open_recovery()`: what the last package open had to do to
    /// rebuild the project, as JSON.
    ///
    /// `noteworthy: false` (the default shape) means an ordinary reopen and the
    /// app says nothing. Anything else — the checkpoint was gone and the session
    /// was rebuilt from the journal, or part of the chain was unreadable — is
    /// something the person is entitled to know, because that is the moment to
    /// look at the project and take a copy. Read once after `initialize`; it
    /// describes an event, not live state, so polling it buys nothing.
    pub fn open_recovery(&self) -> Result<String, FfiError> {
        Ok(to_json_string(&self.host()?.open_recovery_json()))
    }

    /// The generated tool manifest (name/tier/schema) so the in-process copilot
    /// can enumerate tools from the same registry the MCP server serves.
    pub fn tools_manifest(&self) -> String {
        crate::registry::tools_manifest_pretty()
    }

    /// `ffi_studio_open_in_studio(args-json)`: the "Open in Studio" bridge (L8).
    /// Build a bar-aligned, stem-split, lineage-carrying session from a finished
    /// song and OPEN it as this engine's active project, then return the landing
    /// report JSON. The app path passes `separator: "provided"` with the four
    /// stem paths it already got from the Python backend; the args shape is the
    /// `studio_open_in_studio` tool schema. User-attributed (the person clicked
    /// the button), unlike the agent tool path.
    pub fn open_in_studio(&self, args_json: String) -> Result<String, FfiError> {
        let args: Value = serde_json::from_str(&args_json)
            .map_err(|e| FfiError::InvalidArgument { message: format!("bad args json: {e}") })?;
        let mut host = self.host()?;
        let out = crate::landing::dispatch_open_in_studio(&mut host, Actor::user("app"), &args)?;
        Ok(to_json_string(&out))
    }

    /// Load one or more sounds into a sampler / drum rack, creating the
    /// instrument if it does not exist yet, as ONE undoable gesture.
    ///
    /// The FFI surface, not a new catalog command: everything JOURNALED here is
    /// `device.add` + `device.zone.remove` + `device.zone.add`, which the
    /// catalog already has (E0 §9.2 — a new NAME is for new semantics, and this
    /// has none). What the app cannot do for itself is the asset io, because
    /// the only path that turns a file into a `source_id` is `import.audio`,
    /// which also places a clip and opens its own transaction — and v1
    /// transactions do not nest. So it sits beside `bounce_master` and
    /// `open_in_studio`: a host method, over the same bus, with the same undo.
    ///
    /// User-attributed: the person picked the file.
    pub fn bind_samples(&self, args_json: String) -> Result<String, FfiError> {
        let args = parse_args(&args_json)?;
        let mut host = self.host()?;
        let out = host.bind_samples_json(&args)?;
        Ok(to_json_string(&out))
    }

    // ----- L9 Revise / Extend / Add-a-Layer (the killer feature) -----------
    //
    // Each is user-attributed (the person selected bars and described a change)
    // and drives a whole pipeline of catalog commands through the same bus the
    // MCP tools and CLI use, so undo + provenance are identical. Args are the
    // matching studio_* tool schema; results are the workflow JSON (variant
    // takes, promotions, swaps). The deterministic fixture generator is the
    // default; `engine: "live"` asks for a Gen Node.

    /// Generate draft variants for a bar region (per scoped stem) and land them
    /// as candidate takes. Returns the per-variant promotions to commit.
    pub fn revise(&self, args_json: String) -> Result<String, FfiError> {
        self.revise_dispatch("studio_revise", args_json)
    }

    /// The audition loop (region + 2 bars pre-roll) for a revise.
    pub fn audition(&self, args_json: String) -> Result<String, FfiError> {
        let args = parse_args(&args_json)?;
        Ok(to_json_string(&crate::revise::dispatch_audition(&*self.host()?, &args)?))
    }

    /// Commit a chosen variant: promote its take(s) as ONE undo transaction.
    pub fn commit(&self, args_json: String) -> Result<String, FfiError> {
        self.revise_dispatch("studio_commit", args_json)
    }

    /// Re-render committed draft take(s) at the commit rung and swap in place
    /// (the draft/commit two-phase). Sample-aligned and undoable.
    pub fn finalize(&self, args_json: String) -> Result<String, FfiError> {
        self.revise_dispatch("studio_finalize", args_json)
    }

    /// Discard an audition (takes stay as candidates in the Takes history).
    pub fn discard(&self, args_json: String) -> Result<String, FfiError> {
        let args = parse_args(&args_json)?;
        Ok(to_json_string(&crate::revise::dispatch_discard(&*self.host()?, &args)?))
    }

    /// Extend a clip past its end: generate variant tails as candidate takes.
    pub fn extend(&self, args_json: String) -> Result<String, FfiError> {
        self.revise_dispatch("studio_extend", args_json)
    }

    /// Place a chosen extend tail (crossfaded seam + section), one undo txn.
    pub fn commit_extend(&self, args_json: String) -> Result<String, FfiError> {
        self.revise_dispatch("studio_commit_extend", args_json)
    }

    /// Add a Layer (lego): generate an instrument that fits a context region on
    /// a prepared NEW track, as candidate takes.
    pub fn layer(&self, args_json: String) -> Result<String, FfiError> {
        self.revise_dispatch("studio_layer", args_json)
    }

    /// Place a chosen layer take on its prepared track, one undo txn.
    pub fn commit_layer(&self, args_json: String) -> Result<String, FfiError> {
        self.revise_dispatch("studio_commit_layer", args_json)
    }

    // ----- Sterling, the in-app copilot (job-style send/poll/cancel) --------
    //
    // Config is passed per send: endpoint + model from Swift's settings, the key
    // from the Keychain. Nothing is persisted here, so no credential lives in
    // Rust past a turn, and the key is scrubbed from every event. Sterling drives
    // the same host this object holds, so his actions are journaled commands
    // identical to a human's.

    /// Start one Sterling turn for `text`. Returns a turn id to poll.
    pub fn copilot_send(
        &self,
        text: String,
        endpoint: String,
        model: String,
        api_key: Option<String>,
        system_prompt_override: Option<String>,
    ) -> Result<u64, FfiError> {
        let config = crate::copilot::CopilotConfig {
            endpoint,
            model,
            api_key: api_key.filter(|k| !k.is_empty()),
            system_prompt_override: system_prompt_override
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty()),
        };
        self.copilot
            .send(config, text)
            .map_err(|message| FfiError::InvalidArgument { message })
    }

    /// Cumulative turn state as JSON: `{turn_id, state, events: [...]}` with
    /// monotonic `seq` on every event. Poll at 4-10 Hz while `running`.
    pub fn copilot_poll(&self, turn_id: u64) -> Result<String, FfiError> {
        self.copilot
            .poll(turn_id)
            .map(|v| to_json_string(&v))
            .ok_or_else(|| FfiError::InvalidArgument {
                message: format!("unknown copilot turn id {turn_id}"),
            })
    }

    /// Request cancellation; the turn lands "cancelled" shortly after. Idempotent
    /// per id.
    pub fn copilot_cancel(&self, turn_id: u64) -> Result<(), FfiError> {
        if self.copilot.cancel(turn_id) {
            Ok(())
        } else {
            Err(FfiError::InvalidArgument {
                message: format!("unknown copilot turn id {turn_id}"),
            })
        }
    }

    /// Clear cross-turn conversation memory (the dock's "clear chat"). Refused
    /// mid-turn.
    pub fn copilot_clear_history(&self) -> Result<(), FfiError> {
        self.copilot
            .reset_history()
            .map_err(|message| FfiError::InvalidArgument { message })
    }

    /// Sterling's tool surface (name/tier/description) for the dock's trust
    /// panel. Follows the same registry the MCP server serves.
    pub fn copilot_tools(&self) -> String {
        to_json_string(&crate::copilot::tool_manifest())
    }
}

// The MCP control surface is a SEPARATE export block so the whole thing is
// removed by cfg when the `mcp` feature is off (a `#[cfg]` on a single method
// inside one `#[uniffi::export] impl` does not strip cleanly - the macro sees
// it before cfg runs).
#[cfg(feature = "mcp")]
#[uniffi::export]
impl MajiksEngine {
    /// Start the MCP server sharing THIS engine instance. `pat` comes from the
    /// Keychain (never hardcoded); returns the connection snippet (redacted).
    /// Fails closed when `enabled` is false.
    pub fn mcp_start(&self, port: u16, pat: String, enabled: bool) -> Result<String, FfiError> {
        let cfg = crate::mcp::McpConfig {
            enabled,
            port: if port == 0 { crate::mcp::DEFAULT_MCP_PORT } else { port },
        };
        let handle = crate::mcp::start(Arc::clone(&self.host), cfg, pat)?;
        let snippet = handle.connection_snippet(false);
        *self
            .mcp
            .lock()
            .map_err(|_| FfiError::Unsupported { message: "mcp lock".into() })? = Some(handle);
        Ok(snippet)
    }

    /// Stop the MCP server if running.
    pub fn mcp_stop(&self) {
        if let Ok(mut guard) = self.mcp.lock() {
            if let Some(mut handle) = guard.take() {
                handle.stop();
            }
        }
    }

    /// Whether the MCP server is currently running.
    pub fn mcp_running(&self) -> bool {
        self.mcp.lock().map(|g| g.is_some()).unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_roundtrip_command_snapshot_bounce() {
        let dir = tempfile::tempdir().unwrap();
        let pkg = dir.path().join("FfiRoundtrip.mstudio");
        let engine = MajiksEngine::initialize(pkg.display().to_string()).unwrap();

        engine
            .command(r#"{"name":"track.add","params":{"trackId":"t1","name":"Drums"}}"#.to_string())
            .unwrap();
        let snap = engine.snapshot(None).unwrap();
        assert!(snap.contains("\"trackCount\":1"), "{snap}");

        // The tool path mutates the same instance.
        engine
            .tool(
                "studio_track_add".to_string(),
                r#"{"trackId":"t2","name":"Bass"}"#.to_string(),
            )
            .unwrap();
        assert_eq!(engine.seq().unwrap(), 2);

        // A bad command surfaces a typed error, not a panic.
        let err = engine
            .command(r#"{"name":"clip.move","params":{"clipId":"nope","trackId":"t1","startTicks":0}}"#.to_string())
            .unwrap_err();
        assert!(matches!(err, FfiError::Command { .. }), "{err}");
    }
}
