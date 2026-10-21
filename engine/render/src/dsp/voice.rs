//! Fixed-size preallocated polyphonic voice pool with deterministic stealing.
//!
//! Every instrument in E2 owns one of these. The rules it exists to enforce
//! (DESIGN-E1-E2 section 3):
//!
//! - **Preallocated.** The voice slice is built ONCE, control-side, in `new`.
//!   Nothing in `note_on` / `note_off` / `render_frame` allocates, locks or
//!   does I/O. When the pool is full a note steals; it never grows.
//! - **Deterministic stealing.** `oldest-quietest` is implemented as a total
//!   order over `(stage rank, envelope level, serial)`, with the slice index
//!   as an implicit final tie-break. No randomness, no wall clock, no hash
//!   iteration order — so a project renders the same voices every time, which
//!   is a precondition of the bit-identical bounce.
//! - **Declicked.** A stolen voice does not cut. It fades over the engine's
//!   5 ms `MICRO_FADE_FRAMES` window and the incoming note starts when the
//!   fade lands, parked in a fixed-size `Copy` pending slot. That is the same
//!   declick discipline as the transport ramp and the session crossfade.
//! - **Per-frame.** `render_frame` advances every voice exactly one frame.
//!   There is no block-rate path here at all, so block size cannot be
//!   observed in the output.

/// Voices per instrument node. 32 is Ableton's own per-instrument default and
/// costs 32 * sizeof(Voice) of preallocated state — small enough to sit in a
/// snapshot, large enough that stealing is rare in real material.
pub const DEFAULT_MAX_VOICES: usize = 32;

/// A voice generator. Implementors hold ONLY fixed-size state; the pool never
/// allocates on their behalf.
pub trait VoiceDsp {
    /// Per-frame parameter snapshot. `Copy` and small: the node computes it
    /// once per frame from its `Slew`s and passes it by reference.
    ///
    /// It is a GAT so a generator can borrow immutable, node-owned data for
    /// the duration of one frame — the sampler's zone map, the drum rack's
    /// pads. That keeps sample lookup out of the pool and, more importantly,
    /// keeps the pool from having to own or clone anything per note.
    type Params<'a>: Copy;

    /// Begin a note. Returns false if this generator cannot play the pitch
    /// (e.g. a sampler with no zone mapped, an empty drum pad) — the pool then
    /// leaves the slot free instead of burning a voice on silence.
    fn note_on(
        &mut self,
        pitch: u8,
        velocity: f32,
        params: &Self::Params<'_>,
        sample_rate: u32,
    ) -> bool;

    /// Enter release. One-shot generators may ignore this.
    fn note_off(&mut self);

    /// Immediate silence, no ramp. Pool reset / panic only.
    fn kill(&mut self);

    /// Advance exactly one frame.
    fn render_frame(&mut self, params: &Self::Params<'_>, sample_rate: u32) -> [f32; 2];

    /// True once the voice can be reclaimed without any audible loss.
    fn is_finished(&self) -> bool;

    /// Current envelope level, for the stealing order.
    fn level(&self) -> f32;

    /// True while releasing — a releasing voice is the cheapest thing to steal.
    fn is_releasing(&self) -> bool;
}

#[derive(Debug, Clone, Copy)]
struct PendingNote {
    pitch: u8,
    velocity: f32,
    voice_hint: u32,
    /// The note-off arrived while the steal fade was still running (a note
    /// shorter than 5 ms). Release it the instant it starts, rather than
    /// dropping the off and stranding the voice on forever.
    off_early: bool,
}

struct Voice<D> {
    dsp: D,
    active: bool,
    voice_hint: u32,
    /// Monotonic allocation order. "Oldest" == smallest serial.
    serial: u64,
    steal_left: u32,
    steal_gain: f32,
    pending: Option<PendingNote>,
}

impl<D: VoiceDsp> Voice<D> {
    fn new(dsp: D) -> Self {
        Self {
            dsp,
            active: false,
            voice_hint: 0,
            serial: 0,
            steal_left: 0,
            steal_gain: 1.0,
            pending: None,
        }
    }

    #[inline]
    fn free(&self) -> bool {
        !self.active && self.pending.is_none()
    }
}

pub struct VoicePool<D: VoiceDsp> {
    voices: Box<[Voice<D>]>,
    sample_rate: u32,
    next_serial: u64,
    steal_frames: u32,
    steals: u64,
    dropped_notes: u64,
}

impl<D: VoiceDsp> VoicePool<D> {
    /// PREALLOCATION happens here, on the control thread. `make` is called
    /// `capacity` times up front and never again.
    pub fn new(capacity: usize, sample_rate: u32, steal_frames: u32, make: impl Fn() -> D) -> Self {
        let capacity = capacity.max(1);
        let steal_frames = steal_frames.max(1);
        let voices: Vec<Voice<D>> = (0..capacity).map(|_| Voice::new(make())).collect();
        Self {
            voices: voices.into_boxed_slice(),
            sample_rate,
            next_serial: 1,
            steal_frames,
            steals: 0,
            dropped_notes: 0,
        }
    }

