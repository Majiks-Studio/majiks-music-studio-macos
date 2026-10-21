//! Silent import acceptance coverage: media decode/analyze/tile generation,
//! bar snapping, journal provenance, and one-step transactional undo.

use std::path::PathBuf;

use agent_surface::StudioHost;
use serde_json::json;
use timeline_core::Actor;

fn fixture(name: &str) -> PathBuf {
    // engine/fixtures/*.wav are generated (gitignored). Ensure them here so
    // this binary never depends on run order or another lane's leftovers: a
    // missing, truncated, or torn fixture is atomically regenerated instead
    // of surfacing as a misleading "No such file" / decode error.
    static FIXTURES_READY: std::sync::Once = std::sync::Once::new();
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../fixtures");
    FIXTURES_READY.call_once(|| {
        render::fixtures::ensure(&dir).expect("ensure engine/fixtures");
    });
    dir.join(name)
}

#[test]
fn wav_import_is_media_analyzed_tiled_snapped_and_undoable() {
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("Import.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Import").unwrap();
    host.submit(Actor::user("test"), "track.add", json!({
        "trackId": "t1", "name": "Imported"
    })).unwrap();

    let result = host.submit(Actor::user("test"), "import.audio", json!({
        "sourcePath": fixture("click_120bpm_48k_stereo.wav"),
        "targetTrackId": "t1",
        "startTicks": 1920,
        "clipId": "imported_click"
    })).unwrap();
    assert_eq!(result["startTicks"], json!(3840), "import snaps to nearest bar");
    assert_eq!(result["tilesReady"], json!(true));
    assert!(result["measuredBpm"].as_f64().unwrap() > 0.0);

    let snapshot = host.snapshot(None);
    assert_eq!(snapshot["project"]["clipCount"], 1);
    assert!(pkg.join("tiles").read_dir().unwrap().next().is_some());
    let manifest = host.manifest_value();
    assert_eq!(manifest["clips"][0]["origin"], "imported");

    assert!(host.undo(Actor::user("test")).unwrap());
    assert_eq!(host.snapshot(None)["project"]["clipCount"], 0);
}

/// A stem folder with `names` in it, each a copy of a real decodable fixture.
fn stem_dir(root: &std::path::Path, names: &[&str]) -> PathBuf {
    let stems = root.join("stems");
    std::fs::create_dir_all(&stems).unwrap();
    for (i, name) in names.iter().enumerate() {
        let src = if i % 2 == 0 { "click_120bpm_48k_stereo.wav" } else { "tone_440_48k_mono.wav" };
        std::fs::copy(fixture(src), stems.join(name)).unwrap();
    }
    stems
}

/// Everything the project holds, with the fields that are not project state
/// stripped. Comparing this whole structure is the honest form of "undo
/// restored exactly": an assertion listing the things one remembers to check
/// cannot see the orphan one forgot — and this codebase has already lost a
/// track's synth to an inverse that put the track back and nothing else.
///
/// `loadedSources` is excluded, and the exclusion is a FINDING rather than a
/// convenience. It is the host's decoded-audio cache keyed by content hash, not
/// part of the project, and undoing an import does NOT evict it — the bytes
/// stay decoded in memory and the ingested file stays in the package. That is
/// deliberate on both counts: assets are content-addressed and shared, so
/// deleting one on undo could pull the audio out from under a clip somewhere
/// else, and keeping it is what makes redo instant. Nothing points at it, so it
/// is an unreferenced asset, which is the opposite of a dangling reference —
/// `dangling_clip_sources` below asserts the direction that would be a bug.
fn shape(host: &mut StudioHost) -> serde_json::Value {
    let mut p = host.snapshot(None)["project"].clone();
    let obj = p.as_object_mut().unwrap();
    for not_project_state in ["undoDepth", "redoDepth", "loadedSources"] {
        obj.remove(not_project_state);
    }
    p
}

/// Clips whose audio the host cannot resolve. A dangling reference is a clip
/// drawn on the timeline with nothing behind it, and it is what an inverse that
/// took an asset back too far would leave.
fn dangling_clip_sources(host: &mut StudioHost) -> Vec<String> {
    let snap = host.snapshot(None);
    let loaded = snap["project"]["loadedSources"].as_object().cloned().unwrap_or_default();
    let mut dangling = Vec::new();
    for track in snap["project"]["tracks"].as_array().cloned().unwrap_or_default() {
        for clip in track["clips"].as_array().cloned().unwrap_or_default() {
            let source = clip["source_id"].as_str().unwrap_or_default().to_string();
            if !loaded.contains_key(&source) {
                dangling.push(format!("{} -> {source}", clip["id"]));
            }
        }
    }
    dangling
}

