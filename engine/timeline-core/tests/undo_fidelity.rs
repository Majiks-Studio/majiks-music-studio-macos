//! UNDO FIDELITY: a destructive command's inverse must restore the EXACT
//! pre-state, or the command must refuse.
//!
//! Every test here is `apply -> inverse -> model == pre-state`, the shape the
//! property suite claimed to cover and could not, because
//! `tests/support.rs::Conductor` emitted no `device.*` and in fact no remove at
//! all except `note.remove`. `track.remove` therefore dropped `Track::devices`
//! for months: delete a track, press undo, and your instrument was gone — and
//! when the track also carried a `track.device.<id>.<key>` automation lane the
//! inverse was REFUSED halfway through, which is worse than silent, because
//! `Session::undo` pops the undo unit before applying the sequence with `?`
//! and leaves the model half-restored with the unit destroyed.
//!
//! The second class here is `extra`: unknown checkpoint fields written by a
//! NEWER build. No catalog command in this build can name them, so no inverse
//! can carry them. `device.zone.remove` and `fx.remove` already REFUSED on that
//! ground; every other destructive command silently dropped them. They now
//! refuse in the same words.

use serde_json::json;
use timeline_core::cmd::{Cmd, NoteSpec, SendBus};
use timeline_core::envelope::Actor;
use timeline_core::model::{DeviceKind, FxKind, Project, Track};
use timeline_core::num::Num;
use timeline_core::paramref::ParamRef;
use timeline_core::routing::{NodeKind, NodeRef, Tap};
use timeline_core::session::{Session, SeqMeta};
use timeline_core::tempo::{Bpm, TempoMap};
use timeline_core::Source;

fn base() -> Project {
    let mut p = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    p.add_source(Source {
        id: "srcA".into(),
        path: "/tmp/a.wav".into(),
        len_frames: 480_000,
    })
    .unwrap();
    p
}

fn with_track() -> Project {
    let mut p = base();
    p.tracks.push(Track::new("t1", "T1"));
    p
}

/// The load-bearing assertion of this file.
#[track_caller]
fn assert_roundtrip(p: &mut Project, cmd: Cmd) {
    let pre = p.clone();
    let name = cmd.name();
    let effect = p
        .apply_cmd(&cmd)
        .unwrap_or_else(|e| panic!("{name} failed to apply: {e}"));
    for inv in &effect.inverse {
        p.apply_cmd(inv).unwrap_or_else(|e| {
            panic!(
                "inverse of {name} failed to apply ({}): {e}",
                inv.name()
            )
        });
    }
    assert!(
        pre == *p,
        "inverse of {name} did not restore the pre-state (inverse was {:?})",
        effect.inverse.iter().map(|c| c.name()).collect::<Vec<_>>()
    );
}

#[track_caller]
fn assert_refused(p: &mut Project, cmd: Cmd, needle: &str) {
    let pre = p.clone();
    let name = cmd.name();
    let err = p
        .apply_cmd(&cmd)
        .expect_err(&format!("{name} should have been refused"));
    let msg = err.to_string();
    assert!(
        msg.contains(needle),
        "{name} refused for the wrong reason: {msg}"
    );
    // Validate-first: a refusal must not have moved anything.
    assert!(pre == *p, "{name} partially applied before refusing");
}

// ---------------------------------------------------------------------------
// 1. track.remove drops the instrument registry  (THE reported defect)
// ---------------------------------------------------------------------------

#[test]
fn track_remove_restores_devices() {
    let mut p = with_track();
    for (id, kind) in [("d1", DeviceKind::Synth), ("d2", DeviceKind::Sampler)] {
        p.apply_cmd(&Cmd::DeviceAdd {
            track_id: "t1".into(),
            device_id: id.into(),
            kind,
        })
        .unwrap();
    }
    assert_roundtrip(
        &mut p,
        Cmd::TrackRemove {
            track_id: "t1".into(),
        },
    );
    // Registry ORDER is part of the state: `device.add` appends, so the
    // restore sequence must add in `Vec` order.
    let ids: Vec<&str> = p
        .track("t1")
        .unwrap()
        .devices
        .iter()
        .map(|d| d.id.as_str())
        .collect();
    assert_eq!(ids, ["d1", "d2"]);
}

#[test]
fn track_remove_restores_a_samplers_source_bindings() {
    let mut p = with_track();
    p.apply_cmd(&Cmd::DeviceAdd {
        track_id: "t1".into(),
        device_id: "d1".into(),
        kind: DeviceKind::Sampler,
    })
    .unwrap();
    // Two zones, one fully defaulted and one with explicit gain/pan, so a
    // restore that invents defaults fails as loudly as one that drops them.
    for (z, lo, hi, gain) in [("z1", 48i64, 59i64, None), ("z2", 60, 72, Some(-6i64))] {
        p.apply_cmd(&Cmd::DeviceZoneAdd {
            track_id: "t1".into(),
            device_id: "d1".into(),
            zone_id: z.into(),
            source_id: "srcA".into(),
            root_pitch: Num::int(lo),
            lo_pitch: Num::int(lo),
            hi_pitch: Num::int(hi),
            gain_db: gain.map(Num::int),
            pan: None,
        })
        .unwrap();
    }
    assert_roundtrip(
        &mut p,
        Cmd::TrackRemove {
            track_id: "t1".into(),
        },
    );
    assert_eq!(p.track("t1").unwrap().devices[0].zones.len(), 2);
}

