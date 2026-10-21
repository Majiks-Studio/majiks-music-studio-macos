//! Command bus tests: catalog serialization, inverse round-trips, typed
//! errors with no partial apply.

use timeline_core::{Bpm, Command, FadeShape, Project, Source, TempoMap, TrimEdge};

fn project() -> Project {
    let mut p = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    p.add_source(Source {
        id: "src-a".into(),
        path: "fixtures/a.wav".into(),
        len_frames: 480_000,
    })
    .unwrap();
    p.add_source(Source {
        id: "src-b".into(),
        path: "fixtures/b.wav".into(),
        len_frames: 96_000,
    })
    .unwrap();
    for (id, name) in [("t1", "Drums"), ("t2", "Bass")] {
        p.apply(&Command::TrackAdd {
            track_id: id.into(),
            name: name.into(),
            index: None,
        })
        .unwrap();
    }
    p
}

fn place(p: &mut Project, clip: &str, track: &str, bar: u64, len: u64) {
    let tick = p.tempo.bar_to_tick(bar);
    p.apply(&Command::ClipPlace {
        track_id: track.into(),
        clip_id: clip.into(),
        source_id: "src-a".into(),
        start_tick: Some(tick),
        start_frame: None,
        offset_frames: 0,
        len_frames: len,
        gain_db: 0.0,
        fade_in_frames: 0,
        fade_out_frames: 0,
        fade_shape: FadeShape::EqualPower,
    })
    .unwrap();
}

fn apply_inverse_restores(p: &Project, command: Command) {
    let mut work = p.clone();
    let applied = work.apply(&command).expect("command applies");
    assert!(command.is_undoable());
    assert!(!applied.inverse.is_empty(), "undoable command has inverses");
    for inverse in &applied.inverse {
        work.apply(inverse).expect("inverse applies");
    }
    assert_eq!(&work, p, "inverse restores the exact prior state");
}

#[test]
fn serialization_uses_catalog_names() {
    let cases: Vec<(Command, &str)> = vec![
        (
            Command::ClipMove {
                clip_id: "c1".into(),
                to_track_id: None,
                to_start_tick: Some(3840),
                to_start_frame: None,
            },
            "clip.move",
        ),
        (
            Command::ClipFadeSet {
                clip_id: "c1".into(),
                fade_in_frames: Some(240),
                fade_out_frames: None,
                fade_shape: Some(FadeShape::EqualPower),
            },
            "clip.fade.set",
        ),
        (
            Command::ClipSetGain {
                clip_id: "c1".into(),
                gain_db: -6.0,
            },
            "clip.setGain",
        ),
        (Command::TransportPlay {}, "transport.play"),
        (
            Command::TransportLoopSet {
                start_tick: 0,
                end_tick: 3840,
            },
            "transport.loop.set",
        ),
    ];
    for (command, expected) in cases {
        let value = serde_json::to_value(&command).unwrap();
        assert_eq!(value["name"], expected);
        assert_eq!(command.name(), expected);
        let back: Command = serde_json::from_value(value).unwrap();
        assert_eq!(back, command);
    }
}

#[test]
fn unknown_command_name_is_a_typed_parse_error() {
    let raw = r#"{"name":"clip.teleport","params":{"clip_id":"c1"}}"#;
    assert!(serde_json::from_str::<Command>(raw).is_err());
}

