//! E1 §2, the render half: notes baked into `RtSession`.
//!
//! These assert on FRAMES, not on struct shape. "The lane exists" proves
//! nothing — the question is whether a note lands at the frame the tempo map
//! says it should, and whether every note-on is matched by a note-off under
//! the conditions that break real DAWs: loop wrap, seek, clip end.
//!
//! Mutation checks are in `notes_bake_mutation.rs`.

use std::collections::HashMap;
use std::sync::Arc;

use render::compile::{compile_session_full, session_end_frame, DeclickPolicy};
use render::media::AudioBuf;
use render::notes::{FrameEvents, NoteCursor, NoteEvent, NoteLane};
use render::warp::WarpOverlay;
use render::automation::AutomationStore;
use timeline_core::cmd::{Cmd, NoteSpec};
use timeline_core::tempo::{Bpm, TempoMap, PPQ};
use timeline_core::{Num, Project, Track};

const RATE: u32 = 48_000;

fn project(bpm: u32) -> Project {
    let mut p = Project::new(RATE, TempoMap::single(Bpm::from_int(bpm).unwrap()));
    p.tracks.push(Track::new("t1", "Keys"));
    p
}

fn spec(id: &str, start: u64, len: u64, pitch: u8, vel: i64) -> NoteSpec {
    NoteSpec {
        note_id: id.into(),
        start_ticks: start,
        length_ticks: len,
        pitch,
        velocity: Num::int(vel),
    }
}

fn midi_clip(p: &mut Project, clip: &str, start_ticks: u64, len_ticks: u64, notes: Vec<NoteSpec>) {
    p.apply_cmd(&Cmd::ClipPlaceMidi {
        clip_id: clip.into(),
        track_id: "t1".into(),
        start_ticks,
        length_ticks: len_ticks,
    })
    .expect("place");
    if !notes.is_empty() {
        p.apply_cmd(&Cmd::NoteAdd {
            clip_id: clip.into(),
            notes,
        })
        .expect("note.add");
    }
}

fn bake(p: &Project) -> NoteLane {
    let sources: HashMap<String, Arc<AudioBuf>> = HashMap::new();
    let session = compile_session_full(
        p,
        &sources,
        &WarpOverlay::new(),
        &AutomationStore::new(),
        64,
        DeclickPolicy::None,
    )
    .expect("compile");
    session.tracks[0].notes.clone()
}

/// Frames per quarter note at `bpm`.
fn quarter(bpm: u32) -> u64 {
    u64::from(RATE) * 60 / u64::from(bpm)
}

// ---------------------------------------------------------------------------
// Notes land where the tempo map says
// ---------------------------------------------------------------------------

#[test]
fn a_note_lands_at_the_frame_the_tempo_map_computes() {
    // 120 BPM: a quarter note is 24000 frames. Note at beat 2 (960 ticks)
    // lasting one beat.
    let mut p = project(120);
    midi_clip(&mut p, "cm1", 0, 3840, vec![spec("n1", PPQ, PPQ, 60, 100)]);
    let lane = bake(&p);
    let q = quarter(120);
    assert_eq!(lane.events().len(), 2, "one on, one off");
    assert_eq!(lane.events()[0].frame, q, "attack at beat 2");
    assert!(lane.events()[0].on);
    assert_eq!(lane.events()[1].frame, 2 * q, "release at beat 3");
    assert!(!lane.events()[1].on);
    assert!(
        (lane.events()[0].velocity - 100.0 / 127.0).abs() < 1e-6,
        "velocity normalized ONCE, at compile time"
    );
}

#[test]
fn a_clips_timeline_position_offsets_its_notes() {
    // The same note in a clip that starts at bar 2 must land a bar later.
    let mut p = project(120);
    midi_clip(&mut p, "cm1", 4 * PPQ, 3840, vec![spec("n1", 0, PPQ, 60, 100)]);
    let lane = bake(&p);
    assert_eq!(lane.events()[0].frame, 4 * quarter(120));
}

#[test]
fn tempo_is_honoured_not_assumed() {
    // 92 BPM is as first-class as 120 (rational tick math). If baking used a
    // hardcoded 120 this fails.
    let mut p = project(92);
    midi_clip(&mut p, "cm1", 0, 3840, vec![spec("n1", PPQ, PPQ, 60, 100)]);
    let lane = bake(&p);
    assert_eq!(lane.events()[0].frame, quarter(92));
    assert_ne!(lane.events()[0].frame, quarter(120));
}