#[test]
fn track_remove_restores_a_device_automation_lane() {
    // Ordering test: `track.device.<id>.<key>` does not resolve until the
    // device exists, so the restore sequence must rebuild devices BEFORE it
    // replays autopoints. Before the fix this did not merely lose data — the
    // inverse's `autopoint.add` was refused mid-sequence.
    let mut p = with_track();
    p.apply_cmd(&Cmd::DeviceAdd {
        track_id: "t1".into(),
        device_id: "d1".into(),
        kind: DeviceKind::Synth,
    })
    .unwrap();
    p.apply_cmd(&Cmd::AutopointAdd {
        track_id: "t1".into(),
        target: ParamRef::parse("track.device.d1.cutoff").unwrap(),
        point_id: "ap1".into(),
        position_ticks: 480,
        value: Num::int(3),
    })
    .unwrap();
    assert_roundtrip(
        &mut p,
        Cmd::TrackRemove {
            track_id: "t1".into(),
        },
    );
}

#[test]
fn track_remove_restores_the_whole_strip_at_once() {
    // Everything `track_restore_sequence` is responsible for, in one command:
    // colour, height, mute/solo/arm, gain, pan, an EQ band, both sends, an
    // instrument with a zone, an insert with a stored param, and two lanes.
    let mut p = with_track();
    let t = "t1".to_string();
    for c in [
        Cmd::TrackSetColor {
            track_id: t.clone(),
            color: "#123456".into(),
        },
        Cmd::TrackSetHeight {
            track_id: t.clone(),
            height_px: 137,
        },
        Cmd::TrackMute {
            track_id: t.clone(),
            muted: true,
        },
        Cmd::TrackSolo {
            track_id: t.clone(),
            soloed: true,
        },
        Cmd::TrackArm {
            track_id: t.clone(),
            armed: true,
        },
        Cmd::MixGain {
            track_id: t.clone(),
            gain_db: Num::int(-4),
        },
        Cmd::MixPan {
            track_id: t.clone(),
            pan: Num::int(1),
        },
        Cmd::MixEq {
            track_id: t.clone(),
            band: 2,
            freq_hz: Num::int(3000),
            gain_db: Num::int(3),
            q: None,
        },
        Cmd::MixSend {
            track_id: t.clone(),
            bus: SendBus::A,
            amount: Num::int(1),
        },
        Cmd::MixSend {
            track_id: t.clone(),
            bus: SendBus::B,
            amount: Num::int(1),
        },
        Cmd::DeviceAdd {
            track_id: t.clone(),
            device_id: "d1".into(),
            kind: DeviceKind::Sampler,
        },
        Cmd::DeviceZoneAdd {
            track_id: t.clone(),
            device_id: "d1".into(),
            zone_id: "z1".into(),
            source_id: "srcA".into(),
            root_pitch: Num::int(60),
            lo_pitch: Num::int(48),
            hi_pitch: Num::int(72),
            gain_db: Some(Num::int(-2)),
            pan: None,
        },
        Cmd::FxAdd {
            target: NodeRef::Track(t.clone()),
            fx_id: "f1".into(),
            kind: FxKind::Compressor,
        },
        Cmd::FxParamSet {
            target: NodeRef::Track(t.clone()),
            fx_id: "f1".into(),
            key: "threshold".into(),
            value: Num::int(-18),
        },
        Cmd::AutopointAdd {
            track_id: t.clone(),
            target: ParamRef::parse("track.volume").unwrap(),
            point_id: "ap1".into(),
            position_ticks: 0,
            value: Num::int(-3),
        },
        Cmd::AutopointAdd {
            track_id: t.clone(),
            target: ParamRef::parse("track.device.d1.cutoff").unwrap(),
            point_id: "ap2".into(),
            position_ticks: 960,
            value: Num::int(2),
        },
        Cmd::AutopointAdd {
            track_id: t.clone(),
            target: ParamRef::parse("track.fx.f1.ratio").unwrap(),
            point_id: "ap3".into(),
            position_ticks: 1920,
            value: Num::int(4),
        },
    ] {
        p.apply_cmd(&c).unwrap_or_else(|e| panic!("{}: {e}", c.name()));
    }
    assert_roundtrip(&mut p, Cmd::TrackRemove { track_id: t });
}

#[test]
fn a_track_removal_survives_a_real_undo_through_the_session() {
    // The model-level round trip above proves the sequence; this proves the
    // path a user actually takes, including the journal.
    let mut s = Session::new(base());
    let mut n = 1u64;
    let submit = |s: &mut Session, c: Cmd, n: &mut u64| {
        s.submit(
            timeline_core::envelope::EntryMeta {
                id: format!("{:026}", *n),
                ts: format!("2026-01-01T00:00:{:02}Z", *n % 60),
                actor: Actor::user("aaron"),
            },
            c,
        )
        .unwrap();
        *n += 1;
    };
    submit(
        &mut s,
        Cmd::TrackAdd {
            track_id: "t1".into(),
            name: "T1".into(),
            index: None,
        },
        &mut n,
    );
    submit(
        &mut s,
        Cmd::DeviceAdd {
            track_id: "t1".into(),
            device_id: "d1".into(),
            kind: DeviceKind::Synth,
        },
        &mut n,
    );
    let before = s.project().clone();
    submit(
        &mut s,
        Cmd::TrackRemove {
            track_id: "t1".into(),
        },
        &mut n,
    );
    let mut meta = SeqMeta::starting_at(n, Actor::user("undo"));
    assert!(s.undo(&mut meta).expect("undo applies cleanly"));
    assert!(
        before == *s.project(),
        "undo of track.remove did not restore the project"
    );
    assert_eq!(
        s.project().track("t1").unwrap().devices.len(),
        1,
        "the instrument came back"
    );
}

// ---------------------------------------------------------------------------
// 2. A lane whose parameter is gone cannot be re-authored — refuse, do not
//    half-apply. (`device.remove`/`fx.remove` deliberately KEEP the points.)
// ---------------------------------------------------------------------------



// ---------------------------------------------------------------------------
// 3. clip.remove dropped the L8 phase anchor
// ---------------------------------------------------------------------------

