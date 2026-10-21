//! **THE sidechain-ordering test** (`DESIGN-E5-routing.md` §17.3, §18.2, §20.2/6).
//!
//! # Why this file exists
//!
//! A sidechain is an ORDERING CONSTRAINT, not an audio edge. `Routing::schedule`
//! sorts over audio edges; a link carries no audio, so **the sort has to be told
//! about it separately**. The doc states the failure mode and it is worth
//! restating because it is not a rounding error:
//!
//! > If the sort is not told, the detector reads `node_acc[source]` **before it
//! > has been written this frame, i.e. exactly `0.0`.** Not a one-sample error —
//! > **silence**. The compressor would never duck.
//!
//! And the reason it is dangerous rather than merely wrong: **every model-level
//! test still passes.** `Fx::sidechain` is `Some(source)` in the model, the
//! command journals, the inverse is exact, `project.json` round-trips. The bug
//! lives entirely in the ORDER, and nothing that asserts on model state can see
//! it. That is the "green on the wrong axis" class this program keeps catching.
//!
//! # Test-seam honesty (§12.5) — the hops this file traverses, and the ones it does NOT
//!
//! | Traversed | SKIPPED |
//! |---|---|
//! | `Project::sidechain_links` → `Routing::schedule` → the baked `ScheduleStep` order | `compile.rs`'s translation of `ScheduleStep` into `NodeStep` |
//! | command-time link validation (`validate_new_link`) | **the renderer**: nothing here proves `rt.rs` reads `node_acc` in schedule order, or that a compressor ducks |
//!
//! **This test cannot prove the audio is right, and it does not claim to.** It
//! proves the one thing `timeline-core` owns: that the ORDER handed to the
//! renderer puts every key source strictly before its host. §20.2/5–6's
//! rendered-buffer proofs ("B's output dips in time with A's transients";
//! "assert the detector sees a non-zero key value on the first frame") are
//! E5-graph's, on real buffers, and this file is not a substitute for them.

use std::collections::BTreeSet;

use serde_json::json;
use timeline_core::cmd::Cmd;
use timeline_core::model::{Project, Track};
use timeline_core::routing::NodeRef;
use timeline_core::tempo::{Bpm, TempoMap};

fn project() -> Project {
    let mut p = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    p.tracks.push(Track::new("kick", "Kick"));
    p
}

fn cmd(name: &str, params: serde_json::Value) -> Cmd {
    Cmd::from_wire(name, params).unwrap_or_else(|e| panic!("{name}: {e}"))
}

