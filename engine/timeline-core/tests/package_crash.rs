//! .mstudio package io: round-trip, missing-asset -> offline, unknown-field
//! preservation, and the kill -9 mid-save recovery test.
//!
//! The kill -9 test spawns a child that opens a package, submits commands
//! (each written straight through to `journal.jsonl` by `FileJournal::append`),
//! then hard-aborts itself with SIGKILL DURING a save (a corrupt/partial
//! checkpoint), never returning. The parent then opens the package and asserts
//! it recovers to the last journaled command via the full-replay fallback.
//!
//! The child does NOT write the journal itself. It used to, which is how this
//! file stayed green through the defect that made a user's session vanish --
//! see the note in `child_crash`.

#[path = "support.rs"]
mod support;

use std::path::PathBuf;

use serde_json::json;
use timeline_core::cmd::Cmd;
use timeline_core::package::Package;
use timeline_core::session::{MetaSource, SeqMeta};
use timeline_core::{Num, Project, TempoMap};
use timeline_core::tempo::Bpm;

fn tmp(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("mstudio_{name}_{}", std::process::id()))
}

fn base() -> Project {
    Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()))
}

#[test]
fn save_open_round_trip_matches() {
    let dir = tmp("roundtrip");
    let _ = std::fs::remove_dir_all(&dir);
    let mut session = Package::create(&dir, base()).unwrap();
    let mut meta = SeqMeta::user("aaron");
    for cmd in [
        Cmd::ProjectSetTempo { bpm: Num::int(140) },
        Cmd::TrackAdd { track_id: "t1".into(), name: "T1".into(), index: Some(0) },
        Cmd::ClipPlace {
            clip_id: "c1".into(),
            track_id: "t1".into(),
            asset_hash: "a".repeat(64),
            start_ticks: 0,
            length_ticks: 1920,
            source_offset_ticks: None,
        },
    ] {
        session.submit(meta.next_meta(&cmd), cmd).unwrap();
    }
    Package::save(&dir, &mut session).unwrap();

    let reopened = Package::open(&dir).unwrap();
    assert_eq!(reopened.project().bpm_wire, Num::int(140));
    assert_eq!(reopened.project().tracks.len(), 1);
    assert_eq!(reopened.project().tracks[0].clips.len(), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn missing_asset_degrades_to_offline_not_a_refusal() {
    let dir = tmp("offline");
    let _ = std::fs::remove_dir_all(&dir);
    let mut session = Package::create(&dir, base()).unwrap();
    let mut meta = SeqMeta::user("aaron");
    for cmd in [
        Cmd::TrackAdd { track_id: "t1".into(), name: "T1".into(), index: Some(0) },
        Cmd::ClipPlace {
            clip_id: "c1".into(),
            track_id: "t1".into(),
            asset_hash: "f".repeat(64), // no such file under audio/
            start_ticks: 0,
            length_ticks: 1920,
            source_offset_ticks: None,
        },
    ] {
        session.submit(meta.next_meta(&cmd), cmd).unwrap();
    }
    Package::save(&dir, &mut session).unwrap();

    // Reopen: the clip's asset is absent, so it must open with offline=true,
    // never fail to open.
    let reopened = Package::open(&dir).unwrap();
    let clip = reopened.project().clip("c1").expect("clip still present");
    assert!(clip.offline, "missing asset must degrade to offline");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn unknown_checkpoint_fields_round_trip() {
    let dir = tmp("forward_compat");
    let _ = std::fs::remove_dir_all(&dir);
    let mut session = Package::create(&dir, base()).unwrap();
    let cmd = Cmd::TrackAdd { track_id: "t1".into(), name: "T1".into(), index: Some(0) };
    session.submit(SeqMeta::user("a").next_meta(&cmd), cmd).unwrap();
    Package::save(&dir, &mut session).unwrap();

    // A newer app wrote an unknown top-level field into project.json.
    let pj = dir.join("project.json");
    let mut v: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&pj).unwrap()).unwrap();
    v.as_object_mut().unwrap().insert("futureFeature".into(), json!({"x": 1}));
    std::fs::write(&pj, serde_json::to_string_pretty(&v).unwrap()).unwrap();

    // Open (fast path from checkpoint) and re-save; the unknown field survives.
    let mut reopened = Package::open(&dir).unwrap();
    Package::save(&dir, &mut reopened).unwrap();
    let v2: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&pj).unwrap()).unwrap();
    assert_eq!(v2["futureFeature"]["x"], json!(1), "unknown field preserved");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The kill -9 test. A child process builds a package, journals N commands
