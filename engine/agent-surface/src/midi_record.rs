//! MIDI take capture: buffer note-on/off while recording and land one batched
//! `note.add` (plus optional `clip.placeMidi`) as a single undoable unit.
//!
//! Timing: each event is stamped with absolute project ticks from the host's
//! capture clock (`tick_to_frame` inverted via the live position when playing,
//! otherwise a wall-clock → ticks conversion so a performance without an
//! explicit transport.play still lands on the grid). Punch-in/out filter the
//! window; open notes are force-closed at stop/punch so there are no stuck notes.

use std::collections::BTreeMap;
use std::time::Instant;

use serde_json::{json, Value};
use timeline_core::PPQ;

/// One completed note ready for `note.add` (absolute project ticks until land).
#[derive(Debug, Clone)]
pub struct CapturedMidiNote {
    pub pitch: u8,
    pub velocity: u8,
    pub on_ticks: u64,
    pub off_ticks: u64,
}

/// A note-on that has not yet received its note-off.
#[derive(Debug, Clone)]
struct OpenNote {
    velocity: u8,
    on_ticks: u64,
}

/// In-progress MIDI capture for one armed instrument track.
#[derive(Debug)]
pub struct MidiCapture {
    pub track_id: String,
    /// Absolute tick where the take begins (punch-in / record start).
    pub start_ticks: u64,
    /// When set, notes that start at or after this tick are ignored; open notes
    /// close here on land.
    pub punch_out_ticks: Option<u64>,
    /// Completed notes (absolute ticks).
    notes: Vec<CapturedMidiNote>,
    /// Currently held pitches → open note.
    open: BTreeMap<u8, OpenNote>,
    /// Wall clock at capture start (for offline / not-playing stamping).
    t0: Instant,
    /// Project BPM at start (integer shape for wall-clock conversion).
    bpm_num: u32,
    bpm_den: u32,
    /// Test / deterministic override: when set, `now_ticks` returns this value
    /// instead of wall-clock or transport. Cleared after each read when
    /// `consume_override` is true.
    now_override: Option<u64>,
}

impl MidiCapture {
    pub fn new(
        track_id: String,
        start_ticks: u64,
        punch_out_ticks: Option<u64>,
        bpm_num: u32,
        bpm_den: u32,
    ) -> Self {
        Self {
            track_id,
            start_ticks,
            punch_out_ticks: punch_out_ticks.filter(|p| *p > start_ticks),
            notes: Vec::new(),
            open: BTreeMap::new(),
            t0: Instant::now(),
            bpm_num: bpm_num.max(1),
            bpm_den: bpm_den.max(1),
            now_override: None,
        }
    }

    /// Deterministic clock for tests that drive `feed_event` without sleeping.
    pub fn set_now_ticks(&mut self, ticks: u64) {
        self.now_override = Some(ticks);
    }

    /// Wall-clock absolute ticks for a real-time performance when transport is
    /// not advancing. `start_ticks + elapsed`.
    pub fn wall_now_ticks(&self) -> u64 {
        let elapsed = self.t0.elapsed().as_secs_f64();
        // ticks = seconds * (bpm_num/bpm_den) / 60 * PPQ
        let ticks = elapsed * (self.bpm_num as f64) / (self.bpm_den as f64) / 60.0 * (PPQ as f64);
        self.start_ticks.saturating_add(ticks.round().max(0.0) as u64)
    }

    pub fn take_override(&mut self) -> Option<u64> {
        self.now_override.take()
    }

    pub fn peek_override(&self) -> Option<u64> {
        self.now_override
    }

    /// Note-on at absolute `ticks`. Outside the punch window → ignored.
    pub fn note_on(&mut self, pitch: u8, velocity: u8, ticks: u64) {
        if !self.in_window(ticks) {
            return;
        }
        // Retrigger: close the previous at this tick (length ≥ 1).
        if let Some(open) = self.open.remove(&pitch) {
            self.push_completed(pitch, open.velocity, open.on_ticks, ticks);
        }
        let vel = if velocity == 0 { 100 } else { velocity };
        self.open.insert(
            pitch,
            OpenNote {
                velocity: vel,
                on_ticks: ticks,
            },
        );
    }

    /// Note-off at absolute `ticks`.
    pub fn note_off(&mut self, pitch: u8, ticks: u64) {
        let Some(open) = self.open.remove(&pitch) else {
            return;
        };
        // Off before punch-in (shouldn't happen if on was filtered) — drop.
        if open.on_ticks < self.start_ticks {
            return;
        }
        let off = match self.punch_out_ticks {
            Some(po) if ticks > po => po,
            _ => ticks,
        };
        self.push_completed(pitch, open.velocity, open.on_ticks, off);
    }

