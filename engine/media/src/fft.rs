//! Minimal real-input magnitude-spectrum helper built on `rustfft`.
//!
//! Pure math, no I/O. `rustfft` ships x86/neon SIMD backends plus a
//! wasm-simd backend and a portable scalar fallback, so this module
//! compiles and runs correctly on wasm32-unknown-unknown as well as native
//! targets (see ../MAPPING.md).

use std::sync::Arc;

use rustfft::{num_complex::Complex32, Fft, FftPlanner};

/// A pre-planned FFT of a fixed size, reused across many frames (planning
/// an FFT is not free; the onset-envelope and chroma passes call this once
/// per frame over a whole track, so planning it once up front matters).
pub struct PlannedFft {
    fft: Arc<dyn Fft<f32>>,
    window: Vec<f32>,
    scratch: Vec<Complex32>,
    size: usize,
}

impl PlannedFft {
    pub fn new(size: usize) -> Self {
        let mut planner = FftPlanner::new();
        let fft = planner.plan_fft_forward(size);
        Self { fft, window: hann_window(size), scratch: vec![Complex32::new(0.0, 0.0); size], size }
    }

    pub fn size(&self) -> usize {
        self.size
    }

    /// Magnitude spectrum (length `size / 2 + 1`) of one Hann-windowed real
    /// frame. Panics if `frame.len() != size` (internal callers always slice
    /// exact-size frames; this is a programming-error guard, not a runtime
    /// input-validation path).
    pub fn magnitude(&mut self, frame: &[f32]) -> Vec<f32> {
        assert_eq!(frame.len(), self.size, "PlannedFft::magnitude: frame length must equal the planned size");
        for (i, &s) in frame.iter().enumerate() {
            self.scratch[i] = Complex32::new(s * self.window[i], 0.0);
        }
        self.fft.process(&mut self.scratch);
        self.scratch[..self.size / 2 + 1].iter().map(|c| c.norm()).collect()
    }
}

/// Periodic Hann window of length `n` (the "periodic" variant, not
/// "symmetric": correct for STFT-style overlapping analysis).
pub fn hann_window(n: usize) -> Vec<f32> {
    if n <= 1 {
        return vec![1.0; n.max(1)];
    }
    (0..n).map(|i| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / n as f32).cos()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hann_window_endpoints_are_near_zero_and_center_is_one() {
        let w = hann_window(64);
        assert!(w[0] < 0.01);
        assert!((w[32] - 1.0).abs() < 0.01);
    }

    #[test]
    fn magnitude_of_a_pure_tone_peaks_at_the_right_bin() {
        let size = 1024;
        let sample_rate = 48_000.0;
        let target_hz = 1000.0;
        let frame: Vec<f32> = (0..size)
            .map(|i| (2.0 * std::f32::consts::PI * target_hz * i as f32 / sample_rate).sin())
            .collect();
        let mut fft = PlannedFft::new(size);
        let mag = fft.magnitude(&frame);
        let expected_bin = (target_hz * size as f32 / sample_rate).round() as usize;
        let peak_bin = mag
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .map(|(i, _)| i)
            .unwrap();
        assert!((peak_bin as i64 - expected_bin as i64).abs() <= 1, "peak_bin={peak_bin} expected~{expected_bin}");
    }
}
