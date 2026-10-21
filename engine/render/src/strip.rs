//! Per-track channel strip state: gain/pan glides, automation cursors, the
//! 4-band EQ bank, send level glides, and block-local meter accumulation.
//! All fixed-size, allocated at engine construction (max_tracks), advanced
//! strictly per frame.

use crate::automation::AutoLane;
use crate::rt::{LANE_PAN, LANE_VOLUME, MAX_TRACK_LANES};
use crate::dsp::biquad::EqBank;
use crate::dsp::pan::balance_gains;
use crate::dsp::slew::Slew;

/// Full-scale glide time equals the declick window: gain moves at most
/// 1/ramp_frames per frame, pan at most 2/ramp_frames (its range is 2 wide).
pub struct Strip {
    pub gain: Slew,
    /// E5 §3.3: the mute/solo gate WITHOUT the fader, for the `Tap::Pre` send.
    ///
    /// ⚠️ **This is deliberately a SECOND, independent `Slew` and must stay
    /// one.** The document forbids refactoring
    /// `let g = strip.gain.advance(track_gain_target[idx] * vol_auto)` into a
    /// product of two slews: floating-point multiplication is not associative,
    /// so `(gate * fader) * x` and `gate * (fader * x)` differ in the low bit,
    /// and the post path's arithmetic must stay byte-identical or the §12.2
    /// legacy-null gate goes red. Two slews cost one `f32` and one compare per
    /// frame; the refactor costs the gate.
    pub gate: Slew,
    pub pan: Slew,
    pan_cached_pos: f32,
    pan_gains: (f32, f32),
    pub send_a: Slew,
    pub send_b: Slew,
    pub eq: EqBank,
    /// One evaluation cursor per lane SLOT, preallocated at engine
    /// construction. `AutoLane::value_at` is stateless given (lane, frame) —
    /// the cursor is a pure accelerator that self-heals on a seek — so a stale
    /// cursor after a session swap costs one re-search, never a wrong value.
    ///
    /// Fixed-size (not a Vec) because this is audio-thread state: no alloc.
    /// `compile` refuses a session with more than `MAX_TRACK_LANES` lanes.
    lane_cursors: [usize; MAX_TRACK_LANES],
    /// Volume fast path: cache the last evaluated dB so the exp only runs when
    /// the lane value actually changes.
    last_vol_db: f32,
    last_vol_lin: f32,
    // Block-local meter accumulation (flushed once per block).
    pub block_peak_l: f32,
    pub block_peak_r: f32,
    pub block_sumsq: f32,
}

impl Strip {
    pub fn new(sample_rate: u32, ramp_frames: u32) -> Self {
        let _ = sample_rate;
        let step = 1.0 / ramp_frames.max(1) as f32;
        Self {
            gain: Slew::new(1.0, step),
            gate: Slew::new(1.0, step),
            pan: Slew::new(0.0, 2.0 * step),
            pan_cached_pos: 0.0,
            pan_gains: (1.0, 1.0),
            send_a: Slew::new(0.0, step),
            send_b: Slew::new(0.0, step),
            eq: EqBank::new(sample_rate, ramp_frames.max(1)),
            lane_cursors: [0; MAX_TRACK_LANES],
            last_vol_db: 0.0,
            last_vol_lin: 1.0,
            block_peak_l: 0.0,
            block_peak_r: 0.0,
            block_sumsq: 0.0,
        }
    }

    /// Evaluate any lane slot at `frame`. `default` is what an absent lane
    /// reads as. This is the GENERAL path E2/E4/E8 use for device parameters;
    /// it is a constant-index cursor read, no lookup.
    #[inline]
    pub fn lane_value(
        &mut self,
        lane: Option<&AutoLane>,
        slot: usize,
        frame: u64,
        default: f32,
    ) -> f32 {
        match lane {
            None => default,
            Some(lane) => {
                debug_assert!(slot < MAX_TRACK_LANES);
                // Saturating index rather than a panic: on the audio thread a
                // wrong-but-bounded cursor is a re-search, a panic is a crash.
                let cursor = &mut self.lane_cursors[slot.min(MAX_TRACK_LANES - 1)];
                lane.value_at(frame, cursor)
            }
        }
    }

    /// Volume fast path: evaluate the volume lane (dB) and return the linear
    /// gain, converting only when the lane value changed since the last frame.
    /// Measurement justifies the cache (`db_to_lin` is a `powf`); the slot is
    /// still a normal lane, it just has a specialised reader.
    #[inline]
    pub fn vol_lane_lin(&mut self, lane: Option<&AutoLane>, frame: u64) -> f32 {
        match lane {
            None => 1.0,
            Some(_) => {
                let db = self.lane_value(lane, LANE_VOLUME, frame, 0.0);
                if db != self.last_vol_db {
                    self.last_vol_db = db;
                    self.last_vol_lin = crate::dsp::db_to_lin(db);
                }
                self.last_vol_lin
            }
        }
    }

    #[inline]
    pub fn pan_lane_value(&mut self, lane: Option<&AutoLane>, frame: u64) -> f32 {
        self.lane_value(lane, LANE_PAN, frame, 0.0)
    }

    /// Advance the pan glide toward `target` and return the (L, R) balance
    /// gains, recomputing the trig only when the position moved.
    #[inline]
    pub fn pan_gains(&mut self, target: f32) -> (f32, f32) {
        let pos = self.pan.advance(target);
        if pos != self.pan_cached_pos {
            self.pan_cached_pos = pos;
            self.pan_gains = balance_gains(pos);
        }
        self.pan_gains
    }

    #[inline]
    pub fn meter_frame(&mut self, l: f32, r: f32) {
        let al = l.abs();
        let ar = r.abs();
        if al > self.block_peak_l {
            self.block_peak_l = al;
        }
        if ar > self.block_peak_r {
            self.block_peak_r = ar;
        }
        self.block_sumsq += l * l + r * r;
    }

    /// Flush block meters; returns (peak_l, peak_r, rms) and resets.
    pub fn take_block_meters(&mut self, frames: usize) -> (f32, f32, f32) {
        let rms = if frames > 0 {
            (self.block_sumsq / (frames as f32 * 2.0)).sqrt()
        } else {
            0.0
        };
        let out = (self.block_peak_l, self.block_peak_r, rms);
        self.block_peak_l = 0.0;
        self.block_peak_r = 0.0;
        self.block_sumsq = 0.0;
        out
    }
}
