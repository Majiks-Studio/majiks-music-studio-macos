//! E1: MIDI notes — behaviour, not structure.
//!
//! Every assertion here is on REAL DATA: where notes actually land, what the
//! model actually holds after an undo, what bytes a checkpoint actually
//! carries. "The struct has a field" proves nothing; the solo bug shipped for
//! months because a UI-state test passed while nothing was audible.
//!
//! Mutation checks for these live in `notes_mutation.rs`.

#[path = "support.rs"]
mod support;

use serde_json::json;
use timeline_core::catalog::Catalog;
use timeline_core::cmd::{Cmd, NoteEdge, NoteSpec, NoteTiming, TrimEdgeWire};
use timeline_core::error::CommandError;
use timeline_core::model::{ClipKind, Project, Track};
use timeline_core::num::Num;
use timeline_core::tempo::{Bpm, TempoMap};
use timeline_core::Source;

fn project() -> Project {
    let mut p = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    p.add_source(Source {
        id: "a".repeat(64),
        path: "/tmp/a.wav".into(),
        len_frames: 48_000 * 600,
    })
    .unwrap();
    p.tracks.push(Track::new("t1", "Keys"));
    p
}

fn with_midi_clip() -> Project {
    let mut p = project();
    p.apply_cmd(&Cmd::ClipPlaceMidi {
        clip_id: "cm1".into(),
        track_id: "t1".into(),
        start_ticks: 0,
        length_ticks: 3840,
    })
    .expect("place midi clip");
    p
}

fn spec(id: &str, start: u64, len: u64, pitch: u8, vel: i64) -> NoteSpec {
    NoteSpec {
        note_id: id.into(),
        start_ticks: start,
        length_ticks: len,
        pitch,
        velocity: Num::int(vel),
    }
}

fn add(p: &mut Project, specs: Vec<NoteSpec>) {
    p.apply_cmd(&Cmd::NoteAdd {
        clip_id: "cm1".into(),
        notes: specs,
    })
    .expect("note.add");
}

/// The property that matters for every undoable command: applying the full
/// inverse sequence returns the model to an EXACT, structural equal.
fn assert_inverse_is_exact(p: &mut Project, cmd: Cmd) {
    let name = cmd.name();
    let pre = p.clone();
    let effect = p
        .apply_cmd(&cmd)
        .unwrap_or_else(|e| panic!("{name} should apply: {e}"));
    assert!(
        effect.hint.is_some(),
        "{name} is undoable, so session.rs:319-323 hard-errors without a hint"
    );
    assert!(
        !effect.inverse.is_empty(),
        "{name} produced an empty inverse"
    );
    for inv in &effect.inverse {
        p.apply_cmd(inv)
            .unwrap_or_else(|e| panic!("inverse {} of {name} failed: {e}", inv.name()));
    }
    assert_eq!(&pre, p, "inverse of {name} did not restore the exact state");
}

// ---------------------------------------------------------------------------
// The clip discriminator is ADDITIVE: an audio clip is untouched.
// ---------------------------------------------------------------------------

#[test]
fn an_audio_clip_is_bit_identical_before_and_after_e1() {
    // The v1.1 clip path must not gain a single byte. The checkpoint writer is
    // hand-built, so this is the assertion that actually pins it.
    let mut p = project();
    p.apply_cmd(&Cmd::ClipPlace {
        clip_id: "c1".into(),
        track_id: "t1".into(),
        asset_hash: "a".repeat(64),
        start_ticks: 0,
        length_ticks: 1920,
        source_offset_ticks: Some(0),
    })
    .unwrap();
    let session = timeline_core::session::Session::new(p);
    let cp = timeline_core::package::to_project_json(&session);
    let clip = &cp["clips"][0];
    assert!(
        clip.get("kind").is_none(),
        "an audio clip must not gain a `kind` key: {clip}"
    );
    assert!(
        clip.get("notes").is_none(),
        "an audio clip must not gain a `notes` key: {clip}"
    );
    assert_eq!(clip["assetHash"], json!("a".repeat(64)));
}

