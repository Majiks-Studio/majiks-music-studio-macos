//! THE APP MAKES TRACKS NOBODY ASKED FOR, and it used to do it in silence.
//!
//! `play_a_note.rs` pins the first of these — a key pressed on a project with
//! no instrument creates a track, and the snapshot says so. Two more gestures
//! have exactly the same shape and were left unsaid: **Add a Layer** puts its
//! new part on a row of its own (`revise::dispatch_layer`), and a **stem
//! import** gives every file after the first a row of its own
//! (`import_stems_params`). Both journal `track.add`; neither said the word
//! "track" anywhere a user could see it.
//!
//! What is proven here is that the snapshot's `origin` is a VIEW OVER THE
//! JOURNAL and not a flag: it is read back from the `actor` on `track.add` and
//! the `reason` on the transaction around it, both of which were already being
//! written before this file existed. The half that matters most in every test
//! below is the NEGATIVE one — a track the user added by hand, in the same
//! project, after the same boot, must carry no origin at all. A message wired
//! to fire always is the same defect as no message, and it is the failure a
//! one-track fixture cannot see.

use std::path::PathBuf;

use agent_surface::StudioHost;
use serde_json::{json, Value};
use timeline_core::Actor;

const BAR_TICKS: u64 = 4 * 960;

fn user() -> Actor {
    Actor::user("test")
}

fn fixture(name: &str) -> PathBuf {
    // engine/fixtures/*.wav are generated (gitignored) — ensured here so this
    // binary never depends on run order or another lane's leftovers.
    static FIXTURES_READY: std::sync::Once = std::sync::Once::new();
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../fixtures");
    FIXTURES_READY.call_once(|| {
        render::fixtures::ensure(&dir).expect("ensure engine/fixtures");
    });
    dir.join(name)
}

/// Every track in the snapshot as `(name, origin)`, with `None` for a track
/// carrying no origin key at all.
///
/// Reads the SNAPSHOT rather than the journal on purpose: the snapshot is what
/// the app decodes, so a derivation that works but never reaches the wire is
/// still a silent app.
fn origins(host: &StudioHost) -> Vec<(String, Option<String>)> {
    host.snapshot(None)["project"]["tracks"]
        .as_array()
        .expect("snapshot has tracks")
        .iter()
        .map(|t| {
            (
                t["name"].as_str().unwrap_or_default().to_string(),
                t.get("origin")
                    .and_then(Value::as_str)
                    .map(str::to_string),
            )
        })
        .collect()
}

fn origin_of(host: &StudioHost, name: &str) -> Option<String> {
    origins(host)
        .into_iter()
        .find(|(n, _)| n == name)
        .unwrap_or_else(|| panic!("no track named {name} in {:?}", origins(host)))
        .1
}

// ---------------------------------------------------------------------------
// ADD A LAYER
// ---------------------------------------------------------------------------

/// The layer track is marked, and the marking survives the one thing that
/// distinguishes it from the played case: `studio_layer` runs under the
/// CALLER's actor. `user()` here is the very same actor that adds the hand-made
/// track below, so an actor-only reading would mark both or neither, and this
/// test is what stops a future simplification from doing that.
#[test]
fn a_layer_track_says_it_was_made_for_a_layer_and_a_hand_made_one_stays_quiet() {
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("Layer.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Layer").unwrap();

    let out = agent_surface::revise::dispatch_layer(
        &mut host,
        user(),
        &json!({
            "instruction": "warm analog bass",
            "regionStartTicks": 0,
            "regionEndTicks": 2 * BAR_TICKS,
            "stem": "bass",
            "trackName": "Layer",
            "variants": 1
        }),
    )
    .unwrap();
    assert_eq!(out["trackPrepared"], json!(true), "no track was prepared, so there is nothing to explain");

    // The USER-MADE case is constructed AFTER the layer, deliberately. A
    // previous lane's version of this assertion was satisfied by a track that
    // was already in the fixture before anything ran, so the failure would have
    // landed on the wrong line and the net was weaker than it looked.
    host.submit(user(), "track.add", json!({ "trackId": "by_hand", "name": "By hand" }))
        .unwrap();

    assert_eq!(
        origin_of(&host, "Layer").as_deref(),
        Some("layered"),
        "the layer track carries no explanation: {:?}",
        origins(&host)
    );
    assert_eq!(
        origin_of(&host, "By hand"),
        None,
        "a track the user added by hand was marked as one the app made: {:?}",
        origins(&host)
    );

    // WHICH track, not "the project contains one". A classifier that marks
    // everything passes a "some track is layered" assertion.
    let marked: Vec<_> = origins(&host)
        .into_iter()
        .filter(|(_, o)| o.as_deref() == Some("layered"))
        .collect();
    assert_eq!(marked.len(), 1, "exactly one track came from a layer: {marked:?}");
}