    /// Force-close every open note at `ticks` (record.stop / punch-out).
    /// Guarantees no stuck notes.
    pub fn close_all_at(&mut self, ticks: u64) {
        let pitches: Vec<u8> = self.open.keys().copied().collect();
        for pitch in pitches {
            self.note_off(pitch, ticks);
        }
    }

    fn in_window(&self, ticks: u64) -> bool {
        if ticks < self.start_ticks {
            return false;
        }
        if let Some(po) = self.punch_out_ticks {
            if ticks >= po {
                return false;
            }
        }
        true
    }

    fn push_completed(&mut self, pitch: u8, velocity: u8, on_ticks: u64, off_ticks: u64) {
        let off = off_ticks.max(on_ticks.saturating_add(1));
        self.notes.push(CapturedMidiNote {
            pitch,
            velocity,
            on_ticks,
            off_ticks: off,
        });
    }

    /// Drain completed notes for landing. Does not clear open notes.
    pub fn completed(&self) -> &[CapturedMidiNote] {
        &self.notes
    }

    pub fn is_empty(&self) -> bool {
        self.notes.is_empty() && self.open.is_empty()
    }

    /// The pitches whose keys are DOWN right now (note-on with no note-off yet).
    /// Sorted ascending — `open` is a `BTreeMap`, so this is already ordered and
    /// stable, which matters because the UI lights keys from it and a set that
    /// reordered every poll would flicker.
    pub fn sounding_pitches(&self) -> Vec<u8> {
        self.open.keys().copied().collect()
    }

    /// How many notes are finished and keepable.
    pub fn completed_len(&self) -> usize {
        self.notes.len()
    }

    /// Earliest note-on among the completed notes (`None` when empty). The
    /// performance buffer lands a take starting HERE rather than at its own
    /// `start_ticks`, so "keep what I just played" does not prepend however many
    /// bars of silence elapsed between opening the buffer and the first key.
    pub fn first_on_ticks(&self) -> Option<u64> {
        self.notes.iter().map(|n| n.on_ticks).min()
    }

    /// Drop every completed note that ENDED strictly before `ticks`.
    ///
    /// The rolling-window half of the retro-capture buffer: it is what keeps an
    /// always-on capture bounded without an explicit stop. A note still being
    /// held is never touched — a held pedal tone must not be trimmed out from
    /// under the finger holding it.
    pub fn trim_completed_before(&mut self, ticks: u64) {
        self.notes.retain(|n| n.off_ticks >= ticks);
    }

    /// Hard cap on completed notes: keep the `max` most recent by note-on,
    /// dropping the oldest. The second half of the bound — a window alone does
    /// not bound a dense performance (a fast trill inside one bar), and the
    /// audio thread never sees this buffer but memory is still memory.
    pub fn cap_completed(&mut self, max: usize) {
        if self.notes.len() <= max {
            return;
        }
        // Sort by on_ticks so "oldest" means oldest MUSICALLY, not oldest by
        // completion order — a long note started first completes last.
        self.notes.sort_by(|a, b| a.on_ticks.cmp(&b.on_ticks).then(a.pitch.cmp(&b.pitch)));
        let drop = self.notes.len() - max;
        self.notes.drain(0..drop);
    }

    /// Move the whole performance so its first note-on sits at `new_first_on`,
    /// keeping every internal interval EXACTLY.
    ///
    /// This is how a take gets relocated without being damaged. `reanchor`
    /// above deliberately refuses to move a non-empty buffer, because moving the
    /// origin while notes are still ARRIVING would re-time them against the
    /// notes that come after; this is the other case — the performance is
    /// finished, it is being landed, and every note moves by the same delta, so
    /// nothing is re-timed relative to anything else.
    ///
    /// Rhythm is preserved by construction: one delta, applied to every on and
    /// every off. `saturating_*` so a shift past zero clamps rather than
    /// wrapping a `u64` into the far future.
    pub fn rebase(&mut self, new_first_on: u64) {
        let Some(first) = self.first_on_ticks() else {
            return;
        };
        if first == new_first_on {
            return;
        }
        let shift = |t: u64| {
            if new_first_on >= first {
                t.saturating_add(new_first_on - first)
            } else {
                t.saturating_sub(first - new_first_on)
            }
        };
        for n in &mut self.notes {
            n.on_ticks = shift(n.on_ticks);
            n.off_ticks = shift(n.off_ticks);
        }
        self.start_ticks = shift(self.start_ticks);
        self.punch_out_ticks = self.punch_out_ticks.map(shift);
    }