/// ONE CMD-Z PUTS BACK EXACTLY WHAT WAS THERE, AND REDO BRINGS IT BACK WHOLE.
///
/// The counting half lives in `says_what_it_made.rs`
/// (`importing_stems_is_one_undo_step`). This is the half that matters more:
/// a gesture collapsed into one undo step whose inverse is incomplete is not a
/// fix, it is 17 data-loss paths waiting to be reopened. So the fixture carries
/// a device on the track the caller supplied — the exact thing a bare
/// `track.add` inverse ate last time — and the assertion is a whole-project
/// comparison rather than a list of things worth checking.
#[test]
fn one_undo_restores_the_project_a_stem_import_found_and_redo_puts_it_all_back() {
    let tmp = tempfile::tempdir().unwrap();
    let stems = stem_dir(tmp.path(), &["bass.wav", "drums.wav", "keys.wav", "vox.wav"]);
    let pkg = tmp.path().join("StemsUndo.mstudio");
    let mut host = StudioHost::create_at(&pkg, "StemsUndo").unwrap();
    host.submit(Actor::user("test"), "track.add", json!({"trackId": "t1", "name": "Mine"})).unwrap();
    // A device on the caller's track: an inverse that rebuilt the track instead
    // of never touching it would lose this and nothing else would notice.
    host.submit(Actor::user("test"), "device.add",
        json!({"trackId": "t1", "deviceId": "dev1", "kind": "synth"})).unwrap();

    let before = shape(&mut host);
    let depth_before = host.snapshot(None)["project"]["undoDepth"].as_u64().unwrap();

    host.submit(Actor::user("test"), "import.stems",
        json!({"sourceDir": stems, "targetTrackId": "t1", "startTicks": 0})).unwrap();
    let after = shape(&mut host);
    assert_ne!(before, after, "the import changed nothing, so the undo below proves nothing");
    assert_eq!(host.snapshot(None)["project"]["clipCount"], json!(4));
    assert_eq!(host.snapshot(None)["project"]["tracks"].as_array().unwrap().len(), 4);
    assert!(dangling_clip_sources(&mut host).is_empty(), "{:?}", dangling_clip_sources(&mut host));

    assert!(host.undo(Actor::user("test")).unwrap(), "the import left nothing to undo");
    assert_eq!(
        shape(&mut host), before,
        "one Cmd-Z did not restore the project the import found"
    );
    assert_eq!(
        host.snapshot(None)["project"]["undoDepth"].as_u64().unwrap(), depth_before,
        "the import cost more than one undo unit"
    );

    assert!(host.redo(Actor::user("test")).unwrap());
    assert_eq!(shape(&mut host), after, "redo did not bring the import back whole");
    assert!(
        dangling_clip_sources(&mut host).is_empty(),
        "redo put clips back with nothing behind them: {:?}",
        dangling_clip_sources(&mut host)
    );
}