#[test]
fn clip_remove_restores_the_phase_anchor() {
    let mut p = with_track();
    p.apply_cmd(&Cmd::ClipPlace {
        clip_id: "c1".into(),
        track_id: "t1".into(),
        asset_hash: "srcA".into(),
        start_ticks: 0,
        length_ticks: 1920,
        source_offset_ticks: None,
    })
    .unwrap();
    p.apply_cmd(&Cmd::ClipPhaseAnchorSet {
        clip_id: "c1".into(),
        anchor_ticks: 240,
    })
    .unwrap();
    assert_roundtrip(
        &mut p,
        Cmd::ClipRemove {
            clip_id: "c1".into(),
        },
    );
    assert_eq!(p.clip("c1").unwrap().phase_anchor_ticks, 240);
}

#[test]
fn clip_remove_restores_a_fully_dressed_note_clip() {
    let mut p = with_track();
    p.apply_cmd(&Cmd::ClipPlaceMidi {
        clip_id: "m1".into(),
        track_id: "t1".into(),
        start_ticks: 0,
        length_ticks: 1920,
    })
    .unwrap();
    p.apply_cmd(&Cmd::NoteAdd {
        clip_id: "m1".into(),
        notes: vec![
            NoteSpec {
                note_id: "n1".into(),
                start_ticks: 0,
                length_ticks: 240,
                pitch: 60,
                velocity: Num::int(100),
            },
            NoteSpec {
                note_id: "n2".into(),
                start_ticks: 240,
                length_ticks: 240,
                pitch: 64,
                velocity: Num::int(80),
            },
        ],
    })
    .unwrap();
    for c in [
        Cmd::ClipRename {
            clip_id: "m1".into(),
            name: "Riff".into(),
        },
        Cmd::ClipSetGain {
            clip_id: "m1".into(),
            gain_db: Num::int(-2),
        },
        Cmd::ClipMute {
            clip_id: "m1".into(),
            muted: true,
        },
        Cmd::ClipPhaseAnchorSet {
            clip_id: "m1".into(),
            anchor_ticks: 480,
        },
    ] {
        p.apply_cmd(&c).unwrap();
    }
    assert_roundtrip(
        &mut p,
        Cmd::ClipRemove {
            clip_id: "m1".into(),
        },
    );
}

// ---------------------------------------------------------------------------
// 4. `extra`: unknown fields from a newer build. Refuse, never drop.
// ---------------------------------------------------------------------------

const UNRESTORABLE: &str = "unknown field(s) that no catalog command in this build can restore";

#[test]
fn track_remove_refuses_a_track_carrying_unknown_fields() {
    let mut p = base();
    let mut t = Track::new("t1", "T1");
    t.extra.insert("futureField".into(), json!(7));
    p.tracks.push(t);
    assert_refused(
        &mut p,
        Cmd::TrackRemove {
            track_id: "t1".into(),
        },
        UNRESTORABLE,
    );
}

#[test]
fn track_remove_refuses_when_a_device_on_it_is_unrestorable() {
    // Both of `device.remove`'s own guards have to hold one level up, or
    // `track.remove` becomes the back door around them.
    let mut p = with_track();
    p.apply_cmd(&Cmd::DeviceAdd {
        track_id: "t1".into(),
        device_id: "d1".into(),
        kind: DeviceKind::Synth,
    })
    .unwrap();
    let mut q = p.clone();
    p.tracks[0].devices[0]
        .extra
        .insert("futureField".into(), json!(7));
    assert_refused(
        &mut p,
        Cmd::TrackRemove {
            track_id: "t1".into(),
        },
        UNRESTORABLE,
    );
    // Stored params USED to be the second guard, because this build shipped no
    // command that could write one back. `device.param.set` does, so the guard
    // is gone and the restore sequence carries the authored sound instead —
    // which is the property the guard was standing in for. Asserted here, one
    // level up, because `track.remove` is the back door around `device.remove`.
    q.apply_cmd(&Cmd::DeviceParamSet {
        track_id: "t1".into(),
        device_id: "d1".into(),
        key: "cutoff".into(),
        value: Num::int(800),
    })
    .unwrap();
    let effect = q
        .apply_cmd(&Cmd::TrackRemove {
            track_id: "t1".into(),
        })
        .expect("a track whose synth has an authored sound is deletable");
    assert_eq!(
        effect.inverse.iter().map(Cmd::name).collect::<Vec<_>>(),
        ["track.add", "device.add", "device.param.set"],
        "the restore sequence rebuilds the device AND its authored sound"
    );
    for c in &effect.inverse {
        q.apply_cmd(c).unwrap();
    }
    assert_eq!(
        q.track("t1").unwrap().devices[0].params.get("cutoff"),
        Some(&Num::int(800)),
        "undo restored the authored cutoff exactly"
    );
}

#[test]
fn device_remove_refuses_a_device_carrying_unknown_fields() {
    let mut p = with_track();
    p.apply_cmd(&Cmd::DeviceAdd {
        track_id: "t1".into(),
        device_id: "d1".into(),
        kind: DeviceKind::Synth,
    })
    .unwrap();
    p.tracks[0].devices[0]
        .extra
        .insert("futureField".into(), json!(7));
    assert_refused(
        &mut p,
        Cmd::DeviceRemove {
            track_id: "t1".into(),
            device_id: "d1".into(),
        },
        UNRESTORABLE,
    );
}

