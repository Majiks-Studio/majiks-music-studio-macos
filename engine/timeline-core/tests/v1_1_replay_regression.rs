//! Invariant 2, the one that actually matters (design §9.3 says invariant 3,
//! the golden hash, is "nearly vacuous as a v2 safety property" — it is
//! structurally immune to catalog growth).
//!
//! A v1.1 project whose journal exercises BOTH volume and pan automation must
//! open under the v2 binary, replay, and produce a byte-for-byte unchanged
//! blake3 chain.
//!
//! The pinned tip hash is NOT circular evidence: it was computed by
//! `engine/contracts/conformance_py/canonical.py`, an independent
//! implementation of the canonicalization spec that knows nothing about
//! catalog v2, the `Cmd` enum, or `ParamRef`. If the v2 engine's ParamRef
//! serialization drifted by a single byte from the v1 `AutoTarget` enum's, this
//! test fails.

use std::path::PathBuf;

use timeline_core::journal::verify_lines;
use timeline_core::package::Package;
use timeline_core::ParamRef;

/// Produced by `conformance_py`, not by this crate.
const EXPECTED_TIP: &str = "4c79c6c1a1c9e23fe132762977c30d719de26978da8df002df8d444a64458e03";
const EXPECTED_ENTRIES: usize = 10;

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/v1_1-automation.mstudio")
}

#[test]
fn a_v1_1_automation_project_replays_to_an_unchanged_chain() {
    let dir = fixture_dir();

    // 1. The chain verifies on its own terms, straight off disk.
    let text = std::fs::read_to_string(dir.join("journal.jsonl")).expect("fixture journal");
    let lines: Vec<String> = text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(String::from)
        .collect();
    let (tip, n) = verify_lines(&lines).expect("v1.1 chain must verify under v2");
    assert_eq!(n, EXPECTED_ENTRIES);
    assert_eq!(
        tip, EXPECTED_TIP,
        "the blake3 chain of a v1.1 journal changed under catalog v2"
    );

    // 2. It opens and REPLAYS (no checkpoint on disk, so this is the full
    //    replay-from-empty path, i.e. every command goes back through
    //    Cmd::from_wire and apply.rs).
    let session = Package::open(&dir).expect("v1.1 project must open under v2");
    assert_eq!(session.journal().len(), EXPECTED_ENTRIES);
    assert_eq!(
        session.tip_hash(),
        EXPECTED_TIP,
        "replay changed the chain tip"
    );

    // 3. And the replayed model is right: volume AND pan lanes landed in their
    //    legacy fields, and autolane.clear emptied the third lane.
    let p = session.project();
    let bass = p.track("trk_bass").expect("bass track");
    assert_eq!(
        bass.automation
            .lane(&ParamRef::track_volume())
            .iter()
            .map(|x| x.id.as_str())
            .collect::<Vec<_>>(),
        ["ap_v1", "ap_v2"]
    );
    assert_eq!(
        bass.automation
            .lane(&ParamRef::track_pan())
            .iter()
            .map(|x| (x.id.as_str(), x.position_ticks))
            .collect::<Vec<_>>(),
        [("ap_p1", 0), ("ap_p2", 4800)],
        "autopoint.move must have moved the pan point"
    );
    assert!(
        bass.automation.lanes.is_empty(),
        "a v1.1 project must not gain a single v2 lanes entry"
    );

    let synth = p.track("trk_synth").expect("synth track");
    assert!(synth.automation.lane(&ParamRef::track_volume()).is_empty());
}

// ---------------------------------------------------------------------------
// E1: the same invariant, on a fixture that actually has CLIPS.
//
// `Clip` is v1.1 law and E1 adds `kind` + `notes` to it, so the clip path is
// exactly where an accidental break would live. The automation fixture above
// contains ZERO clips, which would make a clip assertion against it vacuously
// green — the "signal on the wrong axis" failure. Hence a second fixture whose
// eleven entries are all v1.1 clip commands (place / rename / setGain / mute /
// fade / split / trim / move).
//
// The pinned tip is NOT circular: it was computed by
// `engine/contracts/conformance_py/canonical.py`, an independent
// implementation of the canonicalization spec that knows nothing about the
// `Cmd` enum, `ClipKind`, or `Note`. If E1 changed one byte of a v1.1
// `clip.place` payload, this fails.
// ---------------------------------------------------------------------------

