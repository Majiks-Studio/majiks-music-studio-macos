//! The E5 effect registry (`DESIGN-E5-routing.md` §16): the seven `fx.*`
//! commands, the three new `ParamRef` families, persistence, and the byte- and
//! replay-compatibility claims §16.1 rests on.
//!
//! # Seam honesty (§12.5)
//!
//! Everything here asserts on the MODEL and on `project.json` BYTES. That is the
//! whole of what `timeline-core` owns and it is deliberately not the whole of
//! the feature: nothing in this file proves an effect makes a sound. §20.2's
//! rendered-buffer proofs belong to E5-graph and E5-fx and are not substituted
//! for here.
//!
//! | Traversed | SKIPPED |
//! |---|---|
//! | catalog schema validation → `Cmd::from_wire` → `apply_cmd` → inverse | `agent-surface`'s tool dispatch; `sync_after_mutation`; the renderer |
//! | `Session::submit` → journal → blake3 chain → `Session::replay` | the cpal callback and every buffer |

#[path = "support.rs"]
mod support;

use std::collections::BTreeMap;

use serde_json::{json, Value};
use timeline_core::catalog::Catalog;
use timeline_core::cmd::Cmd;
use timeline_core::envelope::Actor;
use timeline_core::model::{FxKind, Project, Track, FX_PARAM_KEYS};
use timeline_core::num::Num;
use timeline_core::package::{from_project_json, to_project_json};
use timeline_core::routing::NodeRef;
use timeline_core::session::Session;
use timeline_core::tempo::{Bpm, TempoMap};
use timeline_core::ParamRef;

const FX_COMMANDS: [&str; 7] = [
    "fx.add",
    "fx.remove",
    "fx.move",
    "fx.param.set",
    "fx.param.clear",
    "fx.sidechain.set",
    "fx.sidechain.clear",
];

fn cmd(name: &str, params: Value) -> Cmd {
    // Validate against the embedded catalog FIRST, exactly as live submit does,
    // so a test cannot construct params the contract boundary would reject.
    Catalog::get()
        .validate_params(name, &params)
        .unwrap_or_else(|e| panic!("{name} params invalid: {e}"));
    Cmd::from_wire(name, params).unwrap_or_else(|e| panic!("{name}: {e}"))
}

/// A project with two tracks and one bus, so all three fx HOSTS (track, bus,
/// master) are addressable.
fn seeded() -> Project {
    let mut p = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    p.tracks.push(Track::new("t1", "Track 1"));
    p.tracks.push(Track::new("t2", "Track 2"));
    p.apply_cmd(&cmd(
        "route.node.add",
        json!({"nodeId": "grp", "kind": "group", "name": "Group"}),
    ))
    .unwrap();
    p
}

fn chain_ids(p: &Project, target: &str) -> Vec<String> {
    p.fx_chain(&NodeRef::parse(target).unwrap())
        .unwrap_or_else(|| panic!("no host {target}"))
        .iter()
        .map(|f| f.id.clone())
        .collect()
}

/// Apply, then apply the inverse sequence, and assert the model is BIT-EQUAL to
/// the pre-state. This is the property that makes undo trustworthy, and the one
/// `hint` alone cannot prove.
fn assert_inverse_exact(p: &mut Project, c: Cmd) {
    let name = c.name();
    let pre = p.clone();
    let effect = p
        .apply_cmd(&c)
        .unwrap_or_else(|e| panic!("{name} should apply: {e}"));
    assert!(
        effect.hint.is_some(),
        "{name} is undoable, so session.rs REQUIRES a hint"
    );
    for inv in &effect.inverse {
        p.apply_cmd(inv)
            .unwrap_or_else(|e| panic!("inverse {} of {name} failed: {e}", inv.name()));
    }
    assert!(
        pre == *p,
        "inverse of {name} did not restore the exact pre-state"
    );
}

// ---------------------------------------------------------------------------
// §16.1 — the registry is SEPARATE, and Device is untouched.
// ---------------------------------------------------------------------------

/// The load-bearing structural claim of §16.1, asserted rather than asserted-in-
/// prose: `device.add`'s `kind` enum is still exactly the three instrument
/// kinds. If a later lane "simplifies" by widening it, this fails.
///
/// The reason is concrete: `build_instrument` (`compile.rs:307-322`) hard-errors
/// on a track with more than one device, so an effect in `Track::devices` would
/// break the compile of every instrument track that also carries an effect.
#[test]
fn device_add_kind_enum_is_untouched_and_fx_is_a_separate_collection() {
    let schema = &Catalog::get().spec("device.add").unwrap().params_schema;
    assert_eq!(
        schema["properties"]["kind"]["enum"],
        json!(["synth", "sampler", "drum"]),
        "device.add's kind enum must NOT be widened (E5 §16.1)"
    );

    let mut p = seeded();
    p.apply_cmd(&cmd(
        "device.add",
        json!({"trackId": "t1", "deviceId": "inst", "kind": "synth"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "track.t1", "fxId": "comp", "kind": "compressor"}),
    ))
    .unwrap();
    // An instrument AND an effect coexist on one track, in two collections.
    assert_eq!(p.tracks[0].devices.len(), 1);
    assert_eq!(p.tracks[0].fx.len(), 1);
}