#[test]
fn a_note_clip_round_trips_through_the_checkpoint_with_its_notes() {
    let mut p = with_midi_clip();
    add(
        &mut p,
        vec![spec("n1", 480, 240, 60, 100), spec("n2", 0, 480, 67, 90)],
    );
    let session = timeline_core::session::Session::new(p.clone());
    let cp = timeline_core::package::to_project_json(&session);
    let clip = &cp["clips"][0];
    assert_eq!(clip["kind"], json!("midi"));
    assert!(
        clip.get("assetHash").is_none(),
        "a note clip has no audio asset, and a sentinel hash would make \
         mark_offline flag it offline"
    );
    // Serialized in the model's total order (start, pitch, id), not insert order.
    assert_eq!(
        clip["notes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|n| n["noteId"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["n2", "n1"]
    );
    // Integer velocity stays an INTEGER token: 90, never 90.0. The hash chain
    // depends on that shape.
    assert_eq!(
        serde_json::to_string(&clip["notes"][0]["velocity"]).unwrap(),
        "90"
    );

    let back = timeline_core::package::from_project_json(&cp).expect("reload");
    assert_eq!(back.tracks[0].clips[0], p.tracks[0].clips[0]);
}

#[test]
fn an_unknown_per_note_field_survives_load_and_save() {
    // Design §9.3's lesson: without an `extra` map a future field is
    // DESTROYED, not merely ignored.
    let mut p = with_midi_clip();
    add(&mut p, vec![spec("n1", 0, 480, 60, 100)]);
    let session = timeline_core::session::Session::new(p);
    let mut cp = timeline_core::package::to_project_json(&session);
    cp["clips"][0]["notes"][0]
        .as_object_mut()
        .unwrap()
        .insert("mpeTimbre".into(), json!(0.42));

    let reloaded = timeline_core::package::from_project_json(&cp).expect("reload");
    assert_eq!(
        reloaded.tracks[0].clips[0].notes[0].extra["mpeTimbre"],
        json!(0.42)
    );
    let s2 = timeline_core::session::Session::new(reloaded);
    let cp2 = timeline_core::package::to_project_json(&s2);
    assert_eq!(
        cp2["clips"][0]["notes"][0]["mpeTimbre"],
        json!(0.42),
        "a future per-note field was destroyed on save"
    );
}

// ---------------------------------------------------------------------------
// Ordering
// ---------------------------------------------------------------------------

#[test]
fn ordering_is_identical_across_insert_orders() {
    // Same five notes, three different insertion orders, one canonical result
    // — including two notes that differ ONLY by id and two that differ ONLY by
    // pitch, which is where a partial sort key would show.
    let specs = |order: [usize; 5]| {
        let all = [
            spec("nb", 0, 240, 60, 100),
            spec("na", 0, 240, 60, 100),
            spec("nc", 0, 240, 59, 100),
            spec("nd", 960, 240, 12, 100),
            spec("ne", 480, 240, 72, 100),
        ];
        order.map(|i| all[i].clone()).to_vec()
    };
    let render = |order: [usize; 5]| {
        let mut p = with_midi_clip();
        for s in specs(order) {
            add(&mut p, vec![s]);
        }
        p.tracks[0].clips[0]
            .notes
            .iter()
            .map(|n| n.id.clone())
            .collect::<Vec<_>>()
    };
    let canonical = ["nc", "na", "nb", "ne", "nd"];
    assert_eq!(render([0, 1, 2, 3, 4]), canonical);
    assert_eq!(render([4, 3, 2, 1, 0]), canonical);
    assert_eq!(render([2, 0, 4, 1, 3]), canonical);

    // And a single batched add lands in the same order as five singles.
    let mut batched = with_midi_clip();
    add(&mut batched, specs([3, 1, 4, 2, 0]));
    assert_eq!(
        batched.tracks[0].clips[0]
            .notes
            .iter()
            .map(|n| n.id.as_str())
            .collect::<Vec<_>>(),
        canonical
    );
}

// ---------------------------------------------------------------------------
// Inverse exactness, per command
// ---------------------------------------------------------------------------

#[test]
fn every_note_command_inverse_restores_the_exact_prestate() {
    let mut p = with_midi_clip();
    add(
        &mut p,
        vec![
            spec("n1", 0, 480, 60, 100),
            spec("n2", 0, 480, 64, 90),
            spec("n3", 1920, 240, 67, 80),
        ],
    );

    assert_inverse_is_exact(
        &mut p,
        Cmd::NoteAdd {
            clip_id: "cm1".into(),
            notes: vec![spec("n4", 2880, 480, 72, 110)],
        },
    );
    assert_inverse_is_exact(
        &mut p,
        Cmd::NoteRemove {
            clip_id: "cm1".into(),
            note_ids: vec!["n1".into(), "n3".into()],
        },
    );
    assert_inverse_is_exact(
        &mut p,
        Cmd::NoteMove {
            clip_id: "cm1".into(),
            note_ids: vec!["n1".into(), "n2".into()],
            delta_ticks: 480,
            delta_pitch: -5,
        },
    );
    assert_inverse_is_exact(
        &mut p,
        Cmd::NoteResize {
            clip_id: "cm1".into(),
            note_ids: vec!["n1".into(), "n2".into()],
            edge: NoteEdge::Leading,
            delta_ticks: 120,
        },
    );
    assert_inverse_is_exact(
        &mut p,
        Cmd::NoteResize {
            clip_id: "cm1".into(),
            note_ids: vec!["n3".into()],
            edge: NoteEdge::Trailing,
            delta_ticks: -120,
        },
    );
    assert_inverse_is_exact(
        &mut p,
        Cmd::NoteVelocitySet {
            clip_id: "cm1".into(),
            note_ids: vec!["n1".into(), "n2".into(), "n3".into()],
            delta_velocity: -20,
        },
    );
    assert_inverse_is_exact(
        &mut p,
        Cmd::NoteDuplicate {
            clip_id: "cm1".into(),
            note_ids: vec!["n1".into(), "n2".into()],
            new_note_ids: vec!["d1".into(), "d2".into()],
            delta_ticks: 960,
            delta_pitch: 12,
        },
    );
}

#[test]
fn note_remove_inverse_is_deterministic_regardless_of_caller_array_order() {
    // A journaled inverse must not depend on how the UI happened to order its
    // selection, or two identical edits would hash differently.
    let build = |order: Vec<&str>| {
        let mut p = with_midi_clip();
        add(
            &mut p,
            vec![
                spec("n1", 0, 480, 60, 100),
                spec("n2", 0, 480, 64, 90),
                spec("n3", 960, 480, 67, 80),
            ],
        );
        let e = p
            .apply_cmd(&Cmd::NoteRemove {
                clip_id: "cm1".into(),
                note_ids: order.into_iter().map(String::from).collect(),
            })
            .unwrap();
        e.hint.unwrap().params_value()
    };
    assert_eq!(
        build(vec!["n3", "n1", "n2"]),
        build(vec!["n1", "n2", "n3"]),
        "the inverse payload must be a function of the model, not of the caller's array"
    );
}

// ---------------------------------------------------------------------------
// The no-clamping rule (this is what makes delta commands self-inverse)
// ---------------------------------------------------------------------------

#[test]
fn a_batch_that_would_leave_the_pitch_range_is_refused_whole_and_not_clamped() {
    let mut p = with_midi_clip();
    add(
        &mut p,
        vec![
            spec("low", 0, 480, 2, 100),
            spec("mid", 0, 480, 40, 100),
            spec("high", 0, 480, 80, 100),
        ],
    );
    let before = p.clone();
    let err = p
        .apply_cmd(&Cmd::NoteMove {
            clip_id: "cm1".into(),
            note_ids: vec!["low".into(), "mid".into(), "high".into()],
            delta_ticks: 0,
            delta_pitch: -10, // "low" would land at -8
        })
        .expect_err("must refuse rather than clamp");
    assert!(matches!(err, CommandError::OutOfRange(_)), "{err:?}");
    assert_eq!(
        before, p,
        "a refused batch must not partially apply — the chord's voicing is intact"
    );
    // The whole point: had it clamped, `low` would sit at 0 and the inverse
    // (+10) would put it at 10, not 2. Prove the round trip is exact when the
    // move IS legal.
    p.apply_cmd(&Cmd::NoteMove {
        clip_id: "cm1".into(),
        note_ids: vec!["low".into(), "mid".into(), "high".into()],
        delta_ticks: 0,
        delta_pitch: -2,
    })
    .unwrap();
    p.apply_cmd(&Cmd::NoteMove {
        clip_id: "cm1".into(),
        note_ids: vec!["low".into(), "mid".into(), "high".into()],
        delta_ticks: 0,
        delta_pitch: 2,
    })
    .unwrap();
    assert_eq!(before, p);
}

#[test]
fn velocity_saturation_is_refused_not_clamped() {
    let mut p = with_midi_clip();
    add(&mut p, vec![spec("n1", 0, 480, 60, 120)]);
    let before = p.clone();
    let err = p
        .apply_cmd(&Cmd::NoteVelocitySet {
            clip_id: "cm1".into(),
            note_ids: vec!["n1".into()],
            delta_velocity: 10,
        })
        .expect_err("130 is out of range");
    assert!(matches!(err, CommandError::OutOfRange(_)), "{err:?}");
    assert_eq!(before, p);
}

#[test]
fn a_move_that_would_cross_tick_zero_is_refused() {
    let mut p = with_midi_clip();
    add(&mut p, vec![spec("n1", 240, 480, 60, 100)]);
    let before = p.clone();
    assert!(p
        .apply_cmd(&Cmd::NoteMove {
            clip_id: "cm1".into(),
            note_ids: vec!["n1".into()],
            delta_ticks: -480,
            delta_pitch: 0,
        })
        .is_err());
    assert_eq!(before, p);
}

#[test]
fn a_resize_to_zero_or_negative_length_is_refused() {
    let mut p = with_midi_clip();
    add(&mut p, vec![spec("n1", 0, 480, 60, 100)]);
    let before = p.clone();
    for delta in [-480i64, -960] {
        assert!(
            p.apply_cmd(&Cmd::NoteResize {
                clip_id: "cm1".into(),
                note_ids: vec!["n1".into()],
                edge: NoteEdge::Trailing,
                delta_ticks: delta,
            })
            .is_err(),
            "a zero-length note must never be stored"
        );
    }
    assert_eq!(before, p);
}

// ---------------------------------------------------------------------------
// Kind guards
// ---------------------------------------------------------------------------

#[test]
fn notes_are_refused_on_an_audio_clip_and_audio_ops_on_a_note_clip() {
    let mut p = with_midi_clip();
    p.apply_cmd(&Cmd::ClipPlace {
        clip_id: "ca".into(),
        track_id: "t1".into(),
        asset_hash: "a".repeat(64),
        start_ticks: 7680,
        length_ticks: 1920,
        source_offset_ticks: Some(0),
    })
    .unwrap();

    let err = p
        .apply_cmd(&Cmd::NoteAdd {
            clip_id: "ca".into(),
            notes: vec![spec("n1", 0, 480, 60, 100)],
        })
        .expect_err("notes do not belong on an audio clip");
    assert!(matches!(err, CommandError::InvalidParams(_)), "{err:?}");

    // ... and the mirror: audio-only edits refuse a note clip rather than
    // writing state that means nothing.
    assert!(p
        .apply_cmd(&Cmd::ClipFadeSet {
            clip_id: "cm1".into(),
            edge: timeline_core::cmd::FadeEdge::In,
            length_ticks: 240,
            shape: timeline_core::model::FadeCurve::Linear,
        })
        .is_err());
    assert!(p
        .apply_cmd(&Cmd::ClipWarpSet {
            clip_id: "cm1".into(),
            mode: timeline_core::model::WarpMode::Conform,
            stretch_ratio: None,
        })
        .is_err());
    assert!(
        p.apply_cmd(&Cmd::ClipTrim {
            clip_id: "cm1".into(),
            edge: TrimEdgeWire::Start,
            delta_ticks: 240,
        })
        .is_err(),
        "E1 refuses a start-edge trim on a note clip (documented limitation)"
    );
    // The end edge does work — that is the common crop.
    assert!(p
        .apply_cmd(&Cmd::ClipTrim {
            clip_id: "cm1".into(),
            edge: TrimEdgeWire::End,
            delta_ticks: -960,
        })
        .is_ok());
    assert_eq!(p.clip("cm1").unwrap().length_ticks, 2880);
    assert_eq!(
        p.clip("cm1").unwrap().source_offset_ticks,
        0,
        "a note clip's content offset stays pinned at 0"
    );
}

// ---------------------------------------------------------------------------
// Clip machinery composes (§1: notes live on a clip so this works for free)
// ---------------------------------------------------------------------------

#[test]
fn clip_remove_and_undo_restores_every_note_exactly() {
    let mut p = with_midi_clip();
    add(
        &mut p,
        vec![
            spec("n1", 0, 480, 60, 100),
            spec("n2", 480, 480, 64, 88),
            spec("n3", 960, 480, 67, 77),
        ],
    );
    assert_inverse_is_exact(&mut p, Cmd::ClipRemove {
        clip_id: "cm1".into(),
    });
}

#[test]
fn clip_duplicate_copies_the_notes_and_reuses_their_ids() {
    let mut p = with_midi_clip();
    add(&mut p, vec![spec("n1", 0, 480, 60, 100)]);
    p.apply_cmd(&Cmd::ClipDuplicate {
        clip_id: "cm1".into(),
        new_clip_id: "cm2".into(),
        start_ticks: 3840,
    })
    .unwrap();
    let copy = p.clip("cm2").unwrap();
    assert_eq!(copy.kind, ClipKind::Midi);
    assert_eq!(copy.notes.len(), 1);
    assert_eq!(
        copy.notes[0].id, "n1",
        "note ids are unique PER CLIP, so a duplicate reuses them — minting a \
         fresh id at apply time would make replay diverge from the live model"
    );
}

#[test]
fn clip_split_partitions_notes_by_start_side_and_undo_is_exact() {
    let mut p = with_midi_clip();
    add(
        &mut p,
        vec![
            spec("left", 0, 480, 60, 100),
            // straddles the split at 1920: assigned to the side holding its START
            spec("straddle", 1440, 960, 62, 100),
            spec("right", 2400, 480, 64, 100),
        ],
    );
    assert_inverse_is_exact(&mut p, Cmd::ClipSplit {
        clip_id: "cm1".into(),
        at_ticks: 1920,
        new_clip_id: "cm2".into(),
    });

    // Re-apply and inspect the partition itself.
    p.apply_cmd(&Cmd::ClipSplit {
        clip_id: "cm1".into(),
        at_ticks: 1920,
        new_clip_id: "cm2".into(),
    })
    .unwrap();
    let left: Vec<&str> = p
        .clip("cm1")
        .unwrap()
        .notes
        .iter()
        .map(|n| n.id.as_str())
        .collect();
    let right = p.clip("cm2").unwrap();
    assert_eq!(left, ["left", "straddle"]);
    assert_eq!(
        right.notes.iter().map(|n| n.id.as_str()).collect::<Vec<_>>(),
        ["right"]
    );
    assert_eq!(
        right.notes[0].start_ticks, 480,
        "the right piece's notes are rebased to its own clip origin"
    );
}

// ---------------------------------------------------------------------------
// The catalog gates (design §9.5)
// ---------------------------------------------------------------------------

#[test]
fn every_new_command_declares_a_consistent_catalog_entry() {
    for name in [
        "clip.placeMidi",
        "note.add",
        "note.remove",
        "note.move",
        "note.resize",
        "note.velocity.set",
        "note.duplicate",
        "note.timing.set",
        "note.quantize",
    ] {
        let spec = Catalog::get()
            .spec(name)
            .unwrap_or_else(|| panic!("{name} missing from the catalog"));
        assert!(spec.journaled, "{name} must be journaled");
        assert!(spec.undoable, "{name} must be undoable");
    }
    // add/remove/duplicate genuinely CANNOT be self-inverse: undoing an add is
    // a removal. Declaring `self` there would be a contract lie.
    for (name, target) in [
        ("note.add", "note.remove"),
        ("note.remove", "note.add"),
        ("note.duplicate", "note.remove"),
        ("clip.placeMidi", "clip.remove"),
        // Quantize CANNOT be self-inverse: each note travels its own distance,
        // so there is no delta to negate. Declaring `self` here would be the
        // contract lie that makes undo land on the grid instead of on the
        // performance.
        ("note.quantize", "note.timing.set"),
    ] {
        let spec = Catalog::get().spec(name).unwrap();
        assert_eq!(
            spec.inverse_mode,
            timeline_core::catalog::InverseMode::Explicit,
            "{name} must declare an explicit inverse"
        );
        assert_eq!(spec.inverse_name.as_deref(), Some(target));
    }
    // The delta commands ARE self-inverse, which is the whole reason they are
    // delta-shaped.
    // `note.timing.set` is self-inverse for the OTHER reason the mode admits:
    // it is absolute, so its inverse is the same command carrying the
    // pre-state values (the `clip.move` pattern), not a negated delta.
    for name in [
        "note.move",
        "note.resize",
        "note.velocity.set",
        "note.timing.set",
    ] {
        assert_eq!(
            Catalog::get().spec(name).unwrap().inverse_mode,
            timeline_core::catalog::InverseMode::SelfInverse,
            "{name} must be self-inverse"
        );
    }
}

#[test]
fn a_float_shaped_velocity_is_rejected_at_apply_time() {
    // FINDING: a JSON Schema `integer` accepts 100.0 (it means "zero
    // fractional part", not "integer token"), so the catalog CANNOT enforce
    // the wire shape on its own. Pinned in both directions here.
    let cat = Catalog::get();
    let float_vel = json!({"clipId": "cm1", "notes": [
        {"noteId": "n", "startTicks": 0, "lengthTicks": 480, "pitch": 60, "velocity": 100.0}
    ]});
    assert!(
        cat.validate_params("note.add", &float_vel).is_ok(),
        "this is the gap: the schema lets 100.0 through"
    );
    // ...so apply.rs is where it stops, exactly like E0's ParamRef mitigation.
    let mut p = with_midi_clip();
    let cmd = Cmd::from_wire("note.add", float_vel).expect("parses");
    let before = p.clone();
    let err = p.apply_cmd(&cmd).expect_err("float velocity must be refused");
    assert!(matches!(err, CommandError::InvalidParams(_)), "{err:?}");
    assert_eq!(before, p);

    assert!(cat
        .validate_params(
            "note.add",
            &json!({"clipId": "c", "notes": [
                {"noteId": "n", "startTicks": 0, "lengthTicks": 480, "pitch": 60, "velocity": 100}
            ]})
        )
        .is_ok());
    assert!(cat
        .validate_params(
            "note.add",
            &json!({"clipId": "c", "notes": [
                {"noteId": "n", "startTicks": 0, "lengthTicks": 0, "pitch": 60, "velocity": 100}
            ]})
        )
        .is_err(), "zero length must be rejected by the schema too");
    assert!(cat
        .validate_params(
            "note.move",
            &json!({"clipId": "c", "noteIds": [], "deltaTicks": 0, "deltaPitch": 0})
        )
        .is_err(), "an empty batch is meaningless");
}

#[test]
fn a_journaled_note_edit_replays_to_the_same_chain_and_model() {
    use timeline_core::envelope::Actor;
    use timeline_core::session::{Session, SeqMeta};

    let mut session = Session::new(project());
    let mut n = 1u64;
    for cmd in [
        Cmd::TrackAdd {
            track_id: "t2".into(),
            name: "Keys 2".into(),
            index: None,
        },
        Cmd::ClipPlaceMidi {
            clip_id: "cm1".into(),
            track_id: "t2".into(),
            start_ticks: 0,
            length_ticks: 3840,
        },
        Cmd::NoteAdd {
            clip_id: "cm1".into(),
            notes: vec![spec("n1", 0, 480, 60, 100), spec("n2", 0, 480, 64, 100)],
        },
        Cmd::NoteMove {
            clip_id: "cm1".into(),
            note_ids: vec!["n1".into(), "n2".into()],
            delta_ticks: 240,
            delta_pitch: 3,
        },
        Cmd::NoteVelocitySet {
            clip_id: "cm1".into(),
            note_ids: vec!["n1".into()],
            delta_velocity: -15,
        },
    ] {
        session.submit(support::user_meta(n), cmd).expect("submit");
        n += 1;
    }
    let journal = session.journal().to_vec();
    let replayed = Session::replay(
        Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap())),
        journal,
    )
    .expect("replay");
    // The replayed project starts without the source; compare the note content.
    assert_eq!(
        replayed.project().clip("cm1").unwrap().notes,
        session.project().clip("cm1").unwrap().notes
    );
    assert_eq!(session.tip_hash(), replayed.tip_hash());

    // And the velocities are still integer-shaped after a delta round trip.
    let v = &session.project().clip("cm1").unwrap().note("n1").unwrap().velocity;
    assert_eq!(serde_json::to_string(v).unwrap(), "85");
}

