//! `route.node.set` — the node FADER command (DESIGN-E5-routing.md §4.3's
//! "buses with their own fader", finally reachable from a surface).
//!
//! What is pinned here, and why:
//!
//! - **Byte compatibility** (§16.1 discipline, same template as
//!   `a_project_with_no_fx_checkpoints_to_unchanged_bytes`): a node whose fader
//!   was never touched — or was set to the INT-shaped default — writes NO
//!   `gainDb` key, so every pre-fader project checkpoints to identical bytes.
//! - **package.rs WRITES and READS the field** (E0 §9.3: a field the
//!   checkpoint does not read back is DESTROYED on the next save, and a saved
//!   fader that reopens at unity is exactly that bug).
//! - **The truthful self-inverse carrying the prior value**, shape-exact,
//!   matching `mix.gain` / `route.edge.set`.
//! - **`route.node.remove`'s multi-inverse restores the fader** — the
//!   `track.remove`-drops-devices class, closed before it ships this time.
//!
//! Seam honesty (§12.5): everything here is MODEL-level (`apply_cmd`,
//! `to_project_json`/`from_project_json`). The full public path — submit_json
//! → sync_after_mutation → sync_graph_params → rendered buffers — is proven in
//! `agent-surface/tests/route_node_fader_audible.rs`; a model green here says
//! nothing about audibility, which is §0 row 7's whole lesson.

use serde_json::{json, Value};
use timeline_core::catalog::Catalog;
use timeline_core::cmd::Cmd;
use timeline_core::error::CommandError;
use timeline_core::model::Project;
use timeline_core::num::Num;
use timeline_core::package::{from_project_json, to_project_json};
use timeline_core::session::Session;
use timeline_core::tempo::{Bpm, TempoMap};
use timeline_core::model::Track;

fn cmd(name: &str, params: Value) -> Cmd {
    Cmd::from_wire(name, params).expect("command parses")
}

/// Two tracks and one group node, no fader touched anywhere.
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

/// The routing node objects inside a checkpoint, for structural (not
/// text-contains) assertions — `gainDb` is also a track-level spelling, so a
/// substring check could pass or fail for the wrong reason.
fn checkpoint_nodes(json: &Value) -> &Vec<Value> {
    json["engineRouting"]["nodes"]
        .as_array()
        .expect("engineRouting.nodes present")
}

// ---------------------------------------------------------------------------
// Apply semantics + the truthful inverse.
// ---------------------------------------------------------------------------

#[test]
fn the_fader_sets_and_self_inverts_exactly() {
    let mut p = seeded();
    let pre = p.clone();

    let effect = p
        .apply_cmd(&cmd("route.node.set", json!({"nodeId": "grp", "gainDb": -6})))
        .unwrap();
    assert_eq!(p.routing.nodes[0].gain_db, Num::int(-6));
    // Self-inverse carrying the PRIOR value (the int-shaped default here).
    assert_eq!(effect.inverse.len(), 1);
    assert_eq!(effect.inverse[0].name(), "route.node.set");
    for inv in &effect.inverse {
        p.apply_cmd(inv).unwrap();
    }
    assert!(pre == p, "inverse did not restore the exact pre-state");
}

/// Value SHAPE is part of the contract: the inverse of a second set must carry
/// the prior FLOAT-shaped value verbatim, because the hint is hashed and the
/// chain replays byte-for-byte.
#[test]
fn the_inverse_preserves_the_prior_values_num_shape() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "route.node.set",
        json!({"nodeId": "grp", "gainDb": -6.5}),
    ))
    .unwrap();
    let effect = p
        .apply_cmd(&cmd("route.node.set", json!({"nodeId": "grp", "gainDb": 3})))
        .unwrap();
    let Cmd::RouteNodeSet { gain_db, .. } = &effect.inverse[0] else {
        panic!("inverse must be route.node.set");
    };
    assert_eq!(
        serde_json::to_string(gain_db).unwrap(),
        "-6.5",
        "the prior float shape must survive into the (hashed) inverse"
    );
}

