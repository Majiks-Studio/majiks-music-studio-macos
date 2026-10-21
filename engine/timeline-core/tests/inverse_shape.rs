//! Deferred proposal 4, "split/take inverse shapes" — ACCEPTED (design §6).
//!
//! `inverseRule` names the DECLARED inverse command and is v1.1 law, so v2 must
//! not touch it (the superset test enforces that). But for four commands the
//! runtime undo is a SEQUENCE, not one command, and until now that fact lived
//! only in a code comment. "Invertibility is declared data; an inexact inverse
//! is an undo bug waiting to happen."
//!
//! v2 therefore adds `inverseShape` — an inert annotation recording what
//! `apply.rs` actually returns — and this file makes it a checked claim rather
//! than prose. If someone changes an arm from a single inverse to a sequence
//! (or back) without updating the catalog, this fails.

use serde_json::json;
use timeline_core::catalog::{Catalog, InverseMode, InverseShape};
use timeline_core::cmd::Cmd;
use timeline_core::model::{Project, Track};
use timeline_core::num::Num;
use timeline_core::tempo::{Bpm, TempoMap};
use timeline_core::{ParamRef, Source};

// ---------------------------------------------------------------------------
// Static consistency: inverseShape vs inverseRule, for every command.
// ---------------------------------------------------------------------------

#[test]
fn declared_shape_is_consistent_with_the_declared_rule() {
    for name in Catalog::get().names() {
        let spec = Catalog::get().spec(name).unwrap();
        match (spec.inverse_mode, spec.inverse_shape) {
            (InverseMode::None, InverseShape::None) => {
                assert!(!spec.undoable, "{name}: mode none but undoable");
            }
            (InverseMode::SelfInverse, InverseShape::SelfShaped)
            | (InverseMode::Explicit, InverseShape::Explicit) => {}
            // "multi" refines a self/explicit rule: the catalog HINT is still
            // the single declared name, the runtime undo is a sequence.
            (InverseMode::SelfInverse | InverseMode::Explicit, InverseShape::Multi) => {}
            (m, s) => panic!("{name}: inverseRule.mode {m:?} vs inverseShape {}", s.as_str()),
        }
        if spec.inverse_mode == InverseMode::Explicit {
            let target = spec.inverse_name.as_deref().expect("explicit needs a name");
            assert!(
                Catalog::get().spec(target).is_some(),
                "{name}'s declared inverse {target} is not a catalog command"
            );
        }
    }
}

#[test]
fn exactly_these_commands_declare_a_multi_command_inverse() {
    let mut multi: Vec<&str> = Catalog::get()
        .names()
        .iter()
        .filter(|n| Catalog::get().spec(n).unwrap().inverse_shape == InverseShape::Multi)
        .map(String::as_str)
        .collect();
    multi.sort_unstable();
    assert_eq!(
        multi,
        [
            "autolane.clear",
            "clip.remove",
            "clip.split",
            // Same reason as `fx.param.set` below: the declared inverse NAME
            // cannot cover both directions, because setting a key that was
            // ABSENT inverts to `device.param.clear`, not to a written default.
            "device.param.set",
            // E2 source binding: a sampler device carries its zones, and each
            // one restores through its own `device.zone.add`; since
            // `device.param.set` landed it also carries its authored sound, one
            // `device.param.set` per stored key.
            "device.remove",
            // E5 §16.4. `fx.remove` is a genuine SEQUENCE (chain index, every
            // stored param, the sidechain link). `fx.param.set` and
            // `fx.sidechain.set` are "multi" for the OTHER reason the
            // annotation admits: the declared inverse NAME cannot cover both
            // directions — setting a key/link that was absent inverts to
            // `fx.param.clear` / `fx.sidechain.clear`, not to a written
            // default. Both are pinned in tests/fx_commands.rs.
            "fx.param.set",
            "fx.remove",
            "fx.sidechain.set",
            "route.node.remove",
            "track.remove",
        ],
        "the set of multi-inverse commands changed; update the catalog annotation"
    );
}

// ---------------------------------------------------------------------------
// Dynamic: what apply.rs actually returns.
// ---------------------------------------------------------------------------

fn seeded() -> Project {
    let mut p = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    p.add_source(Source {
        id: "src1".into(),
        path: "/tmp/a.wav".into(),
        len_frames: 48_000 * 60,
    })
    .unwrap();
    p.tracks.push(Track::new("t1", "Track 1"));
    p.tracks.push(Track::new("t2", "Track 2"));
    p.apply_cmd(&Cmd::ClipPlace {
        clip_id: "c1".into(),
        track_id: "t1".into(),
        asset_hash: "src1".into(),
        start_ticks: 0,
        length_ticks: 3840,
        source_offset_ticks: Some(0),
    })
    .expect("place");
    p
}