#[test]
fn clip_and_note_removes_refuse_unknown_fields() {
    let mut p = with_track();
    p.apply_cmd(&Cmd::ClipPlaceMidi {
        clip_id: "m1".into(),
        track_id: "t1".into(),
        start_ticks: 0,
        length_ticks: 1920,
    })
    .unwrap();
    p.apply_cmd(&Cmd::NoteAdd {
        clip_id: "m1".into(),
        notes: vec![NoteSpec {
            note_id: "n1".into(),
            start_ticks: 0,
            length_ticks: 240,
            pitch: 60,
            velocity: Num::int(100),
        }],
    })
    .unwrap();
    let mut q = p.clone();

    // `NoteSpec` carries five of `Note`'s six fields.
    p.tracks[0].clips[0].notes[0]
        .extra
        .insert("futureField".into(), json!(7));
    assert_refused(
        &mut p,
        Cmd::NoteRemove {
            clip_id: "m1".into(),
            note_ids: vec!["n1".into()],
        },
        UNRESTORABLE,
    );
    // ...and removing the CLIP would take the same note with it.
    assert_refused(
        &mut p,
        Cmd::ClipRemove {
            clip_id: "m1".into(),
        },
        UNRESTORABLE,
    );

    q.tracks[0].clips[0]
        .extra
        .insert("futureField".into(), json!(7));
    assert_refused(
        &mut q,
        Cmd::ClipRemove {
            clip_id: "m1".into(),
        },
        UNRESTORABLE,
    );
}

#[test]
fn section_and_marker_removes_refuse_unknown_fields() {
    let mut p = base();
    p.apply_cmd(&Cmd::SectionSet {
        section_id: "s1".into(),
        name: "Verse".into(),
        start_ticks: 0,
        color: None,
    })
    .unwrap();
    p.apply_cmd(&Cmd::MarkerSet {
        marker_id: "mk1".into(),
        position_ticks: 480,
        label: "drop".into(),
        color: None,
    })
    .unwrap();
    p.sections[0].extra.insert("futureField".into(), json!(7));
    p.markers[0].extra.insert("futureField".into(), json!(7));
    assert_refused(
        &mut p,
        Cmd::SectionRemove {
            section_id: "s1".into(),
        },
        UNRESTORABLE,
    );
    assert_refused(
        &mut p,
        Cmd::MarkerRemove {
            marker_id: "mk1".into(),
        },
        UNRESTORABLE,
    );
}

#[test]
fn routing_removes_refuse_unknown_fields_on_the_node_and_on_its_edges() {
    let mut p = with_track();
    p.apply_cmd(&Cmd::RouteNodeAdd {
        node_id: "b1".into(),
        kind: NodeKind::Bus,
        name: "Bus 1".into(),
    })
    .unwrap();
    p.apply_cmd(&Cmd::RouteConnect {
        edge_id: "e1".into(),
        from: NodeRef::Track("t1".into()),
        to: NodeRef::Node("b1".into()),
        level: Num::int(1),
        tap: Tap::Post,
    })
    .unwrap();
    let mut q = p.clone();

    p.routing.nodes[0]
        .extra
        .insert("futureField".into(), json!(7));
    assert_refused(
        &mut p,
        Cmd::RouteNodeRemove {
            node_id: "b1".into(),
        },
        UNRESTORABLE,
    );

    // An edge's unknown fields die with the node, and with the TRACK, so both
    // removals have to see them.
    q.routing.edges[0]
        .extra
        .insert("futureField".into(), json!(7));
    assert_refused(
        &mut q,
        Cmd::RouteDisconnect {
            edge_id: "e1".into(),
        },
        UNRESTORABLE,
    );
    assert_refused(
        &mut q,
        Cmd::RouteNodeRemove {
            node_id: "b1".into(),
        },
        UNRESTORABLE,
    );
    assert_refused(
        &mut q,
        Cmd::TrackRemove {
            track_id: "t1".into(),
        },
        UNRESTORABLE,
    );
}

// ---------------------------------------------------------------------------
// 5. The copy commands. A NEW id inherits no unknown fields — otherwise the
//    guards above would make `clip.split`/`clip.duplicate`/`note.duplicate`
//    un-undoable, since each one's inverse REMOVES the copy it just made.
// ---------------------------------------------------------------------------

#[test]
fn a_copied_object_carries_no_inherited_unknown_fields() {
    let mut p = with_track();
    p.apply_cmd(&Cmd::ClipPlace {
        clip_id: "c1".into(),
        track_id: "t1".into(),
        asset_hash: "srcA".into(),
        start_ticks: 0,
        length_ticks: 1920,
        source_offset_ticks: None,
    })
    .unwrap();
    p.tracks[0].clips[0]
        .extra
        .insert("futureField".into(), json!(7));
    let mut q = p.clone();

    assert_roundtrip(
        &mut p,
        Cmd::ClipSplit {
            clip_id: "c1".into(),
            at_ticks: 960,
            new_clip_id: "c2".into(),
        },
    );
    assert_roundtrip(
        &mut q,
        Cmd::ClipDuplicate {
            clip_id: "c1".into(),
            new_clip_id: "c2".into(),
            start_ticks: 1920,
        },
    );
    // The ORIGINAL keeps them either way.
    assert_eq!(q.clip("c1").unwrap().extra.len(), 1);

    let mut m = with_track();
    m.apply_cmd(&Cmd::ClipPlaceMidi {
        clip_id: "m1".into(),
        track_id: "t1".into(),
        start_ticks: 0,
        length_ticks: 1920,
    })
    .unwrap();
    m.apply_cmd(&Cmd::NoteAdd {
        clip_id: "m1".into(),
        notes: vec![NoteSpec {
            note_id: "n1".into(),
            start_ticks: 0,
            length_ticks: 240,
            pitch: 60,
            velocity: Num::int(100),
        }],
    })
    .unwrap();
    m.tracks[0].clips[0].notes[0]
        .extra
        .insert("futureField".into(), json!(7));
    assert_roundtrip(
        &mut m,
        Cmd::NoteDuplicate {
            clip_id: "m1".into(),
            note_ids: vec!["n1".into()],
            new_note_ids: vec!["n2".into()],
            delta_ticks: 480,
            delta_pitch: 0,
        },
    );
}

