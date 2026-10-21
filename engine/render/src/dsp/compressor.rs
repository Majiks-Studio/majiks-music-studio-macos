//! The keyed feed-forward compressor (`DESIGN-E5-routing.md` §17.2) and the
//! `Detector` the gate shares with it.
//!
//! ```text
//!                  ┌──────────────────────────────────────────┐
//!    key input ───►│ detector: |x| or RMS → attack/release env │──► gain reduction
//!   (self OR a     └──────────────────────────────────────────┘            │
//!    sidechain                                                             ▼
//!    node's                          audio in ──────────────────────────► × ──► out
//!    accumulator)                                          (+ makeup, + dry/wet mix)
//! ```
//!
//! **Zero lookahead, by decision (§17.2).** A lookahead compressor is the only
//! thing in this suite that would need latency, and being the sole reason the
//! graph carries delay is a bad trade against a small transient benefit. It
//! matters *more* now that PDC exists (§19), not less: PDC makes latency
//! survivable, which is exactly the pressure that would let it creep in
//! everywhere. `latency_frames()` stays 0 and a lane that wants lookahead is
//! a report-and-stop (§17.2).
//!
//! **Per-FRAME envelope (§6.1).** Attack/release coefficients are computed
//! once per block from the atomics, in the exact form
//! `EngineParams::limiter_release_coeff` already uses (`params.rs:306-309`);
//! the envelope itself advances every frame. A per-block envelope changes the
//! sound with the buffer size and breaks the null gate.
//!
//! **The static curve is the contract.** With a hard knee, a steady input
//! `over` dB above threshold gets exactly `over * (1/ratio - 1)` dB of gain
//! reduction. `render/tests/fx.rs` measures that curve against the configured
//! ratio and threshold across a grid — an implementation that ignored `ratio`
//! would still "get quieter" and would still fail.

use crate::dsp::fx::{
    coeff_from_ms, converge_exact, db_to_lin_floor, mix_frames, read_param, FxKindId, FxNode,
};
use crate::params::EngineParams;
use crate::dsp::slew::Slew;
use crate::dsp::{db_to_lin, flush_denormal, lin_to_db};

/// Fixed mean-square window for the RMS detector mode.
pub const RMS_WINDOW_MS: f32 = 10.0;

/// Level follower shared by the compressor and the gate (§17.2: *"the same
/// detector with the decision inverted"*).
///
/// Stereo-linked: one envelope drives both channels, which is what makes a
/// keyed sidechain duck a stereo bus coherently instead of wobbling its image.
#[derive(Debug, Clone, Copy)]
pub struct Detector {
    env: f32,
    mean_square: f32,
}

impl Default for Detector {
    fn default() -> Self {
        Self::new()
    }
}

impl Detector {
    pub fn new() -> Self {
        Self {
            env: 0.0,
            mean_square: 0.0,
        }
    }

    pub fn reset(&mut self) {
        self.env = 0.0;
        self.mean_square = 0.0;
    }

    /// Current envelope, linear.
    #[inline(always)]
    pub fn level(&self) -> f32 {
        self.env
    }

    /// One FRAME of detection on the key signal.
    ///
    /// `rms_mode` picks |x| peak vs a fixed-window RMS. `attack_coeff` /
    /// `release_coeff` are per-frame one-pole coefficients (0.0 = instant).
    /// Both the mean-square accumulator and the envelope converge *exactly*,
    /// so silence settles the whole detector to bit-exact zero rather than
    /// leaving denormals to burn CPU forever (`dsp/mod.rs:26-37`).
    #[inline(always)]
    pub fn process_frame(
        &mut self,
        key: [f32; 2],
        rms_mode: bool,
        rms_coeff: f32,
        attack_coeff: f32,
        release_coeff: f32,
    ) -> f32 {
        let inst = if rms_mode {
            let ms = (key[0] * key[0] + key[1] * key[1]) * 0.5;
            self.mean_square = converge_exact(self.mean_square, ms, rms_coeff);
            self.mean_square.sqrt()
        } else {
            key[0].abs().max(key[1].abs())
        };
        let coeff = if inst > self.env {
            attack_coeff
        } else {
            release_coeff
        };
        self.env = flush_denormal(converge_exact(self.env, inst, coeff));
        self.env
    }
}

/// `FxKind::Compressor` (§17.2).
pub struct CompressorFx {
    det: Detector,
    sample_rate: u32,

    // Ramped so a knob move cannot step the gain (zipper-free); they settle
    // exactly, so a static setting is an exact static curve.
    threshold_db: Slew,
    ratio: Slew,
    knee_db: Slew,
    makeup: Slew,
    mix: Slew,

    threshold_target: f32,
    ratio_target: f32,
    knee_target: f32,
    makeup_target: f32,
    mix_target: f32,