fn shape_of(name: &str) -> InverseShape {
    Catalog::get().spec(name).unwrap().inverse_shape
}

fn assert_shape(p: &mut Project, cmd: Cmd) {
    let name = cmd.name();
    let declared = shape_of(name);
    let effect = p
        .apply_cmd(&cmd)
        .unwrap_or_else(|e| panic!("{name} should apply: {e}"));
    let hint = effect
        .hint
        .as_ref()
        .unwrap_or_else(|| panic!("{name} is undoable, so session.rs REQUIRES a hint"));

    match declared {
        // "multi" means the runtime undo MAY exceed one command — for the
        // remove-class commands it does so exactly when there is non-default
        // state to restore, so each call site below seeds that state. What
        // would be a BUG is a self/explicit command ever exceeding one.
        InverseShape::Multi => assert!(
            effect.inverse.len() > 1,
            "{name} declares inverseShape=multi but produced {} inverse command(s) \
             from a state that should have forced a sequence",
            effect.inverse.len()
        ),
        InverseShape::SelfShaped | InverseShape::Explicit => assert_eq!(
            effect.inverse.len(),
            1,
            "{name} declares a single-command inverse but produced {}",
            effect.inverse.len()
        ),
        InverseShape::None => panic!("{name} should not be undoable"),
    }

    // The HINT is always the single declared name, whatever the runtime shape.
    let spec = Catalog::get().spec(name).unwrap();
    let expected_hint = match spec.inverse_mode {
        InverseMode::SelfInverse => name,
        InverseMode::Explicit => spec.inverse_name.as_deref().unwrap(),
        InverseMode::None => unreachable!(),
    };
    assert_eq!(
        hint.name(),
        expected_hint,
        "{name}'s hint must be the catalog's declared inverse"
    );
}

