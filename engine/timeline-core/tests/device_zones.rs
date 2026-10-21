//! The E2 SOURCE BINDING at the model layer: `device.zone.add` /
//! `device.zone.remove`, their inverses, checkpoint round-trip, and the
//! additive-serialization guarantee.
//!
//! The audio proof lives render-side (`render/tests/sampler_binding.rs`) —
//! this file only claims what a model test can honestly claim.

use serde_json::json;
use timeline_core::cmd::Cmd;
use timeline_core::model::{DeviceKind, DeviceZone, Project, Track};
use timeline_core::num::Num;
use timeline_core::tempo::{Bpm, TempoMap};
use timeline_core::Source;

fn seeded(kind: DeviceKind) -> Project {
    let mut p = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    p.add_source(Source {
        id: "srcA".into(),
        path: "/tmp/a.wav".into(),
        len_frames: 48_000,
    })
    .unwrap();
    p.tracks.push(Track::new("t1", "Track 1"));
    p.apply_cmd(&Cmd::DeviceAdd {
        track_id: "t1".into(),
        device_id: "dev1".into(),
        kind,
    })
    .unwrap();
    p
}

fn zone_add(zone_id: &str, lo: i64, hi: i64, root: i64) -> Cmd {
    Cmd::DeviceZoneAdd {
        track_id: "t1".into(),
        device_id: "dev1".into(),
        zone_id: zone_id.into(),
        source_id: "srcA".into(),
        root_pitch: Num::int(root),
        lo_pitch: Num::int(lo),
        hi_pitch: Num::int(hi),
        gain_db: None,
        pan: None,
    }
}

fn zones(p: &Project) -> Vec<String> {
    p.track("t1").unwrap().devices[0]
        .zones
        .iter()
        .map(|z| z.id.clone())
        .collect()
}

// ---------------------------------------------------------------------------
// The binding itself
// ---------------------------------------------------------------------------

#[test]
fn a_zone_binds_a_source_id_to_a_key_range() {
    let mut p = seeded(DeviceKind::Sampler);
    p.apply_cmd(&zone_add("z1", 0, 127, 60)).unwrap();
    let z = &p.track("t1").unwrap().devices[0].zones[0];
    assert_eq!(z.source_id, "srcA", "the zone names the SAME asset id a clip does");
    assert_eq!(z.lo_pitch, Num::int(0));
    assert_eq!(z.hi_pitch, Num::int(127));
    assert_eq!(z.root_pitch, Num::int(60));
    assert_eq!(z.gain, Num::int(0), "gain defaults to integer-shaped 0");
    assert_eq!(z.pan, Num::int(0));
}

#[test]
fn zones_are_stored_in_a_total_deterministic_order() {
    // Insert out of order, twice, from different insertion orders. The stored
    // order must be `(lo_pitch, id)` both times — nondeterministic ordering
    // changes serialized bytes AND changes which overlapping zone wins.
    let mut a = seeded(DeviceKind::Sampler);
    for (id, lo) in [("zc", 60), ("za", 0), ("zb", 60)] {
        a.apply_cmd(&zone_add(id, lo, 127, 60)).unwrap();
    }
    let mut b = seeded(DeviceKind::Sampler);
    for (id, lo) in [("zb", 60), ("zc", 60), ("za", 0)] {
        b.apply_cmd(&zone_add(id, lo, 127, 60)).unwrap();
    }
    assert_eq!(zones(&a), ["za", "zb", "zc"]);
    assert_eq!(zones(&a), zones(&b), "order is a function of content, not insertion");
}

#[test]
fn a_synth_cannot_carry_a_zone() {
    let mut p = seeded(DeviceKind::Synth);
    let err = p.apply_cmd(&zone_add("z1", 0, 127, 60)).unwrap_err();
    assert!(
        err.to_string().contains("reads no audio"),
        "a zone on a synth would be state that renders nothing: {err}"
    );
}

#[test]
fn a_drum_pad_is_exactly_one_key() {
    let mut p = seeded(DeviceKind::Drum);
    let err = p.apply_cmd(&zone_add("z1", 36, 40, 36)).unwrap_err();
    assert!(err.to_string().contains("exactly one key"), "{err}");
    p.apply_cmd(&zone_add("z1", 36, 36, 36)).expect("one key is fine");
}

