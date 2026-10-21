//! INERT LANES: a lane that compiles into a slot must reach the audio, or be
//! REFUSED. Never silently ignored.
//!
//! The shipped defect: `track.send.a.level` was journaled, moved the control,
//! updated the model, and got a real dense slot with a real cursor in
//! `build_lane_index` — and `RenderCore::render` read only `LANE_VOLUME` and
//! `LANE_PAN`, so a 0->1 send ramp rendered **bit-identically to no automation
//! at all**. That is the solo bug's exact shape: a UI-state path that updates
//! while nothing reaches the audio, with a green model-state test over it.
//!
//! So every audibility assertion in this file compares RENDERED SAMPLES. A test
//! that asserts a lane exists, or that a slot was assigned, or that a value was
//! stored, is precisely the kind of test that let this ship, and is marked as
//! structural (not evidence) where one appears.
//!
//! # Which production hops these seams traverse (E5 sec 12.5 honesty)
//!
//! | Seam | Traverses | SKIPS |
//! |---|---|---|
//! | `compile_session_full` + `render_offline_with` | model -> snapshot -> `RenderCommand` channel -> `drain_commands` -> `install_session` -> the one `RenderCore::render` | `sync_after_mutation` -> `push_live_session`; cpal callback |
//! | `EngineParams` set directly | the atomic store + block-boundary load | `host.rs::sync_params` — so nothing here proves the HOST pushes anything |
//!
//! The host half is `agent-surface/tests/send_automation_audible.rs`, which
//! drives `autopoint.add` through the real command bus. Without it this file
//! would prove the renderer and prove nothing about a user pressing a button —
//! which is exactly how the solo bug survived.

use std::collections::HashMap;
use std::sync::Arc;

use render::automation::{
    AutomationStore, CurveKind, RawPoint, TRACK_PAN, TRACK_SEND_A_LEVEL, TRACK_SEND_B_LEVEL,
    TRACK_VOLUME,
};
use render::compile::{compile_session_full, DeclickPolicy};
use render::engine::EngineConfig;
use render::guard;
use render::media::AudioBuf;
use render::offline::{render_offline_with, residual, ManualRenderer, ScheduledCommand};
use render::params::EngineParams;
use render::rt::{lane_has_reader, RenderCommand, ENGINE_SAMPLE_RATE};
use render::warp::WarpOverlay;
use timeline_core::{Bpm, Command, FadeShape, Project, Source, TempoMap};

// The counting allocator only observes anything when it IS the binary's global
// allocator; without this the alloc assertion below is vacuously green
// (`render/tests/solo.rs:29-31` documents the trap).
#[global_allocator]
static ALLOC: guard::CountingAlloc = guard::CountingAlloc;

const LEN: u64 = 96_000;
const LEVEL: f32 = 0.5;
/// 2 bars at 120 bpm / 960 PPQ; the ramp spans the whole rendered region.
const RAMP_END_TICKS: u64 = 3_840;

fn project_120() -> Project {
    Project::new(
        ENGINE_SAMPLE_RATE,
        TempoMap::single(Bpm::from_int(120).unwrap()),
    )
}

/// One track carrying a constant-DC clip, so every level in the mix is
/// identifiable by inspection rather than by a spectrum.
fn dc_project() -> (Project, HashMap<String, Arc<AudioBuf>>) {
    let mut project = project_120();
    let mut sources = HashMap::new();
    let audio = AudioBuf::from_samples(vec![[LEVEL, LEVEL]; LEN as usize], "dc");
    project
        .add_source(Source {
            id: "dc".into(),
            path: "synthetic:dc".into(),
            len_frames: audio.len_frames(),
        })
        .unwrap();
    sources.insert("dc".to_string(), audio);
    project
        .apply(&Command::TrackAdd {
            track_id: "t1".into(),
            name: "t1".into(),
            index: None,
        })
        .unwrap();
    project
        .apply(&Command::ClipPlace {
            track_id: "t1".into(),
            clip_id: "c1".into(),
            source_id: "dc".into(),
            start_tick: None,
            start_frame: Some(0),
            offset_frames: 0,
            len_frames: LEN,
            gain_db: 0.0,
            fade_in_frames: 0,
            fade_out_frames: 0,
            fade_shape: FadeShape::EqualPower,
        })
        .unwrap();
    (project, sources)
}

fn point(tick: u64, value: f32) -> RawPoint {
    RawPoint {
        tick,
        value,
        curve: CurveKind::Linear,
    }
}

fn compile(
    p: &Project,
    sources: &HashMap<String, Arc<AudioBuf>>,
    a: &AutomationStore,
) -> Box<render::rt::RtSession> {
    compile_session_full(
        p,
        sources,
        &WarpOverlay::new(),
        a,
        EngineConfig::default().max_tracks,
        DeclickPolicy::None,
    )
    .expect("compiles")
}

