//! ProjectHost round trip: real WAV sources loaded through the media path,
//! every edit type applied through the command bus, then undo to the exact
//! initial state and redo to the exact edited state. Device-free (the
//! engine's output stream is never started; commands queue harmlessly).

use std::path::Path;

use render::engine::{Engine, EngineConfig};
use render::fixtures;
use render::host::ProjectHost;
use timeline_core::{Bpm, Command, FadeShape, Project, TempoMap, TrimEdge};

fn build_host() -> ProjectHost {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("host-fixtures");
    std::fs::create_dir_all(&dir).unwrap();
    fixtures::generate_all(&dir).unwrap();

    let project = Project::new(48_000, TempoMap::single(Bpm::from_int(174).unwrap()));
    let engine = Engine::new(EngineConfig::default());
    let mut host = ProjectHost::new(project, engine);
    host.load_source("click", &dir.join("click_174bpm_48k_stereo.wav"))
        .unwrap();
    host.load_source("tone", &dir.join("tone_440_48k_mono.wav"))
        .unwrap();
    host
}

fn snapshot(host: &ProjectHost) -> String {
    serde_json::to_string(&host.project).unwrap()
}

#[test]
fn full_edit_script_undoes_and_redoes_exactly() {
    let mut host = build_host();
    for (id, name) in [("t1", "A"), ("t2", "B")] {
        host.apply(&Command::TrackAdd {
            track_id: id.into(),
            name: name.into(),
            index: None,
        })
        .unwrap();
    }
    let bar1 = host.project.tempo.bar_to_tick(1);
    host.apply(&Command::ClipPlace {
        track_id: "t1".into(),
        clip_id: "c1".into(),
        source_id: "click".into(),
        start_tick: Some(0),
        start_frame: None,
        offset_frames: 0,
        len_frames: 300_000,
        gain_db: 0.0,
        fade_in_frames: 0,
        fade_out_frames: 0,
        fade_shape: FadeShape::EqualPower,
    })
    .unwrap();
    host.apply(&Command::ClipPlace {
        track_id: "t2".into(),
        clip_id: "c2".into(),
        source_id: "tone".into(),
        start_tick: Some(bar1),
        start_frame: None,
        offset_frames: 1_000,
        len_frames: 100_000,
        gain_db: -4.5,
        fade_in_frames: 2_400,
        fade_out_frames: 2_400,
        fade_shape: FadeShape::EqualPower,
    })
    .unwrap();

    let initial = snapshot(&host);
    let initial_undo_depth = host.undo_depth();

    let edits = vec![
        Command::ClipTrim {
            clip_id: "c1".into(),
            edge: TrimEdge::Start,
            to_frame: 12_345,
        },
        Command::ClipSplit {
            clip_id: "c1".into(),
            at_frame: 150_000,
            right_clip_id: "c1r".into(),
        },
        Command::ClipMove {
            clip_id: "c1r".into(),
            to_track_id: Some("t2".into()),
            to_start_tick: None,
            to_start_frame: Some(200_000),
        },
        Command::ClipSetGain {
            clip_id: "c2".into(),
            gain_db: -9.0,
        },
        Command::ClipFadeSet {
            clip_id: "c2".into(),
            fade_in_frames: Some(9_600),
            fade_out_frames: Some(4_800),
            fade_shape: Some(FadeShape::Linear),
        },
        Command::TrackMute {
            track_id: "t1".into(),
            mute: true,
        },
        Command::ClipRemove {
            clip_id: "c2".into(),
        },
    ];
    for edit in &edits {
        host.apply(edit).unwrap();
    }
    let edited = snapshot(&host);
    assert_ne!(initial, edited);
    assert_eq!(host.undo_depth(), initial_undo_depth + edits.len());

    // Undo the whole script.
    for _ in 0..edits.len() {
        assert!(host.undo().unwrap());
    }
    assert_eq!(snapshot(&host), initial, "undo restores the initial state");

    // Redo the whole script.
    for _ in 0..edits.len() {
        assert!(host.redo().unwrap());
    }
    assert_eq!(snapshot(&host), edited, "redo reproduces the edited state");

    // Undo past the bottom of the stack is a clean no-op eventually.
    while host.undo().unwrap() {}
    assert!(!host.undo().unwrap());
}

#[test]
fn failed_commands_do_not_pollute_undo() {
    let mut host = build_host();
    host.apply(&Command::TrackAdd {
        track_id: "t1".into(),
        name: "A".into(),
        index: None,
    })
    .unwrap();
    let before = snapshot(&host);
    let depth = host.undo_depth();
    let err = host.apply(&Command::ClipRemove {
        clip_id: "missing".into(),
    });
    assert!(err.is_err());
    assert_eq!(host.undo_depth(), depth);
    assert_eq!(snapshot(&host), before);
}

#[test]
fn transport_commands_route_without_touching_undo() {
    let mut host = build_host();
    host.apply(&Command::TrackAdd {
        track_id: "t1".into(),
        name: "A".into(),
        index: None,
    })
    .unwrap();
    let depth = host.undo_depth();
    for command in [
        Command::TransportPlay {},
        Command::TransportSeek {
            to_tick: Some(host.project.tempo.bar_to_tick(2)),
            to_frame: None,
        },
        Command::TransportLoopSet {
            start_tick: 0,
            end_tick: host.project.tempo.bar_to_tick(1),
        },
        Command::TransportLoopClear {},
        Command::TransportStop {},
    ] {
        host.apply(&command).unwrap();
    }
    assert_eq!(host.undo_depth(), depth, "transport is not undoable");
}