/// Undoing the preparation takes the track and its explanation away together —
/// which is the property a parallel flag cannot have, because nothing would
/// clear it.
#[test]
fn undoing_the_layer_track_removes_its_explanation_with_it() {
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("LayerUndo.mstudio");
    let mut host = StudioHost::create_at(&pkg, "LayerUndo").unwrap();

    agent_surface::revise::dispatch_layer(
        &mut host,
        user(),
        &json!({
            "instruction": "pad", "regionStartTicks": 0, "regionEndTicks": BAR_TICKS,
            "trackName": "Layer", "variants": 1
        }),
    )
    .unwrap();
    assert_eq!(origin_of(&host, "Layer").as_deref(), Some("layered"));

    // `studio_layer` lands the take AFTER preparing the track, so the take is
    // the top of the stack. Undo until the track itself goes.
    let mut guard = 0;
    while host.project().tracks.iter().any(|t| t.name == "Layer") {
        assert!(host.undo(user()).unwrap(), "ran out of undo before the track went");
        guard += 1;
        assert!(guard < 12, "the layer track took more than 12 undos to remove");
    }
    assert!(
        origins(&host).iter().all(|(_, o)| o.is_none()),
        "an explanation outlived the track it explained: {:?}",
        origins(&host)
    );
}

// ---------------------------------------------------------------------------
// IMPORTING A FOLDER OF STEMS
// ---------------------------------------------------------------------------

fn stem_dir(dir: &std::path::Path) -> PathBuf {
    let stems = dir.join("stems");
    std::fs::create_dir(&stems).unwrap();
    for (name, src) in [
        ("bass.wav", "tone_440_48k_mono.wav"),
        ("drums.wav", "click_120bpm_48k_stereo.wav"),
    ] {
        std::fs::copy(fixture(src), stems.join(name)).unwrap();
    }
    stems
}

/// One track per file past the first, and only those. The track the CALLER
/// supplied is not something the app made, so it is not something the app owes
/// a sentence about.
#[test]
fn an_imported_stem_track_says_so_and_the_one_the_caller_supplied_does_not() {
    let dir = tempfile::tempdir().unwrap();
    let stems = stem_dir(dir.path());
    let pkg = dir.path().join("Stems.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Stems").unwrap();
    host.submit(user(), "track.add", json!({ "trackId": "t1", "name": "Mine" }))
        .unwrap();

    host.submit(
        user(),
        "import.stems",
        json!({ "sourceDir": stems, "targetTrackId": "t1", "startTicks": 0 }),
    )
    .unwrap();

    // Files are sorted, so bass.wav is first (onto "Mine") and drums.wav mints
    // a track of its own.
    assert_eq!(
        origin_of(&host, "Mine"),
        None,
        "the track the caller already owned was reported as one the app made: {:?}",
        origins(&host)
    );
    assert_eq!(
        origin_of(&host, "drums").as_deref(),
        Some("imported"),
        "the track the import minted carries no explanation: {:?}",
        origins(&host)
    );
    let marked: Vec<_> = origins(&host)
        .into_iter()
        .filter(|(_, o)| o.as_deref() == Some("imported"))
        .collect();
    assert_eq!(marked.len(), 1, "exactly one track was minted by this import: {marked:?}");
}

/// WHICH TRACKS, NOT HOW MANY.
///
/// This is the agent-facing half. `count: 2` is unusable to the caller that has
/// to do the next thing: it has to diff two snapshots to learn what it now
/// owns. The names are what the arrangement shows and what a follow-up call
/// needs, and `created` says which of them this call is responsible for.
#[test]
fn importing_stems_reports_which_tracks_not_just_how_many() {
    let dir = tempfile::tempdir().unwrap();
    let stems = stem_dir(dir.path());
    let pkg = dir.path().join("StemsNamed.mstudio");
    let mut host = StudioHost::create_at(&pkg, "StemsNamed").unwrap();
    host.submit(user(), "track.add", json!({ "trackId": "t1", "name": "Mine" }))
        .unwrap();

    let out = host
        .submit(
            user(),
            "import.stems",
            json!({ "sourceDir": stems, "targetTrackId": "t1", "startTicks": 0 }),
        )
        .unwrap();

    let tracks = out["tracks"].as_array().expect("the result must list the tracks, not only count them");
    assert_eq!(tracks.len(), 2, "one entry per stem: {out}");

    let named: Vec<&str> = tracks.iter().map(|t| t["name"].as_str().unwrap()).collect();
    assert_eq!(
        named,
        vec!["Mine", "drums"],
        "the result must name the rows the caller can now see: {out}"
    );
    // And it must say which of them this call put there — the difference
    // between "I made this" and "this was already yours".
    assert_eq!(tracks[0]["created"], json!(false), "the caller's own track was claimed as new: {out}");
    assert_eq!(tracks[1]["created"], json!(true), "the minted track was not reported as new: {out}");
    // Every id is resolvable, so a follow-up call can act on it without a
    // snapshot diff. A list of names alone would still leave that round trip.
    for t in tracks {
        let id = t["trackId"].as_str().unwrap();
        assert!(host.project().track(id).is_some(), "result names a track that does not exist: {id}");
    }
}