#[test]
fn multi_inverse_commands_really_return_a_sequence() {
    // clip.split — the P4 proposal's original example.
    let mut p = seeded();
    assert_shape(
        &mut p,
        Cmd::ClipSplit {
            clip_id: "c1".into(),
            at_ticks: 1920,
            new_clip_id: "c2".into(),
        },
    );

    // clip.remove — with non-default clip state, which is what makes the
    // restore sequence longer than the declared single clip.place.
    let mut p = seeded();
    p.apply_cmd(&Cmd::ClipRename {
        clip_id: "c1".into(),
        name: "Verse".into(),
    })
    .unwrap();
    p.apply_cmd(&Cmd::ClipSetGain {
        clip_id: "c1".into(),
        gain_db: Num::int(-3),
    })
    .unwrap();
    assert_shape(&mut p, Cmd::ClipRemove { clip_id: "c1".into() });

    // ... and a PRISTINE clip restores in exactly one command. The annotation
    // is "may be a sequence", not "always is"; pinning both directions keeps
    // it honest.
    let mut p = seeded();
    let effect = p
        .apply_cmd(&Cmd::ClipRemove { clip_id: "c1".into() })
        .unwrap();
    assert_eq!(
        effect.inverse.len(),
        1,
        "a pristine clip needs only the declared clip.place to restore"
    );

    // track.remove — with mixer + automation state, which is what makes the
    // restore sequence long.
    let mut p = seeded();
    p.apply_cmd(&Cmd::MixGain {
        track_id: "t2".into(),
        gain_db: Num::int(-6),
    })
    .unwrap();
    p.apply_cmd(&Cmd::AutopointAdd {
        track_id: "t2".into(),
        target: ParamRef::track_pan(),
        point_id: "p1".into(),
        position_ticks: 0,
        value: Num::int(-1),
    })
    .unwrap();
    assert_shape(&mut p, Cmd::TrackRemove { track_id: "t2".into() });

    // autolane.clear
    let mut p = seeded();
    for (id, tick) in [("a1", 0u64), ("a2", 960)] {
        p.apply_cmd(&Cmd::AutopointAdd {
            track_id: "t1".into(),
            target: ParamRef::track_volume(),
            point_id: id.into(),
            position_ticks: tick,
            value: Num::int(0),
        })
        .unwrap();
    }
    assert_shape(
        &mut p,
        Cmd::AutolaneClear {
            track_id: "t1".into(),
            target: ParamRef::track_volume(),
        },
    );

    // device.remove — a sampler with a bound zone. The zone is what makes the
    // restore sequence longer than the declared single device.add.
    let mut p = seeded();
    p.apply_cmd(&Cmd::from_wire(
        "device.add",
        json!({"trackId": "t1", "deviceId": "dev1", "kind": "sampler"}),
    )
    .unwrap())
    .unwrap();
    p.apply_cmd(&Cmd::from_wire(
        "device.zone.add",
        json!({"trackId": "t1", "deviceId": "dev1", "zoneId": "z1",
               "sourceId": "src1", "rootPitch": 60, "loPitch": 0, "hiPitch": 127}),
    )
    .unwrap())
    .unwrap();
    assert_shape(
        &mut p,
        Cmd::DeviceRemove {
            track_id: "t1".into(),
            device_id: "dev1".into(),
        },
    );

    // ... and a device with NO zones restores in exactly one command. Same
    // "may be a sequence, not always is" pinning as clip.remove above.
    let mut p = seeded();
    p.apply_cmd(&Cmd::from_wire(
        "device.add",
        json!({"trackId": "t1", "deviceId": "dev1", "kind": "synth"}),
    )
    .unwrap())
    .unwrap();
    let effect = p
        .apply_cmd(&Cmd::DeviceRemove {
            track_id: "t1".into(),
            device_id: "dev1".into(),
        })
        .unwrap();
    assert_eq!(
        effect.inverse.len(),
        1,
        "a device with no zones needs only the declared device.add to restore"
    );

    // route.node.remove — the new one, same shape for the same reason.
    let mut p = seeded();
    p.apply_cmd(&Cmd::from_wire(
        "route.node.add",
        json!({"nodeId": "grp", "kind": "group", "name": "Group"}),
    )
    .unwrap())
    .unwrap();
    p.apply_cmd(
        &Cmd::from_wire(
            "route.connect",
            json!({"edgeId": "e1", "from": "track.t1", "to": "bus.grp",
                   "level": 1, "tap": "post"}),
        )
        .unwrap(),
    )
    .unwrap();
    assert_shape(&mut p, Cmd::RouteNodeRemove { node_id: "grp".into() });

    // fx.remove — a CONFIGURED, SIDECHAINED effect at a NON-TERMINAL chain
    // index. All three of those are what make the restore a sequence: fx.add
    // appends, so the index needs a fx.move; params and the link each need
    // their own command. `device.remove`'s "refuse a device with stored params"
    // guard is deliberately NOT copied here — fx.param.set CAN restore them, so
    // copying it would make every configured effect unremovable (§16.4).
    let mut p = seeded();
    for (id, kind) in [("fxA", "compressor"), ("fxB", "utility")] {
        p.apply_cmd(
            &Cmd::from_wire("fx.add", json!({"target": "track.t1", "fxId": id, "kind": kind}))
                .unwrap(),
        )
        .unwrap();
    }
    p.apply_cmd(
        &Cmd::from_wire(
            "fx.param.set",
            json!({"target": "track.t1", "fxId": "fxA", "key": "threshold", "value": -18}),
        )
        .unwrap(),
    )
    .unwrap();
    p.apply_cmd(
        &Cmd::from_wire(
            "fx.sidechain.set",
            json!({"target": "track.t1", "fxId": "fxA", "source": "track.t2"}),
        )
        .unwrap(),
    )
    .unwrap();
    assert_shape(
        &mut p,
        Cmd::from_wire("fx.remove", json!({"target": "track.t1", "fxId": "fxA"})).unwrap(),
    );

    // ... and a PRISTINE, terminal fx restores in exactly the declared fx.add.
    let mut p = seeded();
    p.apply_cmd(
        &Cmd::from_wire("fx.add", json!({"target": "master", "fxId": "m1", "kind": "eq"}))
            .unwrap(),
    )
    .unwrap();
    let effect = p
        .apply_cmd(&Cmd::from_wire("fx.remove", json!({"target": "master", "fxId": "m1"})).unwrap())
        .unwrap();
    assert_eq!(
        effect.inverse.len(),
        1,
        "a pristine terminal fx needs only the declared fx.add to restore"
    );
}

#[test]
fn single_inverse_commands_really_return_exactly_one() {
    let mut p = seeded();
    assert_shape(
        &mut p,
        Cmd::ClipMove {
            clip_id: "c1".into(),
            track_id: "t1".into(),
            start_ticks: 960,
        },
    );
    assert_shape(
        &mut p,
        Cmd::MixPan {
            track_id: "t1".into(),
            pan: Num::int(1),
        },
    );
    // take.promote / take.discard were the OTHER half of proposal 4. Their
    // catalog pair is already exact; assert it rather than assume it.
    assert_eq!(shape_of("take.promote"), InverseShape::Explicit);
    assert_eq!(shape_of("take.discard"), InverseShape::Explicit);
    assert_eq!(
        Catalog::get().spec("take.promote").unwrap().inverse_name.as_deref(),
        Some("take.discard")
    );
    assert_eq!(
        Catalog::get().spec("take.discard").unwrap().inverse_name.as_deref(),
        Some("take.promote")
    );
}
