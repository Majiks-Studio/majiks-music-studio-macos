//! MIDI take capture: play notes through `feed_event` while recording, land
//! one batched `note.add`, prove timing and stuck-note hygiene, prove undo.
//!
//! No CoreMIDI hardware, no audio device. Clock is driven by
//! `midi_record_set_now_ticks` so the rhythm is exact.

use agent_surface::midi::event::MidiEvent;
use agent_surface::midi::feed_event;
use agent_surface::StudioHost;
use serde_json::{json, Value};
use timeline_core::Actor;

fn user() -> Actor {
    Actor::user("test")
}

const KC: &str = "usb midi interface";

fn note_on(n: u8, vel: u8) -> MidiEvent {
    MidiEvent::NoteOn {
        note: n,
        velocity: vel,
        channel: 0,
    }
}
fn note_off(n: u8) -> MidiEvent {
    MidiEvent::NoteOff {
        note: n,
        velocity: 0,
        channel: 0,
    }
}

fn host_with_armed_instrument() -> StudioHost {
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("midi-rec.mstudio");
    let mut host = StudioHost::create_at(&pkg, "MIDI record").unwrap();
    std::mem::forget(dir);
    host.submit(user(), "track.add", json!({"trackId": "t1", "name": "Keys"}))
        .unwrap();
    host.submit(
        user(),
        "device.add",
        json!({"trackId": "t1", "deviceId": "inst1", "kind": "synth"}),
    )
    .unwrap();
    host.submit(user(), "track.arm", json!({"trackId": "t1", "armed": true}))
        .unwrap();
    host
}

fn midi_notes(host: &StudioHost) -> Vec<Value> {
    let snap = host.snapshot(None);
    let tracks = snap["project"]["tracks"].as_array().unwrap();
    let clips = tracks[0]["clips"].as_array().unwrap();
    assert!(!clips.is_empty(), "expected a MIDI clip after landing");
    clips[0]["notes"].as_array().cloned().unwrap_or_default()
}