/// §20.3, and E0 §9.7's outstanding "write the 10-line test before depending on
/// it": an unknown `FxKind` must FAIL `Cmd::from_wire` loudly, not deserialize
/// to a default. §16.1's entire safety argument for a CLOSED enum rests on this.
///
/// `Package::open` calls `Cmd::from_wire` on every journal entry, so a loud
/// failure here is a refused open — which is the safe outcome. A silent default
/// would be a project that verifies its blake3 chain and then builds the WRONG
/// effect.
#[test]
fn an_unknown_fx_kind_fails_from_wire_loudly() {
    let err = Cmd::from_wire(
        "fx.add",
        json!({"target": "track.t1", "fxId": "x", "kind": "convolution"}),
    )
    .expect_err("an unknown kind must not deserialize");
    let msg = format!("{err}");
    assert!(
        msg.contains("convolution") || msg.contains("variant"),
        "the error must name what it could not parse: {msg}"
    );
    // ... and the catalog rejects it one layer earlier, at live submit.
    assert!(Catalog::get()
        .validate_params(
            "fx.add",
            &json!({"target": "track.t1", "fxId": "x", "kind": "convolution"})
        )
        .is_err());
    // Every kind the enum DOES declare parses.
    for k in [
        "eq",
        "compressor",
        "gate",
        "delay",
        "reverb",
        "saturator",
        "chorus",
        "utility",
        "limiter",
    ] {
        assert!(FxKind::parse(k).is_some(), "{k}");
        assert_eq!(FxKind::parse(k).unwrap().wire_name(), k);
    }
}

// ---------------------------------------------------------------------------
// §16.2 — NodeRef is the host address, and master comes free.
// ---------------------------------------------------------------------------

/// All three hosts, including MASTER — which is the point of using `NodeRef`
/// rather than a `trackId`-keyed family. A master-bus effect chain is table
/// stakes for parity and a `trackId` command could never have expressed it.
#[test]
fn all_three_fx_hosts_are_addressable_through_one_command_family() {
    let mut p = seeded();
    for (target, id) in [
        ("track.t1", "onTrack"),
        ("bus.grp", "onBus"),
        ("master", "onMaster"),
    ] {
        p.apply_cmd(&cmd(
            "fx.add",
            json!({"target": target, "fxId": id, "kind": "utility"}),
        ))
        .unwrap_or_else(|e| panic!("{target}: {e}"));
    }
    assert_eq!(chain_ids(&p, "track.t1"), ["onTrack"]);
    assert_eq!(chain_ids(&p, "bus.grp"), ["onBus"]);
    assert_eq!(chain_ids(&p, "master"), ["onMaster"]);
    assert!(p.tracks[1].fx.is_empty(), "t2 must be untouched");
}

#[test]
fn an_unresolvable_host_is_a_typed_error_not_a_silent_noop() {
    let mut p = seeded();
    assert!(p
        .apply_cmd(&cmd(
            "fx.add",
            json!({"target": "track.nope", "fxId": "a", "kind": "eq"})
        ))
        .is_err());
    assert!(p
        .apply_cmd(&cmd(
            "fx.add",
            json!({"target": "bus.nope", "fxId": "a", "kind": "eq"})
        ))
        .is_err());
    // ... and nothing was created anywhere.
    assert!(p.tracks.iter().all(|t| t.fx.is_empty()));
    assert!(p.routing.nodes.iter().all(|n| n.fx.is_empty()));
}

// ---------------------------------------------------------------------------
// The seven commands: behaviour + exact inverses.
// ---------------------------------------------------------------------------

#[test]
fn fx_add_appends_and_rejects_a_duplicate_id_within_the_chain() {
    let mut p = seeded();
    for id in ["a", "b", "c"] {
        p.apply_cmd(&cmd(
            "fx.add",
            json!({"target": "track.t1", "fxId": id, "kind": "eq"}),
        ))
        .unwrap();
    }
    assert_eq!(chain_ids(&p, "track.t1"), ["a", "b", "c"], "fx.add APPENDS");
    assert!(p
        .apply_cmd(&cmd(
            "fx.add",
            json!({"target": "track.t1", "fxId": "b", "kind": "gate"})
        ))
        .is_err());
    // ids are per-CHAIN, so the same id on another host is fine.
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "master", "fxId": "b", "kind": "gate"}),
    ))
    .unwrap();
}

/// `fx.remove`'s inverse restores the CHAIN INDEX, every stored param and the
/// sidechain link. `inverseShape: "multi"`, never `inverseRule: self` — a false
/// inverse is a lie the journal carries forever.
#[test]
fn fx_remove_restores_index_params_and_link_exactly() {
    let mut p = seeded();
    for id in ["first", "victim", "last"] {
        p.apply_cmd(&cmd(
            "fx.add",
            json!({"target": "bus.grp", "fxId": id, "kind": "compressor"}),
        ))
        .unwrap();
    }
    for (k, v) in [("threshold", -18), ("ratio", 4)] {
        p.apply_cmd(&cmd(
            "fx.param.set",
            json!({"target": "bus.grp", "fxId": "victim", "key": k, "value": v}),
        ))
        .unwrap();
    }
    p.apply_cmd(&cmd(
        "fx.sidechain.set",
        json!({"target": "bus.grp", "fxId": "victim", "source": "track.t1"}),
    ))
    .unwrap();

    let pre = p.clone();
    let effect = p
        .apply_cmd(&cmd(
            "fx.remove",
            json!({"target": "bus.grp", "fxId": "victim"}),
        ))
        .unwrap();
    assert_eq!(chain_ids(&p, "bus.grp"), ["first", "last"]);
    assert!(
        effect.inverse.len() > 1,
        "a configured, non-terminal, sidechained fx cannot restore in one command"
    );
    assert_eq!(
        effect.hint.as_ref().unwrap().name(),
        "fx.add",
        "the hint is the catalog's declared inverse"
    );
    for inv in &effect.inverse {
        p.apply_cmd(inv).unwrap();
    }
    assert!(pre == p, "fx.remove's inverse must be EXACT");
    // Belt and braces: the restored fx is at index 1 with both params and the link.
    let fx = &p.routing.node("grp").unwrap().fx[1];
    assert_eq!(fx.id, "victim");
    assert_eq!(fx.params.len(), 2);
    assert_eq!(fx.sidechain, Some(NodeRef::Track("t1".into())));
}

