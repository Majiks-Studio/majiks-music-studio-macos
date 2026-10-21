//! The DJ-interop-style null test: the SAME command script bounced through the
//! FFI path and through the direct (CLI) path must be BIT-IDENTICAL. Only built
//! with `--features ffi`.
#![cfg(feature = "ffi")]

use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use agent_surface::ffi::MajiksEngine;
use agent_surface::StudioHost;
use timeline_core::Actor;

/// The shared mutation script (no lifecycle/export; those differ per route).
fn ops(click: &Path, tone: &Path) -> Vec<(String, Value)> {
    vec![
        ("project.setTempo".into(), json!({ "bpm": 120 })),
        ("track.add".into(), json!({ "trackId": "t1", "name": "Drums" })),
        ("track.add".into(), json!({ "trackId": "t2", "name": "Bass" })),
        (
            "import.audio".into(),
            json!({ "sourcePath": click.display().to_string(), "targetTrackId": "t1", "startTicks": 0, "clipId": "c1" }),
        ),
        (
            "import.audio".into(),
            json!({ "sourcePath": tone.display().to_string(), "targetTrackId": "t2", "startTicks": 7680, "clipId": "c2" }),
        ),
        ("clip.move".into(), json!({ "clipId": "c2", "trackId": "t2", "startTicks": 3840 })),
        ("clip.trim".into(), json!({ "clipId": "c1", "edge": "end", "deltaTicks": -960 })),
        ("mix.gain".into(), json!({ "trackId": "t1", "gainDb": -3 })),
        ("mix.pan".into(), json!({ "trackId": "t2", "pan": 0.5 })),
    ]
}

fn fixtures() -> (PathBuf, PathBuf) {
    let dir = render::fixtures::repo_fixtures_dir();
    render::fixtures::ensure(&dir).expect("fixtures");
    (
        dir.join("click_120bpm_48k_stereo.wav"),
        dir.join("tone_440_48k_mono.wav"),
    )
}

#[test]
fn cli_bounce_null_matches_ffi_bounce_bit_identical() {
    let (click, tone) = fixtures();
    let tmp = tempfile::tempdir().unwrap();

    // Direct route (what the CLI script + ffi_studio_command envelopes do).
    let pkg_a = tmp.path().join("Direct.mstudio");
    let mut host = StudioHost::create_at(&pkg_a, "Direct").unwrap();
    for (name, params) in ops(&click, &tone) {
        host.submit(Actor::user("cli"), &name, params).unwrap();
    }
    let file_a = tmp.path().join("direct.wav");
    host.bounce_master(&file_a).unwrap();

    // FFI route: the MajiksEngine object the Swift app holds.
    let pkg_b = tmp.path().join("Ffi.mstudio");
    let engine = MajiksEngine::initialize(pkg_b.display().to_string()).unwrap();
    for (name, params) in ops(&click, &tone) {
        let env = json!({ "name": name, "params": params }).to_string();
        engine.command(env).unwrap();
    }
    let file_b = tmp.path().join("ffi.wav");
    engine.bounce_master(file_b.display().to_string()).unwrap();

    let a = std::fs::read(&file_a).unwrap();
    let b = std::fs::read(&file_b).unwrap();
    assert_eq!(
        a.len(),
        b.len(),
        "bounce lengths differ ({} vs {})",
        a.len(),
        b.len()
    );
    assert!(
        a == b,
        "FFI bounce is not bit-identical to the direct/CLI bounce (a {} bytes, b {} bytes)",
        a.len(),
        b.len()
    );
    assert!(a.len() > 44, "bounce produced only a header");
}

#[test]
fn ffi_snapshot_reflects_bus_mutations() {
    let tmp = tempfile::tempdir().unwrap();
    let engine = MajiksEngine::initialize(tmp.path().join("Snap.mstudio").display().to_string()).unwrap();
    engine
        .command(r#"{"name":"track.add","params":{"trackId":"t1","name":"Drums"}}"#.to_string())
        .unwrap();
    engine
        .command(r#"{"name":"project.setTempo","params":{"bpm":140}}"#.to_string())
        .unwrap();
    let snap: Value = serde_json::from_str(&engine.snapshot(None).unwrap()).unwrap();
    assert_eq!(snap["project"]["trackCount"], json!(1));
    assert_eq!(snap["seq"], json!(2));
    // A delta since seq 1 reports the tempo change, not the whole world.
    let delta: Value = serde_json::from_str(&engine.snapshot(Some(1)).unwrap()).unwrap();
    assert!(delta["scopes"].as_array().is_some(), "delta carries scopes: {delta}");
}
