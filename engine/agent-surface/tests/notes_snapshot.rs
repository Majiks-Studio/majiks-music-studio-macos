//! E1: what the piano roll and the arrangement grid actually READ.
//!
//! Every assertion goes through the real `StudioHost` snapshot — the same JSON
//! the FFI and MCP read tools return. A note that exists in the model but is
//! unreachable from the snapshot is a note the UI cannot draw, which is the
//! same class of bug as `phaseAnchorTicks` existing in the model since E0 while
//! the arrangement canvas drew bar lines from naive BPM math.

use agent_surface::StudioHost;
use serde_json::{json, Value};
use timeline_core::Actor;

fn user() -> Actor {
    Actor::user("aaron")
}

fn host_with_notes() -> StudioHost {
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("Notes.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Notes").unwrap();
    std::mem::forget(tmp);
    host.submit(user(), "track.add", json!({"trackId": "t1", "name": "Keys"}))
        .unwrap();
    host.submit(
        user(),
        "clip.placeMidi",
        json!({"clipId": "cm1", "trackId": "t1", "startTicks": 0, "lengthTicks": 3840}),
    )
    .unwrap();
    host.submit(
        user(),
        "note.add",
        json!({"clipId": "cm1", "notes": [
            {"noteId": "n_hi",  "startTicks": 480, "lengthTicks": 240, "pitch": 72, "velocity": 100},
            {"noteId": "n_low", "startTicks": 0,   "lengthTicks": 480, "pitch": 48, "velocity": 90}
        ]}),
    )
    .unwrap();
    host
}

fn clip_json(snap: &Value) -> Value {
    snap["project"]["tracks"][0]["clips"][0].clone()
}

#[test]
fn the_snapshot_carries_notes_the_piano_roll_can_draw() {
    let host = host_with_notes();
    let snap = host.snapshot(None);
    let clip = clip_json(&snap);

    assert_eq!(clip["kind"], json!("midi"), "the §1 clip discriminator");
    let notes = clip["notes"].as_array().expect("notes array on the snapshot");
    assert_eq!(notes.len(), 2);

    // Sorted (start_ticks, pitch, id) — the model's one total order, so two
    // clients render the same roll.
    assert_eq!(
        notes.iter().map(|n| n["id"].as_str().unwrap()).collect::<Vec<_>>(),
        ["n_low", "n_hi"]
    );

    // The exact field names the UI decodes, with real values.
    let low = &notes[0];
    assert_eq!(low["startTicks"], json!(0));
    assert_eq!(low["lengthTicks"], json!(480));
    assert_eq!(low["pitch"], json!(48));
    assert_eq!(low["velocity"], json!(90));
    // Integer on the wire: `90`, never `90.0`.
    assert_eq!(serde_json::to_string(&low["velocity"]).unwrap(), "90");
    assert!(
        low["lengthTicks"].as_u64().unwrap() > 0,
        "a zero-length note is never stored"
    );
    for n in notes {
        let p = n["pitch"].as_u64().unwrap();
        assert!(p <= 127, "pitch {p} out of MIDI range");
    }
}

#[test]
fn an_audio_clip_snapshot_gains_no_note_keys() {
    // The additive half: E1 must be invisible to an audio clip.
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("Audio.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Audio").unwrap();
    std::mem::forget(tmp);
    host.submit(user(), "track.add", json!({"trackId": "t1", "name": "Gtr"}))
        .unwrap();
    host.submit(
        user(),
        "clip.place",
        json!({"clipId": "c1", "trackId": "t1", "assetHash": "a".repeat(64),
               "startTicks": 0, "lengthTicks": 1920}),
    )
    .unwrap();
    let clip = clip_json(&host.snapshot(None));
    assert!(clip.get("kind").is_none(), "audio clip gained `kind`: {clip}");
    assert!(clip.get("notes").is_none(), "audio clip gained `notes`: {clip}");
}

