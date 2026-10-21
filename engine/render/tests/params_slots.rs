//! E5-params: the stale-slot hygiene contract (DESIGN-E5-routing.md §6.3)
//! proven THROUGH THE HOST, not by poking `EngineParams`.
//!
//! §12.5 is blunt about why this file exists:
//!
//! > `EngineParams` setters called directly in a test ... SKIP
//! > `host.rs::sync_params` / `sync_track_params` — **so a test that sets
//! > params directly does NOT prove the host pushes them.** This is exactly
//! > how the solo bug survived.
//!
//! `render/src/params.rs`'s unit tests are the direct-poke kind and say so.
//! These drive `ProjectHost::apply`, a real command bus: model apply ->
//! `sync_track_params` -> `sync_routing_params` -> `push_session`. The
//! assertions are on the atomics the audio thread will read.
//!
//! ## Seam honesty (§12.5) — hops traversed
//!
//! | Hop | Traversed? |
//! |---|---|
//! | `ProjectHost::apply` -> `apply_internal` -> `Project::apply` | YES |
//! | `sync_track_params` -> `sync_routing_params` -> the `clear_*_from` calls | YES |
//! | `push_session` -> `compile_session_full` -> `RenderCommand::SetSession` | YES |
//! | `route.*` wire command -> `Routing` | **NO — see below** |
//! | `RenderCore::render` (the atomics are read per block) | NO — E5-graph wires the reader |
//! | cpal device callback | NO — `Engine::new` never opens a stream |
//!
//! **Why the routing graph is built on the model directly here:** the
//! `route.*` family lives on the `Cmd` JSON bus (`timeline_core::Cmd`), and
//! `ProjectHost::apply` takes the older P0-B `Command` enum, which has no
//! routing variants. The wire -> model hop is timeline-core's and is covered
//! there; the hop under test in this file is model -> `EngineParams`, and it
//! is entered exactly as production enters it — through `apply`.
//! `agent-surface/tests/e5_params_seam.rs` carries the `submit_json` half.
//!
//! Device-free and silent: the engine's output stream is never started.

use render::engine::{Engine, EngineConfig};
use render::host::ProjectHost;
use render::params::{MAX_ROUTE_EDGES, MAX_ROUTE_NODES, MIN_GAIN_DB};
use timeline_core::{
    Bpm, Command, NodeKind, NodeRef, Num, Project, RouteEdge, RouteNode, Tap, TempoMap,
};

fn build_host() -> ProjectHost {
    let project = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    let engine = Engine::new(EngineConfig::default());
    let mut host = ProjectHost::new(project, engine);
    for (id, name) in [("t1", "A"), ("t2", "B")] {
        host.apply(&Command::TrackAdd {
            track_id: id.into(),
            name: name.into(),
            index: None,
        })
        .unwrap();
    }
    host
}

/// One group node plus two edges (t1 -> grp, t2 -> grp): live counts are
/// nodes = 1, edges = 2.
fn with_group(host: &mut ProjectHost) {
    host.project.routing.nodes.push(RouteNode {
        id: "grp".into(),
        kind: NodeKind::Group,
        name: "Group".into(),
        // The bus-fader lane added `gain_db` (route.node.set); the int-shaped
        // 0 dB default keeps this fixture's meaning (an untrimmed node).
        gain_db: timeline_core::routing::gain_db_default(),
        // E5-model added `fx` to RouteNode after this fixture was written; an
        // empty chain keeps the node's meaning here (a bare summing point).
        fx: Vec::new(),
        extra: Default::default(),
    });
    for (edge, from) in [("e1", "t1"), ("e2", "t2")] {
        host.project.routing.edges.push(RouteEdge {
            id: edge.into(),
            from: NodeRef::Track(from.into()),
            to: NodeRef::Node("grp".into()),
            level: Num::int(1),
            tap: Tap::Post,
            extra: Default::default(),
        });
    }
}

/// Any non-transport command runs the host's params sync. `track.mute` is a
/// mixer command, so this is the same call production makes on a fader move.
fn mutate(host: &mut ProjectHost, mute: bool) {
    host.apply(&Command::TrackMute {
        track_id: "t1".into(),
        mute,
    })
    .unwrap();
}