/// ONE GESTURE, ONE UNDO STEP — the fix for the defect this test used to pin.
///
/// It was `importing_stems_is_not_yet_one_undo_step`, and it asserted `added ==
/// 4` for a two-stem drop: the `import.stems` record, a bare `track.add` for
/// the second file, and one transaction per `import_audio`. It grew by two per
/// extra file, so a four-stem drop cost eight presses of Cmd-Z and the session
/// came apart in pieces on the way back.
///
/// What unblocked it: `Session` refused nested transactions outright, so
/// wrapping the existing helper made the import FAIL rather than group.
/// `timeline_core::session::OpenTxn` is re-entrant now — one journaled bracket
/// and one undo unit however many times it is re-entered — so
/// `import_stems_params` opens the transaction `apply.rs` always said it opened.
///
/// KEPT rather than replaced, under a name that says the new truth, so the
/// count stays measured. `count` is asserted alongside it because "1 undo unit"
/// is also what a stem import that imported NOTHING would report.
#[test]
fn importing_stems_is_one_undo_step() {
    let dir = tempfile::tempdir().unwrap();
    let stems = stem_dir(dir.path());
    let pkg = dir.path().join("StemsUndo.mstudio");
    let mut host = StudioHost::create_at(&pkg, "StemsUndo").unwrap();
    host.submit(user(), "track.add", json!({ "trackId": "t1", "name": "Mine" }))
        .unwrap();
    let before = host.snapshot(None)["project"]["undoDepth"].as_u64().unwrap();

    let out = host
        .submit(
            user(),
            "import.stems",
            json!({ "sourceDir": stems, "targetTrackId": "t1", "startTicks": 0 }),
        )
        .unwrap();
    assert_eq!(out["count"], json!(2), "both stems must actually have landed: {out}");

    let added = host.snapshot(None)["project"]["undoDepth"].as_u64().unwrap() - before;
    assert_eq!(
        added, 1,
        "one drag of a stem folder must cost one press of Cmd-Z, not {added}"
    );
    // And it is one step for FOUR stems too — the old shape grew by two per
    // file, so a count that is 1 here and 2N there would be a fixture artefact
    // rather than a fix.
    let four = dir.path().join("four");
    std::fs::create_dir(&four).unwrap();
    for name in ["a.wav", "b.wav", "c.wav", "d.wav"] {
        std::fs::copy(fixture("tone_440_48k_mono.wav"), four.join(name)).unwrap();
    }
    // Onto a FRESH track: the first file of a stem drop lands on the track the
    // caller names, and `t1` is already occupied at bar 0 by the drop above.
    host.submit(user(), "track.add", json!({ "trackId": "t2", "name": "Also mine" }))
        .unwrap();
    let before_four = host.snapshot(None)["project"]["undoDepth"].as_u64().unwrap();
    host.submit(
        user(),
        "import.stems",
        json!({ "sourceDir": four, "targetTrackId": "t2", "startTicks": 0 }),
    )
    .unwrap();
    assert_eq!(
        host.snapshot(None)["project"]["undoDepth"].as_u64().unwrap() - before_four,
        1,
        "a four-stem drop is still one undo step"
    );
}

// ---------------------------------------------------------------------------
// PLAYING A NOTE OPENS THE OUTPUT DEVICE
// ---------------------------------------------------------------------------

/// Item 5 of this lane, and the decision is DELIBERATE SILENCE about the
/// success — see `preview_note`. What must not be silent is the refusal, and it
/// names the reason rather than a flat "could not".
///
/// A headless host never opts into audible output, so this is the branch a test
/// can reach; the device-open failure branch interpolates the driver's own
/// message the same way, where it used to go to `eprintln!` and nowhere else.
#[test]
fn a_note_that_cannot_be_heard_says_why_rather_than_failing_quietly() {
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("Quiet.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Quiet").unwrap();

    let out = host.preview_note(&json!({ "pitch": 60 })).unwrap();
    assert_eq!(out["audible"], json!(false));
    let reason = out["reason"].as_str().unwrap_or_default();
    assert!(
        reason.contains("audible output") || reason.contains("output device"),
        "the refusal must say what was not done: {out}"
    );
    // And the note still CREATED the instrument track it needed, which is the
    // thing this lane is about — so the snapshot explains it even on a machine
    // that made no sound at all.
    assert!(
        origins(&host).iter().any(|(_, o)| o.as_deref() == Some("played")),
        "playing on a silent host still makes a track, and it must still say so: {:?}",
        origins(&host)
    );
}
