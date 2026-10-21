//! WHERE a kept performance lands, and how to throw one away.
//!
//! ## The bug, exactly as it happened
//!
//! A person played a two-handed 56-note passage on a MIDI keyboard and pressed
//! Keep. The capture worked perfectly — `txn.begin` → `clip.placeMidi` →
//! `note.add` (56 notes) → `txn.commit`, one clean undo step, every note at the
//! rhythm it was played. The clip landed at `startTicks` **4,128,895**: bar
//! 1,076 at 960 PPQ in 4/4, 1,075 bars past everything else in the project,
//! off screen, with nothing on screen saying so.
//!
//! The cause was not the capture. It was the ANCHOR: the transport had been
//! left rolling for about 36 minutes, and both branches of
//! `performance_now_ticks` are unbounded monotonic clocks (the live play head,
//! or a wall clock from the buffer's origin). Neither is wrong on its own;
//! nothing related either to the music.
//!
//! ## And the other half: there was no way to throw a take away
//!
//! Keep shipped without a counterpart. The buffer is a rolling 128 beats, so a
//! bad pass and a good pass sat in the same count, and the only exits were to
//! keep everything and press Cmd-Z, or to stop playing and wait a minute for it
//! to roll off. "How do I not keep notes?" had no answer.
//!
//! Everything here drives the REAL path: the MIDI pump, `preview_note`'s
//! retro-capture buffer, and the `studio_performance_*` tools — never the
//! buffer directly.

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, Once};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use agent_surface::midi::event::MidiEvent;
use agent_surface::midi::{pump, start_pump};
use agent_surface::{dispatch_tool, StudioHost};
use timeline_core::{tempo::PPQ, Actor};

/// 4/4 at 960 PPQ.
const BAR: u64 = PPQ as u64 * 4;

/// The tick the real clip landed at. Kept as the literal from the incident so
/// this test is unmistakably about that bug.
const BAR_1076: u64 = 4_128_895;

static FILTER: Once = Once::new();
const NO_HARDWARE: &str = "__majiks_no_such_port__";
const UNMAPPED_PORT: &str = "unmapped test port";

fn user() -> Actor {
    Actor::user("placement")
}

fn empty_project_with_pump() -> Arc<Mutex<StudioHost>> {
    FILTER.call_once(|| std::env::set_var("MAJIKS_MIDI_PORT_FILTER", NO_HARDWARE));
    let host = Arc::new(Mutex::new(StudioHost::in_memory()));
    start_pump(&host).expect("start pump");
    std::thread::sleep(Duration::from_millis(150));
    host
}

fn note_on(note: u8) -> MidiEvent {
    MidiEvent::NoteOn {
        note,
        velocity: 100,
        channel: 0,
    }
}
fn note_off(note: u8) -> MidiEvent {
    MidiEvent::NoteOff {
        note,
        velocity: 0,
        channel: 0,
    }
}

/// Inject one event and block until the pump has dispatched it.
fn play(host: &Arc<Mutex<StudioHost>>, event: MidiEvent) {
    let shared = host.lock().unwrap().midi_shared();
    let before = shared.dispatched_seq.load(Ordering::Relaxed);
    assert!(
        pump::inject(&shared, UNMAPPED_PORT, event),
        "the pump inlet refused the event; no pump is running"
    );
    let deadline = Instant::now() + Duration::from_secs(2);
    while shared.dispatched_seq.load(Ordering::Relaxed) == before {
        assert!(Instant::now() < deadline, "event never dispatched within 2 s");
        std::thread::yield_now();
    }
}

/// Pin the retro-capture clock for the NEXT event only.
fn at_tick(host: &Arc<Mutex<StudioHost>>, ticks: u64) {
    host.lock().unwrap().performance_set_now_ticks(ticks);
}

fn snap(host: &Arc<Mutex<StudioHost>>) -> Value {
    host.lock().unwrap().snapshot(None)
}

fn keep(host: &Arc<Mutex<StudioHost>>) -> Value {
    let mut h = host.lock().unwrap();
    dispatch_tool(&mut h, user(), "studio_performance_keep", json!({})).expect("keep")
}

fn discard(host: &Arc<Mutex<StudioHost>>) -> Value {
    let mut h = host.lock().unwrap();
    dispatch_tool(&mut h, user(), "studio_performance_discard", json!({})).expect("discard")
}