// ---------------------------------------------------------------------------
// 6. The generator hole itself. A command family the Conductor never emits is
//    a family whose inverse exactness is never property-tested, which is the
//    single reason this whole file was needed.
// ---------------------------------------------------------------------------

#[path = "support.rs"]
mod support;

#[test]
fn the_conductor_reaches_every_destructive_command_family() {
    use std::collections::BTreeSet;
    let mut seen: BTreeSet<&'static str> = BTreeSet::new();
    // The orphaned-autopoint bug survived the property suite because the
    // remove-object-then-edit-its-dead-lane ORDERING, while reachable, was
    // never actually drawn. Coverage of the family is not coverage of the
    // ordering, so both are counted and both are asserted.
    let mut dead_lane_edits = 0usize; // autopoint.remove/move / autolane.clear on a DEAD lane
    let mut dead_lane_adds = 0usize; // autopoint.add on a dead or never-existed path
    // Same driver shape as the fuzz, but recording NAMES rather than asserting
    // invariants: this is the coverage guard for the generator.
    for seed in [0xC0FFEEu64, 0xDEADBEEF, 0x1234_5678_9ABC] {
        let mut c = support::Conductor::new(seed);
        let mut project = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
        for _ in 0..8_000 {
            let cmd = c.gen(&project);
            let dead = match &cmd {
                Cmd::AutopointAdd { track_id, target, .. }
                | Cmd::AutopointMove { track_id, target, .. }
                | Cmd::AutopointRemove { track_id, target, .. }
                | Cmd::AutolaneClear { track_id, target } => project
                    .track_index(track_id)
                    .map(|ti| support::lane_is_dead(&project, ti, target))
                    .unwrap_or(false),
                _ => false,
            };
            // DETERMINISTIC INVERSE PROBE on the dead-lane class. The 120-case
            // proptest run proved unable to reliably draw the three-event
            // ordering (author lane -> remove object -> edit dead lane), so a
            // reverted fix could sail through it on seed luck. This drive is
            // seeded and 24k steps long; the moment it draws a dead-lane edit
            // it proves the inverse restores the exact pre-state — which is
            // precisely the assertion that was refused before the existence
            // widening ("no such device on this track; device.add it first").
            if dead {
                let pre = project.clone();
                let mut probe = pre.clone();
                if let Ok(eff) = probe.apply_cmd(&cmd) {
                    for inv in &eff.inverse {
                        probe.apply_cmd(inv).unwrap_or_else(|e| {
                            panic!(
                                "inverse of {} on a dead lane was refused: {e}",
                                cmd.name()
                            )
                        });
                    }
                    assert!(
                        pre == probe,
                        "inverse of {} on a dead lane did not restore the pre-state",
                        cmd.name()
                    );
                }
            }
            if project.apply_cmd(&cmd).is_ok() {
                seen.insert(cmd.name());
                if dead {
                    match &cmd {
                        Cmd::AutopointAdd { .. } => dead_lane_adds += 1,
                        _ => dead_lane_edits += 1,
                    }
                }
            }
        }
    }
    assert!(
        dead_lane_edits > 0,
        "no generated sequence ever edited a DEAD lane (remove object, then \
         remove/clear its stray points) — the exact ordering behind the \
         orphaned-autopoint undo bug is out of the property net again"
    );
    assert!(
        dead_lane_adds > 0,
        "no generated sequence ever authored a lane on a dead/never-existed \
         path — the widening's chosen forward-legality is out of the property \
         net"
    );
    for required in [
        "track.remove",
        "clip.remove",
        "device.add",
        "device.remove",
        "device.zone.add",
        "device.zone.remove",
        "fx.add",
        "fx.remove",
        "fx.param.set",
        "autopoint.remove",
        "autolane.clear",
        "route.node.add",
        "route.node.remove",
        "route.node.set",
        "route.connect",
        "route.disconnect",
        "mix.pan",
        "mix.send",
        "track.solo",
        "track.arm",
        "track.setHeight",
        "track.reorder",
        "clip.phaseAnchor.set",
    ] {
        assert!(
            seen.contains(required),
            "the Conductor never successfully applied `{required}`; a family it \
             cannot generate is a family the property suite cannot test. Seen: {seen:?}"
        );
    }
}

// ---------------------------------------------------------------------------
// 7. Orphaned-lane undo: a forward-legal removal whose inverse was refused.
//
//    `autopoint.remove` / `autolane.clear` deliberately skip
//    `require_param_ref_on` ("DELETING is never refused"), and
//    `device.remove` / `fx.remove` / `route.node.remove` / `route.disconnect`
//    deliberately KEEP lanes that reference the removed object. So a user who
//    automates a device, removes the device, tidies the stray point, and
//    presses undo handed `Session::undo` an inverse `autopoint.add` that the
//    forward command never had to survive — and the EXISTENCE half of
//    `require_param_ref_on` refused it. A journal every binary accepts
//    forward, whose recorded inverse cannot be applied: a truthful-inverse
//    violation, one truth-level up from the device-restore bug in section 1.
//
//    The fix WIDENS `require_param_ref_on` for the lane family: the
//    model-state existence checks (device / fx / bus node / routing edge
//    present) drop to well-formedness + build-static key checks. The loud
//    gate lives at render compile, which refuses an unreadable lane BY NAME
//    (render/tests/inert_lanes.rs::a_lane_with_no_reader_is_refused_loudly,
//    ::an_fx_lane_naming_a_missing_fx_is_refused_loudly) — that gate already
//    had to exist, because stranding was always reachable.
// ---------------------------------------------------------------------------

