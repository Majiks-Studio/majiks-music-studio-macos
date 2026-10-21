//! The routing DAG through the real command bus (design §5).
//!
//! E0's contract: topology is project data (journaled, undoable), cycles are
//! rejected at COMMAND time so the audio thread can never discover one, and the
//! evaluation order is precomputed on the control thread. Render-side
//! evaluation is E5's; nothing here touches it.

use serde_json::json;
use timeline_core::envelope::{Actor, EntryMeta};
use timeline_core::model::{Project, Track};
use timeline_core::package::{from_project_json, to_project_json};
use timeline_core::routing::NodeRef;
use timeline_core::session::{SeqMeta, Session};
use timeline_core::tempo::{Bpm, TempoMap};

fn meta(n: u32) -> EntryMeta {
    EntryMeta {
        id: format!("1{n:025}"),
        ts: "2026-07-24T00:00:00Z".into(),
        actor: Actor::user("aaron"),
    }
}

fn undo_meta() -> SeqMeta {
    SeqMeta::starting_at(900, Actor::user("undo"))
}

fn session() -> Session {
    let mut p = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    p.tracks.push(Track::new("t1", "Track 1"));
    p.tracks.push(Track::new("t2", "Track 2"));
    Session::new(p)
}

#[test]
fn nodes_and_edges_are_journaled_project_data() {
    let mut s = session();
    s.submit_json(
        meta(1),
        "route.node.add",
        json!({"nodeId": "grp", "kind": "group", "name": "Drum Bus"}),
    )
    .unwrap();
    s.submit_json(
        meta(2),
        "route.connect",
        json!({"edgeId": "e1", "from": "track.t1", "to": "bus.grp",
               "level": 1, "tap": "post"}),
    )
    .unwrap();
    s.submit_json(
        meta(3),
        "route.connect",
        json!({"edgeId": "e2", "from": "bus.grp", "to": "master",
               "level": 1, "tap": "post"}),
    )
    .unwrap();

    let r = &s.project().routing;
    assert_eq!(r.nodes.len(), 1);
    assert_eq!(r.edges.len(), 2);
    assert_eq!(r.node("grp").unwrap().name, "Drum Bus");
    assert_eq!(s.journal().len(), 3, "all three are journaled");

    // The precomputed evaluation order puts every source before its sink.
    let ids = ["t1", "t2"];
    let sched: Vec<String> = r
        .schedule(&ids, &[])
        .unwrap()
        .iter()
        .map(|st| st.node.wire_name())
        .collect();
    let pos = |n: &str| sched.iter().position(|x| x == n).unwrap();
    assert!(pos("track.t1") < pos("bus.grp"));
    assert!(pos("bus.grp") < pos("master"));
}

#[test]
fn a_cycle_is_rejected_at_command_time_and_leaves_the_graph_untouched() {
    let mut s = session();
    for (n, id) in [(1u32, "a"), (2, "b")] {
        s.submit_json(
            meta(n),
            "route.node.add",
            json!({"nodeId": id, "kind": "bus", "name": id}),
        )
        .unwrap();
    }
    s.submit_json(
        meta(3),
        "route.connect",
        json!({"edgeId": "e1", "from": "bus.a", "to": "bus.b", "level": 1, "tap": "post"}),
    )
    .unwrap();

    let before = s.project().routing.clone();
    let err = s
        .submit_json(
            meta(4),
            "route.connect",
            json!({"edgeId": "e2", "from": "bus.b", "to": "bus.a", "level": 1, "tap": "post"}),
        )
        .expect_err("the cycle-closing edge must be refused");
    assert!(format!("{err}").contains("cycle"), "{err}");

    assert_eq!(
        s.project().routing,
        before,
        "a rejected command must not partially mutate the graph"
    );
    assert_eq!(s.journal().len(), 3, "a rejected command is not journaled");
    // And therefore the schedule always exists.
    assert!(s.project().routing.schedule(&["t1", "t2"], &[]).is_ok());
}

#[test]
fn master_can_never_be_a_source_and_self_loops_are_refused() {
    let mut s = session();
    s.submit_json(
        meta(1),
        "route.node.add",
        json!({"nodeId": "a", "kind": "bus", "name": "A"}),
    )
    .unwrap();
    for (n, from, to) in [
        (2u32, "master", "bus.a"),
        (3, "bus.a", "bus.a"),
        (4, "bus.zz", "master"),
        (5, "track.nope", "bus.a"),
    ] {
        assert!(
            s.submit_json(
                meta(n),
                "route.connect",
                json!({"edgeId": format!("e{n}"), "from": from, "to": to,
                       "level": 1, "tap": "post"}),
            )
            .is_err(),
            "{from} -> {to} should be refused"
        );
    }
}