#[test]
fn baking_is_deterministic_across_note_insert_orders() {
    // Two projects with the same notes added in opposite orders must compile
    // to byte-identical event slices — otherwise a bounce is not reproducible.
    let build = |reversed: bool| {
        let mut notes = vec![
            spec("a", 0, 480, 60, 100),
            spec("b", 0, 480, 64, 90),
            spec("c", 480, 480, 67, 80),
            spec("d", 480, 480, 60, 70),
        ];
        if reversed {
            notes.reverse();
        }
        let mut p = project(120);
        midi_clip(&mut p, "cm1", 0, 3840, notes);
        bake(&p)
    };
    let a = build(false);
    let b = build(true);
    assert_eq!(a.events(), b.events());
}

// ---------------------------------------------------------------------------
// Stuck notes: the worst failure mode
// ---------------------------------------------------------------------------

/// Every note-on delivered must be matched by exactly one note-off with the
/// same `voice_hint`, and nothing may be left sounding.
fn assert_no_stuck_notes(delivered: &[NoteEvent], cursor: &NoteCursor, what: &str) {
    let mut open: HashMap<u32, i32> = HashMap::new();
    for e in delivered {
        let c = open.entry(e.voice_hint).or_insert(0);
        if e.on {
            *c += 1;
            assert!(*c <= 1, "{what}: voice {} attacked twice with no release", e.voice_hint);
        } else {
            *c -= 1;
            assert!(*c >= 0, "{what}: voice {} released with no attack", e.voice_hint);
        }
    }
    for (hint, c) in &open {
        assert_eq!(*c, 0, "{what}: voice {hint} is STUCK — attacked, never released");
    }
    assert_eq!(cursor.sounding_count(), 0, "{what}: cursor still holds notes");
}

fn play(lane: &NoteLane, frames: impl Iterator<Item = u64>) -> (Vec<NoteEvent>, NoteCursor) {
    let mut cursor = NoteCursor::new();
    let mut out = FrameEvents::new();
    let mut all = Vec::new();
    for f in frames {
        cursor.advance(lane, f, &mut out);
        all.extend_from_slice(out.as_slice());
    }
    (all, cursor)
}

#[test]
fn a_note_overhanging_the_clip_end_is_released_at_the_clip_end() {
    // The note asks for 4 beats; the clip is 2 beats long. The release MUST
    // land at the clip end, not at the note's authored end and not never.
    let mut p = project(120);
    midi_clip(&mut p, "cm1", 0, 2 * PPQ, vec![spec("n1", 0, 4 * PPQ, 60, 100)]);
    let lane = bake(&p);
    let q = quarter(120);
    assert_eq!(lane.events().len(), 2);
    assert_eq!(
        lane.events()[1].frame,
        2 * q,
        "release cropped to the clip end"
    );
    let (delivered, cursor) = play(&lane, 0..(6 * q));
    assert_no_stuck_notes(&delivered, &cursor, "clip end");
}

#[test]
fn looping_a_region_matches_every_note_on_with_a_note_off() {
    // The gate from the seam spec. A 2-bar region looped four times, with a
    // note that SUSTAINS PAST the loop end — the case where a naive
    // implementation hangs a voice forever.
    let mut p = project(120);
    let bar = 4 * PPQ;
    midi_clip(
        &mut p,
        "cm1",
        0,
        4 * bar,
        vec![
            spec("short", 0, PPQ, 60, 100),
            // starts inside the loop region, ends well past it
            spec("sustain", 3 * PPQ, 6 * PPQ, 64, 100),
        ],
    );
    let lane = bake(&p);

    let loop_start = 0u64;
    let loop_end = 2 * bar * quarter(120) / PPQ; // 2 bars in frames
    let mut frames = Vec::new();
    for _ in 0..4 {
        frames.extend(loop_start..loop_end);
    }
    let (mut delivered, mut cursor) = play(&lane, frames.into_iter());

    // Three wraps happened, so three sustains were released by the fold. The
    // FOURTH pass ends with the transport simply stopping mid-note — that is
    // not a wrap, and the only correct release is the explicit stop-time one.
    assert_eq!(
        cursor.sounding_count(),
        1,
        "the last pass is still sustaining when the transport stops"
    );
    let mut out = FrameEvents::new();
    cursor.release_all(loop_end, &mut out);
    delivered.extend_from_slice(out.as_slice());

    assert_no_stuck_notes(&delivered, &cursor, "loop wrap");

    // And it actually PLAYED — a test that passes because nothing happened is
    // worthless.
    let ons = delivered.iter().filter(|e| e.on).count();
    assert_eq!(ons, 8, "2 notes x 4 passes");
    let offs = delivered.iter().filter(|e| !e.on).count();
    assert_eq!(offs, 8, "every one of them released");
    // 3 of those releases are synthetic (the folds); the short note's 4 are
    // authored. Prove the wrap releases really happened AT the fold frame.
    assert_eq!(
        delivered
            .iter()
            .filter(|e| !e.on && e.frame == 0 && e.pitch == 64)
            .count(),
        3,
        "each of the three folds released the sustaining note at the fold frame"
    );
}

