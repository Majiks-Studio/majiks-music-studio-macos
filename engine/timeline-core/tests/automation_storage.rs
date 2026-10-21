//! Automation storage under catalog v2 (`DESIGN-catalog-v2.md` §3/§4).
//!
//! The properties that matter, in the order they can bite:
//!   1. `track.volume` / `track.pan` render byte-identically to v1.1.
//!   2. An unknown-but-well-formed ParamRef survives load→save byte-identically.
//!   3. Exactly ONE storage location per ParamRef.
//!   4. Serialization is deterministic regardless of insertion order.

use serde_json::{json, Value};
use timeline_core::model::{AutoPoint, AutoTarget, Automation, Project};
use timeline_core::num::Num;
use timeline_core::package::{from_project_json, to_project_json};
use timeline_core::session::Session;
use timeline_core::tempo::{Bpm, TempoMap};
use timeline_core::ParamRef;

fn pt(id: &str, ticks: u64, v: i64) -> AutoPoint {
    AutoPoint {
        id: id.into(),
        position_ticks: ticks,
        value: Num::int(v),
        extra: Default::default(),
    }
}

fn project() -> Project {
    Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()))
}

// ---------------------------------------------------------------------------
// 1. Legacy wire form
// ---------------------------------------------------------------------------

#[test]
fn legacy_targets_are_byte_identical_and_never_normalized() {
    for (target, wire) in [
        (AutoTarget::Volume, "track.volume"),
        (AutoTarget::Pan, "track.pan"),
    ] {
        let r = target.param_ref();
        assert_eq!(r.as_str(), wire);
        assert_eq!(serde_json::to_value(&r).unwrap(), json!(wire));
        assert_eq!(AutoTarget::from_param_ref(&r), Some(target));
    }
    // Nothing "more consistent" ever gets emitted.
    assert_ne!(ParamRef::track_volume().as_str(), "track.0.volume");
}

#[test]
fn the_autopoint_command_wire_form_is_unchanged() {
    // The full envelope params for an autopoint.add are the same bytes they
    // were under v1.1 — this is what keeps every historical hash valid.
    use timeline_core::cmd::Cmd;
    let cmd = Cmd::AutopointAdd {
        track_id: "t1".into(),
        target: ParamRef::track_volume(),
        point_id: "p1".into(),
        position_ticks: 480,
        value: Num::int(-6),
    };
    let name = cmd.name();
    let params = cmd.params_value();
    assert_eq!(name, "autopoint.add");
    assert_eq!(
        params,
        json!({
            "trackId": "t1",
            "target": "track.volume",
            "pointId": "p1",
            "positionTicks": 480,
            "value": -6
        })
    );
    let back = Cmd::from_wire(name, params).unwrap();
    assert_eq!(back, cmd);
}

// ---------------------------------------------------------------------------
// 2. Unknown lanes survive
// ---------------------------------------------------------------------------

fn checkpoint_with_unknown_lane() -> Value {
    // A checkpoint as a FUTURE build might have written it: a lane whose path
    // this build does not understand, plus an automation-level key it has never
    // heard of.
    json!({
        "formatVersion": 1,
        "projectId": "00000000000000000000000000",
        "name": "T",
        "sampleRateHz": 48000,
        "ppq": 960,
        "tempo": { "bpm": 120 },
        "tracks": [{
            "trackId": "t1",
            "name": "Track 1",
            "index": 0,
            "automation": {
                "volume": [
                    { "pointId": "v1", "positionTicks": 0, "value": -6 },
                    { "pointId": "v2", "positionTicks": 960, "value": 0 }
                ],
                "pan": [
                    { "pointId": "p1", "positionTicks": 0, "value": -1 }
                ],
                "lanes": {
                    "track.device.01J8XZ.cutoff": [
                        { "pointId": "d1", "positionTicks": 0, "value": 200 },
                        { "pointId": "d2", "positionTicks": 480, "value": 8000 }
                    ],
                    "rack.macro.7": [
                        { "pointId": "m1", "positionTicks": 0, "value": 1 }
                    ]
                },
                "someFutureLaneDefault": { "curve": "spline" }
            }
        }],
        "clips": [],
        "journal": { "entryCount": 0, "tipId": null,
                     "tipHash": "0000000000000000000000000000000000000000000000000000000000000000",
                     "genesisHash": "0000000000000000000000000000000000000000000000000000000000000000" }
    })
}

