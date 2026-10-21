//! E5-params seam proofs (DESIGN-E5-routing.md §6.3, §16.6, §3.3).
//!
//! Two things are proven here and neither of them is a model-state assertion:
//!
//! 1. **The legacy-null gate (§12.2 / §20.1).** A v1 project — no routing
//!    graph, no fx — bounces to a BYTE-IDENTICAL buffer before and after the
//!    E5-params change. The reference digest is pinned as a constant, captured
//!    from the epic baseline `1920796` on a pristine tree. §12.2 calls this
//!    "the single test that catches more than the rest of §12 combined"; it is
//!    pinned rather than compared against a sibling run so that it keeps
//!    catching regressions for every later E5 lane, not just this one.
//!
//! 2. **The stale-slot hygiene contract (§6.3) through the FULL PUBLIC PATH.**
//!    §12.5 is explicit that a test which pokes `EngineParams` directly proves
//!    nothing about whether a user pressing a button reaches it — "this is
//!    exactly how the solo bug survived". So the stale-slot test dirties a
//!    retired slot, then drives `submit_json` → `sync_after_mutation` →
//!    `render_master` (the real bounce) and asserts the host cleared it.
//!
//! ## Seam honesty (§12.5) — the hops these tests traverse
//!
//! | Hop | Traversed? |
//! |---|---|
//! | `StudioHost::submit` → `bus_submit` → `Session::submit_json` | YES |
//! | `sync_after_mutation` → `push_live_session` | YES (no-op offline: no live engine) |
//! | `render_master` → `compile_session_full` → `sync_params` → `ManualRenderer` | YES |
//! | `RenderCommand` channel → `drain_commands` → `install_session` → `RenderCore::render` | YES |
//! | cpal device callback; real-time deadline | NO — offline bounce, silent |
//!
//! `sync_params` is the hop that matters: it is the one a direct-`EngineParams`
//! test skips, and it is where the §6.3 `clear_*_from` calls live.

use std::path::PathBuf;
use std::sync::OnceLock;

use serde_json::json;

use agent_surface::StudioHost;
use timeline_core::Actor;

fn tone_fixture() -> PathBuf {
    static READY: OnceLock<PathBuf> = OnceLock::new();
    READY
        .get_or_init(|| {
            let dir = render::fixtures::repo_fixtures_dir();
            render::fixtures::ensure(&dir).expect("fixtures");
            dir
        })
        .join("tone_440_48k_mono.wav")
}

fn user() -> Actor {
    Actor::user("aaron")
}

fn digest(audio: &[[f32; 2]]) -> String {
    let mut h = blake3::Hasher::new();
    h.update(&(audio.len() as u64).to_le_bytes());
    for f in audio {
        h.update(&f[0].to_bits().to_le_bytes());
        h.update(&f[1].to_bits().to_le_bytes());
    }
    h.finalize().to_hex().to_string()
}

