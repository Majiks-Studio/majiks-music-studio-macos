//! `FxKind::Utility` (`DESIGN-E5-routing.md` §17.1): *"gain / pan
//! (`dsp/pan.rs`) / width / polarity invert"*.
//!
//! The pan law is the existing `pan::balance_gains` — the same equal-power
//! balance the strip uses, so a Utility at centre is a bit-exact
//! pass-through and a Utility panned hard behaves identically to the channel
//! fader's pan. Reimplementing the law here would let the two drift.
//!
//! Width is mid/side: `M = (L+R)/2`, `S = (L−R)/2`, `S *= width`. At
//! `width == 1.0` the M/S round trip is **skipped entirely** rather than
//! computed — `(L+R)·0.5 + (L−R)·0.5` is not bit-identically `L` in f32, and
//! §20.2 proof 1 needs a Utility that only changes what it was asked to
//! change.
//!
//! Zero latency, per-frame, allocation-free.

use crate::dsp::fx::{read_param, FxKindId, FxNode};
use crate::params::EngineParams;
use crate::dsp::pan::balance_gains;
use crate::dsp::slew::Slew;
use crate::dsp::{db_to_lin, flush_denormal};

pub struct UtilityFx {
    gain: Slew,
    pan: Slew,
    width: Slew,
    gain_target: f32,
    pan_target: f32,
    width_target: f32,
    invert: Slew,
    invert_target: f32,
    /// Lane fast path for `gain` (dB): (last dB, its linear value) —
    /// `Strip::vol_lane_lin`'s change-gated cache.
    gain_db_cache: f32,
    gain_lin_cache: f32,
}

impl UtilityFx {
    pub fn new(_sample_rate: u32, ramp_frames: u32) -> Self {
        let step = 1.0 / ramp_frames.max(1) as f32;
        let k = FxKindId::Utility;
        let d = |i: usize| k.params()[i].default;
        let g = db_to_lin(d(0));
        Self {
            gain: Slew::new(g, 16.0 * step),
            pan: Slew::new(d(1), 2.0 * step),
            width: Slew::new(d(2), 2.0 * step),
            gain_target: g,
            pan_target: d(1),
            width_target: d(2),
            // Polarity flip crossfades through zero over the declick window
            // instead of stepping from +x to -x, which is a click at any level.
            invert: Slew::new(1.0, 2.0 * step),
            invert_target: 1.0,
            gain_db_cache: d(0),
            gain_lin_cache: g,
        }
    }
}

impl FxNode for UtilityFx {
    #[inline]
    fn process_frame(&mut self, x: [f32; 2], _key: [f32; 2]) -> [f32; 2] {
        let width = self.width.advance(self.width_target);
        let mut out = if width == 1.0 {
            x
        } else {
            let m = (x[0] + x[1]) * 0.5;
            let s = (x[0] - x[1]) * 0.5 * width;
            [flush_denormal(m + s), flush_denormal(m - s)]
        };

        let g = self.gain.advance(self.gain_target) * self.invert.advance(self.invert_target);
        let (gl, gr) = balance_gains(self.pan.advance(self.pan_target));
        out[0] *= g * gl;
        out[1] *= g * gr;
        out
    }

    fn load_block_targets(&mut self, p: &EngineParams, base_slot: usize) {
        let k = FxKindId::Utility;
        self.gain_target = db_to_lin(read_param(p, base_slot, k, 0));
        self.pan_target = read_param(p, base_slot, k, 1);
        self.width_target = read_param(p, base_slot, k, 2);
        self.invert_target = if read_param(p, base_slot, k, 3) >= 0.5 {
            -1.0
        } else {
            1.0
        };
    }

    fn set_frame_param(&mut self, index: usize, value: f32) {
        match index {
            // Cache pair + UNCONDITIONAL apply (compare gates the
            // reconversion only, never the apply).
            0 => {
                if value != self.gain_db_cache {
                    self.gain_db_cache = value;
                    self.gain_lin_cache = db_to_lin(value);
                }
                self.gain_target = self.gain_lin_cache;
            }
            1 => self.pan_target = value,
            2 => self.width_target = value,
            // A polarity lane rides the same through-zero crossfade a block
            // change does; the Slew makes the flip a ramp either way.
            3 => self.invert_target = if value >= 0.5 { -1.0 } else { 1.0 },
            _ => debug_assert!(false, "Utility has no Frame param index {index}"),
        }
    }