fn submit_all(s: &mut Session, cmds: &[Cmd], n0: u64) -> u64 {
    let mut n = n0;
    for c in cmds {
        s.submit(
            timeline_core::envelope::EntryMeta {
                id: format!("{:026}", n),
                ts: format!("2026-01-01T00:{:02}:{:02}Z", n / 60 % 60, n % 60),
                actor: Actor::user("aaron"),
            },
            c.clone(),
        )
        .unwrap_or_else(|e| panic!("{} refused: {e}", c.name()));
        n += 1;
    }
    n
}

/// One shape, four lane families. `pre` = the state the single undo must
/// restore (taken just before the last command).
fn assert_undo_of_last_restores(setup: Vec<Cmd>, last: Cmd) {
    let mut s = Session::new(base());
    let n = submit_all(&mut s, &setup, 1);
    let pre = s.project().clone();
    let n = submit_all(&mut s, std::slice::from_ref(&last), n);
    let mut meta = SeqMeta::starting_at(n, Actor::user("undo"));
    // THE assertion: before the widening this returned
    // UnknownParameter("...no such device on this track; device.add it first").
    s.undo(&mut meta)
        .unwrap_or_else(|e| panic!("undo of {} was refused: {e}", last.name()));
    assert!(
        pre == *s.project(),
        "undo of {} did not restore the pre-state",
        last.name()
    );
    // And the whole journal still replays to the live model, chain intact.
    let replayed = Session::replay(base(), s.journal().to_vec()).expect("replay");
    assert!(replayed.project() == s.project(), "replay diverged");
    assert_eq!(replayed.tip_hash(), s.tip_hash());
}

#[test]
fn undo_restores_a_point_removed_from_a_dead_device_lane() {
    // The exact five-command repro, verbatim.
    assert_undo_of_last_restores(
        vec![
            Cmd::TrackAdd {
                track_id: "t1".into(),
                name: "T1".into(),
                index: None,
            },
            Cmd::DeviceAdd {
                track_id: "t1".into(),
                device_id: "dev0".into(),
                kind: DeviceKind::Synth,
            },
            Cmd::AutopointAdd {
                track_id: "t1".into(),
                target: ParamRef::parse("track.device.dev0.sustain").unwrap(),
                point_id: "p0".into(),
                position_ticks: 480,
                value: Num::int(2),
            },
            Cmd::DeviceRemove {
                track_id: "t1".into(),
                device_id: "dev0".into(),
            },
        ],
        Cmd::AutopointRemove {
            track_id: "t1".into(),
            target: ParamRef::parse("track.device.dev0.sustain").unwrap(),
            point_id: "p0".into(),
        },
    );
}

#[test]
fn undo_restores_a_point_removed_from_a_dead_fx_lane() {
    assert_undo_of_last_restores(
        vec![
            Cmd::TrackAdd {
                track_id: "t1".into(),
                name: "T1".into(),
                index: None,
            },
            Cmd::FxAdd {
                target: NodeRef::Track("t1".into()),
                fx_id: "f0".into(),
                kind: FxKind::Compressor,
            },
            Cmd::AutopointAdd {
                track_id: "t1".into(),
                target: ParamRef::parse("track.fx.f0.mix").unwrap(),
                point_id: "p0".into(),
                position_ticks: 480,
                value: Num::int(1),
            },
            Cmd::FxRemove {
                target: NodeRef::Track("t1".into()),
                fx_id: "f0".into(),
            },
        ],
        Cmd::AutopointRemove {
            track_id: "t1".into(),
            target: ParamRef::parse("track.fx.f0.mix").unwrap(),
            point_id: "p0".into(),
        },
    );
}

#[test]
fn undo_restores_a_point_removed_from_a_dead_bus_gain_lane() {
    assert_undo_of_last_restores(
        vec![
            Cmd::TrackAdd {
                track_id: "t1".into(),
                name: "T1".into(),
                index: None,
            },
            Cmd::RouteNodeAdd {
                node_id: "b0".into(),
                kind: NodeKind::Bus,
                name: "Bus 0".into(),
            },
            Cmd::AutopointAdd {
                track_id: "t1".into(),
                target: ParamRef::parse("bus.b0.gain").unwrap(),
                point_id: "p0".into(),
                position_ticks: 480,
                value: Num::int(-3),
            },
            Cmd::RouteNodeRemove {
                node_id: "b0".into(),
            },
        ],
        Cmd::AutopointRemove {
            track_id: "t1".into(),
            target: ParamRef::parse("bus.b0.gain").unwrap(),
            point_id: "p0".into(),
        },
    );
}

#[test]
fn undo_restores_a_point_removed_from_a_dead_edge_level_lane() {
    assert_undo_of_last_restores(
        vec![
            Cmd::TrackAdd {
                track_id: "t1".into(),
                name: "T1".into(),
                index: None,
            },
            Cmd::RouteConnect {
                edge_id: "e1".into(),
                from: NodeRef::Track("t1".into()),
                to: NodeRef::Master,
                level: Num::int(1),
                tap: Tap::Post,
            },
            Cmd::AutopointAdd {
                track_id: "t1".into(),
                target: ParamRef::parse("route.edge.e1.level").unwrap(),
                point_id: "p0".into(),
                position_ticks: 480,
                value: Num::int(1),
            },
            Cmd::RouteDisconnect {
                edge_id: "e1".into(),
            },
        ],
        Cmd::AutopointRemove {
            track_id: "t1".into(),
            target: ParamRef::parse("route.edge.e1.level").unwrap(),
            point_id: "p0".into(),
        },
    );
}