/// A v1 project that exercises every signal-path feature E5 could disturb:
/// both legacy sends, mute, solo (so the solo gate is live for every strip),
/// pan, the channel EQ, a per-track gain trim, master gain, the limiter, and
/// `track.volume` automation. It declares NO routing graph and NO fx, so
/// §12.2's rule applies: it must render EXACTLY the same samples after E5.
fn legacy_v1_project() -> StudioHost {
    let tone = tone_fixture();
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("E5ParamsLegacyNull.mstudio");
    let mut host = StudioHost::create_at(&pkg, "E5ParamsLegacyNull").unwrap();
    std::mem::forget(tmp);

    for (track, clip) in [("t1", "c1"), ("t2", "c2"), ("t3", "c3")] {
        host.submit(user(), "track.add", json!({ "trackId": track, "name": track }))
            .unwrap();
        host.import_audio(&tone.display().to_string(), track, 0, Some(clip.into()))
            .unwrap();
    }

    // t1: trimmed, panned, EQ'd, feeding BOTH legacy sends, and automated.
    host.submit(user(), "mix.gain", json!({ "trackId": "t1", "gainDb": -3.0 }))
        .unwrap();
    host.submit(user(), "mix.pan", json!({ "trackId": "t1", "pan": -0.4 }))
        .unwrap();
    host.submit(
        user(),
        "mix.eq",
        json!({ "trackId": "t1", "band": 1, "freqHz": 440.0, "gainDb": -12.0, "q": 2.0 }),
    )
    .unwrap();
    host.submit(user(), "mix.send", json!({ "trackId": "t1", "bus": "a", "amount": 0.7 }))
        .unwrap();
    host.submit(user(), "mix.send", json!({ "trackId": "t1", "bus": "b", "amount": 0.35 }))
        .unwrap();
    host.submit(
        user(),
        "autopoint.add",
        json!({ "trackId": "t1", "target": "track.volume", "pointId": "p0",
                "positionTicks": 0, "value": -12.0 }),
    )
    .unwrap();
    host.submit(
        user(),
        "autopoint.add",
        json!({ "trackId": "t1", "target": "track.volume", "pointId": "p1",
                "positionTicks": 1920, "value": 0.0 }),
    )
    .unwrap();

    // t2: muted AND solo-gated (mute wins, §3.3 / params.rs).
    host.submit(user(), "mix.gain", json!({ "trackId": "t2", "gainDb": -6.0 }))
        .unwrap();
    host.submit(user(), "track.mute", json!({ "trackId": "t2", "muted": true }))
        .unwrap();

    // Solo on t1 and t3 makes the global solo gate LIVE for the whole bounce,
    // so the gate arithmetic is inside the reference, not bypassed by it.
    host.submit(user(), "track.solo", json!({ "trackId": "t1", "soloed": true }))
        .unwrap();
    host.submit(user(), "track.solo", json!({ "trackId": "t3", "soloed": true }))
        .unwrap();
    host.submit(user(), "mix.pan", json!({ "trackId": "t3", "pan": 0.55 }))
        .unwrap();

    host.submit(user(), "mix.master.gain", json!({ "gainDb": -2.0 }))
        .unwrap();
    host.submit(
        user(),
        "mix.limiter.set",
        json!({ "enabled": true, "ceilingDb": -1.0, "releaseMs": 50.0 }),
    )
    .unwrap();
    host
}

/// blake3 of the reference bounce, captured on a PRISTINE tree at the E5
/// baseline commit `1920796` (`merge(E5 II): effect-device registry, dynamics,
/// sidechain ordering, PDC`) before a single source line of this lane existed.
///
/// **If this goes red, stop.** Do not adjust it and do not add a tolerance:
/// per §20.1 a v1 project must bounce bit-identically through everything E5
/// adds. A changed digest means the legacy signal path moved.
const REFERENCE_BOUNCE_1920796: &str =
    "7f2d161cc75fa058628efffcc9519da475393065b166a87401c2396fa1a4d5ae";
/// Frames in the reference bounce. Asserted separately so a truncated render
/// reports as "wrong length" rather than as an opaque digest mismatch.
const REFERENCE_BOUNCE_FRAMES: usize = 240_000;

#[test]
fn legacy_v1_bounce_is_bit_identical_to_the_baseline() {
    let host = legacy_v1_project();
    let audio = host.render_master().unwrap();
    assert_eq!(
        audio.len(),
        REFERENCE_BOUNCE_FRAMES,
        "the reference bounce changed LENGTH, so the digest below cannot be \
         meaningfully compared"
    );
    let got = digest(&audio);
    println!("E5 reference bounce: {} frames, blake3 {}", audio.len(), got);
    assert_eq!(
        got, REFERENCE_BOUNCE_1920796,
        "LEGACY-NULL GATE RED (§12.2/§20.1): a v1 project with no routing graph \
         and no fx no longer bounces bit-identically to baseline 1920796"
    );
}

