//! Master true-peak lookahead limiter.
//!
//! Topology (the standard guaranteed-ceiling design):
//!   1. per-frame true-peak estimate of the input (4x polyphase detector)
//!   2. required gain g = min(1, ceiling / tp)
//!   3. sliding-window MINIMUM of g over the lookahead window (monotonic
//!      wedge on a fixed ring, O(1) amortized, allocation-free)
//!   4. exponential release toward unity, clamped so it never exceeds the
//!      window minimum
//!   5. two cascaded moving averages (triangular smoothing) whose combined
//!      support fits inside the lookahead, so the smoothed gain reaches the
//!      required attenuation no later than the peak leaves the delay line
//!   6. the delayed audio is multiplied by the smoothed gain
//!
//! Alignment proof sketch: a peak entering at frame m is detected by
//! m + d_det; the output of frame m happens at m + D. Every average tap that
//! contributes to the gain at m + D looks at window minima whose windows all
//! contain m + d_det, because S (smoother support) <= D - d_det + 1 and the
//! min window length equals D. Therefore the applied gain <= g_req of the
//! peak: the ceiling holds by construction (within detector accuracy).
//!
//! Latency: exactly `LOOKAHEAD_FRAMES` when enabled; the engine treats an
//! enable/disable toggle as a content change and declicks around it.

use crate::dsp::truepeak::{TruePeakDetector, DETECTOR_DELAY_FRAMES};

/// Lookahead / audio delay in frames (2 ms at 48 kHz).
pub const LOOKAHEAD_FRAMES: usize = 96;
/// Moving-average length for each smoothing stage. Support of the cascade
/// (2*MA_LEN - 1 = 87) must stay <= LOOKAHEAD - DETECTOR_DELAY + 1 = 89.
const MA_LEN: usize = 44;
/// Recompute the running sums exactly this often (guards f64 drift).
const RESUM_INTERVAL: u64 = 1 << 14;

/// Compile-time proof that the smoother support fits the lookahead alignment
/// budget (the ceiling guarantee depends on it).
const _: () = assert!(2 * MA_LEN - 1 <= LOOKAHEAD_FRAMES - DETECTOR_DELAY_FRAMES + 1);

pub struct Limiter {
    detector: TruePeakDetector,
    delay: [[f32; 2]; LOOKAHEAD_FRAMES],
    delay_write: usize,
    /// Monotonic wedge over the gain window: ring of (frame, gain). Sized
    /// LOOKAHEAD_FRAMES + 2: the push happens before the front-eviction, so
    /// occupancy momentarily reaches LOOKAHEAD_FRAMES + 1 entries; a
    /// +1-sized ring would then alias head==tail (the empty sentinel) and
    /// skip the eviction, collapsing the window minimum and letting a
    /// delayed peak through above the ceiling. +2 keeps head != tail at max
    /// occupancy.
    wedge: [(u64, f32); LOOKAHEAD_FRAMES + 2],
    wedge_head: usize,
    wedge_tail: usize,
    frame_counter: u64,
    /// Release-smoothed envelope feeding the averages.
    env: f32,
    ma1: [f32; MA_LEN],
    ma2: [f32; MA_LEN],
    ma_write: usize,
    ma1_sum: f64,
    ma2_sum: f64,
    /// Telemetry: smallest smoothed gain since the last take().
    min_gain_since: f32,
    input_tp_since: f32,
    output_tp: TruePeakDetector,
    output_tp_since: f32,
}

impl Limiter {
    pub fn new() -> Self {
        Self {
            detector: TruePeakDetector::new(),
            delay: [[0.0; 2]; LOOKAHEAD_FRAMES],
            delay_write: 0,
            wedge: [(0, 1.0); LOOKAHEAD_FRAMES + 2],
            wedge_head: 0,
            wedge_tail: 0,
            frame_counter: 0,
            env: 1.0,
            ma1: [1.0; MA_LEN],
            ma2: [1.0; MA_LEN],
            ma_write: 0,
            ma1_sum: MA_LEN as f64,
            ma2_sum: MA_LEN as f64,
            min_gain_since: 1.0,
            input_tp_since: 0.0,
            output_tp: TruePeakDetector::new(),
            output_tp_since: 0.0,
        }
    }

    /// Reset all state (used when the limiter is toggled on).
    pub fn reset(&mut self) {
        *self = Self::new();
    }