    pub fn capacity(&self) -> usize {
        self.voices.len()
    }

    pub fn active_voices(&self) -> usize {
        self.voices.iter().filter(|v| v.active).count()
    }

    /// Voices currently sounding a hint that has not been released. Used by
    /// the stuck-note tests.
    pub fn held_voices(&self) -> usize {
        self.voices
            .iter()
            .filter(|v| v.active && !v.dsp.is_releasing())
            .count()
    }

    pub fn steal_count(&self) -> u64 {
        self.steals
    }

    /// Note-ons that found no playable generator (unmapped pitch). Not an
    /// error — a drum rack with 4 pads is silent on the other 124 keys — but
    /// a counter beats a silent nothing when a sampler map is wrong.
    pub fn dropped_notes(&self) -> u64 {
        self.dropped_notes
    }

    pub fn active_hints(&self) -> impl Iterator<Item = u32> + '_ {
        self.voices.iter().filter(|v| v.active).map(|v| v.voice_hint)
    }

    /// Full reset: silence everything immediately, clear pending notes.
    /// Control-side (session swap) or panic path.
    pub fn reset(&mut self) {
        for v in self.voices.iter_mut() {
            v.dsp.kill();
            v.active = false;
            v.pending = None;
            v.steal_left = 0;
            v.steal_gain = 1.0;
        }
    }

    /// Release every sounding voice. This is the anti-stuck-note lever; it
    /// ramps through each voice's own release, so it is click-free.
    pub fn all_notes_off(&mut self) {
        for v in self.voices.iter_mut() {
            if v.active {
                v.dsp.note_off();
            }
            if let Some(p) = v.pending.as_mut() {
                p.off_early = true;
            }
        }
    }

    #[inline]
    fn start(
        &mut self,
        idx: usize,
        pitch: u8,
        velocity: f32,
        hint: u32,
        params: &D::Params<'_>,
    ) -> bool {
        let rate = self.sample_rate;
        let serial = self.next_serial;
        let v = &mut self.voices[idx];
        if !v.dsp.note_on(pitch, velocity, params, rate) {
            v.active = false;
            self.dropped_notes += 1;
            return false;
        }
        self.next_serial += 1;
        v.active = true;
        v.voice_hint = hint;
        v.serial = serial;
        v.steal_left = 0;
        v.steal_gain = 1.0;
        true
    }

    /// Deterministic victim selection: total order over
    /// `(rank, level, serial, index)`.
    ///
    /// rank 0 = releasing (already on its way out)
    /// rank 1 = sounding
    /// rank 2 = mid-steal with a note parked on it — stealing this one would
    ///          silently DROP the parked note, so it is always the last resort.
    fn pick_victim(&self) -> usize {
        let mut best = 0usize;
        let mut best_rank = u8::MAX;
        let mut best_level = f32::INFINITY;
        let mut best_serial = u64::MAX;
        for (i, v) in self.voices.iter().enumerate() {
            let rank = if v.pending.is_some() {
                2u8
            } else if v.dsp.is_releasing() {
                0u8
            } else {
                1u8
            };
            let level = v.dsp.level();
            let better = rank < best_rank
                || (rank == best_rank && level < best_level)
                || (rank == best_rank && level == best_level && v.serial < best_serial);
            if better {
                best = i;
                best_rank = rank;
                best_level = level;
                best_serial = v.serial;
            }
        }
        best
    }

    #[inline]
    fn begin_steal(&mut self, idx: usize, pitch: u8, velocity: f32, hint: u32) {
        let steal_frames = self.steal_frames;
        let v = &mut self.voices[idx];
        v.steal_left = steal_frames;
        v.steal_gain = 1.0;
        v.pending = Some(PendingNote {
            pitch,
            velocity,
            voice_hint: hint,
            off_early: false,
        });
        self.steals += 1;
    }

    /// Start a note. Allocation-free: at most one linear scan of the fixed
    /// voice slice.
    pub fn note_on(&mut self, pitch: u8, velocity: f32, hint: u32, params: &D::Params<'_>) {
        // 1. A live voice already owns this hint (duplicate on, or a retrigger
        //    of a held note). Retrigger IN PLACE so the matching off still has
        //    exactly one owner — otherwise the first voice is stranded.
        if let Some(idx) = self
            .voices
            .iter()
            .position(|v| v.active && v.voice_hint == hint)
        {
            self.begin_steal(idx, pitch, velocity, hint);
            return;
        }
        // 2. First free slot (lowest index) — deterministic.
        if let Some(idx) = self.voices.iter().position(|v| v.free()) {
            self.start(idx, pitch, velocity, hint, params);
            return;
        }
        // 3. Full: steal.
        let idx = self.pick_victim();
        self.begin_steal(idx, pitch, velocity, hint);
    }

