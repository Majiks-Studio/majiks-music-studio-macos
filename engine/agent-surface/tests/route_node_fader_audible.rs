//! End-to-end proof that `route.node.set` — the node FADER command — changes
//! the AUDIO, driven through the real `StudioHost` command bus, never by
//! poking `EngineParams`.
//!
//! The gap this closes: §4.3 promises buses "with their own fader", the render
//! side already evaluates node faders, the atomics existed
//! (`set_node_gain_db`), the automation lane (`bus.<id>.gain`) was readable —
//! and NO command set the fader, because `RouteNode` had no gain field and
//! nothing pushed one. A bus fader unreachable from any surface is §0 row 7's
//! bug class (a green model over silent DSP), so every assertion here compares
//! RENDERED SAMPLES.
//!
//! # Hops this seam traverses (§12.5 honesty)
//!
//! `StudioHost::submit` -> catalog schema validation -> `Session::submit` ->
//! `Project::apply_cmd` (`RouteNodeSet`, truthful self-inverse) -> journal
//! envelope + hash chain -> `sync_after_mutation` -> `render_master` ->
//! `compile_session_full` -> `sync_params` -> `compile::sync_graph_params`
//! (the model->atomic PUSH under test) -> `RenderCommand::SetSession` ->
//! `drain_commands` -> `install_session` -> the one `RenderCore::render`.
//!
//! SKIPPED: the cpal device callback and the real-time deadline (offline
//! bounce, same `RenderCore::render`).
//!
//! The chunk-independence test compiles the host's OWN project/sources and
//! calls the host's production `sync_params` on each renderer, so the push it
//! exercises is the shipping one, not a re-implementation.

use std::path::PathBuf;
use std::sync::OnceLock;

use serde_json::json;

use agent_surface::StudioHost;
use render::automation::AutomationStore;
use render::compile::compile_session_full;
use render::engine::EngineConfig;
use render::offline::{render_offline_with, ManualRenderer, ScheduledCommand};
use render::warp::WarpOverlay;
use render::RenderCommand;
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

fn rms(audio: &[[f32; 2]]) -> f64 {
    let sum: f64 = audio
        .iter()
        .map(|f| f64::from(f[0]) * f64::from(f[0]) + f64::from(f[1]) * f64::from(f[1]))
        .sum();
    (sum / (2.0 * audio.len() as f64)).sqrt()
}

/// One tone track feeding a GROUP through a post-tap edge at unity. §4.2: the
/// post edge suppresses t1's implicit master feed, and the group's own
/// implicit feed carries it to master — so the group fader scales the ENTIRE
/// mix and the expected ratio is exact, not diluted by a parallel dry path.
fn host_with_grouped_tone(tag: &str) -> (StudioHost, PathBuf) {
    let tone = tone_fixture();
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join(format!("{tag}.mstudio"));
    let mut host = StudioHost::create_at(&pkg, tag).unwrap();
    std::mem::forget(tmp);

    host.submit(user(), "track.add", json!({"trackId": "t1", "name": "Tone"}))
        .unwrap();
    host.import_audio(&tone.display().to_string(), "t1", 0, Some("c1".into()))
        .unwrap();
    host.submit(
        user(),
        "route.node.add",
        json!({"nodeId": "grp", "kind": "group", "name": "Drums"}),
    )
    .unwrap();
    host.submit(
        user(),
        "route.connect",
        json!({"edgeId": "e1", "from": "track.t1", "to": "bus.grp",
               "level": 1, "tap": "post"}),
    )
    .unwrap();
    (host, pkg)
}

/// −6 dB in the same shape the engine computes it (`db_to_lin` is
/// `10^(db/20)` in f32).
fn minus_six_linear() -> f32 {
    10f32.powf(-6.0 / 20.0)
}

// ---------------------------------------------------------------------------
// THE proof: submit_json -> sync_after_mutation -> bounce, ratio asserted.
// ---------------------------------------------------------------------------

/// ⚠️ Before this lane, the SAME gesture was impossible: no command could set
/// a node fader at all, and hand-editing the model would have bounced at
/// unity because nothing pushed it. This asserts the ratio, not "quieter".
#[test]
fn a_minus_six_db_bus_fader_halves_the_bus_contribution() {
    let (mut host, _) = host_with_grouped_tone("NodeFaderRatio");
    let unity = host.render_master().unwrap();
    let unity_peak = unity.iter().fold(0f32, |m, f| m.max(f[0].abs()).max(f[1].abs()));
    assert!(
        unity_peak > 0.05,
        "the fixture carries no signal (peak {unity_peak}); a ratio proof over \
         silence is vacuous"
    );

    host.submit(
        user(),
        "route.node.set",
        json!({"nodeId": "grp", "gainDb": -6.0}),
    )
    .unwrap();
    let trimmed = host.render_master().unwrap();
    assert_eq!(trimmed.len(), unity.len(), "bounce length moved");

    let g = minus_six_linear(); // 0.50118727
    let mut checked = 0usize;
    for (i, (u, t)) in unity.iter().zip(trimmed.iter()).enumerate() {
        for ch in 0..2 {
            let a = u[ch];
            let b = t[ch];
            if a.abs() > 1e-3 {
                checked += 1;
                let ratio = b / a;
                assert!(
                    (ratio - g).abs() <= 1e-5,
                    "frame {i} ch {ch}: ratio {ratio} != db_to_lin(-6) = {g} \
                     (a={a}, b={b})"
                );
            } else {
                // Where the unity bounce is (near-)silent the trimmed one must
                // be too: the fader must scale ONLY the bus's contribution,
                // never add anything.
                assert!(
                    b.abs() <= 1e-3,
                    "frame {i} ch {ch}: signal appeared where unity had none (b={b})"
                );
            }
        }
    }
    assert!(
        checked > 50_000,
        "only {checked} samples carried signal; the ratio proof is too thin"
    );

    // The aggregate, in one number: RMS scales by exactly the fader, and
    // -6 dB is, measurably, a halving (10^(-6/20) = 0.5012).
    let ratio = rms(&trimmed) / rms(&unity);
    assert!(
        (ratio - f64::from(g)).abs() < 1e-6,
        "RMS ratio {ratio} != {g}"
    );
    assert!(
        (0.499..0.502).contains(&ratio),
        "a -6 dB fader must halve the bus's contribution (got {ratio})"
    );
}