/// Two buses declared in the order `bassbus`, `keybus`. Enumeration order is
/// tracks, then nodes in DECLARATION order, then master — so with no link the
/// sort puts `bassbus` (the host) BEFORE `keybus` (the key source). That is
/// precisely the arrangement in which the detector would read a not-yet-written
/// accumulator, and it is why this fixture uses two buses rather than a track
/// keying a bus (a track is always enumerated first, which would make the test
/// pass for the wrong reason).
fn two_bus_project() -> Project {
    let mut p = project();
    for id in ["bassbus", "keybus"] {
        p.apply_cmd(&cmd(
            "route.node.add",
            json!({"nodeId": id, "kind": "bus", "name": id}),
        ))
        .unwrap();
    }
    p.apply_cmd(&cmd(
        "route.connect",
        json!({"edgeId": "e1", "from": "bus.bassbus", "to": "master", "level": 1, "tap": "post"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "route.connect",
        json!({"edgeId": "e2", "from": "bus.keybus", "to": "master", "level": 1, "tap": "post"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "fx.add",
        json!({"target": "bus.bassbus", "fxId": "comp", "kind": "compressor"}),
    ))
    .unwrap();
    p
}

fn order(p: &Project, links: &[(NodeRef, NodeRef)]) -> Vec<String> {
    let ids: Vec<&str> = p.tracks.iter().map(|t| t.id.as_str()).collect();
    p.routing
        .schedule(&ids, links)
        .expect("schedule")
        .iter()
        .map(|s| s.node.wire_name())
        .collect()
}

fn pos(order: &[String], node: &str) -> usize {
    order
        .iter()
        .position(|s| s == node)
        .unwrap_or_else(|| panic!("{node} not in schedule {order:?}"))
}

// ---------------------------------------------------------------------------
// The proof, and the mutation that must break it.
// ---------------------------------------------------------------------------

/// **The baseline that makes the proof non-vacuous.** With NO link, the sort
/// puts the compressor's host BEFORE its key source. A renderer walking this
/// order reads `node_acc[keybus]` at exactly `0.0` — silence, not a small error.
///
/// If a later change to `all_nodes`'s enumeration order made this assertion
/// fail, the ordering test below would start passing for a reason that has
/// nothing to do with links, so this test is load-bearing: it pins that the
/// hazard is real in this fixture.
#[test]
fn without_the_link_the_host_is_scheduled_before_its_key_source() {
    let p = two_bus_project();
    let o = order(&p, &[]);
    assert!(
        pos(&o, "bus.bassbus") < pos(&o, "bus.keybus"),
        "fixture no longer exercises the hazard: {o:?}"
    );
}

/// **THE ordering proof.** Once the fx is keyed, `Project::sidechain_links`
/// reports the constraint and `Routing::schedule` honours it: the key source is
/// scheduled STRICTLY BEFORE the host, reversing the order above.
///
/// *Mutation check (§12.4), run and confirmed RED:* replacing
/// `&p.sidechain_links()` with `&[]` on the marked line — i.e. simulating a
/// `schedule` that was never told about the link, which is the exact §17.3
/// failure — makes this assertion fail with
/// `sidechain source must be scheduled first: ["track.kick", "bus.bassbus", "bus.keybus", "master"]`.
#[test]
fn the_link_forces_the_key_source_to_be_scheduled_first() {
    let p = two_bus_project();

    let links = p.sidechain_links();
    assert!(links.is_empty(), "no link until fx.sidechain.set");

    let mut p = p;
    p.apply_cmd(&cmd(
        "fx.sidechain.set",
        json!({"target": "bus.bassbus", "fxId": "comp", "source": "bus.keybus"}),
    ))
    .unwrap();

    let links = p.sidechain_links();
    assert_eq!(
        links,
        vec![(
            NodeRef::Node("keybus".into()),
            NodeRef::Node("bassbus".into())
        )],
        "the link must be reported as (source, host)"
    );

    // MUTATION SITE: swap `&links` for `&[]` and this test must go red.
    let o = order(&p, &links);
    assert!(
        pos(&o, "bus.keybus") < pos(&o, "bus.bassbus"),
        "sidechain source must be scheduled first: {o:?}"
    );
    // ... and the audio topology is untouched: a link creates NO edge (§18.1).
    assert_eq!(p.routing.edges.len(), 2, "a link must not add an edge");
}

/// Clearing the link releases the constraint — the order reverts. Without this,
/// a stale constraint could keep an ordering alive after the feature that needed
/// it was removed.
#[test]
fn clearing_the_link_releases_the_ordering_constraint() {
    let mut p = two_bus_project();
    p.apply_cmd(&cmd(
        "fx.sidechain.set",
        json!({"target": "bus.bassbus", "fxId": "comp", "source": "bus.keybus"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "fx.sidechain.clear",
        json!({"target": "bus.bassbus", "fxId": "comp"}),
    ))
    .unwrap();
    assert!(p.sidechain_links().is_empty());
    let o = order(&p, &p.sidechain_links());
    assert!(pos(&o, "bus.bassbus") < pos(&o, "bus.keybus"), "{o:?}");
}

/// A link is transitive through the sort exactly as an edge is: A keys B, B
/// keys C, so A must precede B must precede C even though no audio flows along
/// either link.
#[test]
fn links_chain_transitively_through_the_sort() {
    let mut p = project();
    for id in ["c", "b", "a"] {
        p.apply_cmd(&cmd(
            "route.node.add",
            json!({"nodeId": id, "kind": "bus", "name": id}),
        ))
        .unwrap();
        p.apply_cmd(&cmd(
            "fx.add",
            json!({"target": format!("bus.{id}"), "fxId": "g", "kind": "gate"}),
        ))
        .unwrap();
    }
    // Declaration order c, b, a — the reverse of the required order.
    p.apply_cmd(&cmd(
        "fx.sidechain.set",
        json!({"target": "bus.b", "fxId": "g", "source": "bus.a"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "fx.sidechain.set",
        json!({"target": "bus.c", "fxId": "g", "source": "bus.b"}),
    ))
    .unwrap();
    let o = order(&p, &p.sidechain_links());
    assert!(pos(&o, "bus.a") < pos(&o, "bus.b"), "{o:?}");
    assert!(pos(&o, "bus.b") < pos(&o, "bus.c"), "{o:?}");
}

/// The schedule stays a pure function of the project: the same graph and links
/// declared in different orders produce the identical order, so the bounce does
/// not depend on the order the user happened to click.
#[test]
fn the_schedule_is_deterministic_regardless_of_link_declaration_order() {
    let build = |reverse: bool| {
        let mut p = project();
        for id in ["x", "y", "z"] {
            p.apply_cmd(&cmd(
                "route.node.add",
                json!({"nodeId": id, "kind": "bus", "name": id}),
            ))
            .unwrap();
            p.apply_cmd(&cmd(
                "fx.add",
                json!({"target": format!("bus.{id}"), "fxId": "c", "kind": "compressor"}),
            ))
            .unwrap();
        }
        let mut sets = vec![("bus.z", "bus.x"), ("bus.y", "bus.x")];
        if reverse {
            sets.reverse();
        }
        for (host, src) in sets {
            p.apply_cmd(&cmd(
                "fx.sidechain.set",
                json!({"target": host, "fxId": "c", "source": src}),
            ))
            .unwrap();
        }
        order(&p, &p.sidechain_links())
    };
    assert_eq!(build(false), build(true));
}

// ---------------------------------------------------------------------------
// §18.3's acceptance table, one test per row, asserting the ERROR TEXT.
// ---------------------------------------------------------------------------

fn err_of(p: &mut Project, host: &str, src: &str) -> String {
    format!(
        "{}",
        p.apply_cmd(&cmd(
            "fx.sidechain.set",
            json!({"target": host, "fxId": "comp", "source": src}),
        ))
        .expect_err("should be rejected")
    )
}

/// Row 1: the canonical sidechain — a kick keys a compressor on the bass bus,
/// the kick also feeds master, the bass bus feeds master. **Not a cycle.** This
/// is the row that matters most: a validator that rejected it would make the
/// feature useless.
#[test]
fn row1_the_canonical_sidechain_is_accepted() {
    let mut p = two_bus_project();
    p.apply_cmd(&cmd(
        "route.connect",
        json!({"edgeId": "ek", "from": "track.kick", "to": "master", "level": 1, "tap": "post"}),
    ))
    .unwrap();
    p.apply_cmd(&cmd(
        "fx.sidechain.set",
        json!({"target": "bus.bassbus", "fxId": "comp", "source": "track.kick"}),
    ))
    .expect("the canonical sidechain must be ACCEPTED");
    let o = order(&p, &p.sidechain_links());
    assert!(pos(&o, "track.kick") < pos(&o, "bus.bassbus"), "{o:?}");
}

/// Row 2: bus X keys an fx on bus Y and bus Y already FEEDS bus X. The audio
/// edge plus the link close a loop, so the link is rejected and the message
/// names the path.
#[test]
fn row2_a_link_closing_a_loop_with_an_audio_edge_is_rejected_naming_the_path() {
    let mut p = two_bus_project();
    // bassbus -> keybus is audio; keybus -> bassbus as a KEY closes the loop.
    p.apply_cmd(&cmd(
        "route.connect",
        json!({"edgeId": "e3", "from": "bus.bassbus", "to": "bus.keybus",
               "level": 1, "tap": "post"}),
    ))
    .unwrap();
    let e = err_of(&mut p, "bus.bassbus", "bus.keybus");
    assert!(e.contains("cycle"), "{e}");
    assert!(e.contains("bus.bassbus"), "message must name the path: {e}");
    assert!(e.contains("bus.keybus"), "message must name the path: {e}");
    // ... and the model is UNCHANGED, because validation happens first.
    assert!(p.sidechain_links().is_empty());
}

/// Row 3: an fx keyed by its own host. That is `sidechain: None` (the internal
/// detector), not a link, and accepting it would create a self-loop in the sort.
#[test]
fn row3_keying_an_fx_from_its_own_host_is_rejected() {
    let mut p = two_bus_project();
    let e = err_of(&mut p, "bus.bassbus", "bus.bassbus");
    assert!(e.contains("internal detector"), "{e}");
}

/// Row 4: master is the topological sink and can never be a source — of audio
/// (`routing.rs:249-254`) or of a key.
#[test]
fn row4_master_can_never_be_a_key_source() {
    let mut p = two_bus_project();
    let e = err_of(&mut p, "bus.bassbus", "master");
    assert!(e.contains("master is the sink"), "{e}");
}

/// Row 5: a dangling reference. The link would name a node the graph does not
/// contain, which is a constraint the sort cannot honour.
#[test]
fn row5_a_dangling_source_is_rejected() {
    let mut p = two_bus_project();
    assert!(err_of(&mut p, "bus.bassbus", "bus.nope").contains("does not exist"));
    assert!(err_of(&mut p, "bus.bassbus", "track.nope").contains("does not exist"));
    // ... and a dangling HOST is an unknown fx, caught before the link rules.
    let e = format!(
        "{}",
        p.apply_cmd(&cmd(
            "fx.sidechain.set",
            json!({"target": "bus.nope", "fxId": "comp", "source": "bus.keybus"}),
        ))
        .expect_err("unknown host")
    );
    assert!(e.contains("no such routing node"), "{e}");
}

/// Row 6: A -> B -> C -> A over links ALONE, with no audio edges involved at
/// all. `find_cycle` is total over edges + links together, so a loop made only
/// of ordering constraints is still a loop.
#[test]
fn row6_a_cycle_made_only_of_links_is_rejected() {
    let mut p = project();
    for id in ["a", "b", "c"] {
        p.apply_cmd(&cmd(
            "route.node.add",
            json!({"nodeId": id, "kind": "bus", "name": id}),
        ))
        .unwrap();
        p.apply_cmd(&cmd(
            "fx.add",
            json!({"target": format!("bus.{id}"), "fxId": "comp", "kind": "compressor"}),
        ))
        .unwrap();
    }
    for (host, src) in [("bus.b", "bus.a"), ("bus.c", "bus.b")] {
        p.apply_cmd(&cmd(
            "fx.sidechain.set",
            json!({"target": host, "fxId": "comp", "source": src}),
        ))
        .unwrap();
    }
    let e = err_of(&mut p, "bus.a", "bus.c");
    assert!(e.contains("cycle"), "{e}");
    for n in ["bus.a", "bus.b", "bus.c"] {
        assert!(e.contains(n), "message must name the whole path: {e}");
    }
}

/// The mirror of row 2: an AUDIO EDGE that would close a cycle through an
/// existing LINK must be rejected by `route.connect` too.
///
/// Without this, `route.connect` would accept the edge, `schedule` would fail at
/// compile, and `push_live_session` swallows compile errors by design — live
/// audio silently frozen on the previous session, with no signal. Same
/// silent-degradation class, opposite direction.
#[test]
fn an_audio_edge_closing_a_cycle_through_a_link_is_rejected_at_command_time() {
    let mut p = two_bus_project();
    p.apply_cmd(&cmd(
        "fx.sidechain.set",
        json!({"target": "bus.bassbus", "fxId": "comp", "source": "bus.keybus"}),
    ))
    .unwrap();
    // keybus must precede bassbus. An audio edge bassbus -> keybus closes it.
    let e = format!(
        "{}",
        p.apply_cmd(&cmd(
            "route.connect",
            json!({"edgeId": "bad", "from": "bus.bassbus", "to": "bus.keybus",
                   "level": 1, "tap": "post"}),
        ))
        .expect_err("must be rejected at command time")
    );
    assert!(e.contains("cycle"), "{e}");
    assert_eq!(p.routing.edges.len(), 2, "no partial apply");
}

/// Re-pointing an existing link must not be validated against ITSELF: the link
/// being replaced is excluded from the `existing` set the cycle check sees.
///
/// The ordinary re-point below cannot fail either way — two links into the same
/// host never form a loop between themselves — so on its own it is a **vacuous**
/// assertion. (It was: the first version of this test stayed GREEN under the
/// mutation that deletes the exclusion.) The case that makes the exclusion
/// load-bearing is REPAIR, so this test drives it.
#[test]
fn repointing_a_link_is_not_rejected_against_the_link_it_replaces() {
    let mut p = two_bus_project();
    p.apply_cmd(&cmd(
        "route.node.add",
        json!({"nodeId": "third", "kind": "bus", "name": "third"}),
    ))
    .unwrap();
    for src in ["bus.keybus", "bus.third", "bus.keybus"] {
        p.apply_cmd(&cmd(
            "fx.sidechain.set",
            json!({"target": "bus.bassbus", "fxId": "comp", "source": src}),
        ))
        .unwrap_or_else(|e| panic!("re-point to {src}: {e}"));
    }
    assert_eq!(p.sidechain_links().len(), 1, "one fx holds one link");
}

/// **A CORRUPT LINK MUST BE REPAIRABLE.** This is what makes the exclusion above
/// load-bearing rather than defensive.
///
/// `fx.sidechain.set` refuses a link that would cycle, so no command in this
/// build can create one. A hand-edited or foreign-written `.mstudio` can — and
/// `Package::open` does not yet validate the routing graph (E5 §10/§18.4 is not
/// implemented; see the lane report). So a cyclic link CAN reach the model.
///
/// If the command validated the new link against the stale one it is replacing,
/// the stale cycle would reject every repair and the project would be
/// permanently unopenable-in-practice: the only way to fix the link would be to
/// hand-edit the file again. Excluding the replaced link makes "point it
/// somewhere legal" always work.
#[test]
fn a_cyclic_link_that_reached_the_model_can_still_be_repaired() {
    let mut p = two_bus_project();
    // Audio: bassbus -> keybus. A key link keybus -> bassbus closes the loop,
    // and fx.sidechain.set would refuse to create it...
    p.apply_cmd(&cmd(
        "route.connect",
        json!({"edgeId": "e3", "from": "bus.bassbus", "to": "bus.keybus",
               "level": 1, "tap": "post"}),
    ))
    .unwrap();
    assert!(p
        .apply_cmd(&cmd(
            "fx.sidechain.set",
            json!({"target": "bus.bassbus", "fxId": "comp", "source": "bus.keybus"}),
        ))
        .is_err());

    // ... so plant it the way a hand-edited file would.
    let ni = p.routing.node_index("bassbus").unwrap();
    p.routing.nodes[ni].fx[0].sidechain = Some(NodeRef::Node("keybus".into()));
    let cyclic = {
        let ids: BTreeSet<&str> = p.tracks.iter().map(|t| t.id.as_str()).collect();
        let links = p.sidechain_links();
        p.routing.find_cycle(&ids, &links).is_some()
    };
    assert!(cyclic, "the fixture must actually be corrupt");

    // The repair — re-point at a legal source — MUST be accepted.
    p.apply_cmd(&cmd(
        "fx.sidechain.set",
        json!({"target": "bus.bassbus", "fxId": "comp", "source": "track.kick"}),
    ))
    .expect("a corrupt link must be repairable, not permanently rejected");
    let still_cyclic = {
        let ids: BTreeSet<&str> = p.tracks.iter().map(|t| t.id.as_str()).collect();
        let links = p.sidechain_links();
        p.routing.find_cycle(&ids, &links).is_some()
    };
    assert!(!still_cyclic, "the repair must leave a DAG");

    // Clearing it is the other repair, and must work too.
    p.routing.nodes[ni].fx[0].sidechain = Some(NodeRef::Node("keybus".into()));
    p.apply_cmd(&cmd(
        "fx.sidechain.clear",
        json!({"target": "bus.bassbus", "fxId": "comp"}),
    ))
    .expect("clearing a corrupt link must work");
}

/// `find_cycle` and `schedule` must agree, links included: whenever `schedule`
/// refuses, `find_cycle` must be able to name the loop. A disagreement would
/// produce the "not a DAG; it should have been rejected at command time" error
/// with `unknown` as the path — a dead end for whoever has to debug it.
#[test]
fn find_cycle_and_schedule_agree_over_links() {
    let mut r = timeline_core::routing::Routing::default();
    for id in ["a", "b"] {
        r.nodes.push(timeline_core::routing::RouteNode {
            id: id.into(),
            kind: timeline_core::routing::NodeKind::Bus,
            name: id.into(),
            gain_db: timeline_core::routing::gain_db_default(),
            fx: Vec::new(),
            extra: Default::default(),
        });
    }
    let links = vec![
        (NodeRef::Node("a".into()), NodeRef::Node("b".into())),
        (NodeRef::Node("b".into()), NodeRef::Node("a".into())),
    ];
    let ids: BTreeSet<&str> = BTreeSet::new();
    assert!(r.find_cycle(&ids, &links).is_some());
    let err = r.schedule(&[], &links).expect_err("cyclic links");
    assert!(format!("{err}").contains("not a DAG"), "{err}");
    assert!(
        !format!("{err}").contains("unknown"),
        "the path must be nameable: {err}"
    );
    // ... and the same graph with no links is a perfectly good DAG.
    assert!(r.find_cycle(&ids, &[]).is_none());
    assert!(r.schedule(&[], &[]).is_ok());
}