    /// Discard everything, completed and held. Used when the buffer is handed
    /// off (kept) or invalidated (a real take starts and owns the input).
    pub fn clear(&mut self) {
        self.notes.clear();
        self.open.clear();
    }

    /// Re-anchor an EMPTY buffer at a new absolute tick, restarting its
    /// wall-clock origin. Refuses when anything is buffered, because moving the
    /// origin under existing notes would silently re-time them.
    pub fn reanchor(&mut self, start_ticks: u64) -> bool {
        if !self.is_empty() {
            return false;
        }
        self.start_ticks = start_ticks;
        self.punch_out_ticks = None;
        self.t0 = Instant::now();
        self.now_override = None;
        true
    }

    /// Build the wire `notes` array for `note.add`, clip-relative to `clip_start`.
    /// Notes are sorted deterministically by (start, pitch, original index).
    /// `id_for` mints stable unique ids (host passes a ULID mint).
    pub fn to_note_specs<F>(&self, clip_start: u64, mut id_for: F) -> Vec<Value>
    where
        F: FnMut(&CapturedMidiNote) -> String,
    {
        let mut items: Vec<_> = self.notes.iter().collect();
        items.sort_by(|a, b| {
            a.on_ticks
                .cmp(&b.on_ticks)
                .then(a.pitch.cmp(&b.pitch))
        });
        items
            .into_iter()
            .map(|n| {
                let start = n.on_ticks.saturating_sub(clip_start);
                let length = n.off_ticks.saturating_sub(n.on_ticks).max(1);
                json!({
                    "noteId": id_for(n),
                    "startTicks": start,
                    "lengthTicks": length,
                    "pitch": n.pitch,
                    "velocity": n.velocity as i64,
                })
            })
            .collect()
    }

    /// Absolute end tick of the take (last note-off, or start if empty).
    pub fn end_ticks(&self) -> u64 {
        self.notes
            .iter()
            .map(|n| n.off_ticks)
            .max()
            .unwrap_or(self.start_ticks)
            .max(self.start_ticks.saturating_add(1))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stuck_note_gets_closed_with_positive_length() {
        let mut cap = MidiCapture::new("t1".into(), 0, None, 120, 1);
        cap.note_on(60, 100, 0);
        // Stop mid-note at tick 480.
        cap.close_all_at(480);
        assert_eq!(cap.completed().len(), 1);
        assert_eq!(cap.completed()[0].on_ticks, 0);
        assert_eq!(cap.completed()[0].off_ticks, 480);
        assert!(cap.open.is_empty());
    }

    #[test]
    fn punch_out_filters_and_closes() {
        let mut cap = MidiCapture::new("t1".into(), 0, Some(960), 120, 1);
        cap.note_on(60, 100, 0);
        cap.note_on(64, 90, 480);
        // Past punch — ignored.
        cap.note_on(67, 80, 960);
        cap.close_all_at(960);
        assert_eq!(cap.completed().len(), 2);
        assert!(cap.completed().iter().all(|n| n.off_ticks <= 960));
        assert!(!cap.completed().iter().any(|n| n.pitch == 67));
    }

    #[test]
    fn rhythm_ticks_survive() {
        let mut cap = MidiCapture::new("t1".into(), 0, None, 120, 1);
        // Quarter notes at 0, 960, 1920.
        for (i, pitch) in [60u8, 62, 64].iter().enumerate() {
            let on = (i as u64) * 960;
            cap.note_on(*pitch, 100, on);
            cap.note_off(*pitch, on + 480);
        }
        let specs = cap.to_note_specs(0, |n| format!("n_{}", n.pitch));
        assert_eq!(specs.len(), 3);
        assert_eq!(specs[0]["startTicks"], 0);
        assert_eq!(specs[1]["startTicks"], 960);
        assert_eq!(specs[2]["startTicks"], 1920);
        assert_eq!(specs[0]["lengthTicks"], 480);
    }

    #[test]
    fn zero_length_is_never_emitted() {
        let mut cap = MidiCapture::new("t1".into(), 0, None, 120, 1);
        cap.note_on(60, 100, 100);
        cap.note_off(60, 100); // same tick
        assert_eq!(cap.completed()[0].off_ticks, 101);
    }
}
