//! Boot-test: build a project via catalog commands, save a `.mstudio`
//! package, reopen it, and verify the reopened state matches. Also exercises
//! undo/redo and the diff-cursor. Run: `cargo run -p timeline-core --example
//! mstudio_roundtrip`.

use std::path::PathBuf;

use timeline_core::cmd::{Cmd, FadeEdge};
use timeline_core::model::FadeCurve;
use timeline_core::package::Package;
use timeline_core::session::{MetaSource, SeqMeta, Session};
use timeline_core::tempo::Bpm;
use timeline_core::{Changes, Num, Project, TempoMap};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let dir: PathBuf = std::env::temp_dir().join(format!("mstudio_boot_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);

    // A fresh project shell; project.setTempo etc. come through the journal.
    let project = Project::new(48_000, TempoMap::single(Bpm::from_int(120)?));
    let mut session = Package::create(&dir, project)?;
    let mut meta = SeqMeta::user("aaron");

    // Build a small arrangement entirely through catalog commands.
    let steps: Vec<Cmd> = vec![
        Cmd::ProjectSetTempo { bpm: Num::int(92) },
        Cmd::ProjectSetKey { key: "A minor".into() },
        Cmd::TrackAdd { track_id: "trk_drums".into(), name: "Drums".into(), index: Some(0) },
        Cmd::TrackAdd { track_id: "trk_bass".into(), name: "Bass".into(), index: Some(1) },
        Cmd::TrackSetColor { track_id: "trk_drums".into(), color: "#E05252".into() },
        Cmd::ClipPlace {
            clip_id: "clip_a".into(),
            track_id: "trk_drums".into(),
            asset_hash: "a".repeat(64),
            start_ticks: 0,
            length_ticks: 3840,
            source_offset_ticks: None,
        },
        Cmd::ClipSetGain { clip_id: "clip_a".into(), gain_db: Num::int(-3) },
        Cmd::ClipFadeSet {
            clip_id: "clip_a".into(),
            edge: FadeEdge::In,
            length_ticks: 240,
            shape: FadeCurve::Linear,
        },
        Cmd::MarkerSet {
            marker_id: "mk_1".into(),
            position_ticks: 1920,
            label: "drop".into(),
            color: None,
        },
    ];
    for cmd in steps {
        session.submit(meta.next_meta(&cmd), cmd)?;
    }

    // A transaction grouping two moves into one undo unit.
    let txn = "txn_1".to_string();
    session.submit(meta.next_meta(&Cmd::TxnBegin { txn_id: txn.clone(), reason: None }),
        Cmd::TxnBegin { txn_id: txn.clone(), reason: None })?;
    let m = Cmd::ClipMove { clip_id: "clip_a".into(), track_id: "trk_bass".into(), start_ticks: 960 };
    session.submit(meta.next_meta(&m), m)?;
    session.submit(meta.next_meta(&Cmd::TxnCommit { txn_id: txn.clone() }),
        Cmd::TxnCommit { txn_id: txn })?;

    let seq_before = session.seq();
    let snap_before = session.snapshot();
    let clip_track_before = snap_before
        .project
        .find_clip("clip_a")
        .map(|(ti, _)| snap_before.project.tracks[ti].id.clone());
    assert_eq!(clip_track_before.as_deref(), Some("trk_bass"));

    // Undo the transaction (one unit) and confirm the clip is back on drums.
    session.undo(&mut meta)?;
    let after_undo = session.snapshot();
    let clip_track_after = after_undo
        .project
        .find_clip("clip_a")
        .map(|(ti, _)| after_undo.project.tracks[ti].id.clone());
    assert_eq!(clip_track_after.as_deref(), Some("trk_drums"), "undo restores track");

    // Redo and confirm we are back.
    session.redo(&mut meta)?;
    let redone = session.snapshot();
    assert_eq!(
        redone.project.find_clip("clip_a").map(|(ti, _)| redone.project.tracks[ti].id.clone()).as_deref(),
        Some("trk_bass"),
        "redo re-applies"
    );

    // Diff-cursor: something changed since seq_before (undo+redo journaled).
    match session.changes_since(seq_before) {
        Changes::Delta(scopes) => assert!(!scopes.is_empty()),
        other => panic!("expected a delta, got {other:?}"),
    }

    // Save, then reopen from disk and compare the model.
    Package::save(&dir, &mut session)?;
    let reopened = Package::open(&dir)?;
    let a = session.snapshot();
    assert_projects_equal(&a.project, reopened.project());

    // Full crash-recovery replay (ignore the checkpoint): read the journal and
    // replay from empty, and confirm identical state.
    let envs = session.journal().to_vec();
    let replayed = Session::replay(
        Project::new(48_000, TempoMap::single(Bpm::from_int(120)?)),
        envs,
    )?;
    assert_projects_equal(&a.project, replayed.project());

    println!(
        "boot-test OK: {} journal entries, tip {}, reopened + full-replay match",
        session.seq(),
        &session.tip_hash()[..12]
    );
    let _ = std::fs::remove_dir_all(&dir);
    Ok(())
}

fn assert_projects_equal(a: &Project, b: &Project) {
    // Compare the catalog-canonical, machine-independent view (frame fields
    // are derived, so compare ticks + attributes, not materialized frames).
    assert_eq!(a.bpm_wire, b.bpm_wire, "bpm");
    assert_eq!(a.key, b.key, "key");
    assert_eq!(a.tracks.len(), b.tracks.len(), "track count");
    for (ta, tb) in a.tracks.iter().zip(&b.tracks) {
        assert_eq!(ta.id, tb.id);
        assert_eq!(ta.name, tb.name);
        assert_eq!(ta.color, tb.color);
        assert_eq!(ta.clips.len(), tb.clips.len(), "clip count on {}", ta.id);
        for (ca, cb) in ta.clips.iter().zip(&tb.clips) {
            assert_eq!(ca.id, cb.id);
            assert_eq!(ca.start_ticks, cb.start_ticks);
            assert_eq!(ca.length_ticks, cb.length_ticks);
            assert_eq!(ca.gain, cb.gain);
            assert_eq!(ca.fade_in, cb.fade_in);
        }
    }
    assert_eq!(a.markers.len(), b.markers.len(), "marker count");
}
