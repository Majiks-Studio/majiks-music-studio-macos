//! Topology-preserving-transform state-variable filter (Zavalishin / Cytomic
//! form), used as the synth's resonant low-pass.
//!
//! Why not `dsp::biquad`: the biquad bank is the right tool for a mixer EQ,
//! where the target moves rarely and `Band` ramps between two coefficient
//! sets. A synth cutoff is *modulated*, potentially every frame, over four
//! decades. A Direct-Form biquad under fast coefficient modulation is only
//! conditionally stable and audibly zippers; the TPT SVF is unconditionally
//! stable at any coefficient trajectory and needs no ramping machinery. It
//! follows biquad.rs's contract in every other respect: `Copy` state,
//! per-FRAME advance, denormal flush, and the strip.rs coefficient CACHE
//! idiom (`last_vol_db`) so the `tan()` only runs when the input actually
//! moved — which, once a `Slew` has settled, is never.

use crate::dsp::flush_denormal;

#[derive(Debug, Clone, Copy)]
pub struct Svf {
    ic1: f32,
    ic2: f32,
    // Cached coefficient inputs. NaN forces the first update.
    cached_cutoff: f32,
    cached_res: f32,
    cached_rate: u32,
    k: f32,
    a1: f32,
    a2: f32,
    a3: f32,
}

impl Default for Svf {
    fn default() -> Self {
        Self {
            ic1: 0.0,
            ic2: 0.0,
            cached_cutoff: f32::NAN,
            cached_res: f32::NAN,
            cached_rate: 0,
            k: 2.0,
            a1: 1.0,
            a2: 0.0,
            a3: 0.0,
        }
    }
}

impl Svf {
    /// Clear the filter state (note-on). Coefficients are kept: they are a
    /// pure function of the parameters, not signal history.
    #[inline]
    pub fn reset(&mut self) {
        self.ic1 = 0.0;
        self.ic2 = 0.0;
    }

    #[inline]
    fn update(&mut self, cutoff_hz: f32, res: f32, sample_rate: u32) {
        let rate = sample_rate.max(1) as f32;
        let fc = cutoff_hz.clamp(20.0, rate * 0.45);
        // res 0..=1 maps to damping k 2..=0.05. k == 0 self-oscillates and can
        // run away on a modulated cutoff, so the top of the range is clamped
        // short of it — the same "clamp into a stable range" discipline as
        // biquad::compute.
        let r = res.clamp(0.0, 1.0);
        let k = (2.0 - 1.95 * r).max(0.05);
        let g = (std::f32::consts::PI * fc / rate).tan();
        let a1 = 1.0 / (1.0 + g * (g + k));
        self.k = k;
        self.a1 = a1;
        self.a2 = g * a1;
        self.a3 = g * self.a2;
        self.cached_cutoff = cutoff_hz;
        self.cached_res = res;
        self.cached_rate = sample_rate;
    }

    /// One frame of low-pass. `cutoff_hz` / `res` may change every frame; the
    /// coefficient solve only runs when they actually differ from last frame.
    #[inline(always)]
    pub fn process_lp(&mut self, x: f32, cutoff_hz: f32, res: f32, sample_rate: u32) -> f32 {
        if cutoff_hz != self.cached_cutoff
            || res != self.cached_res
            || sample_rate != self.cached_rate
        {
            self.update(cutoff_hz, res, sample_rate);
        }
        let v3 = x - self.ic2;
        let v1 = self.a1 * self.ic1 + self.a2 * v3;
        let v2 = self.ic2 + self.a2 * self.ic1 + self.a3 * v3;
        self.ic1 = flush_denormal(2.0 * v1 - self.ic1);
        self.ic2 = flush_denormal(2.0 * v2 - self.ic2);
        v2
    }

    #[inline]
    pub fn is_quiet(&self) -> bool {
        self.ic1.abs() < 1.0e-10 && self.ic2.abs() < 1.0e-10
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::TAU;

    /// RMS of a sine at `hz` after the filter, relative to unfiltered RMS.
    fn gain_at(cutoff: f32, res: f32, hz: f32) -> f32 {
        let rate = 48_000u32;
        let mut f = Svf::default();
        let n = 24_000usize;
        let mut sum_in = 0.0f64;
        let mut sum_out = 0.0f64;
        for i in 0..n {
            let x = (TAU * hz * i as f32 / rate as f32).sin();
            let y = f.process_lp(x, cutoff, res, rate);
            // Skip the first 4800 frames so the filter has settled.
            if i >= 4800 {
                sum_in += (x * x) as f64;
                sum_out += (y * y) as f64;
            }
        }
        ((sum_out / sum_in).sqrt()) as f32
    }

    #[test]
    fn passes_below_cutoff_and_rejects_above() {
        let pass = gain_at(1000.0, 0.0, 100.0);
        let stop = gain_at(1000.0, 0.0, 8000.0);
        assert!(pass > 0.9, "passband gain {pass}");
        assert!(stop < 0.05, "stopband gain {stop}");
        assert!(stop < pass * 0.1, "rolls off by at least 20 dB");
    }

    #[test]
    fn resonance_lifts_the_corner() {
        let flat = gain_at(1000.0, 0.0, 1000.0);
        let resonant = gain_at(1000.0, 0.9, 1000.0);
        assert!(
            resonant > flat * 2.0,
            "resonance should peak at the corner: flat {flat}, resonant {resonant}"
        );
    }

    #[test]
    fn stable_under_per_frame_cutoff_modulation() {
        let rate = 48_000u32;
        let mut f = Svf::default();
        let mut peak = 0.0f32;
        for i in 0..48_000usize {
            let x = (TAU * 220.0 * i as f32 / rate as f32).sin();
            // Sweep the cutoff every single frame across four decades.
            let sweep = 20.0 + 19_000.0 * (0.5 + 0.5 * (TAU * 7.0 * i as f32 / rate as f32).sin());
            let y = f.process_lp(x, sweep, 0.95, rate);
            assert!(y.is_finite(), "filter blew up at frame {i}");
            peak = peak.max(y.abs());
        }
        assert!(peak < 8.0, "resonant sweep stayed bounded, peak {peak}");
    }

    #[test]
    fn settled_parameters_skip_the_coefficient_solve() {
        let mut f = Svf::default();
        f.process_lp(0.0, 1000.0, 0.5, 48_000);
        let (a1, a2, a3) = (f.a1, f.a2, f.a3);
        f.process_lp(0.0, 1000.0, 0.5, 48_000);
        assert_eq!((f.a1, f.a2, f.a3), (a1, a2, a3), "cache hit, no recompute");
    }
}