#[test]
fn undo_restores_a_lane_cleared_after_its_device_died() {
    // autolane.clear's inverse is N x autopoint.add — the multi-command
    // variant of the same violation.
    assert_undo_of_last_restores(
        vec![
            Cmd::TrackAdd {
                track_id: "t1".into(),
                name: "T1".into(),
                index: None,
            },
            Cmd::DeviceAdd {
                track_id: "t1".into(),
                device_id: "dev0".into(),
                kind: DeviceKind::Synth,
            },
            Cmd::AutopointAdd {
                track_id: "t1".into(),
                target: ParamRef::parse("track.device.dev0.cutoff").unwrap(),
                point_id: "p0".into(),
                position_ticks: 0,
                value: Num::int(1),
            },
            Cmd::AutopointAdd {
                track_id: "t1".into(),
                target: ParamRef::parse("track.device.dev0.cutoff").unwrap(),
                point_id: "p1".into(),
                position_ticks: 960,
                value: Num::int(3),
            },
            Cmd::DeviceRemove {
                track_id: "t1".into(),
                device_id: "dev0".into(),
            },
        ],
        Cmd::AutolaneClear {
            track_id: "t1".into(),
            target: ParamRef::parse("track.device.dev0.cutoff").unwrap(),
        },
    );
}

#[test]
fn undo_of_track_remove_restores_an_edge_level_lane_before_its_edge() {
    // THE HALF-RESTORE. track.remove's restore sequence replays automation
    // (inside track_restore_sequence) BEFORE it re-connects the track's
    // incident edges (appended after). With the existence check in place the
    // sequence refused at the lane point, mid-undo — and Session::undo pops
    // the unit before applying with `?`, so the model was left half-restored
    // (track back, lane and edge gone) and the unit destroyed. The forward
    // guard could not see it: at guard time the edge still existed.
    let mut s = Session::new(base());
    let n = submit_all(
        &mut s,
        &[
            Cmd::TrackAdd {
                track_id: "t1".into(),
                name: "T1".into(),
                index: None,
            },
            Cmd::RouteConnect {
                edge_id: "e1".into(),
                from: NodeRef::Track("t1".into()),
                to: NodeRef::Master,
                level: Num::int(1),
                tap: Tap::Post,
            },
            Cmd::AutopointAdd {
                track_id: "t1".into(),
                target: ParamRef::parse("route.edge.e1.level").unwrap(),
                point_id: "p0".into(),
                position_ticks: 0,
                value: Num::int(1),
            },
        ],
        1,
    );
    let pre = s.project().clone();
    let n = submit_all(
        &mut s,
        &[Cmd::TrackRemove {
            track_id: "t1".into(),
        }],
        n,
    );
    let mut meta = SeqMeta::starting_at(n, Actor::user("undo"));
    s.undo(&mut meta)
        .unwrap_or_else(|e| panic!("undo of track.remove was refused mid-sequence: {e}"));
    assert!(
        pre == *s.project(),
        "undo of track.remove left the model half-restored"
    );
}

#[test]
fn undo_then_redo_is_identity_over_the_repro_sequence() {
    let mut s = Session::new(base());
    let n = submit_all(
        &mut s,
        &[
            Cmd::TrackAdd {
                track_id: "t1".into(),
                name: "T1".into(),
                index: None,
            },
            Cmd::DeviceAdd {
                track_id: "t1".into(),
                device_id: "dev0".into(),
                kind: DeviceKind::Synth,
            },
            Cmd::AutopointAdd {
                track_id: "t1".into(),
                target: ParamRef::parse("track.device.dev0.sustain").unwrap(),
                point_id: "p0".into(),
                position_ticks: 480,
                value: Num::int(2),
            },
            Cmd::DeviceRemove {
                track_id: "t1".into(),
                device_id: "dev0".into(),
            },
            Cmd::AutopointRemove {
                track_id: "t1".into(),
                target: ParamRef::parse("track.device.dev0.sustain").unwrap(),
                point_id: "p0".into(),
            },
        ],
        1,
    );
    let end = s.project().clone();
    let depth = s.undo_depth();
    let mut meta = SeqMeta::starting_at(n, Actor::user("undo"));
    let mut undone = 0;
    while s.undo(&mut meta).expect("undo") {
        undone += 1;
    }
    assert_eq!(undone, depth);
    assert_eq!(s.project().tracks.len(), 0, "full undo reaches baseline");
    let mut redone = 0;
    while s.redo(&mut meta).expect("redo") {
        redone += 1;
    }
    assert_eq!(redone, depth);
    assert!(end == *s.project(), "undo+redo changed state");
}

// ---- the consequences the widening chooses, asserted so they are chosen ----

#[test]
fn autopoint_add_on_a_never_existed_path_is_forward_legal_and_round_trips() {
    // A typo'd device id now LANDS in the model instead of being refused at
    // apply time. That is the deliberate trade: the model can represent it,
    // the checkpoint preserves it, and the loud refusal happens at render
    // compile, BY NAME, with a remedy (render/tests/inert_lanes.rs) — the same
    // gate that already caught the stranded version of the same lane. Chosen,
    // not accidental: this test is the choice.
    let mut p = with_track();
    for target in [
        "track.device.ghost.cutoff",
        "track.fx.ghost.mix",
        "bus.ghost.gain",
        "route.edge.ghost.level",
    ] {
        let mut q = p.clone();
        assert_roundtrip(
            &mut q,
            Cmd::AutopointAdd {
                track_id: "t1".into(),
                target: ParamRef::parse(target).unwrap(),
                point_id: "p0".into(),
                position_ticks: 0,
                value: Num::int(1),
            },
        );
        // ...and the add itself lands.
        q.apply_cmd(&Cmd::AutopointAdd {
            track_id: "t1".into(),
            target: ParamRef::parse(target).unwrap(),
            point_id: "p0".into(),
            position_ticks: 0,
            value: Num::int(1),
        })
        .unwrap_or_else(|e| panic!("{target} should be forward-legal now: {e}"));
        assert_eq!(
            q.tracks[0]
                .automation
                .lane(&ParamRef::parse(target).unwrap())
                .len(),
            1
        );
    }
    let _ = &mut p;
}