/// `device.remove` refuses a device carrying stored params because E1/E2 had no
/// command to restore them. `fx.remove` DOES have one, so copying that guard
/// would make every configured effect unremovable. Pinned so nobody "restores
/// consistency" by adding it.
#[test]
fn fx_remove_does_not_copy_device_removes_non_empty_params_guard() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "master", "fxId": "c", "kind": "compressor"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "fx.param.set",
        json!({"target": "master", "fxId": "c", "key": "ratio", "value": 8}),
    ))
    .unwrap();
    p.apply_cmd(&cmd("fx.remove", json!({"target": "master", "fxId": "c"})))
        .expect("a configured effect must remain removable");
}

/// An fx carrying unknown `extra` IS refused, for the opposite reason: no
/// catalog command can restore it, so the remove would not be undoable. Same
/// doctrine as `device.zone.remove`.
#[test]
fn fx_remove_refuses_an_fx_carrying_unrestorable_extra() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "master", "fxId": "c", "kind": "eq"}),
    ))
    .unwrap();
    p.master.fx[0]
        .extra
        .insert("fromTheFuture".into(), json!(1));
    let e = format!(
        "{}",
        p.apply_cmd(&cmd("fx.remove", json!({"target": "master", "fxId": "c"})))
            .expect_err("must refuse")
    );
    assert!(e.contains("not be undoable"), "{e}");
    assert_eq!(p.master.fx.len(), 1, "no partial apply");
}

#[test]
fn fx_move_reorders_and_is_exactly_self_inverse() {
    let mut p = seeded();
    for id in ["a", "b", "c", "d"] {
        p.apply_cmd(&cmd(
            "fx.add",
            json!({"target": "track.t1", "fxId": id, "kind": "eq"}),
        ))
        .unwrap();
    }
    // Every (from, to) pair round-trips through its own inverse.
    for (id, to) in [("d", 0), ("a", 3), ("b", 2), ("c", 1)] {
        assert_inverse_exact(
            &mut p,
            cmd(
                "fx.move",
                json!({"target": "track.t1", "fxId": id, "index": to}),
            ),
        );
    }
    // ... and the move actually moves.
    p.apply_cmd(&cmd(
        "fx.move",
        json!({"target": "track.t1", "fxId": "d", "index": 0}),
    ))
    .unwrap();
    assert_eq!(chain_ids(&p, "track.t1"), ["d", "a", "b", "c"]);
    // Past the end is a typed error, not a clamp: clamping would make the
    // self-inverse's stored index wrong.
    assert!(p
        .apply_cmd(&cmd(
            "fx.move",
            json!({"target": "track.t1", "fxId": "d", "index": 4})
        ))
        .is_err());
    assert_eq!(chain_ids(&p, "track.t1"), ["d", "a", "b", "c"]);
}

/// **The sparsity property, both directions.** Params stay sparse: an absent key
/// means the DSP default. So setting a key that was ABSENT must undo to ABSENT,
/// not to a written default — which is exactly why the inverse is a
/// `fx.param.clear` and why `inverseShape` is `multi`.
///
/// This is the property that makes `fx.param.set` safe where E1/E2 judged a
/// `device.param.set` to be a booby trap: no default is ever invented.
#[test]
fn fx_param_set_is_sparse_and_undoes_to_absent_not_to_a_default() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "track.t1", "fxId": "c", "kind": "compressor"}),
    ))
    .unwrap();
    assert!(p.tracks[0].fx[0].params.is_empty(), "fx.add stores NO params");

    // First set: the key was absent, so the inverse must CLEAR it.
    let effect = p
        .apply_cmd(&cmd(
            "fx.param.set",
            json!({"target": "track.t1", "fxId": "c", "key": "threshold", "value": -18}),
        ))
        .unwrap();
    assert_eq!(effect.inverse.len(), 1);
    assert_eq!(
        effect.inverse[0].name(),
        "fx.param.clear",
        "setting an ABSENT key inverts to clear, never to a written default"
    );
    p.apply_cmd(&effect.inverse[0]).unwrap();
    assert!(
        p.tracks[0].fx[0].params.is_empty(),
        "undo must restore SPARSITY, not write a default"
    );

    // Second set over an existing value: the inverse carries the PRIOR value.
    p.apply_cmd(&cmd(
        "fx.param.set",
        json!({"target": "track.t1", "fxId": "c", "key": "threshold", "value": -18}),
    ))
    .unwrap();
    let effect = p
        .apply_cmd(&cmd(
            "fx.param.set",
            json!({"target": "track.t1", "fxId": "c", "key": "threshold", "value": -6}),
        ))
        .unwrap();
    assert_eq!(effect.inverse[0].name(), "fx.param.set");
    p.apply_cmd(&effect.inverse[0]).unwrap();
    assert_eq!(
        p.tracks[0].fx[0].params["threshold"],
        Num::int(-18),
        "undo must restore the PRIOR value"
    );
}

