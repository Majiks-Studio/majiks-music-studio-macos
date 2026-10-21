//! `FxKind::Chorus` (`DESIGN-E5-routing.md` §17.1): *"short modulated delay
//! off `DelayBus`'s ring pattern"*.
//!
//! It follows `dsp/delay.rs`'s ring shape — a fixed `Box<[f32]>` per channel
//! with index arithmetic, never a `VecDeque` — but cannot literally reuse
//! `DelayBus`, whose tap is an *integer* frame count resolved control-side. A
//! chorus needs a *fractional*, continuously moving tap; snapping it to whole
//! frames is what makes a cheap chorus sound gritty. So the ring pattern is
//! reused and the read is linearly interpolated.
//!
//! ## The physics the test measures
//!
//! With delay `d(t) = base + depth·sin(2π·rate·t)` the output is the input
//! evaluated at `t − d(t)`, so the instantaneous frequency ratio is
//! `1 − d′(t) = 1 − depth·2π·rate·cos(2π·rate·t)`.
//!
//! The peak fractional pitch deviation is therefore **exactly
//! `2π · rate · depth_seconds`** — a number that constrains `rate` and `depth`
//! *jointly*. `render/tests/fx.rs` measures it from interpolated zero
//! crossings of a rendered tone and checks it against that formula, which is
//! why an implementation that ignored `depth` (or that quantised the tap to
//! whole frames, killing the modulation) cannot pass.
//!
//! Zero latency in the PDC sense (§19): the effect *is* a delay, but it adds
//! no delay to a dry path — `mix = 0` is an exact passthrough and the wet
//! signal's lateness is the effect, exactly as for the legacy FX buses (§9.1).

use crate::dsp::fx::{mix_frames, read_param, FxKindId, FxNode};
use crate::params::EngineParams;
use crate::dsp::slew::Slew;
use crate::dsp::flush_denormal;

/// Ring length in milliseconds. Comfortably above `BASE_DELAY_MS + max depth`.
const RING_MS: f32 = 60.0;
/// Centre delay of the modulated tap.
pub const BASE_DELAY_MS: f32 = 10.0;
/// The tap never gets closer to the write head than this (interpolation needs
/// two valid neighbours).
const MIN_DELAY_FRAMES: f32 = 2.0;

pub struct ChorusFx {
    rings: [Box<[f32]>; 2],
    write: usize,
    len: usize,
    sample_rate: f32,
    /// LFO phase in cycles, [0, 1).
    phase: f32,

    rate: Slew,
    depth_ms: Slew,
    mix: Slew,
    rate_target: f32,
    depth_target: f32,
    mix_target: f32,
    /// Right-channel LFO offset in cycles.
    spread: f32,
}

impl ChorusFx {
    pub fn new(sample_rate: u32, ramp_frames: u32) -> Self {
        let sr = sample_rate.max(1) as f32;
        let len = ((RING_MS * 0.001 * sr) as usize).max(64);
        let step = 1.0 / ramp_frames.max(1) as f32;
        let k = FxKindId::Chorus;
        let d = |i: usize| k.params()[i].default;
        Self {
            rings: [
                vec![0.0; len].into_boxed_slice(),
                vec![0.0; len].into_boxed_slice(),
            ],
            write: 0,
            len,
            sample_rate: sr,
            phase: 0.0,
            rate: Slew::new(d(0), 20.0 * step),
            depth_ms: Slew::new(d(1), 9.0 * step),
            mix: Slew::new(d(2), step),
            rate_target: d(0),
            depth_target: d(1),
            mix_target: d(2),
            spread: d(3),
        }
    }

    /// Peak fractional pitch deviation for a given rate/depth, i.e.
    /// `2π · rate · depth_seconds`. The identity the rendered proof checks.
    pub fn expected_pitch_deviation(rate_hz: f32, depth_ms: f32) -> f32 {
        2.0 * std::f32::consts::PI * rate_hz * depth_ms * 0.001
    }

    /// Linear-interpolated read `d` frames behind the write head.
    #[inline(always)]
    fn read_frac(&self, ch: usize, d: f32) -> f32 {
        let len_f = self.len as f32;
        let d = d.clamp(MIN_DELAY_FRAMES, len_f - 2.0);
        let mut pos = self.write as f32 - d;
        if pos < 0.0 {
            pos += len_f;
        }
        let i0 = pos.floor();
        let frac = pos - i0;
        let i0 = (i0 as usize) % self.len;
        let i1 = (i0 + 1) % self.len;
        let a = self.rings[ch][i0];
        let b = self.rings[ch][i1];
        a + (b - a) * frac
    }
}