/// One `u64` field of a snapshot object, accepting either spelling and
/// PANICKING when neither is present.
///
/// ⚠️ Written this way because the obvious version is a decoy, and the decoy is
/// live in `play_a_note.rs::landed_notes` today: `Clip` derives serde with no
/// `rename_all`, so a clip's position is `start_ticks` on the wire, and
/// `clip["startTicks"].as_u64().unwrap_or(0)` therefore reads EVERY clip as
/// starting at bar 1. That helper has only ever been used on projects whose
/// clips really are at 0, so it has never been wrong — and it could not have
/// caught a clip landing at bar 1,076, which is the exact bug this file is
/// about. A silent `unwrap_or(0)` on a position is not a default, it is an
/// assertion that quietly cannot fail.
fn ticks(v: &Value, camel: &str, snake: &str) -> u64 {
    v.get(camel)
        .or_else(|| v.get(snake))
        .and_then(Value::as_u64)
        .unwrap_or_else(|| panic!("neither {camel} nor {snake} is present in {v}"))
}

/// Every note in the project as `(pitch, absoluteStartTicks, lengthTicks)`.
fn landed_notes(host: &Arc<Mutex<StudioHost>>) -> Vec<(u64, u64, u64)> {
    let s = snap(host);
    let mut out = Vec::new();
    for track in s["project"]["tracks"].as_array().into_iter().flatten() {
        for clip in track["clips"].as_array().into_iter().flatten() {
            let clip_start = ticks(clip, "startTicks", "start_ticks");
            for note in clip["notes"].as_array().into_iter().flatten() {
                out.push((
                    note["pitch"].as_u64().unwrap(),
                    clip_start + ticks(note, "startTicks", "start_ticks"),
                    ticks(note, "lengthTicks", "length_ticks"),
                ));
            }
        }
    }
    out.sort_unstable();
    out
}

/// Play a three-note figure whose FIRST note is at `origin`, with a fixed
/// internal rhythm. The rhythm is what must survive any relocation.
///
/// The play head is SEEKED to `origin` first, and that is not a convenience:
/// `performance_now_ticks` stamps the very first note of a fresh buffer from
/// the transport position (the deterministic override only applies to a buffer
/// that already exists), so seeking is how a test reproduces "the clock had run
/// a long way out before I played". It is also a real user path in its own
/// right — drag the play head to bar 1,076 and play.
fn play_a_figure(host: &Arc<Mutex<StudioHost>>, origin: u64) {
    host.lock()
        .unwrap()
        .submit(user(), "transport.seek", json!({"positionTicks": origin}))
        .expect("seek");
    for (i, pitch) in [60u8, 64, 67].iter().enumerate() {
        let on = origin + (i as u64) * PPQ as u64;
        at_tick(host, on);
        play(host, note_on(*pitch));
        at_tick(host, on + PPQ as u64 / 2);
        play(host, note_off(*pitch));
    }
}

/// Give the project some existing music to be "past". A MIDI clip is enough:
/// `content_end_ticks` is a max over every clip's end.
fn seed_content(host: &Arc<Mutex<StudioHost>>, bars: u64) {
    let mut h = host.lock().unwrap();
    h.submit(user(), "track.add", json!({"trackId": "bed", "name": "Bed"}))
        .unwrap();
    h.submit(
        user(),
        "clip.placeMidi",
        json!({"clipId": "bedclip", "trackId": "bed", "startTicks": 0,
               "lengthTicks": bars * BAR}),
    )
    .unwrap();
}

// ---------------------------------------------------------------------------
// 1. The bar-1076 bug
// ---------------------------------------------------------------------------