/// Journaled values are `Num`, never `f32`/`f64`: the integer/float SHAPE is
/// hashed, so `4` and `4.0` must not be interchangeable through a round trip.
#[test]
fn fx_param_values_preserve_integer_float_shape_through_the_inverse() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "master", "fxId": "c", "kind": "compressor"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "fx.param.set",
        json!({"target": "master", "fxId": "c", "key": "ratio", "value": 4}),
    ))
    .unwrap();
    let effect = p
        .apply_cmd(&cmd(
            "fx.param.set",
            json!({"target": "master", "fxId": "c", "key": "ratio", "value": 2.5}),
        ))
        .unwrap();
    let inverse_params = effect.inverse[0].params_value();
    assert_eq!(
        serde_json::to_string(&inverse_params["value"]).unwrap(),
        "4",
        "an integer-shaped prior must come back integer-shaped, not 4.0"
    );
    p.apply_cmd(&effect.inverse[0]).unwrap();
    let stored = to_project_json(&Session::new(p.clone()));
    assert!(
        serde_json::to_string(&stored).unwrap().contains("\"ratio\":4"),
        "the checkpoint must carry the integer shape"
    );
}

#[test]
fn fx_param_clear_restores_sparsity_and_refuses_an_absent_key() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "bus.grp", "fxId": "c", "kind": "gate"}),
    ))
    .unwrap();
    // Clearing a key that stores nothing is a typed error, not a silent no-op:
    // a no-op has no exact inverse to journal.
    assert!(p
        .apply_cmd(&cmd(
            "fx.param.clear",
            json!({"target": "bus.grp", "fxId": "c", "key": "hold"})
        ))
        .is_err());
    p.apply_cmd(&cmd(
        "fx.param.set",
        json!({"target": "bus.grp", "fxId": "c", "key": "hold", "value": 30}),
    ))
    .unwrap();
    assert_inverse_exact(
        &mut p,
        cmd(
            "fx.param.clear",
            json!({"target": "bus.grp", "fxId": "c", "key": "hold"}),
        ),
    );
}

/// A key outside `FX_PARAM_KEYS` is refused. Growing that list later is a
/// WIDENING (nothing previously valid becomes invalid), which is the safe
/// direction; narrowing it would break replay.
#[test]
fn an_unknown_param_key_is_refused_and_every_declared_key_is_accepted() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "master", "fxId": "c", "kind": "compressor"}),
    ))
    .unwrap();
    assert!(p
        .apply_cmd(&cmd(
            "fx.param.set",
            json!({"target": "master", "fxId": "c", "key": "wobble", "value": 1})
        ))
        .is_err());
    // The (kind, key) pairing is deliberately NOT validated (§16.3): apply.rs
    // runs on REPLAY, so tightening it would break replay of a project that
    // automated a key its kind ignores. A compressor accepting `band0Gain` is
    // the intended behaviour, not an oversight.
    for key in FX_PARAM_KEYS {
        p.apply_cmd(&cmd(
            "fx.param.set",
            json!({"target": "master", "fxId": "c", "key": key, "value": 1}),
        ))
        .unwrap_or_else(|e| panic!("{key}: {e}"));
    }
    assert_eq!(p.master.fx[0].params.len(), FX_PARAM_KEYS.len());
}

#[test]
fn fx_sidechain_set_and_clear_invert_exactly_in_both_directions() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "bus.grp", "fxId": "c", "kind": "compressor"}),
    ))
    .unwrap();
    // From ABSENT: the inverse must be a clear.
    let effect = p
        .apply_cmd(&cmd(
            "fx.sidechain.set",
            json!({"target": "bus.grp", "fxId": "c", "source": "track.t1"}),
        ))
        .unwrap();
    assert_eq!(effect.inverse[0].name(), "fx.sidechain.clear");
    p.apply_cmd(&effect.inverse[0]).unwrap();
    assert_eq!(p.routing.node("grp").unwrap().fx[0].sidechain, None);

    // From PRESENT: the inverse must be a set carrying the prior source.
    p.apply_cmd(&cmd(
        "fx.sidechain.set",
        json!({"target": "bus.grp", "fxId": "c", "source": "track.t1"}),
    ))
    .unwrap();
    assert_inverse_exact(
        &mut p,
        cmd(
            "fx.sidechain.set",
            json!({"target": "bus.grp", "fxId": "c", "source": "track.t2"}),
        ),
    );
    assert_inverse_exact(
        &mut p,
        cmd(
            "fx.sidechain.clear",
            json!({"target": "bus.grp", "fxId": "c"}),
        ),
    );
    // Clearing an fx that has no link is a typed error, not a silent no-op.
    p.apply_cmd(&cmd(
        "fx.sidechain.clear",
        json!({"target": "bus.grp", "fxId": "c"}),
    ))
    .unwrap();
    assert!(p
        .apply_cmd(&cmd(
            "fx.sidechain.clear",
            json!({"target": "bus.grp", "fxId": "c"})
        ))
        .is_err());
}

// ---------------------------------------------------------------------------
// Removing a HOST must not silently lose its chain, or dangle links into it.
// ---------------------------------------------------------------------------

