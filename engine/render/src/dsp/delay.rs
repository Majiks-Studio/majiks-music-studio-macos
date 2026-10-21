//! Bus B: tempo-synced ping-pong feedback delay.
//!
//! Donor shape: majiks-dj effects/delay.rs (stereo cross-feedback), rebuilt
//! on fixed rings with two DAW requirements added:
//! - the delay time is a TEMPO DIVISION: the control side resolves the
//!   division to frames through the tempo map and hands the render side an
//!   integer frame count (no tempo math on the audio thread)
//! - time changes CROSSFADE between the old and new tap over the declick
//!   window instead of jumping the read head (no click, no pitch chirp)
//!
//! A one-pole tone filter sits in the feedback loop so repeats darken
//! naturally. Output is 100% wet (send bus discipline).

use crate::dsp::flush_denormal;
use crate::dsp::slew::Slew;

/// Maximum delay: 2 seconds at the engine rate.
pub const MAX_DELAY_SECONDS: usize = 2;

/// Tempo-sync divisions offered by the bus (fractions of one beat).
/// Encoded as (numerator, denominator) of a beat.
pub const DIVISIONS: [(u32, u32); 6] = [
    (1, 4), // sixteenth
    (1, 2), // eighth
    (3, 4), // dotted eighth
    (1, 1), // quarter
    (3, 2), // dotted quarter
    (2, 1), // half
];

pub struct DelayBus {
    rings: [Box<[f32]>; 2],
    write: usize,
    len: usize,
    /// Active tap (frames) and the crossfade to a new one.
    tap_cur: usize,
    tap_new: usize,
    xfade_t: f32,
    xfade_dt: f32,
    /// Feedback tone filter state per channel.
    tone_state: [f32; 2],
    feedback: Slew,
    tone: Slew,
}

pub const DEFAULT_FEEDBACK: f32 = 0.35;
pub const DEFAULT_TONE: f32 = 0.4;

impl DelayBus {
    pub fn new(sample_rate: u32, initial_tap_frames: u32, ramp_frames: u32) -> Self {
        let len = (sample_rate as usize * MAX_DELAY_SECONDS).max(16);
        let step = 1.0 / ramp_frames.max(1) as f32;
        let tap = (initial_tap_frames as usize).clamp(1, len - 1);
        Self {
            rings: [
                vec![0.0; len].into_boxed_slice(),
                vec![0.0; len].into_boxed_slice(),
            ],
            write: 0,
            len,
            tap_cur: tap,
            tap_new: tap,
            xfade_t: 1.0,
            xfade_dt: step,
            tone_state: [0.0; 2],
            feedback: Slew::new(DEFAULT_FEEDBACK, step),
            tone: Slew::new(DEFAULT_TONE, step),
        }
    }

    #[inline(always)]
    fn read_tap(&self, ch: usize, tap: usize) -> f32 {
        let idx = (self.write + self.len - tap.min(self.len - 1)) % self.len;
        self.rings[ch][idx]
    }

