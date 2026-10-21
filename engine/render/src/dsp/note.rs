//! The E1 -> E2 note seam (DESIGN-E1-E2-notes-instruments.md section 2) plus the
//! RT-safe schedule reader that consumes it.
//!
//! `NoteEvent` used to be declared here as a **fixture of the locked contract**,
//! with the standing instruction: "when E1's definition arrives, this
//! declaration is deleted and replaced by a `pub use`". E1 has landed
//! ([`crate::notes::NoteEvent`], baked by `compile.rs` into the session
//! snapshot), so that is exactly what this now is. Nothing else in `dsp/**`
//! changed: every consumer reads the fields and never constructs the type
//! outside tests, and the two declarations were field-for-field identical.
//!
//! Keeping two structurally identical structs either side of a seam is how a
//! seam quietly forks; one type means a compile error is the worst that can
//! happen instead of a silent mismatch.
//!
//! `Num -> f32` happened at COMPILE time. This module never converts, never
//! allocates and never sorts on the audio thread: the events arrive already
//! sorted in a preallocated `Box<[NoteEvent]>`, and the cursor is a pure
//! accelerator that self-heals on seek/loop exactly like
//! `AutoLane::value_at` (`render/src/automation.rs:78-124`).
//!
//! ## `NoteSchedule` is NOT the cursor the engine drives
//!
//! ⚠️ The wired engine drives instruments from E1's [`crate::notes::NoteCursor`]
//! over [`crate::notes::NoteLane`], NOT from `NoteSchedule` — see the "two
//! cursors" note on [`crate::rt::TrackInstrument`]. `NoteSchedule` is kept
//! because it is `InstrumentNode`'s self-contained unit-test harness and a
//! usable standalone driver, but a node installed on a track is REQUIRED to
//! carry an empty schedule (`TrackInstrument::new` asserts it), because running
//! both cursors over the same events would double-trigger every note.

pub use crate::notes::NoteEvent;

/// Sorted, preallocated note events for one instrument node, plus a cursor.
///
/// Determinism contract: `drain_frame` is a PURE FUNCTION of `frame` and the
/// event slice. The cursor only makes the common (sequential) case O(1); any
/// discontinuity re-anchors with a binary search over the immutable slice, so
/// rendering the same schedule at any block size dispatches exactly the same
/// events at exactly the same frames. That is what carries the bit-identical
/// bounce guarantee through the note layer.
pub struct NoteSchedule {
    events: Box<[NoteEvent]>,
    cursor: usize,
}

impl NoteSchedule {
    /// Control-side construction: sorting and boxing happen HERE, never on the
    /// audio thread. Ordering is total and deterministic:
    /// `(frame, on, pitch, voice_hint)` — offs before ons at the same frame so
    /// a re-trigger of the same voice_hint releases before it restarts.
    pub fn new(mut events: Vec<NoteEvent>) -> Self {
        events.sort_by(|a, b| {
            a.frame
                .cmp(&b.frame)
                .then(a.on.cmp(&b.on))
                .then(a.pitch.cmp(&b.pitch))
                .then(a.voice_hint.cmp(&b.voice_hint))
        });
        Self {
            events: events.into_boxed_slice(),
            cursor: 0,
        }
    }

    pub fn empty() -> Self {
        Self {
            events: Vec::new().into_boxed_slice(),
            cursor: 0,
        }
    }

    pub fn events(&self) -> &[NoteEvent] {
        &self.events
    }

    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }

    /// Dispatch every event whose frame is exactly `frame`, in schedule order.
    ///
    /// Allocation-free, lock-free, no I/O. Events strictly before `frame` that
    /// the cursor has not reached are SKIPPED (a seek means they did not
    /// happen) — the note-off that keeps them from sticking is emitted
    /// control-side at the loop wrap / clip edge, per the section 2 contract.
    #[inline]
    pub fn drain_frame(&mut self, frame: u64, mut dispatch: impl FnMut(&NoteEvent)) {
        let n = self.events.len();
        if n == 0 {
            return;
        }
        if self.cursor > n {
            self.cursor = n;
        }
        // Invariant: everything in events[..cursor] has frame < `frame`.
        // Restore it after any discontinuity with a binary search (pure, so the
        // result cannot depend on how the timeline was chunked).
        let ahead = self.cursor > 0 && self.events[self.cursor - 1].frame >= frame;
        let behind = self.cursor < n && self.events[self.cursor].frame < frame;
        if ahead || behind {
            self.cursor = self.events.partition_point(|e| e.frame < frame);
        }
        while self.cursor < n && self.events[self.cursor].frame == frame {
            dispatch(&self.events[self.cursor]);
            self.cursor += 1;
        }
    }

    /// Force a re-anchor on the next `drain_frame` (session swap / transport
    /// reset). Cheap enough that it is never a correctness dependency —
    /// `drain_frame` self-heals regardless.
    pub fn rewind(&mut self) {
        self.cursor = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sched() -> NoteSchedule {
        NoteSchedule::new(vec![
            NoteEvent::on(10, 60, 1.0, 1),
            NoteEvent::off(20, 60, 1),
            NoteEvent::on(20, 64, 0.5, 2),
            NoteEvent::off(30, 64, 2),
        ])
    }

    fn collect(s: &mut NoteSchedule, frames: impl Iterator<Item = u64>) -> Vec<(u64, u8, bool)> {
        let mut got = Vec::new();
        for f in frames {
            s.drain_frame(f, |e| got.push((e.frame, e.pitch, e.on)));
        }
        got
    }

    #[test]
    fn off_sorts_before_on_at_the_same_frame() {
        let s = sched();
        let at20: Vec<bool> = s.events().iter().filter(|e| e.frame == 20).map(|e| e.on).collect();
        assert_eq!(at20, vec![false, true], "off must precede on at the same frame");
    }

    #[test]
    fn sequential_dispatch_is_exact() {
        let mut s = sched();
        let got = collect(&mut s, 0..40);
        assert_eq!(
            got,
            vec![(10, 60, true), (20, 60, false), (20, 64, true), (30, 64, false)]
        );
    }

    #[test]
    fn backward_jump_reanchors() {
        let mut s = sched();
        let _ = collect(&mut s, 0..40);
        // Loop back to 0 and replay: identical dispatch, no lost events.
        let again = collect(&mut s, 0..40);
        assert_eq!(again.len(), 4, "cursor self-healed on the backward jump");
    }

    #[test]
    fn forward_jump_skips_and_resyncs() {
        let mut s = sched();
        // Seek straight to 25: events at 10 and 20 are skipped.
        let got = collect(&mut s, 25..40);
        assert_eq!(got, vec![(30, 64, false)]);
    }

    #[test]
    fn chunked_traversal_matches_frame_by_frame() {
        let mut a = sched();
        let by_frame = collect(&mut a, 0..40);
        let mut b = sched();
        let mut chunked = Vec::new();
        for chunk_start in (0..40).step_by(7) {
            for f in chunk_start..(chunk_start + 7).min(40) {
                b.drain_frame(f, |e| chunked.push((e.frame, e.pitch, e.on)));
            }
        }
        assert_eq!(by_frame, chunked);
    }
}