#[test]
fn pitches_are_integer_shaped_and_in_range() {
    let mut p = seeded(DeviceKind::Sampler);
    // `60.0` is accepted by a JSON Schema `integer`, but `Num` hashes it
    // differently from `60`, so the shape has to be refused here.
    let float_shaped: Num = serde_json::from_str("60.0").unwrap();
    let mut cmd = zone_add("z1", 0, 127, 60);
    if let Cmd::DeviceZoneAdd { root_pitch, .. } = &mut cmd {
        *root_pitch = float_shaped;
    }
    let err = p.apply_cmd(&cmd).unwrap_err();
    assert!(err.to_string().contains("float-shaped"), "{err}");

    let err = p.apply_cmd(&zone_add("z2", 0, 128, 60)).unwrap_err();
    assert!(err.to_string().contains("outside [0, 127]"), "{err}");

    let err = p.apply_cmd(&zone_add("z3", 80, 40, 60)).unwrap_err();
    assert!(err.to_string().contains("below loPitch"), "{err}");

    assert!(zones(&p).is_empty(), "no partial application");
}

// ---------------------------------------------------------------------------
// Inverses — the contract the journal carries forever
// ---------------------------------------------------------------------------

#[test]
fn zone_add_and_remove_are_exact_inverses_of_each_other() {
    let mut p = seeded(DeviceKind::Sampler);
    let pre_empty = p.clone();
    let add = Cmd::DeviceZoneAdd {
        track_id: "t1".into(),
        device_id: "dev1".into(),
        zone_id: "z1".into(),
        source_id: "srcA".into(),
        root_pitch: Num::int(36),
        lo_pitch: Num::int(24),
        hi_pitch: Num::int(48),
        gain_db: Some(Num::int(-6)),
        pan: Some(Num::int(1)),
    };
    let eff = p.apply_cmd(&add).unwrap();
    assert_eq!(eff.inverse.len(), 1);
    assert_eq!(eff.hint.as_ref().unwrap().name(), "device.zone.remove");
    let with_zone = p.clone();

    // add -> inverse -> back to empty, exactly.
    for inv in &eff.inverse {
        p.apply_cmd(inv).unwrap();
    }
    assert!(pre_empty == p, "device.zone.remove did not restore the pre-state");

    // remove -> inverse -> back to the zone, exactly, gain and pan included.
    let mut p = with_zone.clone();
    let eff = p
        .apply_cmd(&Cmd::DeviceZoneRemove {
            track_id: "t1".into(),
            device_id: "dev1".into(),
            zone_id: "z1".into(),
        })
        .unwrap();
    assert_eq!(eff.hint.as_ref().unwrap().name(), "device.zone.add");
    for inv in &eff.inverse {
        p.apply_cmd(inv).unwrap();
    }
    assert!(
        with_zone == p,
        "device.zone.add did not restore a customized zone exactly"
    );
}

#[test]
fn removing_a_device_restores_its_zones_too() {
    let mut p = seeded(DeviceKind::Sampler);
    p.apply_cmd(&zone_add("z1", 0, 59, 40)).unwrap();
    p.apply_cmd(&zone_add("z2", 60, 127, 72)).unwrap();
    let before = p.clone();

    let eff = p
        .apply_cmd(&Cmd::DeviceRemove {
            track_id: "t1".into(),
            device_id: "dev1".into(),
        })
        .unwrap();
    // The hint stays the single declared name; the runtime undo is a sequence.
    assert_eq!(eff.hint.as_ref().unwrap().name(), "device.add");
    assert_eq!(eff.inverse.len(), 3, "device.add + one zone.add per zone");
    for inv in &eff.inverse {
        p.apply_cmd(inv).unwrap();
    }
    assert!(
        before == p,
        "undoing device.remove lost the source bindings — a sampler would come back silent"
    );
}