#[test]
fn the_snapshot_exposes_the_bar_grid_inputs() {
    // The engine HAS had `phaseAnchorTicks` since E0 (`project.setPhaseAnchor`)
    // and a segmented tempo map since P0-B — neither was reachable from the
    // snapshot, so no client could draw a correct bar line.
    let mut host = host_with_notes();
    let snap = host.snapshot(None);
    let p = &snap["project"];
    assert_eq!(p["phaseAnchorTicks"], json!(0), "default anchor");
    assert_eq!(p["ppq"], json!(960));
    assert_eq!(p["timeSignature"]["numerator"], json!(4));

    let tm = p["tempoMap"].as_array().expect("tempoMap must be a LIST");
    assert_eq!(tm.len(), 1, "v1 holds exactly one segment; the SHAPE is a list");
    assert_eq!(tm[0]["startTicks"], json!(0));
    assert_eq!(tm[0]["bpm"], json!(120.0));
    // The exact rational the engine actually computes positions with. A float
    // BPM is display only — that is the whole reason tick math is rational.
    assert_eq!(tm[0]["bpmNum"], json!(120));
    assert_eq!(tm[0]["bpmDen"], json!(1));

    // And it TRACKS: set a non-bar-aligned anchor and a fractional tempo and
    // both must move. A constant would pass the assertions above.
    host.submit(user(), "project.setPhaseAnchor", json!({"anchorTicks": 1234}))
        .unwrap();
    host.submit(user(), "project.setTempo", json!({"bpm": 92.5}))
        .unwrap();
    let p = host.snapshot(None)["project"].clone();
    assert_eq!(p["phaseAnchorTicks"], json!(1234));
    assert_eq!(p["tempoMap"][0]["bpm"], json!(92.5));
    assert_eq!(
        (p["tempoMap"][0]["bpmNum"].as_u64().unwrap(),
         p["tempoMap"][0]["bpmDen"].as_u64().unwrap()),
        (185, 2),
        "92.5 BPM is the exact rational 185/2, not a float approximation"
    );
}

#[test]
fn the_snapshot_reports_undo_and_redo_depth() {
    let mut host = host_with_notes();
    let before = host.snapshot(None)["project"]["undoDepth"].as_u64().unwrap();
    assert!(before > 0, "three journaled edits happened");
    assert_eq!(host.snapshot(None)["project"]["redoDepth"], json!(0));

    host.undo(user()).expect("undo");
    let snap = host.snapshot(None);
    assert_eq!(snap["project"]["undoDepth"], json!(before - 1));
    assert_eq!(snap["project"]["redoDepth"], json!(1));
}

#[test]
fn a_batched_chord_drag_is_one_journal_entry_and_one_undo() {
    // The reason the note commands are batch-shaped at all: dragging a chord
    // must be ONE undo step, not one per note.
    let mut host = host_with_notes();
    let seq_before = host.snapshot(None)["seq"].as_u64().unwrap();
    let depth_before = host.snapshot(None)["project"]["undoDepth"]
        .as_u64()
        .unwrap();

    host.submit(
        user(),
        "note.move",
        json!({"clipId": "cm1", "noteIds": ["n_low", "n_hi"],
               "deltaTicks": 240, "deltaPitch": 5}),
    )
    .unwrap();

    let snap = host.snapshot(None);
    assert_eq!(
        snap["seq"].as_u64().unwrap(),
        seq_before + 1,
        "a two-note drag is ONE journal entry"
    );
    assert_eq!(
        snap["project"]["undoDepth"].as_u64().unwrap(),
        depth_before + 1,
        "and ONE undo step"
    );

    // Relative voicing is preserved: both notes moved by the same delta.
    let notes = clip_json(&snap)["notes"].clone();
    let by_id = |id: &str| -> Value {
        notes
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["id"] == json!(id))
            .unwrap()
            .clone()
    };
    assert_eq!(by_id("n_low")["startTicks"], json!(240));
    assert_eq!(by_id("n_low")["pitch"], json!(53));
    assert_eq!(by_id("n_hi")["startTicks"], json!(720));
    assert_eq!(by_id("n_hi")["pitch"], json!(77));
    assert_eq!(
        by_id("n_hi")["pitch"].as_i64().unwrap() - by_id("n_low")["pitch"].as_i64().unwrap(),
        24,
        "the interval between the two notes is unchanged"
    );

    // One undo puts the whole chord back exactly.
    host.undo(user()).expect("undo");
    let notes = clip_json(&host.snapshot(None))["notes"].clone();
    let low = notes
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["id"] == json!("n_low"))
        .unwrap();
    assert_eq!(low["startTicks"], json!(0));
    assert_eq!(low["pitch"], json!(48));
}

#[test]
fn the_mcp_tool_surface_carries_the_note_commands() {
    // A command with no tool is a command an agent cannot reach; the parity
    // gate proves the mapping exists, this proves the tools are actually
    // generated with usable schemas.
    let names: Vec<String> = agent_surface::tool_defs()
        .iter()
        .filter(|t| t.catalog_name.is_some())
        .map(|t| t.name.clone())
        .collect();
    for expected in [
        "studio_clip_place_midi",
        "studio_note_add",
        "studio_note_remove",
        "studio_note_move",
        "studio_note_resize",
        "studio_note_velocity_set",
        "studio_note_duplicate",
    ] {
        assert!(
            names.iter().any(|n| n == expected),
            "no MCP tool named {expected}; generated: {names:?}"
        );
    }
}