/// Adding `Track::fx` would have made `track.remove` newly LOSSY: `track.add`
/// carries no chain. The restore sequence therefore rebuilds it — before the
/// automation loop, because a `track.fx.<id>.<key>` lane does not resolve until
/// the fx exists.
#[test]
fn track_remove_restores_the_tracks_fx_chain_and_its_automation() {
    let mut p = seeded();
    for id in ["a", "b"] {
        p.apply_cmd(&cmd(
            "fx.add",
            json!({"target": "track.t2", "fxId": id, "kind": "saturator"}),
        ))
        .unwrap();
    }
    p.apply_cmd(&cmd(
        "fx.param.set",
        json!({"target": "track.t2", "fxId": "a", "key": "drive", "value": 6}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "autopoint.add",
        json!({"trackId": "t2", "target": "track.fx.a.drive", "pointId": "p1",
               "positionTicks": 0, "value": 3}),
    ))
    .unwrap();
    assert_inverse_exact(&mut p, cmd("track.remove", json!({"trackId": "t2"})));
}

/// Same for a routing node: `route.node.add` carries no chain either, so
/// removing a bus with a compressor on it and undoing would silently return a
/// bare summing point.
#[test]
fn route_node_remove_restores_the_nodes_fx_chain() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "bus.grp", "fxId": "c", "kind": "compressor"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "fx.param.set",
        json!({"target": "bus.grp", "fxId": "c", "key": "ratio", "value": 4}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "fx.sidechain.set",
        json!({"target": "bus.grp", "fxId": "c", "source": "track.t1"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "route.connect",
        json!({"edgeId": "e1", "from": "track.t1", "to": "bus.grp", "level": 1, "tap": "post"}),
    ))
    .unwrap();
    assert_inverse_exact(&mut p, cmd("route.node.remove", json!({"nodeId": "grp"})));
}

/// Removing a track that is a KEY SOURCE must clear the dangling link, for
/// exactly the reason `track.remove` already clears incident EDGES: "the graph
/// would keep an endpoint that resolves to nothing". A link is an ordering
/// constraint over the same graph.
#[test]
fn removing_a_key_source_clears_the_dangling_link_and_undo_restores_it() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "master", "fxId": "c", "kind": "compressor"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "fx.sidechain.set",
        json!({"target": "master", "fxId": "c", "source": "track.t2"}),
    ))
    .unwrap();
    assert_eq!(p.sidechain_links().len(), 1);

    let pre = p.clone();
    let effect = p.apply_cmd(&cmd("track.remove", json!({"trackId": "t2"}))).unwrap();
    assert!(
        p.sidechain_links().is_empty(),
        "a link into a deleted track must not dangle"
    );
    for inv in &effect.inverse {
        p.apply_cmd(inv).unwrap();
    }
    assert!(pre == p, "the link must come back with the track");
}

// ---------------------------------------------------------------------------
// §16.3 — the three ParamRef families, and §2.2's routing one.
// ---------------------------------------------------------------------------

#[test]
fn the_three_fx_paramref_families_classify_and_resolve() {
    use timeline_core::paramref::ParamRefKind as K;
    assert_eq!(
        ParamRef::parse("track.fx.c1.threshold").unwrap().kind(),
        K::TrackFxParam {
            fx_id: "c1",
            param: "threshold"
        }
    );
    assert_eq!(
        ParamRef::parse("bus.grp.fx.c1.ratio").unwrap().kind(),
        K::BusFxParam {
            bus_id: "grp",
            fx_id: "c1",
            param: "ratio"
        }
    );
    assert_eq!(
        ParamRef::parse("master.fx.c1.ceiling").unwrap().kind(),
        K::MasterFxParam {
            fx_id: "c1",
            param: "ceiling"
        }
    );
    // The pre-existing neighbours must be undisturbed.
    assert_eq!(ParamRef::parse("bus.grp.gain").unwrap().kind(), K::BusGain { bus_id: "grp" });
    assert_eq!(
        ParamRef::parse("track.device.d1.cutoff").unwrap().kind(),
        K::TrackDeviceParam {
            device_id: "d1",
            param: "cutoff"
        }
    );

    let mut p = seeded();
    for (target, id) in [("track.t1", "c1"), ("bus.grp", "c1"), ("master", "c1")] {
        p.apply_cmd(&cmd(
            "fx.add",
            json!({"target": target, "fxId": id, "kind": "compressor"}),
        ))
        .unwrap();
    }
    for path in [
        "track.fx.c1.threshold",
        "bus.grp.fx.c1.ratio",
        "master.fx.c1.ceiling",
    ] {
        p.apply_cmd(&cmd(
            "autopoint.add",
            json!({"trackId": "t1", "target": path, "pointId": format!("p-{path}"),
                   "positionTicks": 0, "value": 0}),
        ))
        .unwrap_or_else(|e| panic!("{path} must resolve: {e}"));
    }
}

/// **Zero catalog schema edits** (§16.3). The three families are already
/// well-formed under the `autopoint`/`autolane` `target` pattern E0 widened, so
/// automation reaches effect parameters with no contract change at all. Asserted
/// against the catalog rather than trusted.
#[test]
fn the_fx_paramref_families_need_no_catalog_schema_change() {
    let pattern = Catalog::get().spec("autopoint.add").unwrap().params_schema
        ["properties"]["target"]["pattern"]
        .as_str()
        .expect("target is a pattern, not an enum")
        .to_string();
    assert_eq!(pattern, "^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)*$");
    for path in [
        "track.fx.c1.threshold",
        "bus.grp.fx.c1.ratio",
        "master.fx.c1.ceiling",
        "route.edge.e1.level",
    ] {
        Catalog::get()
            .validate_params(
                "autopoint.add",
                &json!({"trackId": "t1", "target": path, "pointId": "p",
                        "positionTicks": 0, "value": 0}),
            )
            .unwrap_or_else(|e| panic!("{path} must already validate: {e}"));
    }
}