fn try_compile(
    p: &Project,
    sources: &HashMap<String, Arc<AudioBuf>>,
    a: &AutomationStore,
) -> Result<Box<render::rt::RtSession>, String> {
    compile_session_full(
        p,
        sources,
        &WarpOverlay::new(),
        a,
        EngineConfig::default().max_tracks,
        DeclickPolicy::None,
    )
}

/// Render `LEN` frames of the DC project with `automation` baked in and
/// `setup` applied to the atomics, at `chunk` frames per block.
fn render(automation: &AutomationStore, setup: impl Fn(&EngineParams), chunk: usize) -> Vec<[f32; 2]> {
    let (project, sources) = dc_project();
    let session = compile(&project, &sources, automation);
    let cfg = EngineConfig::default();
    let mut renderer = ManualRenderer::new(&cfg);
    setup(renderer.params());
    render_offline_with(
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
        LEN,
        chunk,
    )
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

// ---------------------------------------------------------------------------
// THE BUG: a send ramp must change the rendered samples.
// ---------------------------------------------------------------------------

/// ⚠️ **This test asserts the INVERSE of what the tree did before this fix.**
/// A 0->1 ramp on `track.send.a.level` used to render bit-identically to no
/// automation at all; that bit-identity was the bug.
#[test]
fn a_send_a_ramp_changes_the_rendered_buffer() {
    let dry = render(&AutomationStore::new(), |_| {}, 512);

    let mut a = AutomationStore::new();
    a.add_point_path("t1", TRACK_SEND_A_LEVEL, point(0, 0.0));
    a.add_point_path("t1", TRACK_SEND_A_LEVEL, point(RAMP_END_TICKS, 1.0));
    let ramped = render(&a, |_| {}, 512);

    let r = residual(&dry, &ramped);
    assert!(
        !r.bit_identical,
        "a 0->1 send ramp rendered bit-identically to no automation: the lane is INERT"
    );
    assert!(
        r.max_abs > 0.01,
        "the send ramp moved the mix by only {} (peak {} dBFS) — that is not audible",
        r.max_abs,
        r.peak_dbfs
    );

    // And it must GROW: the reverb send opens over the ramp, so the wet
    // contribution (ramped - dry) has to be far larger at the end than at the
    // start. A constant offset would satisfy "not bit-identical" and would not
    // be a ramp.
    let n = dry.len();
    let early = energy(&dry, &ramped, 0..n / 8);
    let late = energy(&dry, &ramped, n - n / 8..n);
    assert!(
        late > early * 50.0,
        "send ramp energy did not grow with the ramp: early {early:.6}, late {late:.6}"
    );
}

#[test]
fn a_send_b_ramp_changes_the_rendered_buffer() {
    let dry = render(&AutomationStore::new(), |_| {}, 512);

    let mut a = AutomationStore::new();
    a.add_point_path("t1", TRACK_SEND_B_LEVEL, point(0, 0.0));
    a.add_point_path("t1", TRACK_SEND_B_LEVEL, point(RAMP_END_TICKS, 1.0));
    let ramped = render(&a, |_| {}, 512);

    let r = residual(&dry, &ramped);
    assert!(!r.bit_identical, "bus B send lane is INERT");
    assert!(
        r.max_abs > 0.01,
        "the bus B send ramp moved the mix by only {}",
        r.max_abs
    );
}

/// The lane is an ABSOLUTE level that OVERRIDES the fader atomic — the
/// convention `render_instrument_frame` already uses for device params, not
/// volume's dB-offset one.
///
/// ⚠️ Note on the install snap, which shapes how these assertions are written:
/// `install_session` (`rt.rs:753-768`) deliberately snaps `strip.send_a` to the
/// ATOMIC, not to frame-0 automation — "for the same reason the strip snaps to
/// the atomic target and not to the volume lane: automation then ramps in over
/// the 5 ms declick window like every other parameter move." A send lane
/// therefore GLIDES from the fader's value to the lane's over 240 frames, which
/// is exactly what a volume lane already does. So the bit-exact assertion below
/// holds the snap constant, and the override assertion is an energy comparison
/// against four references instead.
#[test]
fn a_send_lane_overrides_the_fader_atomic_absolutely() {
    // (a) EXACT: with the fader and the lane both at 0.8 — same install snap —
    //     the lane render is bit-identical to the no-lane render. So a lane
    //     value lands in the same place, through the same slew, with the same
    //     arithmetic, and is not scaled or offset by anything on the way.
    let no_lane = render(&AutomationStore::new(), |p| p.set_track_send(0, false, 0.8), 512);
    let mut lane = AutomationStore::new();
    lane.add_point_path("t1", TRACK_SEND_A_LEVEL, point(0, 0.8));
    let with_lane = render(&lane, |p| p.set_track_send(0, false, 0.8), 512);
    assert!(
        residual(&no_lane, &with_lane).bit_identical,
        "a lane pinned at the fader's own value must be a no-op, bit for bit"
    );
    // Non-vacuity: that render is not silence and the send really is audible.
    let dry = render(&AutomationStore::new(), |_| {}, 512);
    assert!(
        !residual(&dry, &no_lane).bit_identical,
        "the 0.8 send is inaudible even from the fader — the equality above is vacuous"
    );

    // (b) WHICH VALUE WINS. Fader at 0.4, lane pinned at 0.8. Four candidate
    //     conventions predict four different sends:
    //        absolute override -> 0.8      (what this build must do)
    //        multiply          -> 0.32
    //        dB-offset like volume, or additive -> 1.0 (1.2, clamped)
    //        ignored (the BUG) -> 0.4
    //     Render a static reference for each and assert the automated render is
    //     closest to 0.8 by a wide margin.
    let mut pinned = AutomationStore::new();
    pinned.add_point_path("t1", TRACK_SEND_A_LEVEL, point(0, 0.8));
    let automated = render(&pinned, |p| p.set_track_send(0, false, 0.4), 512);

    let n = automated.len();
    // Skip the 5 ms declick glide; compare where the send has settled.
    let window = 4_800..n;
    let mut scored: Vec<(&str, f64)> = Vec::new();
    for (name, level) in [
        ("override 0.8", 0.8_f32),
        ("multiply 0.32", 0.32),
        ("additive 1.0", 1.0),
        ("ignored 0.4", 0.4),
    ] {
        let reference = render(&AutomationStore::new(), move |p| p.set_track_send(0, false, level), 512);
        scored.push((name, energy(&automated, &reference, window.clone())));
    }
    scored.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap());
    assert_eq!(
        scored[0].0, "override 0.8",
        "the send lane does not override the fader absolutely; distances were {scored:?}"
    );
    assert!(
        scored[1].1 > scored[0].1 * 100.0,
        "the winning convention is not decisively closest: {scored:?}"
    );
}

