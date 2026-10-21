//! Baked MIDI notes as the RENDER side sees them (E1 §2 — THE SEAM).
//!
//! Notes are baked control-side into the session snapshot, exactly like
//! automation lanes. They are NOT streamed per-event through the command
//! channel. That follows the established pattern (`compile.rs` flattens
//! `Project` -> `RtSession`) and it is what keeps bounce bit-identical to live.
//!
//! Three pieces, mirroring `automation.rs`'s three:
//!
//! - [`NoteEvent`] — the §2 contract struct. `Copy`, RT-safe, no allocation.
//! - [`NoteLane`] — a **sorted, preallocated** `Box<[NoteEvent]>` per node,
//!   the direct analogue of `AutoLane`.
//! - [`NoteCursor`] — the accelerator that self-heals on seek and loop wrap,
//!   modelled on `AutoLane::value_at` (`automation.rs:78-124`), which already
//!   solves the sequential-read-plus-arbitrary-jump problem.
//!
//! # Why the cursor, and not just an index
//!
//! `AutoLane::value_at` is *stateless given (lane, frame)* — a cursor is a pure
//! accelerator, so a backward jump merely re-searches. Notes cannot be that,
//! for one reason: an instrument holds state between frames. If the transport
//! folds from loop-end back to loop-start while a note is sounding, the
//! authored note-off lies past the fold and will never be reached. **A stuck
//! note is the single worst failure mode here** — an instrument that never
//! releases. So `NoteCursor` carries the minimum state that makes the
//! guarantee structural rather than hopeful: a 128-bit "which pitches are
//! sounding" set, and the `voice_hint` that opened each one. On ANY frame
//! discontinuity it emits a note-off for every sounding pitch BEFORE
//! re-anchoring.
//!
//! # RT rules honoured here
//!
//! - No allocation, no locks, no I/O: `NoteLane` is built control-side and the
//!   cursor is fixed-size ([`NoteCursor`] is 528 bytes and `Copy`-free but
//!   never grows). [`FrameEvents`] is a caller-owned fixed buffer.
//! - `Num -> f32` happens ONCE, at compile time (`compile.rs`), never here.
//! - State advances per FRAME. `advance` is a pure function of
//!   `(lane, frame, cursor state)` and must be called once per frame, so block
//!   size cannot change the output — the rule bounce parity rests on.

use timeline_core::note::Note;
use timeline_core::TempoMap;

/// The E1/E2 seam. Locked in `DESIGN-E1-E2-notes-instruments.md` §2.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NoteEvent {
    /// Absolute frame in the session timeline.
    pub frame: u64,
    pub pitch: u8,
    /// Normalized 0.0..=1.0 for DSP. The `Num -> f32` conversion happens at
    /// COMPILE time; the audio thread never sees a `Num`.
    pub velocity: f32,
    /// true = note-on, false = note-off.
    pub on: bool,
    /// Stable per-note id so an off matches its on.
    pub voice_hint: u32,
}

impl NoteEvent {
    /// Test/fixture constructors. Control-side only — the audio thread reads
    /// baked events, it never builds one. (Moved here from `dsp/note.rs` when
    /// the two identical seam declarations were unified into this one.)
    pub fn on(frame: u64, pitch: u8, velocity: f32, voice_hint: u32) -> Self {
        Self {
            frame,
            pitch,
            velocity,
            on: true,
            voice_hint,
        }
    }

    pub fn off(frame: u64, pitch: u8, voice_hint: u32) -> Self {
        Self {
            frame,
            pitch,
            velocity: 0.0,
            on: false,
            voice_hint,
        }
    }
}

/// Number of MIDI pitches; the width of the "sounding" set.
pub const PITCHES: usize = 128;

/// Upper bound on the events one frame can carry: a full 128-pitch release
/// (loop wrap with everything held) plus the events authored at that frame.
pub const MAX_FRAME_EVENTS: usize = 256;

/// Fixed-size output buffer for one frame. Caller-owned and reused, so the
/// audio thread never allocates.
pub struct FrameEvents {
    buf: [NoteEvent; MAX_FRAME_EVENTS],
    len: usize,
}

impl Default for FrameEvents {
    fn default() -> Self {
        Self::new()
    }
}

impl FrameEvents {
    pub fn new() -> Self {
        FrameEvents {
            buf: [NoteEvent {
                frame: 0,
                pitch: 0,
                velocity: 0.0,
                on: false,
                voice_hint: 0,
            }; MAX_FRAME_EVENTS],
            len: 0,
        }
    }

