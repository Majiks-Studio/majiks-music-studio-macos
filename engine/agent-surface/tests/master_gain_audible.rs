//! Does `mix.master.gain` reach the AUDIO, and by exactly how much?
//!
//! `persistence_bounce.rs::the_bounce_is_sensitive_to_each_persisted_value_it_
//! claims_to_protect` already proves the bounce is not blind to master gain —
//! but it compares a digest, so it answers "something moved", not "the mix is
//! 12 dB quieter". A gain that reached the render path with the wrong sign, at
//! half strength, or only on the first block would pass that comparison.
//!
//! This file asserts the magnitude, through the real command bus:
//! `StudioHost::submit` -> `Project::apply_cmd` -> `sync_after_mutation` ->
//! `sync_params` -> `EngineParams::set_master_gain_db` -> `RenderCore::render`
//! -> the master multiply in `rt.rs`. Nothing here touches `EngineParams`
//! directly (that would skip `sync_params`, which is the hop that has broken
//! before) and nothing here opens an audio device.

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

fn host_with_tone() -> StudioHost {
    let tone = tone_fixture();
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("MasterGain.mstudio");
    let mut host = StudioHost::create_at(&pkg, "MasterGain").unwrap();
    std::mem::forget(tmp);
    host.submit(user(), "track.add", json!({"trackId":"t1","name":"Tone"}))
        .unwrap();
    host.import_audio(&tone.display().to_string(), "t1", 0, Some("c1".into()))
        .unwrap();
    // The limiter would flatten exactly the difference this test measures, so
    // it is switched off explicitly rather than assumed off.
    host.submit(
        user(),
        "mix.limiter.set",
        json!({"enabled": false, "ceilingDb": -1, "releaseMs": 50}),
    )
    .unwrap();
    host
}

/// RMS over a window that starts after the master gain's slew has settled.
/// `Slew` is snapped on reset, but skipping the first 100 ms costs nothing and
/// means a ramp could never be mistaken for a level.
fn rms(frames: &[[f32; 2]]) -> f64 {
    let window = &frames[4_800.min(frames.len())..];
    assert!(!window.is_empty(), "nothing to measure");
    let sum: f64 = window
        .iter()
        .map(|f| f[0] as f64 * f[0] as f64 + f[1] as f64 * f[1] as f64)
        .sum();
    (sum / (window.len() * 2) as f64).sqrt()
}

fn peak(frames: &[[f32; 2]]) -> f64 {
    frames
        .iter()
        .map(|f| f[0].abs().max(f[1].abs()) as f64)
        .fold(0.0, f64::max)
}

#[test]
fn master_gain_scales_the_bounce_by_the_decibels_it_was_given() {
    let mut host = host_with_tone();

    host.submit(user(), "mix.master.gain", json!({"gainDb": -6}))
        .unwrap();
    let loud = host.render_master().unwrap();
    host.submit(user(), "mix.master.gain", json!({"gainDb": -18}))
        .unwrap();
    let quiet = host.render_master().unwrap();

    // Guard the guard: two silences would satisfy every ratio below.
    assert!(
        peak(&loud) > 0.01,
        "the -6 dB bounce is silent (peak {}), so this test proves nothing",
        peak(&loud)
    );
    assert_eq!(loud.len(), quiet.len(), "the two bounces are different lengths");

    let (a, b) = (rms(&loud), rms(&quiet));
    let ratio = b / a;
    // 12 dB down is a factor of 0.251189.
    assert!(
        (ratio - 0.251189).abs() < 0.005,
        "a 12 dB master gain change scaled the bounce by {ratio:.6}, not 0.251189 \
         (-6 dB rms {a:.6}, -18 dB rms {b:.6})"
    );
    // Peak agrees with RMS: the change is a gain, not a shape.
    let peak_ratio = peak(&quiet) / peak(&loud);
    assert!(
        (peak_ratio - 0.251189).abs() < 0.005,
        "peak ratio {peak_ratio:.6} disagrees with the rms ratio {ratio:.6}"
    );

    // Unity is unity: +0 dB must leave the mix alone, so the scale factor is
    // anchored at both ends and not merely proportional.
    host.submit(user(), "mix.master.gain", json!({"gainDb": 0}))
        .unwrap();
    let unity = host.render_master().unwrap();
    let unity_over_loud = rms(&unity) / a;
    // 0 dB / -6 dB = 1.995262.
    assert!(
        (unity_over_loud - 1.995262).abs() < 0.02,
        "0 dB against -6 dB is {unity_over_loud:.6}, not 1.995262"
    );
}

/// The snapshot must report back what the bounce just proved, under the exact
/// key the Swift app reads (`project.master.gain_db`). `agent_parity.rs` pins
/// this for one value; this pins it for the ends of the catalog range, which is
/// where a clamp or a wire-name fallback would show up.
#[test]
fn the_snapshot_reports_the_master_gain_the_render_used() {
    let mut host = host_with_tone();
    for db in [-60.0_f64, -13.5, 0.0, 12.0] {
        host.submit(user(), "mix.master.gain", json!({ "gainDb": db }))
            .unwrap();
        let snap = host.snapshot(None);
        let read = snap["project"]["master"]["gain_db"]
            .as_f64()
            .unwrap_or_else(|| panic!("project.master.gain_db is missing or not a number: {snap:#}"));
        assert!(
            (read - db).abs() < 1e-9,
            "submitted {db} dB, snapshot reports {read} dB"
        );
    }
}