    /// Release the voice owning `hint`. A hint with no owner is a normal
    /// outcome (its voice was already stolen or its release finished), not an
    /// error.
    pub fn note_off(&mut self, hint: u32) {
        for v in self.voices.iter_mut() {
            if let Some(p) = v.pending.as_mut() {
                if p.voice_hint == hint {
                    p.off_early = true;
                    return;
                }
            }
            if v.active && v.voice_hint == hint {
                v.dsp.note_off();
                return;
            }
        }
    }

    /// Advance every voice exactly one frame and sum. No allocation, no locks.
    ///
    /// The steal fade is advanced BEFORE the voice renders, so the gain applied
    /// to a fading frame is the post-decrement value. The sequence is therefore
    /// (N-1)/N ... 1/N, 0/N: it ends on EXACTLY 0.0 and the parked note starts
    /// on the following frame, so the outgoing and incoming notes never overlap
    /// and there is no residual step. (Ending one step ABOVE zero is the
    /// classic declick bug — inaudible at 240 frames, obvious at 8.)
    #[inline]
    pub fn render_frame(&mut self, params: &D::Params<'_>) -> [f32; 2] {
        let rate = self.sample_rate;
        let denom = self.steal_frames as f32;
        let mut out = [0.0f32; 2];
        let mut serial = self.next_serial;
        let mut started = false;
        let mut dropped = 0u64;
        for v in self.voices.iter_mut() {
            let mut fade_done = false;
            if v.steal_left > 0 {
                v.steal_left -= 1;
                v.steal_gain = v.steal_left as f32 / denom;
                fade_done = v.steal_left == 0;
            }
            if v.active {
                let s = v.dsp.render_frame(params, rate);
                let g = v.steal_gain;
                out[0] += s[0] * g;
                out[1] += s[1] * g;
                if v.dsp.is_finished() {
                    v.active = false;
                }
            }
            if fade_done {
                v.dsp.kill();
                v.active = false;
                v.steal_gain = 1.0;
                if let Some(p) = v.pending.take() {
                    if v.dsp.note_on(p.pitch, p.velocity, params, rate) {
                        v.active = true;
                        v.voice_hint = p.voice_hint;
                        v.serial = serial;
                        serial += 1;
                        started = true;
                        if p.off_early {
                            v.dsp.note_off();
                        }
                    } else {
                        dropped += 1;
                    }
                }
            }
        }
        if started {
            self.next_serial = serial;
        }
        self.dropped_notes += dropped;
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Minimal generator: a DC level that decays linearly, so "level" and
    /// "finished" are trivially inspectable and stealing order is obvious.
    #[derive(Debug, Clone, Copy, Default)]
    struct TestVoice {
        level: f32,
        decay: f32,
        releasing: bool,
        pitch: u8,
    }

    #[derive(Debug, Clone, Copy)]
    struct TestParams {
        decay: f32,
    }

    impl VoiceDsp for TestVoice {
        type Params<'a> = TestParams;

        fn note_on(&mut self, pitch: u8, velocity: f32, p: &TestParams, _sr: u32) -> bool {
            if pitch == 0 {
                return false; // "unmapped"
            }
            self.level = velocity;
            self.decay = p.decay;
            self.releasing = false;
            self.pitch = pitch;
            true
        }
        fn note_off(&mut self) {
            self.releasing = true;
            self.decay = 0.1;
        }
        fn kill(&mut self) {
            self.level = 0.0;
            self.releasing = false;
        }
        fn render_frame(&mut self, _p: &TestParams, _sr: u32) -> [f32; 2] {
            let v = self.level;
            self.level = (self.level - self.decay).max(0.0);
            [v, v]
        }
        fn is_finished(&self) -> bool {
            self.level <= 0.0
        }
        fn level(&self) -> f32 {
            self.level
        }
        fn is_releasing(&self) -> bool {
            self.releasing
        }
    }

    fn pool(cap: usize) -> VoicePool<TestVoice> {
        VoicePool::new(cap, 48_000, 8, TestVoice::default)
    }

    const P: TestParams = TestParams { decay: 0.0 };

    #[test]
    fn allocates_lowest_free_index_first() {
        let mut p = pool(4);
        p.note_on(60, 1.0, 1, &P);
        p.note_on(62, 1.0, 2, &P);
        assert_eq!(p.active_voices(), 2);
        assert_eq!(p.voices[0].voice_hint, 1);
        assert_eq!(p.voices[1].voice_hint, 2);
    }

    #[test]
    fn polyphony_sums() {
        let mut p = pool(4);
        p.note_on(60, 0.25, 1, &P);
        p.note_on(62, 0.5, 2, &P);
        let out = p.render_frame(&P);
        assert_eq!(out[0], 0.75, "two voices sum");
    }

    #[test]
    fn steals_the_quietest_then_the_oldest() {
        let mut p = pool(2);
        p.note_on(60, 0.9, 1, &P); // serial 1, level .9
        p.note_on(62, 0.2, 2, &P); // serial 2, level .2  <- quietest
        p.note_on(64, 1.0, 3, &P); // full -> steals hint 2
        assert_eq!(p.steal_count(), 1);
        assert!(p.voices[1].pending.is_some(), "quietest voice was the victim");
        assert!(p.voices[0].pending.is_none());
    }

    #[test]
    fn a_releasing_voice_is_stolen_before_a_louder_sounding_one() {
        let mut p = pool(2);
        p.note_on(60, 1.0, 1, &P);
        p.note_on(62, 0.1, 2, &P);
        p.note_off(1); // voice 0 is now releasing, but LOUDER
        p.note_on(64, 1.0, 3, &P);
        assert!(
            p.voices[0].pending.is_some(),
            "releasing outranks quiet-but-sounding"
        );
    }

    #[test]
    fn stealing_is_deterministic_across_identical_runs() {
        let run = || {
            let mut p = pool(3);
            let mut out = Vec::new();
            for (i, (pitch, vel)) in [(60u8, 1.0f32), (62, 0.4), (64, 0.7), (65, 0.9), (67, 0.2)]
                .into_iter()
                .enumerate()
            {
                p.note_on(pitch, vel, i as u32 + 1, &P);
                for _ in 0..4 {
                    out.push(p.render_frame(&P));
                }
            }
            let hints: Vec<u32> = p.active_hints().collect();
            (out, hints, p.steal_count())
        };
        let a = run();
        let b = run();
        assert_eq!(a.0, b.0, "rendered output is bit-identical");
        assert_eq!(a.1, b.1, "the same voices survive");
        assert_eq!(a.2, b.2, "the same number of steals");
    }

    #[test]
    fn a_stolen_voice_fades_rather_than_cutting() {
        let mut p = pool(1);
        p.note_on(60, 1.0, 1, &P);
        p.note_on(62, 1.0, 2, &P); // steals immediately
        let mut prev = f32::INFINITY;
        for _ in 0..8 {
            let s = p.render_frame(&P)[0];
            assert!(s <= prev + 1e-6, "steal fade is monotone: {s} after {prev}");
            prev = s;
        }
        assert_eq!(prev, 0.0, "fade reaches zero before the new note starts");
        let after = p.render_frame(&P)[0];
        assert!(after > 0.0, "the parked note started, got {after}");
        assert_eq!(p.voices[0].voice_hint, 2);
    }

    #[test]
    fn note_off_during_a_steal_fade_is_not_lost() {
        let mut p = pool(1);
        p.note_on(60, 1.0, 1, &P);
        p.note_on(62, 1.0, 2, &P);
        p.note_off(2); // arrives before the parked note even starts
        for _ in 0..9 {
            p.render_frame(&P);
        }
        assert!(
            p.voices[0].dsp.is_releasing() || !p.voices[0].active,
            "the parked note released instead of sticking"
        );
    }

    #[test]
    fn retrigger_of_a_live_hint_reuses_its_voice() {
        let mut p = pool(4);
        p.note_on(60, 1.0, 7, &P);
        p.note_on(72, 1.0, 7, &P);
        assert_eq!(p.active_voices(), 1, "no second voice for the same hint");
        assert_eq!(p.steal_count(), 1);
    }

    #[test]
    fn unmapped_pitch_burns_no_voice() {
        let mut p = pool(2);
        p.note_on(0, 1.0, 1, &P);
        assert_eq!(p.active_voices(), 0);
        assert_eq!(p.dropped_notes(), 1);
        p.note_on(60, 1.0, 2, &P);
        assert_eq!(p.active_voices(), 1, "the slot was still free");
    }

    #[test]
    fn all_notes_off_leaves_nothing_held() {
        let mut p = pool(4);
        for i in 0..4u32 {
            p.note_on(60 + i as u8, 1.0, i, &P);
        }
        assert_eq!(p.held_voices(), 4);
        p.all_notes_off();
        assert_eq!(p.held_voices(), 0);
    }
}
