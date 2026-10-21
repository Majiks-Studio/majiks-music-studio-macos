//! THE HOST HALF OF THE METRONOME.
//!
//! `render/tests/metronome.rs` proves the click generator: given a grid in
//! `EngineParams`, the render core clicks on every beat. It sets those params
//! by hand. NOTHING proved that the HOST puts the right thing in them — and
//! that is the half a user actually drives, because the only way to switch the
//! click on in the app is `transport.metronome` on the command bus.
//!
//! The gap that leaves is exactly the gap the metronome keeps falling into:
//! the flag round-trips (the button lights up, the snapshot carries
//! `metronomeEnabled: true`), the render core is provably capable of clicking,
//! and the two are never shown to be connected. A grid pushed with the wrong
//! tempo, a level pushed at zero, or an enable that never reaches the params
//! all leave both existing suites green and the room silent.
//!
//! So every assertion here drives the REAL `StudioHost` bus and then measures
//! RENDERED SAMPLES through `sync_params` — the same function
//! `push_live_session` calls on the live engine's params block.
//!
//! Silent: no device is opened. `ManualRenderer::new_monitoring` is the live
//! core's `monitor: true` without the hardware.

use serde_json::json;

use agent_surface::StudioHost;
use render::engine::EngineConfig;
use render::offline::{render_offline_with, ManualRenderer, ScheduledCommand};
use render::rt::RenderCommand;
use timeline_core::Actor;

const RATE: u32 = 48_000;

fn user() -> Actor {
    Actor::user("aaron")
}

fn cfg() -> EngineConfig {
    EngineConfig {
        sample_rate: RATE,
        max_tracks: 8,
        ..EngineConfig::default()
    }
}

/// See `render/tests/metronome.rs` — same separator, same reasoning.
const SILENCE_GAP_FRAMES: usize = 1_000;

fn click_onsets(audio: &[[f32; 2]]) -> Vec<usize> {
    let mut onsets = Vec::new();
    let mut zeros = SILENCE_GAP_FRAMES;
    for (i, f) in audio.iter().enumerate() {
        if f[0] == 0.0 && f[1] == 0.0 {
            zeros += 1;
        } else {
            if zeros >= SILENCE_GAP_FRAMES {
                onsets.push(i);
            }
            zeros = 0;
        }
    }
    onsets
}

/// A host with the shape of the app's default project: one track carrying a
/// synth. The tempo (120) and time signature (4/4) are the project defaults,
/// which is what `sync_metronome_params` reads.
fn host_with_a_track() -> StudioHost {
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("MetronomeHost.mstudio");
    let mut host = StudioHost::create_at(&pkg, "MetronomeHost").unwrap();
    std::mem::forget(tmp);
    host.submit(
        user(),
        "track.add",
        json!({ "trackId": "t1", "name": "Instrument 1" }),
    )
    .unwrap();
    host.submit(
        user(),
        "device.add",
        json!({ "trackId": "t1", "deviceId": "inst1", "kind": "synth" }),
    )
    .unwrap();
    host
}

/// Render four seconds through a monitoring core whose params the HOST filled.
fn render_through_host(host: &StudioHost) -> Vec<[f32; 2]> {
    let c = cfg();
    let mut r = ManualRenderer::new_monitoring(&c);
    // The production push: `push_live_session` calls exactly this on the live
    // engine's params, and it is what carries the metronome grid + enable.
    host.sync_params(r.params());
    render_offline_with(
        &mut r,
        vec![ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::Play,
        }],
        4 * u64::from(RATE),
        512,
    )
}