#[test]
fn a_seek_backwards_mid_note_releases_before_re_anchoring() {
    let mut p = project(120);
    midi_clip(&mut p, "cm1", 0, 16 * PPQ, vec![spec("n1", 0, 8 * PPQ, 60, 100)]);
    let lane = bake(&p);
    let q = quarter(120);

    let mut cursor = NoteCursor::new();
    let mut out = FrameEvents::new();
    let mut all = Vec::new();
    for f in 0..(2 * q) {
        cursor.advance(&lane, f, &mut out);
        all.extend_from_slice(out.as_slice());
    }
    assert_eq!(cursor.sounding_count(), 1, "the note is held mid-flight");
    // Jump backwards.
    cursor.advance(&lane, 10, &mut out);
    all.extend_from_slice(out.as_slice());
    assert_eq!(cursor.sounding_count(), 0, "the seek released it");
    // Play the rest out.
    for f in 11..(9 * q) {
        cursor.advance(&lane, f, &mut out);
        all.extend_from_slice(out.as_slice());
    }
    assert_no_stuck_notes(&all, &cursor, "backward seek");
}

#[test]
fn same_pitch_overlap_never_leaves_two_voices_live() {
    // The model permits overlapping same-pitch notes (rejecting them would
    // make the piano roll refuse a legal edit); baking truncates the earlier
    // one at the later attack.
    let mut p = project(120);
    midi_clip(
        &mut p,
        "cm1",
        0,
        8 * PPQ,
        vec![
            spec("first", 0, 4 * PPQ, 60, 100),
            spec("second", 2 * PPQ, 4 * PPQ, 60, 100),
        ],
    );
    let lane = bake(&p);
    let q = quarter(120);
    assert_eq!(
        lane.events()[1].frame,
        2 * q,
        "the first note's release moved to the second's attack"
    );
    let (delivered, cursor) = play(&lane, 0..(10 * q));
    assert_no_stuck_notes(&delivered, &cursor, "same-pitch overlap");
    assert_eq!(delivered.iter().filter(|e| e.on).count(), 2);
}

#[test]
fn a_muted_note_clip_produces_no_events_at_all() {
    let mut p = project(120);
    midi_clip(&mut p, "cm1", 0, 3840, vec![spec("n1", 0, PPQ, 60, 100)]);
    assert!(!bake(&p).is_empty());
    p.apply_cmd(&Cmd::ClipMute {
        clip_id: "cm1".into(),
        muted: true,
    })
    .unwrap();
    assert!(
        bake(&p).is_empty(),
        "a muted clip must not emit a single event — half-muting is worse than not muting"
    );
}

// ---------------------------------------------------------------------------
// Compile-level integration
// ---------------------------------------------------------------------------

#[test]
fn a_note_clip_compiles_without_an_audio_source() {
    // The regression this guards: `compile` used to hard-fail on any clip
    // whose source_id was not in the source map. A note clip has no source.
    let mut p = project(120);
    midi_clip(&mut p, "cm1", 0, 3840, vec![spec("n1", 0, PPQ, 60, 100)]);
    let sources: HashMap<String, Arc<AudioBuf>> = HashMap::new();
    let session = compile_session_full(
        &p,
        &sources,
        &WarpOverlay::new(),
        &AutomationStore::new(),
        64,
        DeclickPolicy::None,
    )
    .expect("a note clip must not need a loaded audio source");
    assert_eq!(session.tracks[0].clips.len(), 0, "no RtClip for a note clip");
    assert_eq!(session.tracks[0].notes.events().len(), 2);
}