/// Out-of-range drawn points are clamped to the same 0..=1 range `mix.send` and
/// `EngineParams::set_track_send` clamp to. A negative send level would flip
/// polarity into the bus.
#[test]
fn a_send_lane_is_clamped_to_the_faders_range() {
    let mut at_one = AutomationStore::new();
    at_one.add_point_path("t1", TRACK_SEND_A_LEVEL, point(0, 1.0));
    let unity = render(&at_one, |_| {}, 512);

    let mut too_hot = AutomationStore::new();
    too_hot.add_point_path("t1", TRACK_SEND_A_LEVEL, point(0, 7.5));
    assert!(
        residual(&unity, &render(&too_hot, |_| {}, 512)).bit_identical,
        "a lane above 1.0 must clamp to 1.0"
    );

    let dry = render(&AutomationStore::new(), |_| {}, 512);
    let mut negative = AutomationStore::new();
    negative.add_point_path("t1", TRACK_SEND_A_LEVEL, point(0, -3.0));
    assert!(
        residual(&dry, &render(&negative, |_| {}, 512)).bit_identical,
        "a negative lane value must clamp to 0.0, not invert into the bus"
    );
}

// ---------------------------------------------------------------------------
// The invariant this fix is most able to break.
// ---------------------------------------------------------------------------

/// **ALL signal state advances per FRAME.** A send level read once per block
/// instead of once per frame passes every casual test above and fails here.
#[test]
fn send_automation_bounces_bit_identically_at_128_417_480_512() {
    let mut a = AutomationStore::new();
    a.add_point_path("t1", TRACK_SEND_A_LEVEL, point(0, 0.0));
    a.add_point_path("t1", TRACK_SEND_A_LEVEL, point(RAMP_END_TICKS, 1.0));
    a.add_point_path("t1", TRACK_SEND_B_LEVEL, point(0, 1.0));
    a.add_point_path("t1", TRACK_SEND_B_LEVEL, point(RAMP_END_TICKS, 0.0));
    // Volume and pan lanes too, so the send slots are NOT slots 0/1 and a
    // cursor mixed up between lanes would show here.
    a.add_point_path("t1", TRACK_VOLUME, point(0, -6.0));
    a.add_point_path("t1", TRACK_VOLUME, point(RAMP_END_TICKS, 0.0));
    a.add_point_path("t1", TRACK_PAN, point(0, -0.8));
    a.add_point_path("t1", TRACK_PAN, point(RAMP_END_TICKS, 0.8));

    let setup = |p: &EngineParams| {
        p.set_track_eq(0, 2, 2_500.0, -5.0, 0.9);
        p.set_master_gain_db(-1.0);
        p.set_limiter(true, -1.0, 50.0);
    };

    let reference = render(&a, setup, 128);
    // NON-SILENCE GATE: a parity test over silence is vacuous, and that false
    // green has been caught twice in this program.
    let peak = reference
        .iter()
        .flat_map(|f| [f[0].abs(), f[1].abs()])
        .fold(0.0_f32, f32::max);
    assert!(peak > 0.05, "the parity reference is silence (peak {peak})");

    for block in [417_usize, 480, 512] {
        let other = render(&a, setup, block);
        let r = residual(&reference, &other);
        assert!(
            r.bit_identical,
            "send automation must bounce bit-identically at block {block} \
             (peak residual {} dBFS, max_abs {}) — a per-BLOCK lane read does \
             exactly this",
            r.peak_dbfs, r.max_abs
        );
    }
}

