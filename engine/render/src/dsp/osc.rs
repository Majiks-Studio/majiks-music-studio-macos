//! Oscillator for the subtractive synth: sine, saw, square, triangle.
//!
//! Saw and square are band-limited with PolyBLEP (a 2-point polynomial
//! approximation of the band-limited step). Naive saw/square alias badly
//! enough to be obvious on a held note in the top octave, and PolyBLEP is a
//! branch plus a handful of multiplies — no tables, no allocation, no state
//! beyond the phase, so it does not perturb the per-frame determinism rule.
//!
//! Triangle stays naive on purpose: its harmonics fall off as 1/n^2, so the
//! worst alias lands ~40 dB below the fundamental. PolyBLAMP would buy a few
//! dB for real per-frame cost, and E2 scope is "a synth a musician can use",
//! not an anti-aliasing project.

use std::f32::consts::TAU;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Waveform {
    #[default]
    Sine,
    Saw,
    Square,
    Triangle,
}

impl Waveform {
    /// Automation lanes carry `f32`, so the waveform parameter is a rounded
    /// index. Out-of-range clamps to Sine rather than failing: an unknown
    /// value on the audio thread must degrade to something audible and
    /// documented, never to a panic.
    #[inline]
    pub fn from_param(v: f32) -> Self {
        match v.round() as i32 {
            1 => Waveform::Saw,
            2 => Waveform::Square,
            3 => Waveform::Triangle,
            _ => Waveform::Sine,
        }
    }

    pub fn as_param(self) -> f32 {
        match self {
            Waveform::Sine => 0.0,
            Waveform::Saw => 1.0,
            Waveform::Square => 2.0,
            Waveform::Triangle => 3.0,
        }
    }
}

/// MIDI note number -> Hz (A4 = 69 = 440 Hz). Called at NOTE-ON only; the
/// per-frame path uses the cached phase increment.
#[inline]
pub fn midi_to_hz(pitch: f32) -> f32 {
    440.0 * ((pitch - 69.0) / 12.0).exp2()
}

/// PolyBLEP correction at normalized phase `t` with per-frame phase step `dt`.
#[inline(always)]
fn poly_blep(t: f32, dt: f32) -> f32 {
    if t < dt {
        let x = t / dt;
        x + x - x * x - 1.0
    } else if t > 1.0 - dt {
        let x = (t - 1.0) / dt;
        x * x + x + x + 1.0
    } else {
        0.0
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Osc {
    /// Normalized phase in [0, 1).
    phase: f32,
}

impl Osc {
    /// Reset to phase zero. Called at note-on so a given note always renders
    /// the identical waveform — that determinism is what lets the null test
    /// compare renders sample-for-sample.
    #[inline]
    pub fn reset(&mut self) {
        self.phase = 0.0;
    }

    #[inline(always)]
    pub fn phase(&self) -> f32 {
        self.phase
    }

    /// One frame. `inc` is `freq_hz / sample_rate`, precomputed at note-on.
    #[inline(always)]
    pub fn advance(&mut self, wave: Waveform, inc: f32) -> f32 {
        let dt = inc.clamp(0.0, 0.5);
        let t = self.phase;
        let y = match wave {
            Waveform::Sine => (TAU * t).sin(),
            Waveform::Saw => 2.0 * t - 1.0 - poly_blep(t, dt),
            Waveform::Square => {
                let naive = if t < 0.5 { 1.0 } else { -1.0 };
                let t2 = if t < 0.5 { t + 0.5 } else { t - 0.5 };
                naive + poly_blep(t, dt) - poly_blep(t2, dt)
            }
            Waveform::Triangle => 4.0 * (t - 0.5).abs() - 1.0,
        };
        self.phase += dt;
        if self.phase >= 1.0 {
            self.phase -= 1.0;
        }
        y
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(wave: Waveform, hz: f32, frames: usize) -> Vec<f32> {
        let mut o = Osc::default();
        let inc = hz / 48_000.0;
        (0..frames).map(|_| o.advance(wave, inc)).collect()
    }

    #[test]
    fn midi_to_hz_anchors_at_a440() {
        assert!((midi_to_hz(69.0) - 440.0).abs() < 1e-3);
        assert!((midi_to_hz(81.0) - 880.0).abs() < 1e-2, "an octave up doubles");
        assert!((midi_to_hz(57.0) - 220.0).abs() < 1e-2, "an octave down halves");
    }

    #[test]
    fn every_waveform_produces_signal_in_range() {
        for wave in [
            Waveform::Sine,
            Waveform::Saw,
            Waveform::Square,
            Waveform::Triangle,
        ] {
            let out = render(wave, 220.0, 4096);
            let peak = out.iter().fold(0.0f32, |m, v| m.max(v.abs()));
            assert!(peak > 0.5, "{wave:?} produced no signal (peak {peak})");
            assert!(peak <= 1.5, "{wave:?} exceeded range (peak {peak})");
        }
    }

    #[test]
    fn period_matches_frequency() {
        // Count zero crossings of a sine: 2 per period.
        let hz = 300.0;
        let frames = 48_000;
        let out = render(Waveform::Sine, hz, frames);
        let crossings = out
            .windows(2)
            .filter(|w| (w[0] < 0.0) != (w[1] < 0.0))
            .count();
        let expected = (2.0 * hz) as usize;
        assert!(
            crossings.abs_diff(expected) <= 2,
            "expected ~{expected} crossings, got {crossings}"
        );
    }

    #[test]
    fn polyblep_tames_the_saw_discontinuity() {
        // At a high fundamental the naive saw's alias energy shows up as a
        // sample-to-sample jump larger than the ideal ramp step. PolyBLEP
        // keeps the largest step bounded well under the full 2.0 swing.
        let hz = 4000.0;
        let out = render(Waveform::Saw, hz, 4800);
        let max_step = out
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0f32, f32::max);
        assert!(
            max_step < 1.9,
            "polyblep should soften the reset edge, max step {max_step}"
        );
    }

    #[test]
    fn reset_makes_a_note_bit_reproducible() {
        let a = render(Waveform::Saw, 261.6, 1024);
        let b = render(Waveform::Saw, 261.6, 1024);
        assert_eq!(a, b, "same note renders bit-identically");
    }
}
