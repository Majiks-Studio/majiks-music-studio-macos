//! Live audio end-to-end proof (the I1 "it's real" checkpoint), headless.
//!
//! This test opens a REAL cpal output device, so it is OFF by default: it
//! no-ops unless `MAJIKS_TEST_LIVE=1`, which keeps `cargo test --workspace`
//! from ever touching an audio device on CI or a headless run. When it does
//! run, the stream is still SILENCE-GATED (nothing audible unless
//! `MAJIKS_TEST_AUDIBLE=1`), so it is safe to run on a machine with live
//! monitors.
//!
//! What it proves, through the same command bus the app and MCP agents use:
//!   1. a real WAV imports onto the timeline as a clip;
//!   2. `start_live` opens the live engine and the transport RUNS against it
//!      (the render thread advances `position_frame`);
//!   3. an agent-issued `clip.move` (the tool route -- the exact function the
//!      MCP server dispatches) is reflected in the next snapshot.
//!
//! Reproduce:  MAJIKS_TEST_LIVE=1 cargo test -p agent-surface --features ffi --test live -- --nocapture

use std::time::{Duration, Instant};

use serde_json::json;

use agent_surface::{dispatch_tool, StudioHost};
use timeline_core::envelope::ActorKind;
use timeline_core::Actor;

fn live_enabled() -> bool {
    std::env::var("MAJIKS_TEST_LIVE").as_deref() == Ok("1")
}

fn agent() -> Actor {
    Actor {
        kind: ActorKind::Agent,
        name: "i1-live-test".into(),
    }
}

#[test]
fn live_transport_advances_and_agent_move_reflects() {
    if !live_enabled() {
        eprintln!("skipping live test (set MAJIKS_TEST_LIVE=1 to run; opens an audio device)");
        return;
    }

    // A real fixture WAV (generated on demand, pinned by blake3).
    let fixtures = render::fixtures::repo_fixtures_dir();
    render::fixtures::ensure(&fixtures).expect("ensure fixtures");
    let click = fixtures.join("click_120bpm_48k_stereo.wav");

    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("LiveProof.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Live Proof").expect("create package");

    // Build a tiny project: one track, one imported clip at bar 1.
    host.submit(agent(), "track.add", json!({ "trackId": "t1", "name": "Drums" }))
        .expect("track.add");
    let placed = host
        .submit(
            agent(),
            "import.audio",
            json!({ "sourcePath": click.display().to_string(), "targetTrackId": "t1", "startTicks": 0, "clipId": "c1" }),
        )
        .expect("import.audio");
    assert_eq!(placed["ok"], json!(true), "{placed}");

    // 1. Go live. The stream opens SILENT; the graph renders for real.
    let info = host.start_live().expect("start_live");
    assert_eq!(info["live"], json!(true), "start_live info: {info}");
    assert!(host.is_live());
    // Audio safety: audible only behind the env flag; default must be silent.
    assert_eq!(
        info["audible"],
        json!(std::env::var("MAJIKS_TEST_AUDIBLE").as_deref() == Ok("1")),
        "stream must be silent unless MAJIKS_TEST_AUDIBLE=1"
    );

    // 2. Play, and prove the REAL engine clock advances (position_frame > 0).
    host.submit(agent(), "transport.play", json!({})).expect("play");
    let mut position_frame = 0_u64;
    let deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(30));
        let stats = host.engine_stats();
        position_frame = stats["positionFrame"].as_u64().unwrap_or(0);
        if position_frame > 0 && stats["callbacks"].as_u64().unwrap_or(0) > 0 {
            break;
        }
    }
    assert!(
        position_frame > 0,
        "the transport did not advance against the live engine (position_frame stayed 0)"
    );
    let snap = host.snapshot(None);
    assert_eq!(snap["transport"]["live"], json!(true), "{}", snap["transport"]);
    assert_eq!(snap["transport"]["playing"], json!(true), "{}", snap["transport"]);
    host.submit(agent(), "transport.stop", json!({})).expect("stop");

    // 3. An agent moves the clip over the TOOL route (dispatch_tool is exactly
    // what the MCP server calls). The next snapshot must reflect the new start.
    let before = clip_start(&host.snapshot(None), "c1");
    assert_eq!(before, Some(0), "clip should start at 0 before the move");
    let moved = dispatch_tool(
        &mut host,
        agent(),
        "studio_clip_move",
        json!({ "clipId": "c1", "trackId": "t1", "startTicks": 3840 }),
    )
    .expect("agent clip.move");
    assert_eq!(moved["ok"], json!(true), "{moved}");
    let after = clip_start(&host.snapshot(None), "c1");
    assert_eq!(after, Some(3840), "the snapshot must reflect the agent's move");

    // Live edits recompile + repush to the audio thread without breaking; a
    // stale-but-honest read is fine, a panic is not. Engine stays healthy.
    let stats = host.engine_stats();
    assert_eq!(stats["underruns"], json!(0), "no underruns during the run: {stats}");
    assert_eq!(stats["allocViolations"], json!(0), "render callback stayed alloc-free: {stats}");

    assert!(host.stop_live(), "stop_live should report a session was closed");
    assert!(!host.is_live());
}

/// Pull clip `id`'s startTicks out of a snapshot's serialized project model.
fn clip_start(snapshot: &serde_json::Value, id: &str) -> Option<i64> {
    let tracks = snapshot.get("project")?.get("tracks")?.as_array()?;
    for t in tracks {
        if let Some(clips) = t.get("clips").and_then(|c| c.as_array()) {
            for c in clips {
                let cid = c.get("id").or_else(|| c.get("clipId")).and_then(|v| v.as_str());
                if cid == Some(id) {
                    return c
                        .get("start_ticks")
                        .or_else(|| c.get("startTicks"))
                        .and_then(|v| v.as_i64());
                }
            }
        }
    }
    None
}
