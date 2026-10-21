use std::collections::BTreeMap;

use serde_json::json;
use timeline_core::cmd::Cmd;
use timeline_core::model::{TakeRecord, TakeStatus};
use timeline_core::{Bpm, Project, Source, TempoMap};

fn project_with_clip() -> Project {
    let mut p = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    p.add_source(Source {
        id: "a".into(),
        path: "a.wav".into(),
        len_frames: 480_000,
    })
    .unwrap();
    p.apply_cmd(&Cmd::TrackAdd {
        track_id: "t".into(),
        name: "Track".into(),
        index: None,
    })
    .unwrap();
    p.apply_cmd(&Cmd::ClipPlace {
        clip_id: "c".into(),
        track_id: "t".into(),
        asset_hash: "a".repeat(64),
        start_ticks: 0,
        length_ticks: 3840,
        source_offset_ticks: None,
    })
    .unwrap();
    p
}

#[test]
fn phase_anchor_inverse_round_trips() {
    let mut p = project_with_clip();
    let before = p.clone();
    let effect = p
        .apply_cmd(&Cmd::ClipPhaseAnchorSet {
            clip_id: "c".into(),
            anchor_ticks: 3840,
        })
        .unwrap();
    assert_eq!(p.track("t").unwrap().clips[0].phase_anchor_ticks, 3840);
    for inverse in effect.inverse {
        p.apply_cmd(&inverse).unwrap();
    }
    assert_eq!(p, before);
}

#[test]
fn purge_and_restore_are_journalable_inverse_commands() {
    let mut p = project_with_clip();
    p.takes.push(TakeRecord {
        take_id: "take".into(),
        request_id: "req".into(),
        source_command: "gen.revise".into(),
        asset_hashes: BTreeMap::from([(String::from("mix"), String::from("b").repeat(64))]),
        engine_identity: json!({"model": "test"}),
        status: TakeStatus::Candidate,
        promoted_into: None,
        prior_asset: None,
    });
    let before = p.clone();
    let effect = p
        .apply_cmd(&Cmd::TakePurge {
            take_id: "take".into(),
        })
        .unwrap();
    assert_eq!(p.take("take").unwrap().status, TakeStatus::Offline);
    for inverse in effect.inverse {
        p.apply_cmd(&inverse).unwrap();
    }
    assert_eq!(p, before);
}