#[test]
fn autopoint_move_works_on_a_dead_lane_too() {
    // Same rule, same reason: before the widening you could REMOVE a stray
    // point but not MOVE it, and the inverse of a legal pre-removal move was
    // refused at undo time.
    let mut p = with_track();
    p.apply_cmd(&Cmd::DeviceAdd {
        track_id: "t1".into(),
        device_id: "dev0".into(),
        kind: DeviceKind::Synth,
    })
    .unwrap();
    p.apply_cmd(&Cmd::AutopointAdd {
        track_id: "t1".into(),
        target: ParamRef::parse("track.device.dev0.cutoff").unwrap(),
        point_id: "p0".into(),
        position_ticks: 0,
        value: Num::int(1),
    })
    .unwrap();
    p.apply_cmd(&Cmd::DeviceRemove {
        track_id: "t1".into(),
        device_id: "dev0".into(),
    })
    .unwrap();
    assert_roundtrip(
        &mut p,
        Cmd::AutopointMove {
            track_id: "t1".into(),
            target: ParamRef::parse("track.device.dev0.cutoff").unwrap(),
            point_id: "p0".into(),
            position_ticks: 960,
            value: Num::int(4),
        },
    );
}

#[test]
fn the_wellformedness_floor_still_refuses_what_no_build_state_could_make_real() {
    // The widening dropped MODEL-STATE lookups, nothing else. Everything
    // build-static still refuses at apply time, because accepting it could
    // never become right: no sequence of commands makes `zzz` an instrument
    // parameter or gives v1 a third send.
    let mut p = with_track();
    for (target, why) in [
        ("track.device.dev0.zzz", "not an instrument parameter"),
        ("track.fx.f0.zzz", "not an effect parameter"),
        ("bus.b0.fx.f0.zzz", "not an effect parameter"),
        ("master.fx.f0.zzz", "not an effect parameter"),
        ("track.eq.9.gain", "4 bands"),
        ("track.send.z.level", "exactly two sends"),
        ("master.limiter.wobble", "ceiling"),
        ("totally.made.up", "not a parameter"),
    ] {
        let err = p
            .apply_cmd(&Cmd::AutopointAdd {
                track_id: "t1".into(),
                target: ParamRef::parse(target).unwrap(),
                point_id: "px".into(),
                position_ticks: 0,
                value: Num::int(0),
            })
            .expect_err(&format!("{target} must stay refused"));
        assert!(
            err.to_string().contains(why),
            "{target}: wrong refusal: {err}"
        );
    }
}

#[test]
fn track_remove_round_trips_stranded_lanes_now() {
    // Section 2's guard tests asserted REFUSAL here, because the restore
    // sequence's autopoint.add could not survive. The widening makes the
    // restore sequence total for every path this build can author, so the
    // same setups now round-trip exactly — the strictly better outcome the
    // guard was standing in for.
    for strand in ["device", "fx"] {
        let mut p = with_track();
        match strand {
            "device" => {
                p.apply_cmd(&Cmd::DeviceAdd {
                    track_id: "t1".into(),
                    device_id: "d1".into(),
                    kind: DeviceKind::Synth,
                })
                .unwrap();
                p.apply_cmd(&Cmd::AutopointAdd {
                    track_id: "t1".into(),
                    target: ParamRef::parse("track.device.d1.cutoff").unwrap(),
                    point_id: "ap1".into(),
                    position_ticks: 480,
                    value: Num::int(3),
                })
                .unwrap();
                p.apply_cmd(&Cmd::DeviceRemove {
                    track_id: "t1".into(),
                    device_id: "d1".into(),
                })
                .unwrap();
            }
            _ => {
                p.apply_cmd(&Cmd::FxAdd {
                    target: NodeRef::Track("t1".into()),
                    fx_id: "f1".into(),
                    kind: FxKind::Compressor,
                })
                .unwrap();
                p.apply_cmd(&Cmd::AutopointAdd {
                    track_id: "t1".into(),
                    target: ParamRef::parse("track.fx.f1.threshold").unwrap(),
                    point_id: "ap1".into(),
                    position_ticks: 480,
                    value: Num::int(-10),
                })
                .unwrap();
                p.apply_cmd(&Cmd::FxRemove {
                    target: NodeRef::Track("t1".into()),
                    fx_id: "f1".into(),
                })
                .unwrap();
            }
        }
        assert_roundtrip(
            &mut p,
            Cmd::TrackRemove {
                track_id: "t1".into(),
            },
        );
    }
}

#[test]
fn track_remove_still_refuses_a_lane_this_build_cannot_reauthor() {
    // The guard's remaining, honest job: a lane whose KEY this build does not
    // know (only reachable from a newer build's checkpoint — autopoint.add
    // refuses it live). Its restore autopoint.add would be refused mid-undo,
    // so the remove must refuse up front, with the remedy named.
    let mut p = with_track();
    p.tracks[0].automation.lanes.insert(
        ParamRef::parse("track.device.d1.zzz").unwrap(),
        vec![timeline_core::model::AutoPoint {
            id: "ap1".into(),
            position_ticks: 0,
            value: Num::int(1),
            extra: Default::default(),
        }],
    );
    assert_refused(
        &mut p,
        Cmd::TrackRemove {
            track_id: "t1".into(),
        },
        "track.device.d1.zzz",
    );
    // The named remedy still works on the dead path.
    p.apply_cmd(&Cmd::AutolaneClear {
        track_id: "t1".into(),
        target: ParamRef::parse("track.device.d1.zzz").unwrap(),
    })
    .unwrap();
    assert_roundtrip(
        &mut p,
        Cmd::TrackRemove {
            track_id: "t1".into(),
        },
    );
}