#[test]
fn full_undo_of_a_note_session_returns_to_the_baseline() {
    use timeline_core::envelope::Actor;
    use timeline_core::session::{Session, SeqMeta};

    let baseline = project();
    let mut session = Session::new(baseline.clone());
    let mut n = 1u64;
    for cmd in [
        Cmd::TrackAdd {
            track_id: "t2".into(),
            name: "Keys 2".into(),
            index: None,
        },
        Cmd::ClipPlaceMidi {
            clip_id: "cm1".into(),
            track_id: "t2".into(),
            start_ticks: 0,
            length_ticks: 3840,
        },
        Cmd::NoteAdd {
            clip_id: "cm1".into(),
            notes: vec![spec("n1", 0, 480, 60, 100)],
        },
        Cmd::NoteDuplicate {
            clip_id: "cm1".into(),
            note_ids: vec!["n1".into()],
            new_note_ids: vec!["n2".into()],
            delta_ticks: 480,
            delta_pitch: 4,
        },
        Cmd::NoteResize {
            clip_id: "cm1".into(),
            note_ids: vec!["n1".into(), "n2".into()],
            edge: NoteEdge::Trailing,
            delta_ticks: 120,
        },
    ] {
        session.submit(support::user_meta(n), cmd).expect("submit");
        n += 1;
    }
    let mut meta = SeqMeta::starting_at(n, Actor::user("undo"));
    while session.undo(&mut meta).expect("undo") {}
    assert_eq!(
        session.project(),
        &baseline,
        "full undo left residue behind"
    );
}

