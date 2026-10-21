//! render: the realtime half of the Majik's Music Studio engine.
//!
//! Patterns lifted from the Majik's DJ engine (read-only donor,
//! majiks-dj/src-tauri/src/audio_engine.rs + clip_engine.rs + effects/*) with
//! the documented hazards fixed:
//! - no global engine singleton: `Engine::new(EngineConfig)` instances
//! - no hardcoded track count: capacity comes from `EngineConfig`
//! - SRC is rubato windowed-sinc, not linear interpolation
//! - stretch runs off-thread into pre-rendered buffers (never in the
//!   callback), coalesced latest-wins per clip
//! - the drop-thread leak path counts a stat instead of printing from the
//!   render callback
//!
//! The render callback rule (02-ARCHITECTURE.md section 3): zero allocation,
//! zero locks, zero I/O, zero syscalls. Command structs arrive over a bounded
//! lock-free channel and are drained with `try_recv` at block start; replaced
//! buffers leave through a bounded drop channel and are freed on a dedicated
//! drop thread (leak-on-full, counted). Params load once per block from
//! atomics; meters publish through atomics.

pub mod automation;
pub mod compile;
pub mod dsp;
pub mod encode;
pub mod engine;
pub mod fixtures;
pub mod guard;
pub mod host;
pub mod loudness;
pub mod media;
pub mod notes;
pub mod offline;
pub mod params;
pub mod pdc;
pub mod probe;
pub mod recording;
pub mod routing_rt;
pub mod rt;
pub mod scale;
pub mod stats;
pub mod strip;
pub mod warp;

pub use compile::DeclickPolicy;
pub use encode::{encode_aac_m4a, normalize_to_target, write_wav_i24, LoudnessTarget, NormalizeReport};
pub use engine::{Engine, EngineConfig, StreamInfo};
pub use rt::{
    CaptureBuf, RenderCommand, RtSession, ENGINE_SAMPLE_RATE, MICRO_FADE_FRAMES,
    PREVIEW_HINT_BASE, PREVIEW_VOICES,
};
pub use stats::{MeterBank, MeterSnapshot, StatsSnapshot};
pub use warp::{Stretcher, WarpWorker};