/// THE ONE THAT MATTERS: `transport.metronome` on the bus makes a steady click.
///
/// Not "the flag is true" — eight clicks, a beat apart, in the buffer.
#[test]
fn the_bus_command_produces_a_steady_audible_click() {
    let mut host = host_with_a_track();
    host.submit(user(), "transport.metronome", json!({ "enabled": true }))
        .expect("transport.metronome");

    let audio = render_through_host(&host);
    let onsets = click_onsets(&audio);
    assert_eq!(
        onsets.len(),
        8,
        "transport.metronome must give two clicks a second at the project's 120 BPM; \
         got {} at {onsets:?}",
        onsets.len()
    );
    for pair in onsets.windows(2) {
        assert_eq!(
            pair[1] - pair[0],
            24_000,
            "the host pushed a grid that is not the project's tempo: {pair:?}"
        );
    }
}

/// And switching it back off is silence — so the command is the thing that
/// controls the click, not merely something that happens to precede it.
#[test]
fn switching_the_click_off_again_is_silence() {
    let mut host = host_with_a_track();
    host.submit(user(), "transport.metronome", json!({ "enabled": true }))
        .expect("on");
    assert_eq!(click_onsets(&render_through_host(&host)).len(), 8, "on");

    host.submit(user(), "transport.metronome", json!({ "enabled": false }))
        .expect("off");
    let audio = render_through_host(&host);
    assert!(
        click_onsets(&audio).is_empty(),
        "the click kept sounding after transport.metronome{{enabled:false}}"
    );
}

/// The grid the host pushes is the PROJECT'S tempo, not a hardcoded 120.
///
/// This is the assertion that fails if `sync_metronome_params` ever loses the
/// tempo lookup: at 92 BPM the beat is 31 304.35 frames, so a click that is
/// still 24 000 apart is a click on the wrong grid — audibly wrong against the
/// music, and invisible to any test that only counts onsets.
#[test]
fn the_pushed_grid_follows_the_projects_tempo() {
    let mut host = host_with_a_track();
    host.submit(user(), "project.setTempo", json!({ "bpm": 92 }))
        .expect("project.setTempo");
    host.submit(user(), "transport.metronome", json!({ "enabled": true }))
        .expect("transport.metronome");

    let audio = render_through_host(&host);
    let onsets = click_onsets(&audio);
    assert!(
        onsets.len() >= 6,
        "92 BPM for 4 s is at least six clicks, got {} at {onsets:?}",
        onsets.len()
    );
    // Beat n of the model's grid: ticks * rate * 60 / (PPQ * bpm), round-half-up.
    for (beat, onset) in onsets.iter().enumerate() {
        let tick = beat as u128 * u128::from(render::dsp::click::PPQ);
        let n = tick * u128::from(RATE) * 60;
        let d = u128::from(render::dsp::click::PPQ) * 92;
        let want = ((n + d / 2) / d) as usize + 1;
        assert_eq!(
            *onset, want,
            "click {beat} at {onset}: the host pushed a grid that is not 92 BPM"
        );
    }
}

// ---------------------------------------------------------------------------
// THE CLICK, OBSERVABLE FROM THE HOST
//
// The tests above measure samples, which no one in the running app can do. The
// click is kept out of the master bus, the meters and the capture tap on
// purpose, so the app had NO signal for it: a user reporting "one chirp and
// then silence" could not be answered without someone listening. These pin the
// signal that closes that gap — the counter on the host-driven path, and the
// field name the app reads it by.
// ---------------------------------------------------------------------------

/// Render four seconds through host-filled params, and report what the engine
/// counted alongside what it produced.
fn render_and_count(host: &StudioHost) -> (Vec<[f32; 2]>, u64) {
    use std::sync::atomic::Ordering;

    let c = cfg();
    let mut r = ManualRenderer::new_monitoring(&c);
    host.sync_params(r.params());
    let audio = render_offline_with(
        &mut r,
        vec![ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::Play,
        }],
        4 * u64::from(RATE),
        512,
    );
    let counted = r.stats().metronome_clicks.load(Ordering::Relaxed);
    (audio, counted)
}