/// THE FAILURE PATH, WHICH IS THE ONE THAT MATTERS FOR A GROUPED GESTURE.
///
/// A folder where the third file is not decodable. The import must fail with
/// the first two ALREADY APPLIED and taken back again: no half-folder in the
/// project, no undo unit published, no open transaction wedging every later
/// gesture — and, because the journal is replayed, nothing left in it that
/// would put the half-folder back on the next open. That last one is why
/// `Session::abort_txn` journals its rollback.
#[test]
fn a_stem_that_will_not_decode_takes_the_whole_import_back_including_on_reopen() {
    let tmp = tempfile::tempdir().unwrap();
    let stems = stem_dir(tmp.path(), &["a_good.wav", "b_good.wav", "d_good.wav"]);
    // Sorts third of four: two stems land before this one refuses.
    std::fs::write(stems.join("c_broken.wav"), b"this is not a RIFF file at all").unwrap();

    let pkg = tmp.path().join("StemsFail.mstudio");
    let mut host = StudioHost::create_at(&pkg, "StemsFail").unwrap();
    host.submit(Actor::user("test"), "track.add", json!({"trackId": "t1", "name": "Mine"})).unwrap();
    let before = shape(&mut host);
    let depth_before = host.snapshot(None)["project"]["undoDepth"].as_u64().unwrap();

    let mark = host.journal_page(None, 500)["total"].as_u64().unwrap() as usize;
    let failed = host.submit(Actor::user("test"), "import.stems",
        json!({"sourceDir": stems, "targetTrackId": "t1", "startTicks": 0}));
    assert!(failed.is_err(), "an undecodable stem was reported as a success: {failed:?}");

    // THE ROLLBACK HAD SOMETHING TO ROLL BACK. Without this the whole test
    // could pass on an import that refused the first file and never touched the
    // project — a green assertion about a code path nothing entered. The
    // journal shows two stems landing, being compensated away, and the bracket
    // left open (no `txn.commit`, because nothing was committed).
    let entries = host.journal_page(None, 500);
    let names: Vec<&str> = entries["entries"].as_array().unwrap()[mark..]
        .iter().map(|e| e["name"].as_str().unwrap()).collect();
    assert_eq!(names.first(), Some(&"txn.begin"), "the gesture opened no bracket: {names:?}");
    assert_eq!(
        names.iter().filter(|n| **n == "clip.place").count(), 2,
        "two stems must have LANDED before the third refused: {names:?}"
    );
    assert_eq!(
        names.iter().filter(|n| **n == "clip.remove").count(), 2,
        "the landed clips were not compensated in the journal: {names:?}"
    );
    assert_eq!(
        names.iter().filter(|n| **n == "track.add").count(),
        names.iter().filter(|n| **n == "track.remove").count(),
        "a minted track was not compensated in the journal: {names:?}"
    );
    assert!(!names.contains(&"txn.commit"), "a rolled-back bracket was committed: {names:?}");

    assert_eq!(shape(&mut host), before, "the import half-applied: {:?}", shape(&mut host));
    assert_eq!(
        host.snapshot(None)["project"]["undoDepth"].as_u64().unwrap(), depth_before,
        "a transaction that applied nothing became an undo unit"
    );
    // Not wedged: an open transaction would make both of these fail.
    host.submit(Actor::user("test"), "track.add", json!({"trackId": "t2", "name": "After"})).unwrap();
    assert!(host.undo(Actor::user("test")).unwrap(), "the session was left with an open transaction");

    // AND THE JOURNAL AGREES. No project.save and no Drop, so this is the
    // crash-recovery path: the package is rebuilt from journal entries alone.
    // Compared on tracks + clip count rather than the whole shape, because the
    // live host and a freshly opened one legitimately differ on which assets
    // they have LOADED — and the claim here is about the arrangement, which is
    // what a half-import would show up in.
    let expected_tracks = host.snapshot(None)["project"]["tracks"].clone();
    std::mem::forget(host);
    let mut reopened = StudioHost::open_package(&pkg).unwrap();
    let after_reopen = reopened.snapshot(None);
    assert_eq!(
        after_reopen["project"]["tracks"], expected_tracks,
        "replaying the journal put the rolled-back half-import back"
    );
    assert_eq!(after_reopen["project"]["clipCount"], json!(0), "a rolled-back clip came back on reopen");
}

/// Every journaled envelope in `journal.jsonl`, as JSON. The FILE, not the
/// in-memory journal: the envelope's `inverse` is one of the seven hashed
/// fields, so what is written is what a later build will read and verify.
fn journal_envelopes(pkg: &std::path::Path) -> Vec<serde_json::Value> {
    std::fs::read_to_string(pkg.join("journal.jsonl"))
        .expect("journal.jsonl")
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| serde_json::from_str(l).expect("envelope parses"))
        .collect()
}

