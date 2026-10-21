//! End-to-end proof that a lane STRANDED by `device.remove` / `route.node.remove`
//! is reported on `liveRenderError` the moment the strand happens — through the
//! real `StudioHost` command bus, device-free.
//!
//! This is the journal shape the `require_param_ref_on` widening made
//! forward-legal on purpose (apply-time existence checks broke recorded
//! inverses): the removal commands deliberately KEEP the lanes. The render
//! compile is the honest fence — and the host's per-mutation model feed runs
//! the SAME `compile::refuse_unreadable_lanes` sweep, so the fault appears in
//! the report of the very removal command that stranded the lane, not at the
//! next bounce.
//!
//! Closes the residual declared in the first inert-lanes report:
//! "`device.remove` leaves its automation lanes behind… still silently inert."
//!
//! Hops traversed: `StudioHost::submit` -> catalog validation -> apply ->
//! journal -> `sync_after_mutation` -> the model-side lane sweep (offline arm
//! of `push_live_session`) -> `liveRenderError` on the report and snapshot.
//! SKIPPED: a live cpal device (the sweep is deliberately device-free — a
//! check that only ran with a device open could never run in this gate).

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

fn host_with_tone() -> (StudioHost, u64) {
    let tone = tone_fixture();
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("Dangling.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Dangling").unwrap();
    std::mem::forget(tmp);
    host.submit(user(), "track.add", json!({"trackId":"t1","name":"Tone"}))
        .unwrap();
    let outcome = host
        .import_audio(&tone.display().to_string(), "t1", 0, Some("c1".into()))
        .unwrap();
    (host, outcome.length_ticks)
}

/// `device.remove` strands the device's lanes; the report of THAT command
/// carries the fault; undo of the removal clears it; `autolane.clear` is the
/// other way out. Every step through the real bus.
#[test]
fn device_remove_strands_its_lane_and_the_removal_report_says_so() {
    let (mut host, len) = host_with_tone();
    host.submit(
        user(),
        "device.add",
        json!({"trackId":"t1","deviceId":"d1","kind":"synth"}),
    )
    .unwrap();
    for (n, tick, value) in [(0u32, 0u64, 200.0), (1, len, 8000.0)] {
        host.submit(
            user(),
            "autopoint.add",
            json!({"trackId":"t1","target":"track.device.d1.cutoff",
                   "pointId":format!("p{n}"),"positionTicks":tick,"value":value}),
        )
        .unwrap();
    }
    // Healthy while the device exists: no fault, and the project bounces.
    assert!(host.live_render_error().is_none(), "healthy project reports a fault");
    host.render_master().expect("bounces while the device exists");

    // The strand. The command SUCCEEDS (forward-legal by design) and its own
    // report carries the fault.
    let report = host
        .submit(user(), "device.remove", json!({"trackId":"t1","deviceId":"d1"}))
        .expect("device.remove is forward-legal");
    assert_eq!(report["ok"], json!(true));
    let fault = report["liveRenderError"]
        .as_str()
        .unwrap_or_else(|| panic!("device.remove SWALLOWED the strand: {report}"));
    assert!(fault.contains("track.device.d1.cutoff"), "path not named: {fault}");
    assert!(fault.contains("'d1'"), "device id not named: {fault}");
    assert!(fault.contains("t1"), "track not named: {fault}");
    assert!(fault.contains("NOTHING IS LOST"), "recoverability not stated: {fault}");
    assert!(fault.contains("autolane.clear"), "no way forward: {fault}");
    assert!(
        fault.contains("undo the device.remove"),
        "the undo remedy is missing: {fault}"
    );
    // And the bounce refuses with the same story — the fence and the report
    // cannot disagree, they are one function.
    let bounce_err = host.render_master().err().expect("bounce must refuse").to_string();
    assert!(bounce_err.contains("track.device.d1.cutoff"), "{bounce_err}");

    // Way forward 1: undo the removal — the device returns, the fault clears,
    // the bounce works, and the automation is intact (it was never touched).
    host.undo(user()).expect("undo device.remove");
    assert!(
        host.live_render_error().is_none(),
        "undoing the strand must clear the fault"
    );
    host.render_master().expect("bounces again after undo");

    // Way forward 2: redo the strand, then clear the lane as the message says.
    host.redo(user()).expect("redo device.remove");
    assert!(host.live_render_error().is_some(), "the redo re-strands");
    let cleared = host
        .submit(
            user(),
            "autolane.clear",
            json!({"trackId":"t1","target":"track.device.d1.cutoff"}),
        )
        .expect("autolane.clear is the documented escape");
    assert!(
        cleared["liveRenderError"].is_null(),
        "clearing the stranded lane must clear the fault: {cleared}"
    );
    host.render_master().expect("bounces after the clear");
}