const CLIPS_EXPECTED_TIP: &str =
    "34cb55b1f6f4bde9f3343135e78db7bfaf49ca35cd6e542024c5a00b688ea1ae";
const CLIPS_EXPECTED_ENTRIES: usize = 11;

fn clips_fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/v1_1-clips.mstudio")
}

#[test]
fn a_v1_1_clip_project_replays_to_an_unchanged_chain_under_e1() {
    let dir = clips_fixture_dir();

    let text = std::fs::read_to_string(dir.join("journal.jsonl")).expect("fixture journal");
    let lines: Vec<String> = text
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(String::from)
        .collect();
    let (tip, n) = verify_lines(&lines).expect("v1.1 clip chain must verify under E1");
    assert_eq!(n, CLIPS_EXPECTED_ENTRIES);
    assert_eq!(
        tip, CLIPS_EXPECTED_TIP,
        "the blake3 chain of a v1.1 CLIP journal changed under E1"
    );

    // Full replay-from-empty: every command goes back through Cmd::from_wire
    // and apply.rs, which is where a new field on Clip would show.
    let session = Package::open(&dir).expect("v1.1 clip project must open under E1");
    assert_eq!(session.journal().len(), CLIPS_EXPECTED_ENTRIES);
    assert_eq!(session.tip_hash(), CLIPS_EXPECTED_TIP, "replay changed the tip");

    // The fixture really does carry clips — without this the loops below would
    // be vacuous, which is exactly how a mutation check gets a false green.
    let p = session.project();
    let clips: Vec<_> = p.tracks.iter().flat_map(|t| t.clips.iter()).collect();
    assert_eq!(clips.len(), 3, "clp_a + clp_c (from the split) + clp_b");

    for c in &clips {
        assert!(!c.is_midi(), "clip {} was read as note-backed", c.id);
        assert!(c.notes.is_empty(), "clip {} gained notes", c.id);
    }
    // And the state the clip commands actually produced, not just their count.
    let a = p.clip("clp_a").expect("clp_a");
    assert_eq!(a.name, "Riff");
    assert_eq!(a.length_ticks, 1920, "split at 1920 shortened the left piece");
    assert_eq!(a.fade_in.length_ticks, 240);
    let c = p.clip("clp_c").expect("clp_c");
    assert_eq!(c.length_ticks, 1440, "1920 right piece trimmed by 480");
    assert_eq!(p.clip("clp_b").expect("clp_b").start_ticks, 5760);

    // The checkpoint carries no E1 key at all: an audio clip's bytes are
    // unchanged by E1.
    let cp = timeline_core::package::to_project_json(&session);
    let cp_clips = cp["clips"].as_array().expect("clips array");
    assert_eq!(cp_clips.len(), 3);
    for clip in cp_clips {
        let obj = clip.as_object().unwrap();
        assert!(
            obj.get("kind").is_none(),
            "a v1.1 clip gained a `kind` key on save: {clip}"
        );
        assert!(
            obj.get("notes").is_none(),
            "a v1.1 clip gained a `notes` key on save: {clip}"
        );
        assert!(
            obj.contains_key("assetHash"),
            "a v1.1 audio clip must still carry its asset hash: {clip}"
        );
    }

    // Reloading that checkpoint reproduces the same model — proof the additive
    // read path did not quietly reinterpret anything.
    let reloaded = timeline_core::package::from_project_json(&cp).expect("reload");
    assert_eq!(&reloaded.tracks, &p.tracks);
}

#[test]
fn re_serializing_a_v1_1_clip_entry_is_byte_stable() {
    let dir = clips_fixture_dir();
    let text = std::fs::read_to_string(dir.join("journal.jsonl")).expect("fixture journal");
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let env = timeline_core::Envelope::from_line(line).expect("parses");
        assert_eq!(
            env.to_jsonl(),
            line,
            "re-serializing a v1.1 clip entry changed its bytes"
        );
    }
}

#[test]
fn re_serializing_a_v1_1_journal_entry_is_byte_stable() {
    // The tightest form of invariant 2: reopen every entry and re-emit it. A
    // single changed byte anywhere in `params` would change its hash.
    let dir = fixture_dir();
    let text = std::fs::read_to_string(dir.join("journal.jsonl")).expect("fixture journal");
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let env = timeline_core::Envelope::from_line(line).expect("parses");
        assert_eq!(
            env.to_jsonl(),
            line,
            "re-serializing a v1.1 entry changed its bytes"
        );
    }
}