#[test]
fn bounds_and_dangling_node_are_refused() {
    let mut p = seeded();
    // Same window as mix.gain: [-60, 12], checked in apply so REPLAY of an
    // out-of-range value is refused too, not just live submit.
    for bad in [json!(12.5), json!(-60.5), json!(999)] {
        let err = p
            .apply_cmd(&cmd("route.node.set", json!({"nodeId": "grp", "gainDb": bad})))
            .unwrap_err();
        assert!(
            matches!(err, CommandError::OutOfRange(_)),
            "gainDb {bad} must be OutOfRange, got {err:?}"
        );
    }
    let err = p
        .apply_cmd(&cmd(
            "route.node.set",
            json!({"nodeId": "ghost", "gainDb": -3}),
        ))
        .unwrap_err();
    assert!(
        matches!(&err, CommandError::Routing(m) if m.contains("ghost")),
        "a dangling node must be refused BY NAME, got {err:?}"
    );
    // Live-submit schema: unknown params are rejected (additionalProperties
    // false), and gainDb must be a number.
    let cat = Catalog::get();
    assert!(cat
        .validate_params(
            "route.node.set",
            &json!({"nodeId": "grp", "gainDb": -6, "extra": 1})
        )
        .is_err());
    assert!(cat
        .validate_params("route.node.set", &json!({"nodeId": "grp", "gainDb": "-6"}))
        .is_err());
}

// ---------------------------------------------------------------------------
// Byte compatibility + persistence (package.rs must WRITE and READ).
// ---------------------------------------------------------------------------

/// A project whose node faders were never touched serializes to EXACTLY the
/// bytes it did before this field existed — and an explicit set BACK to the
/// int-shaped default is byte-identical to never having touched it.
#[test]
fn an_untouched_fader_checkpoints_to_unchanged_bytes() {
    let pristine = to_project_json(&Session::new(seeded()));
    assert!(
        !checkpoint_nodes(&pristine)[0]
            .as_object()
            .unwrap()
            .contains_key("gainDb"),
        "an unset node fader must not be written: {pristine}"
    );

    // set -6, then back to the integer default: omitted again, bit-for-bit.
    let mut p = seeded();
    p.apply_cmd(&cmd("route.node.set", json!({"nodeId": "grp", "gainDb": -6})))
        .unwrap();
    p.apply_cmd(&cmd("route.node.set", json!({"nodeId": "grp", "gainDb": 0})))
        .unwrap();
    assert_eq!(
        to_project_json(&Session::new(p)),
        pristine,
        "an int-shaped 0 dB fader is THE default and must serialize as absence"
    );
}

/// A FLOAT-shaped 0.0 is a real journaled value, not the default: `Num`
/// equality is shape-aware, and dropping it would make the checkpoint disagree
/// with the journal's hashed shapes (design §9.8.1's hazard, the safe side).
#[test]
fn a_float_zero_fader_is_written_not_dropped() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "route.node.set",
        json!({"nodeId": "grp", "gainDb": 0.0}),
    ))
    .unwrap();
    let json = to_project_json(&Session::new(p));
    let node = checkpoint_nodes(&json)[0].as_object().unwrap();
    assert_eq!(
        serde_json::to_string(&node["gainDb"]).unwrap(),
        "0.0",
        "float-shaped 0.0 must be WRITTEN (shape-aware default comparison)"
    );
}

/// The §9.3 test: write AND read. A fader that saves but does not load would
/// reopen at unity and then SAVE at unity — silent data destruction.
#[test]
fn a_set_fader_survives_save_and_reopen() {
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "route.node.set",
        json!({"nodeId": "grp", "gainDb": -6.5}),
    ))
    .unwrap();

    let json = to_project_json(&Session::new(p.clone()));
    let back = from_project_json(&json).expect("reopen");
    assert_eq!(
        back.routing.nodes[0].gain_db, p.routing.nodes[0].gain_db,
        "the fader must survive the round trip"
    );
    assert_eq!(
        serde_json::to_string(&back.routing.nodes[0].gain_db).unwrap(),
        "-6.5",
        "float shape preserved through disk"
    );
    assert_eq!(back.routing, p.routing, "nothing else on the graph moved");

    // A second save is byte-identical — the READ is complete, not merely
    // present (same fixed-point proof the fx round-trip uses).
    assert_eq!(
        to_project_json(&Session::new(back)),
        json,
        "save -> open -> save must be a fixed point"
    );
}