#[test]
fn an_unknown_but_well_formed_paramref_survives_load_then_save() {
    let input = checkpoint_with_unknown_lane();
    let p = from_project_json(&input).expect("loads");

    let t = &p.tracks[0];
    assert_eq!(t.automation.volume.len(), 2);
    assert_eq!(t.automation.pan.len(), 1);
    assert_eq!(t.automation.lanes.len(), 2);
    let unknown = ParamRef::parse("rack.macro.7").unwrap();
    assert_eq!(
        t.automation.lane(&unknown).len(),
        1,
        "an unrecognized path is a normal lane, not an error"
    );
    assert_eq!(
        t.automation.extra.get("someFutureLaneDefault"),
        Some(&json!({ "curve": "spline" })),
        "automation-level metadata must survive (design §9.3)"
    );

    // Round-trip through a real session checkpoint.
    let session = Session::new(p);
    let out = to_project_json(&session);
    let auto = &out["tracks"][0]["automation"];
    assert_eq!(auto["volume"], input["tracks"][0]["automation"]["volume"]);
    assert_eq!(auto["pan"], input["tracks"][0]["automation"]["pan"]);
    assert_eq!(auto["lanes"], input["tracks"][0]["automation"]["lanes"]);
    assert_eq!(auto["someFutureLaneDefault"], json!({ "curve": "spline" }));

    // And a second full cycle is a fixed point: load(save(load(x))) == load(x).
    let p2 = from_project_json(&out).expect("reloads");
    let out2 = to_project_json(&Session::new(p2));
    assert_eq!(
        serde_json::to_string(&out2["tracks"]).unwrap(),
        serde_json::to_string(&out["tracks"]).unwrap(),
        "load->save is not a fixed point; a lane is being mutated or dropped"
    );
}

// ---------------------------------------------------------------------------
// 3. Exactly one storage location
// ---------------------------------------------------------------------------

#[test]
fn a_legacy_path_never_lands_in_the_lanes_map() {
    let mut a = Automation::default();
    a.lane_mut(&ParamRef::track_volume()).push(pt("v1", 0, -6));
    a.lane_mut(&ParamRef::track_pan()).push(pt("p1", 0, 0));
    a.lane_mut(&ParamRef::parse("master.gain").unwrap())
        .push(pt("m1", 0, 0));

    assert_eq!(a.volume.len(), 1);
    assert_eq!(a.pan.len(), 1);
    assert_eq!(a.lanes.len(), 1, "only the non-legacy lane is in the map");
    assert!(a.single_storage_violations().is_empty());
    // Reading routes to the same one place.
    assert_eq!(a.lane(&ParamRef::track_volume()).len(), 1);
    assert!(a.lanes.get(&ParamRef::track_volume()).is_none());
}

#[test]
fn a_foreign_writer_that_split_a_legacy_lane_is_repaired_on_load() {
    // Hand-built: legacy points in BOTH the field and the map. Left alone this
    // would desync — one writer updating the field, another the map.
    let input = json!({
        "formatVersion": 1, "projectId": "00000000000000000000000000", "name": "T",
        "sampleRateHz": 48000, "ppq": 960, "tempo": { "bpm": 120 },
        "tracks": [{
            "trackId": "t1", "name": "Track 1", "index": 0,
            "automation": {
                "volume": [{ "pointId": "v1", "positionTicks": 960, "value": 0 }],
                "lanes": {
                    "track.volume": [{ "pointId": "v0", "positionTicks": 0, "value": -6 }]
                }
            }
        }],
        "clips": [],
        "journal": { "entryCount": 0, "tipId": null,
                     "tipHash": "0000000000000000000000000000000000000000000000000000000000000000",
                     "genesisHash": "0000000000000000000000000000000000000000000000000000000000000000" }
    });
    let p = from_project_json(&input).expect("loads");
    let a = &p.tracks[0].automation;
    assert!(
        a.single_storage_violations().is_empty(),
        "normalize() must fold the map copy into the legacy field"
    );
    assert!(a.lanes.is_empty());
    assert_eq!(
        a.volume.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(),
        ["v0", "v1"],
        "merged and re-sorted by (positionTicks, id)"
    );
}

// ---------------------------------------------------------------------------
// 4. Determinism
// ---------------------------------------------------------------------------