/// The §6.3 hazard, end to end: a level left in a slot the current session no
/// longer uses must not survive a mutation, and a level in a LIVE slot must.
///
/// Over-clearing is as wrong as under-clearing: `clear_edge_levels_from(0)`
/// would wipe the level the host is about to push for a live edge.
#[test]
fn host_clears_retired_edge_slots_and_keeps_live_ones() {
    let mut host = build_host();
    with_group(&mut host);
    let params = host.engine().params_arc();

    // Slots 0..2 are this session's two edges. 2..8 are retired/never-used.
    for slot in 0..8 {
        params.set_edge_level(slot, 3.0);
    }
    params.set_edge_level(MAX_ROUTE_EDGES - 1, 3.0);

    mutate(&mut host, true);

    for slot in 0..2 {
        assert_eq!(
            params.edge_level_target(slot),
            3.0,
            "live edge slot {slot} was wiped by the host sync; a pushed send level \
             would not survive the next unrelated edit"
        );
    }
    for slot in 2..8 {
        assert_eq!(
            params.edge_level_target(slot),
            0.0,
            "retired edge slot {slot} kept its level: a recycled edge would inherit \
             a level the user never set for it (the §6.3 stale-slot hazard)"
        );
    }
    assert_eq!(
        params.edge_level_target(MAX_ROUTE_EDGES - 1),
        0.0,
        "the clear must reach the top of the slot space, not stop at the dirty prefix"
    );
}

#[test]
fn host_clears_retired_node_gain_slots_and_keeps_live_ones() {
    let mut host = build_host();
    with_group(&mut host);
    let params = host.engine().params_arc();

    for slot in 0..6 {
        params.set_node_gain_db(slot, -18.0);
    }
    params.set_node_gain_db(MAX_ROUTE_NODES - 1, -18.0);

    mutate(&mut host, true);

    let expected_live = 10.0_f32.powf(MIN_GAIN_DB.max(-18.0) / 20.0);
    assert!(
        (params.node_gain_target(0) - expected_live).abs() < 1e-6,
        "the one live node slot was wiped by the host sync (got {})",
        params.node_gain_target(0)
    );
    for slot in 1..6 {
        assert_eq!(
            params.node_gain_target(slot),
            1.0,
            "retired node slot {slot} kept its fader: a recycled bus would boot \
             at a gain the user never set"
        );
    }
    assert_eq!(params.node_gain_target(MAX_ROUTE_NODES - 1), 1.0);
}

/// A v1 project (empty `Routing`) retires EVERY routing slot, so the whole
/// slot space must come back clean. This is the case that actually ships
/// today, and it is the one a `skip(from)` off-by-one would break.
#[test]
fn empty_routing_clears_the_entire_slot_space() {
    let mut host = build_host();
    let params = host.engine().params_arc();
    assert!(host.project.routing.edges.is_empty());
    assert!(host.project.routing.nodes.is_empty());

    for slot in [0usize, 1, 17, MAX_ROUTE_EDGES - 1] {
        params.set_edge_level(slot, 4.0);
    }
    for slot in [0usize, 5, MAX_ROUTE_NODES - 1] {
        params.set_node_gain_db(slot, 12.0);
    }

    mutate(&mut host, true);

    for slot in [0usize, 1, 17, MAX_ROUTE_EDGES - 1] {
        assert_eq!(params.edge_level_target(slot), 0.0, "edge slot {slot}");
    }
    for slot in [0usize, 5, MAX_ROUTE_NODES - 1] {
        assert_eq!(params.node_gain_target(slot), 1.0, "node slot {slot}");
    }
}

/// Removing an edge SHRINKS the live count, which is the moment the hazard
/// actually fires: the slot the removed edge used is now retired and must be
/// cleared by the very mutation that retired it.
#[test]
fn shrinking_the_graph_retires_the_freed_slot_on_the_same_mutation() {
    let mut host = build_host();
    with_group(&mut host);
    let params = host.engine().params_arc();
    params.set_edge_level(0, 2.0);
    params.set_edge_level(1, 2.0);

    host.project.routing.edges.pop();
    mutate(&mut host, true);

    assert_eq!(host.project.routing.edges.len(), 1);
    assert_eq!(
        params.edge_level_target(0),
        2.0,
        "the surviving edge's slot was wiped"
    );
    assert_eq!(
        params.edge_level_target(1),
        0.0,
        "the freed edge slot still carries its level"
    );
}