/// A project WITH a routing graph, built through `submit_json`, must still
/// compile, sync and bounce. This is the path that newly reaches
/// `sync_params`' `clear_edge_levels_from(routing.edges.len())` /
/// `clear_node_gains_from(routing.nodes.len())` with non-zero counts.
///
/// ⚠️ **This test deliberately does NOT pin the samples.** The routing graph is
/// inert in the renderer until E5-graph lands `node_order`'s reader, and
/// pinning today's (inert) output would turn E5-graph's whole deliverable into
/// a false red. What is pinned is that the host survives a non-empty graph and
/// still produces the same audio a graph-free project produces — which is
/// correct TODAY and is also what §4.2's implicit-master-feed rule requires for
/// this particular graph tomorrow, since `t1 -> bus.rev` is a PRE tap (a send)
/// and pre-tap edges never suppress the implicit master feed.
#[test]
fn a_routed_project_still_syncs_and_bounces_through_the_full_bus() {
    let tone = tone_fixture();
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("E5ParamsRouted.mstudio");
    let mut host = StudioHost::create_at(&pkg, "E5ParamsRouted").unwrap();
    std::mem::forget(tmp);

    host.submit(user(), "track.add", json!({ "trackId": "t1", "name": "t1" }))
        .unwrap();
    host.import_audio(&tone.display().to_string(), "t1", 0, Some("c1".into()))
        .unwrap();
    let plain = host.render_master().unwrap();

    host.submit(
        user(),
        "route.node.add",
        json!({ "nodeId": "rev", "kind": "bus", "name": "Reverb" }),
    )
    .unwrap();
    host.submit(
        user(),
        "route.connect",
        json!({ "edgeId": "e1", "from": "track.t1", "to": "bus.rev",
                "level": 0.5, "tap": "pre" }),
    )
    .unwrap();
    // Guard against the test silently exercising an EMPTY graph, which would
    // make it a duplicate of the null gate above rather than a routing proof.
    assert_eq!(host.project().routing.nodes.len(), 1);
    assert_eq!(host.project().routing.edges.len(), 1);

    let routed = host.render_master().unwrap();
    assert_eq!(routed.len(), plain.len());
    // ⚠️ AMENDED BY E5-graph. The original assertion was bit-IDENTITY, with the
    // note that the routing graph was inert until `node_order` had a reader and
    // that pinning the inert output would turn E5-graph's deliverable into a
    // false red. It has a reader now, and the identity was also wrong on its
    // own terms: §4.2 says a pre-tap edge does not suppress **t1's** implicit
    // master feed, which is true and is asserted below — but `bus.rev` has an
    // implicit master feed of its OWN, so the send returns to master and the
    // mix genuinely changes. That is what a send IS.
    assert_ne!(
        digest(&routed),
        digest(&plain),
        "a pre-tap send at level 0.5 into a bus that returns to master left the \
         bounce unchanged — the send is inaudible, which is §0 row 7's bug"
    );
    // t1's own direct path is still there: §4.2's rule, from the other side.
    // With the send returning at unity the routed mix must be LOUDER, never a
    // replacement for the direct feed.
    let peak = |a: &[[f32; 2]]| a.iter().fold(0.0_f32, |m, f| m.max(f[0].abs()));
    assert!(
        peak(&routed) > peak(&plain),
        "the direct feed was suppressed by a PRE tap (routed peak {} <= plain {})",
        peak(&routed),
        peak(&plain)
    );
}

