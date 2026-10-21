//! End-to-end proof that `autopoint.add` on `track.send.<a|b>.level` changes
//! the AUDIO — driven through the real `StudioHost` command bus, not by poking
//! `EngineParams`.
//!
//! The shipped defect: the command was journaled, undo restored it, the
//! snapshot carried the points, the lane got a dense slot with a live cursor in
//! `build_lane_index` — and the bounce was **bit-identical to no automation at
//! all**. Every model-state assertion passed the whole time. So does every
//! assertion here compare RENDERED SAMPLES.
//!
//! # Hops this seam traverses (E5 sec 12.5 honesty)
//!
//! `StudioHost::submit` -> catalog schema validation -> `Session::submit` ->
//! `Project::apply_cmd` -> `require_param_ref_on` -> journal envelope + hash
//! chain -> `sync_after_mutation` -> `build_automation` (model lanes ->
//! `AutomationStore`) -> `compile_session_full` -> `build_lane_index` ->
//! `RtSession::send_lane_slots` -> `RenderCommand::SetSession` ->
//! `drain_commands` -> `install_session` -> the one `RenderCore::render`.
//!
//! SKIPPED: the cpal device callback and the real-time deadline. `render_master`
//! is the offline bounce through that same `RenderCore::render`, so nothing here
//! opens a device.
//!
//! Setting `EngineParams` directly would skip `sync_params` and `build_automation`
//! entirely — which is exactly how the solo bug survived — so this file never
//! touches the params struct.

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

/// One track carrying the tone at tick 0. Returns the host and the clip length
/// in ticks, which is the span the ramp is drawn over.
fn host_with_tone() -> (StudioHost, u64) {
    let tone = tone_fixture();
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("SendAuto.mstudio");
    let mut host = StudioHost::create_at(&pkg, "SendAuto").unwrap();
    // The bounce renders from the host's in-memory sources; leak the tempdir
    // handle so nothing races a delete.
    std::mem::forget(tmp);
    host.submit(user(), "track.add", json!({"trackId":"t1","name":"Tone"}))
        .unwrap();
    let outcome = host
        .import_audio(&tone.display().to_string(), "t1", 0, Some("c1".into()))
        .unwrap();
    (host, outcome.length_ticks)
}

fn draw_ramp(host: &mut StudioHost, target: &str, len_ticks: u64, lo: f64, hi: f64) {
    for (n, tick, value) in [(0, 0, lo), (1, len_ticks, hi)] {
        host.submit(
            user(),
            "autopoint.add",
            json!({
                "trackId": "t1",
                "target": target,
                "pointId": format!("p{n}"),
                "positionTicks": tick,
                "value": value,
            }),
        )
        .unwrap_or_else(|e| panic!("autopoint.add {target} @{tick}: {e}"));
    }
}

fn to_bytes(audio: &[[f32; 2]]) -> Vec<u8> {
    audio
        .iter()
        .flat_map(|f| [f[0].to_bits(), f[1].to_bits()])
        .flat_map(u32::to_le_bytes)
        .collect()
}

fn energy(a: &[[f32; 2]], b: &[[f32; 2]], range: std::ops::Range<usize>) -> f64 {
    range
        .map(|i| {
            let dl = f64::from(a[i][0] - b[i][0]);
            let dr = f64::from(a[i][1] - b[i][1]);
            dl * dl + dr * dr
        })
        .sum()
}


/// Last frame at which the dry mix still has signal. The bounce runs past the
/// clip so the reverb tail rings out, and the tail is NOT where a send ramp's
/// growth can be measured — the source has stopped feeding it.
fn last_active_frame(dry: &[[f32; 2]]) -> usize {
    (0..dry.len())
        .rev()
        .find(|&i| dry[i][0].abs() > 1.0e-4 || dry[i][1].abs() > 1.0e-4)
        .expect("the dry reference is silence")
}