    #[inline]
    pub fn clear(&mut self) {
        self.len = 0;
    }

    #[inline]
    pub fn as_slice(&self) -> &[NoteEvent] {
        &self.buf[..self.len]
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.len
    }

    /// Append, saturating. Dropping an event is preferable to a panic on the
    /// audio thread, and the bound cannot be hit by construction: at most 128
    /// synthetic offs plus the events at one frame.
    #[inline]
    fn push(&mut self, e: NoteEvent) {
        if self.len < MAX_FRAME_EVENTS {
            self.buf[self.len] = e;
            self.len += 1;
        }
    }
}

/// A node's baked note events: sorted, preallocated, immutable.
///
/// The sort key is `(frame, offs-before-ons, pitch, voice_hint)`. Offs sort
/// before ons at the same frame so a re-articulation of the same pitch on the
/// exact frame the previous note ends is a release-then-attack, never an
/// attack the previous note's release immediately kills.
#[derive(Debug, Clone, Default)]
pub struct NoteLane {
    events: Box<[NoteEvent]>,
}

impl NoteLane {
    /// Sorts into the canonical order. Takes the events by value; the caller
    /// (compile) owns the only allocation.
    pub fn new(mut events: Vec<NoteEvent>) -> Self {
        events.sort_by_key(|e| (e.frame, e.on, e.pitch, e.voice_hint));
        NoteLane {
            events: events.into_boxed_slice(),
        }
    }

    pub fn empty() -> Self {
        NoteLane {
            events: Vec::new().into_boxed_slice(),
        }
    }

    pub fn events(&self) -> &[NoteEvent] {
        &self.events
    }

    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }

    /// Last frame at which this lane produces anything (bounce-length helper).
    pub fn end_frame(&self) -> u64 {
        self.events.last().map(|e| e.frame).unwrap_or(0)
    }

    /// Index of the first event at or after `frame`. Allocation-free binary
    /// search; the cursor's re-anchor path.
    #[inline]
    fn seek(&self, frame: u64) -> usize {
        self.events.partition_point(|e| e.frame < frame)
    }
}

/// Per-node playback state over a [`NoteLane`].
///
/// Fixed size, no allocation, no locks. One per instrument node, preallocated
/// alongside the node.
pub struct NoteCursor {
    /// Index of the first event not yet delivered.
    idx: usize,
    /// Which pitches are currently sounding (2 x u64 = 128 bits).
    sounding: [u64; 2],
    /// The `voice_hint` that opened each sounding pitch, so a synthetic
    /// release carries the same id as its attack.
    voice: [u32; PITCHES],
    /// The frame delivered last, or `None` after a reset.
    last_frame: Option<u64>,
}

impl Default for NoteCursor {
    fn default() -> Self {
        Self::new()
    }
}

impl NoteCursor {
    pub fn new() -> Self {
        NoteCursor {
            idx: 0,
            sounding: [0; 2],
            voice: [0; PITCHES],
            last_frame: None,
        }
    }

    /// Forget everything WITHOUT emitting offs. Only correct when the consumer
    /// is also being discarded (session swap where the voice pool is reset).
    /// For a live swap use [`NoteCursor::release_all`] first.
    pub fn reset(&mut self) {
        self.idx = 0;
        self.sounding = [0; 2];
        self.last_frame = None;
    }

    #[inline]
    fn is_sounding(&self, pitch: u8) -> bool {
        let p = pitch as usize;
        self.sounding[p >> 6] & (1u64 << (p & 63)) != 0
    }

    #[inline]
    fn set_sounding(&mut self, pitch: u8, on: bool) {
        let p = pitch as usize;
        let bit = 1u64 << (p & 63);
        if on {
            self.sounding[p >> 6] |= bit;
        } else {
            self.sounding[p >> 6] &= !bit;
        }
    }

    /// Any pitch currently held.
    pub fn sounding_count(&self) -> u32 {
        self.sounding.iter().map(|w| w.count_ones()).sum()
    }

    /// Emit a note-off at `frame` for every sounding pitch and clear the set.
    /// The explicit release path: transport stop, session swap, loop wrap.
    pub fn release_all(&mut self, frame: u64, out: &mut FrameEvents) {
        for pitch in 0..PITCHES {
            if self.is_sounding(pitch as u8) {
                out.push(NoteEvent {
                    frame,
                    pitch: pitch as u8,
                    velocity: 0.0,
                    on: false,
                    voice_hint: self.voice[pitch],
                });
            }
        }
        self.sounding = [0; 2];
    }