/// THE regression test. A runaway clock must not put a person's playing 1,075
/// bars off screen.
#[test]
fn a_take_played_far_past_the_music_does_not_land_a_thousand_bars_away() {
    let host = empty_project_with_pump();
    seed_content(&host, 8);

    play_a_figure(&host, BAR_1076);
    let out = keep(&host);

    assert_eq!(out["kept"], json!(true), "{out}");
    assert_eq!(out["noteCount"], json!(3), "{out}");
    let start = out["startTicks"].as_u64().unwrap();
    assert!(
        start < 12 * BAR,
        "the take landed at tick {start} (bar {}), which is exactly the bug: 4,128,895 was \
         bar 1,076 and nothing on screen said so",
        start / BAR + 1
    );
    assert_eq!(
        start,
        8 * BAR,
        "past everything the project contains, a take belongs at the next bar line after the \
         music — which is where a person adding a part actually wants it"
    );
    assert_eq!(
        out["snapped"],
        json!(true),
        "the move must be REPORTED. Silently relocating someone's work is the same class of \
         bug as putting it out of sight: {out}"
    );
    assert_eq!(out["playedAtTicks"], json!(BAR_1076), "{out}");

    // And the NOTES moved with the clip. Moving the clip alone would have left
    // the notes 1,075 bars out inside a clip at bar 9 — the same bug wearing a
    // different hat, and invisible to any assertion on `startTicks`.
    assert_eq!(
        landed_notes(&host),
        vec![
            (60, 8 * BAR, PPQ as u64 / 2),
            (64, 8 * BAR + PPQ as u64, PPQ as u64 / 2),
            (67, 8 * BAR + 2 * PPQ as u64, PPQ as u64 / 2),
        ],
        "the clip moved but the notes inside it did not"
    );
}

/// An empty project is the commonest case of all — a person who just opened
/// the app, played something, and pressed Keep. Bar 1.
#[test]
fn the_first_thing_you_ever_play_lands_at_bar_one() {
    let host = empty_project_with_pump();
    play_a_figure(&host, BAR_1076);
    let out = keep(&host);

    assert_eq!(out["startTicks"], json!(0), "{out}");
    assert_eq!(
        landed_notes(&host),
        vec![
            (60, 0, PPQ as u64 / 2),
            (64, PPQ as u64, PPQ as u64 / 2),
            (67, 2 * PPQ as u64, PPQ as u64 / 2),
        ],
        "bar 1, at the rhythm it was played"
    );
}

/// The case the playhead anchor was DESIGNED for, and it is still right:
/// playing along to a rolling transport means the bar you were listening to.
/// A fix that snapped everything to the origin would have broken this.
#[test]
fn playing_along_inside_the_music_still_lands_where_it_was_played() {
    let host = empty_project_with_pump();
    seed_content(&host, 16);

    let origin = 3 * BAR;
    play_a_figure(&host, origin);
    let out = keep(&host);

    assert_eq!(
        out["startTicks"],
        json!(origin),
        "a take played over existing music must stay where it was played: {out}"
    );
    assert_eq!(out["snapped"], json!(false), "{out}");
}

/// One bar of grace, so an entry made just after the last clip ends is treated
/// as playing along rather than as a runaway.
#[test]
fn an_entry_just_after_the_last_clip_is_not_treated_as_a_runaway() {
    let host = empty_project_with_pump();
    seed_content(&host, 8);

    // Half a bar past the end of the music — a late entry, not a runaway.
    let origin = 8 * BAR + BAR / 2;
    play_a_figure(&host, origin);
    let out = keep(&host);

    assert_eq!(out["startTicks"], json!(origin), "{out}");
    assert_eq!(out["snapped"], json!(false), "{out}");
}

/// Relocating the clip must not touch the MUSIC. The passage's internal rhythm
/// is the whole value of the take.
#[test]
fn the_rhythm_of_the_passage_survives_the_relocation() {
    let host = empty_project_with_pump();
    seed_content(&host, 8);
    play_a_figure(&host, BAR_1076);
    keep(&host);

    let notes = landed_notes(&host);
    assert_eq!(notes.len(), 3);
    let base = notes[0].1;
    assert_eq!(
        notes
            .iter()
            .map(|(p, s, l)| (*p, s - base, *l))
            .collect::<Vec<_>>(),
        vec![
            (60, 0, PPQ as u64 / 2),
            (64, PPQ as u64, PPQ as u64 / 2),
            (67, 2 * PPQ as u64, PPQ as u64 / 2),
        ],
        "the notes moved relative to each other, so the relocation damaged the performance"
    );
}

/// Keeping is still ONE undo step after the anchoring change — the anchor is
/// arithmetic before the transaction, not an extra command inside it.
#[test]
fn a_relocated_keep_is_still_one_undo_step() {
    let host = empty_project_with_pump();
    seed_content(&host, 8);
    play_a_figure(&host, BAR_1076);

    let before = snap(&host)["project"]["undoDepth"].as_u64().unwrap();
    keep(&host);
    let after = snap(&host)["project"]["undoDepth"].as_u64().unwrap();
    assert_eq!(after, before + 1, "a whole take is ONE undo step");

    assert!(host.lock().unwrap().undo(user()).unwrap());
    assert!(
        landed_notes(&host).is_empty(),
        "one undo must take the whole take back"
    );
}