/// ⚠️ **This asserts the INVERSE of what the tree did before this fix.** The
/// same gesture used to produce a byte-identical bounce.
#[test]
fn a_send_a_ramp_drawn_through_the_command_bus_is_audible() {
    let (host_dry, _) = host_with_tone();
    let dry = host_dry.render_master().unwrap();

    let (mut host, len) = host_with_tone();
    draw_ramp(&mut host, "track.send.a.level", len, 0.0, 1.0);
    let wet = host.render_master().unwrap();

    assert_eq!(dry.len(), wet.len(), "the bounce length changed");
    assert_ne!(
        to_bytes(&dry),
        to_bytes(&wet),
        "a 0->1 send ramp submitted through the real command bus produced a \
         BYTE-IDENTICAL bounce: send automation is inert"
    );

    // Non-vacuity + SHAPE. "Not identical" is satisfied by a constant offset,
    // which is not a ramp. Split the region where the source is still playing
    // into sixths and require the send's contribution to GROW across every one
    // of them. Measured only up to `last_active_frame`: past the clip the dry
    // has stopped and the reverb is decaying, so energy legitimately falls
    // there — an early-vs-late comparison over the whole bounce reads that
    // decay as a failure.
    let active = last_active_frame(&dry);
    let sixths: Vec<f64> = (0..6)
        .map(|k| energy(&dry, &wet, active * k / 6..active * (k + 1) / 6))
        .collect();
    for k in 1..6 {
        assert!(
            sixths[k] > sixths[k - 1] * 1.3,
            "the send contribution did not grow across the ramp: {sixths:?}"
        );
    }
    assert!(
        sixths[5] > sixths[0] * 20.0,
        "the send ramp barely moved end to end: {sixths:?}"
    );
}

#[test]
fn a_send_b_ramp_drawn_through_the_command_bus_is_audible() {
    let (host_dry, _) = host_with_tone();
    let dry = host_dry.render_master().unwrap();

    let (mut host, len) = host_with_tone();
    draw_ramp(&mut host, "track.send.b.level", len, 0.0, 1.0);
    let wet = host.render_master().unwrap();

    assert_ne!(
        to_bytes(&dry),
        to_bytes(&wet),
        "bus B send automation is inert through the host path"
    );
}

/// The drawn lane beats the `mix.send` fader, through the host's own sync path.
/// This is the half `EngineParams`-poking tests cannot see: it proves
/// `build_automation` and `sync_params` agree about which value wins.
#[test]
fn a_drawn_send_lane_overrides_the_mix_send_fader() {
    // Fader alone at 0.9.
    let (mut hot, _) = host_with_tone();
    hot.submit(user(), "mix.send", json!({"trackId":"t1","bus":"a","amount":0.9}))
        .unwrap();
    let fader_hot = hot.render_master().unwrap();

    // Fader alone at 0.1.
    let (mut quiet, _) = host_with_tone();
    quiet
        .submit(user(), "mix.send", json!({"trackId":"t1","bus":"a","amount":0.1}))
        .unwrap();
    let fader_quiet = quiet.render_master().unwrap();

    // Fader at 0.9, lane pinned at 0.1. The lane must win.
    let (mut both, len) = host_with_tone();
    both.submit(user(), "mix.send", json!({"trackId":"t1","bus":"a","amount":0.9}))
        .unwrap();
    draw_ramp(&mut both, "track.send.a.level", len, 0.1, 0.1);
    let overridden = both.render_master().unwrap();

    let n = overridden.len();
    // Past the 5 ms declick glide from the fader's value to the lane's.
    let window = 4_800..n;
    let to_quiet = energy(&overridden, &fader_quiet, window.clone());
    let to_hot = energy(&overridden, &fader_hot, window);
    assert!(
        to_hot > to_quiet * 100.0,
        "a lane pinned at 0.1 did not override the fader at 0.9 \
         (distance to the 0.1 render {to_quiet:.9}, to the 0.9 render {to_hot:.9})"
    );
}