impl FxNode for ChorusFx {
    #[inline]
    fn process_frame(&mut self, x: [f32; 2], _key: [f32; 2]) -> [f32; 2] {
        let rate = self.rate.advance(self.rate_target);
        let depth_ms = self.depth_ms.advance(self.depth_target);
        let mix = self.mix.advance(self.mix_target);

        let base = BASE_DELAY_MS * 0.001 * self.sample_rate;
        let depth = depth_ms * 0.001 * self.sample_rate;

        let mut wet = [0.0_f32; 2];
        for ch in 0..2 {
            let ph = self.phase + if ch == 1 { self.spread } else { 0.0 };
            let lfo = (2.0 * std::f32::consts::PI * ph).sin();
            wet[ch] = self.read_frac(ch, base + depth * lfo);
        }

        for ch in 0..2 {
            self.rings[ch][self.write] = flush_denormal(x[ch]);
        }
        self.write += 1;
        if self.write >= self.len {
            self.write = 0;
        }

        // Per FRAME, so the LFO is at the same place at frame N regardless of
        // how the frames were chunked into blocks.
        self.phase += rate / self.sample_rate;
        if self.phase >= 1.0 {
            self.phase -= 1.0;
        }

        mix_frames(x, wet, mix)
    }

    fn load_block_targets(&mut self, p: &EngineParams, base_slot: usize) {
        let k = FxKindId::Chorus;
        self.rate_target = read_param(p, base_slot, k, 0);
        self.depth_target = read_param(p, base_slot, k, 1);
        self.mix_target = read_param(p, base_slot, k, 2);
        self.spread = read_param(p, base_slot, k, 3);
    }

    fn set_frame_param(&mut self, index: usize, value: f32) {
        match index {
            // `rate` and `depth` already resolve to per-frame arithmetic in
            // `process_frame` (phase increment, ms -> frames multiply); the
            // lane just supplies the target per frame and the existing Slews
            // smooth it. `spread` is a direct phase offset, exactly as the
            // block path treats it.
            0 => self.rate_target = value,
            1 => self.depth_target = value,
            2 => self.mix_target = value,
            3 => self.spread = value,
            _ => debug_assert!(false, "Chorus has no Frame param index {index}"),
        }
    }

    fn reset(&mut self) {
        for r in &mut self.rings {
            r.fill(0.0);
        }
        self.write = 0;
        self.phase = 0.0;
        self.rate.snap(self.rate_target);
        self.depth_ms.snap(self.depth_target);
        self.mix.snap(self.mix_target);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dsp::fx::{seed_fx_defaults, set_fx_param_by_key};

    #[test]
    fn dry_is_an_exact_passthrough_at_mix_zero() {
        let mut c = ChorusFx::new(48_000, 240);
        let p = EngineParams::new(1);
        seed_fx_defaults(&p, FxKindId::Chorus, 0);
        assert!(set_fx_param_by_key(&p, FxKindId::Chorus, 0, "mix", 0.0));
        c.load_block_targets(&p, 0);
        // Let the mix slew settle, then assert bit-exact passthrough.
        for _ in 0..1_000 {
            c.process_frame([0.3, -0.4], [0.0, 0.0]);
        }
        for i in 0..1_000 {
            let x = [(i as f32 * 0.001).sin(), (i as f32 * 0.002).cos()];
            assert_eq!(c.process_frame(x, [0.0, 0.0]), x);
        }
    }

    #[test]
    fn expected_deviation_scales_with_both_rate_and_depth() {
        let a = ChorusFx::expected_pitch_deviation(2.0, 4.0);
        assert!((a - 2.0 * std::f32::consts::PI * 2.0 * 0.004).abs() < 1e-9);
        assert!((ChorusFx::expected_pitch_deviation(4.0, 4.0) - 2.0 * a).abs() < 1e-6);
        assert!((ChorusFx::expected_pitch_deviation(2.0, 8.0) - 2.0 * a).abs() < 1e-6);
    }

    #[test]
    fn silence_stays_silent() {
        let mut c = ChorusFx::new(48_000, 240);
        let p = EngineParams::new(1);
        seed_fx_defaults(&p, FxKindId::Chorus, 0);
        assert!(set_fx_param_by_key(&p, FxKindId::Chorus, 0, "mix", 1.0));
        c.load_block_targets(&p, 0);
        for _ in 0..48_000 {
            assert_eq!(c.process_frame([0.0, 0.0], [0.0, 0.0]), [0.0, 0.0]);
        }
    }
}
