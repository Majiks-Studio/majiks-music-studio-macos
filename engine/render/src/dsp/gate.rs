//! `FxKind::Gate` (`DESIGN-E5-routing.md` §17.2): *"the same detector with the
//! decision inverted (below threshold → attenuate), plus `hold` (ms) and
//! `range` (dB). Sharing the detector is why it costs almost nothing."*
//!
//! It literally shares it — `compressor::Detector` — rather than growing a
//! parallel level follower that can drift away from the compressor's.
//!
//! Timing split, stated because it is the one judgement call here:
//! - the **detector** runs instant-attack with a fixed fast release
//!   ([`DETECTOR_RELEASE_MS`]) so the open/close *decision* is responsive and
//!   does not chatter on the zero crossings of a periodic signal;
//! - the user's `attack` / `release` shape the **gain** one-pole, which is what
//!   a musician means by a gate's attack and release.
//!
//! Coupling both to the same coefficients would make the audible attack the
//! sum of two time constants, which is the kind of thing that measures wrong
//! and gets "fixed" by tuning a test tolerance.
//!
//! **The release genuinely reaches the range floor.** `converge_exact` flushes
//! the residual, and `range <= -96 dB` maps to exactly 0.0, so a closing gate
//! lands on silence instead of parking a hair above it. A truncated release is
//! a click, and a floor that is never quite reached is a denormal generator.
//!
//! Zero latency, per-frame, allocation-free.

use crate::dsp::compressor::{Detector, RMS_WINDOW_MS};
use crate::dsp::fx::{
    coeff_from_ms, converge_exact, db_to_lin_floor, read_param, FxKindId, FxNode,
};
use crate::params::EngineParams;

/// Release time constant of the gate's *detector* (not its gain). Fast enough
/// that the decision tracks a transient, slow enough that a 20 Hz waveform's
/// zero crossings do not slam the gate shut every half cycle.
pub const DETECTOR_RELEASE_MS: f32 = 5.0;

pub struct GateFx {
    det: Detector,
    sample_rate: u32,

    /// Applied gain, one-pole toward `1.0` (open) or `range_lin` (closed).
    gain: f32,
    /// Frames of hold remaining after the detector fell below threshold.
    hold_left: u32,

    threshold_lin: f32,
    range_lin: f32,
    hold_frames: u32,
    attack_coeff: f32,
    release_coeff: f32,
    det_release_coeff: f32,
    rms_coeff: f32,
    rms_mode: bool,

    /// Lane fast paths for the two dB keys (`threshold`, `range`): (last dB,
    /// its linear value) pairs, so `db_to_lin_floor` runs only when the lane
    /// value actually moves — `Strip::vol_lane_lin`'s cache, twice.
    threshold_db_cache: f32,
    threshold_lin_cache: f32,
    range_db_cache: f32,
    range_lin_cache: f32,

    meter_min_gain: f32,
}

impl GateFx {
    pub fn new(sample_rate: u32, _ramp_frames: u32) -> Self {
        let k = FxKindId::Gate;
        let d = |i: usize| k.params()[i].default;
        Self {
            det: Detector::new(),
            sample_rate,
            // Starts OPEN: a freshly inserted gate must not swallow the first
            // note while its detector charges.
            gain: 1.0,
            hold_left: 0,
            threshold_lin: db_to_lin_floor(d(0)),
            range_lin: db_to_lin_floor(d(4)),
            hold_frames: (d(2) * 0.001 * sample_rate as f32) as u32,
            attack_coeff: coeff_from_ms(d(1), sample_rate),
            release_coeff: coeff_from_ms(d(3), sample_rate),
            det_release_coeff: coeff_from_ms(DETECTOR_RELEASE_MS, sample_rate),
            rms_coeff: coeff_from_ms(RMS_WINDOW_MS, sample_rate),
            rms_mode: false,
            threshold_db_cache: d(0),
            threshold_lin_cache: db_to_lin_floor(d(0)),
            range_db_cache: d(4),
            range_lin_cache: db_to_lin_floor(d(4)),
            meter_min_gain: 1.0,
        }
    }

    /// Current applied gain (linear). Test/telemetry accessor.
    pub fn gain(&self) -> f32 {
        self.gain
    }

    /// True while the gate is passing (detector above threshold, or holding).
    pub fn is_open(&self) -> bool {
        self.hold_left > 0 || self.det.level() >= self.threshold_lin
    }
}

impl FxNode for GateFx {
    #[inline]
    fn process_frame(&mut self, x: [f32; 2], key: [f32; 2]) -> [f32; 2] {
        // Instant attack on the detector: `attack_coeff = 0.0`.
        let env = self.det.process_frame(
            key,
            self.rms_mode,
            self.rms_coeff,
            0.0,
            self.det_release_coeff,
        );

        // Inverted decision (§17.2), with hold.
        let open = if env >= self.threshold_lin {
            self.hold_left = self.hold_frames;
            true
        } else if self.hold_left > 0 {
            self.hold_left -= 1;
            true
        } else {
            false
        };

        let target = if open { 1.0 } else { self.range_lin };
        let coeff = if target > self.gain {
            self.attack_coeff
        } else {
            self.release_coeff
        };
        self.gain = converge_exact(self.gain, target, coeff);
        if self.gain < self.meter_min_gain {
            self.meter_min_gain = self.gain;
        }

        [x[0] * self.gain, x[1] * self.gain]
    }