    fn reset(&mut self) {
        self.gain.snap(self.gain_target);
        self.pan.snap(self.pan_target);
        self.width.snap(self.width_target);
        self.invert.snap(self.invert_target);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dsp::fx::{seed_fx_defaults, set_fx_param_by_key};

    fn settled(u: &mut UtilityFx) {
        for _ in 0..2_000 {
            u.process_frame([0.0, 0.0], [0.0, 0.0]);
        }
    }

    #[test]
    fn defaults_are_a_bit_exact_passthrough() {
        let mut u = UtilityFx::new(48_000, 240);
        let p = EngineParams::new(1);
        seed_fx_defaults(&p, FxKindId::Utility, 0);
        u.load_block_targets(&p, 0);
        settled(&mut u);
        for i in 0..500 {
            let x = [(i as f32 * 0.01).sin(), (i as f32 * 0.013).cos()];
            assert_eq!(u.process_frame(x, [0.0, 0.0]), x, "frame {i}");
        }
    }

    #[test]
    fn minus_six_db_halves_the_signal() {
        let mut u = UtilityFx::new(48_000, 240);
        let p = EngineParams::new(1);
        seed_fx_defaults(&p, FxKindId::Utility, 0);
        assert!(set_fx_param_by_key(&p, FxKindId::Utility, 0, "gain", -6.0206));
        u.load_block_targets(&p, 0);
        settled(&mut u);
        let out = u.process_frame([1.0, 1.0], [0.0, 0.0]);
        assert!((out[0] - 0.5).abs() < 1e-4, "{out:?}");
        assert!((out[1] - 0.5).abs() < 1e-4, "{out:?}");
    }

    #[test]
    fn width_zero_collapses_to_mono_and_two_widens() {
        let mut u = UtilityFx::new(48_000, 240);
        let p = EngineParams::new(1);
        seed_fx_defaults(&p, FxKindId::Utility, 0);
        assert!(set_fx_param_by_key(&p, FxKindId::Utility, 0, "width", 0.0));
        u.load_block_targets(&p, 0);
        settled(&mut u);
        let out = u.process_frame([1.0, 0.0], [0.0, 0.0]);
        assert!((out[0] - 0.5).abs() < 1e-6 && (out[1] - 0.5).abs() < 1e-6, "{out:?}");

        assert!(set_fx_param_by_key(&p, FxKindId::Utility, 0, "width", 2.0));
        u.load_block_targets(&p, 0);
        settled(&mut u);
        let out = u.process_frame([1.0, 0.0], [0.0, 0.0]);
        assert!((out[0] - 1.5).abs() < 1e-6 && (out[1] + 0.5).abs() < 1e-6, "{out:?}");
    }

    #[test]
    fn invert_flips_polarity_and_ramps_through_zero() {
        let mut u = UtilityFx::new(48_000, 240);
        let p = EngineParams::new(1);
        seed_fx_defaults(&p, FxKindId::Utility, 0);
        u.load_block_targets(&p, 0);
        settled(&mut u);
        assert_eq!(u.process_frame([1.0, 1.0], [0.0, 0.0]), [1.0, 1.0]);

        assert!(set_fx_param_by_key(&p, FxKindId::Utility, 0, "polarity", 1.0));
        u.load_block_targets(&p, 0);
        let mut prev = 1.0_f32;
        let mut max_step = 0.0_f32;
        for _ in 0..600 {
            let v = u.process_frame([1.0, 1.0], [0.0, 0.0])[0];
            max_step = max_step.max((v - prev).abs());
            prev = v;
        }
        assert!((prev + 1.0).abs() < 1e-6, "polarity flipped: {prev}");
        assert!(max_step < 0.02, "flip ramped rather than stepped: {max_step}");
    }

    #[test]
    fn pan_uses_the_shared_balance_law() {
        let mut u = UtilityFx::new(48_000, 240);
        let p = EngineParams::new(1);
        seed_fx_defaults(&p, FxKindId::Utility, 0);
        assert!(set_fx_param_by_key(&p, FxKindId::Utility, 0, "pan", 0.5));
        u.load_block_targets(&p, 0);
        settled(&mut u);
        let out = u.process_frame([1.0, 1.0], [0.0, 0.0]);
        let (gl, gr) = balance_gains(0.5);
        assert!((out[0] - gl).abs() < 1e-6 && (out[1] - gr).abs() < 1e-6, "{out:?}");
    }
}