/// `route.node.remove` strands a `bus.<id>.gain` lane the same way, and the
/// node-fader bake would otherwise sail past it without a sound.
#[test]
fn route_node_remove_strands_the_bus_gain_lane_and_the_removal_report_says_so() {
    let (mut host, len) = host_with_tone();
    host.submit(
        user(),
        "route.node.add",
        json!({"nodeId":"b1","kind":"bus","name":"Bus 1"}),
    )
    .unwrap();
    for (n, tick, value) in [(0u32, 0u64, -12.0), (1, len, 0.0)] {
        host.submit(
            user(),
            "autopoint.add",
            json!({"trackId":"t1","target":"bus.b1.gain",
                   "pointId":format!("p{n}"),"positionTicks":tick,"value":value}),
        )
        .unwrap();
    }
    assert!(host.live_render_error().is_none(), "healthy project reports a fault");
    host.render_master().expect("bounces while the node exists");

    let report = host
        .submit(user(), "route.node.remove", json!({"nodeId":"b1"}))
        .expect("route.node.remove is forward-legal");
    assert_eq!(report["ok"], json!(true));
    let fault = report["liveRenderError"]
        .as_str()
        .unwrap_or_else(|| panic!("route.node.remove SWALLOWED the strand: {report}"));
    assert!(fault.contains("bus.b1.gain"), "path not named: {fault}");
    assert!(fault.contains("'b1'"), "node id not named: {fault}");
    assert!(fault.contains("t1"), "owning track not named: {fault}");
    assert!(fault.contains("NOTHING IS LOST"), "recoverability not stated: {fault}");
    assert!(fault.contains("autolane.clear"), "no way forward: {fault}");
    assert!(fault.contains("route.node.add"), "the re-create remedy is missing: {fault}");

    // Undo restores the node; the fault clears; the bounce returns.
    host.undo(user()).expect("undo route.node.remove");
    assert!(host.live_render_error().is_none(), "undo must clear the fault");
    host.render_master().expect("bounces again after undo");
}

/// PARITY, the fx half. `device.remove` and `route.node.remove` were already
/// proven to strand their lanes and say so on the removal's own report. The fx
/// and edge halves of the same fence live in their BAKES rather than in
/// `refuse_unreadable_lanes`' sweep, and nothing asserted that a bake's refusal
/// reaches the app the same way. Implemented is not the same as delivered: a
/// refusal the user never sees is the silent degradation this fence exists to
/// prevent, one layer down.
#[test]
fn fx_remove_strands_its_param_lane_and_the_removal_report_says_so() {
    let (mut host, len) = host_with_tone();
    host.submit(
        user(),
        "fx.add",
        json!({"target":"track.t1","fxId":"fx1","kind":"delay"}),
    )
    .expect("fx.add on a track");

    for (n, tick, value) in [(0u32, 0u64, 0.0), (1, len, 1.0)] {
        host.submit(
            user(),
            "autopoint.add",
            json!({"trackId":"t1","target":"track.fx.fx1.feedback",
                   "pointId":format!("f{n}"),"positionTicks":tick,"value":value}),
        )
        .expect("a readable fx param lane is drawable");
    }
    assert!(
        host.live_render_error().is_none(),
        "healthy project reports a fault"
    );
    host.render_master().expect("bounces while the fx exists");

    let report = host
        .submit(user(), "fx.remove", json!({"target":"track.t1","fxId":"fx1"}))
        .expect("fx.remove is forward-legal");
    assert_eq!(report["ok"], json!(true));
    let fault = report["liveRenderError"]
        .as_str()
        .unwrap_or_else(|| panic!("fx.remove SWALLOWED the strand: {report}"));
    assert!(fault.contains("track.fx.fx1.feedback"), "path not named: {fault}");
    assert!(fault.contains("NOTHING IS LOST"), "recoverability not stated: {fault}");
    assert!(fault.contains("autolane.clear"), "no way forward: {fault}");

    host.undo(user()).expect("undo fx.remove");
    assert!(
        host.live_render_error().is_none(),
        "undo must clear the fault"
    );
    host.render_master().expect("bounces again after undo");
}

/// PARITY, the edge half. Same argument as above: `route.disconnect` removes
/// the edge an `route.edge.<id>.level` lane is bound to, and the lane is then
/// bound to nothing. The removal's own report must say so.
#[test]
fn route_disconnect_strands_its_edge_level_lane_and_the_report_says_so() {
    let (mut host, len) = host_with_tone();
    host.submit(
        user(),
        "route.node.add",
        json!({"nodeId":"b1","kind":"bus","name":"Bus 1"}),
    )
    .expect("bus add");
    host.submit(
        user(),
        "route.connect",
        json!({"edgeId":"e1","from":"track.t1","to":"bus.b1",
               "level":1.0,"tap":"post"}),
    )
    .expect("a track-sourced edge");

    for (n, tick, value) in [(0u32, 0u64, 0.0), (1, len, 1.0)] {
        host.submit(
            user(),
            "autopoint.add",
            json!({"trackId":"t1","target":"route.edge.e1.level",
                   "pointId":format!("e{n}"),"positionTicks":tick,"value":value}),
        )
        .expect("a track-sourced edge level lane is drawable");
    }
    assert!(
        host.live_render_error().is_none(),
        "healthy project reports a fault"
    );
    host.render_master().expect("bounces while the edge exists");

    let report = host
        .submit(user(), "route.disconnect", json!({"edgeId":"e1"}))
        .expect("route.disconnect is forward-legal");
    assert_eq!(report["ok"], json!(true));
    let fault = report["liveRenderError"]
        .as_str()
        .unwrap_or_else(|| panic!("route.disconnect SWALLOWED the strand: {report}"));
    assert!(fault.contains("route.edge.e1.level"), "path not named: {fault}");
    assert!(fault.contains("NOTHING IS LOST"), "recoverability not stated: {fault}");
    assert!(fault.contains("autolane.clear"), "no way forward: {fault}");

    host.undo(user()).expect("undo route.disconnect");
    assert!(
        host.live_render_error().is_none(),
        "undo must clear the fault"
    );
    host.render_master().expect("bounces again after undo");
}