#[test]
fn midi_record_lands_one_batch_and_undoes_as_one_step() {
    std::env::remove_var("MAJIKS_TEST_AUDIBLE");
    let mut host = host_with_armed_instrument();

    let start = host
        .submit(
            user(),
            "record.start",
            json!({"trackId": "t1", "startTicks": 0}),
        )
        .unwrap();
    assert_eq!(start["kind"], "midi");
    assert_eq!(start["recording"], true);
    assert_eq!(
        host.snapshot(None)["transport"]["recording"],
        true,
        "transport.recording must reflect MIDI capture"
    );

    // Known rhythm: C4 quarters at 0, 960, 1920 — each held 480 ticks.
    for (i, pitch) in [60u8, 62, 64].iter().enumerate() {
        let on = (i as u64) * 960;
        host.midi_record_set_now_ticks(on);
        feed_event(&mut host, KC, &note_on(*pitch, 100));
        host.midi_record_set_now_ticks(on + 480);
        feed_event(&mut host, KC, &note_off(*pitch));
    }

    let stop = host.submit(user(), "record.stop", json!({})).unwrap();
    assert_eq!(stop["landed"], true);
    assert_eq!(stop["kind"], "midi");
    assert_eq!(stop["noteCount"], 3);

    let notes = midi_notes(&host);
    assert_eq!(notes.len(), 3);
    assert_eq!(notes[0]["startTicks"], 0);
    assert_eq!(notes[0]["lengthTicks"], 480);
    assert_eq!(notes[0]["pitch"], 60);
    assert_eq!(notes[1]["startTicks"], 960);
    assert_eq!(notes[1]["pitch"], 62);
    assert_eq!(notes[2]["startTicks"], 1920);
    assert_eq!(notes[2]["pitch"], 64);
    // Velocities are integers on the wire (Num shape).
    assert!(notes[0]["velocity"].as_i64().is_some());

    // Journal: one txn with note.add (and placeMidi). Not three note.adds.
    let journal = host.journal_page(None, 500);
    let entries = journal["entries"].as_array().unwrap();
    let note_adds: Vec<_> = entries
        .iter()
        .filter(|e| e["name"] == "note.add")
        .collect();
    assert_eq!(
        note_adds.len(),
        1,
        "one take must be one note.add, got {note_adds:?}"
    );
    assert_eq!(
        note_adds[0]["params"]["notes"].as_array().unwrap().len(),
        3
    );

    // One undo restores pre-state (empty clips).
    assert!(host.undo(user()).unwrap());
    let tracks = host.snapshot(None)["project"]["tracks"][0]["clips"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    assert!(
        tracks.is_empty(),
        "undo of the record txn must remove the MIDI clip"
    );
}

#[test]
fn midi_record_closes_stuck_notes_on_stop() {
    std::env::remove_var("MAJIKS_TEST_AUDIBLE");
    let mut host = host_with_armed_instrument();
    host.submit(
        user(),
        "record.start",
        json!({"trackId": "t1", "startTicks": 0}),
    )
    .unwrap();

    host.midi_record_set_now_ticks(100);
    feed_event(&mut host, KC, &note_on(60, 90));
    // No note-off — stop mid-hold.
    host.midi_record_set_now_ticks(700);
    let stop = host.submit(user(), "record.stop", json!({})).unwrap();
    assert_eq!(stop["landed"], true);

    let notes = midi_notes(&host);
    assert_eq!(notes.len(), 1);
    assert_eq!(notes[0]["pitch"], 60);
    assert_eq!(notes[0]["startTicks"], 100);
    // Closed at stop clock (700); length > 0.
    assert_eq!(notes[0]["lengthTicks"], 600);
}

#[test]
fn midi_record_honors_punch_out() {
    std::env::remove_var("MAJIKS_TEST_AUDIBLE");
    let mut host = host_with_armed_instrument();
    host.submit(
        user(),
        "record.start",
        json!({"trackId": "t1", "startTicks": 0, "punchOutTicks": 960}),
    )
    .unwrap();

    host.midi_record_set_now_ticks(0);
    feed_event(&mut host, KC, &note_on(60, 100));
    host.midi_record_set_now_ticks(480);
    feed_event(&mut host, KC, &note_off(60));

    // After punch-out: ignored.
    host.midi_record_set_now_ticks(960);
    feed_event(&mut host, KC, &note_on(64, 100));
    host.midi_record_set_now_ticks(1200);
    feed_event(&mut host, KC, &note_off(64));

    // Open note spanning punch: closed at punch.
    host.midi_record_set_now_ticks(200);
    // Re-open capture context already closed the first; for a held note past punch:
    // restart is messy — instead hold from 200 without off before stop.
    // (Already closed 60 at 480.) Start a held note before punch.
    host.midi_record_set_now_ticks(700);
    feed_event(&mut host, KC, &note_on(67, 80));
    // stop closes at punch 960
    let stop = host.submit(user(), "record.stop", json!({})).unwrap();
    assert_eq!(stop["landed"], true);

    let notes = midi_notes(&host);
    let pitches: Vec<u64> = notes
        .iter()
        .map(|n| n["pitch"].as_u64().unwrap())
        .collect();
    assert!(pitches.contains(&60));
    assert!(!pitches.contains(&64), "note starting at punch-out must be ignored");
    assert!(pitches.contains(&67));
    let held = notes.iter().find(|n| n["pitch"] == 67).unwrap();
    assert_eq!(
        held["startTicks"].as_u64().unwrap() + held["lengthTicks"].as_u64().unwrap(),
        960,
        "held note must close at punch-out"
    );
}

#[test]
fn midi_record_cancel_discards() {
    std::env::remove_var("MAJIKS_TEST_AUDIBLE");
    let mut host = host_with_armed_instrument();
    host.submit(
        user(),
        "record.start",
        json!({"trackId": "t1", "startTicks": 0}),
    )
    .unwrap();
    host.midi_record_set_now_ticks(0);
    feed_event(&mut host, KC, &note_on(60, 100));
    host.midi_record_set_now_ticks(480);
    feed_event(&mut host, KC, &note_off(60));
    let cancel = host.submit(user(), "record.cancel", json!({})).unwrap();
    assert_eq!(cancel["cancelled"], true);
    let clips = host.snapshot(None)["project"]["tracks"][0]["clips"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    assert!(clips.is_empty());
}

#[test]
fn midi_record_readable_from_saved_package() {
    std::env::remove_var("MAJIKS_TEST_AUDIBLE");
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("midi-save.mstudio");
    let mut host = StudioHost::create_at(&pkg, "MIDI save").unwrap();
    host.submit(user(), "track.add", json!({"trackId": "t1", "name": "Keys"}))
        .unwrap();
    host.submit(
        user(),
        "device.add",
        json!({"trackId": "t1", "deviceId": "inst1", "kind": "synth"}),
    )
    .unwrap();
    host.submit(user(), "track.arm", json!({"trackId": "t1", "armed": true}))
        .unwrap();
    host.submit(
        user(),
        "record.start",
        json!({"trackId": "t1", "startTicks": 0}),
    )
    .unwrap();
    host.midi_record_set_now_ticks(0);
    feed_event(&mut host, KC, &note_on(60, 100));
    host.midi_record_set_now_ticks(480);
    feed_event(&mut host, KC, &note_off(60));
    host.submit(user(), "record.stop", json!({})).unwrap();
    host.submit(user(), "project.save", json!({})).unwrap();

    // Re-open and assert notes are in the project model.
    let host2 = StudioHost::open_package(&pkg).unwrap();
    let notes = midi_notes(&host2);
    assert_eq!(notes.len(), 1);
    assert_eq!(notes[0]["pitch"], 60);
    assert_eq!(notes[0]["startTicks"], 0);
    assert_eq!(notes[0]["lengthTicks"], 480);
    let _ = host2.seq();
}