/// The counter agrees with the audio ON THE PATH THE BUTTON DRIVES.
///
/// `render/tests/metronome.rs` proves the counter matches hand-set params.
/// This proves it matches params the HOST filled from a `transport.metronome`
/// command — which is the only reading that licenses telling the owner "if the
/// number is climbing, the click is being made".
#[test]
fn the_click_counter_agrees_with_the_bus_driven_click() {
    let mut host = host_with_a_track();
    host.submit(user(), "transport.metronome", json!({ "enabled": true }))
        .expect("transport.metronome");

    let (audio, counted) = render_and_count(&host);
    let onsets = click_onsets(&audio);
    assert_eq!(onsets.len(), 8, "precondition: eight clicks in four seconds");
    assert_eq!(
        counted, 8,
        "the bus switched the click on and eight clicks sounded, but the engine \
         counted {counted} — the counter cannot be trusted to answer 'is it clicking?'"
    );

    host.submit(user(), "transport.metronome", json!({ "enabled": false }))
        .expect("off");
    let (audio, counted) = render_and_count(&host);
    assert!(click_onsets(&audio).is_empty(), "precondition: silence");
    assert_eq!(
        counted, 0,
        "the counter moved on a fresh core with the click switched off"
    );
}

/// THE FIELD NAME THE APP READS, carrying a REAL count.
///
/// `engine_stats_json` is the exact mapping `engine_stats()` uses for the
/// render thread's stats, and `RealStudioEngine` reads `metronomeClicks` out
/// of it by that string. Fed here from a core that genuinely clicked eight
/// times, so a renamed key, a dropped key, or a snapshot that forgets to copy
/// the atomic all fail — none of which a "the key exists and is 0" assertion
/// could see.
///
/// Device-free: the count comes from `ManualRenderer`, and the four fields
/// that need real hardware (`deviceName`, `audible`, `sourceCount`, `seq`) are
/// added by `engine_stats()` on top of this and are not this test's business.
#[test]
fn engine_stats_json_carries_the_real_click_count() {
    let mut host = host_with_a_track();
    host.submit(user(), "transport.metronome", json!({ "enabled": true }))
        .expect("transport.metronome");

    let c = cfg();
    let mut r = ManualRenderer::new_monitoring(&c);
    host.sync_params(r.params());
    render_offline_with(
        &mut r,
        vec![ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::Play,
        }],
        4 * u64::from(RATE),
        512,
    );

    let wire = agent_surface::engine_stats_json(&r.stats().snapshot());
    assert_eq!(
        wire["metronomeClicks"].as_u64(),
        Some(8),
        "the app reads the click count by the key `metronomeClicks`, and it must \
         carry the engine's real count (wire: {wire})"
    );
    assert_eq!(
        wire["deviceFramesAudible"].as_u64(),
        Some(0),
        "an offline render never reached a device callback, so this must be 0 \
         (wire: {wire})"
    );
    // The existing engine-health fields are still on the wire beside them.
    assert!(wire["underruns"].is_number(), "wire lost `underruns`: {wire}");
    assert!(
        wire["callbackP95Ms"].is_number(),
        "wire lost `callbackP95Ms`: {wire}"
    );
}

/// With no device open, `engine_stats()` still names the field — and answers a
/// real 0 rather than omitting it, so a reader never has to decide whether an
/// absent key means "none" or "unknown".
#[test]
fn engine_stats_reports_zero_clicks_with_no_device() {
    let host = host_with_a_track();
    let stats = host.engine_stats();
    assert_eq!(stats["live"].as_bool(), Some(false), "precondition: no device");
    assert_eq!(
        stats["metronomeClicks"].as_u64(),
        Some(0),
        "offline engine_stats() must carry `metronomeClicks` as 0 (got {stats})"
    );
    assert_eq!(
        stats["deviceFramesAudible"].as_u64(),
        Some(0),
        "offline engine_stats() must carry `deviceFramesAudible` as 0 (got {stats})"
    );
}