// ---------------------------------------------------------------------------
// 2. Throwing a take away
// ---------------------------------------------------------------------------

#[test]
fn discarding_empties_the_buffer_and_puts_nothing_in_the_project() {
    let host = empty_project_with_pump();
    play_a_figure(&host, 0);
    assert_eq!(snap(&host)["performance"]["keepableNotes"], json!(3));

    let out = discard(&host);
    assert_eq!(out["discarded"], json!(true), "{out}");
    assert_eq!(out["noteCount"], json!(3), "{out}");

    assert_eq!(
        snap(&host)["performance"]["keepableNotes"],
        json!(0),
        "the buffer still holds the take, so the count a person is looking at did not move"
    );
    assert!(
        landed_notes(&host).is_empty(),
        "discard put notes in the project, which is the one thing it must never do"
    );
}

/// THE safety property, stated as a test: a discard cannot reach anything that
/// is already in the project, and therefore journals nothing and needs no undo.
#[test]
fn discarding_journals_nothing_and_cannot_reach_the_project() {
    let host = empty_project_with_pump();
    seed_content(&host, 4);
    // Keep one take, so there is real work in the project to be endangered.
    play_a_figure(&host, 0);
    keep(&host);
    let kept = landed_notes(&host);
    assert_eq!(kept.len(), 3, "the take to be protected");
    let depth = snap(&host)["project"]["undoDepth"].as_u64().unwrap();

    // Now play a second, worse pass and throw it away.
    play_a_figure(&host, 8 * BAR);
    discard(&host);

    assert_eq!(
        landed_notes(&host),
        kept,
        "discarding an unkept pass touched work that was already in the project"
    );
    assert_eq!(
        snap(&host)["project"]["undoDepth"].as_u64().unwrap(),
        depth,
        "discard pushed an undo step. It writes nothing, so there is nothing to undo — and a \
         phantom step would mean the NEXT Cmd-Z silently took back the user's last real edit \
         instead"
    );
}

#[test]
fn discarding_when_nothing_was_played_says_so_rather_than_claiming_success() {
    let host = empty_project_with_pump();
    let out = discard(&host);
    assert_eq!(out["discarded"], json!(false), "{out}");
    assert_eq!(out["noteCount"], json!(0), "{out}");
    assert!(
        out["reason"].as_str().unwrap_or("").contains("nothing"),
        "a person needs to be told why nothing happened: {out}"
    );
}

/// After a discard, the next thing played starts a FRESH performance rather
/// than resuming the thrown-away one.
#[test]
fn playing_again_after_a_discard_keeps_only_the_new_pass() {
    let host = empty_project_with_pump();
    play_a_figure(&host, 0);
    discard(&host);

    at_tick(&host, 4 * BAR);
    play(&host, note_on(72));
    at_tick(&host, 4 * BAR + PPQ as u64);
    play(&host, note_off(72));

    assert_eq!(snap(&host)["performance"]["keepableNotes"], json!(1));
    let out = keep(&host);
    assert_eq!(out["noteCount"], json!(1), "{out}");
    assert_eq!(
        landed_notes(&host).iter().map(|n| n.0).collect::<Vec<_>>(),
        vec![72],
        "the discarded pass came back from the dead"
    );
}

/// The discard tool is REACHABLE. A host method nothing dispatches is the
/// inert-control failure this codebase keeps finding; the tool registry and the
/// dispatcher are two separate lists and both have to name it.
#[test]
fn the_discard_tool_is_registered_and_dispatchable() {
    let defs = agent_surface::registry::tool_defs();
    let names: Vec<&str> = defs.iter().map(|t| t.name.as_str()).collect();
    assert!(
        names.contains(&"studio_performance_discard"),
        "the discard tool is not in the registry, so no agent can reach it"
    );
    // ...and the dispatcher actually routes it, rather than falling through to
    // "unknown session tool".
    let host = empty_project_with_pump();
    let out = discard(&host);
    assert!(out.get("discarded").is_some(), "dispatched to nothing: {out}");
}