// ---------------------------------------------------------------------------
// Devices: the registry that makes `track.device.<id>.<param>` RESOLVE
// ---------------------------------------------------------------------------

#[test]
fn an_instrument_parameter_becomes_automatable_the_moment_the_device_exists() {
    // E0 §3 promised "instrument params are already addressable and
    // automatable — E2 needs NO contract work for automation". That promise
    // needed something to resolve against: before the registry,
    // `require_param_ref` rejected every `track.device.*` path outright, so
    // the promise was one the model could not keep.
    //
    // Since the existence widening (`require_param_ref_on`'s doc;
    // `tests/undo_fidelity.rs` §7) the KEY is still gated at apply time but
    // device PRESENCE no longer is — a lane on an absent device must be
    // authorable, because the inverse of a forward-legal `autopoint.remove`
    // on a stranded lane is exactly such an add. So the "before" half of this
    // test asserts acceptance-with-exact-inverse now, and the resolve-at-
    // compile refusal lives render-side.
    let mut p = project();
    let target = timeline_core::ParamRef::parse("track.device.synth1.cutoff").unwrap();

    let autopoint = |value: i64| Cmd::AutopointAdd {
        track_id: "t1".into(),
        target: target.clone(),
        point_id: format!("ap{value}"),
        position_ticks: 0,
        value: Num::int(value),
    };

    // Before the device exists: the add LANDS (and round-trips) — the compile
    // gate, not the command bus, is where an unreadable lane is refused.
    assert_inverse_is_exact(&mut p, autopoint(1));

    // Add the device — through the catalog bus, journaled and undoable.
    assert_inverse_is_exact(
        &mut p,
        Cmd::DeviceAdd {
            track_id: "t1".into(),
            device_id: "synth1".into(),
            kind: timeline_core::model::DeviceKind::Synth,
        },
    );
    p.apply_cmd(&Cmd::DeviceAdd {
        track_id: "t1".into(),
        device_id: "synth1".into(),
        kind: timeline_core::model::DeviceKind::Synth,
    })
    .unwrap();

    // After: the SAME automation command, unchanged, now lands. No new command
    // was needed to automate an instrument — which was the whole point.
    assert_inverse_is_exact(&mut p, autopoint(2));
    p.apply_cmd(&autopoint(2)).unwrap();
    assert_eq!(
        p.track("t1").unwrap().automation.lane(&target).len(),
        1,
        "the lane exists and holds the point"
    );

    // A parameter key the build does not know is still refused: a typo that
    // the contract accepts becomes automation that silently drives nothing.
    let bogus = timeline_core::ParamRef::parse("track.device.synth1.wobble").unwrap();
    assert!(p
        .apply_cmd(&Cmd::AutopointAdd {
            track_id: "t1".into(),
            target: bogus,
            point_id: "apx".into(),
            position_ticks: 0,
            value: Num::int(0),
        })
        .is_err());

    // A lane on ANOTHER track naming this track's device id is authorable
    // (existence is not an apply-time question any more), and its inverse is
    // exact. The registry stays PER TRACK where it matters: at compile,
    // `render::compile::build_instrument` binds lane slots only from the
    // track's OWN device ids, so t2's instrument never reads a lane that
    // names t1's synth.
    p.tracks.push(Track::new("t2", "Other"));
    assert_inverse_is_exact(
        &mut p,
        Cmd::AutopointAdd {
            track_id: "t2".into(),
            target: target.clone(),
            point_id: "apy".into(),
            position_ticks: 0,
            value: Num::int(0),
        },
    );
}

