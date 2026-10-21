//! §20.2 proof 9, host half: an FX-PARAMETER automation ramp submitted through
//! the FULL PUBLIC PATH audibly changes the render, on all three host
//! spellings — and the bounce of that same project is bit-identical at
//! 128 / 417 / 480 / 512.
//!
//! Row 7's lesson applied prospectively: *"a compiled lane that nothing reads
//! is the default outcome, not the unlikely one."* So every audibility
//! assertion here compares RENDERED SAMPLES produced by the real command bus,
//! and never touches `EngineParams` — poking the params struct is exactly how
//! the solo bug survived.
//!
//! # Hops this seam traverses (§12.5 honesty)
//!
//! `StudioHost::submit` -> catalog schema validation -> `Session::submit` ->
//! `Project::apply_cmd` -> `require_param_ref_on` -> journal envelope + hash
//! chain -> `sync_after_mutation` -> `build_automation` (model lanes ->
//! `AutomationStore`) -> `compile_session_full` -> `bake_fx_lanes` ->
//! `RtFx::lanes` -> `RenderCommand::SetSession` -> `drain_commands` ->
//! `install_session` -> the one `RenderCore::render`, where `run_fx_chain`
//! drives `FxNode::set_frame_param` per FRAME.
//!
//! SKIPPED: the cpal device callback and the real-time deadline —
//! `render_master` is the offline bounce through that same
//! `RenderCore::render`.
//!
//! # The chunk-parity WELD
//!
//! `render_master` bounces at one fixed chunk (512), so block-size parity
//! needs a chunk-controllable renderer. The parity test below compiles the
//! HOST'S OWN model + sources + automation through the public
//! `compile_session_full`, pushes params through the host's own public
//! `sync_params`, renders at four chunk sizes — and then WELDS the harnesses
//! by asserting its chunk-512 render is byte-identical to
//! `host.render_master()`. If the weld holds, the four-way digest equality is
//! a statement about the real public bounce, not about a lookalike harness.

use std::path::PathBuf;
use std::sync::OnceLock;

use serde_json::json;

use agent_surface::StudioHost;
use render::automation::{AutomationStore, CurveKind, RawPoint};
use render::compile::{compile_session_full, DeclickPolicy};
use render::engine::EngineConfig;
use render::offline::{render_offline_with, ManualRenderer, ScheduledCommand};
use render::rt::RenderCommand;
use render::warp::WarpOverlay;
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