#[test]
fn an_fx_paramref_is_gated_on_the_key_at_apply_and_on_existence_at_compile() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "track.t1", "fxId": "c1", "kind": "compressor"}),
    ))
    .unwrap();
    // An unknown KEY is build-static — no command sequence could ever make
    // `wobble` an effect parameter — so it still refuses at apply time.
    assert!(
        p.apply_cmd(&cmd(
            "autopoint.add",
            json!({"trackId": "t1", "target": "track.fx.c1.wobble", "pointId": "p",
                   "positionTicks": 0, "value": 0}),
        ))
        .is_err(),
        "track.fx.c1.wobble (unknown key) must stay refused"
    );
    // Host/fx EXISTENCE is live state: `fx.remove` keeps lanes, so the inverse
    // of removing a stray point must re-apply after the fx is gone. These are
    // apply-legal now; the unreadable lane is refused at the compile gate by
    // name (`render/tests/inert_lanes.rs::an_fx_lane_naming_a_missing_fx_is_refused_loudly`).
    for (i, path) in [
        "track.fx.nope.threshold", // no such fx on the track
        "bus.nope.fx.c1.ratio",    // no such routing node
        "master.fx.c1.ratio",      // no such fx on master
    ]
    .iter()
    .enumerate()
    {
        p.apply_cmd(&cmd(
            "autopoint.add",
            json!({"trackId": "t1", "target": path, "pointId": format!("p{i}"),
                   "positionTicks": 0, "value": 0}),
        ))
        .unwrap_or_else(|e| panic!("{path} is a compile-gate concern, not an apply refusal: {e}"));
    }
}

/// §6.5's deferral (a bus→bus edge level is atomic-only in E5) is enforced at
/// the COMPILE gate now, not at apply time. Apply-time existence/source checks
/// were removed for the whole lane family because they broke truthful
/// inverses: `route.disconnect` keeps the lane, `autopoint.remove` of a stray
/// point is legal, and its inverse `autopoint.add` must re-apply after the
/// edge is gone — and `track.remove`'s restore sequence re-adds lane points
/// BEFORE it re-connects the track's incident edges, so the old check refused
/// mid-undo and left the model half-restored (`require_param_ref_on`'s doc;
/// `tests/undo_fidelity.rs` §7). The lane with no reader is refused loudly at
/// compile (`render/tests/inert_lanes.rs::a_lane_with_no_reader_is_refused_loudly`).
#[test]
fn route_edge_level_lanes_are_apply_legal_for_any_edge_id_and_gated_at_compile() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "route.connect",
        json!({"edgeId": "fromTrack", "from": "track.t1", "to": "bus.grp",
               "level": 1, "tap": "pre"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "route.connect",
        json!({"edgeId": "fromBus", "from": "bus.grp", "to": "master",
               "level": 1, "tap": "post"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "autopoint.add",
        json!({"trackId": "t1", "target": "route.edge.fromTrack.level", "pointId": "p1",
               "positionTicks": 0, "value": 1}),
    ))
    .expect("a track-sourced edge level must automate");
    p.apply_cmd(&cmd(
        "autopoint.add",
        json!({"trackId": "t1", "target": "route.edge.fromBus.level", "pointId": "p2",
               "positionTicks": 0, "value": 1}),
    ))
    .expect("a bus-sourced edge level lane lands in the model; the deferral is compile-gated");
    assert!(
        p.apply_cmd(&cmd(
            "autopoint.add",
            json!({"trackId": "t1", "target": "route.edge.nope.level", "pointId": "p3",
                   "positionTicks": 0, "value": 1}),
        ))
        .is_ok(),
        "a dangling edge id is apply-legal; the compile refuses the unreadable lane by name"
    );
}

// ---------------------------------------------------------------------------
// §16.1 byte compatibility + persistence (package.rs must WRITE and READ).
// ---------------------------------------------------------------------------

/// **A project with no `fx` anywhere serializes to EXACTLY the bytes it did
/// before.** All three `fx` fields are `skip_serializing_if = "Vec::is_empty"`
/// and none is written by the hand-built checkpoint when empty.
///
/// This also resolves the dangling citation §20.3 found: `model.rs` claimed a
/// test named `device_bytes_unchanged_without_zones` pinned the same property
/// for `Device::zones`, and no such test existed. Both are pinned here.
#[test]
fn a_project_with_no_fx_checkpoints_to_unchanged_bytes() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "device.add",
        json!({"trackId": "t1", "deviceId": "d1", "kind": "synth"}),
    ))
    .unwrap();
    let json = to_project_json(&Session::new(p));
    let text = serde_json::to_string(&json).unwrap();
    assert!(
        !text.contains("\"fx\""),
        "an empty fx chain must not be written anywhere: {text}"
    );
    assert!(
        !text.contains("\"zones\""),
        "an empty zone list must not be written either (the dangling \
         device_bytes_unchanged_without_zones citation, now resolved)"
    );
    assert!(!text.contains("\"sidechain\""));
}