/// THE RECORD MUST NOT CLAIM IT UNDOES ITSELF BY DELETING SOMEBODY ELSE'S TRACK.
///
/// `import.stems` is journaled as an io REQUEST record: `apply.rs` mutates
/// nothing and the undo sequence is empty, so this envelope's `inverse` is
/// never executed — reversal comes from the `track.add` / `clip.place` entries
/// beside it in the same transaction. It is still a hash-chained claim in a
/// replayed record, and it used to name `track.remove` of the CALLER'S track:
/// the one track in the group the import did not create, carrying whatever
/// devices, mixer state and automation the user already had on it. That is the
/// exact loss `one_undo_restores_the_project_a_stem_import_found_and_redo_puts_it_all_back`
/// stages a device to catch.
///
/// The catalog cannot be where this is fixed: `inverseRule` is v1.1 law and
/// `timeline-core/tests/catalog_superset.rs` pins it byte-equal to the frozen
/// file, so the declared NAME is `track.remove` and stays `track.remove`. What
/// is asserted here is that the track it NAMES is one the import minted.
///
/// ⚠️ Both halves matter. Asserting only "not t1" would pass on a claim naming
/// a track that never existed; asserting only "a track exists" would pass on
/// the old, wrong t1. So the target is required to be absent BEFORE the import
/// and present AFTER it — a fact only a minted track can satisfy.
#[test]
fn the_stem_import_record_names_a_track_the_import_made() {
    let tmp = tempfile::tempdir().unwrap();
    let stems = stem_dir(tmp.path(), &["bass.wav", "drums.wav", "keys.wav"]);
    let pkg = tmp.path().join("StemsInverse.mstudio");
    let mut host = StudioHost::create_at(&pkg, "StemsInverse").unwrap();
    host.submit(Actor::user("test"), "track.add", json!({"trackId": "t1", "name": "Mine"})).unwrap();

    let track_ids = |h: &mut StudioHost| -> Vec<String> {
        h.snapshot(None)["project"]["tracks"].as_array().unwrap().iter()
            .map(|t| t["id"].as_str().unwrap().to_string()).collect()
    };
    let before = track_ids(&mut host);

    host.submit(Actor::user("test"), "import.stems",
        json!({"sourceDir": stems, "targetTrackId": "t1", "startTicks": 0})).unwrap();
    let after = track_ids(&mut host);
    assert_eq!(after.len(), before.len() + 2, "three stems onto t1 mint two tracks: {after:?}");

    let envelopes = journal_envelopes(&pkg);
    let record = envelopes.iter().find(|e| e["name"] == "import.stems")
        .expect("the import.stems record is journaled");
    let inverse = &record["inverse"];
    assert!(!inverse.is_null(), "undoable=true, so conformance requires a non-null inverse");
    assert_eq!(inverse["name"], json!("track.remove"), "the declared inverse NAME is v1.1 law");

    let target = inverse["params"]["trackId"].as_str().expect("trackId");
    assert!(
        !before.contains(&target.to_string()),
        "the record claims it undoes by removing {target}, which was on the timeline BEFORE \
         the import — the import did not create it and undo must never touch it"
    );
    assert!(
        after.contains(&target.to_string()),
        "the record names {target}, which no track in the project has: {after:?}"
    );

    // AND THE SEQUENCE IS STILL EMPTY, which is why the claim above is a claim
    // and not a data-loss path. If a later change starts EXECUTING it, undo
    // depth would move and this pins that it does not.
    assert!(host.undo(Actor::user("test")).unwrap());
    assert_eq!(track_ids(&mut host), before, "one undo did not restore the project the import found");
}

/// The residual, pinned so it cannot be mistaken for an oversight: a folder
/// holding ONE stem mints no track, `undoable: true` is v1.1 law, and
/// `contracts/conformance` refuses a null inverse under it — so there is no
/// truthful `track.remove` available and the record keeps the caller's track.
/// Recorded here rather than left to be rediscovered from the journal.
#[test]
fn a_single_stem_folder_has_no_minted_track_for_the_record_to_name() {
    let tmp = tempfile::tempdir().unwrap();
    let stems = stem_dir(tmp.path(), &["only.wav"]);
    let pkg = tmp.path().join("StemsOne.mstudio");
    let mut host = StudioHost::create_at(&pkg, "StemsOne").unwrap();
    host.submit(Actor::user("test"), "track.add", json!({"trackId": "t1", "name": "Mine"})).unwrap();

    host.submit(Actor::user("test"), "import.stems",
        json!({"sourceDir": stems, "targetTrackId": "t1", "startTicks": 0})).unwrap();
    assert_eq!(
        host.snapshot(None)["project"]["tracks"].as_array().unwrap().len(), 1,
        "a single stem lands on the caller's track and mints nothing"
    );

    let envelopes = journal_envelopes(&pkg);
    let record = envelopes.iter().find(|e| e["name"] == "import.stems").expect("record");
    assert_eq!(record["inverse"]["name"], json!("track.remove"));
    assert_eq!(
        record["inverse"]["params"]["trackId"], json!("t1"),
        "there is no minted track to name, so this case still names the caller's"
    );
}

#[test]
fn stem_directory_places_one_clip_per_track() {
    let tmp = tempfile::tempdir().unwrap();
    let stems = tmp.path().join("stems");
    std::fs::create_dir(&stems).unwrap();
    for (name, fixture_name) in [("drums.wav", "click_120bpm_48k_stereo.wav"), ("bass.wav", "tone_440_48k_mono.wav")] {
        std::fs::copy(fixture(fixture_name), stems.join(name)).unwrap();
    }
    let pkg = tmp.path().join("Stems.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Stems").unwrap();
    host.submit(Actor::user("test"), "track.add", json!({ "trackId": "t1", "name": "Drums" })).unwrap();
    let result = host.submit(Actor::user("test"), "import.stems", json!({
        "sourceDir": stems, "targetTrackId": "t1", "startTicks": 100
    })).unwrap();
    assert_eq!(result["count"], json!(2));
    assert_eq!(host.snapshot(None)["project"]["clipCount"], 2);
}