// ---------------------------------------------------------------------------
// Undo restores the prior gain exactly — through the full path.
// ---------------------------------------------------------------------------

#[test]
fn undo_restores_the_prior_fader_bit_exactly() {
    let (mut host, _) = host_with_grouped_tone("NodeFaderUndo");
    // A non-default prior, so the inverse carries a real value, then a second
    // set on top of it.
    host.submit(
        user(),
        "route.node.set",
        json!({"nodeId": "grp", "gainDb": -3.5}),
    )
    .unwrap();
    let before = host.render_master().unwrap();
    host.submit(
        user(),
        "route.node.set",
        json!({"nodeId": "grp", "gainDb": -9.0}),
    )
    .unwrap();
    let deep = host.render_master().unwrap();
    assert_ne!(
        digest(&before),
        digest(&deep),
        "the second set was inaudible — the push is dead and every later \
         assertion here would be vacuous"
    );

    assert!(host.undo(user()).unwrap(), "undo had nothing to undo");
    assert_eq!(
        serde_json::to_string(&host.project().routing.nodes[0].gain_db).unwrap(),
        "-3.5",
        "undo must restore the prior model value shape-exactly"
    );
    let after_undo = host.render_master().unwrap();
    assert_eq!(
        digest(&after_undo),
        digest(&before),
        "undo of route.node.set did not restore the prior BOUNCE bit-exactly"
    );
}

// ---------------------------------------------------------------------------
// Persistence: the fader survives save -> reopen ON DISK, audibly.
// ---------------------------------------------------------------------------

/// The E0 §9.3 bug, asserted on samples: a saved fader that reopens at unity
/// means `package.rs` wrote the field and did not read it (or neither).
#[test]
fn a_saved_fader_reopens_at_the_same_gain_not_unity() {
    let (mut host, pkg) = host_with_grouped_tone("NodeFaderPersist");
    host.submit(
        user(),
        "route.node.set",
        json!({"nodeId": "grp", "gainDb": -6.0}),
    )
    .unwrap();
    let before = host.render_master().unwrap();
    host.save().unwrap();
    drop(host);

    let reopened = StudioHost::open_package(&pkg).unwrap();
    assert_eq!(
        serde_json::to_string(&reopened.project().routing.nodes[0].gain_db).unwrap(),
        "-6.0",
        "the reopened model lost the fader (write-without-read, E0 §9.3)"
    );
    let after = reopened.render_master().unwrap();
    assert_eq!(
        digest(&after),
        digest(&before),
        "the reopened project does not BOUNCE identically — a saved fader \
         that reopens at unity is silent data destruction"
    );
}

// ---------------------------------------------------------------------------
// Chunk independence: bit-identical at 128 / 417 / 480 / 512.
// ---------------------------------------------------------------------------

/// The engine invariant (§6.1) with the fader ACTIVE, through the host's own
/// compile + production `sync_params` push. The existing full-graph test pins
/// chunk independence with the fader at DEFAULT; this pins it at -6 dB, where
/// a per-block gain shortcut would first become visible.
#[test]
fn a_trimmed_bus_bounces_bit_identically_at_128_417_480_512() {
    let (mut host, _) = host_with_grouped_tone("NodeFaderChunks");
    host.submit(
        user(),
        "route.node.set",
        json!({"nodeId": "grp", "gainDb": -6.0}),
    )
    .unwrap();

    let project = host.project();
    let max_tracks = project.tracks.len().max(1);
    let total: u64 = 96_000; // 2 s @ 48k — plenty of signal, fast to render
    let mut digests = Vec::new();
    for chunk in [128usize, 417, 480, 512] {
        // A fresh compile per renderer (the session moves into the engine),
        // from the host's OWN model + sources, exactly as render_master does.
        let session = compile_session_full(
            project,
            host.sources(),
            &WarpOverlay::new(),
            &AutomationStore::new(),
            max_tracks,
            render::compile::DeclickPolicy::Auto,
        )
        .expect("compile");
        let cfg = EngineConfig {
            sample_rate: project.sample_rate,
            max_tracks,
            ..EngineConfig::default()
        };
        let mut renderer = ManualRenderer::new(&cfg);
        // The PRODUCTION push: host state -> atomics, including
        // sync_graph_params' node-fader loop.
        host.sync_params(renderer.params());
        let audio = render_offline_with(
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
            total,
            chunk,
        );
        assert_eq!(audio.len() as u64, total);
        digests.push((chunk, digest(&audio)));
    }
    let reference = &digests[0].1;
    let peak_probe = digests.iter().all(|(_, d)| d == reference);
    assert!(
        peak_probe,
        "a -6 dB bus fader is chunk-DEPENDENT: {digests:?}"
    );
}
