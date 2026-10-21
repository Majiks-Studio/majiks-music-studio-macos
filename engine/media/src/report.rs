//! Top-level orchestration: decode + hash + tempo + key + loudness -> one
//! `AnalyzeReport`. Native-only (calls `decode`).

use std::path::Path;

use crate::decode::decode_to_stereo;
use crate::hash::hash_file;
use crate::key::estimate_key;
use crate::loudness::measure_loudness;
use crate::tempo::estimate_tempo;
use crate::types::AnalyzeReport;
use crate::MediaError;

/// Mirrors `engine/render/src/rt.rs::ENGINE_SAMPLE_RATE` (48 kHz). Not a
/// dependency on `render` (this crate does not depend on it; see
/// MAPPING.md) -- just the same documented v1 engine rate, used as the
/// default analysis target rate so a decoded, tempo-tracked buffer here is
/// already at the rate the render engine plays at.
pub const ENGINE_SAMPLE_RATE_HINT: u32 = 48_000;

/// Decode + hash + analyze one audio file. `declared_bpm_hint` is optional
/// context (a generation request's requested BPM, or a file's embedded
/// tag); see `tempo::estimate_tempo` for exactly how it is (and is not)
/// used.
pub fn analyze_file(path: &Path, declared_bpm_hint: Option<f64>) -> Result<AnalyzeReport, MediaError> {
    analyze_file_at_rate(path, declared_bpm_hint, ENGINE_SAMPLE_RATE_HINT)
}

/// Same as `analyze_file` but at a caller-chosen analysis sample rate
/// (exposed mainly for tests that want to avoid resampling overhead on
/// synthetic fixtures already authored at a specific rate).
pub fn analyze_file_at_rate(path: &Path, declared_bpm_hint: Option<f64>, target_sample_rate: u32) -> Result<AnalyzeReport, MediaError> {
    let decoded = decode_to_stereo(path, target_sample_rate)?;
    let content_hash = hash_file(path)?;
    let mono: Vec<f32> = decoded.frames.iter().map(|f| 0.5 * (f[0] + f[1])).collect();

    let tempo = estimate_tempo(&mono, decoded.sample_rate, declared_bpm_hint);
    let key_estimate = estimate_key(&mono, decoded.sample_rate);
    let loudness = measure_loudness(&decoded.frames, decoded.sample_rate).ok();
    let duration = decoded.duration_seconds();

    let declared_vs_measured_pct = declared_bpm_hint.filter(|d| *d > 0.0).map(|d| (tempo.bpm - d) / d * 100.0);

    Ok(AnalyzeReport {
        bpm: Some(tempo.bpm),
        key: Some(key_estimate.to_string()),
        duration: Some(duration),
        downbeats: Some(tempo.downbeats.clone()),
        loudness_lufs: loudness.as_ref().map(|l| l.integrated_lufs),
        content_hash,
        sample_rate: decoded.sample_rate,
        source_sample_rate: decoded.source_sample_rate,
        channels: decoded.source_channels,
        true_peak_dbtp: loudness.as_ref().map(|l| l.true_peak_dbtp),
        tempo: Some(tempo),
        key_estimate: Some(key_estimate),
        declared_bpm: declared_bpm_hint,
        declared_vs_measured_pct,
    })
}
