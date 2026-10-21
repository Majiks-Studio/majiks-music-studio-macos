//! L12 acceptance: mixer + automation drive the SAME command bus everything
//! else does, so every control round-trips (undo restores it), an agent's
//! command lands in the snapshot the dock reads, and drawn automation renders
//! into a deterministic, click-free bounce.
//!
//! These exercise the real `StudioHost` (the instance the FFI/MCP/CLI share),
//! its journaled undo, and the offline bounce (the same `RenderCore::render`
//! the device callback runs). Silent: the offline path never opens a device.

use std::path::PathBuf;
use std::sync::OnceLock;

use serde_json::{json, Value};

use agent_surface::StudioHost;
use timeline_core::envelope::ActorKind;
use timeline_core::Actor;

fn tone_fixture() -> PathBuf {
    // `ensure` generates missing fixtures into a shared repo dir; serialize the
    // first call so parallel test threads never race on the same file write.
    static READY: OnceLock<PathBuf> = OnceLock::new();
    READY
        .get_or_init(|| {
            let dir = render::fixtures::repo_fixtures_dir();
            render::fixtures::ensure(&dir).expect("fixtures");
            dir
        })
        .join("tone_440_48k_mono.wav")
}

/// A host with one track carrying a steady 440 Hz tone clip at tick 0.
/// Returns the host and the clip length in ticks.
fn host_with_tone() -> (StudioHost, u64) {
    let tone = tone_fixture();
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("MixerAuto.mstudio");
    let mut host = StudioHost::create_at(&pkg, "MixerAuto").unwrap();
    // The bounce renders from the host's in-memory sources, so the package dir
    // is only needed through import; leak the handle so nothing races a delete.
    std::mem::forget(tmp);
    host.submit(Actor::user("t"), "track.add", json!({ "trackId": "t1", "name": "Tone" }))
        .unwrap();
    let outcome = host
        .import_audio(&tone.display().to_string(), "t1", 0, Some("c1".into()))
        .unwrap();
    (host, outcome.length_ticks)
}

fn user() -> Actor {
    Actor::user("aaron")
}

fn agent() -> Actor {
    Actor {
        kind: ActorKind::Agent,
        name: "copilot".into(),
    }
}

fn track_gain_db(host: &StudioHost) -> f64 {
    host.project().track("t1").unwrap().gain.as_f64()
}

fn max_abs_delta(audio: &[[f32; 2]]) -> f32 {
    audio
        .windows(2)
        .map(|w| (w[1][0] - w[0][0]).abs().max((w[1][1] - w[0][1]).abs()))
        .fold(0.0_f32, f32::max)
}

fn rms(audio: &[[f32; 2]]) -> f64 {
    if audio.is_empty() {
        return 0.0;
    }
    let sumsq: f64 = audio
        .iter()
        .map(|f| f64::from(f[0]) * f64::from(f[0]) + f64::from(f[1]) * f64::from(f[1]))
        .sum();
    (sumsq / (audio.len() as f64 * 2.0)).sqrt()
}

// ---------------------------------------------------------------------------
// 1. Every mixer control round-trips through the bus, and undo restores it.
// ---------------------------------------------------------------------------

