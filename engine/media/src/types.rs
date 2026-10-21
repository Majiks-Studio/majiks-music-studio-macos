//! `AnalyzeReport`: the top-level output of `report::analyze_file` (and
//! `examples/analyze.rs`'s CLI JSON).
//!
//! Field names are deliberately chosen to overlap 1:1 with
//! `engine/contracts/gen-protocol.schemas.json`'s `analyzeResponse` shape
//! (`bpm`, `key`, `duration`, `downbeats`, `loudnessLufs`) -- see
//! ../MAPPING.md -- so a consumer (L4's Gen Protocol service, or a test)
//! can project this report onto that schema by picking those five fields
//! and ignoring the rest, without a translation layer. This crate does NOT
//! depend on `engine/contracts` (see MAPPING.md for why); the overlap is
//! maintained by convention, checked by
//! `tests/gen_protocol_field_parity.rs`, not by a shared Rust type.

use serde::{Deserialize, Serialize};

use crate::key::KeyEstimate;
use crate::tempo::TempoMapEstimate;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalyzeReport {
    // --- Fields matching gen-protocol.schemas.json's analyzeResponse ---
    /// Measured BPM (`tempo.bpm`), NOT declared/tag BPM. See
    /// `tempo`'s module docs for why measured is the source of truth.
    pub bpm: Option<f64>,
    /// `"<tonic> <major|minor>"`, e.g. `"D minor"`.
    pub key: Option<String>,
    pub duration: Option<f64>,
    /// Downbeat positions in seconds (`tempo.downbeats`). Was always
    /// `null` from the Python backend as of v3.3.0
    /// (gen-protocol-mapping.md: "NOT YET PRODUCED by the Python backend
    /// ... Always null until a later lane implements it"); this crate is
    /// that lane.
    pub downbeats: Option<Vec<f64>>,
    /// Integrated LUFS. Was always `null` from the Python backend as of
    /// v3.3.0 for the same reason as `downbeats`.
    pub loudness_lufs: Option<f64>,

    // --- media-crate-only fields (no gen-protocol equivalent yet) ---
    pub content_hash: String,
    pub sample_rate: u32,
    pub source_sample_rate: u32,
    pub channels: u16,
    pub true_peak_dbtp: Option<f64>,
    /// The full tempo estimate (bpm/confidence/first_beat_offset/downbeats/
    /// beats), not just the flat `bpm`/`downbeats` fields above.
    pub tempo: Option<TempoMapEstimate>,
    pub key_estimate: Option<KeyEstimate>,
    /// Echoes the `--declared-bpm` CLI flag (or a caller-supplied hint),
    /// when given. Never influences `bpm` above except as a documented
    /// tie-breaker (see `tempo::TempoMapEstimate::declared_bpm_hint_used`).
    pub declared_bpm: Option<f64>,
    /// `(measured - declared) / declared * 100`. Positive means the audio
    /// runs faster than declared. See docs/evidence/l3-media-analysis.md
    /// for the P0-A songs' measured values (binding finding: this is
    /// routinely 1-3%, not 0, for ACE-Step output).
    pub declared_vs_measured_pct: Option<f64>,
}