/// A project that draws no send automation must bounce EXACTLY as before,
/// through the same host path — including with both sends, mute, solo, EQ and
/// volume/pan automation live.
#[test]
fn a_project_without_send_automation_bounces_unchanged() {
    let (mut host, len) = host_with_tone();
    host.submit(user(), "track.add", json!({"trackId":"t2","name":"Two"}))
        .unwrap();
    let tone = tone_fixture();
    host.import_audio(&tone.display().to_string(), "t2", 0, Some("c2".into()))
        .unwrap();
    for (t, a, b) in [("t1", 0.4, 0.3), ("t2", 0.2, 0.6)] {
        host.submit(user(), "mix.send", json!({"trackId":t,"bus":"a","amount":a}))
            .unwrap();
        host.submit(user(), "mix.send", json!({"trackId":t,"bus":"b","amount":b}))
            .unwrap();
        host.submit(
            user(),
            "mix.eq",
            json!({"trackId":t,"band":2,"freqHz":2500,"gainDb":-5,"q":0.9}),
        )
        .unwrap();
    }
    host.submit(user(), "mix.master.gain", json!({"gainDb": -1}))
        .unwrap();
    host.submit(
        user(),
        "mix.limiter.set",
        json!({"enabled":true,"ceilingDb":-1,"releaseMs":50}),
    )
    .unwrap();
    draw_ramp(&mut host, "track.volume", len, -12.0, 0.0);

    let a = host.render_master().unwrap();
    let b = host.render_master().unwrap();
    assert_eq!(
        to_bytes(&a),
        to_bytes(&b),
        "the bounce is not deterministic, so nothing downstream can be pinned"
    );
    let peak = a
        .iter()
        .flat_map(|f| [f[0].abs(), f[1].abs()])
        .fold(0.0_f32, f32::max);
    assert!(peak > 0.01, "the reference bounce is silence (peak {peak})");
    // (Cross-branch bit-identity against feat/ms-342 is asserted out of band by
    // rendering this same project on both branches — see the lane report.)
}

/// A lane this build cannot render is REFUSED, by name and with a reason, when
/// the render is asked for — not silently dropped on the floor.
///
/// The refusal is at COMPILE, not at the command: `Session::resume` replays
/// through `Project::apply_cmd`, so narrowing `autopoint.add` would make a
/// project that already journaled such a lane fail to OPEN. The command still
/// succeeds and the points still persist; only the render says no.
#[test]
fn a_lane_this_build_cannot_render_is_refused_at_bounce_not_ignored() {
    for (target, lo, hi, why) in [
        ("track.eq.1.gain", 0.0, 12.0, "per FRAME"),
        ("master.gain", -24.0, 0.0, "GLOBAL"),
        ("master.limiter.ceiling", -6.0, 0.0, "GLOBAL"),
    ] {
        let (mut host, len) = host_with_tone();
        draw_ramp(&mut host, target, len, lo, hi);
        // The COMMAND is still accepted and the points are still in the model:
        // replay and load->save must keep working.
        assert!(
            host.project().track("t1").is_some(),
            "{target}: the command path broke"
        );
        let err = host
            .render_master()
            .err()
            .unwrap_or_else(|| panic!("{target}: bounced fine, so the lane is silently INERT"))
            .to_string();
        assert!(err.contains(target), "{target}: refusal does not name it: {err}");
        assert!(err.contains(why), "{target}: refusal does not say why: {err}");
    }
}

// ---------------------------------------------------------------------------
// A refusal that nobody can see is just a quieter version of the same bug.
// ---------------------------------------------------------------------------