/// A project with no automation on a send path must render EXACTLY as it did
/// before the reader existed. This is the regression gate on the fix.
#[test]
fn a_project_without_send_automation_is_unaffected() {
    let setup = |p: &EngineParams| {
        p.set_track_gain_db(0, -2.0);
        p.set_track_pan(0, 0.35);
        p.set_track_eq(0, 2, 2_500.0, -5.0, 0.9);
        p.set_track_send(0, false, 0.4);
        p.set_track_send(0, true, 0.3);
        p.set_master_gain_db(-1.0);
        p.set_limiter(true, -1.0, 50.0);
    };
    // Volume + pan automation present; NO send lane. The send slots are `None`
    // and the atomics must be the only source, byte for byte.
    let mut a = AutomationStore::new();
    a.add_point_path("t1", TRACK_VOLUME, point(0, -6.0));
    a.add_point_path("t1", TRACK_VOLUME, point(RAMP_END_TICKS, 0.0));
    a.add_point_path("t1", TRACK_PAN, point(0, -0.8));
    a.add_point_path("t1", TRACK_PAN, point(RAMP_END_TICKS, 0.8));

    for block in [128_usize, 417, 480, 512] {
        let r = residual(&render(&a, setup, block), &render(&a, setup, 128));
        assert!(r.bit_identical, "unautomated-send render moved at block {block}");
    }
    // (The cross-branch bit-identity against feat/ms-342 is asserted out of
    // band, by rendering this same fixture on both branches and comparing the
    // digests — see the lane report.)
}

/// RT rule: no allocation on the audio thread, with send automation live.
#[test]
fn rendering_send_automation_allocates_nothing() {
    let mut a = AutomationStore::new();
    a.add_point_path("t1", TRACK_SEND_A_LEVEL, point(0, 0.0));
    a.add_point_path("t1", TRACK_SEND_A_LEVEL, point(RAMP_END_TICKS, 1.0));
    a.add_point_path("t1", TRACK_SEND_B_LEVEL, point(0, 1.0));
    a.add_point_path("t1", TRACK_SEND_B_LEVEL, point(RAMP_END_TICKS, 0.0));

    // POSITIVE CONTROL first: the counter must be able to move at all, or the
    // negative assertion below is decoration.
    let control_before = guard::violations();
    guard::enter_render_scope();
    let canary: Vec<u8> = Vec::with_capacity(64);
    std::hint::black_box(&canary);
    guard::leave_render_scope();
    assert!(
        guard::violations() > control_before,
        "the counting allocator is not installed; the assertion below would be vacuous"
    );
    drop(canary);

    // Build and compile OUTSIDE the measured window (both allocate, control-side).
    let (project, sources) = dc_project();
    let session = compile(&project, &sources, &a);
    let cfg = EngineConfig::default();
    let mut renderer = ManualRenderer::new(&cfg);
    let before = guard::violations();
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
        LEN,
        512,
    );
    assert_eq!(
        guard::violations() - before,
        0,
        "send automation allocated on the audio thread"
    );
    assert!(!out.is_empty());
}

// ---------------------------------------------------------------------------
// The other half of the lesson: refuse loudly, never silently ignore.
// ---------------------------------------------------------------------------

