//! Inter-sample (true) peak estimation: 4x polyphase FIR interpolation in
//! the spirit of ITU-R BS.1770-4 Annex 2. Used by the limiter's detector and
//! the master true-peak meter.
//!
//! 48-tap windowed-sinc lowpass split into 4 phases of 12 taps; each phase
//! is normalized to unity DC gain so steady signals measure exactly. The
//! detector keeps a 12-frame history ring per channel; per input frame it
//! evaluates the 4 interpolation phases and returns the largest magnitude
//! (including the raw sample itself).

pub const PHASES: usize = 4;
pub const TAPS_PER_PHASE: usize = 12;
const TOTAL_TAPS: usize = PHASES * TAPS_PER_PHASE;

/// Group delay of the interpolator in input frames (for limiter alignment).
pub const DETECTOR_DELAY_FRAMES: usize = TAPS_PER_PHASE / 2 + 2;

fn blackman_harris(n: usize, len: usize) -> f64 {
    let x = std::f64::consts::TAU * n as f64 / (len as f64 - 1.0);
    0.35875 - 0.48829 * x.cos() + 0.14128 * (2.0 * x).cos() - 0.01168 * (3.0 * x).cos()
}

fn sinc(x: f64) -> f64 {
    if x.abs() < 1e-12 {
        1.0
    } else {
        let px = std::f64::consts::PI * x;
        px.sin() / px
    }
}

/// Build the polyphase bank: phase p, tap j applies to input frame (n - j).
fn build_bank() -> [[f32; TAPS_PER_PHASE]; PHASES] {
    let center = (TOTAL_TAPS - 1) as f64 / 2.0;
    let mut proto = [0.0_f64; TOTAL_TAPS];
    for (n, v) in proto.iter_mut().enumerate() {
        let t = (n as f64 - center) / PHASES as f64;
        *v = sinc(t) * blackman_harris(n, TOTAL_TAPS);
    }
    let mut bank = [[0.0_f32; TAPS_PER_PHASE]; PHASES];
    for (p, phase) in bank.iter_mut().enumerate() {
        // Phase p interpolates offset p/4 between samples: taps are the
        // prototype decimated by 4 starting at p.
        let mut sum = 0.0_f64;
        let mut taps = [0.0_f64; TAPS_PER_PHASE];
        for (j, tap) in taps.iter_mut().enumerate() {
            *tap = proto[j * PHASES + p];
            sum += *tap;
        }
        // Unity DC gain per phase.
        for (j, tap) in taps.iter().enumerate() {
            phase[j] = (*tap / sum) as f32;
        }
    }
    bank
}

pub struct TruePeakDetector {
    bank: [[f32; TAPS_PER_PHASE]; PHASES],
    history: [[f32; TAPS_PER_PHASE]; 2],
    write: usize,
}

impl TruePeakDetector {
    pub fn new() -> Self {
        Self {
            bank: build_bank(),
            history: [[0.0; TAPS_PER_PHASE]; 2],
            write: 0,
        }
    }

    pub fn reset(&mut self) {
        self.history = [[0.0; TAPS_PER_PHASE]; 2];
        self.write = 0;
    }

    /// Push one stereo frame, return the true-peak magnitude estimate for
    /// the neighborhood of this frame (max over both channels, all phases,
    /// and the raw sample).
    #[inline]
    pub fn process_frame(&mut self, frame: [f32; 2]) -> f32 {
        self.history[0][self.write] = frame[0];
        self.history[1][self.write] = frame[1];
        self.write = (self.write + 1) % TAPS_PER_PHASE;

        let mut peak = frame[0].abs().max(frame[1].abs());
        for ch in 0..2 {
            let hist = &self.history[ch];
            for phase in &self.bank {
                let mut acc = 0.0_f32;
                // Tap j reads the sample written j frames ago.
                let mut idx = self.write; // oldest position after increment
                // history[write - 1] is newest; walk backwards j = 0..12.
                for tap in phase.iter() {
                    idx = if idx == 0 { TAPS_PER_PHASE - 1 } else { idx - 1 };
                    acc += *tap * hist[idx];
                }
                peak = peak.max(acc.abs());
            }
        }
        peak
    }
}

impl Default for TruePeakDetector {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 12 kHz sine sampled at 48 kHz whose peaks land BETWEEN samples:
    /// sample peaks measure ~0.7071 of the true peak. The detector must see
    /// (close to) the true value.
    #[test]
    fn detects_inter_sample_peaks() {
        let mut det = TruePeakDetector::new();
        let freq = 12_000.0_f32;
        let mut sample_peak = 0.0_f32;
        let mut true_peak = 0.0_f32;
        for i in 0..4_800 {
            // Phase offset pi/4 puts continuous peaks exactly between samples.
            let phase = std::f32::consts::TAU * freq * i as f32 / 48_000.0
                + std::f32::consts::FRAC_PI_4;
            let v = phase.sin();
            sample_peak = sample_peak.max(v.abs());
            true_peak = true_peak.max(det.process_frame([v, v]));
        }
        assert!(sample_peak < 0.72, "constructed inter-sample case: {sample_peak}");
        assert!(
            true_peak > 0.97 && true_peak < 1.05,
            "true peak of a unit sine should read ~1.0, got {true_peak}"
        );
    }

    #[test]
    fn dc_measures_exactly() {
        let mut det = TruePeakDetector::new();
        let mut peak = 0.0_f32;
        for _ in 0..100 {
            peak = det.process_frame([0.5, 0.5]);
        }
        assert!((peak - 0.5).abs() < 1e-4, "DC gain per phase is unity: {peak}");
    }
}