    fn load_block_targets(&mut self, p: &EngineParams, base_slot: usize) {
        let k = FxKindId::Gate;
        self.threshold_lin = db_to_lin_floor(read_param(p, base_slot, k, 0));
        self.attack_coeff = coeff_from_ms(read_param(p, base_slot, k, 1), self.sample_rate);
        self.hold_frames =
            (read_param(p, base_slot, k, 2) * 0.001 * self.sample_rate as f32) as u32;
        self.release_coeff = coeff_from_ms(read_param(p, base_slot, k, 3), self.sample_rate);
        self.range_lin = db_to_lin_floor(read_param(p, base_slot, k, 4));
        self.rms_mode = read_param(p, base_slot, k, 5) >= 0.5;
        self.det_release_coeff = coeff_from_ms(DETECTOR_RELEASE_MS, self.sample_rate);
        self.rms_coeff = coeff_from_ms(RMS_WINDOW_MS, self.sample_rate);
    }

    fn set_frame_param(&mut self, index: usize, value: f32) {
        match index {
            // Cache pair + UNCONDITIONAL apply (the compare gates only the
            // reconversion; a gated apply would leave the block loader's
            // atomic value standing while the lane holds steady).
            0 => {
                if value != self.threshold_db_cache {
                    self.threshold_db_cache = value;
                    self.threshold_lin_cache = db_to_lin_floor(value);
                }
                self.threshold_lin = self.threshold_lin_cache;
            }
            // `hold` is a time VALUE, not a time COEFFICIENT: ms -> frames is
            // one multiply and a cast. It arms on the next retrigger exactly
            // as a block-rate change does.
            2 => self.hold_frames = (value * 0.001 * self.sample_rate as f32) as u32,
            4 => {
                if value != self.range_db_cache {
                    self.range_db_cache = value;
                    self.range_lin_cache = db_to_lin_floor(value);
                }
                self.range_lin = self.range_lin_cache;
            }
            5 => self.rms_mode = value >= 0.5,
            // 1 (`attack`) and 3 (`release`) are Block-rate gain one-pole
            // coefficients; compile refuses their lanes by key.
            _ => debug_assert!(false, "Gate has no Frame param index {index}"),
        }
    }

    fn take_block_meter(&mut self) -> f32 {
        let m = self.meter_min_gain;
        self.meter_min_gain = 1.0;
        m
    }

    fn reset(&mut self) {
        self.det.reset();
        self.gain = 1.0;
        self.hold_left = 0;
        self.meter_min_gain = 1.0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dsp::fx::{seed_fx_defaults, set_fx_param_by_key};

    fn bank(threshold: f32, attack: f32, hold: f32, release: f32, range: f32) -> EngineParams {
        let p = EngineParams::new(1);
        seed_fx_defaults(&p, FxKindId::Gate, 0);
        for (k, v) in [
            ("threshold", threshold),
            ("attack", attack),
            ("hold", hold),
            ("release", release),
            ("range", range),
        ] {
            assert!(set_fx_param_by_key(&p, FxKindId::Gate, 0, k, v));
        }
        p
    }

    #[test]
    fn closes_to_exact_silence_and_reopens() {
        let mut g = GateFx::new(48_000, 240);
        // -20 dB threshold, fast attack, no hold, 20 ms release, full range.
        let p = bank(-20.0, 0.5, 0.0, 20.0, -96.0);
        g.load_block_targets(&p, 0);

        // Silence for 2 s: the gate must reach EXACTLY zero, not 1e-9.
        let mut last = [0.0_f32; 2];
        for _ in 0..96_000 {
            last = g.process_frame([0.5, 0.5], [0.0, 0.0]);
        }
        assert_eq!(g.gain(), 0.0, "release reaches exactly zero");
        assert_eq!(last, [0.0, 0.0]);

        // Loud key: reopens.
        for _ in 0..4_800 {
            g.process_frame([0.5, 0.5], [0.5, 0.5]);
        }
        assert!(g.gain() > 0.99, "gate reopens: {}", g.gain());
    }

    #[test]
    fn range_limits_the_attenuation() {
        let mut g = GateFx::new(48_000, 240);
        let p = bank(-20.0, 0.5, 0.0, 20.0, -12.0);
        g.load_block_targets(&p, 0);
        for _ in 0..96_000 {
            g.process_frame([1.0, 1.0], [0.0, 0.0]);
        }
        let want = 10.0_f32.powf(-12.0 / 20.0);
        assert!(
            (g.gain() - want).abs() < 1e-6,
            "closed gain sits at the range floor: {} vs {want}",
            g.gain()
        );
    }

    #[test]
    fn hold_keeps_the_gate_open_for_its_configured_span() {
        let sr = 48_000_u32;
        let hold_ms = 50.0_f32;
        let mut g = GateFx::new(sr, 240);
        // Long release so the measurement is dominated by hold, not by decay.
        let p = bank(-20.0, 0.5, hold_ms, 2_000.0, -96.0);
        g.load_block_targets(&p, 0);

        // Charge the detector, then cut the key and count frames until the
        // gate starts to close.
        for _ in 0..4_800 {
            g.process_frame([1.0, 1.0], [0.5, 0.5]);
        }
        let mut frames_until_closing = 0_u32;
        for i in 0..sr {
            g.process_frame([1.0, 1.0], [0.0, 0.0]);
            if g.gain() < 1.0 {
                frames_until_closing = i;
                break;
            }
        }
        // The detector must fall below threshold first (its own 5 ms release
        // from 0.5 to 0.1 is ~8 ms), then the hold runs.
        let hold_frames = (hold_ms * 0.001 * sr as f32) as u32;
        let det_frames = (20.0 * 0.001 * sr as f32) as u32;
        assert!(
            frames_until_closing >= hold_frames,
            "held at least {hold_frames} frames, got {frames_until_closing}"
        );
        assert!(
            frames_until_closing <= hold_frames + det_frames,
            "hold did not run long: {frames_until_closing}"
        );
    }
}