#[test]
fn every_editing_command_inverts_exactly() {
    let mut p = project();
    place(&mut p, "c1", "t1", 0, 96_000);
    place(&mut p, "c2", "t1", 2, 48_000);
    place(&mut p, "c3", "t2", 1, 200_000);
    p.apply(&Command::ClipFadeSet {
        clip_id: "c1".into(),
        fade_in_frames: Some(240),
        fade_out_frames: Some(4_800),
        fade_shape: None,
    })
    .unwrap();

    apply_inverse_restores(
        &p,
        Command::ClipPlace {
            track_id: "t2".into(),
            clip_id: "c9".into(),
            source_id: "src-b".into(),
            start_tick: Some(p.tempo.bar_to_tick(4)),
            start_frame: None,
            offset_frames: 1_000,
            len_frames: 90_000,
            gain_db: -3.0,
            fade_in_frames: 100,
            fade_out_frames: 200,
            fade_shape: FadeShape::Linear,
        },
    );
    apply_inverse_restores(&p, Command::ClipRemove { clip_id: "c2".into() });
    apply_inverse_restores(
        &p,
        Command::ClipMove {
            clip_id: "c2".into(),
            to_track_id: Some("t2".into()),
            to_start_tick: Some(p.tempo.bar_to_tick(8)),
            to_start_frame: None,
        },
    );
    apply_inverse_restores(
        &p,
        Command::ClipTrim {
            clip_id: "c1".into(),
            edge: TrimEdge::Start,
            to_frame: 10_123,
        },
    );
    apply_inverse_restores(
        &p,
        Command::ClipTrim {
            clip_id: "c1".into(),
            edge: TrimEdge::End,
            to_frame: 80_001,
        },
    );
    apply_inverse_restores(
        &p,
        Command::ClipSplit {
            clip_id: "c1".into(),
            at_frame: 33_333,
            right_clip_id: "c1r".into(),
        },
    );
    apply_inverse_restores(
        &p,
        Command::ClipSetGain {
            clip_id: "c3".into(),
            gain_db: -12.5,
        },
    );
    apply_inverse_restores(
        &p,
        Command::ClipFadeSet {
            clip_id: "c3".into(),
            fade_in_frames: Some(999),
            fade_out_frames: None,
            fade_shape: Some(FadeShape::Linear),
        },
    );
    apply_inverse_restores(
        &p,
        Command::TrackAdd {
            track_id: "t3".into(),
            name: "Lead".into(),
            index: Some(1),
        },
    );
    apply_inverse_restores(
        &p,
        Command::TrackMute {
            track_id: "t1".into(),
            mute: true,
        },
    );

    // track.remove on an empty track.
    let mut p2 = p.clone();
    p2.apply(&Command::TrackAdd {
        track_id: "t4".into(),
        name: "Empty".into(),
        index: Some(0),
    })
    .unwrap();
    apply_inverse_restores(&p2, Command::TrackRemove { track_id: "t4".into() });
}

#[test]
fn trim_start_reanchors_source_content() {
    let mut p = project();
    place(&mut p, "c1", "t1", 0, 96_000);
    // Content at timeline frame F reads source frame offset + (F - start).
    // After a start trim the same timeline frame must read the same source
    // frame.
    let probe_timeline_frame = 50_000_u64;
    let before = {
        let c = p.clip("c1").unwrap();
        c.offset_frames + (probe_timeline_frame - c.start_frame)
    };
    p.apply(&Command::ClipTrim {
        clip_id: "c1".into(),
        edge: TrimEdge::Start,
        to_frame: 20_000,
    })
    .unwrap();
    let after = {
        let c = p.clip("c1").unwrap();
        assert_eq!(c.start_frame, 20_000);
        assert_eq!(c.offset_frames, 20_000);
        assert_eq!(c.len_frames, 76_000);
        c.offset_frames + (probe_timeline_frame - c.start_frame)
    };
    assert_eq!(before, after);
}

#[test]
fn split_partitions_content_without_gaps() {
    let mut p = project();
    place(&mut p, "c1", "t1", 0, 96_000);
    p.apply(&Command::ClipSplit {
        clip_id: "c1".into(),
        at_frame: 40_000,
        right_clip_id: "c1r".into(),
    })
    .unwrap();
    let left = p.clip("c1").unwrap().clone();
    let right = p.clip("c1r").unwrap().clone();
    assert_eq!(left.start_frame, 0);
    assert_eq!(left.len_frames, 40_000);
    assert_eq!(right.start_frame, 40_000);
    assert_eq!(right.len_frames, 56_000);
    assert_eq!(right.offset_frames, 40_000);
    assert_eq!(left.end_frame(), right.start_frame);
}