#[test]
fn every_mixer_control_round_trips_and_undoes() {
    let (mut host, _len) = host_with_tone();

    // Each control: (name, params, an assertion the model changed).
    type Check = fn(&StudioHost) -> bool;
    let cases: Vec<(&str, Value, Check)> = vec![
        (
            "mix.gain",
            json!({ "trackId": "t1", "gainDb": -6 }),
            (|h| (track_gain_db(h) - -6.0).abs() < 1e-9) as Check,
        ),
        (
            "mix.pan",
            json!({ "trackId": "t1", "pan": 0.5 }),
            (|h| (h.project().track("t1").unwrap().pan.as_f64() - 0.5).abs() < 1e-9) as Check,
        ),
        (
            "mix.eq",
            json!({ "trackId": "t1", "band": 1, "freqHz": 900, "gainDb": 4, "q": 1.2 }),
            (|h| {
                let b = &h.project().track("t1").unwrap().eq[1];
                (b.gain_db.as_f64() - 4.0).abs() < 1e-9 && (b.freq_hz.as_f64() - 900.0).abs() < 1e-9
            }) as Check,
        ),
        (
            "mix.send",
            json!({ "trackId": "t1", "bus": "a", "amount": 0.3 }),
            (|h| (h.project().track("t1").unwrap().sends.a.as_f64() - 0.3).abs() < 1e-9) as Check,
        ),
        (
            "mix.master.gain",
            json!({ "gainDb": -2 }),
            (|h| (h.project().master.gain_db.as_f64() - -2.0).abs() < 1e-9) as Check,
        ),
        (
            "mix.limiter.set",
            json!({ "enabled": true, "ceilingDb": -0.5, "releaseMs": 80 }),
            (|h| {
                let l = &h.project().master.limiter;
                l.enabled
                    && (l.ceiling_db.as_f64() - -0.5).abs() < 1e-9
                    && (l.release_ms.as_f64() - 80.0).abs() < 1e-9
            }) as Check,
        ),
    ];

    for (name, params, check) in &cases {
        let seq_before = host.seq();
        host.submit(user(), name, params.clone())
            .unwrap_or_else(|e| panic!("{name} submit failed: {e:?}"));
        assert!(host.seq() > seq_before, "{name} did not journal (seq unchanged)");
        assert!(check(&host), "{name} did not land in the model snapshot");
    }

    // Undo the whole stack in reverse; every control returns to its default.
    for _ in 0..cases.len() {
        assert!(host.undo(user()).unwrap(), "undo ran out of history early");
    }
    let t = host.project().track("t1").unwrap();
    assert_eq!(t.gain.as_f64(), 0.0, "gain back to default after undo");
    assert_eq!(t.pan.as_f64(), 0.0, "pan back to default after undo");
    assert_eq!(t.eq[1].gain_db.as_f64(), 0.0, "eq band back to default after undo");
    assert_eq!(t.sends.a.as_f64(), 0.0, "send A back to default after undo");
    assert_eq!(host.project().master.gain_db.as_f64(), 0.0, "master back to default");
    assert!(!host.project().master.limiter.enabled, "limiter back to default (off)");
}

/// A single mix.gain undoes to the exact prior value, not just to default:
/// two moves then one undo restores the FIRST move's value.
#[test]
fn mixer_undo_restores_the_prior_value_not_just_default() {
    let (mut host, _len) = host_with_tone();
    host.submit(user(), "mix.gain", json!({ "trackId": "t1", "gainDb": -6 })).unwrap();
    host.submit(user(), "mix.gain", json!({ "trackId": "t1", "gainDb": -12 })).unwrap();
    assert!((track_gain_db(&host) - -12.0).abs() < 1e-9);
    assert!(host.undo(user()).unwrap());
    assert!((track_gain_db(&host) - -6.0).abs() < 1e-9, "undo restored the prior move");
    assert!(host.redo(user()).unwrap());
    assert!((track_gain_db(&host) - -12.0).abs() < 1e-9, "redo re-applies");
}

/// The dock reads engine truth whoever moved it: an AGENT-actor mix.gain (the
/// MCP path) lands in the same snapshot the UI polls.
#[test]
fn an_agent_fader_move_shows_up_in_the_snapshot() {
    let (mut host, _len) = host_with_tone();
    host.submit(agent(), "mix.gain", json!({ "trackId": "t1", "gainDb": -8 }))
        .unwrap();
    // The snapshot the FFI/dock reads (serialized project) carries the new gain.
    let snap = host.snapshot(None);
    let gain = snap
        .get("project")
        .and_then(|p| p.get("tracks"))
        .and_then(Value::as_array)
        .and_then(|ts| ts.first())
        .and_then(|t| t.get("gain"))
        .and_then(Value::as_f64)
        .expect("snapshot carries track gain");
    assert!((gain - -8.0).abs() < 1e-9, "agent's fader move is in the snapshot: {gain}");
}

// ---------------------------------------------------------------------------
// 2. Automation: draw -> engine render -> bounce is deterministic + applied.
// ---------------------------------------------------------------------------