    /// One frame. `tap_frames` is the tempo-resolved delay in frames (from
    /// the control side); a change starts a linear crossfade to the new tap.
    #[inline]
    pub fn process_frame(
        &mut self,
        input: [f32; 2],
        tap_frames: u32,
        feedback_target: f32,
        tone_target: f32,
    ) -> [f32; 2] {
        let requested = (tap_frames as usize).clamp(1, self.len - 1);
        if requested != self.tap_new {
            // Retarget: fade from whatever is currently sounding. If a fade
            // is mid-flight, fold the current blend into `tap_cur` weighting
            // by restarting from the dominant tap (bounded artifact, control
            // tweaks are rare relative to the 5 ms window).
            self.tap_cur = if self.xfade_t >= 0.5 { self.tap_new } else { self.tap_cur };
            self.tap_new = requested;
            self.xfade_t = 0.0;
        }
        let feedback = self.feedback.advance(feedback_target.clamp(0.0, 0.95));
        let tone = self.tone.advance(tone_target.clamp(0.0, 0.99));

        if self.xfade_t < 1.0 {
            self.xfade_t = (self.xfade_t + self.xfade_dt).min(1.0);
        }
        let t = self.xfade_t;

        let mut out = [0.0_f32; 2];
        for ch in 0..2 {
            let a = self.read_tap(ch, self.tap_cur);
            let b = self.read_tap(ch, self.tap_new);
            out[ch] = if t >= 1.0 { b } else { a + (b - a) * t };
        }

        // Ping-pong: each channel's line is fed the OTHER channel's delayed
        // signal (tone-filtered) plus its own input.
        for ch in 0..2 {
            let cross = out[1 - ch];
            let filtered = flush_denormal(
                self.tone_state[ch] * tone + cross * (1.0 - tone),
            );
            self.tone_state[ch] = filtered;
            let write_val = flush_denormal(input[ch] + filtered * feedback);
            self.rings[ch][self.write] = write_val;
        }
        self.write += 1;
        if self.write >= self.len {
            self.write = 0;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_stays_silent() {
        let mut d = DelayBus::new(48_000, 12_000, 240);
        for _ in 0..50_000 {
            let out = d.process_frame([0.0, 0.0], 12_000, DEFAULT_FEEDBACK, DEFAULT_TONE);
            assert_eq!(out, [0.0, 0.0]);
        }
    }

    #[test]
    fn first_echo_lands_exactly_at_the_tap() {
        let tap = 4_800_u32;
        let mut d = DelayBus::new(48_000, tap, 240);
        let mut first_echo = None;
        for i in 0..20_000 {
            let input = if i == 0 { [1.0, 0.0] } else { [0.0, 0.0] };
            let out = d.process_frame(input, tap, 0.5, 0.0);
            if first_echo.is_none() && (out[0].abs() > 1e-6 || out[1].abs() > 1e-6) {
                first_echo = Some((i, out));
            }
        }
        let (frame, out) = first_echo.expect("echo arrives");
        assert_eq!(frame, tap as usize, "echo exactly at the tap length");
        // Impulse went into the LEFT input; the first audible tap comes off
        // the left ring, then ping-pongs to the right on the next pass.
        assert!(out[0].abs() > 0.5, "left tap carries the first echo");
    }

    #[test]
    fn echoes_decay_with_feedback() {
        let tap = 2_400_u32;
        let mut d = DelayBus::new(48_000, tap, 240);
        let mut peaks: Vec<f32> = Vec::new();
        let mut current_peak = 0.0_f32;
        for i in 0..(2_400 * 8) {
            let input = if i == 0 { [0.8, 0.8] } else { [0.0, 0.0] };
            let out = d.process_frame(input, tap, 0.5, 0.2);
            current_peak = current_peak.max(out[0].abs()).max(out[1].abs());
            if i % 2_400 == 2_399 {
                peaks.push(current_peak);
                current_peak = 0.0;
            }
        }
        // Bucket 0 is the dry span before the first echo; the first echo
        // lands exactly at frame `tap` which opens bucket 1.
        assert!(peaks[1] > 0.4, "first echo present: {peaks:?}");
        assert!(
            peaks[6] < peaks[1] * 0.3,
            "repeats decay: {peaks:?}"
        );
    }

    #[test]
    fn tap_change_crossfades_without_step() {
        let mut d = DelayBus::new(48_000, 4_800, 240);
        // Feed a steady tone so the ring is full of continuous material.
        let tone = |i: usize| (2.0 * std::f32::consts::PI * 60.0 * i as f32 / 48_000.0).sin() * 0.5;
        let mut out_hist = Vec::new();
        let mut tap = 4_800_u32;
        for i in 0..30_000 {
            if i == 20_000 {
                tap = 9_600;
            }
            let out = d.process_frame([tone(i), tone(i)], tap, 0.3, 0.2);
            out_hist.push(out[0]);
        }
        // 60 Hz at half scale: legitimate per-frame delta is tiny; allow
        // summed feedback headroom.
        for (i, w) in out_hist.windows(2).enumerate().skip(6_000) {
            let step = (w[1] - w[0]).abs();
            assert!(step < 0.05, "tap change stepped {step} at {i}");
        }
    }
}
