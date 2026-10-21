//! `engine/media`: decode, sample-rate conversion, waveform peak tiles, and
//! audio analysis (tempo, key, loudness) for Majik's Music Studio.
//!
//! Owned by lane L3 (see docs/evidence/l3-media-analysis.md). Standalone
//! crate: NOT a member of `../Cargo.toml`'s workspace (see this crate's own
//! `[workspace]` table and MAPPING.md) so it builds independently of lane
//! L1's timeline-core/render workspace; the coordinator adds `"media"` to
//! `../Cargo.toml`'s `members` at merge.
//!
//! ## Feature split (see MAPPING.md)
//!
//! - `default = ["native"]`: decode (symphonia), resample (rubato),
//!   loudness (ebur128), blake3 file hashing, the threaded/cancel-safe tile
//!   job + disk cache (std::fs, std::thread, crossbeam-channel).
//! - Pure math -- tempo, key, waveform peak min/max, the small FFT helper,
//!   in-memory blake3 hashing -- has NO feature gate: it compiles on any
//!   target, including `wasm32-unknown-unknown`, via
//!   `cargo build --target wasm32-unknown-unknown --no-default-features`
//!   (alias `--features wasm`, an empty marker feature for CI clarity; see
//!   docs/evidence/l3-media-analysis.md for the exact command and result).
//!
//! ## Binding product fact (P0-A, carried into `tempo`'s module docs)
//!
//! Generated songs drift 1.2-2.9% from their declared/metadata BPM
//! (docs/evidence/p0a-repaint.md). `tempo::TempoMapEstimate::bpm` is
//! measured from audio, never copied from a tag or generation request, and
//! is the DAW's bar-snap source of truth; declared/metadata BPM is only a
//! prior (see `tempo::estimate_tempo`'s `declared_bpm_hint` parameter).

pub mod error;
pub mod fft;
pub mod hash;
pub mod key;
pub mod tempo;
pub mod tiles;
pub mod types;

#[cfg(feature = "native")]
pub mod decode;
#[cfg(feature = "native")]
pub mod loudness;
#[cfg(feature = "native")]
pub mod report;
#[cfg(feature = "native")]
pub mod tile_job;

pub use error::MediaError;
pub use types::AnalyzeReport;