fn to_bytes(audio: &[[f32; 2]]) -> Vec<u8> {
    audio
        .iter()
        .flat_map(|f| [f[0].to_bits(), f[1].to_bits()])
        .flat_map(u32::to_le_bytes)
        .collect()
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

fn energy(a: &[[f32; 2]], b: &[[f32; 2]], range: std::ops::Range<usize>) -> f64 {
    range
        .map(|i| {
            let dl = f64::from(a[i][0] - b[i][0]);
            let dr = f64::from(a[i][1] - b[i][1]);
            dl * dl + dr * dr
        })
        .sum()
}

fn last_active_frame(dry: &[[f32; 2]]) -> usize {
    (0..dry.len())
        .rev()
        .find(|&i| dry[i][0].abs() > 1.0e-4 || dry[i][1].abs() > 1.0e-4)
        .expect("the dry reference is silence")
}

/// One tone track feeding a group bus, with an fx on the TRACK chain (keyed
/// compressor), the BUS chain (utility) and the MASTER chain (saturator) —
/// every parameter the ramps will move pinned at the ramp's START value, so a
/// lane-less render of this host is the exact t=0 reference and any
/// difference a ramp makes has to GROW out of (near) zero.
fn fixture_host() -> (StudioHost, u64) {
    let tone = tone_fixture();
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("FxParamAuto.mstudio");
    let mut host = StudioHost::create_at(&pkg, "FxParamAuto").unwrap();
    std::mem::forget(tmp);

    host.submit(user(), "track.add", json!({"trackId":"t1","name":"Tone"}))
        .unwrap();
    let outcome = host
        .import_audio(&tone.display().to_string(), "t1", 0, Some("c1".into()))
        .unwrap();

    host.submit(
        user(),
        "route.node.add",
        json!({"nodeId":"grp","kind":"group","name":"Group"}),
    )
    .unwrap();
    host.submit(
        user(),
        "route.connect",
        json!({"edgeId":"e1","from":"track.t1","to":"bus.grp","level":1.0,"tap":"post"}),
    )
    .unwrap();

    for (target, fx_id, kind) in [
        ("track.t1", "c1x", "compressor"),
        ("bus.grp", "bu", "utility"),
        ("master", "ms", "saturator"),
    ] {
        host.submit(
            user(),
            "fx.add",
            json!({"target": target, "fxId": fx_id, "kind": kind}),
        )
        .unwrap();
    }
    // Ramp-start values, journaled, so dry == wet at t=0 up to the declick.
    for (target, fx_id, key, value) in [
        ("track.t1", "c1x", "threshold", 0.0_f64),
        ("bus.grp", "bu", "gain", 0.0),
        ("master", "ms", "drive", 0.0),
    ] {
        host.submit(
            user(),
            "fx.param.set",
            json!({"target": target, "fxId": fx_id, "key": key, "value": value}),
        )
        .unwrap();
    }
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

/// The three ramps of this file, one per host spelling. Each is drawn from the
/// exact value its parameter is pinned at, so the wet-vs-dry difference must
/// grow across the ramp.
const RAMPS: [(&str, f64, f64); 3] = [
    ("track.fx.c1x.threshold", 0.0, -45.0),
    ("bus.grp.fx.bu.gain", 0.0, -24.0),
    ("master.fx.ms.drive", 0.0, 24.0),
];

/// §20.2 proof 9, audibility: each spelling's ramp, drawn through the real
/// command bus, changes the bounce — and the change GROWS across the ramp,
/// so it is a ramp and not a constant offset.
#[test]
fn an_fx_param_ramp_on_each_host_spelling_is_audible_through_the_command_bus() {
    let (dry_host, _) = fixture_host();
    let dry = dry_host.render_master().unwrap();
    let active = last_active_frame(&dry);

    for (target, lo, hi) in RAMPS {
        let (mut host, len) = fixture_host();
        draw_ramp(&mut host, target, len, lo, hi);
        let wet = host.render_master().unwrap();

        assert_eq!(dry.len(), wet.len(), "{target}: the bounce length changed");
        assert_ne!(
            to_bytes(&dry),
            to_bytes(&wet),
            "{target}: a ramp submitted through the real command bus produced a \
             BYTE-IDENTICAL bounce — fx parameter automation is inert"
        );

        // Shape: energy against the dry reference must grow across the region
        // where the source is playing. Sixths, each above the last.
        let sixths: Vec<f64> = (0..6)
            .map(|k| energy(&dry, &wet, active * k / 6..active * (k + 1) / 6))
            .collect();
        assert!(
            sixths[5] > sixths[0] * 10.0 && sixths[5] > 0.0,
            "{target}: the ramp barely moved end to end: {sixths:?}"
        );
        for k in 1..6 {
            assert!(
                sixths[k] >= sixths[k - 1] * 0.9,
                "{target}: the difference collapsed mid-ramp (segment {k}): {sixths:?}"
            );
        }
    }
}

/// §20.2 proof 9, parity: the SAME project — all three ramps live at once —
/// bounces bit-identically at 128 / 417 / 480 / 512, welded to the public
/// `render_master` bounce byte-for-byte at chunk 512.
#[test]
fn the_full_path_fx_param_bounce_is_bit_identical_at_128_417_480_512() {
    let (mut host, len) = fixture_host();
    for (target, lo, hi) in RAMPS {
        draw_ramp(&mut host, target, len, lo, hi);
    }
    let public = host.render_master().unwrap();
    let peak = public
        .iter()
        .flat_map(|f| [f[0].abs(), f[1].abs()])
        .fold(0.0_f32, f32::max);
    assert!(peak > 0.05, "the parity reference is silence (peak {peak})");

    // Reconstruct the automation store exactly as the host's own
    // `build_automation` does (model lanes -> RawPoint, Linear) — the weld
    // assertion below is what proves this reconstruction faithful.
    let project = host.project().clone();
    let mut automation = AutomationStore::new();
    for track in &project.tracks {
        for (path, points) in track.automation.iter_lanes() {
            for p in points {
                automation.add_point_path(
                    &track.id,
                    path.as_str(),
                    RawPoint {
                        tick: p.position_ticks,
                        value: p.value.as_f64() as f32,
                        curve: CurveKind::Linear,
                    },
                );
            }
        }
    }

    let max_tracks = project.tracks.len().max(1);
    let mut digests = Vec::new();
    let mut chunk512: Vec<[f32; 2]> = Vec::new();
    for chunk in [128_usize, 417, 480, 512] {
        let session = compile_session_full(
            &project,
            host.sources(),
            &WarpOverlay::new(),
            &automation,
            max_tracks,
            DeclickPolicy::Auto, // the host's policy (`render_to` uses self.declick)
        )
        .expect("compiles");
        let cfg = EngineConfig {
            sample_rate: project.sample_rate,
            max_tracks,
            ..EngineConfig::default()
        };
        let mut renderer = ManualRenderer::new(&cfg);
        host.sync_params(renderer.params());
        let out = render_offline_with(
            &mut renderer,
            vec![
                ScheduledCommand {
                    at_frame: 0,
                    command: RenderCommand::SetSession(session),
                },
                ScheduledCommand {
                    at_frame: 0,
                    command: RenderCommand::Play,
                },
            ],
            public.len() as u64,
            chunk,
        );
        if chunk == 512 {
            chunk512 = out.clone();
        }
        let d = digest(&out);
        println!("proof 9 parity: chunk {chunk:>3}, {} frames, blake3 {d}", out.len());
        digests.push((chunk, d));
    }

    // THE WELD: the chunk-512 render is byte-identical to the public bounce,
    // so the digests above are digests OF the public path's output.
    assert_eq!(
        to_bytes(&chunk512),
        to_bytes(&public),
        "the chunk-512 harness render is not the public bounce — the parity \
         digests below would be about a lookalike, not about render_master"
    );

    for (chunk, d) in &digests {
        assert_eq!(
            d, &digests[0].1,
            "proof 9 FAILED: the bounce differs at chunk {chunk} vs 128 — an fx \
             lane is applied per BLOCK somewhere (§6.1)"
        );
    }
}

/// The refusal half through the full bus: a COEFFICIENT key (`attack`), the
/// slotless `bypass`, and a readable key on a kind that does not declare it
/// (`gain` on a compressor) are all accepted as COMMANDS — apply runs on
/// replay, narrowing it would break opens — and refused at RENDER, loudly,
/// naming the lane and the way out.
#[test]
fn a_refused_fx_lane_is_loud_at_bounce_and_the_command_still_lands() {
    for (target, lo, hi, why) in [
        ("track.fx.c1x.attack", 0.0, 150.0, "COEFFICIENT"),
        ("track.fx.c1x.bypass", 0.0, 1.0, "NO parameter slot"),
        // Kind-aware: `gain` IS readable vocabulary (utility/saturator), but
        // the compressor does not declare it.
        ("track.fx.c1x.gain", 0.0, -12.0, "no 'gain' parameter"),
    ] {
        let (mut host, len) = fixture_host();
        draw_ramp(&mut host, target, len, lo, hi);
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
        assert!(
            err.contains("autolane.clear"),
            "{target}: no way forward offered: {err}"
        );
    }
}