#[test]
fn undo_restores_the_exact_pre_state_including_removed_edges() {
    let mut s = session();
    s.submit_json(
        meta(1),
        "route.node.add",
        json!({"nodeId": "grp", "kind": "group", "name": "Drum Bus"}),
    )
    .unwrap();
    for (n, id, from, to) in [
        (2u32, "e1", "track.t1", "bus.grp"),
        (3, "e2", "track.t2", "bus.grp"),
        (4, "e3", "bus.grp", "master"),
    ] {
        s.submit_json(
            meta(n),
            "route.connect",
            json!({"edgeId": id, "from": from, "to": to, "level": 1, "tap": "post"}),
        )
        .unwrap();
    }
    let before = s.project().routing.clone();

    // Removing the node takes its three edges with it...
    s.submit_json(meta(5), "route.node.remove", json!({"nodeId": "grp"}))
        .unwrap();
    assert!(s.project().routing.nodes.is_empty());
    assert!(s.project().routing.edges.is_empty());

    // ...and undo puts all four back, exactly.
    assert!(s.undo(&mut undo_meta()).expect("undo"), "there must be something to undo");
    assert_eq!(
        s.project().routing,
        before,
        "undo must restore the node AND every removed edge"
    );
}

#[test]
fn removing_a_track_takes_its_edges_with_it_and_undo_restores_them() {
    // A track is an implicit node, so a dangling `track.<id>` edge would make
    // the schedule emit a phantom step.
    let mut s = session();
    s.submit_json(
        meta(1),
        "route.node.add",
        json!({"nodeId": "grp", "kind": "group", "name": "G"}),
    )
    .unwrap();
    s.submit_json(
        meta(2),
        "route.connect",
        json!({"edgeId": "e1", "from": "track.t2", "to": "bus.grp",
               "level": 1, "tap": "post"}),
    )
    .unwrap();
    let before = s.project().routing.clone();

    s.submit_json(meta(3), "track.remove", json!({"trackId": "t2"}))
        .unwrap();
    assert!(
        s.project().routing.edges.is_empty(),
        "the edge from the removed track must go with it"
    );
    let sched = s.project().routing.schedule(&["t1"], &[]).unwrap();
    assert!(
        !sched.iter().any(|st| st.node == NodeRef::Track("t2".into())),
        "no phantom step for a removed track"
    );

    assert!(s.undo(&mut undo_meta()).expect("undo"), "there must be something to undo");
    assert_eq!(s.project().routing, before);
}

#[test]
fn edge_level_and_tap_are_self_inverse() {
    let mut s = session();
    s.submit_json(
        meta(1),
        "route.node.add",
        json!({"nodeId": "a", "kind": "bus", "name": "A"}),
    )
    .unwrap();
    s.submit_json(
        meta(2),
        "route.connect",
        json!({"edgeId": "e1", "from": "track.t1", "to": "bus.a",
               "level": 1, "tap": "post"}),
    )
    .unwrap();
    let before = s.project().routing.clone();

    s.submit_json(
        meta(3),
        "route.edge.set",
        json!({"edgeId": "e1", "level": 0, "tap": "pre"}),
    )
    .unwrap();
    let e = s.project().routing.edge("e1").unwrap();
    assert_eq!(e.level.0.to_string(), "0", "level stays a Num, not an f64");
    assert_eq!(e.tap.wire_name(), "pre");

    assert!(s.undo(&mut undo_meta()).expect("undo"), "there must be something to undo");
    assert_eq!(s.project().routing, before);
}

#[test]
fn the_graph_round_trips_through_the_checkpoint() {
    let mut s = session();
    s.submit_json(
        meta(1),
        "route.node.add",
        json!({"nodeId": "grp", "kind": "group", "name": "Drum Bus"}),
    )
    .unwrap();
    s.submit_json(
        meta(2),
        "route.connect",
        json!({"edgeId": "e1", "from": "track.t1", "to": "bus.grp",
               "level": 1, "tap": "pre"}),
    )
    .unwrap();

    let out = to_project_json(&s);
    let back = from_project_json(&out).expect("reloads");
    assert_eq!(back.routing, *&s.project().routing);

    // And an untouched project gains no key at all.
    let plain = to_project_json(&session());
    assert!(
        plain.get("engineRouting").is_none(),
        "an empty routing graph must not appear in the checkpoint"
    );
}

#[test]
fn the_project_phase_anchor_is_journaled_undoable_and_persisted() {
    // Deferred proposal L8, accepted: bar-aligned lead-in for E7 warp markers.
    let mut s = session();
    assert_eq!(s.project().phase_anchor_ticks, 0, "v1 behaviour is 0");
    s.submit_json(meta(1), "project.setPhaseAnchor", json!({"anchorTicks": 1915}))
        .unwrap();
    assert_eq!(s.project().phase_anchor_ticks, 1915);

    let out = to_project_json(&s);
    assert_eq!(out["phaseAnchorTicks"], json!(1915));
    assert_eq!(
        from_project_json(&out).unwrap().phase_anchor_ticks,
        1915
    );

    assert!(s.undo(&mut undo_meta()).expect("undo"), "there must be something to undo");
    assert_eq!(s.project().phase_anchor_ticks, 0);
    assert!(
        to_project_json(&s).get("phaseAnchorTicks").is_none(),
        "back to the default must be byte-identical to never having set it"
    );
}