#[test]
fn removing_a_device_preserves_its_automation_lane_rather_than_destroying_it() {
    // Silent data loss is the failure mode E0 §3 exists to prevent. A removed
    // device must not take an authored lane with it: undo has to give back a
    // working project.
    let mut p = project();
    let target = timeline_core::ParamRef::parse("track.device.synth1.cutoff").unwrap();
    p.apply_cmd(&Cmd::DeviceAdd {
        track_id: "t1".into(),
        device_id: "synth1".into(),
        kind: timeline_core::model::DeviceKind::Synth,
    })
    .unwrap();
    p.apply_cmd(&Cmd::AutopointAdd {
        track_id: "t1".into(),
        target: target.clone(),
        point_id: "ap1".into(),
        position_ticks: 480,
        value: Num::int(3),
    })
    .unwrap();

    assert_inverse_is_exact(
        &mut p,
        Cmd::DeviceRemove {
            track_id: "t1".into(),
            device_id: "synth1".into(),
        },
    );

    p.apply_cmd(&Cmd::DeviceRemove {
        track_id: "t1".into(),
        device_id: "synth1".into(),
    })
    .unwrap();
    assert_eq!(
        p.track("t1").unwrap().automation.lane(&target).len(),
        1,
        "the lane survived; only NEW points on a dead path are refused"
    );
}