// ---------------------------------------------------------------------------
// route.node.remove's multi-inverse carries the fader.
// ---------------------------------------------------------------------------

/// Removing a trimmed bus and undoing must NOT reopen it at unity. The inverse
/// sequence gains a `route.node.set` exactly when the fader is non-default —
/// and stays the bare declared `route.node.add` when it is default, so the
/// "may be a sequence" shape honesty of tests/inverse_shape.rs is preserved.
#[test]
fn remove_restores_the_fader_through_the_multi_inverse() {
    // Non-default fader, an insert, and an incident edge: the RICH state.
    let mut p = seeded();
    p.apply_cmd(&cmd(
        "route.connect",
        json!({"edgeId": "e1", "from": "track.t1", "to": "bus.grp",
               "level": 1, "tap": "post"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "bus.grp", "fxId": "comp", "kind": "compressor"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "route.node.set",
        json!({"nodeId": "grp", "gainDb": -9.25}),
    ))
    .unwrap();

    let pre = p.clone();
    let effect = p
        .apply_cmd(&cmd("route.node.remove", json!({"nodeId": "grp"})))
        .unwrap();
    assert!(
        effect
            .inverse
            .iter()
            .any(|c| matches!(c, Cmd::RouteNodeSet { .. })),
        "the multi-inverse must carry the fader restore"
    );
    for inv in &effect.inverse {
        p.apply_cmd(inv).unwrap();
    }
    assert!(
        pre == p,
        "undo of route.node.remove did not restore the exact pre-state \
         (fader, insert chain, edges)"
    );

    // ... and a node at the DEFAULT fader restores with NO route.node.set.
    let mut p = seeded();
    let effect = p
        .apply_cmd(&cmd("route.node.remove", json!({"nodeId": "grp"})))
        .unwrap();
    assert!(
        !effect
            .inverse
            .iter()
            .any(|c| matches!(c, Cmd::RouteNodeSet { .. })),
        "a default fader must not grow the inverse sequence"
    );
}

// ---------------------------------------------------------------------------
// The journal: hashed, replayable, undoable through the Session.
// ---------------------------------------------------------------------------

/// Through the real Session: submit, verify the hint is the prior value, undo,
/// and confirm the model round-trips. The hint is HASHED (E0 §9.5 gate 2), so
/// this also proves the inverse params are `Num`-clean.
#[test]
fn session_submit_and_undo_round_trip() {
    use timeline_core::envelope::Actor;

    let mut p = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    p.tracks.push(Track::new("t1", "Track 1"));
    let mut session = Session::new(p);
    let mut n = 0u64;
    let mut meta = || {
        n += 1;
        timeline_core::envelope::EntryMeta {
            id: format!("{n:026}"),
            ts: "2026-07-25T12:00:00Z".into(),
            actor: Actor::user("aaron"),
        }
    };
    session
        .submit_json(
            meta(),
            "route.node.add",
            json!({"nodeId": "b1", "kind": "bus", "name": "Bus"}),
        )
        .unwrap();
    session
        .submit_json(
            meta(),
            "route.node.set",
            json!({"nodeId": "b1", "gainDb": -6.0}),
        )
        .unwrap();
    assert_eq!(
        serde_json::to_string(&session.project().routing.nodes[0].gain_db).unwrap(),
        "-6.0"
    );
    let mut seq = timeline_core::session::SeqMeta::starting_at(n + 1, Actor::user("aaron"));
    assert!(session.undo(&mut seq).unwrap());
    assert_eq!(
        session.project().routing.nodes[0].gain_db,
        Num::int(0),
        "undo must restore the prior (default) fader exactly"
    );
}