/// `package.rs` must WRITE **and READ** everything new. The E0 doc records the
/// consequence of omitting the read: a saved project reopens broken, because a
/// field the checkpoint does not read back is DESTROYED on the next save, not
/// merely ignored.
#[test]
fn every_fx_field_on_every_host_survives_a_checkpoint_round_trip() {
    let mut p = seeded();
    for (target, id, kind) in [
        ("track.t1", "tfx", "compressor"),
        ("bus.grp", "bfx", "reverb"),
        ("master", "mfx", "limiter"),
    ] {
        p.apply_cmd(&cmd(
            "fx.add",
            json!({"target": target, "fxId": id, "kind": kind}),
        ))
        .unwrap();
        p.apply_cmd(&cmd(
            "fx.param.set",
            json!({"target": target, "fxId": id, "key": "mix", "value": 0.5}),
        ))
        .unwrap();
        p.apply_cmd(&cmd(
            "fx.param.set",
            json!({"target": target, "fxId": id, "key": "gain", "value": -3}),
        ))
        .unwrap();
    }
    // A second effect on the track, so CHAIN ORDER is exercised too.
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "track.t1", "fxId": "second", "kind": "chorus"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "fx.sidechain.set",
        json!({"target": "bus.grp", "fxId": "bfx", "source": "track.t2"}),
    ))
    .unwrap();
    // And an unknown field from a newer writer, which must be PRESERVED.
    p.master.fx[0]
        .extra
        .insert("fromTheFuture".into(), json!({"x": 1}));

    let json = to_project_json(&Session::new(p.clone()));
    let back = from_project_json(&json).expect("reopen");

    assert_eq!(back.tracks[0].fx, p.tracks[0].fx, "track chain");
    assert_eq!(chain_ids(&back, "track.t1"), ["tfx", "second"], "chain ORDER");
    assert_eq!(back.routing.nodes[0].fx, p.routing.nodes[0].fx, "bus chain");
    assert_eq!(back.master.fx, p.master.fx, "master chain");
    assert_eq!(
        back.master.fx[0].extra["fromTheFuture"],
        json!({"x": 1}),
        "an unknown field must be preserved, not dropped"
    );
    assert_eq!(
        back.routing.nodes[0].fx[0].sidechain,
        Some(NodeRef::Track("t2".into())),
        "the sidechain link must survive the round trip"
    );
    // Value SHAPE survives too: 0.5 stays a float, -3 stays an integer.
    let params: &BTreeMap<String, Num> = &back.tracks[0].fx[0].params;
    assert_eq!(params["gain"], Num::int(-3));
    assert_eq!(
        serde_json::to_string(&params["mix"]).unwrap(),
        "0.5",
        "float shape preserved"
    );

    // ... and a second save is byte-identical, which is what proves the READ is
    // complete rather than merely present.
    assert_eq!(
        to_project_json(&Session::new(back)),
        json,
        "save -> open -> save must be a fixed point"
    );
}

/// An effect written by a NEWER build, with a kind this one cannot evaluate, is
/// SKIPPED on load rather than coerced — the same decision `parse_device` makes.
/// Coercing it would silently reinterpret the project as a different sound.
#[test]
fn an_unknown_fx_kind_on_disk_is_skipped_not_coerced() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "master", "fxId": "known", "kind": "eq"}),
    ))
    .unwrap();
    let mut json = to_project_json(&Session::new(p));
    json["masterBus"]["fx"].as_array_mut().unwrap().push(json!({
        "fxId": "future", "kind": "convolution"
    }));
    let back = from_project_json(&json).unwrap();
    assert_eq!(
        back.master.fx.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
        ["known"],
        "an unevaluatable kind must be skipped, never coerced to another effect"
    );
}

// ---------------------------------------------------------------------------
// Journal, replay, and the four E0 §9.5 gates.
// ---------------------------------------------------------------------------

/// Every one of the seven satisfies the four gates: a catalog entry with
/// consistent `journaled`/`undoable`/`inverseRule`, an `apply.rs` arm returning
/// `hint: Some(cmd)`, an entry in `representative_commands()`, and the count
/// bumps (asserted in `conformance.rs` / `parity.rs`).
#[test]
fn all_seven_are_journaled_undoable_and_carry_a_hint() {
    for name in FX_COMMANDS {
        let spec = Catalog::get()
            .spec(name)
            .unwrap_or_else(|| panic!("{name} missing from the catalog"));
        assert!(spec.journaled, "{name} must be journaled");
        assert!(spec.undoable, "{name} must be undoable");
    }
    let reps = support::representative_commands();
    for name in FX_COMMANDS {
        assert!(
            reps.iter().any(|(n, _)| *n == name),
            "{name} missing from representative_commands()"
        );
    }
}