#[test]
fn devices_round_trip_through_the_checkpoint_and_leave_a_deviceless_track_untouched() {
    let mut p = project();
    p.tracks.push(Track::new("t2", "No devices"));
    p.apply_cmd(&Cmd::DeviceAdd {
        track_id: "t1".into(),
        device_id: "synth1".into(),
        kind: timeline_core::model::DeviceKind::Sampler,
    })
    .unwrap();
    // A stored parameter, written the way the app writes one.
    p.apply_cmd(&Cmd::DeviceParamSet {
        track_id: "t1".into(),
        device_id: "synth1".into(),
        key: "cutoff".into(),
        value: Num::int(8000),
    })
    .unwrap();

    let session = timeline_core::session::Session::new(p.clone());
    let cp = timeline_core::package::to_project_json(&session);
    let tracks = cp["tracks"].as_array().unwrap();
    assert_eq!(tracks[0]["devices"][0]["deviceId"], json!("synth1"));
    assert_eq!(tracks[0]["devices"][0]["kind"], json!("sampler"));
    assert_eq!(tracks[0]["devices"][0]["params"]["cutoff"], json!(8000));
    assert_eq!(
        serde_json::to_string(&tracks[0]["devices"][0]["params"]["cutoff"]).unwrap(),
        "8000",
        "integer-shaped on the wire"
    );
    assert!(
        tracks[1].as_object().unwrap().get("devices").is_none(),
        "a track with no devices must not gain a `devices` key: {}",
        tracks[1]
    );

    let back = timeline_core::package::from_project_json(&cp).expect("reload");
    assert_eq!(back.tracks[0].devices, p.tracks[0].devices);

    // A device carrying params USED to refuse removal, because no command
    // could write one back. `device.param.set` can, so the removal is allowed
    // and its inverse is a SEQUENCE that restores the stored sound exactly.
    // Asserting the round trip rather than the old refusal is the stronger
    // claim: it is the refusal's whole reason for existing, met.
    let mut loaded = back;
    let effect = loaded
        .apply_cmd(&Cmd::DeviceRemove {
            track_id: "t1".into(),
            device_id: "synth1".into(),
        })
        .expect("a device with an authored sound is removable now");
    assert!(loaded.track("t1").unwrap().devices.is_empty(), "removed");
    assert_eq!(
        effect.inverse.iter().map(Cmd::name).collect::<Vec<_>>(),
        ["device.add", "device.param.set"],
        "the inverse restores the device AND its authored sound"
    );
    for c in &effect.inverse {
        loaded.apply_cmd(c).unwrap();
    }
    assert_eq!(
        loaded.track("t1").unwrap().devices[0].params.get("cutoff"),
        Some(&Num::int(8000)),
        "undo put the authored cutoff back, integer shape and all"
    );
}

// ---------------------------------------------------------------------------
// Quantize.
//
// The one note edit where the INVERSE is the whole design problem: every note
// travels its own distance to its own grid line, so there is no delta to
// negate. Everything below asserts on tick positions with the arithmetic
// written out, because "the notes moved" is exactly the claim a broken
// quantize also satisfies.
//
// The safety property is asserted too, in
// `nothing_but_an_explicit_quantize_ever_quantizes`: the owner's own recorded
// take is deliberately off the grid — the tempo map was fitted to his playing
// — so a quantize that fires on capture, on load, or on any other edit would
// destroy the one real performance in the project.
// ---------------------------------------------------------------------------

/// Notes deliberately placed OFF the grid, the way a played take is.
/// 240 ticks is a sixteenth at PPQ 960.
fn with_a_loose_take() -> Project {
    let mut p = with_midi_clip();
    add(
        &mut p,
        vec![
            // 3 ticks EARLY of the sixteenth at 240.
            spec("early", 237, 461, 60, 100),
            // 10 ticks LATE of the same line.
            spec("late", 250, 240, 64, 90),
            // 2 ticks early of the sixteenth at 1920.
            spec("drag", 1918, 240, 67, 80),
        ],
    );
    p
}

fn starts(p: &Project) -> Vec<(String, u64, u64)> {
    p.clip("cm1")
        .unwrap()
        .notes
        .iter()
        .map(|n| (n.id.clone(), n.start_ticks, n.length_ticks))
        .collect()
}

fn quantize(strength: u32, ends: bool) -> Cmd {
    Cmd::NoteQuantize {
        clip_id: "cm1".into(),
        note_ids: vec!["early".into(), "late".into(), "drag".into()],
        grid_ticks: 240,
        strength_percent: strength,
        quantize_ends: ends,
    }
}

#[test]
fn a_full_strength_quantize_lands_every_note_on_its_line_and_leaves_lengths_alone() {
    let mut p = with_a_loose_take();
    p.apply_cmd(&quantize(100, false)).expect("quantize");
    assert_eq!(
        starts(&p),
        vec![
            // 237 -> 240 (nearest line), 250 -> 240, 1918 -> 1920.
            ("early".into(), 240, 461),
            ("late".into(), 240, 240),
            ("drag".into(), 1920, 240),
        ],
        "starts land on the sixteenth grid; lengths are untouched with quantizeEnds off"
    );
}