    /// Lane fast path for `makeup` (a dB value applied as LINEAR gain): the
    /// (last dB, its linear value) pair, so `db_to_lin`'s `powf` runs only
    /// when the lane value actually moves — `Strip::vol_lane_lin`'s cache.
    makeup_db_cache: f32,
    makeup_lin_cache: f32,

    // Per-block coefficients.
    attack_coeff: f32,
    release_coeff: f32,
    rms_coeff: f32,
    rms_mode: bool,

    /// Smallest linear gain applied since the last `take_block_meter`.
    meter_min_gain: f32,
}

impl CompressorFx {
    pub fn new(sample_rate: u32, ramp_frames: u32) -> Self {
        let step = 1.0 / ramp_frames.max(1) as f32;
        let k = FxKindId::Compressor;
        let d = |i: usize| k.params()[i].default;
        Self {
            det: Detector::new(),
            sample_rate,
            // dB/ratio ramps move over the declick window scaled by their own
            // range; a plain 1/ramp step would take 12 s to cross 60 dB.
            threshold_db: Slew::new(d(0), 60.0 * step),
            ratio: Slew::new(d(1), 20.0 * step),
            knee_db: Slew::new(d(2), 24.0 * step),
            makeup: Slew::new(db_to_lin(d(5)), 16.0 * step),
            mix: Slew::new(d(6), step),
            threshold_target: d(0),
            ratio_target: d(1),
            knee_target: d(2),
            makeup_target: db_to_lin(d(5)),
            mix_target: d(6),
            makeup_db_cache: d(5),
            makeup_lin_cache: db_to_lin(d(5)),
            attack_coeff: coeff_from_ms(d(3), sample_rate),
            release_coeff: coeff_from_ms(d(4), sample_rate),
            rms_coeff: coeff_from_ms(RMS_WINDOW_MS, sample_rate),
            rms_mode: false,
            meter_min_gain: 1.0,
        }
    }

    /// The static gain-reduction curve, in dB (always <= 0).
    ///
    /// Hard knee when `knee_db <= 0`; otherwise the standard quadratic
    /// interpolation across the knee, centred on the threshold.
    #[inline(always)]
    pub fn gain_reduction_db(level_db: f32, threshold_db: f32, ratio: f32, knee_db: f32) -> f32 {
        let slope = 1.0 / ratio.max(1.0) - 1.0; // <= 0
        let over = level_db - threshold_db;
        if knee_db <= 0.0 {
            if over > 0.0 {
                slope * over
            } else {
                0.0
            }
        } else if over <= -knee_db * 0.5 {
            0.0
        } else if over >= knee_db * 0.5 {
            slope * over
        } else {
            let t = over + knee_db * 0.5;
            slope * t * t / (2.0 * knee_db)
        }
    }
}

impl FxNode for CompressorFx {
    #[inline]
    fn process_frame(&mut self, x: [f32; 2], key: [f32; 2]) -> [f32; 2] {
        let env = self.det.process_frame(
            key,
            self.rms_mode,
            self.rms_coeff,
            self.attack_coeff,
            self.release_coeff,
        );

        let threshold = self.threshold_db.advance(self.threshold_target);
        let ratio = self.ratio.advance(self.ratio_target);
        let knee = self.knee_db.advance(self.knee_target);
        let makeup = self.makeup.advance(self.makeup_target);
        let mix = self.mix.advance(self.mix_target);

        // Below threshold this is exactly 0 dB -> db_to_lin(0.0) == 1.0
        // exactly, so an idle compressor holds unity, not 0.9999.
        let gr_db = Self::gain_reduction_db(lin_to_db(env), threshold, ratio, knee);
        let gain = db_to_lin_floor(gr_db);
        if gain < self.meter_min_gain {
            self.meter_min_gain = gain;
        }

        let g = gain * makeup;
        mix_frames(x, [x[0] * g, x[1] * g], mix)
    }

    fn load_block_targets(&mut self, p: &EngineParams, base_slot: usize) {
        let k = FxKindId::Compressor;
        self.threshold_target = read_param(p, base_slot, k, 0);
        self.ratio_target = read_param(p, base_slot, k, 1);
        self.knee_target = read_param(p, base_slot, k, 2);
        self.attack_coeff = coeff_from_ms(read_param(p, base_slot, k, 3), self.sample_rate);
        self.release_coeff = coeff_from_ms(read_param(p, base_slot, k, 4), self.sample_rate);
        self.makeup_target = db_to_lin(read_param(p, base_slot, k, 5));
        self.mix_target = read_param(p, base_slot, k, 6);
        self.rms_mode = read_param(p, base_slot, k, 7) >= 0.5;
        self.rms_coeff = coeff_from_ms(RMS_WINDOW_MS, self.sample_rate);
    }