/// (fsynced), then corrupts the checkpoint and SIGKILLs itself mid-save. The
/// parent reopens and must recover to the last journaled command.
#[test]
fn kill9_mid_save_recovers_to_last_journaled_command() {
    // Re-exec THIS test binary in a child role via an env var. If we are the
    // child, do the crash and never return.
    if std::env::var("MSTUDIO_KILL9_CHILD").is_ok() {
        child_crash();
        // unreachable: child SIGKILLs itself.
        std::process::exit(2);
    }

    let dir = tmp("kill9");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    let exe = std::env::current_exe().unwrap();
    let status = std::process::Command::new(exe)
        .arg("--exact")
        .arg("kill9_mid_save_recovers_to_last_journaled_command")
        .arg("--nocapture")
        .env("MSTUDIO_KILL9_CHILD", "1")
        .env("MSTUDIO_KILL9_DIR", &dir)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .expect("spawn child");
    // The child killed itself with SIGKILL (signal 9): not a clean exit.
    assert!(!status.success(), "child should have died by SIGKILL, got {status:?}");

    // Parent recovery: open the package. The checkpoint is stale/partial, so
    // open falls back to full journal replay and recovers the 5 committed
    // commands.
    let reopened = Package::open(&dir).expect("recover after kill -9");
    let p = reopened.project();
    assert_eq!(p.bpm_wire, Num::int(96), "tempo from journal recovered");
    assert_eq!(p.tracks.len(), 2, "both tracks recovered");
    assert!(p.clip("c1").is_some(), "placed clip recovered");
    assert_eq!(reopened.seq(), 5, "exactly the 5 journaled commands");
    let _ = std::fs::remove_dir_all(&dir);
    println!("kill -9 recovery OK: replayed to seq {}", reopened.seq());
}

fn child_crash() {
    let dir = PathBuf::from(std::env::var("MSTUDIO_KILL9_DIR").unwrap());
    // Fresh package; journal 5 commands. Each one reaches journal.jsonl at
    // submit time through the production sink -- no help from this test.
    let mut session = Package::create(&dir, base()).unwrap();
    let mut meta = SeqMeta::user("aaron");
    let cmds = [
        Cmd::ProjectSetTempo { bpm: Num::int(96) },
        Cmd::TrackAdd { track_id: "t1".into(), name: "Drums".into(), index: Some(0) },
        Cmd::TrackAdd { track_id: "t2".into(), name: "Bass".into(), index: Some(1) },
        Cmd::ClipPlace {
            clip_id: "c1".into(),
            track_id: "t1".into(),
            asset_hash: "a".repeat(64),
            start_ticks: 0,
            length_ticks: 1920,
            source_offset_ticks: None,
        },
        Cmd::ClipSetGain { clip_id: "c1".into(), gain_db: Num::int(-4) },
    ];
    for cmd in cmds {
        session.submit(meta.next_meta(&cmd), cmd).unwrap();
    }
    // ⚠️ HISTORY, because this is how the test USED to pass over the bug it
    // claimed to prove: it re-wrote `journal.jsonl` by hand here, with a comment
    // asserting "each fsynced by the FileJournal" that was FALSE. `FileJournal`
    // buffered every append and nothing in the engine ever called `sync()`, so
    // the hand-write was silently substituting for the production write path.
    // The test was green and the shipping app lost a whole day's work.
    //
    // The hand-write is gone. `FileJournal::append` now writes each line
    // through on submit, so by this point the 5 commands are already in the
    // file, put there by the code the app runs. Nothing below touches the
    // journal.
    //
    // Torn checkpoint: truncated JSON that will fail to parse on open.
    std::fs::write(dir.join("project.json"), b"{ \"formatVersion\": 1, \"tra").unwrap();

    // Hard kill: SIGKILL self, mid-save, no unwinding, no clean exit.
    unsafe {
        libc_kill(std::process::id() as i32, 9);
    }
    // If the kill somehow did not take, loop forever so the parent's
    // !success assertion still holds rather than a clean return.
    loop {
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
}

// Minimal libc kill binding (avoid adding the libc crate to timeline-core's
// dev-deps for one call).
extern "C" {
    #[link_name = "kill"]
    fn libc_kill(pid: i32, sig: i32) -> i32;
}