    /// One frame. `ceiling_lin` is the true-peak ceiling as linear gain,
    /// `release_coeff` = exp(-1 / (release_seconds * sample_rate)).
    #[inline]
    pub fn process_frame(
        &mut self,
        input: [f32; 2],
        ceiling_lin: f32,
        release_coeff: f32,
    ) -> [f32; 2] {
        // 1-2: detect and compute required gain.
        let tp = self.detector.process_frame(input);
        if tp > self.input_tp_since {
            self.input_tp_since = tp;
        }
        let g_req = if tp > ceiling_lin { ceiling_lin / tp } else { 1.0 };

        // 3: sliding minimum over the last LOOKAHEAD_FRAMES gains.
        let n = self.frame_counter;
        self.frame_counter += 1;
        // Drop back entries dominated by the new value.
        while self.wedge_head != self.wedge_tail {
            let back = (self.wedge_tail + self.wedge.len() - 1) % self.wedge.len();
            if self.wedge[back].1 >= g_req {
                self.wedge_tail = back;
            } else {
                break;
            }
        }
        self.wedge[self.wedge_tail] = (n, g_req);
        self.wedge_tail = (self.wedge_tail + 1) % self.wedge.len();
        // Drop front entries older than the window.
        while self.wedge_head != self.wedge_tail {
            let (frame, _) = self.wedge[self.wedge_head];
            if frame + (LOOKAHEAD_FRAMES as u64) <= n {
                self.wedge_head = (self.wedge_head + 1) % self.wedge.len();
            } else {
                break;
            }
        }
        let window_min = self.wedge[self.wedge_head].1;

        // 4: exponential release toward unity, never above the window min.
        let released = 1.0 - (1.0 - self.env) * release_coeff;
        self.env = released.min(window_min);

        // 5: two moving averages (running sums, exact periodic recompute).
        let old1 = self.ma1[self.ma_write];
        self.ma1[self.ma_write] = self.env;
        self.ma1_sum += f64::from(self.env) - f64::from(old1);
        let avg1 = (self.ma1_sum / MA_LEN as f64) as f32;
        let old2 = self.ma2[self.ma_write];
        self.ma2[self.ma_write] = avg1;
        self.ma2_sum += f64::from(avg1) - f64::from(old2);
        let gain = (self.ma2_sum / MA_LEN as f64) as f32;
        self.ma_write = (self.ma_write + 1) % MA_LEN;
        if self.frame_counter % RESUM_INTERVAL == 0 {
            self.ma1_sum = self.ma1.iter().map(|v| f64::from(*v)).sum();
            self.ma2_sum = self.ma2.iter().map(|v| f64::from(*v)).sum();
        }
        if gain < self.min_gain_since {
            self.min_gain_since = gain;
        }

        // 6: delayed audio times smoothed gain.
        let delayed = self.delay[self.delay_write];
        self.delay[self.delay_write] = input;
        self.delay_write = (self.delay_write + 1) % LOOKAHEAD_FRAMES;
        let out = [delayed[0] * gain, delayed[1] * gain];
        let otp = self.output_tp.process_frame(out);
        if otp > self.output_tp_since {
            self.output_tp_since = otp;
        }
        out
    }

    /// Telemetry since the last call: (min smoothed gain, input true peak,
    /// output true peak). Resets the accumulators.
    pub fn take_telemetry(&mut self) -> (f32, f32, f32) {
        let t = (self.min_gain_since, self.input_tp_since, self.output_tp_since);
        self.min_gain_since = 1.0;
        self.input_tp_since = 0.0;
        self.output_tp_since = 0.0;
        t
    }
}

impl Default for Limiter {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dsp::db_to_lin;

    fn release_coeff(release_ms: f32) -> f32 {
        (-1.0 / (release_ms * 0.001 * 48_000.0)).exp()
    }

    /// Measure the true peak of a rendered buffer with a fresh detector.
    fn measure_tp(buf: &[[f32; 2]]) -> f32 {
        let mut det = TruePeakDetector::new();
        let mut peak = 0.0_f32;
        for frame in buf {
            peak = peak.max(det.process_frame(*frame));
        }
        peak
    }