#[test]
fn a_midi_only_session_has_a_nonzero_bounce_length() {
    // Otherwise a MIDI-only project bounces to zero frames of silence.
    let mut p = project(120);
    midi_clip(&mut p, "cm1", 0, 4 * PPQ, vec![spec("n1", 0, 2 * PPQ, 60, 100)]);
    let sources: HashMap<String, Arc<AudioBuf>> = HashMap::new();
    let session = compile_session_full(
        &p,
        &sources,
        &WarpOverlay::new(),
        &AutomationStore::new(),
        64,
        DeclickPolicy::None,
    )
    .unwrap();
    assert_eq!(session_end_frame(&session), 2 * quarter(120));
}

// ---------------------------------------------------------------------------
// Block-size independence — the note-path half of the bounce-parity guarantee
// ---------------------------------------------------------------------------

#[test]
fn the_note_stream_is_identical_at_every_block_size() {
    // Bounce parity rests on ONE rule (`dsp/mod.rs:1-5`, `rt.rs:19-22`): all
    // signal state advances per FRAME, and block boundaries only read atomics.
    // For notes that means the delivered event stream must be a function of
    // the frame alone. This is the note-layer analogue of the 128/417/480/512
    // null test — and it is what makes an instrument's bounce reproducible,
    // because the instrument is driven entirely by this stream.
    //
    // 417 is deliberately not a power of two and not a divisor of anything, so
    // block boundaries land inside notes rather than on their edges.
    let mut p = project(92); // a tempo whose quarter is not a round frame count
    let bar = 4 * PPQ;
    midi_clip(
        &mut p,
        "cm1",
        0,
        4 * bar,
        vec![
            spec("a", 0, 480, 60, 100),
            spec("b", 120, 3000, 64, 90),
            spec("c", 480, 480, 60, 80), // same pitch as `a`, overlapping
            spec("d", 3719, 61, 72, 127), // deliberately odd tick numbers
        ],
    );
    let lane = bake(&p);
    let total = lane.end_frame() + 5_000;

    let reference = {
        let mut c = NoteCursor::new();
        let mut out = FrameEvents::new();
        let mut all = Vec::new();
        for f in 0..total {
            c.advance(&lane, f, &mut out);
            all.extend_from_slice(out.as_slice());
        }
        all
    };
    assert!(
        reference.iter().filter(|e| e.on).count() >= 4,
        "the reference run must actually contain notes, or this proves nothing"
    );

    for block in [128u64, 417, 480, 512] {
        let mut c = NoteCursor::new();
        let mut out = FrameEvents::new();
        let mut all = Vec::new();
        let mut f = 0u64;
        while f < total {
            let n = block.min(total - f);
            for i in 0..n {
                c.advance(&lane, f + i, &mut out);
                all.extend_from_slice(out.as_slice());
            }
            f += n;
        }
        assert_eq!(
            all, reference,
            "the note stream diverged at block size {block}"
        );
    }
}

#[test]
fn note_events_are_ordered_offs_before_ons_at_the_same_frame() {
    // E2's schedule depends on this: a same-hint retrigger must release before
    // it restarts, or the release kills the new voice.
    let mut p = project(120);
    midi_clip(
        &mut p,
        "cm1",
        0,
        8 * PPQ,
        vec![
            spec("a", 0, PPQ, 60, 100),
            spec("b", PPQ, PPQ, 60, 100), // starts exactly where `a` ends
        ],
    );
    let lane = bake(&p);
    let q = quarter(120);
    let at_q: Vec<bool> = lane
        .events()
        .iter()
        .filter(|e| e.frame == q)
        .map(|e| e.on)
        .collect();
    assert_eq!(at_q, [false, true], "release must precede the attack");

    let (delivered, cursor) = play(&lane, 0..(4 * q));
    assert_no_stuck_notes(&delivered, &cursor, "butt-joined retrigger");
}