    fn set_frame_param(&mut self, index: usize, value: f32) {
        match index {
            // The static curve runs entirely in the dB domain, so these three
            // are direct target writes; the per-frame `Slew`s below them do
            // the smoothing exactly as they do for a block-rate change.
            0 => self.threshold_target = value,
            1 => self.ratio_target = value,
            2 => self.knee_target = value,
            // `makeup` is dB applied as linear gain: cache pair, UNCONDITIONAL
            // apply (the compare gates the reconversion, never the apply — a
            // gated apply would leave the block loader's atomic value standing
            // on frames where the lane holds steady).
            5 => {
                if value != self.makeup_db_cache {
                    self.makeup_db_cache = value;
                    self.makeup_lin_cache = db_to_lin(value);
                }
                self.makeup_target = self.makeup_lin_cache;
            }
            6 => self.mix_target = value,
            7 => self.rms_mode = value >= 0.5,
            // 3 (`attack`) and 4 (`release`) are Block-rate envelope
            // coefficients; compile refuses their lanes by key.
            _ => debug_assert!(false, "Compressor has no Frame param index {index}"),
        }
    }

    fn take_block_meter(&mut self) -> f32 {
        let m = self.meter_min_gain;
        self.meter_min_gain = 1.0;
        m
    }

    fn reset(&mut self) {
        self.det.reset();
        self.threshold_db.snap(self.threshold_target);
        self.ratio.snap(self.ratio_target);
        self.knee_db.snap(self.knee_target);
        self.makeup.snap(self.makeup_target);
        self.mix.snap(self.mix_target);
        self.meter_min_gain = 1.0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn static_curve_follows_the_ratio_exactly() {
        // The property a "did it get quieter" test cannot see: the amount of
        // reduction is a function OF THE RATIO.
        for &(over, ratio, want) in &[
            (12.0_f32, 4.0_f32, 12.0 * (0.25 - 1.0)),
            (12.0, 2.0, 12.0 * (0.5 - 1.0)),
            (6.0, 8.0, 6.0 * (0.125 - 1.0)),
            (0.0, 4.0, 0.0),
            (-6.0, 4.0, 0.0),
        ] {
            let got = CompressorFx::gain_reduction_db(-20.0 + over, -20.0, ratio, 0.0);
            assert!((got - want).abs() < 1e-4, "over={over} ratio={ratio}: {got} vs {want}");
        }
    }

    #[test]
    fn ratio_of_one_is_exactly_no_reduction() {
        for over in [0.0_f32, 6.0, 24.0] {
            assert_eq!(
                CompressorFx::gain_reduction_db(-20.0 + over, -20.0, 1.0, 0.0),
                0.0
            );
        }
    }

    #[test]
    fn soft_knee_is_continuous_at_both_hinges() {
        let (thr, ratio, knee) = (-20.0_f32, 4.0_f32, 12.0_f32);
        let lo = CompressorFx::gain_reduction_db(thr - knee * 0.5, thr, ratio, knee);
        assert!(lo.abs() < 1e-5, "knee starts at 0 dB reduction: {lo}");
        let hi_in = thr + knee * 0.5;
        let hi = CompressorFx::gain_reduction_db(hi_in, thr, ratio, knee);
        let hard = CompressorFx::gain_reduction_db(hi_in, thr, ratio, 0.0);
        assert!((hi - hard).abs() < 1e-4, "knee rejoins the hard curve: {hi} vs {hard}");
        // And inside the knee it is strictly gentler than the hard curve.
        let mid = CompressorFx::gain_reduction_db(thr, thr, ratio, knee);
        let mid_hard = CompressorFx::gain_reduction_db(thr, thr, ratio, 0.0);
        assert!(mid < mid_hard, "soft knee reduces at the threshold: {mid}");
    }

    #[test]
    fn detector_settles_to_exact_zero_on_silence() {
        let mut d = Detector::new();
        let a = coeff_from_ms(1.0, 48_000);
        let r = coeff_from_ms(50.0, 48_000);
        let rms = coeff_from_ms(RMS_WINDOW_MS, 48_000);
        for _ in 0..4_800 {
            d.process_frame([0.7, 0.7], true, rms, a, r);
        }
        assert!(d.level() > 0.6);
        // A 50 ms release from 0.7 needs ~2.3 s to cross the 1e-20 flush
        // floor; the point of the test is that it DOES cross it, so give it
        // the frames rather than raising the floor.
        for _ in 0..48_000 * 5 {
            d.process_frame([0.0, 0.0], true, rms, a, r);
        }
        assert_eq!(d.level(), 0.0, "envelope reaches exactly zero");
        assert_eq!(d.mean_square, 0.0, "mean-square flushes to exactly zero");
    }

    #[test]
    fn peak_detector_settles_exactly_on_dc() {
        let mut d = Detector::new();
        let a = coeff_from_ms(1.0, 48_000);
        for _ in 0..48_000 {
            d.process_frame([0.5, 0.25], false, 0.0, a, a);
        }
        assert_eq!(d.level(), 0.5, "peak of the two channels, exactly");
    }
}