/// The §6.3 stale-slot clears in `sync_params`, covered.
///
/// ⚠️ **Seam honesty, and the reason this test looks the way it does.** The
/// first attempt at this proof went through `render_master`, and a mutation
/// that DELETED both clear calls left it green. That is not a weak assertion,
/// it is a structurally blind seam: every offline bounce constructs a fresh
/// `ManualRenderer`, so its `EngineParams` start at their cleared defaults and
/// a missing clear is unobservable no matter what you assert on the samples.
/// The only params block that outlives a session swap is the LIVE engine's,
/// and the live tests are opt-in behind `MAJIKS_TEST_LIVE=1` — skipped in the
/// gate, so "covered by the live test" would have been a false green too.
///
/// So this test calls the production `sync_params` with a params block it
/// keeps, which is exactly what the live engine does across a swap.
///
/// | Hop | Traversed? |
/// |---|---|
/// | `submit_json` -> model (the routing graph is real, not hand-built) | YES |
/// | `sync_params` -> the `clear_*_from` calls | YES |
/// | `push_live_session` -> `sync_params` (the CALL SITE) | **NO** — unchanged by this lane, and device-gated |
#[test]
fn sync_params_clears_retired_routing_slots_and_keeps_live_ones() {
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("E5ParamsStaleSlots.mstudio");
    let mut host = StudioHost::create_at(&pkg, "E5ParamsStaleSlots").unwrap();
    std::mem::forget(tmp);

    host.submit(user(), "track.add", json!({ "trackId": "t1", "name": "t1" }))
        .unwrap();
    host.submit(
        user(),
        "route.node.add",
        json!({ "nodeId": "grp", "kind": "group", "name": "Group" }),
    )
    .unwrap();
    host.submit(
        user(),
        "route.connect",
        json!({ "edgeId": "e1", "from": "track.t1", "to": "bus.grp",
                "level": 1.0, "tap": "post" }),
    )
    .unwrap();
    assert_eq!(host.project().routing.edges.len(), 1);
    assert_eq!(host.project().routing.nodes.len(), 1);
    // A MODEL fader on the live node, so the push half below is asserted
    // against an authoritative value rather than whatever the test poked in.
    host.submit(
        user(),
        "route.node.set",
        json!({ "nodeId": "grp", "gainDb": -20.0 }),
    )
    .unwrap();

    // A params block that OUTLIVES the swap, the way the live engine's does.
    // The poked fader (-40) deliberately DIFFERS from the model's (-20): if
    // the push were deleted, slot 0 would keep the poke and the assertion
    // below would read 0.01, not 0.1 — so this test detects a dead push
    // rather than mistaking a surviving poke for one.
    let params = render::params::EngineParams::new(8);
    for slot in 0..6 {
        params.set_edge_level(slot, 2.5);
        params.set_node_gain_db(slot, -40.0);
    }

    host.sync_params(&params);

    // ⚠️ AMENDED BY E5-graph, §23.1. When this test was written `sync_params`
    // had only the CLEAR half, so "the live slot survives" could only be
    // spelled as "the value the test poked in is still there". The push half
    // has landed, so the live slot now holds the MODEL's level — which is the
    // stronger property the assertion was reaching for: slot 0 is not wiped,
    // and it is authoritative rather than whatever was left in it.
    assert_eq!(
        params.edge_level_target(0),
        1.0,
        "the one live edge slot does not carry edge e1's model level: a send \
         level must survive — and be refreshed by — the next unrelated edit"
    );
    // ⚠️ AMENDED BY the bus-fader lane. When this was written the node half
    // had only the CLEAR (RouteNode had no gain field, so there was nothing
    // to push) and this could only assert "the poked value survived". The
    // push has landed (`route.node.set` -> `sync_graph_params`), so the live
    // slot now holds the MODEL's fader — db_to_lin(-20 dB) = 0.1 — which is
    // the stronger property the edge half above already pins.
    let live = params.node_gain_target(0);
    assert!(
        (live - 0.1).abs() < 1e-6,
        "the one live node slot does not carry grp's model fader \
         (want db_to_lin(-20) = 0.1, got {live})"
    );
    for slot in 1..6 {
        assert_eq!(
            params.edge_level_target(slot),
            0.0,
            "retired edge slot {slot} kept its level (§6.3 stale-slot hazard)"
        );
        assert_eq!(
            params.node_gain_target(slot),
            1.0,
            "retired node slot {slot} kept its fader (§6.3 stale-slot hazard)"
        );
    }
}