#[test]
fn a_partial_strength_quantize_moves_part_of_the_way_and_not_all_of_it() {
    let mut p = with_a_loose_take();
    p.apply_cmd(&quantize(50, false)).expect("quantize");
    assert_eq!(
        starts(&p),
        vec![
            // 237: needs +3, half of 3 rounds away from zero to +2 -> 239.
            ("early".into(), 239, 461),
            // 250: needs -10, half is -5 -> 245.
            ("late".into(), 245, 240),
            // 1918: needs +2, half is +1 -> 1919.
            ("drag".into(), 1919, 240),
        ],
        "at 50% the notes are TIGHTER but still off the line — that is the point"
    );
}

#[test]
fn zero_strength_is_an_exact_no_op_rather_than_a_small_nudge() {
    let mut p = with_a_loose_take();
    let before = starts(&p);
    p.apply_cmd(&quantize(0, false)).expect("quantize");
    assert_eq!(starts(&p), before, "0% moved a note");
}

#[test]
fn quantize_measures_the_grid_from_the_project_phase_anchor_not_from_tick_zero() {
    // A landed generative song has a lead-in: bar 1 does not start at tick 0.
    // Grid lines measured from zero are not where that song's beats are, so a
    // quantize anchored at zero moves notes OFF the beat with total confidence.
    let mut p = with_a_loose_take();
    p.apply_cmd(&Cmd::ProjectSetPhaseAnchor { anchor_ticks: 100 })
        .expect("phase anchor");
    p.apply_cmd(&quantize(100, false)).expect("quantize");
    assert_eq!(
        starts(&p),
        vec![
            // Lines are now 100, 340, 580 ... so 237 -> 340, NOT 240.
            ("early".into(), 340, 461),
            ("late".into(), 340, 240),
            // 1918 - 100 = 1818; 1818 = 7*240 + 138, and 138 is past the
            // half-step, so the line above wins: 100 + 8*240 = 2020.
            ("drag".into(), 2020, 240),
        ],
        "the grid follows the project's phase anchor"
    );
}

#[test]
fn quantizing_ends_changes_length_and_leaving_it_off_does_not() {
    let mut p = with_a_loose_take();
    p.apply_cmd(&quantize(100, true)).expect("quantize");
    assert_eq!(
        starts(&p),
        vec![
            // early: start 237 -> 240 (+3). End 237+461 = 698 -> 720 (+22).
            // New length = 461 + 22 - 3 = 480.
            ("early".into(), 240, 480),
            // late: start 250 -> 240 (-10). End 490 -> 480 (-10). Length 240.
            ("late".into(), 240, 240),
            // drag: start 1918 -> 1920 (+2). End 2158 -> 2160 (+2). Length 240.
            ("drag".into(), 1920, 240),
        ],
        "with quantizeEnds the note END is pulled to the grid too"
    );
}

#[test]
fn a_quantize_that_would_squeeze_a_note_to_nothing_is_refused_whole_and_not_clamped() {
    let mut p = with_midi_clip();
    add(
        &mut p,
        vec![
            spec("ok", 0, 480, 60, 100),
            // A 4-tick grace note whose start and end quantize to the SAME
            // line: length would come out 0.
            spec("grace", 122, 4, 72, 100),
        ],
    );
    let before = starts(&p);
    let err = p
        .apply_cmd(&Cmd::NoteQuantize {
            clip_id: "cm1".into(),
            note_ids: vec!["ok".into(), "grace".into()],
            grid_ticks: 240,
            strength_percent: 100,
            quantize_ends: true,
        })
        .expect_err("a zero-length note must never be written");
    assert!(
        matches!(err, CommandError::OutOfRange(_)),
        "expected OutOfRange, got {err:?}"
    );
    assert_eq!(starts(&p), before, "the OTHER note moved anyway — partial apply");
}

#[test]
fn a_quantize_that_would_cross_tick_zero_is_refused_whole() {
    // The clip starts at 500, so its note 0 sits at absolute 500; the nearest
    // sixteenth below is 480, which is 20 ticks BEFORE the clip.
    let mut p = project();
    p.apply_cmd(&Cmd::ClipPlaceMidi {
        clip_id: "cm1".into(),
        track_id: "t1".into(),
        start_ticks: 500,
        length_ticks: 3840,
    })
    .expect("place");
    add(&mut p, vec![spec("n1", 0, 240, 60, 100)]);
    let before = starts(&p);
    let err = p
        .apply_cmd(&Cmd::NoteQuantize {
            clip_id: "cm1".into(),
            note_ids: vec!["n1".into()],
            grid_ticks: 240,
            strength_percent: 100,
            quantize_ends: false,
        })
        .expect_err("a negative start must never be written");
    assert!(matches!(err, CommandError::OutOfRange(_)), "{err:?}");
    assert_eq!(starts(&p), before);
}

#[test]
fn the_quantize_inverse_restores_the_exact_performance_not_the_grid() {
    // The property the owner's take depends on. A "quantize back" inverse
    // would land on the grid and look fine in a count-based test; this one
    // asserts the ORIGINAL, off-grid tick positions come back.
    for (strength, ends) in [(100u32, false), (65, false), (100, true), (0, false)] {
        let mut p = with_a_loose_take();
        let original = starts(&p);
        assert_inverse_is_exact(&mut p, quantize(strength, ends));
        assert_eq!(
            starts(&p),
            original,
            "undo of quantize({strength}%, ends={ends}) did not restore the performance"
        );
    }
    // And the declared inverse is the absolute setter, never another quantize.
    let mut p = with_a_loose_take();
    let effect = p.apply_cmd(&quantize(100, false)).unwrap();
    assert_eq!(
        effect.inverse.iter().map(Cmd::name).collect::<Vec<_>>(),
        ["note.timing.set"],
        "quantize must undo through absolute positions, never through a reverse quantize"
    );
}

