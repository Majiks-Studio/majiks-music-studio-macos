//! Bus A: the Majik's DJ Freeverb port, re-voiced for send use.
//!
//! Donor: majiks-dj effects/reverb.rs (4 parallel combs + 2 series allpasses
//! per channel, stereo-offset delay lengths, one-pole damping in the comb
//! feedback). Changes for the DAW send bus, all deliberate:
//! - fixed ring buffers with index math instead of VecDeque (provably
//!   allocation-free process path)
//! - tap lengths are FIXED at construction (voiced defaults); the donor's
//!   live room_size tap scaling could click, and v1 buses are fixed-slot
//!   with quality defaults (01-DESIGN 3.7)
//! - output is 100% wet: dry/wet belongs to the send/return gains
//! - damping and decay are smoothed per frame so control tweaks cannot step
//! - denormal flush on every feedback state
//!
//! Zero input produces exactly zero output (deterministic starts).

use crate::dsp::flush_denormal;
use crate::dsp::slew::Slew;

/// Comb delay voicing (ms) straight from the donor, used at full length.
const COMB_MS: [f32; 4] = [29.7, 37.1, 41.1, 43.7];
/// Series allpass voicing (ms), donor values.
const ALLPASS_MS: [f32; 2] = [5.0, 1.7];
/// Right-channel decorrelation offsets in samples (donor: +23 combs, +7 aps).
const COMB_STEREO_OFFSET: usize = 23;
const ALLPASS_STEREO_OFFSET: usize = 7;
/// Output normalization for 4 parallel combs.
const COMB_MIX: f32 = 0.25;
const ALLPASS_G: f32 = 0.5;

struct Ring {
    buf: Box<[f32]>,
    write: usize,
}

impl Ring {
    fn new(len: usize) -> Self {
        Self {
            buf: vec![0.0; len.max(1)].into_boxed_slice(),
            write: 0,
        }
    }

    /// Read the sample written `len` frames ago (the full ring length), then
    /// write the new one. Fixed full-length tap.
    #[inline(always)]
    fn exchange(&mut self, input: f32) -> f32 {
        let out = self.buf[self.write];
        self.buf[self.write] = input;
        self.write += 1;
        if self.write >= self.buf.len() {
            self.write = 0;
        }
        out
    }
}

pub struct ReverbBus {
    combs: [[Ring; 4]; 2],
    allpasses: [[Ring; 2]; 2],
    /// One-pole damping filter state per comb per channel.
    damp_state: [[f32; 4]; 2],
    /// Smoothed parameters.
    damping: Slew,
    feedback: Slew,
}

/// Voiced defaults for the send bus: medium room, moderate damping.
pub const DEFAULT_FEEDBACK: f32 = 0.84;
pub const DEFAULT_DAMPING: f32 = 0.35;

impl ReverbBus {
    pub fn new(sample_rate: u32, ramp_frames: u32) -> Self {
        let sr = sample_rate.max(1) as f32;
        let frames = |ms: f32| ((ms / 1000.0) * sr) as usize;
        let step = 1.0 / ramp_frames.max(1) as f32;
        Self {
            combs: [
                std::array::from_fn(|i| Ring::new(frames(COMB_MS[i]))),
                std::array::from_fn(|i| Ring::new(frames(COMB_MS[i]) + COMB_STEREO_OFFSET)),
            ],
            allpasses: [
                std::array::from_fn(|i| Ring::new(frames(ALLPASS_MS[i]))),
                std::array::from_fn(|i| Ring::new(frames(ALLPASS_MS[i]) + ALLPASS_STEREO_OFFSET)),
            ],
            damp_state: [[0.0; 4]; 2],
            damping: Slew::new(DEFAULT_DAMPING, step),
            feedback: Slew::new(DEFAULT_FEEDBACK, step),
        }
    }

    /// One frame through the bus. Input is the stereo send accumulator; the
    /// donor topology feeds the mono sum into both channel banks. Output is
    /// 100% wet.
    #[inline]
    pub fn process_frame(
        &mut self,
        input: [f32; 2],
        damping_target: f32,
        feedback_target: f32,
    ) -> [f32; 2] {
        let damping = self.damping.advance(damping_target.clamp(0.0, 0.99));
        let feedback = self.feedback.advance(feedback_target.clamp(0.0, 0.98));
        let mono = (input[0] + input[1]) * 0.5;

        let mut out = [0.0_f32; 2];
        for ch in 0..2 {
            let mut acc = 0.0_f32;
            for i in 0..4 {
                let delayed = self.combs[ch][i].buf[self.combs[ch][i].write];
                // One-pole low-pass in the feedback path (donor damping).
                let filtered = flush_denormal(
                    self.damp_state[ch][i] * damping + delayed * (1.0 - damping),
                );
                self.damp_state[ch][i] = filtered;
                let comb_in = flush_denormal(mono + filtered * feedback);
                self.combs[ch][i].exchange(comb_in);
                acc += delayed;
            }
            acc *= COMB_MIX;
            for i in 0..2 {
                let delayed = self.allpasses[ch][i].buf[self.allpasses[ch][i].write];
                let ap_out = delayed - acc;
                self.allpasses[ch][i]
                    .exchange(flush_denormal(acc + delayed * ALLPASS_G));
                acc = ap_out;
            }
            out[ch] = acc;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_in_silence_out() {
        let mut rv = ReverbBus::new(48_000, 240);
        for _ in 0..10_000 {
            let out = rv.process_frame([0.0, 0.0], DEFAULT_DAMPING, DEFAULT_FEEDBACK);
            assert_eq!(out, [0.0, 0.0]);
        }
    }

    #[test]
    fn impulse_rings_then_decays() {
        let mut rv = ReverbBus::new(48_000, 240);
        let mut energy_early = 0.0_f64;
        let mut energy_late = 0.0_f64;
        let mut peak = 0.0_f32;
        for i in 0..(48_000 * 4) {
            let input = if i == 0 { [1.0, 1.0] } else { [0.0, 0.0] };
            let out = rv.process_frame(input, DEFAULT_DAMPING, DEFAULT_FEEDBACK);
            let e = f64::from(out[0] * out[0] + out[1] * out[1]);
            peak = peak.max(out[0].abs()).max(out[1].abs());
            if i < 48_000 {
                energy_early += e;
            } else if i >= 48_000 * 3 {
                energy_late += e;
            }
        }
        assert!(energy_early > 0.0, "the tail exists");
        assert!(peak < 2.0, "voiced level stays sane, peak {peak}");
        assert!(
            energy_late < energy_early * 0.05,
            "tail decays: early {energy_early}, late {energy_late}"
        );
    }

    #[test]
    fn stereo_channels_decorrelate() {
        let mut rv = ReverbBus::new(48_000, 240);
        let mut diff = 0.0_f64;
        for i in 0..48_000 {
            let input = if i % 4_800 == 0 { [0.5, 0.5] } else { [0.0, 0.0] };
            let out = rv.process_frame(input, DEFAULT_DAMPING, DEFAULT_FEEDBACK);
            diff += f64::from((out[0] - out[1]).abs());
        }
        assert!(diff > 0.1, "offset delays must decorrelate channels");
    }
}