#[test]
fn a_zone_carrying_unrestorable_fields_refuses_to_be_removed() {
    // A zone written by a NEWER build can carry fields no command here names.
    // Dropping them on an undo is data loss, so both removes refuse.
    let mut p = seeded(DeviceKind::Sampler);
    p.apply_cmd(&zone_add("z1", 0, 127, 60)).unwrap();
    let dev = &mut p.tracks[0].devices[0];
    dev.zones[0]
        .extra
        .insert("roundRobin".into(), json!(["a", "b"]));

    let err = p
        .apply_cmd(&Cmd::DeviceZoneRemove {
            track_id: "t1".into(),
            device_id: "dev1".into(),
            zone_id: "z1".into(),
        })
        .unwrap_err();
    assert!(err.to_string().contains("not be undoable"), "{err}");

    let err = p
        .apply_cmd(&Cmd::DeviceRemove {
            track_id: "t1".into(),
            device_id: "dev1".into(),
        })
        .unwrap_err();
    assert!(err.to_string().contains("not be undoable"), "{err}");
    assert_eq!(zones(&p), ["z1"], "nothing was partially applied");
}

// ---------------------------------------------------------------------------
// Serialization: additive, and NOT destroyed by the hand-built checkpoint
// ---------------------------------------------------------------------------

#[test]
fn a_device_without_zones_serializes_byte_identically() {
    // The additive guarantee, at the derived-serde layer: `zones` must not
    // appear at all on a device that has none.
    let p = seeded(DeviceKind::Synth);
    let json = serde_json::to_string(&p.track("t1").unwrap().devices[0]).unwrap();
    assert_eq!(
        json, r#"{"id":"dev1","kind":"synth"}"#,
        "adding `zones` changed an existing device's bytes"
    );
}

#[test]
fn zones_survive_the_hand_built_checkpoint_round_trip() {
    // `package.rs` writes a HAND-BUILT checkpoint, not the derived
    // serialization. A field it forgets is DESTROYED on save, not ignored
    // (E0 §9.3) — which for this feature means a saved sampler reopens silent.
    use timeline_core::package::{from_project_json, to_project_json};
    use timeline_core::session::Session;
    let mut p = seeded(DeviceKind::Sampler);
    p.apply_cmd(&Cmd::DeviceZoneAdd {
        track_id: "t1".into(),
        device_id: "dev1".into(),
        zone_id: "z1".into(),
        source_id: "srcA".into(),
        root_pitch: Num::int(69),
        lo_pitch: Num::int(48),
        hi_pitch: Num::int(72),
        gain_db: Some(Num::int(-3)),
        pan: Some(Num::int(1)),
    })
    .unwrap();
    p.apply_cmd(&zone_add("z2", 73, 127, 84)).unwrap();
    let expected = p.track("t1").unwrap().devices[0].zones.clone();

    let cp = to_project_json(&Session::new(p));
    let round = from_project_json(&cp).expect("checkpoint parses");
    assert_eq!(
        round.track("t1").unwrap().devices[0].zones, expected,
        "the checkpoint lost or mangled the source bindings"
    );
    // And the defaulted zone really did round-trip as integer-shaped defaults.
    let z2 = round.track("t1").unwrap().devices[0].zone("z2").unwrap();
    assert_eq!(z2.gain, DeviceZone::default_gain());
    assert_eq!(z2.pan, DeviceZone::default_pan());
}

#[test]
fn a_zone_naming_no_source_is_dropped_on_load_not_defaulted() {
    use timeline_core::package::{from_project_json, to_project_json};
    use timeline_core::session::Session;
    let mut p = seeded(DeviceKind::Sampler);
    p.apply_cmd(&zone_add("z1", 0, 127, 60)).unwrap();
    let mut cp = to_project_json(&Session::new(p));
    cp["tracks"][0]["devices"][0]["zones"]
        .as_array_mut()
        .unwrap()[0]
        .as_object_mut()
        .unwrap()
        .remove("sourceId");
    let round = from_project_json(&cp).expect("checkpoint parses");
    assert!(
        round.track("t1").unwrap().devices[0].zones.is_empty(),
        "a binding that names no asset must be dropped, never defaulted to \"\""
    );
}
