//! agent-surface: the drivable face of the Majik's Music Studio engine.
//!
//! One engine INSTANCE (`StudioHost`, never a process global) sits behind three
//! transports that all emit the SAME catalog commands through the timeline-core
//! command bus, so undo, provenance, and agent parity are identical whoever is
//! driving:
//!
//! - FFI (`ffi` feature): a UniFFI object the Swift app holds; scalars in, JSON
//!   snapshots out (DJ `ffi.rs` idiom), typed `FfiError`.
//! - MCP (`mcp` feature): an rmcp localhost streamable-HTTP server, bearer PAT,
//!   off by default, tools GENERATED from `command-catalog.v1.json` so the tool
//!   set can never drift from the bus (parity gate test enforces it).
//! - CLI (`cli` feature): `majiks-studio-cli`, opens/creates a `.mstudio`,
//!   applies a jsonl command script through the same bus, bounces a WAV. The
//!   agents-render-anywhere surface and the acceptance backbone.
//!
//! HARD RULE inherited from render: nothing here touches the render callback.
//! Everything flows through control-side APIs (Session::submit, EngineParams
//! setters, snapshot reads, the offline ManualRenderer).

pub mod capabilities;
pub mod dispatch;
pub mod error;
pub mod export;
pub mod gen;
pub mod host;
pub mod landing;
pub mod live;
pub mod midi;
pub mod midi_record;
pub mod record_input;
pub mod registry;
pub mod revise;
pub mod stem_usability;
pub mod ulid;

// Sterling, the in-app copilot: an in-process OpenAI-compatible tool-calling
// loop driving the SAME command bus (via `dispatch_tool`) every transport uses.
#[cfg(feature = "copilot")]
pub mod copilot;

#[cfg(feature = "mcp")]
pub mod mcp;
#[cfg(feature = "mcp")]
pub mod secret;

#[cfg(feature = "ffi")]
pub mod ffi;

pub use capabilities::capabilities;
pub use dispatch::dispatch_tool;
pub use export::{build_manifest, composition, ClipOrigin, Composition};
#[cfg(feature = "copilot")]
pub use copilot::{Copilot, CopilotConfig};
pub use error::StudioError;
pub use host::{
    engine_stats_json, AssetIngest, BindSamplesOutcome, BindSamplesRequest, BoundZone, BounceReport,
    ImportOutcome, RecordingOutcome, SampleBinding, StudioHost,
};
pub use landing::{
    build_landing, HtdemucsSeparator, InterleaveFixtureSeparator, LandingReport, LandingRequest,
    PreSeparated, Separator, SeparatorKind, SeparatorSpec, StemSet, DEFAULT_SEPARATOR,
    INTERLEAVE_FIXTURE_NAME, SEPARATOR_REGISTRY,
};
pub use stem_usability::StemUsability;
pub use live::LiveAudio;
pub use registry::{tool_defs, ToolDef, ToolKind, ToolTier, EXCLUDED_COMMANDS};
pub use revise::generator::{MockGenerator, QualityRung, RegionGenerator};
pub use revise::splice;

// UniFFI proc-macro scaffolding must live at the crate root: the
// `#[uniffi::export]` / `#[derive(uniffi::Object)]` expansions in `ffi.rs`
// reference `crate::UniFfiTag`, which this macro defines.
#[cfg(feature = "ffi")]
uniffi::setup_scaffolding!("majiks_engine");
