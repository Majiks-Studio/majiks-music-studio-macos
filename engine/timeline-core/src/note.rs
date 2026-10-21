//! MIDI notes (E1, `DESIGN-E1-E2-notes-instruments.md` §1).
//!
//! A `Note` is journaled, undoable, `.mstudio`-serialized project content. It
//! lives on a note-backed [`crate::model::Clip`], never loose on a track, so
//! every existing clip operation (move, trim, split, duplicate, rename,
//! lineage) composes without a second scheduler.
//!
//! # Why `velocity` is `Num` and not `f32`
//!
//! E0 §1 invariant 6: every value that reaches the journal is `Num`. `Num`
//! preserves the integer/float *shape* (`100` vs `100.0`), and the blake3
//! chain hashes the canonical rendering of the exact shape. A `f32` velocity
//! would re-render `100` as `100.0` in an inverse and change the hash of an
//! entry that nothing semantically changed. The `Num -> f32` conversion
//! happens exactly ONCE, at compile time, in `render::compile` (§2).
//!
//! # Position domain
//!
//! `start_ticks` is CLIP-RELATIVE (§1), in the same 960-PPQ tick domain as
//! clips. Formally it indexes the clip's CONTENT coordinate — the coordinate
//! `Clip::source_offset_ticks` indexes for audio — and the audible window is
//! `[source_offset_ticks, source_offset_ticks + length_ticks)`. On a
//! note-backed clip `source_offset_ticks` is **pinned at 0** (E1 refuses
//! `clip.trim` on the start edge of a note clip, see `apply.rs`), so the two
//! coordinates are the same number and §1 reads literally. The distinction is
//! kept in the code because a later epic that lifts the trim restriction wants
//! the window, not a rewrite of every note position.
//!
//! # Ordering
//!
//! Total and deterministic: `(start_ticks, pitch, id)`, mirroring
//! `Automation::sort_lane`'s `(position_ticks, id)`. Nondeterministic ordering
//! changes serialized bytes, which changes the checkpoint, which breaks
//! byte-stability.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::num::Num;

/// Highest MIDI note number / velocity value on the wire.
pub const MIDI_MAX: i64 = 127;

/// One MIDI note on a note-backed clip.
/// The DERIVED serde form is camelCase because it is what the UI reads off the
/// snapshot (`agent-surface::host::project_json` serializes the model
/// directly). The CHECKPOINT form is hand-built in `package.rs`, like every
/// other clip field, and is camelCase too — so there is exactly one spelling
/// of a note on the wire.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    /// Stable identity for edit/undo. ULID-shaped in practice; opaque here.
    pub id: String,
    /// Position in the clip's content coordinate (see module docs).
    pub start_ticks: u64,
    /// Sounding length in ticks. Always > 0; zero-length is rejected at apply
    /// time, never stored.
    pub length_ticks: u64,
    /// MIDI note number, 0..=127.
    pub pitch: u8,
    /// 0..=127 on the wire. `Num`, NEVER f32/f64 (E0 §1 invariant 6).
    pub velocity: Num,
    /// Unknown fields, preserved round-trip. Every sibling struct has one;
    /// E0 §9.3 showed that omitting it means a future field is DESTROYED, not
    /// merely ignored.
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub extra: Map<String, Value>,
}

impl Note {
    pub fn new(
        id: impl Into<String>,
        start_ticks: u64,
        length_ticks: u64,
        pitch: u8,
        velocity: Num,
    ) -> Self {
        Note {
            id: id.into(),
            start_ticks,
            length_ticks,
            pitch,
            velocity,
            extra: Map::new(),
        }
    }

    /// One tick past the last sounding tick, in the content coordinate.
    pub fn end_ticks(&self) -> u64 {
        self.start_ticks.saturating_add(self.length_ticks)
    }
}

/// The one total ordering for notes: `(start_ticks, pitch, id)`.
///
/// Free function rather than an `Ord` impl so it cannot be silently shadowed
/// by a derive, and so `sort_by` sites read as the contract they implement.
pub fn sort_notes(notes: &mut [Note]) {
    notes.sort_by(|a, b| {
        (a.start_ticks, a.pitch, &a.id).cmp(&(b.start_ticks, b.pitch, &b.id))
    });
}

/// Velocity/pitch range check shared by every note command.
pub fn velocity_in_range(v: &Num) -> bool {
    let f = v.as_f64();
    (0.0..=(MIDI_MAX as f64)).contains(&f)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn n(id: &str, start: u64, pitch: u8) -> Note {
        Note::new(id, start, 480, pitch, Num::int(100))
    }

    #[test]
    fn ordering_is_total_and_breaks_ties_by_pitch_then_id() {
        // Deliberately adversarial: same tick, same pitch, differing only by
        // id; and same tick differing only by pitch.
        let mut a = vec![
            n("z", 0, 60),
            n("a", 0, 60),
            n("m", 0, 59),
            n("b", 960, 12),
            n("c", 0, 61),
        ];
        let mut b = vec![
            n("c", 0, 61),
            n("b", 960, 12),
            n("a", 0, 60),
            n("m", 0, 59),
            n("z", 0, 60),
        ];
        sort_notes(&mut a);
        sort_notes(&mut b);
        assert_eq!(a, b, "sort must be independent of insertion order");
        assert_eq!(
            a.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(),
            ["m", "a", "z", "c", "b"]
        );
    }

    #[test]
    fn velocity_keeps_its_wire_shape() {
        let int = Note::new("n1", 0, 480, 60, Num::int(100));
        let float: Note = serde_json::from_str(
            r#"{"id":"n1","startTicks":0,"lengthTicks":480,"pitch":60,"velocity":100.0}"#,
        )
        .unwrap();
        // 100 and 100.0 are DIFFERENT on the wire and must stay different, or
        // an inverse re-renders and changes an entry's hash.
        assert_ne!(
            serde_json::to_string(&int.velocity).unwrap(),
            serde_json::to_string(&float.velocity).unwrap()
        );
        assert_eq!(serde_json::to_string(&int.velocity).unwrap(), "100");
        assert_eq!(serde_json::to_string(&float.velocity).unwrap(), "100.0");
    }

    #[test]
    fn extra_survives_round_trip() {
        // The `extra` map is the forward-compat carrier. Checkpoint-level
        // unknown-KEY capture is done by `package::parse_note` (hand-built,
        // exactly like `parse_clip`); this covers the model half.
        let src = r#"{"id":"n1","startTicks":0,"lengthTicks":480,"pitch":60,"velocity":100,"extra":{"mpe":true}}"#;
        let note: Note = serde_json::from_str(src).unwrap();
        assert_eq!(note.extra["mpe"], serde_json::json!(true));
        let back = serde_json::to_value(&note).unwrap();
        assert_eq!(back["extra"]["mpe"], serde_json::json!(true));

        // Empty extra is omitted entirely (keeps the piano-roll snapshot lean).
        let plain = Note::new("n2", 0, 480, 60, Num::int(100));
        assert!(!serde_json::to_string(&plain).unwrap().contains("extra"));
    }
}