/// STRUCTURAL (not audio evidence): the reader set and the refusal set are one
/// list, so a path cannot be added to `lane_has_reader` without a reader, nor
/// silently accepted without one.
///
/// The audit that produced this table drove every path through the real command
/// bus and compared bounce bytes; the results are recorded in the lane report.
#[test]
fn the_reader_set_is_exactly_the_paths_that_reach_the_audio() {
    for path in [
        "track.volume",
        "track.pan",
        "track.send.a.level",
        "track.send.b.level",
        "track.device.d1.cutoff",
        "track.device.d1.gain",
        "track.device.d1.waveform",
        // E5-graph: the graph walk over `node_order` now runs, so a routing
        // node's fader and a track-sourced edge level both reach the audio.
        "bus.b1.gain",
        "route.edge.e1.level",
        // fx-param-automation: `run_fx_chain` drives `FxNode::set_frame_param`
        // from `RtFx::lanes` per FRAME, for keys whose application is
        // arithmetic or a change-cached dB conversion — on all three host
        // spellings. Every key here is audibility-proven per (kind, key) in
        // `render/tests/graph.rs`.
        "track.fx.f1.threshold",
        "track.fx.f1.ratio",
        "track.fx.f1.makeup",
        "track.fx.f1.mix",
        "track.fx.f1.gain",
        "track.fx.f1.time",
        "bus.b1.fx.f1.threshold",
        "bus.b1.fx.f1.mix",
        "bus.b1.fx.f1.damping",
        "master.fx.f1.threshold",
        "master.fx.f1.drive",
        "master.fx.f1.ceiling",
    ] {
        assert!(lane_has_reader(path), "{path} should have a reader");
    }
    for path in [
        // No per-frame coefficient path (block-rate `retarget_band_checked`).
        "track.eq.0.gain",
        "track.eq.1.freq",
        "track.eq.3.q",
        // Global parameters with a per-TRACK lane store: ambiguous owner.
        "master.gain",
        "master.limiter.ceiling",
        "master.limiter.release",
        // Fx keys whose application recomputes a filter or envelope
        // COEFFICIENT stay refused BY KEY — `coeff_from_ms` is an `exp` and an
        // EQ band retarget is RBJ trig, the same cost cliff that keeps
        // `track.eq.*` in the list above. The refusal is per key: the same fx
        // instance's threshold/mix/... ARE readable.
        "track.fx.f1.attack",
        "track.fx.f1.release",
        "bus.b1.fx.f1.release",
        "master.fx.f1.band0Freq",
        "track.fx.f1.band3Q",
        // `bypass` occupies NO parameter slot (§23.5) — a lane on it would be
        // a third spelling of one fact.
        "track.fx.f1.bypass",
        "master.fx.f1.bypass",
        // Vocabulary no kind implements: nothing exists for a lane to drive.
        "track.fx.f1.division",
        "track.fx.f1.zorp",
        // Not a parameter at all.
        "track.send.c.level",
        "quantum.flux.capacitor",
        "not a path",
    ] {
        assert!(!lane_has_reader(path), "{path} must NOT claim a reader");
    }
}

/// The fx half of the reader set is DERIVED, not hand-listed: for every key in
/// the fx vocabulary and every host spelling, `lane_has_reader` must agree
/// with `dsp::fx::fx_key_class` — the one classification, computed from the
/// same `FxParamSpec` tables `load_block_targets` reads. A refusal set that
/// drifted from the reader set (a key flipped in one place but not the other)
/// fails here by construction. STRUCTURAL; the per-(kind, key) audibility of
/// the Frame class is proven on rendered samples in `render/tests/graph.rs`.
#[test]
fn the_fx_reader_set_is_exactly_the_frame_rate_key_class() {
    use render::dsp::fx::{all_fx_param_keys, fx_key_class, FxKeyClass};
    let mut keys = all_fx_param_keys();
    // `division` is model vocabulary no kind implements; it must classify (and
    // refuse) like any other unimplemented key even though `all_fx_param_keys`
    // does not emit it.
    keys.push("division");
    for key in keys {
        let readable = fx_key_class(key) == FxKeyClass::Frame;
        for path in [
            format!("track.fx.f1.{key}"),
            format!("bus.b1.fx.f1.{key}"),
            format!("master.fx.f1.{key}"),
        ] {
            assert_eq!(
                lane_has_reader(&path),
                readable,
                "{path}: lane_has_reader disagrees with fx_key_class — the reader \
                 set and the refusal set have drifted apart"
            );
        }
    }
}

/// A lane nothing can render is REFUSED at compile, by name, with the reason —
/// not handed a dense slot and a live cursor that nothing will ever read.
#[test]
fn a_lane_with_no_reader_is_refused_loudly() {
    let (project, sources) = dc_project();
    for (path, must_mention) in [
        ("track.eq.1.gain", "per FRAME"),
        ("master.gain", "GLOBAL"),
        ("master.limiter.ceiling", "GLOBAL"),
        // Coefficient-class fx keys: refused BY KEY, and the reason must say
        // both why THIS key is out and that arithmetic-class keys are not.
        ("track.fx.f1.attack", "COEFFICIENT"),
        ("track.fx.f1.release", "cost cliff"),
        ("bus.b1.fx.f1.band2Q", "RBJ"),
        ("master.fx.f1.release", "COEFFICIENT"),
        // `bypass` has no parameter slot at all (§23.5).
        ("track.fx.f1.bypass", "NO parameter slot"),
        // Vocabulary no kind implements.
        ("track.fx.f1.division", "no effect kind implements"),
    ] {
        let mut a = AutomationStore::new();
        a.add_point_path("t1", path, point(0, 0.0));
        a.add_point_path("t1", path, point(RAMP_END_TICKS, 1.0));
        let err = try_compile(&project, &sources, &a)
            .err()
            .unwrap_or_else(|| panic!("{path}: compiled, so the lane is silently INERT again"));
        assert!(err.contains(path), "{path}: refusal does not name the path: {err}");
        assert!(
            err.contains(must_mention),
            "{path}: refusal does not say WHY ({must_mention}): {err}"
        );
        assert!(
            err.contains("autolane.clear"),
            "{path}: refusal does not say how to proceed: {err}"
        );
    }
}