#[test]
fn lane_insertion_order_does_not_change_the_bytes() {
    let paths = [
        "track.device.zzz.cutoff",
        "bus.reverb.gain",
        "master.limiter.ceiling",
        "track.eq.3.q",
        "track.send.a.level",
    ];
    let build = |order: &[usize]| {
        let mut a = Automation::default();
        a.lane_mut(&ParamRef::track_volume()).push(pt("v1", 0, -6));
        for i in order {
            a.lane_mut(&ParamRef::parse(paths[*i]).unwrap())
                .push(pt("x", 0, 1));
        }
        serde_json::to_string(&a).unwrap()
    };
    let forward = build(&[0, 1, 2, 3, 4]);
    let backward = build(&[4, 3, 2, 1, 0]);
    let shuffled = build(&[2, 0, 4, 1, 3]);
    assert_eq!(forward, backward);
    assert_eq!(forward, shuffled);
    // And through the checkpoint writer, which is the byte surface that
    // actually matters.
    let ck = |order: &[usize]| {
        let mut p = project();
        let mut t = timeline_core::Track::new("t1", "Track 1");
        for i in order {
            t.automation
                .lane_mut(&ParamRef::parse(paths[*i]).unwrap())
                .push(pt("x", 0, 1));
        }
        p.tracks.push(t);
        serde_json::to_string(&to_project_json(&Session::new(p))["tracks"]).unwrap()
    };
    assert_eq!(ck(&[0, 1, 2, 3, 4]), ck(&[4, 3, 2, 1, 0]));
    assert_eq!(ck(&[0, 1, 2, 3, 4]), ck(&[2, 0, 4, 1, 3]));
}

#[test]
fn an_empty_automation_still_checkpoints_to_nothing() {
    // The v1 bytes for a track with no automation must not gain a key.
    let mut p = project();
    p.tracks.push(timeline_core::Track::new("t1", "Track 1"));
    let out = to_project_json(&Session::new(p));
    assert!(
        out["tracks"][0].get("automation").is_none(),
        "an untouched track gained an automation key: {}",
        out["tracks"][0]
    );
}

// ---------------------------------------------------------------------------
// Apply-time resolution (design §3's "Open risk, flagged not hidden")
// ---------------------------------------------------------------------------

#[test]
fn apply_time_resolution_replaces_the_schema_enum_that_was_widened_away() {
    use serde_json::json as j;
    let mut p = project();
    p.tracks.push(timeline_core::Track::new("t1", "Track 1"));
    let mut s = Session::new(p);

    let meta = |n: u8| timeline_core::EntryMeta {
        id: format!("0{}JZZZZZZZZZZZZZZZZZZZZZZZZ", n),
        ts: "2026-07-24T00:00:00Z".into(),
        actor: timeline_core::Actor::user("t"),
    };

    // Legacy: accepted, exactly as under v1.1.
    s.submit_json(
        meta(1),
        "autopoint.add",
        j!({"trackId": "t1", "target": "track.volume", "pointId": "p1",
            "positionTicks": 0, "value": 0}),
    )
    .expect("legacy target still works");

    // Well-formed, recognized, in range: accepted.
    s.submit_json(
        meta(2),
        "autopoint.add",
        j!({"trackId": "t1", "target": "track.eq.2.gain", "pointId": "p2",
            "positionTicks": 0, "value": 0}),
    )
    .expect("a real EQ band resolves");

    // Live-state existence is deliberately NOT checked here any more: a lane
    // family target that names a missing object is forward-legal, because the
    // inverse of a legal `autopoint.remove` must re-apply after the object is
    // gone (`require_param_ref_on`'s doc; `tests/undo_fidelity.rs` §7). The
    // loud gate is the render compile, by name, with a remedy.
    s.submit_json(
        meta(5),
        "autopoint.add",
        j!({"trackId": "t1", "target": "bus.nope.gain", "pointId": "p3",
            "positionTicks": 0, "value": 0}),
    )
    .expect("a missing routing node is a compile-gate concern, not an apply refusal");

    // BUILD-STATIC invalidity stays REJECTED at apply time. Under v1.1 the
    // enum caught this at the contract boundary; validation moved, it did not
    // disappear — no sequence of commands could ever make these mean anything
    // in this build.
    for bad in [
        "track.eq.9.gain",        // out of range band
        "track.send.z.level",     // no such send
        "track.device.dev1.foo",  // `foo` is not an instrument param key
        "master.limiter.wobble",  // not a limiter parameter
        "totally.made.up",        // unrecognized
    ] {
        let err = s
            .submit_json(
                meta(3),
                "autopoint.add",
                j!({"trackId": "t1", "target": bad, "pointId": "px",
                    "positionTicks": 0, "value": 0}),
            )
            .expect_err(&format!("{bad} should not resolve"));
        assert!(
            format!("{err}").contains("unknown parameter"),
            "{bad}: wrong error {err}"
        );
    }

    // Malformed paths are still rejected by the SCHEMA, before apply.
    let err = s
        .submit_json(
            meta(4),
            "autopoint.add",
            j!({"trackId": "t1", "target": "track..volume", "pointId": "px",
                "positionTicks": 0, "value": 0}),
        )
        .expect_err("malformed path");
    assert!(format!("{err}").contains("schema"), "{err}");
}
