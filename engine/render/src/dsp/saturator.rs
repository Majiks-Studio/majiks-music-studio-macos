//! `FxKind::Saturator` (`DESIGN-E5-routing.md` §17.1): *"waveshaper +
//! oversample-free `tanh`-style curve, `Slew`'d drive"*.
//!
//! Curve: `y = tanh(g·x) / g`, with `g = 10^(drive_dB/20)`.
//!
//! Dividing by `g` (rather than by `tanh(g)`) is deliberate: the small-signal
//! slope is `tanh'(0)·g/g = 1`, so quiet material passes at **unity** and the
//! drive control adds harmonics without also adding a level change the user
//! has to undo. Peaks compress smoothly; the curve is odd, so it generates
//! odd harmonics only, which is what makes it read as "saturation" and not as
//! "distortion with a DC offset".
//!
//! **No oversampling, by design.** Oversampling would need either a per-block
//! FFT (forbidden, §16.7) or polyphase filters with latency (§19 pressure).
//! The cost is aliasing on very bright material at high drive; that is a known
//! and stated trade, not an oversight.
//!
//! Zero latency, per-frame, allocation-free.

use crate::dsp::fx::{mix_frames, read_param, FxKindId, FxNode};
use crate::params::EngineParams;
use crate::dsp::slew::Slew;
use crate::dsp::{db_to_lin, lin_to_db};

pub struct SaturatorFx {
    drive: Slew,
    output: Slew,
    mix: Slew,
    drive_target: f32,
    output_target: f32,
    mix_target: f32,
    /// Lane fast paths for the two dB keys (`drive`, `gain`): (last dB, its
    /// linear value) pairs — `Strip::vol_lane_lin`'s change-gated cache.
    drive_db_cache: f32,
    drive_lin_cache: f32,
    output_db_cache: f32,
    output_lin_cache: f32,
}

impl SaturatorFx {
    pub fn new(_sample_rate: u32, ramp_frames: u32) -> Self {
        let step = 1.0 / ramp_frames.max(1) as f32;
        let k = FxKindId::Saturator;
        let d = |i: usize| k.params()[i].default;
        let drive = db_to_lin(d(0));
        let out = db_to_lin(d(2));
        Self {
            // Linear-gain slews cross their full range over the declick
            // window scaled by that range, so a big jump still declicks.
            drive: Slew::new(drive, 64.0 * step),
            output: Slew::new(out, 16.0 * step),
            mix: Slew::new(d(1), step),
            drive_target: drive,
            output_target: out,
            mix_target: d(1),
            drive_db_cache: d(0),
            drive_lin_cache: drive,
            output_db_cache: d(2),
            output_lin_cache: out,
        }
    }

    /// The static transfer curve. Unity slope at zero, odd-symmetric.
    #[inline(always)]
    pub fn shape(x: f32, g: f32) -> f32 {
        let g = g.max(1.0e-6);
        (g * x).tanh() / g
    }

    /// Drive in dB that produces linear gain `g`. Test convenience.
    pub fn drive_db(g: f32) -> f32 {
        lin_to_db(g)
    }
}

impl FxNode for SaturatorFx {
    #[inline]
    fn process_frame(&mut self, x: [f32; 2], _key: [f32; 2]) -> [f32; 2] {
        let g = self.drive.advance(self.drive_target);
        let out = self.output.advance(self.output_target);
        let m = self.mix.advance(self.mix_target);
        let wet = [
            Self::shape(x[0], g) * out,
            Self::shape(x[1], g) * out,
        ];
        mix_frames(x, wet, m)
    }

    fn load_block_targets(&mut self, p: &EngineParams, base_slot: usize) {
        let k = FxKindId::Saturator;
        self.drive_target = db_to_lin(read_param(p, base_slot, k, 0));
        self.mix_target = read_param(p, base_slot, k, 1);
        self.output_target = db_to_lin(read_param(p, base_slot, k, 2));
    }

    fn set_frame_param(&mut self, index: usize, value: f32) {
        match index {
            // Cache pairs + UNCONDITIONAL apply (compare gates the
            // reconversion only, never the apply).
            0 => {
                if value != self.drive_db_cache {
                    self.drive_db_cache = value;
                    self.drive_lin_cache = db_to_lin(value);
                }
                self.drive_target = self.drive_lin_cache;
            }
            1 => self.mix_target = value,
            2 => {
                if value != self.output_db_cache {
                    self.output_db_cache = value;
                    self.output_lin_cache = db_to_lin(value);
                }
                self.output_target = self.output_lin_cache;
            }
            _ => debug_assert!(false, "Saturator has no Frame param index {index}"),
        }
    }

    fn reset(&mut self) {
        self.drive.snap(self.drive_target);
        self.output.snap(self.output_target);
        self.mix.snap(self.mix_target);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn curve_is_odd_symmetric() {
        for g in [0.5_f32, 1.0, 4.0, 16.0] {
            for x in [0.01_f32, 0.2, 0.5, 0.9, 1.5] {
                let a = SaturatorFx::shape(x, g);
                let b = SaturatorFx::shape(-x, g);
                assert!((a + b).abs() < 1e-7, "g={g} x={x}: {a} {b}");
            }
        }
    }

    #[test]
    fn small_signal_gain_is_unity_at_every_drive() {
        // The property that makes `drive` a tone control rather than a level
        // control: a division by tanh(g) instead of by g would fail this.
        for g in [0.5_f32, 1.0, 4.0, 16.0, 63.0] {
            let x = 1.0e-4_f32;
            let y = SaturatorFx::shape(x, g);
            assert!(
                (y / x - 1.0).abs() < 1e-3,
                "g={g}: small-signal gain {}",
                y / x
            );
        }
    }

    #[test]
    fn higher_drive_compresses_peaks_harder() {
        let x = 0.9_f32;
        let mut last = f32::INFINITY;
        for g in [1.0_f32, 2.0, 4.0, 8.0, 16.0] {
            let ratio = SaturatorFx::shape(x, g) / x;
            assert!(ratio < last, "g={g} ratio {ratio} not below {last}");
            last = ratio;
        }
    }

    #[test]
    fn drive_db_round_trips() {
        assert!((SaturatorFx::drive_db(db_to_lin(12.0)) - 12.0).abs() < 1e-3);
    }
}