/// Drawing the SAME volume automation into two independent sessions bounces
/// BIT-IDENTICALLY (the render is a pure function of the journal), and the
/// automation actually changes the audio versus no automation.
#[test]
fn automation_draw_bounce_is_deterministic_and_applied() {
    let (host_plain, len) = host_with_tone();
    let baseline = host_plain.render_master().unwrap();

    // Draw a volume ramp: unity at the top, -18 dB by the last quarter.
    let draw = |host: &mut StudioHost| {
        let q = len / 4;
        for (i, (tick, db)) in [(0u64, 0.0), (q, 0.0), (len - q, -18.0), (len, -18.0)]
            .into_iter()
            .enumerate()
        {
            host.submit(
                user(),
                "autopoint.add",
                json!({
                    "trackId": "t1",
                    "target": "track.volume",
                    "pointId": format!("p{i}"),
                    "positionTicks": tick,
                    "value": db,
                }),
            )
            .unwrap();
        }
    };

    let (mut host_a, _) = host_with_tone();
    draw(&mut host_a);
    let bounce_a = host_a.render_master().unwrap();

    let (mut host_b, _) = host_with_tone();
    draw(&mut host_b);
    let bounce_b = host_b.render_master().unwrap();

    // Draw -> render -> bounce is identical across two independent builds.
    assert_eq!(bounce_a.len(), bounce_b.len(), "bounce lengths differ");
    assert_eq!(
        to_bytes(&bounce_a),
        to_bytes(&bounce_b),
        "the same drawn automation must bounce bit-identically"
    );

    // The automation is really applied: the second half is quieter than the
    // baseline's second half (the ramp pulls it down by ~18 dB).
    let tail = |a: &[[f32; 2]]| rms(&a[a.len() / 2..]);
    eprintln!(
        "[l12] automation bounce: identical A==B across 2 builds; tail RMS auto={:.5} vs plain={:.5}",
        tail(&bounce_a), tail(&baseline)
    );
    assert!(
        tail(&bounce_a) < tail(&baseline) * 0.5,
        "volume automation should pull the tail down (auto {} vs plain {})",
        tail(&bounce_a),
        tail(&baseline)
    );

    // Undo every point restores the plain bounce exactly (round-trip closes).
    for _ in 0..4 {
        assert!(host_a.undo(user()).unwrap());
    }
    let restored = host_a.render_master().unwrap();
    assert_eq!(
        to_bytes(&restored),
        to_bytes(&baseline),
        "undoing the automation returns the exact original bounce"
    );
}

/// A near-instant automation step renders click-free: the strip's declick slew
/// turns the step into a bounded-slope ramp, so the master's max per-sample
/// delta stays near the steady tone's own slope (no zipper edge).
#[test]
fn automation_step_bounces_without_zipper() {
    // Steady reference: what the tone's own max per-sample delta looks like.
    let (host_ref, len) = host_with_tone();
    let steady = host_ref.render_master().unwrap();
    let steady_delta = max_abs_delta(&steady);

    // A hard step: unity, then -48 dB one tick later, held to the end.
    let (mut host, _) = host_with_tone();
    let mid = len / 2;
    for (i, (tick, db)) in [(0u64, 0.0), (mid, 0.0), (mid + 1, -48.0), (len, -48.0)]
        .into_iter()
        .enumerate()
    {
        host.submit(
            user(),
            "autopoint.add",
            json!({
                "trackId": "t1",
                "target": "track.volume",
                "pointId": format!("s{i}"),
                "positionTicks": tick,
                "value": db,
            }),
        )
        .unwrap();
    }
    let stepped = host.render_master().unwrap();
    let stepped_delta = max_abs_delta(&stepped);
    eprintln!(
        "[l12] no-zipper: stepped max per-sample delta={:.5}, steady tone delta={:.5} (a raw step would be ~0.4-0.5)",
        stepped_delta, steady_delta
    );

    // A raw (un-declicked) step on this ~-6 dBFS tone would jump by ~0.4-0.5 in
    // a single sample. The declick slew keeps it near the steady tone's slope.
    assert!(
        stepped_delta < steady_delta + 0.02,
        "zipper: stepped max delta {stepped_delta} >> steady {steady_delta}"
    );
    assert!(
        stepped_delta < 0.1,
        "stepped max per-sample delta {stepped_delta} indicates a click"
    );
}

fn to_bytes(audio: &[[f32; 2]]) -> Vec<u8> {
    let mut out = Vec::with_capacity(audio.len() * 8);
    for f in audio {
        out.extend_from_slice(&f[0].to_bits().to_le_bytes());
        out.extend_from_slice(&f[1].to_bits().to_le_bytes());
    }
    out
}

// Guard: the tone lands as exactly one content-addressed source, so the
// bounce comparisons above compare the same audio under different automation.
#[test]
fn tone_source_is_content_addressed() {
    let (host, _len) = host_with_tone();
    assert_eq!(host.sources().len(), 1, "one decoded source for the tone");
}