    #[test]
    fn below_threshold_is_unity_gain_delayed() {
        let mut lim = Limiter::new();
        let ceiling = db_to_lin(-1.0);
        let rc = release_coeff(50.0);
        let tone = |i: usize| {
            (std::f32::consts::TAU * 300.0 * i as f32 / 48_000.0).sin() * 0.3
        };
        let mut out = Vec::new();
        for i in 0..9_600 {
            out.push(lim.process_frame([tone(i), tone(i)], ceiling, rc));
        }
        // Output equals input delayed by LOOKAHEAD_FRAMES, bit-exact.
        for i in LOOKAHEAD_FRAMES..9_600 {
            let expected = tone(i - LOOKAHEAD_FRAMES);
            assert_eq!(
                out[i][0].to_bits(),
                expected.to_bits(),
                "unity gain must be bit-exact at {i}"
            );
        }
    }

    #[test]
    fn ceiling_holds_for_hot_material_including_inter_sample_peaks() {
        let mut lim = Limiter::new();
        let ceiling = db_to_lin(-1.0);
        let rc = release_coeff(50.0);
        let mut out = Vec::new();
        // +6 dB pumped mix of an inter-sample-hot 12 kHz tone and bass.
        for i in 0..48_000 {
            let t = i as f32 / 48_000.0;
            let hot = (std::f32::consts::TAU * 12_000.0 * t + std::f32::consts::FRAC_PI_4).sin();
            let bass = (std::f32::consts::TAU * 60.0 * t).sin();
            let burst = if (i / 4_800) % 2 == 0 { 2.0 } else { 0.4 };
            let v = (hot * 0.7 + bass * 0.6) * burst;
            out.push(lim.process_frame([v, v], ceiling, rc));
        }
        let tp = measure_tp(&out[..]);
        let tp_db = 20.0 * tp.log10();
        assert!(
            tp_db <= -1.0 + 0.11,
            "true-peak ceiling -1 dBTP exceeded: measured {tp_db} dBTP"
        );
        // And it is actually limiting, not muting.
        let rms: f32 = (out.iter().map(|f| f[0] * f[0]).sum::<f32>() / out.len() as f32).sqrt();
        assert!(rms > 0.1, "signal survives limiting, rms {rms}");
    }

    #[test]
    fn ceiling_holds_on_a_strictly_decreasing_hot_ramp() {
        // Regression for the wedge-ring aliasing bug: a full-scale sine whose
        // amplitude ramps DOWN while staying above the ceiling makes g_req
        // strictly increase, which grows the sliding-min deque to full. A
        // too-small ring would alias full==empty, collapse the window
        // minimum, and let the still-delayed loud samples through above the
        // ceiling.
        let mut lim = Limiter::new();
        let ceiling = db_to_lin(-1.0);
        let rc = release_coeff(50.0);
        let mut out = Vec::new();
        let n = 4_000usize;
        for i in 0..n {
            // amplitude 4.0 -> 1.2 over the whole run (always hot).
            let amp = 4.0 - (4.0 - 1.2) * (i as f32 / n as f32);
            let v = (std::f32::consts::TAU * 137.0 * i as f32 / 48_000.0).sin() * amp;
            out.push(lim.process_frame([v, v], ceiling, rc));
        }
        let tp = measure_tp(&out[LOOKAHEAD_FRAMES..]);
        let tp_db = 20.0 * tp.log10();
        assert!(
            tp_db <= -1.0 + 0.2,
            "ceiling exceeded on a decreasing hot ramp: {tp_db} dBTP"
        );
    }

    #[test]
    fn gain_changes_are_smooth() {
        let mut lim = Limiter::new();
        let ceiling = db_to_lin(-1.0);
        let rc = release_coeff(50.0);
        let mut out = Vec::new();
        for i in 0..24_000 {
            // A steady 100 Hz tone that jumps 12 dB hot mid-way.
            let t = i as f32 / 48_000.0;
            let amp = if i > 12_000 { 2.4 } else { 0.6 };
            let v = (std::f32::consts::TAU * 100.0 * t).sin() * amp;
            out.push(lim.process_frame([v, v], ceiling, rc));
        }
        // The output may never step: max legitimate slope of a limited
        // 100 Hz tone at ceiling is ~0.012/frame; allow smoothing headroom.
        for (i, w) in out.windows(2).enumerate().skip(200) {
            let step = (w[1][0] - w[0][0]).abs();
            assert!(step < 0.03, "limiter stepped {step} at frame {i}");
        }
    }
}
