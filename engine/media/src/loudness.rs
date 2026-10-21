//! Integrated loudness (LUFS) and true peak via EBU R128 (`ebur128` crate).
//!
//! Native-only (`native` feature) as a SCOPE choice, not a hard technical
//! limit: `ebur128` is pure Rust with no C dependency (its optional `cc`
//! build-dependency is only for its own reference tests against the
//! original C libebur128, a feature this crate never enables), so it could
//! plausibly join the wasm32 pure-math set later if a consumer needs
//! loudness metering in the browser. Kept native-default for now to match
//! the acceptance bar (tile/peak math is what's required to compile under
//! wasm32) and to keep the wasm feature's surface minimal and easy to
//! reason about.

use ebur128::{EbuR128, Mode};

use crate::error::MediaError;

#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct LoudnessEstimate {
    pub integrated_lufs: f64,
    pub true_peak_dbtp: f64,
}

/// Measures integrated (program) loudness and true peak over a whole
/// stereo buffer. EBU R128 integrated measurement needs a minimum amount of
/// audio to form a valid gating block; very short/near-silent input surfaces
/// as an `Err` from the underlying crate rather than a fabricated number.
pub fn measure_loudness(stereo: &[[f32; 2]], sample_rate: u32) -> Result<LoudnessEstimate, MediaError> {
    let mut state = EbuR128::new(2, sample_rate, Mode::I | Mode::TRUE_PEAK).map_err(|e| MediaError::Loudness(format!("{e}")))?;
    let interleaved: Vec<f32> = stereo.iter().flat_map(|f| [f[0], f[1]]).collect();
    state.add_frames_f32(&interleaved).map_err(|e| MediaError::Loudness(format!("{e}")))?;
    let integrated_lufs = state.loudness_global().map_err(|e| MediaError::Loudness(format!("{e}")))?;
    let peak_l = state.true_peak(0).map_err(|e| MediaError::Loudness(format!("{e}")))?;
    let peak_r = state.true_peak(1).map_err(|e| MediaError::Loudness(format!("{e}")))?;
    // ebur128::true_peak returns LINEAR amplitude; dBTP = 20*log10(peak)
    // (per the crate's own doc comment on `true_peak`).
    let peak_linear = peak_l.max(peak_r).max(1e-12);
    let true_peak_dbtp = 20.0 * peak_linear.log10();
    Ok(LoudnessEstimate { integrated_lufs, true_peak_dbtp })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_scale_tone_reads_plausible_loudness_and_peak() {
        let sample_rate = 48_000u32;
        let mut stereo = Vec::new();
        for i in 0..sample_rate as usize * 3 {
            let t = i as f32 / sample_rate as f32;
            let s = (2.0 * std::f32::consts::PI * 1000.0 * t).sin() * 0.999;
            stereo.push([s, s]);
        }
        let est = measure_loudness(&stereo, sample_rate).unwrap();
        // A near-full-scale 1kHz sine sits close to -3 LUFS integrated and
        // just under 0 dBTP; loose bounds, not a calibration test.
        assert!(est.integrated_lufs > -6.0 && est.integrated_lufs < 0.0, "lufs={}", est.integrated_lufs);
        assert!(est.true_peak_dbtp > -2.0 && est.true_peak_dbtp <= 3.0, "dbtp={}", est.true_peak_dbtp);
    }

    #[test]
    fn silence_does_not_panic_even_if_measurement_is_an_error() {
        let stereo = vec![[0.0f32, 0.0f32]; 48_000 * 2];
        // Silence has no gated loudness blocks above the absolute
        // threshold; accept either a very-low reading or an Err, just
        // don't panic.
        let _ = measure_loudness(&stereo, 48_000);
    }
}