    /// Every event the instrument must receive for `frame`.
    ///
    /// `out` is CLEARED first. Call exactly once per frame, in order, for
    /// block-size independence.
    ///
    /// Discontinuity handling (this is the anti-stuck-note guarantee):
    /// `frame != last + 1` means the transport seeked or folded a loop. Every
    /// sounding pitch is released AT `frame`, before the lane is re-anchored,
    /// so a note whose authored off lies past the fold can never hang.
    pub fn advance(&mut self, lane: &NoteLane, frame: u64, out: &mut FrameEvents) {
        out.clear();
        let contiguous = matches!(self.last_frame, Some(f) if f.wrapping_add(1) == frame);
        if !contiguous {
            // Release BEFORE re-anchoring: a loop wrap must not deliver the
            // new region's attacks while the old region's notes are still held.
            self.release_all(frame, out);
            self.idx = lane.seek(frame);
        }
        self.last_frame = Some(frame);

        let events = lane.events();
        // Skip anything the cursor is behind on (only reachable if a caller
        // steps frames non-contiguously forward, which the re-anchor above
        // already handles; kept as a cheap invariant).
        while self.idx < events.len() && events[self.idx].frame < frame {
            self.idx += 1;
        }
        while self.idx < events.len() && events[self.idx].frame == frame {
            let e = events[self.idx];
            self.idx += 1;
            if e.on {
                // Defensive: an attack on an already-sounding pitch releases
                // the previous voice first. `compile` truncates same-pitch
                // overlap so this should be unreachable; if it ever is
                // reachable, it degrades to a re-articulation, never a leak.
                if self.is_sounding(e.pitch) {
                    out.push(NoteEvent {
                        frame,
                        pitch: e.pitch,
                        velocity: 0.0,
                        on: false,
                        voice_hint: self.voice[e.pitch as usize],
                    });
                }
                self.set_sounding(e.pitch, true);
                self.voice[e.pitch as usize] = e.voice_hint;
                out.push(e);
            } else {
                // A release for a pitch that is not sounding is DROPPED. It
                // would otherwise reach the voice pool as a spurious off (and,
                // after a loop wrap release, a double release).
                if self.is_sounding(e.pitch) {
                    self.set_sounding(e.pitch, false);
                    out.push(e);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Control-side baking
// ---------------------------------------------------------------------------

/// Wire velocity (0..=127, `Num`) -> normalized DSP velocity (0.0..=1.0).
///
/// THE ONE PLACE `Num -> f32` happens for notes, and it happens at compile
/// time. `Num::as_f64` is documented as "never used for journaling"; this is
/// the render view, which is exactly what it is for.
#[inline]
pub fn normalize_velocity(v: &timeline_core::Num) -> f32 {
    let f = v.as_f64();
    let clamped = if f.is_finite() { f.clamp(0.0, 127.0) } else { 0.0 };
    (clamped / 127.0) as f32
}

/// Deterministic `voice_hint` for a note id.
///
/// §2 wants "a stable per-note id so off matches on". Note ids are strings and
/// the RT struct is `Copy`, so the id is hashed with FNV-1a — a pure function
/// of the id, therefore identical on every compile of the same project, which
/// is what keeps a bounce reproducible. Collisions are harmless: the hint is a
/// matching token for the voice pool, not an index.
pub fn voice_hint_for(note_id: &str) -> u32 {
    let mut h: u32 = 0x811c_9dc5;
    for b in note_id.as_bytes() {
        h ^= u32::from(*b);
        h = h.wrapping_mul(0x0100_0193);
    }
    h
}

/// Bake one clip's notes into absolute-frame events.
///
/// `clip_start_ticks` is the clip's timeline position; `content_start` /
/// `content_end` bound the clip's visible content window (for a note clip the
/// window is `[0, length_ticks)` — see `timeline_core::note`).
///
/// Rules, all of them load-bearing:
/// - a note is CROPPED to the clip's content window, so its off always lands
///   at or before the clip end. That is where "no stuck note at clip end"
///   comes from — it is structural, not a special case.
/// - a note starting before the window is skipped entirely (no retrigger for
///   material scrolled off the left edge), matching every DAW's behaviour.
/// - a note that survives cropping to zero frames emits NOTHING (neither on
///   nor off), so the on/off pairing stays exact.
/// - same-pitch overlap within a clip is resolved by truncating the earlier
///   note at the later note's attack, so at most one voice per pitch is live.
///   The model permits the overlap; resolving it here means the piano-roll
///   lane never has to reject a legal edit.
pub fn bake_clip_notes(
    notes: &[Note],
    clip_start_ticks: u64,
    content_start: u64,
    content_end: u64,
    tempo: &TempoMap,
    sample_rate: u32,
    out: &mut Vec<NoteEvent>,
) {
    // Pass 1: crop to the window, in the TICK domain (integer, exact).
    // (note_start_ticks, note_end_ticks, pitch, velocity, voice_hint)
    let mut cropped: Vec<(u64, u64, u8, f32, u32)> = Vec::with_capacity(notes.len());
    for n in notes {
        if n.start_ticks < content_start {
            continue; // starts before the window: not retriggered
        }
        if n.start_ticks >= content_end {
            continue; // starts after the window: silent
        }
        let end = n.end_ticks().min(content_end);
        if end <= n.start_ticks {
            continue;
        }
        cropped.push((
            n.start_ticks,
            end,
            n.pitch,
            normalize_velocity(&n.velocity),
            voice_hint_for(&n.id),
        ));
    }
    // Deterministic order for the overlap pass: same key as the model's total
    // ordering, with the voice hint as the final tiebreak so two notes that are
    // identical in every visible field still resolve reproducibly.
    cropped.sort_by_key(|(s, e, p, _, h)| (*p, *s, *e, *h));

    // Pass 2: same-pitch overlap -> truncate the earlier note at the later
    // attack. `cropped` is grouped by pitch and ascending in start.
    for i in 0..cropped.len().saturating_sub(1) {
        let (_, _, p_next, _, _) = cropped[i + 1];
        let (s_next, ..) = cropped[i + 1];
        let (s_cur, e_cur, p_cur, _, _) = cropped[i];
        if p_cur == p_next && e_cur > s_next {
            cropped[i].1 = s_next.max(s_cur);
        }
    }

    for (start_t, end_t, pitch, velocity, voice_hint) in cropped {
        if end_t <= start_t {
            // Truncated to nothing by an identical-onset duplicate: emit
            // neither event, so every on still has exactly one off.
            continue;
        }
        let on_tick = clip_start_ticks + (start_t - content_start);
        let off_tick = clip_start_ticks + (end_t - content_start);
        let on_frame = tempo.tick_to_frame(on_tick, sample_rate);
        let off_frame = tempo.tick_to_frame(off_tick, sample_rate);
        if off_frame <= on_frame {
            // Sub-frame note: inaudible, and emitting a same-frame on/off pair
            // would make the voice pool allocate and immediately free.
            continue;
        }
        out.push(NoteEvent {
            frame: on_frame,
            pitch,
            velocity,
            on: true,
            voice_hint,
        });
        out.push(NoteEvent {
            frame: off_frame,
            pitch,
            velocity: 0.0,
            on: false,
            voice_hint,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(frame: u64, pitch: u8, on: bool) -> NoteEvent {
        NoteEvent {
            frame,
            pitch,
            velocity: if on { 1.0 } else { 0.0 },
            on,
            voice_hint: pitch as u32,
        }
    }

    fn drain(lane: &NoteLane, cursor: &mut NoteCursor, frames: impl Iterator<Item = u64>) -> Vec<NoteEvent> {
        let mut out = FrameEvents::new();
        let mut all = Vec::new();
        for f in frames {
            cursor.advance(lane, f, &mut out);
            all.extend_from_slice(out.as_slice());
        }
        all
    }

    #[test]
    fn offs_sort_before_ons_at_the_same_frame() {
        let lane = NoteLane::new(vec![ev(100, 60, true), ev(100, 60, false)]);
        let order: Vec<bool> = lane.events().iter().map(|e| e.on).collect();
        assert_eq!(order, [false, true], "a release must precede an attack");
    }

    #[test]
    fn events_land_on_their_exact_frame_and_nowhere_else() {
        let lane = NoteLane::new(vec![ev(10, 60, true), ev(30, 60, false)]);
        let mut c = NoteCursor::new();
        let mut out = FrameEvents::new();
        for f in 0..40u64 {
            c.advance(&lane, f, &mut out);
            match f {
                10 => {
                    assert_eq!(out.len(), 1);
                    assert!(out.as_slice()[0].on);
                }
                30 => {
                    assert_eq!(out.len(), 1);
                    assert!(!out.as_slice()[0].on);
                }
                _ => assert!(out.is_empty(), "spurious event at frame {f}"),
            }
        }
    }

    #[test]
    fn a_contiguous_pass_delivers_exactly_the_baked_lane_in_order() {
        // The accelerator must never change the answer: a straight play-through
        // is the identity over the lane. Adjacent same-pitch notes (57 off /
        // 57 on) exercise the offs-before-ons rule on real data.
        let lane = NoteLane::new(vec![
            ev(10, 60, true),
            ev(57, 60, false),
            ev(57, 60, true),
            ev(58, 60, false),
            ev(400, 64, true),
            ev(401, 64, false),
        ]);
        let mut c = NoteCursor::new();
        let got = drain(&lane, &mut c, 0..500u64);
        assert_eq!(
            got.as_slice(),
            lane.events(),
            "a contiguous pass must deliver the lane verbatim"
        );
        assert_eq!(c.sounding_count(), 0, "nothing left held");
    }

    #[test]
    fn a_loop_wrap_releases_every_held_note() {
        // Note spans 10..1000; the loop folds at 500 back to 0. The authored
        // off at 1000 is never reached — the wrap must release it.
        let lane = NoteLane::new(vec![ev(10, 60, true), ev(1000, 60, false)]);
        let mut c = NoteCursor::new();
        let mut frames: Vec<u64> = (0..500).collect();
        frames.extend(0..20); // the fold
        let all = drain(&lane, &mut c, frames.into_iter());
        let ons = all.iter().filter(|e| e.on).count();
        let offs = all.iter().filter(|e| !e.on).count();
        assert_eq!(ons, 2, "attack once per pass");
        assert_eq!(offs, 1, "the wrap released the first pass's note");
        assert!(
            all.iter().any(|e| !e.on && e.frame == 0),
            "the release must land ON the fold frame, not later"
        );
    }

    #[test]
    fn a_backward_seek_releases_and_re_anchors() {
        let lane = NoteLane::new(vec![ev(10, 60, true), ev(900, 60, false)]);
        let mut c = NoteCursor::new();
        let mut out = FrameEvents::new();
        for f in 0..100u64 {
            c.advance(&lane, f, &mut out);
        }
        assert_eq!(c.sounding_count(), 1);
        c.advance(&lane, 5, &mut out);
        assert_eq!(c.sounding_count(), 0, "seek must not leave a note held");
        assert_eq!(out.len(), 1);
        assert!(!out.as_slice()[0].on);
        // And it re-anchored: the attack at 10 is delivered again.
        c.advance(&lane, 6, &mut out);
        assert!(out.is_empty());
        for f in 7..=10u64 {
            c.advance(&lane, f, &mut out);
        }
        assert_eq!(c.sounding_count(), 1);
    }

    #[test]
    fn a_release_for_a_pitch_that_is_not_sounding_is_dropped() {
        let lane = NoteLane::new(vec![ev(10, 60, true), ev(20, 60, false)]);
        let mut c = NoteCursor::new();
        // Seek past the attack: the cursor lands after frame 10, so the off at
        // 20 has no matching on and must not reach the instrument.
        let mut out = FrameEvents::new();
        c.advance(&lane, 15, &mut out);
        assert!(out.is_empty());
        c.advance(&lane, 20, &mut out);
        assert!(out.is_empty(), "orphan release must be swallowed");
    }

    #[test]
    fn velocity_normalizes_once_and_clamps() {
        use timeline_core::Num;
        assert_eq!(normalize_velocity(&Num::int(0)), 0.0);
        assert_eq!(normalize_velocity(&Num::int(127)), 1.0);
        assert!((normalize_velocity(&Num::int(64)) - 64.0 / 127.0).abs() < 1e-7);
        // Out-of-range never produces a NaN or a >1 gain on the audio thread.
        assert_eq!(normalize_velocity(&Num::int(-5)), 0.0);
        assert_eq!(normalize_velocity(&Num::int(300)), 1.0);
    }

    #[test]
    fn voice_hint_is_a_pure_function_of_the_id() {
        assert_eq!(voice_hint_for("note-a"), voice_hint_for("note-a"));
        assert_ne!(voice_hint_for("note-a"), voice_hint_for("note-b"));
    }
}