/// The whole family through `Session::submit`: journaled, chain verified, and
/// **replay from empty reproduces the model and the tip hash exactly**. This is
/// the gate that catches an inverse or a model field that does not survive the
/// journal.
#[test]
fn the_whole_family_journals_and_replays_with_an_identical_chain() {
    let mut base = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    base.tracks.push(Track::new("t1", "Track 1"));
    base.tracks.push(Track::new("t2", "Track 2"));
    let mut s = Session::new(base.clone());

    let script = [
        ("route.node.add", json!({"nodeId": "grp", "kind": "group", "name": "G"})),
        ("fx.add", json!({"target": "track.t1", "fxId": "a", "kind": "eq"})),
        ("fx.add", json!({"target": "track.t1", "fxId": "b", "kind": "compressor"})),
        ("fx.move", json!({"target": "track.t1", "fxId": "b", "index": 0})),
        ("fx.param.set", json!({"target": "track.t1", "fxId": "b", "key": "ratio", "value": 4})),
        ("fx.param.set", json!({"target": "track.t1", "fxId": "b", "key": "ratio", "value": 2.5})),
        ("fx.param.clear", json!({"target": "track.t1", "fxId": "b", "key": "ratio"})),
        ("fx.add", json!({"target": "bus.grp", "fxId": "c", "kind": "gate"})),
        ("fx.sidechain.set", json!({"target": "bus.grp", "fxId": "c", "source": "track.t2"})),
        ("fx.sidechain.set", json!({"target": "bus.grp", "fxId": "c", "source": "track.t1"})),
        ("fx.sidechain.clear", json!({"target": "bus.grp", "fxId": "c"})),
        ("fx.add", json!({"target": "master", "fxId": "m", "kind": "limiter"})),
        ("fx.remove", json!({"target": "track.t1", "fxId": "a"})),
    ];
    for (i, (name, params)) in script.iter().enumerate() {
        s.submit(
            support::meta(i as u64 + 1, Actor::user("aaron")),
            cmd(name, params.clone()),
        )
        .unwrap_or_else(|e| panic!("{name}: {e}"));
    }

    let replayed = Session::replay(base, s.journal().to_vec()).expect("replay");
    assert!(
        s.project() == replayed.project(),
        "replay must reproduce the model exactly"
    );
    assert_eq!(
        s.tip_hash(),
        replayed.tip_hash(),
        "the blake3 chain must be identical"
    );

    // Full undo must return to the empty baseline: nothing left behind.
    let mut meta = timeline_core::session::SeqMeta::starting_at(
        script.len() as u64 + 1,
        Actor::user("undo"),
    );
    let mut s2 = s;
    while s2.undo(&mut meta).expect("undo") {}
    assert!(s2.project().tracks.iter().all(|t| t.fx.is_empty()));
    assert!(s2.project().master.fx.is_empty());
    assert!(s2.project().routing.nodes.is_empty());
}

/// Randomised inverse exactness over the whole family, the way
/// `properties.rs::single_command_inverse_restores_prestate` covers the rest of
/// the catalog. Deterministic seed sweep rather than proptest's generator so the
/// state machine (which ids exist, which keys are set, which links are legal)
/// stays legal by construction.
#[test]
fn randomised_fx_sequences_have_exact_inverses() {
    let keys = ["threshold", "ratio", "mix", "gain", "bypass"];
    let hosts = ["track.t1", "track.t2", "bus.grp", "master"];
    let kinds = ["eq", "compressor", "gate", "utility", "reverb"];

    for seed in 0u64..64 {
        let mut rng = support::Rng::new(seed.wrapping_mul(0x9E3779B97F4A7C15) ^ 0xDEADBEEF);
        let mut p = seeded();
        let mut minted = 0u64;
        for _ in 0..40 {
            let host = hosts[rng.below(hosts.len() as u64) as usize];
            let href = NodeRef::parse(host).unwrap();
            let existing: Vec<String> = p
                .fx_chain(&href)
                .map(|c| c.iter().map(|f| f.id.clone()).collect())
                .unwrap_or_default();

            let c = if existing.is_empty() || rng.below(4) == 0 {
                minted += 1;
                cmd(
                    "fx.add",
                    json!({"target": host, "fxId": format!("f{minted}"),
                           "kind": kinds[rng.below(kinds.len() as u64) as usize]}),
                )
            } else {
                let fx_id = &existing[rng.below(existing.len() as u64) as usize];
                let key = keys[rng.below(keys.len() as u64) as usize];
                match rng.below(6) {
                    0 => cmd("fx.remove", json!({"target": host, "fxId": fx_id})),
                    1 => cmd(
                        "fx.move",
                        json!({"target": host, "fxId": fx_id,
                               "index": rng.below(existing.len() as u64)}),
                    ),
                    2 => cmd(
                        "fx.param.set",
                        json!({"target": host, "fxId": fx_id, "key": key,
                               "value": rng.below(24) as i64 - 12}),
                    ),
                    3 => cmd(
                        "fx.param.clear",
                        json!({"target": host, "fxId": fx_id, "key": key}),
                    ),
                    4 => {
                        let src = hosts[rng.below(hosts.len() as u64) as usize];
                        cmd(
                            "fx.sidechain.set",
                            json!({"target": host, "fxId": fx_id, "source": src}),
                        )
                    }
                    _ => cmd("fx.sidechain.clear", json!({"target": host, "fxId": fx_id})),
                }
            };

            // Illegal candidates for this state (a clear with nothing to clear,
            // a link that would cycle) are SKIPPED — their rejects prove the
            // no-partial-apply rule as much as the accepts prove the inverses.
            let pre = p.clone();
            let name = c.name();
            match p.apply_cmd(&c) {
                Ok(effect) => {
                    let mut probe = p.clone();
                    for inv in &effect.inverse {
                        probe.apply_cmd(inv).unwrap_or_else(|e| {
                            panic!("seed {seed}: inverse {} of {name} failed: {e}", inv.name())
                        });
                    }
                    assert!(
                        pre == probe,
                        "seed {seed}: inverse of {name} did not restore the pre-state"
                    );
                }
                Err(_) => assert!(pre == p, "seed {seed}: {name} partially applied on failure"),
            }
        }
    }
}