// ---------------------------------------------------------------------------
// The KIND-AWARE half of the fx-lane refusal (`compile::bake_fx_lanes`).
// `lane_has_reader` is a pure path function and cannot see which FxKind an fx
// id resolves to, so a readable KEY can still bind to nothing: a missing fx,
// a kind that does not declare the key, or an ambiguous session-scoped owner.
// Each of those must refuse LOUDLY at compile — a binding nothing reads is the
// original sin of this file.
// ---------------------------------------------------------------------------

/// A readable key on an fx id the host does not carry: refused by name (the
/// dangling `route.edge.<id>.level` precedent), not compiled into silence.
#[test]
fn an_fx_lane_naming_a_missing_fx_is_refused_loudly() {
    let (project, sources) = dc_project();
    let mut a = AutomationStore::new();
    a.add_point_path("t1", "track.fx.ghost.mix", point(0, 0.0));
    a.add_point_path("t1", "track.fx.ghost.mix", point(RAMP_END_TICKS, 1.0));
    let err = try_compile(&project, &sources, &a)
        .err()
        .expect("a lane on a missing fx compiled: it is silently INERT");
    assert!(err.contains("track.fx.ghost.mix"), "not named: {err}");
    assert!(err.contains("ghost"), "fx id not named: {err}");
    assert!(err.contains("autolane.clear"), "no way forward: {err}");
}

/// A readable key on a kind that does not declare it (`mix` on an Eq): §16.3
/// forbids validating the (kind, key) pairing at apply time — apply runs on
/// replay — so the pairing is enforced HERE, render-side, where refusing
/// cannot break an open. The message names the kind, so the user learns why a
/// key that works on their compressor does nothing on their EQ.
#[test]
fn an_fx_lane_on_a_key_its_kind_ignores_is_refused_loudly_with_the_kind_named() {
    use timeline_core::cmd::Cmd;
    use timeline_core::model::FxKind;
    use timeline_core::NodeRef;

    let (mut project, sources) = dc_project();
    project
        .apply_cmd(&Cmd::FxAdd {
            target: NodeRef::parse("track.t1").unwrap(),
            fx_id: "e1".into(),
            kind: FxKind::Eq,
        })
        .unwrap();
    let mut a = AutomationStore::new();
    a.add_point_path("t1", "track.fx.e1.mix", point(0, 0.0));
    a.add_point_path("t1", "track.fx.e1.mix", point(RAMP_END_TICKS, 1.0));
    let err = try_compile(&project, &sources, &a)
        .err()
        .expect("a lane on a key its kind ignores compiled: it is silently INERT");
    assert!(err.contains("track.fx.e1.mix"), "not named: {err}");
    assert!(err.contains("'eq'"), "the kind is not named: {err}");
    assert!(err.contains("autolane.clear"), "no way forward: {err}");
}

/// A `bus.*.fx.*` / `master.fx.*` parameter is SESSION-scoped, but the lane
/// store is keyed (track, path): two tracks carrying the same master-fx lane
/// is refused (the `bus.<id>.gain` precedent), never resolved by iteration
/// luck. The same path on two tracks' OWN chains (`track.fx.*`) is fine — the
/// path is track-relative — and the second half proves that compiles.
#[test]
fn a_session_scoped_fx_lane_on_two_tracks_is_refused_and_track_fx_lanes_are_not() {
    use timeline_core::cmd::Cmd;
    use timeline_core::model::FxKind;
    use timeline_core::{Command, NodeRef};

    let (mut project, sources) = dc_project();
    project
        .apply(&Command::TrackAdd {
            track_id: "t2".into(),
            name: "t2".into(),
            index: None,
        })
        .unwrap();
    project
        .apply_cmd(&Cmd::FxAdd {
            target: NodeRef::parse("master").unwrap(),
            fx_id: "m1".into(),
            kind: FxKind::Utility,
        })
        .unwrap();

    // Ambiguous owner: the same master-fx path on two tracks.
    let mut a = AutomationStore::new();
    a.add_point_path("t1", "master.fx.m1.gain", point(0, -6.0));
    a.add_point_path("t2", "master.fx.m1.gain", point(0, -12.0));
    let err = try_compile(&project, &sources, &a)
        .err()
        .expect("an ambiguous session-scoped fx lane compiled");
    assert!(err.contains("master.fx.m1.gain"), "not named: {err}");
    assert!(
        err.contains("t1") && err.contains("t2"),
        "the owning tracks are not named: {err}"
    );
    assert!(err.contains("autolane.clear"), "no way forward: {err}");

    // Track-relative is NOT ambiguous: each track's identical path binds to
    // its own chain.
    for t in ["t1", "t2"] {
        project
            .apply_cmd(&Cmd::FxAdd {
                target: NodeRef::parse(&format!("track.{t}")).unwrap(),
                fx_id: "u1".into(),
                kind: FxKind::Utility,
            })
            .unwrap();
    }
    let mut a = AutomationStore::new();
    a.add_point_path("t1", "track.fx.u1.gain", point(0, -6.0));
    a.add_point_path("t2", "track.fx.u1.gain", point(0, -12.0));
    // One owner for the master lane this time, so only the track paths are in
    // question.
    a.add_point_path("t1", "master.fx.m1.gain", point(0, -6.0));
    try_compile(&project, &sources, &a)
        .expect("track-relative fx lanes on two tracks must compile");
}