#[test]
fn typed_errors_and_no_partial_apply() {
    let mut p = project();
    place(&mut p, "c1", "t1", 0, 96_000);
    let snapshot = p.clone();

    let cases = vec![
        Command::ClipPlace {
            track_id: "missing".into(),
            clip_id: "cx".into(),
            source_id: "src-a".into(),
            start_tick: Some(0),
            start_frame: None,
            offset_frames: 0,
            len_frames: 1,
            gain_db: 0.0,
            fade_in_frames: 0,
            fade_out_frames: 0,
            fade_shape: FadeShape::EqualPower,
        },
        // Reads past source end.
        Command::ClipPlace {
            track_id: "t1".into(),
            clip_id: "cx".into(),
            source_id: "src-b".into(),
            start_tick: Some(0),
            start_frame: None,
            offset_frames: 90_000,
            len_frames: 10_000,
            gain_db: 0.0,
            fade_in_frames: 0,
            fade_out_frames: 0,
            fade_shape: FadeShape::EqualPower,
        },
        // Both position fields set.
        Command::ClipPlace {
            track_id: "t1".into(),
            clip_id: "cx".into(),
            source_id: "src-a".into(),
            start_tick: Some(0),
            start_frame: Some(0),
            offset_frames: 0,
            len_frames: 1,
            gain_db: 0.0,
            fade_in_frames: 0,
            fade_out_frames: 0,
            fade_shape: FadeShape::EqualPower,
        },
        // Duplicate clip id.
        Command::ClipPlace {
            track_id: "t1".into(),
            clip_id: "c1".into(),
            source_id: "src-a".into(),
            start_tick: Some(0),
            start_frame: None,
            offset_frames: 0,
            len_frames: 1,
            gain_db: 0.0,
            fade_in_frames: 0,
            fade_out_frames: 0,
            fade_shape: FadeShape::EqualPower,
        },
        Command::ClipRemove {
            clip_id: "missing".into(),
        },
        // Start trim past the clip end.
        Command::ClipTrim {
            clip_id: "c1".into(),
            edge: TrimEdge::Start,
            to_frame: 96_000,
        },
        // Start trim before source frame zero.
        Command::ClipTrim {
            clip_id: "c1".into(),
            edge: TrimEdge::Start,
            to_frame: u64::MAX,
        },
        // End trim past source content.
        Command::ClipTrim {
            clip_id: "c1".into(),
            edge: TrimEdge::End,
            to_frame: 480_001,
        },
        // Split on the boundary is not strictly inside.
        Command::ClipSplit {
            clip_id: "c1".into(),
            at_frame: 0,
            right_clip_id: "cr".into(),
        },
        Command::ClipSplit {
            clip_id: "c1".into(),
            at_frame: 96_000,
            right_clip_id: "cr".into(),
        },
        // Split right id collides.
        Command::ClipSplit {
            clip_id: "c1".into(),
            at_frame: 10,
            right_clip_id: "c1".into(),
        },
        Command::ClipSetGain {
            clip_id: "c1".into(),
            gain_db: f32::NAN,
        },
        Command::ClipSetGain {
            clip_id: "c1".into(),
            gain_db: 100.0,
        },
        // Fade longer than the clip.
        Command::ClipFadeSet {
            clip_id: "c1".into(),
            fade_in_frames: Some(96_001),
            fade_out_frames: None,
            fade_shape: None,
        },
        // Empty fade set.
        Command::ClipFadeSet {
            clip_id: "c1".into(),
            fade_in_frames: None,
            fade_out_frames: None,
            fade_shape: None,
        },
        Command::TrackAdd {
            track_id: "t1".into(),
            name: "dup".into(),
            index: None,
        },
        Command::TrackRemove {
            track_id: "t1".into(),
        },
        Command::TrackMute {
            track_id: "missing".into(),
            mute: true,
        },
        Command::TransportLoopSet {
            start_tick: 3840,
            end_tick: 3840,
        },
        Command::TransportSeek {
            to_tick: None,
            to_frame: None,
        },
    ];
    for command in cases {
        let err = p.apply(&command);
        assert!(err.is_err(), "expected error for {:?}", command.name());
        assert_eq!(p, snapshot, "failed command must not mutate the project");
    }
}

#[test]
fn transport_commands_are_valid_but_not_undoable() {
    let mut p = project();
    let snapshot = p.clone();
    for command in [
        Command::TransportPlay {},
        Command::TransportStop {},
        Command::TransportSeek {
            to_tick: Some(3840),
            to_frame: None,
        },
        Command::TransportLoopSet {
            start_tick: 0,
            end_tick: 3840,
        },
        Command::TransportLoopClear {},
    ] {
        let applied = p.apply(&command).unwrap();
        assert!(applied.inverse.is_empty());
        assert!(!command.is_undoable());
        assert!(command.is_transport());
    }
    assert_eq!(p, snapshot, "transport commands do not touch the model");
}

#[test]
fn clips_stay_sorted_after_edits() {
    let mut p = project();
    place(&mut p, "c1", "t1", 4, 10_000);
    place(&mut p, "c2", "t1", 0, 10_000);
    place(&mut p, "c3", "t1", 2, 10_000);
    let order: Vec<&str> = p.track("t1").unwrap().clips.iter().map(|c| c.id.as_str()).collect();
    assert_eq!(order, vec!["c2", "c3", "c1"]);
    p.apply(&Command::ClipMove {
        clip_id: "c1".into(),
        to_track_id: None,
        to_start_tick: Some(p.tempo.bar_to_tick(1)),
        to_start_frame: None,
    })
    .unwrap();
    let order: Vec<&str> = p.track("t1").unwrap().clips.iter().map(|c| c.id.as_str()).collect();
    assert_eq!(order, vec!["c2", "c1", "c3"]);
}