#[test]
fn note_timing_set_is_absolute_exact_and_its_own_inverse() {
    let mut p = with_a_loose_take();
    assert_inverse_is_exact(
        &mut p,
        Cmd::NoteTimingSet {
            clip_id: "cm1".into(),
            notes: vec![
                NoteTiming {
                    note_id: "early".into(),
                    start_ticks: 1,
                    length_ticks: 7,
                },
                NoteTiming {
                    note_id: "drag".into(),
                    start_ticks: 3000,
                    length_ticks: 13,
                },
            ],
        },
    );
    // Absolute, not a delta: the written values ARE the positions.
    p.apply_cmd(&Cmd::NoteTimingSet {
        clip_id: "cm1".into(),
        notes: vec![NoteTiming {
            note_id: "late".into(),
            start_ticks: 42,
            length_ticks: 99,
        }],
    })
    .expect("timing set");
    let n = p.clip("cm1").unwrap().note("late").unwrap();
    assert_eq!((n.start_ticks, n.length_ticks), (42, 99));
    // Pitch and velocity are NOT this command's business.
    assert_eq!(n.pitch, 64);
    assert_eq!(n.velocity, Num::int(90));
}

#[test]
fn note_timing_set_refuses_an_unknown_note_a_duplicate_and_a_zero_length() {
    let mut p = with_a_loose_take();
    let before = starts(&p);
    for (notes, what) in [
        (
            vec![NoteTiming {
                note_id: "ghost".into(),
                start_ticks: 0,
                length_ticks: 240,
            }],
            "unknown note",
        ),
        (
            vec![
                NoteTiming {
                    note_id: "early".into(),
                    start_ticks: 0,
                    length_ticks: 240,
                },
                NoteTiming {
                    note_id: "early".into(),
                    start_ticks: 480,
                    length_ticks: 240,
                },
            ],
            "duplicate id",
        ),
        (
            vec![NoteTiming {
                note_id: "early".into(),
                start_ticks: 0,
                length_ticks: 0,
            }],
            "zero length",
        ),
    ] {
        p.apply_cmd(&Cmd::NoteTimingSet {
            clip_id: "cm1".into(),
            notes,
        })
        .expect_err(what);
        assert_eq!(starts(&p), before, "{what} left the model modified");
    }
}

#[test]
fn a_quantize_replays_to_the_same_chain_and_the_same_positions() {
    use timeline_core::envelope::Actor;
    use timeline_core::session::{Session, SeqMeta};

    let mut session = Session::new(project());
    let mut n = 1u64;
    for cmd in [
        // The replay target starts blank, so the track has to arrive on the
        // journal like everything else.
        Cmd::TrackAdd {
            track_id: "t2".into(),
            name: "Keys 2".into(),
            index: None,
        },
        Cmd::ClipPlaceMidi {
            clip_id: "cm1".into(),
            track_id: "t2".into(),
            start_ticks: 0,
            length_ticks: 3840,
        },
        Cmd::NoteAdd {
            clip_id: "cm1".into(),
            notes: vec![spec("early", 237, 461, 60, 100), spec("late", 250, 240, 64, 90)],
        },
        Cmd::NoteQuantize {
            clip_id: "cm1".into(),
            note_ids: vec!["early".into(), "late".into()],
            grid_ticks: 240,
            strength_percent: 65,
            quantize_ends: false,
        },
    ] {
        session.submit(support::user_meta(n), cmd).expect("submit");
        n += 1;
    }
    let replayed = Session::replay(
        Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap())),
        session.journal().to_vec(),
    )
    .expect("replay");
    assert_eq!(
        replayed.project().clip("cm1").unwrap().notes,
        session.project().clip("cm1").unwrap().notes,
        "quantize must be deterministic under replay — no float rounding anywhere"
    );
    assert_eq!(session.tip_hash(), replayed.tip_hash());
    // 65% of +3 is 1.95, which rounds away from zero to 2.
    assert_eq!(
        session.project().clip("cm1").unwrap().note("early").unwrap().start_ticks,
        239
    );
    // 65% of -10 is -6.5, which rounds away from zero to -7.
    assert_eq!(
        session.project().clip("cm1").unwrap().note("late").unwrap().start_ticks,
        243
    );
}

#[test]
fn nothing_but_an_explicit_quantize_ever_quantizes() {
    // The safety property, asserted rather than promised. Every other note
    // path — placing a clip, landing a take, moving, resizing, duplicating,
    // even undoing — must leave off-grid positions exactly where they were.
    use timeline_core::envelope::Actor;
    use timeline_core::session::{Session, SeqMeta};

    let mut session = Session::new(project());
    let mut n = 1u64;
    let mut submit = |session: &mut Session, cmd: Cmd, n: &mut u64| {
        session.submit(support::user_meta(*n), cmd).expect("submit");
        *n += 1;
    };
    submit(
        &mut session,
        Cmd::ClipPlaceMidi {
            clip_id: "cm1".into(),
            track_id: "t1".into(),
            start_ticks: 0,
            length_ticks: 3840,
        },
        &mut n,
    );
    submit(
        &mut session,
        Cmd::NoteAdd {
            clip_id: "cm1".into(),
            notes: vec![spec("early", 237, 461, 60, 100)],
        },
        &mut n,
    );
    submit(
        &mut session,
        Cmd::NoteMove {
            clip_id: "cm1".into(),
            note_ids: vec!["early".into()],
            delta_ticks: 480,
            delta_pitch: 0,
        },
        &mut n,
    );
    submit(
        &mut session,
        Cmd::NoteDuplicate {
            clip_id: "cm1".into(),
            note_ids: vec!["early".into()],
            new_note_ids: vec!["copy".into()],
            delta_ticks: 960,
            delta_pitch: 0,
        },
        &mut n,
    );
    // 237 + 480 = 717, and 717 + 960 = 1677. Both still 3 ticks shy of the
    // grid, because nothing on this path is allowed to tidy them up.
    assert_eq!(
        session.project().clip("cm1").unwrap().note("early").unwrap().start_ticks,
        717
    );
    assert_eq!(
        session.project().clip("cm1").unwrap().note("copy").unwrap().start_ticks,
        1677
    );
    assert!(
        session
            .journal()
            .iter()
            .all(|e| e.name != "note.quantize"),
        "something journaled a quantize nobody asked for"
    );
}