/// The refusal must not be a blanket "anything unusual fails": the paths that
/// DO have a reader still compile, and still get their slot.
#[test]
fn paths_with_a_reader_still_compile_and_still_get_a_slot() {
    let (mut project, sources) = dc_project();
    // The device lane below must RESOLVE: since the dangling-lane sweep, a
    // `track.device.<id>.<key>` lane naming a device the track does not carry
    // is refused (it used to get a dense slot nothing reads).
    project
        .apply_cmd(&timeline_core::cmd::Cmd::DeviceAdd {
            track_id: "t1".into(),
            device_id: "d1".into(),
            kind: timeline_core::model::DeviceKind::Synth,
        })
        .unwrap();
    let mut a = AutomationStore::new();
    a.add_point_path("t1", TRACK_VOLUME, point(0, -6.0));
    a.add_point_path("t1", TRACK_PAN, point(0, 0.2));
    a.add_point_path("t1", TRACK_SEND_A_LEVEL, point(0, 0.4));
    a.add_point_path("t1", TRACK_SEND_B_LEVEL, point(0, 0.6));
    a.add_point_path("t1", "track.device.d1.cutoff", point(0, 800.0));
    let s = compile(&project, &sources, &a);
    assert!(s.lane_index.contains_key(TRACK_SEND_A_LEVEL));
    assert!(s.lane_index.contains_key(TRACK_SEND_B_LEVEL));
    assert_eq!(
        s.send_lane_slots[0].map(usize::from),
        s.lane_index.get(TRACK_SEND_A_LEVEL).copied(),
        "the baked send slot must be the slot the lane index assigned"
    );
    assert_eq!(
        s.send_lane_slots[1].map(usize::from),
        s.lane_index.get(TRACK_SEND_B_LEVEL).copied()
    );
    // No send automation -> no slots -> the atomic path, unchanged.
    let none = compile(&project, &sources, &AutomationStore::new());
    assert_eq!(none.send_lane_slots, [None, None]);
}

// ---------------------------------------------------------------------------
// The RESOLUTION-AWARE half of the sweep (`compile::refuse_unreadable_lanes`
// with `LaneTargets`). `lane_has_reader` is a pure path function: it says the
// `bus.<id>.gain` and `track.device.<id>.<key>` FAMILIES have readers, and it
// cannot see whether `<id>` resolves in THIS project. Since the
// `require_param_ref_on` widening, a dangling lane is forward-legal (stranded
// by `route.node.remove` / `device.remove`, or born of a typo'd id) — and both
// bakes downstream iterate what EXISTS: the node-fader bake never visits a
// lane naming a missing node, and `build_instrument` binds slots from live
// device ids only. Without the sweep, both are the inert-lane defect again.
// ---------------------------------------------------------------------------

/// A `bus.<id>.gain` lane naming no routing node: refused by name with the
/// remedy, not skipped by the node-fader bake without a sound. The same lane
/// on a node that EXISTS still compiles — the false-positive guard.
#[test]
fn a_bus_gain_lane_naming_a_missing_node_is_refused_loudly() {
    use timeline_core::cmd::Cmd;
    use timeline_core::routing::NodeKind;

    let (mut project, sources) = dc_project();
    let mut a = AutomationStore::new();
    a.add_point_path("t1", "bus.nope.gain", point(0, -6.0));
    a.add_point_path("t1", "bus.nope.gain", point(RAMP_END_TICKS, 0.0));
    let err = try_compile(&project, &sources, &a)
        .err()
        .expect("a bus-gain lane naming a MISSING node compiled: silently inert again");
    assert!(err.contains("bus.nope.gain"), "path not named: {err}");
    assert!(err.contains("'nope'"), "the missing node id not named: {err}");
    assert!(err.contains("t1"), "the owning track not named: {err}");
    assert!(err.contains("NOTHING IS LOST"), "recoverability not stated: {err}");
    assert!(err.contains("autolane.clear"), "no way forward: {err}");
    assert!(
        err.contains("route.node.add"),
        "the re-create remedy is missing: {err}"
    );

    // False-positive guard: the identical lane on an EXISTING node compiles.
    project
        .apply_cmd(&Cmd::RouteNodeAdd {
            node_id: "nope".into(),
            kind: NodeKind::Bus,
            name: "Nope Bus".into(),
        })
        .unwrap();
    try_compile(&project, &sources, &a)
        .expect("the same lane must compile once the node exists");
}