/// ⚠️ **The regression this fix was held for.**
///
/// `push_live_session` used to be `if let Ok(session) = … { }` with **no else
/// branch**. So once `build_lane_index` started refusing unreadable lanes, a
/// user who drew one got: command `ok: true`, model updated, undo armed — and
/// the audio thread silently kept rendering the PREVIOUS session. Edit, hear
/// nothing change, no error anywhere. That trades a quiet wrong answer for a
/// quiet DEAD one, which is worse.
///
/// This asserts the failure is observable on the two surfaces a human reads:
/// the report of the very command that caused it, and the snapshot the app
/// polls. It does not assert that `compile` returns `Err` — that layer already
/// worked; the swallow was the defect.
///
/// Device-free on purpose: the check runs through
/// `compile::refuse_unreadable_lanes`, the SAME function `build_lane_index`
/// calls, which needs no live engine. A test that only ran with
/// `MAJIKS_TEST_LIVE=1` would never run in the gate, and a gate that cannot see
/// this bug is how it shipped.
#[test]
fn a_refused_lane_is_reported_on_the_command_and_the_snapshot_not_swallowed() {
    for (target, lo, hi) in [
        ("track.eq.1.gain", 0.0, 12.0),
        ("master.gain", -24.0, 0.0),
        ("bus.nope.gain", -24.0, 0.0),
    ] {
        let (mut host, len) = host_with_tone();

        // Clean before.
        assert!(
            host.live_render_error().is_none(),
            "{target}: a fault was reported before anything was drawn"
        );
        let clean = host.snapshot(None);
        assert!(
            clean["liveRenderError"].is_null(),
            "{target}: snapshot reports a fault on a healthy project"
        );

        // Draw the lane through the real bus. `bus.nope.gain` names no routing
        // node, so it is rejected at the COMMAND; the other two are accepted as
        // commands and refused at render. Both must end up visible.
        let first = host.submit(
            user(),
            "autopoint.add",
            json!({"trackId":"t1","target":target,"pointId":"p0",
                   "positionTicks":0,"value":lo}),
        );
        if first.is_err() {
            // Rejected at the command boundary — already loud. Nothing to
            // report, and nothing silently broken.
            assert!(
                host.live_render_error().is_none(),
                "{target}: rejected at the command yet left a fault behind"
            );
            continue;
        }
        let report = host
            .submit(
                user(),
                "autopoint.add",
                json!({"trackId":"t1","target":target,"pointId":"p1",
                       "positionTicks":len,"value":hi}),
            )
            .unwrap_or_else(|e| panic!("{target}: {e}"));

        // 1. The command still SUCCEEDED — it is applied, journaled, undoable.
        //    Claiming otherwise would be a second lie, since the edit landed.
        assert_eq!(report["ok"], json!(true), "{target}: the command should still succeed");
        assert_eq!(report["journaled"], json!(true), "{target}: should still journal");

        // 2. …and the same report says live rendering is broken, naming the
        //    path, the track, and the way out.
        let on_report = report["liveRenderError"]
            .as_str()
            .unwrap_or_else(|| panic!("{target}: command report SWALLOWED the fault: {report}"));
        assert!(on_report.contains(target), "{target}: not named: {on_report}");
        assert!(on_report.contains("t1"), "{target}: track not named: {on_report}");
        assert!(
            on_report.contains("autolane.clear"),
            "{target}: no way forward offered: {on_report}"
        );
        assert!(
            on_report.contains("NOTHING IS LOST"),
            "{target}: does not say the data is recoverable: {on_report}"
        );

        // 3. The snapshot the app polls carries it too, so a UI that never
        //    inspects a command report can still show a banner.
        let snap = host.snapshot(None);
        assert_eq!(
            snap["liveRenderError"].as_str(),
            Some(on_report),
            "{target}: snapshot does not carry the fault"
        );

        // 4. It rides the `unchanged` early-return path as well — that is
        //    exactly when the user has stopped editing and started listening.
        let seq = snap["seq"].as_u64().unwrap();
        let quiet = host.snapshot(Some(seq));
        assert_eq!(quiet["unchanged"], json!(true), "{target}: expected an unchanged delta");
        assert!(
            quiet["liveRenderError"].as_str().is_some(),
            "{target}: the fault vanishes on an unchanged snapshot: {quiet}"
        );
    }
}

/// The way FORWARD works, end to end: clear the lane and the project renders
/// again — and undo brings the points back. A refusal the user cannot escape
/// would be a dead end dressed up as an error message.
#[test]
fn clearing_a_refused_lane_restores_rendering_and_undo_restores_the_points() {
    let (mut host, len) = host_with_tone();
    let healthy = host.render_master().unwrap();

    draw_ramp(&mut host, "track.eq.1.gain", len, 0.0, 12.0);
    assert!(host.render_master().is_err(), "the refused lane should block the bounce");
    assert!(host.live_render_error().is_some(), "and be reported");

    // The way out, exactly as the message spells it.
    let cleared = host
        .submit(
            user(),
            "autolane.clear",
            json!({"trackId": "t1", "target": "track.eq.1.gain"}),
        )
        .expect("autolane.clear is the documented escape and must work");
    assert!(
        cleared["liveRenderError"].is_null(),
        "the fault should clear the moment the lane does: {cleared}"
    );
    assert!(host.live_render_error().is_none());

    // Rendering works again, and is bit-identical to before the lane existed —
    // the refused lane never touched the audio, so removing it cannot either.
    let recovered = host.render_master().expect("bounce works again");
    assert_eq!(
        to_bytes(&healthy),
        to_bytes(&recovered),
        "clearing the refused lane changed the audio, so it was not inert after all"
    );

    // NOTHING IS LOST: undo brings the points back (and the refusal with them).
    host.undo(user()).expect("undo");
    assert!(
        host.live_render_error().is_some(),
        "undo restored the lane, so the refusal must come back"
    );
    let points = host
        .project()
        .track("t1")
        .unwrap()
        .automation
        .iter_lanes()
        .into_iter()
        .find(|(p, _)| p.as_str() == "track.eq.1.gain")
        .map(|(_, pts)| pts.len())
        .unwrap_or(0);
    assert_eq!(points, 2, "undo did not restore every point");
}