/// A `track.device.<id>.<key>` lane naming a device the AUTHORING track does
/// not carry: refused — including when the id exists on a DIFFERENT track,
/// because the lane bakes against its own track and `build_instrument` binds
/// only that track's device. The same lane on the carrying track compiles.
#[test]
fn a_device_lane_naming_a_device_the_track_does_not_carry_is_refused_loudly() {
    use timeline_core::cmd::Cmd;
    use timeline_core::model::DeviceKind;
    use timeline_core::Command;

    let (mut project, sources) = dc_project();
    project
        .apply(&Command::TrackAdd {
            track_id: "t2".into(),
            name: "t2".into(),
            index: None,
        })
        .unwrap();
    // The device exists — but on t2, not on the authoring track t1.
    project
        .apply_cmd(&Cmd::DeviceAdd {
            track_id: "t2".into(),
            device_id: "d1".into(),
            kind: DeviceKind::Synth,
        })
        .unwrap();

    let mut a = AutomationStore::new();
    a.add_point_path("t1", "track.device.d1.cutoff", point(0, 200.0));
    a.add_point_path("t1", "track.device.d1.cutoff", point(RAMP_END_TICKS, 8000.0));
    let err = try_compile(&project, &sources, &a)
        .err()
        .expect("a device lane on a track that does not carry the device compiled");
    assert!(err.contains("track.device.d1.cutoff"), "path not named: {err}");
    assert!(err.contains("'d1'"), "the device id not named: {err}");
    assert!(err.contains("t1"), "the owning track not named: {err}");
    assert!(err.contains("NOTHING IS LOST"), "recoverability not stated: {err}");
    assert!(err.contains("autolane.clear"), "no way forward: {err}");
    assert!(err.contains("device.add"), "the re-add remedy is missing: {err}");

    // False-positive guard: the SAME path authored on the CARRYING track
    // compiles — per-track resolution, not a global id lookup.
    let mut b = AutomationStore::new();
    b.add_point_path("t2", "track.device.d1.cutoff", point(0, 200.0));
    try_compile(&project, &sources, &b)
        .expect("the same lane on the track that carries the device must compile");
}

/// THE STRANDING CASE — closes the residual declared in the first inert-lanes
/// report ("device.remove leaves its automation lanes behind… still silently
/// inert"). The exact five-command journal from the widening's doc: the lane
/// compiles while the device exists, `device.remove` strands it, and the sweep
/// refuses the very next compile instead of handing the lane a dense slot
/// nothing reads.
#[test]
fn removing_a_device_strands_its_lanes_and_the_sweep_refuses_the_next_compile() {
    use timeline_core::cmd::Cmd;
    use timeline_core::model::DeviceKind;

    let (mut project, sources) = dc_project();
    project
        .apply_cmd(&Cmd::DeviceAdd {
            track_id: "t1".into(),
            device_id: "d1".into(),
            kind: DeviceKind::Synth,
        })
        .unwrap();
    let mut a = AutomationStore::new();
    a.add_point_path("t1", "track.device.d1.sustain", point(0, 0.2));
    a.add_point_path("t1", "track.device.d1.sustain", point(RAMP_END_TICKS, 0.9));
    try_compile(&project, &sources, &a).expect("compiles while the device exists");

    project
        .apply_cmd(&Cmd::DeviceRemove {
            track_id: "t1".into(),
            device_id: "d1".into(),
        })
        .unwrap();
    let err = try_compile(&project, &sources, &a)
        .err()
        .expect("the stranded lane compiled after device.remove: silently inert again");
    assert!(err.contains("track.device.d1.sustain"), "path not named: {err}");
    assert!(err.contains("'d1'"), "device id not named: {err}");
    assert!(
        err.contains("undo the device.remove"),
        "the undo remedy is missing: {err}"
    );
}

/// Determinism of the sweep's report when BOTH families offend: the first
/// path in sorted order wins, and the others are counted by name — never
/// iteration luck deciding which error the user sees.
#[test]
fn the_sweep_reports_the_first_offender_deterministically_and_counts_the_rest() {
    let (project, sources) = dc_project();
    let mut a = AutomationStore::new();
    a.add_point_path("t1", "track.device.ghost.cutoff", point(0, 1.0));
    a.add_point_path("t1", "bus.nope.gain", point(0, -6.0));
    a.add_point_path("t1", "master.gain", point(0, -6.0));
    let err = try_compile(&project, &sources, &a).err().expect("must refuse");
    // Sorted: bus.nope.gain < master.gain < track.device.ghost.cutoff.
    assert!(
        err.starts_with("automation lane 'bus.nope.gain'"),
        "first offender is not the sorted-first path: {err}"
    );
    assert!(
        err.contains("2 other unrenderable lane(s)"),
        "the other offenders are not counted: {err}"
    );
    assert!(
        err.contains("master.gain") && err.contains("track.device.ghost.cutoff"),
        "the other offenders are not named: {err}"
    );
}
