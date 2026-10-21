//! Phase 1 render-graph acceptance tests. All manual-clock rendering, no
//! audio device, nothing audible.
//!
//! Covers: mixer bit-exact bypass, EQ/pan/send audible effect, automation
//! sample-accuracy + the 10 Hz square zipper proof, declick invariant on a
//! scripted edit session, session-swap crossfade + gapless adjacency, the
//! master limiter ceiling, LUFS, and the full-graph offline-vs-realtime null
//! test.

use std::collections::HashMap;
use std::sync::Arc;

use render::automation::{AutoLane, AutoPoint, AutoTarget, AutomationStore, CurveKind};
use render::compile::{compile_session, compile_session_full, DeclickPolicy};
use render::dsp::truepeak::TruePeakDetector;
use render::engine::EngineConfig;
use render::loudness::integrated_lufs;
use render::media::AudioBuf;
use render::offline::{render_offline_with, residual, ManualRenderer, ScheduledCommand};
use render::params::EngineParams;
use render::rt::{RenderCommand, ENGINE_SAMPLE_RATE, MICRO_FADE_FRAMES};
use render::warp::WarpOverlay;
use timeline_core::{Bpm, Command, FadeShape, Project, Source, TempoMap};

fn project_120() -> Project {
    Project::new(ENGINE_SAMPLE_RATE, TempoMap::single(Bpm::from_int(120).unwrap()))
}

fn add_synth(
    project: &mut Project,
    sources: &mut HashMap<String, Arc<AudioBuf>>,
    id: &str,
    samples: Vec<[f32; 2]>,
) {
    let audio = AudioBuf::from_samples(samples, id);
    project
        .add_source(Source {
            id: id.into(),
            path: format!("synthetic:{id}"),
            len_frames: audio.len_frames(),
        })
        .unwrap();
    sources.insert(id.to_string(), audio);
}

fn add_track(project: &mut Project, id: &str) {
    project
        .apply(&Command::TrackAdd {
            track_id: id.into(),
            name: id.into(),
            index: None,
        })
        .unwrap();
}

#[allow(clippy::too_many_arguments)]
fn place(
    project: &mut Project,
    track: &str,
    clip: &str,
    source: &str,
    start: u64,
    offset: u64,
    len: u64,
    fade_in: u64,
    fade_out: u64,
) {
    project
        .apply(&Command::ClipPlace {
            track_id: track.into(),
            clip_id: clip.into(),
            source_id: source.into(),
            start_tick: None,
            start_frame: Some(start),
            offset_frames: offset,
            len_frames: len,
            gain_db: 0.0,
            fade_in_frames: fade_in,
            fade_out_frames: fade_out,
            fade_shape: FadeShape::EqualPower,
        })
        .unwrap();
}

fn sine(freq: f32, frames: usize, amp: f32) -> Vec<[f32; 2]> {
    (0..frames)
        .map(|i| {
            let v = (std::f32::consts::TAU * freq * i as f32 / 48_000.0).sin() * amp;
            [v, v]
        })
        .collect()
}

/// Render with an explicit params object and pre-set schedule.
fn render_with(
    session: Box<render::rt::RtSession>,
    params_setup: impl FnOnce(&EngineParams),
    total: u64,
    chunk: usize,
    extra: Vec<ScheduledCommand>,
) -> (Vec<[f32; 2]>, ManualRenderer) {
    let cfg = EngineConfig::default();
    let mut renderer = ManualRenderer::new(&cfg);
    params_setup(renderer.params());
    let mut schedule = vec![
        ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::SetSession(session),
        },
        ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::Play,
        },
    ];
    schedule.extend(extra);
    let out = render_offline_with(&mut renderer, schedule, total, chunk);
    (out, renderer)
}

// ---------------------------------------------------------------------------
// Mixer
// ---------------------------------------------------------------------------

#[test]
fn strip_is_bit_exact_at_defaults() {
    // Default strip (unity gain, center pan, flat EQ, no sends, no limiter)
    // must pass the clip content through untouched: this is why the P0-B
    // sample-exact tests still hold with the full graph.
    let mut project = project_120();
    let mut sources = HashMap::new();
    add_synth(&mut project, &mut sources, "tone", sine(220.0, 20_000, 0.5));
    add_track(&mut project, "t1");
    place(&mut project, "t1", "c1", "tone", 0, 0, 20_000, 0, 0);

    let cfg = EngineConfig::default();
    let session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let (out, _) = render_with(session, |_| {}, 20_000, 128, vec![]);
    // Past the transport ramp, output equals the source exactly.
    let src = sources.get("tone").unwrap();
    for i in (MICRO_FADE_FRAMES as usize)..20_000 {
        assert_eq!(out[i][0].to_bits(), src.samples[i][0].to_bits(), "frame {i}");
    }
}

#[test]
fn pan_hard_left_silences_right() {
    let mut project = project_120();
    let mut sources = HashMap::new();
    add_synth(&mut project, &mut sources, "tone", sine(220.0, 20_000, 0.5));
    add_track(&mut project, "t1");
    place(&mut project, "t1", "c1", "tone", 0, 0, 20_000, 0, 0);

    let cfg = EngineConfig::default();
    let session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let (out, _) = render_with(
        session,
        |p| p.set_track_pan(0, -1.0),
        20_000,
        128,
        vec![],
    );
    // Well past the pan glide: left carries signal, right is silent.
    let left_energy: f32 = out[10_000..].iter().map(|f| f[0].abs()).sum();
    let right_energy: f32 = out[10_000..].iter().map(|f| f[1].abs()).sum();
    assert!(left_energy > 100.0, "left energy {left_energy}");
    assert!(right_energy < 1e-3, "right must be silent, got {right_energy}");
}

#[test]
fn eq_low_shelf_boost_raises_low_energy() {
    let mut project = project_120();
    let mut sources = HashMap::new();
    // A 60 Hz tone: a low-shelf boost should raise its level.
    add_synth(&mut project, &mut sources, "bass", sine(60.0, 48_000, 0.3));
    add_track(&mut project, "t1");
    place(&mut project, "t1", "c1", "bass", 0, 0, 48_000, 0, 0);

    let cfg = EngineConfig::default();
    let flat = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let (dry, _) = render_with(flat, |_| {}, 48_000, 128, vec![]);
    let boosted_session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let (wet, _) = render_with(
        boosted_session,
        |p| p.set_track_eq(0, 0, 80.0, 12.0, 0.71),
        48_000,
        128,
        vec![],
    );
    let dry_rms: f32 =
        (dry[24_000..].iter().map(|f| f[0] * f[0]).sum::<f32>() / 24_000.0).sqrt();
    let wet_rms: f32 =
        (wet[24_000..].iter().map(|f| f[0] * f[0]).sum::<f32>() / 24_000.0).sqrt();
    let gain_db = 20.0 * (wet_rms / dry_rms).log10();
    assert!(
        gain_db > 8.0,
        "low-shelf +12 dB should lift a 60 Hz tone well above 8 dB, got {gain_db}"
    );
}

#[test]
fn reverb_send_produces_a_tail_past_the_clip() {
    let mut project = project_120();
    let mut sources = HashMap::new();
    // Short burst then silence; the reverb send must ring after the clip.
    add_synth(&mut project, &mut sources, "burst", sine(440.0, 2_400, 0.5));
    add_track(&mut project, "t1");
    place(&mut project, "t1", "c1", "burst", 0, 0, 2_400, 0, 100);

    let cfg = EngineConfig::default();
    let session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let (out, _) = render_with(
        session,
        |p| {
            p.set_track_send(0, false, 0.9); // bus A (reverb)
            p.set_return_db(false, 0.0);
        },
        48_000,
        128,
        vec![],
    );
    // Energy after the clip ends (frame 2400) is the reverb tail.
    let tail: f32 = out[6_000..24_000].iter().map(|f| f[0].abs()).sum();
    assert!(tail > 1.0, "reverb send must produce an audible tail: {tail}");
}

// ---------------------------------------------------------------------------
// Automation + zipper proof
// ---------------------------------------------------------------------------

#[test]
fn automation_volume_is_sample_accurate_and_ramps() {
    // A volume lane from -inf(ish) to 0 dB over a known frame span, on a DC
    // source, should produce a linear-in-dB ramp evaluated per sample.
    let mut project = project_120();
    let mut sources = HashMap::new();
    add_synth(&mut project, &mut sources, "dc", vec![[1.0, 1.0]; 48_000]);
    add_track(&mut project, "t1");
    place(&mut project, "t1", "c1", "dc", 0, 0, 48_000, 0, 0);

    let mut store = AutomationStore::new();
    // Volume automation in dB: -24 at tick 0, 0 at tick 1600 (frame 40000,
    // inside the 48000-frame clip). 120 BPM at 48k = 25 frames/tick.
    store.add_point(
        "t1",
        AutoTarget::Volume,
        render::automation::RawPoint {
            tick: 0,
            value: -24.0,
            curve: CurveKind::Linear,
        },
    );
    let end_tick = 1_600_u64;
    store.add_point(
        "t1",
        AutoTarget::Volume,
        render::automation::RawPoint {
            tick: end_tick,
            value: 0.0,
            curve: CurveKind::Linear,
        },
    );
    let end_frame = project.tempo.tick_to_frame(end_tick, 48_000);
    assert_eq!(end_frame, 40_000);

    let cfg = EngineConfig::default();
    let session = compile_session_full(
        &project,
        &sources,
        &WarpOverlay::new(),
        &store,
        cfg.max_tracks,
        DeclickPolicy::None,
    )
    .unwrap();
    let (out, _) = render_with(session, |_| {}, end_frame + 4_000, 128, vec![]);

    // At the end of the ramp, value is 0 dB -> ~1.0 on DC.
    assert!((out[end_frame as usize][0] - 1.0).abs() < 1e-3);
    // Midpoint (in dB) is -12 dB.
    let mid = out[(end_frame / 2) as usize][0];
    let expected = 10.0_f32.powf(-12.0 / 20.0);
    assert!(
        (mid - expected).abs() < 0.02,
        "midpoint {mid} vs expected {expected}"
    );
}

/// The zipper proof: a 10 Hz square automation lane on a DC source. Each edge
/// of the square is a step in the target; the strip's per-frame glide must
/// turn every step into a bounded-slope ramp so no output sample jumps more
/// than the declick slope.
#[test]
fn ten_hz_square_automation_has_no_zipper_steps() {
    let mut project = project_120();
    let mut sources = HashMap::new();
    // Source and clip cover the full render so the proof isolates
    // automation zipper, not the clip-end boundary.
    add_synth(&mut project, &mut sources, "dc", vec![[1.0, 1.0]; 96_000]);
    add_track(&mut project, "t1");
    place(&mut project, "t1", "c1", "dc", 0, 0, 96_000, 0, 0);

    // Build a 10 Hz square directly as an automation lane (frames), pan
    // target alternating -0.9 / +0.9 every half period (2400 frames), using
    // Step segments so the ideal target is a true square.
    let half = 2_400_u64; // 48000 / 10 / 2
    let mut pts = Vec::new();
    for k in 0..40_u64 {
        let value = if k % 2 == 0 { 0.9 } else { -0.9 };
        pts.push(AutoPoint {
            frame: k * half,
            value,
            curve: CurveKind::Step,
        });
    }
    let lane = AutoLane::new(pts).unwrap();

    // Verify the LANE itself is a hard square (steps), so the proof is about
    // the strip glide, not a pre-smoothed source.
    let mut cursor = 0;
    let a = lane.value_at(half - 1, &mut cursor);
    let b = lane.value_at(half, &mut cursor);
    assert!((a - b).abs() > 1.5, "lane really steps by ~1.8 at the edge");

    // Drive the pan through the store on a DC tone and render.
    let mut store = AutomationStore::new();
    for k in 0..40_u64 {
        let value = if k % 2 == 0 { 0.9 } else { -0.9 };
        // Convert frame back to a tick position for the store (120 BPM: 25
        // frames/tick, so these land exactly).
        let tick = project.tempo.frame_to_tick(k * half, 48_000);
        store.add_point(
            "t1",
            AutoTarget::Pan,
            render::automation::RawPoint {
                tick,
                value,
                curve: CurveKind::Step,
            },
        );
    }
    let cfg = EngineConfig::default();
    let session = compile_session_full(
        &project,
        &sources,
        &WarpOverlay::new(),
        &store,
        cfg.max_tracks,
        DeclickPolicy::None,
    )
    .unwrap();
    let (out, _) = render_with(session, |_| {}, 96_000, 128, vec![]);

    // No output sample may step more than the pan glide slope (2/ramp per
    // frame) times the DC level, plus float slack. The pan law adds trig but
    // stays within this bound.
    let max_step = 2.0 / MICRO_FADE_FRAMES as f32 + 0.01;
    let start = MICRO_FADE_FRAMES as usize; // skip the transport fade-in
    let mut worst = 0.0_f32;
    for w in out[start..].windows(2) {
        let step = (w[1][0] - w[0][0]).abs();
        worst = worst.max(step);
    }
    assert!(
        worst <= max_step,
        "zipper: worst per-sample step {worst} exceeds glide bound {max_step}"
    );
    // And it actually moved (the automation is doing something).
    let span = out[start..].iter().map(|f| f[0]).fold(f32::MAX, f32::min)
        ..out[start..].iter().map(|f| f[0]).fold(f32::MIN, f32::max);
    assert!(span.end - span.start > 0.2, "automation actually swings the pan");
}

// ---------------------------------------------------------------------------
// Declick invariant (scripted edit session, Auto policy)
// ---------------------------------------------------------------------------

#[test]
fn declick_invariant_holds_across_a_scripted_edit_session() {
    // Auto policy: a loud clip with hard edges gets implicit 5 ms edge
    // ramps, so playback across its boundaries never steps more than 0.02.
    let mut project = project_120();
    let mut sources = HashMap::new();
    // Loud DC (worst case for boundary clicks).
    add_synth(&mut project, &mut sources, "dc", vec![[0.9, -0.9]; 96_000]);
    add_track(&mut project, "t1");
    // Two hard-edged clips with a gap between them and a butt joint after.
    place(&mut project, "t1", "c1", "dc", 10_000, 0, 8_000, 0, 0);
    place(&mut project, "t1", "c2", "dc", 30_000, 0, 8_000, 0, 0);
    // Butt-joint continuation of c2 (same source, contiguous offset): must
    // stay gapless (no dip) because it is sample-continuous.
    place(&mut project, "t1", "c3", "dc", 38_000, 8_000, 8_000, 0, 0);

    let cfg = EngineConfig::default();
    let session = compile_session_full(
        &project,
        &sources,
        &WarpOverlay::new(),
        &AutomationStore::new(),
        cfg.max_tracks,
        DeclickPolicy::Auto,
    )
    .unwrap();
    let (out, _) = render_with(session, |_| {}, 60_000, 128, vec![]);

    let start = MICRO_FADE_FRAMES as usize;
    for (i, w) in out[start..].windows(2).enumerate() {
        let step = (w[1][0] - w[0][0]).abs();
        assert!(
            step <= 0.02,
            "declick invariant: step {step} at frame {} exceeds 0.02",
            i + start
        );
    }
    // Gapless proof: across the c2->c3 butt joint (frame 38000) the level is
    // the full 0.9, not dipped by an implicit fade.
    assert!(
        out[38_000][0].abs() > 0.85,
        "butt joint dipped: {}",
        out[38_000][0]
    );
}

// ---------------------------------------------------------------------------
// Session swap crossfade
// ---------------------------------------------------------------------------

#[test]
fn identical_session_swap_is_transparent() {
    // Swapping to an identical arrangement mid-play must not perturb output
    // (linear crossfade of identical content to itself).
    let mut project = project_120();
    let mut sources = HashMap::new();
    add_synth(&mut project, &mut sources, "tone", sine(330.0, 48_000, 0.4));
    add_track(&mut project, "t1");
    place(&mut project, "t1", "c1", "tone", 0, 0, 48_000, 0, 0);

    let cfg = EngineConfig::default();
    let s1 = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let s2 = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let mut renderer = ManualRenderer::new(&cfg);
    let out = render_offline_with(
        &mut renderer,
        vec![
            ScheduledCommand { at_frame: 0, command: RenderCommand::SetSession(s1) },
            ScheduledCommand { at_frame: 0, command: RenderCommand::Play },
            ScheduledCommand { at_frame: 20_000, command: RenderCommand::SetSession(s2) },
        ],
        40_000,
        128,
    );
    // Reference: no swap.
    let s_ref = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let mut ref_renderer = ManualRenderer::new(&cfg);
    let reference = render_offline_with(
        &mut ref_renderer,
        vec![
            ScheduledCommand { at_frame: 0, command: RenderCommand::SetSession(s_ref) },
            ScheduledCommand { at_frame: 0, command: RenderCommand::Play },
        ],
        40_000,
        128,
    );
    // A float crossfade of identical content to itself (new*t + old*(1-t))
    // is transparent to ~-140 dBFS but not bit-exact (a few ULPs), so the
    // bar is inaudibility, not bit-identity. It must also not click.
    let r = residual(&out, &reference);
    assert!(
        r.peak_dbfs < -120.0,
        "identical-content swap must be transparent, peak residual {} dBFS",
        r.peak_dbfs
    );
    for w in out.windows(2) {
        assert!((w[1][0] - w[0][0]).abs() < 0.02, "swap must not click");
    }
}

#[test]
fn swap_storm_with_changing_track_counts_is_safe() {
    // Regression: a session swap that lands DURING a crossfade parks as
    // latest-wins and is promoted at the next block boundary. If it has a
    // different track count than the in-flight session, promoting it must
    // not index out of bounds. Drive small blocks so a crossfade spans
    // several blocks and a parked swap promotes mid-crossfade.
    fn session_n_tracks(n: usize) -> Box<render::rt::RtSession> {
        let mut project = project_120();
        let mut sources = HashMap::new();
        add_synth(&mut project, &mut sources, "s", sine(220.0, 48_000, 0.4));
        for i in 0..n {
            let tid = format!("t{i}");
            add_track(&mut project, &tid);
            place(&mut project, &tid, &format!("c{i}"), "s", 0, 0, 48_000, 0, 0);
        }
        let cfg = EngineConfig::default();
        compile_session(&project, &sources, cfg.max_tracks).unwrap()
    }

    let cfg = EngineConfig::default();
    let mut r = ManualRenderer::new(&cfg);
    r.send(RenderCommand::SetSession(session_n_tracks(2)));
    r.send(RenderCommand::Play);
    let mut out = vec![[0.0_f32; 2]; 64]; // blocks smaller than the 240-frame ramp

    // Warm up.
    for _ in 0..4 {
        r.render(&mut out);
    }
    // Storm: queue several swaps with wildly different track counts across a
    // few small blocks so pending-promotion with a count change fires.
    for round in 0..20 {
        r.send(RenderCommand::SetSession(session_n_tracks(1)));
        r.send(RenderCommand::SetSession(session_n_tracks(5)));
        r.send(RenderCommand::SetSession(session_n_tracks(3)));
        r.render(&mut out);
        for f in &out {
            assert!(f[0].is_finite() && f[1].is_finite(), "round {round} produced NaN/inf");
            assert!(f[0].abs() < 8.0, "round {round} runaway output {}", f[0]);
        }
    }
    // Settle and confirm it is still rendering sane audio.
    for _ in 0..40 {
        r.render(&mut out);
    }
    let peak = out.iter().map(|f| f[0].abs()).fold(0.0_f32, f32::max);
    assert!(peak > 0.0 && peak < 8.0, "still rendering after the storm, peak {peak}");
    assert_eq!(r.stats().snapshot().underruns, 0, "no faults during the storm");
}

// ---------------------------------------------------------------------------
// Master limiter
// ---------------------------------------------------------------------------

#[test]
fn master_limiter_holds_the_true_peak_ceiling() {
    let mut project = project_120();
    let mut sources = HashMap::new();
    // Two hot tones summed well above 0 dBFS.
    add_synth(&mut project, &mut sources, "hot", sine(1_000.0, 48_000, 0.9));
    add_track(&mut project, "t1");
    add_track(&mut project, "t2");
    place(&mut project, "t1", "c1", "hot", 0, 0, 48_000, 0, 0);
    place(&mut project, "t2", "c2", "hot", 0, 0, 48_000, 0, 0);

    let cfg = EngineConfig::default();
    let session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let (out, _) = render_with(
        session,
        |p| {
            p.set_master_gain_db(6.0); // push it hotter
            p.set_limiter(true, -1.0, 50.0);
        },
        48_000,
        128,
        vec![],
    );
    let mut det = TruePeakDetector::new();
    let mut tp = 0.0_f32;
    for f in &out[8_000..] {
        tp = tp.max(det.process_frame(*f));
    }
    let tp_db = 20.0 * tp.log10();
    assert!(
        tp_db <= -1.0 + 0.2,
        "master true-peak ceiling -1 dBTP exceeded: {tp_db} dBTP"
    );
    // Still audible (not muted).
    let rms: f32 = (out[8_000..].iter().map(|f| f[0] * f[0]).sum::<f32>()
        / (out.len() - 8_000) as f32)
        .sqrt();
    assert!(rms > 0.2, "limited mix survives, rms {rms}");
}

#[test]
fn integrated_lufs_of_the_bounce_is_reported() {
    let mut project = project_120();
    let mut sources = HashMap::new();
    add_synth(&mut project, &mut sources, "tone", sine(1_000.0, 48_000 * 3, 0.25));
    add_track(&mut project, "t1");
    place(&mut project, "t1", "c1", "tone", 0, 0, 48_000 * 3, 0, 0);
    let cfg = EngineConfig::default();
    let session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let (out, _) = render_with(session, |_| {}, 48_000 * 3, 512, vec![]);
    let lufs = integrated_lufs(&out, 48_000);
    assert!(
        (-40.0..-6.0).contains(&lufs),
        "bounce integrated LUFS out of sane range: {lufs}"
    );
}

// ---------------------------------------------------------------------------
// Full-graph null test
// ---------------------------------------------------------------------------

#[test]
fn full_graph_offline_vs_realtime_null_test() {
    // The whole graph (strips + EQ + sends + buses + master + limiter) must
    // bounce bit-identically to a captured-realtime-style run of the same
    // schedule, at different block sizes.
    let mut project = project_120();
    let mut sources = HashMap::new();
    add_synth(&mut project, &mut sources, "a", sine(220.0, 96_000, 0.4));
    add_synth(&mut project, &mut sources, "b", sine(330.0, 96_000, 0.4));
    add_track(&mut project, "t1");
    add_track(&mut project, "t2");
    place(&mut project, "t1", "c1", "a", 0, 0, 96_000, 2_400, 2_400);
    place(&mut project, "t2", "c2", "b", 10_000, 0, 80_000, 4_800, 9_600);

    let cfg = EngineConfig::default();
    let setup = |p: &EngineParams| {
        p.set_track_gain_db(0, -3.0);
        p.set_track_pan(0, -0.4);
        p.set_track_eq(0, 1, 800.0, 4.0, 1.2);
        p.set_track_send(0, false, 0.3);
        p.set_track_send(1, true, 0.25);
        p.set_master_gain_db(-1.0);
        p.set_limiter(true, -1.0, 50.0);
    };
    let schedule = |session: Box<render::rt::RtSession>| {
        vec![
            ScheduledCommand { at_frame: 0, command: RenderCommand::SetSession(session) },
            ScheduledCommand { at_frame: 0, command: RenderCommand::Play },
            ScheduledCommand {
                at_frame: 24_000,
                command: RenderCommand::LoopSet { start_frame: 30_000, end_frame: 42_000 },
            },
            ScheduledCommand { at_frame: 60_000, command: RenderCommand::LoopClear },
            ScheduledCommand { at_frame: 70_000, command: RenderCommand::Seek { frame: 15_000 } },
        ]
    };
    let total = 96_000;

    let mut rt = ManualRenderer::new(&cfg);
    setup(rt.params());
    let s_rt = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let realtime = render_offline_with(&mut rt, schedule(s_rt), total, 128);

    let mut off = ManualRenderer::new(&cfg);
    setup(off.params());
    let s_off = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let offline = render_offline_with(&mut off, schedule(s_off), total, 512);

    let r = residual(&realtime, &offline);
    assert!(
        r.peak_dbfs < -120.0,
        "full-graph null test: peak residual {} dBFS (max_abs {})",
        r.peak_dbfs,
        r.max_abs
    );
    assert!(r.bit_identical, "full-graph bounce must be bit-identical");

    // Odd chunk as a third witness.
    let mut odd = ManualRenderer::new(&cfg);
    setup(odd.params());
    let s_odd = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let odd_out = render_offline_with(&mut odd, schedule(s_odd), total, 417);
    assert!(residual(&realtime, &odd_out).bit_identical, "chunk independence (417)");

    // The graph produced real signal.
    let peak = realtime.iter().map(|f| f[0].abs()).fold(0.0_f32, f32::max);
    assert!(peak > 0.1, "graph produced signal, peak {peak}");
}

/// THE E1/E2 WIRING GATE, on the FULL graph.
///
/// The test above proves the audio graph nulls. This one adds a track whose
/// only content is MIDI notes driving a synth device, and proves the whole
/// graph — instrument -> strip gain/pan/EQ -> sends -> reverb/delay buses ->
/// master -> limiter — still nulls bit-exactly at 128 / 417 / 480 / 512 while
/// that instrument is playing, across a loop fold and a seek.
///
/// The instrument sums in at the CLIP LAYER, which is why it is subject to the
/// strip EQ and the sends at all. Summing it after the strip would make this
/// test pass and the product wrong.
#[test]
fn full_graph_null_test_with_an_instrument_playing() {
    use timeline_core::cmd::{Cmd, NoteSpec};
    use timeline_core::model::DeviceKind;
    use timeline_core::tempo::PPQ;
    use timeline_core::Num;

    let mut project = project_120();
    let mut sources = HashMap::new();
    add_synth(&mut project, &mut sources, "a", sine(220.0, 96_000, 0.4));
    add_track(&mut project, "t1");
    add_track(&mut project, "t2");
    place(&mut project, "t1", "c1", "a", 0, 0, 96_000, 2_400, 2_400);
    // t2 is MIDI only: no audio clip at all.
    project
        .apply_cmd(&Cmd::DeviceAdd {
            track_id: "t2".into(),
            device_id: "inst1".into(),
            kind: DeviceKind::Synth,
        })
        .unwrap();
    project
        .apply_cmd(&Cmd::ClipPlaceMidi {
            clip_id: "cm1".into(),
            track_id: "t2".into(),
            start_ticks: 0,
            length_ticks: PPQ * 16,
        })
        .unwrap();
    let notes: Vec<NoteSpec> = (0..20u64)
        .map(|i| NoteSpec {
            note_id: format!("n{i}"),
            start_ticks: i * (PPQ / 3),
            length_ticks: PPQ,
            pitch: 45 + (i % 15) as u8,
            velocity: Num::int(70 + (i % 40) as i64),
        })
        .collect();
    project
        .apply_cmd(&Cmd::NoteAdd {
            clip_id: "cm1".into(),
            notes,
        })
        .unwrap();

    let cfg = EngineConfig::default();
    // Route the instrument track through EQ, pan and both sends, so the null
    // covers the whole chain downstream of it.
    let setup = |p: &EngineParams| {
        p.set_track_gain_db(1, -2.0);
        p.set_track_pan(1, 0.35);
        p.set_track_eq(1, 2, 2_500.0, -5.0, 0.9);
        p.set_track_send(1, false, 0.4);
        p.set_track_send(1, true, 0.3);
        p.set_master_gain_db(-1.0);
        p.set_limiter(true, -1.0, 50.0);
    };
    let schedule = |session: Box<render::rt::RtSession>| {
        vec![
            ScheduledCommand { at_frame: 0, command: RenderCommand::SetSession(session) },
            ScheduledCommand { at_frame: 0, command: RenderCommand::Play },
            // The loop is engaged AT RUNTIME and folds under sounding notes;
            // the wrap note-off cannot be baked, so this exercises the
            // per-frame all-notes-off in `rt.rs`.
            ScheduledCommand {
                at_frame: 12_000,
                command: RenderCommand::LoopSet { start_frame: 20_000, end_frame: 44_000 },
            },
            ScheduledCommand { at_frame: 90_000, command: RenderCommand::LoopClear },
            ScheduledCommand { at_frame: 100_000, command: RenderCommand::Seek { frame: 30_000 } },
        ]
    };
    let total = 144_000;

    let mut rt = ManualRenderer::new(&cfg);
    setup(rt.params());
    let s_rt = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let realtime = render_offline_with(&mut rt, schedule(s_rt), total, 128);

    // NON-SILENCE GATE, and specifically an INSTRUMENT gate: mute the audio
    // track and confirm what is left is still real signal. A parity test on
    // silence — or on a mix the instrument never joined — is vacuous, and that
    // false green has already been caught twice in this program.
    let mut solo = ManualRenderer::new(&cfg);
    setup(solo.params());
    solo.params().set_track_mute(0, true);
    let s_solo = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let instrument_only = render_offline_with(&mut solo, schedule(s_solo), total, 128);
    let ipeak = instrument_only.iter().map(|f| f[0].abs()).fold(0.0_f32, f32::max);
    assert!(
        ipeak > 0.02,
        "the instrument produced no audible signal through the full graph (peak {ipeak})"
    );

    for block in [417_usize, 480, 512] {
        let mut other = ManualRenderer::new(&cfg);
        setup(other.params());
        let s = compile_session(&project, &sources, cfg.max_tracks).unwrap();
        let out = render_offline_with(&mut other, schedule(s), total, block);
        let r = residual(&realtime, &out);
        assert!(
            r.bit_identical,
            "full-graph bounce with an instrument playing must be bit-identical \
             at block {block} (peak residual {} dBFS, max_abs {})",
            r.peak_dbfs, r.max_abs
        );
    }
}

/// THE E2 SOURCE-BINDING GATE, on the FULL graph.
///
/// Same shape as the test above, but the instrument is a SAMPLER whose zones
/// name real assets through `device.zone.add`. It proves the binding survives
/// the whole chain — zone -> voice -> strip gain/pan/EQ -> sends ->
/// reverb/delay buses -> master -> limiter — and that the bounce still nulls
/// bit-exactly at 128 / 417 / 480 / 512 across a loop fold and a seek.
///
/// A sampler is the harder case for this gate than a synth: it holds
/// `Arc<AudioBuf>` handles cloned per note-on and advances a FRACTIONAL read
/// position per frame. Any block-rate shortcut in that read would show up here
/// as a null failure and nowhere else.
#[test]
fn full_graph_null_test_with_a_sampler_playing() {
    use timeline_core::cmd::{Cmd, NoteSpec};
    use timeline_core::model::DeviceKind;
    use timeline_core::tempo::PPQ;
    use timeline_core::Num;

    let mut project = project_120();
    let mut sources = HashMap::new();
    add_synth(&mut project, &mut sources, "a", sine(220.0, 96_000, 0.4));
    // Two zone assets, split across the keyboard, registered exactly the way a
    // clip's asset is.
    add_synth(&mut project, &mut sources, "zlow", sine(180.0, 192_000, 0.5));
    add_synth(&mut project, &mut sources, "zhigh", sine(700.0, 192_000, 0.5));
    add_track(&mut project, "t1");
    add_track(&mut project, "t2");
    place(&mut project, "t1", "c1", "a", 0, 0, 96_000, 2_400, 2_400);

    // t2 is MIDI only, driving a SAMPLER: no audio clip at all.
    project
        .apply_cmd(&Cmd::DeviceAdd {
            track_id: "t2".into(),
            device_id: "smp1".into(),
            kind: DeviceKind::Sampler,
        })
        .unwrap();
    for (zone_id, source_id, lo, hi, root) in [
        ("zA", "zlow", 0i64, 59i64, 45i64),
        ("zB", "zhigh", 60, 127, 81),
    ] {
        project
            .apply_cmd(&Cmd::DeviceZoneAdd {
                track_id: "t2".into(),
                device_id: "smp1".into(),
                zone_id: zone_id.into(),
                source_id: source_id.into(),
                root_pitch: Num::int(root),
                lo_pitch: Num::int(lo),
                hi_pitch: Num::int(hi),
                gain_db: None,
                pan: None,
            })
            .unwrap();
    }
    project
        .apply_cmd(&Cmd::ClipPlaceMidi {
            clip_id: "cm1".into(),
            track_id: "t2".into(),
            start_ticks: 0,
            length_ticks: PPQ * 16,
        })
        .unwrap();
    // Notes on BOTH sides of the zone split, so both zones are live.
    let notes: Vec<NoteSpec> = (0..20u64)
        .map(|i| NoteSpec {
            note_id: format!("n{i}"),
            start_ticks: i * (PPQ / 3),
            length_ticks: PPQ,
            pitch: 45 + (i % 30) as u8,
            velocity: Num::int(70 + (i % 40) as i64),
        })
        .collect();
    project
        .apply_cmd(&Cmd::NoteAdd {
            clip_id: "cm1".into(),
            notes,
        })
        .unwrap();

    let cfg = EngineConfig::default();
    let setup = |p: &EngineParams| {
        p.set_track_gain_db(1, -2.0);
        p.set_track_pan(1, 0.35);
        p.set_track_eq(1, 2, 2_500.0, -5.0, 0.9);
        p.set_track_send(1, false, 0.4);
        p.set_track_send(1, true, 0.3);
        p.set_master_gain_db(-1.0);
        p.set_limiter(true, -1.0, 50.0);
    };
    let schedule = |session: Box<render::rt::RtSession>| {
        vec![
            ScheduledCommand { at_frame: 0, command: RenderCommand::SetSession(session) },
            ScheduledCommand { at_frame: 0, command: RenderCommand::Play },
            ScheduledCommand {
                at_frame: 12_000,
                command: RenderCommand::LoopSet { start_frame: 20_000, end_frame: 44_000 },
            },
            ScheduledCommand { at_frame: 90_000, command: RenderCommand::LoopClear },
            ScheduledCommand { at_frame: 100_000, command: RenderCommand::Seek { frame: 30_000 } },
        ]
    };
    let total = 144_000;

    let mut rt = ManualRenderer::new(&cfg);
    setup(rt.params());
    let s_rt = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let realtime = render_offline_with(&mut rt, schedule(s_rt), total, 128);

    // NON-SILENCE GATE, and specifically a SAMPLER gate: mute the audio track
    // and confirm what is left is still real signal. A parity test on silence
    // — or on a mix the sampler never joined — is vacuous.
    let mut solo = ManualRenderer::new(&cfg);
    setup(solo.params());
    solo.params().set_track_mute(0, true);
    let s_solo = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let sampler_only = render_offline_with(&mut solo, schedule(s_solo), total, 128);
    let ipeak = sampler_only.iter().map(|f| f[0].abs()).fold(0.0_f32, f32::max);
    assert!(
        ipeak > 0.02,
        "the sampler produced no audible signal through the full graph (peak {ipeak})"
    );

    for block in [417_usize, 480, 512] {
        let mut other = ManualRenderer::new(&cfg);
        setup(other.params());
        let s = compile_session(&project, &sources, cfg.max_tracks).unwrap();
        let out = render_offline_with(&mut other, schedule(s), total, block);
        let r = residual(&realtime, &out);
        assert!(
            r.bit_identical,
            "full-graph bounce with a SAMPLER playing must be bit-identical \
             at block {block} (peak residual {} dBFS, max_abs {})",
            r.peak_dbfs, r.max_abs
        );
    }
}

// ===========================================================================
// E5-graph — the routing graph and the effect chains, proven on RENDERED
// BUFFERS (DESIGN-E5-routing.md §12.3, §12.6, §20.2).
//
// ⚠️ **Seam honesty (§12.5).** Every test in this section drives:
//
//   `Project` (built with real `Command`s, applied through `Project::apply`)
//     -> `compile_session_full`            (model -> snapshot)
//     -> `compile::sync_graph_params`      (model -> the routing/fx atomics)
//     -> `RenderCommand::SetSession` over the command channel
//     -> `drain_commands` -> `install_session`
//     -> THE one `RenderCore::render`
//
// and SKIPS: the cpal device callback, the real-time deadline, and
// `StudioHost::sync_params` / `sync_after_mutation`. **A test that sets
// `EngineParams` directly does NOT prove the host pushes them** — that is
// exactly how the solo bug survived. The full public path
// (`submit_json` -> `sync_after_mutation` -> bounce) is driven by
// `agent-surface/tests/e5_params_seam.rs::
// a_routed_project_still_syncs_and_bounces_through_the_full_bus`, which
// asserts a non-zero edge level is AUDIBLE (§23.1).
// ===========================================================================

use render::routing_rt::{ACC_MASTER, ACC_TRACK_BASE};
use timeline_core::cmd::Cmd;
use timeline_core::model::FxKind;
use timeline_core::routing::{NodeKind, NodeRef, Tap};
use timeline_core::Num;

/// A float-shaped `Num`. `Num::int` would journal an integer shape, which is a
/// different wire value (and a different hash).
fn fnum(v: f64) -> Num {
    Num::from(serde_json::Number::from_f64(v).expect("finite"))
}

/// A constant-DC clip, so every contribution is identifiable by inspection —
/// the `render/tests/solo.rs` convention.
fn dc(level: f32, frames: usize) -> Vec<[f32; 2]> {
    vec![[level, level]; frames]
}

const DC_FRAMES: usize = 4_000;

fn add_dc_track(
    project: &mut Project,
    sources: &mut HashMap<String, Arc<AudioBuf>>,
    track: &str,
    level: f32,
) {
    let src = format!("{track}_dc");
    add_synth(project, sources, &src, dc(level, DC_FRAMES));
    add_track(project, track);
    place(
        project,
        track,
        &format!("{track}_c"),
        &src,
        0,
        0,
        DC_FRAMES as u64,
        0,
        0,
    );
}

fn node(project: &mut Project, id: &str, kind: NodeKind) {
    project
        .apply_cmd(&Cmd::RouteNodeAdd {
            node_id: id.into(),
            kind,
            name: id.into(),
        })
        .unwrap();
}

fn connect(project: &mut Project, edge: &str, from: &str, to: &str, level: f64, tap: Tap) {
    project
        .apply_cmd(&Cmd::RouteConnect {
            edge_id: edge.into(),
            from: NodeRef::parse(from).unwrap(),
            to: NodeRef::parse(to).unwrap(),
            level: fnum(level),
            tap,
        })
        .unwrap();
}

fn fx_add(project: &mut Project, target: &str, fx_id: &str, kind: FxKind) {
    project
        .apply_cmd(&Cmd::FxAdd {
            target: NodeRef::parse(target).unwrap(),
            fx_id: fx_id.into(),
            kind,
        })
        .unwrap();
}

fn fx_set(project: &mut Project, target: &str, fx_id: &str, key: &str, value: f64) {
    project
        .apply_cmd(&Cmd::FxParamSet {
            target: NodeRef::parse(target).unwrap(),
            fx_id: fx_id.into(),
            key: key.into(),
            value: fnum(value),
        })
        .unwrap();
}

fn compile_routed(
    project: &Project,
    sources: &HashMap<String, Arc<AudioBuf>>,
    automation: &AutomationStore,
) -> Box<render::rt::RtSession> {
    compile_session_full(
        project,
        sources,
        &WarpOverlay::new(),
        automation,
        EngineConfig::default().max_tracks,
        DeclickPolicy::None,
    )
    .expect("compile")
}

/// Mirror the model's per-track mixer state into the atomics.
///
/// ⚠️ **This exists because its absence produced a false green.** The first
/// version of `the_pre_tap_does_not_carry_the_channel_eq` set a −24 dB notch
/// with `mix.eq` and asserted the pre tap did not carry it — and stayed GREEN
/// under a mutation that forced every tap to `Post`, because the EQ was model
/// state that nothing pushed, so both renders were flat and the assertion
/// compared two identical silences of meaning. `compile::sync_graph_params`
/// covers the ROUTING and FX atomics only; gain/pan/EQ/sends are the pre-E5
/// surface that `StudioHost::sync_params` pushes, and a harness that omits
/// them cannot see any of them.
fn sync_mixer_params(project: &Project, p: &EngineParams) {
    for (i, t) in project.tracks.iter().enumerate() {
        p.set_track_mute(i, t.mute);
        p.set_track_solo(i, t.solo);
        p.set_track_gain_db(i, t.gain.as_f64() as f32);
        p.set_track_pan(i, t.pan.as_f64() as f32);
        for (band, eq) in t.eq.iter().enumerate() {
            p.set_track_eq(
                i,
                band,
                eq.freq_hz.as_f64() as f32,
                eq.gain_db.as_f64() as f32,
                eq.q.as_f64() as f32,
            );
        }
        p.set_track_send(i, false, t.sends.a.as_f64() as f32);
        p.set_track_send(i, true, t.sends.b.as_f64() as f32);
    }
    p.clear_track_solos_from(project.tracks.len());
    p.set_master_gain_db(project.master.gain_db.as_f64() as f32);
}

/// Render a routed project, pushing the routing/fx atomics through the SAME
/// production function the host calls (`compile::sync_graph_params`) and the
/// mixer atomics through [`sync_mixer_params`], plus any extra params the test
/// needs (node faders, which have no model field at all — §2.2).
fn render_routed(
    project: &Project,
    sources: &HashMap<String, Arc<AudioBuf>>,
    automation: &AutomationStore,
    extra: impl FnOnce(&EngineParams),
    frames: u64,
    chunk: usize,
) -> Vec<[f32; 2]> {
    let session = compile_routed(project, sources, automation);
    let p2 = project.clone();
    render_with(
        session,
        move |p| {
            sync_mixer_params(&p2, p);
            render::compile::sync_graph_params(&p2, p);
            extra(p);
        },
        frames,
        chunk,
        vec![],
    )
    .0
}

/// Peak of the left channel over a settled window (past the 5 ms declick and
/// the transport ramp), so a comparison is of steady-state levels.
fn settled(out: &[[f32; 2]]) -> f32 {
    let from = (MICRO_FADE_FRAMES as usize) * 4;
    out[from..].iter().fold(0.0_f32, |m, f| m.max(f[0].abs()))
}

fn digest_of(out: &[[f32; 2]]) -> u64 {
    let mut h = 1469598103934665603_u64;
    for f in out {
        for c in f {
            h ^= u64::from(c.to_bits());
            h = h.wrapping_mul(1099511628211);
        }
    }
    h
}

// ---- §12.3 proof 1: a group sums, and does not double-count ---------------

/// Two tracks through one group node land at master at exactly the direct mix.
/// The group's own implicit master feed is the ONLY path; each track's direct
/// feed is suppressed by its `post` edge (§4.2).
#[test]
fn a_group_sums_its_members_without_double_counting() {
    let (mut p, mut s) = (project_120(), HashMap::new());
    add_dc_track(&mut p, &mut s, "t1", 0.25);
    add_dc_track(&mut p, &mut s, "t2", 0.50);
    let direct = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_000, 512);

    node(&mut p, "grp", NodeKind::Group);
    connect(&mut p, "e1", "track.t1", "bus.grp", 1.0, Tap::Post);
    connect(&mut p, "e2", "track.t2", "bus.grp", 1.0, Tap::Post);
    let grouped = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_000, 512);

    assert!(
        (settled(&direct) - 0.75).abs() < 1e-4,
        "fixture broken: direct mix is {}",
        settled(&direct)
    );
    assert!(
        (settled(&grouped) - settled(&direct)).abs() < 1e-5,
        "grouping changed the level: direct {} vs grouped {} (a double count \
         would read 1.5)",
        settled(&direct),
        settled(&grouped)
    );
}

// ---- §12.3 proof 2: the implicit-master-feed rule, one test per row -------

/// §4.2's table, rendered. Each row states what master must contain.
#[test]
fn the_implicit_master_feed_rule_holds_row_by_row() {
    // Row 1: empty routing -> every track to master. Exactly v1.
    {
        let (mut p, mut s) = (project_120(), HashMap::new());
        add_dc_track(&mut p, &mut s, "t1", 0.25);
        let out = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 2_000, 512);
        assert!((settled(&out) - 0.25).abs() < 1e-5, "{}", settled(&out));
    }
    // Row 2: t1 -> bus.grp (POST) -> t1 feeds ONLY the group. No double count.
    {
        let (mut p, mut s) = (project_120(), HashMap::new());
        add_dc_track(&mut p, &mut s, "t1", 0.25);
        node(&mut p, "grp", NodeKind::Group);
        connect(&mut p, "e1", "track.t1", "bus.grp", 1.0, Tap::Post);
        let out = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 2_000, 512);
        assert!((settled(&out) - 0.25).abs() < 1e-5, "{}", settled(&out));
    }
    // Row 3: t1 -> bus.rev (PRE) -> t1 feeds master AND the bus. A send.
    {
        let (mut p, mut s) = (project_120(), HashMap::new());
        add_dc_track(&mut p, &mut s, "t1", 0.25);
        node(&mut p, "rev", NodeKind::Bus);
        connect(&mut p, "e1", "track.t1", "bus.rev", 1.0, Tap::Pre);
        let out = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 2_000, 512);
        assert!(
            (settled(&out) - 0.50).abs() < 1e-4,
            "a PRE tap must not suppress the direct feed: got {}",
            settled(&out)
        );
    }
    // Row 4: a POST edge to the group AND a POST edge to master at 0.5.
    // Both paths, with a trim on the direct one.
    {
        let (mut p, mut s) = (project_120(), HashMap::new());
        add_dc_track(&mut p, &mut s, "t1", 0.25);
        node(&mut p, "grp", NodeKind::Group);
        connect(&mut p, "e1", "track.t1", "bus.grp", 1.0, Tap::Post);
        connect(&mut p, "e2", "track.t1", "master", 0.5, Tap::Post);
        let out = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 2_000, 512);
        assert!(
            (settled(&out) - 0.375).abs() < 1e-4,
            "expected 0.25 (group) + 0.125 (trimmed direct): got {}",
            settled(&out)
        );
    }
    // Row 5: disconnecting the last POST edge brings the implicit feed back.
    {
        let (mut p, mut s) = (project_120(), HashMap::new());
        add_dc_track(&mut p, &mut s, "t1", 0.25);
        node(&mut p, "grp", NodeKind::Group);
        connect(&mut p, "e1", "track.t1", "bus.grp", 1.0, Tap::Post);
        p.apply_cmd(&Cmd::RouteDisconnect {
            edge_id: "e1".into(),
        })
        .unwrap();
        let out = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 2_000, 512);
        assert!((settled(&out) - 0.25).abs() < 1e-5, "{}", settled(&out));
    }
}

// ---- §12.3 proof 3: the node fader ---------------------------------------

/// `bus.<id>.gain` at −6 dB halves the group's contribution and nothing else.
#[test]
fn the_node_fader_scales_only_that_nodes_contribution() {
    let (mut p, mut s) = (project_120(), HashMap::new());
    add_dc_track(&mut p, &mut s, "t1", 0.40); // through the group
    add_dc_track(&mut p, &mut s, "t2", 0.20); // straight to master
    node(&mut p, "grp", NodeKind::Group);
    connect(&mut p, "e1", "track.t1", "bus.grp", 1.0, Tap::Post);

    let unity = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_000, 512);
    assert!((settled(&unity) - 0.60).abs() < 1e-4, "{}", settled(&unity));

    let trimmed = render_routed(
        &p,
        &s,
        &AutomationStore::new(),
        |params| params.set_node_gain_db(0, -6.0206),
        3_000,
        512,
    );
    // t1 halves (0.20), t2 untouched (0.20).
    assert!(
        (settled(&trimmed) - 0.40).abs() < 2e-3,
        "expected 0.40, got {}",
        settled(&trimmed)
    );
}

// ---- §12.3 proofs 4-6: the taps, mute and solo ---------------------------

/// A POST send is killed by mute AND by solo — today's behaviour, now pinned,
/// and the PRE send is killed by both as well (§3.3). The difference is the
/// FADER: only the post tap follows it.
#[test]
fn both_taps_are_gated_by_mute_and_by_solo() {
    let build = |tap: Tap| {
        let (mut p, mut s) = (project_120(), HashMap::new());
        add_dc_track(&mut p, &mut s, "t1", 0.50);
        add_dc_track(&mut p, &mut s, "t2", 0.10);
        node(&mut p, "aux", NodeKind::Bus);
        connect(&mut p, "e1", "track.t1", "bus.aux", 1.0, tap);
        (p, s)
    };
    for tap in [Tap::Post, Tap::Pre] {
        let (p, s) = build(tap);
        let open = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_000, 512);
        let muted = render_routed(
            &p,
            &s,
            &AutomationStore::new(),
            |params| params.set_track_mute(0, true),
            3_000,
            512,
        );
        let soloed = render_routed(
            &p,
            &s,
            &AutomationStore::new(),
            |params| params.set_track_solo(1, true),
            3_000,
            512,
        );
        // t2 alone is 0.10 either way; t1's contribution (direct and/or bus)
        // must be gone in both gated renders.
        assert!(
            settled(&open) > 0.4,
            "{tap:?}: fixture broken, open mix is {}",
            settled(&open)
        );
        assert!(
            (settled(&muted) - 0.10).abs() < 2e-3,
            "{tap:?}: mute left a send ringing: {}",
            settled(&muted)
        );
        assert!(
            (settled(&soloed) - 0.10).abs() < 2e-3,
            "{tap:?}: solo left a non-soloed track's send in the mix: {}",
            settled(&soloed)
        );
    }
}

/// The useful pre-fader case: pull the fader to silence and the send survives.
/// The post tap, on the same graph, does not.
#[test]
fn a_pre_fader_send_survives_the_fader_and_a_post_fader_send_does_not() {
    let build = |tap: Tap| {
        let (mut p, mut s) = (project_120(), HashMap::new());
        add_dc_track(&mut p, &mut s, "t1", 0.50);
        node(&mut p, "aux", NodeKind::Bus);
        connect(&mut p, "e1", "track.t1", "bus.aux", 1.0, tap);
        (p, s)
    };
    let (pp, ps) = build(Tap::Pre);
    let pre = render_routed(
        &pp,
        &ps,
        &AutomationStore::new(),
        |params| params.set_track_gain_db(0, -96.0),
        3_000,
        512,
    );
    let (op, os) = build(Tap::Post);
    let post = render_routed(
        &op,
        &os,
        &AutomationStore::new(),
        |params| params.set_track_gain_db(0, -96.0),
        3_000,
        512,
    );
    assert!(
        settled(&pre) > 0.4,
        "the pre tap followed the fader: {}",
        settled(&pre)
    );
    assert!(
        settled(&post) < 1e-3,
        "the post tap ignored the fader: {}",
        settled(&post)
    );
}

/// §3.2 — **`Tap::Pre` is PRE-EQ, deliberately, and this test pins that
/// divergence on purpose.**
///
/// A −24 dB notch on the strip must NOT appear in the pre tap's contribution.
/// This is not an oversight to be "improved": the three ways to make the pre
/// tap carry the EQ were each rejected with a reason (§3.2), and the third —
/// a second `EqBank` per strip — is the documented upgrade path. **A later
/// lane that makes this test fail has changed a decided seam, not fixed a
/// bug.**
#[test]
fn the_pre_tap_does_not_carry_the_channel_eq() {
    // Master hears ONLY the pre tap's path: the direct feed is suppressed by a
    // POST edge to master trimmed to zero, so any EQ leakage is unmissable.
    let render_for = |band_gain: f64| {
        let (mut p, mut s) = (project_120(), HashMap::new());
        add_dc_track(&mut p, &mut s, "t1", 0.50);
        p.apply_cmd(&Cmd::MixEq {
            track_id: "t1".into(),
            band: 0,
            freq_hz: fnum(120.0),
            gain_db: fnum(band_gain),
            q: Some(fnum(0.707)),
        })
        .unwrap();
        node(&mut p, "aux", NodeKind::Bus);
        connect(&mut p, "e1", "track.t1", "bus.aux", 1.0, Tap::Pre);
        connect(&mut p, "e2", "track.t1", "master", 0.0, Tap::Post);
        render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_000, 512)
    };
    let flat = render_for(0.0);
    let notched = render_for(-24.0);
    assert!(
        settled(&flat) > 0.4,
        "fixture broken: the pre path is silent ({})",
        settled(&flat)
    );
    assert!(
        (settled(&flat) - settled(&notched)).abs() < 1e-4,
        "the pre tap carried the channel EQ: flat {} vs notched {}. §3.2 says it \
         must not — read the doc comment before changing this assertion",
        settled(&flat),
        settled(&notched)
    );
}

/// §12.3 proof 8: the pre-tap gate DECLICKS. Assert the ramp, not the
/// endpoints — a step would pass an endpoint-only test.
#[test]
fn the_pre_tap_gate_ramps_rather_than_stepping() {
    let (mut p, mut s) = (project_120(), HashMap::new());
    add_dc_track(&mut p, &mut s, "t1", 0.50);
    node(&mut p, "aux", NodeKind::Bus);
    connect(&mut p, "e1", "track.t1", "bus.aux", 1.0, Tap::Pre);
    // Direct feed trimmed to zero so master hears ONLY the gated pre path.
    connect(&mut p, "e2", "track.t1", "master", 0.0, Tap::Post);

    let session = compile_routed(&p, &s, &AutomationStore::new());
    let cfg = EngineConfig::default();
    let mut renderer = ManualRenderer::new(&cfg);
    render::compile::sync_graph_params(&p, renderer.params());
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
        3_000,
        64,
    );
    // Now mute mid-render and confirm the fall takes the declick window.
    let session2 = compile_routed(&p, &s, &AutomationStore::new());
    let mut r2 = ManualRenderer::new(&cfg);
    render::compile::sync_graph_params(&p, r2.params());
    let out_head = render_offline_with(
        &mut r2,
        vec![
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::SetSession(session2),
            },
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::Play,
            },
        ],
        2_000,
        64,
    );
    let before = out_head[1_999][0].abs();
    assert!(before > 0.4, "fixture broken: pre path silent ({before})");
    r2.params().set_track_mute(0, true);
    let tail = render_offline_with(&mut r2, vec![], 1_000, 64);
    // The fall must take roughly MICRO_FADE_FRAMES, and must be MONOTONE —
    // a step would land at 0.0 within one frame.
    let mut fell_at = None;
    for (i, f) in tail.iter().enumerate() {
        if f[0].abs() < 1e-6 {
            fell_at = Some(i);
            break;
        }
    }
    let fell_at = fell_at.expect("the gate never closed");
    assert!(
        fell_at >= MICRO_FADE_FRAMES as usize - 2,
        "the pre-tap gate STEPPED: reached silence after {fell_at} frames, the \
         declick window is {MICRO_FADE_FRAMES}"
    );
    assert!(
        fell_at <= MICRO_FADE_FRAMES as usize + 64,
        "the pre-tap gate took {fell_at} frames, far longer than the declick window"
    );
    let _ = out;
}

// ---- §12.3 proof 10: edge-level automation is AUDIBLE ---------------------

/// A 0->1 ramp on `route.edge.<id>.level` changes the rendered buffer.
///
/// ⚠️ This asserts the INVERSE of what the tree did before E5-graph: the lane
/// compiled into a real slot and nothing read it (§0 row 7's class).
#[test]
fn a_route_edge_level_ramp_is_audible() {
    let (mut p, mut s) = (project_120(), HashMap::new());
    add_dc_track(&mut p, &mut s, "t1", 0.50);
    node(&mut p, "aux", NodeKind::Bus);
    // PRE tap so the direct feed stays, and the bus return is the only thing
    // the ramp can move.
    connect(&mut p, "e1", "track.t1", "bus.aux", 0.0, Tap::Pre);

    let flat = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_000, 512);

    let mut a = AutomationStore::new();
    a.add_point_path(
        "t1",
        "route.edge.e1.level",
        render::automation::RawPoint {
            tick: 0,
            value: 0.0,
            curve: CurveKind::Linear,
        },
    );
    a.add_point_path(
        "t1",
        "route.edge.e1.level",
        render::automation::RawPoint {
            tick: 40,
            value: 1.0,
            curve: CurveKind::Linear,
        },
    );
    let ramped = render_routed(&p, &s, &a, |_| {}, 3_000, 512);

    assert_ne!(
        digest_of(&flat),
        digest_of(&ramped),
        "a 0->1 ramp on route.edge.e1.level rendered bit-identically to no \
         automation — the lane is INERT, which is the bug this epic exists to fix"
    );
    assert!(
        settled(&ramped) > settled(&flat) + 0.2,
        "the ramp did not raise the mix: flat {} vs ramped {}",
        settled(&flat),
        settled(&ramped)
    );
}

/// A `bus.<id>.gain` ramp is audible too (§6.5's node lane table).
#[test]
fn a_node_fader_automation_ramp_is_audible() {
    let (mut p, mut s) = (project_120(), HashMap::new());
    add_dc_track(&mut p, &mut s, "t1", 0.50);
    node(&mut p, "grp", NodeKind::Group);
    connect(&mut p, "e1", "track.t1", "bus.grp", 1.0, Tap::Post);

    let flat = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_000, 512);
    let mut a = AutomationStore::new();
    for (tick, v) in [(0_u64, -60.0_f32), (40, 0.0)] {
        a.add_point_path(
            "t1",
            "bus.grp.gain",
            render::automation::RawPoint {
                tick,
                value: v,
                curve: CurveKind::Linear,
            },
        );
    }
    let ramped = render_routed(&p, &s, &a, |_| {}, 3_000, 512);
    assert_ne!(
        digest_of(&flat),
        digest_of(&ramped),
        "a bus fader ramp rendered bit-identically to no automation"
    );
}

// ---- §12.3 proof 11: stale-slot hygiene ----------------------------------

/// A level left in a RETIRED slot must not reach the audio (§6.3).
///
/// ⚠️ **Seam honesty — what this test does NOT prove.** A mutation that deletes
/// `clear_edge_levels_from` leaves this test GREEN, and that is structural, not
/// a weak assertion: `sync_graph_params` pushes every LIVE slot from the model
/// on every call, so a slot that is still referenced is always authoritative
/// and a slot that is not referenced is never read. The clear is defence in
/// depth for the moment those two facts stop holding together. The observable
/// assertion is on the params block itself, and it lives at
/// `agent-surface/tests/e5_params_seam.rs::
/// sync_params_clears_retired_routing_slots_and_keeps_live_ones`, which DOES go
/// red when the clear is removed. What this test proves is the other half: a
/// hostile params block cannot reach the audio through a retired slot.
#[test]
fn a_dirty_retired_edge_slot_does_not_reach_the_audio() {
    let (mut p, mut s) = (project_120(), HashMap::new());
    add_dc_track(&mut p, &mut s, "t1", 0.50);
    node(&mut p, "aux", NodeKind::Bus);
    connect(&mut p, "e1", "track.t1", "bus.aux", 1.0, Tap::Pre);
    let with_edge = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_000, 512);

    // Retire the edge, then dirty every slot BEFORE the production push runs.
    p.apply_cmd(&Cmd::RouteDisconnect {
        edge_id: "e1".into(),
    })
    .unwrap();
    let clean = render_routed(
        &p,
        &s,
        &AutomationStore::new(),
        |_| {},
        3_000,
        512,
    );
    let session = compile_routed(&p, &s, &AutomationStore::new());
    let cfg = EngineConfig::default();
    let mut renderer = ManualRenderer::new(&cfg);
    for slot in 0..8 {
        renderer.params().set_edge_level(slot, 4.0);
        renderer.params().set_node_gain_db(slot, 24.0);
    }
    render::compile::sync_graph_params(&p, renderer.params());
    let dirty = render_offline_with(
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
        3_000,
        512,
    );
    assert!(settled(&with_edge) > settled(&clean) + 0.2);
    assert_eq!(
        digest_of(&dirty),
        digest_of(&clean),
        "a retired edge/node slot reached the audio: the stale-slot clears are \
         not doing their job (§6.3)"
    );
}

// ---- §12.3 proof 12 / §20.2 proof 11: bit-identity at 4 block sizes -------

/// A FULL graph — a group, a pre-tap send, a track insert chain, a bus insert
/// chain, a master effect, a sidechain, and non-zero PDC — renders
/// **bit-identically** at 128 / 417 / 480 / 512.
///
/// A per-block shortcut anywhere in the walk, the chains or the compensation
/// rings breaks this and nothing else in the suite would notice.
#[test]
fn the_full_graph_bounces_bit_identically_at_128_417_480_512() {
    let (mut p, mut s) = (project_120(), HashMap::new());
    add_dc_track(&mut p, &mut s, "kick", 0.60);
    add_dc_track(&mut p, &mut s, "bass", 0.40);
    add_synth(&mut p, &mut s, "tone", sine(220.0, DC_FRAMES, 0.5));
    add_track(&mut p, "pad");
    place(&mut p, "pad", "pad_c", "tone", 0, 0, DC_FRAMES as u64, 0, 0);

    node(&mut p, "grp", NodeKind::Group);
    node(&mut p, "lim", NodeKind::Bus);
    connect(&mut p, "e1", "track.bass", "bus.grp", 1.0, Tap::Post);
    connect(&mut p, "e2", "track.pad", "bus.lim", 0.8, Tap::Pre);
    connect(&mut p, "e3", "track.kick", "master", 0.9, Tap::Post);

    // A track insert, a bus insert with LATENCY (so PDC is non-zero), a master
    // insert, and a sidechain.
    fx_add(&mut p, "track.bass", "sat", FxKind::Saturator);
    fx_set(&mut p, "track.bass", "sat", "drive", 6.0);
    fx_add(&mut p, "bus.lim", "l1", FxKind::Limiter);
    fx_add(&mut p, "bus.grp", "cmp", FxKind::Compressor);
    fx_set(&mut p, "bus.grp", "cmp", "threshold", -24.0);
    p.apply_cmd(&Cmd::FxSidechainSet {
        target: NodeRef::parse("bus.grp").unwrap(),
        fx_id: "cmp".into(),
        source: NodeRef::parse("track.kick").unwrap(),
    })
    .unwrap();
    fx_add(&mut p, "master", "mu", FxKind::Utility);
    fx_set(&mut p, "master", "mu", "gain", -2.0);

    // Guard: the graph must genuinely carry compensation, or this test is a
    // duplicate of the empty-graph null test.
    let probe = compile_routed(&p, &s, &AutomationStore::new());
    assert!(
        probe.graph.edges.iter().any(|e| e.comp > 0),
        "no edge carries compensation — the PDC path is not under test"
    );
    assert!(probe.graph.fx.len() >= 4, "the fx chains are not under test");
    drop(probe);

    let a = AutomationStore::new();
    let reference = render_routed(&p, &s, &a, |_| {}, 3_000, 128);
    for chunk in [417_usize, 480, 512] {
        let got = render_routed(&p, &s, &a, |_| {}, 3_000, chunk);
        assert_eq!(
            digest_of(&got),
            digest_of(&reference),
            "the full graph is NOT bit-identical at chunk {chunk} vs 128: \
             something in the walk, a chain or a compensation ring advances \
             per BLOCK instead of per FRAME (§6.1)"
        );
    }
}

// ---- §20.2 proofs 1-3: effects ------------------------------------------

/// An effect changes the audio: a `Utility` at −6 dB on a bus halves that
/// bus's contribution.
#[test]
fn a_utility_fx_on_a_bus_scales_that_bus() {
    let build = |gain: Option<f64>| {
        let (mut p, mut s) = (project_120(), HashMap::new());
        add_dc_track(&mut p, &mut s, "t1", 0.50);
        node(&mut p, "grp", NodeKind::Group);
        connect(&mut p, "e1", "track.t1", "bus.grp", 1.0, Tap::Post);
        if let Some(g) = gain {
            fx_add(&mut p, "bus.grp", "u", FxKind::Utility);
            fx_set(&mut p, "bus.grp", "u", "gain", g);
        }
        render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_000, 512)
    };
    let plain = build(None);
    let trimmed = build(Some(-6.0206));
    assert!((settled(&plain) - 0.50).abs() < 1e-4, "{}", settled(&plain));
    assert!(
        (settled(&trimmed) - 0.25).abs() < 3e-3,
        "expected 0.25, got {}",
        settled(&trimmed)
    );
}

/// Chain ORDER matters, rendered: saturator -> utility is not the same buffer
/// as utility -> saturator, and `fx.move` swaps them.
#[test]
fn the_insert_chain_order_changes_the_render() {
    let build = |swap: bool| {
        let (mut p, mut s) = (project_120(), HashMap::new());
        add_dc_track(&mut p, &mut s, "t1", 0.50);
        fx_add(&mut p, "track.t1", "sat", FxKind::Saturator);
        fx_set(&mut p, "track.t1", "sat", "drive", 18.0);
        fx_add(&mut p, "track.t1", "u", FxKind::Utility);
        fx_set(&mut p, "track.t1", "u", "gain", -12.0);
        if swap {
            p.apply_cmd(&Cmd::FxMove {
                target: NodeRef::parse("track.t1").unwrap(),
                fx_id: "u".into(),
                index: 0,
            })
            .unwrap();
            assert_eq!(p.tracks[0].fx[0].id, "u", "fx.move did not reorder");
        }
        render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_000, 512)
    };
    let sat_first = build(false);
    let util_first = build(true);
    assert_ne!(
        digest_of(&sat_first),
        digest_of(&util_first),
        "reordering a saturator and a −12 dB trim did not change the render: \
         the chain is not being evaluated in Vec order"
    );
}

/// A settled bypass is bit-identical to no effect at all — `Slew` arrives
/// exactly, so the branch is exact, not "within epsilon" (§20.2 proof 3).
#[test]
fn a_bypassed_fx_is_bit_identical_to_no_fx() {
    let (mut p0, mut s0) = (project_120(), HashMap::new());
    add_dc_track(&mut p0, &mut s0, "t1", 0.50);
    let none = render_routed(&p0, &s0, &AutomationStore::new(), |_| {}, 3_000, 512);

    let (mut p1, mut s1) = (project_120(), HashMap::new());
    add_dc_track(&mut p1, &mut s1, "t1", 0.50);
    fx_add(&mut p1, "track.t1", "sat", FxKind::Saturator);
    fx_set(&mut p1, "track.t1", "sat", "drive", 24.0);
    let active = render_routed(&p1, &s1, &AutomationStore::new(), |_| {}, 3_000, 512);
    fx_set(&mut p1, "track.t1", "sat", "bypass", 1.0);
    let bypassed = render_routed(&p1, &s1, &AutomationStore::new(), |_| {}, 3_000, 512);

    assert_ne!(
        digest_of(&active),
        digest_of(&none),
        "the saturator did nothing even un-bypassed"
    );
    assert_eq!(
        digest_of(&bypassed),
        digest_of(&none),
        "a bypassed effect is not a bit-exact passthrough"
    );
}

// ---- §20.2 proofs 4-6: dynamics and the sidechain ------------------------

/// A compressor above threshold comes out quieter; below threshold it is a
/// unity passthrough.
#[test]
fn a_compressor_reduces_gain_above_threshold_only() {
    let build = |level: f32, threshold: f64| {
        let (mut p, mut s) = (project_120(), HashMap::new());
        add_dc_track(&mut p, &mut s, "t1", level);
        fx_add(&mut p, "track.t1", "c", FxKind::Compressor);
        fx_set(&mut p, "track.t1", "c", "threshold", threshold);
        fx_set(&mut p, "track.t1", "c", "ratio", 8.0);
        fx_set(&mut p, "track.t1", "c", "attack", 1.0);
        render_routed(&p, &s, &AutomationStore::new(), |_| {}, 4_000, 512)
    };
    // 0.5 is about −6 dB: well above a −24 dB threshold.
    let squashed = build(0.5, -24.0);
    assert!(
        settled(&squashed) < 0.35,
        "a signal 18 dB over an 8:1 threshold was not reduced: {}",
        settled(&squashed)
    );
    // The same signal with the threshold above it must pass at unity.
    let clean = build(0.5, 0.0);
    assert!(
        (settled(&clean) - 0.5).abs() < 5e-3,
        "a signal below threshold was not passed at unity: {}",
        settled(&clean)
    );
}

/// ⚑ **THE sidechain proof.** A pulsing key on track `kick` ducks a sustained
/// tone on `bus.b`, and removing the link stops the ducking.
#[test]
fn a_sidechained_compressor_ducks_in_time_with_its_key() {
    let build = |keyed: bool| {
        let (mut p, mut s) = (project_120(), HashMap::new());
        // A pulsing key: loud for 1000 frames, silent for 1000.
        let pulse: Vec<[f32; 2]> = (0..DC_FRAMES)
            .map(|i| {
                let v = if (i / 1_000) % 2 == 0 { 0.9 } else { 0.0 };
                [v, v]
            })
            .collect();
        add_synth(&mut p, &mut s, "pulse", pulse);
        add_track(&mut p, "kick");
        place(&mut p, "kick", "kc", "pulse", 0, 0, DC_FRAMES as u64, 0, 0);
        add_dc_track(&mut p, &mut s, "tone", 0.5);

        node(&mut p, "b", NodeKind::Bus);
        connect(&mut p, "e1", "track.tone", "bus.b", 1.0, Tap::Post);
        // The kick feeds master directly, so it is a real signal, not a
        // phantom that only exists as a key.
        fx_add(&mut p, "bus.b", "c", FxKind::Compressor);
        fx_set(&mut p, "bus.b", "c", "threshold", -30.0);
        fx_set(&mut p, "bus.b", "c", "ratio", 20.0);
        fx_set(&mut p, "bus.b", "c", "attack", 0.5);
        fx_set(&mut p, "bus.b", "c", "release", 20.0);
        if keyed {
            p.apply_cmd(&Cmd::FxSidechainSet {
                target: NodeRef::parse("bus.b").unwrap(),
                fx_id: "c".into(),
                source: NodeRef::parse("track.kick").unwrap(),
            })
            .unwrap();
        }
        // Mute the kick's own path at master so the measured buffer is the
        // BUS only; solo is not used because it would gate the key too.
        connect(&mut p, "e2", "track.kick", "master", 0.0, Tap::Post);
        render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_500, 512)
    };
    let keyed = build(true);
    let unkeyed = build(false);

    // Frame 1500 is inside a key-silent window; frame 500 is inside a key-loud
    // one. With the link, the loud window must be markedly quieter.
    let at = |v: &[[f32; 2]], i: usize| v[i][0].abs();
    let ducked = at(&keyed, 800);
    let open = at(&keyed, 1_800);
    assert!(
        ducked < open * 0.7,
        "the bus did not duck in time with the key: {ducked} during the key, \
         {open} between keys"
    );
    let u_ducked = at(&unkeyed, 800);
    let u_open = at(&unkeyed, 1_800);
    assert!(
        (u_ducked - u_open).abs() < 1e-3,
        "the UNKEYED compressor ducked anyway ({u_ducked} vs {u_open}), so the \
         test is measuring something other than the sidechain"
    );
}

/// §17.3's failure mode, asserted directly: with the link present the detector
/// must see a **non-zero key on the very first frame of the key**, not a
/// not-yet-written accumulator reading exactly `0.0`.
///
/// A test that only checked "the output changed" would pass while the detector
/// read zero on a later, reordered graph. This asserts the ORDER.
#[test]
fn the_key_source_is_scheduled_before_its_host() {
    let (mut p, mut s) = (project_120(), HashMap::new());
    add_dc_track(&mut p, &mut s, "tone", 0.5);
    add_dc_track(&mut p, &mut s, "kick", 0.9);
    node(&mut p, "b", NodeKind::Bus);
    connect(&mut p, "e1", "track.tone", "bus.b", 1.0, Tap::Post);
    fx_add(&mut p, "bus.b", "c", FxKind::Compressor);
    p.apply_cmd(&Cmd::FxSidechainSet {
        target: NodeRef::parse("bus.b").unwrap(),
        fx_id: "c".into(),
        source: NodeRef::parse("track.kick").unwrap(),
    })
    .unwrap();

    let session = compile_routed(&p, &s, &AutomationStore::new());
    // The key source's accumulator slot must be written by a step that comes
    // BEFORE the step hosting the keyed effect.
    let key_slot = session.graph.fx[0].key_src.expect("the link was dropped") as usize;
    assert_eq!(
        key_slot,
        ACC_TRACK_BASE + 1,
        "the key resolved to the wrong accumulator slot"
    );
    let pos = |pred: &dyn Fn(&render::rt::NodeStep) -> bool| {
        session.node_order.iter().position(|s| pred(s))
    };
    let key_at = pos(&|s| s.kind == render::rt::NodeStepKind::Track(1)).unwrap();
    let host_at = pos(&|s| s.kind == render::rt::NodeStepKind::Node(0)).unwrap();
    assert!(
        key_at < host_at,
        "the sidechain SOURCE (step {key_at}) is scheduled after its HOST \
         (step {host_at}); the detector would read node_acc BEFORE it is \
         written this frame — exactly 0.0, i.e. silence, not a small error"
    );
    assert!(host_at < pos(&|s| s.kind == render::rt::NodeStepKind::Master).unwrap());
}

// ---- §20.2 proof 7: THE PDC proof ----------------------------------------

/// Two paths carrying the same source, one of them through a 96-frame
/// `Limiter` bus, must NULL against each other when one is polarity-inverted.
/// Without compensation they are 96 frames apart and cannot cancel.
#[test]
fn parallel_paths_through_a_latency_bearing_bus_still_null() {
    let (mut p, mut s) = (project_120(), HashMap::new());
    // One source, two tracks carrying identical audio.
    add_synth(&mut p, &mut s, "tone", sine(300.0, DC_FRAMES, 0.2));
    for t in ["dry", "wet"] {
        add_track(&mut p, t);
        place(&mut p, t, &format!("{t}_c"), "tone", 0, 0, DC_FRAMES as u64, 0, 0);
    }
    // The wet path goes through a bus whose only effect is a Limiter set so
    // far below threshold that it is a pure delay, and is polarity-inverted so
    // the two paths cancel when aligned.
    node(&mut p, "lim", NodeKind::Bus);
    connect(&mut p, "e1", "track.wet", "bus.lim", 1.0, Tap::Post);
    fx_add(&mut p, "bus.lim", "l", FxKind::Limiter);
    fx_set(&mut p, "bus.lim", "l", "ceiling", 0.0);
    fx_add(&mut p, "bus.lim", "inv", FxKind::Utility);
    fx_set(&mut p, "bus.lim", "inv", "polarity", 1.0);

    let session = compile_routed(&p, &s, &AutomationStore::new());
    let comps: Vec<u32> = session.graph.edges.iter().map(|e| e.comp).collect();
    assert!(
        comps.iter().any(|c| *c == 96),
        "no edge received the limiter's 96 frames of compensation: {comps:?}"
    );
    drop(session);

    let out = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_000, 512);
    // Measure past the compensation ring's fill and the declick.
    let from = 96 + MICRO_FADE_FRAMES as usize * 3;
    let residual_peak = out[from..].iter().fold(0.0_f32, |m, f| m.max(f[0].abs()));
    assert!(
        residual_peak < 5e-3,
        "the compensated parallel paths did not cancel (residual {residual_peak}); \
         a phase error is INAUDIBLE in a single path, so without this test PDC is \
         unverified"
    );
}

// ---- §20.2 proof 8: the master chain -------------------------------------

/// An effect on `master` affects the bounce, and it runs BEFORE the master
/// gain and the existing master limiter (§16.7).
#[test]
fn a_master_fx_chain_affects_the_bounce() {
    let (mut p, mut s) = (project_120(), HashMap::new());
    add_dc_track(&mut p, &mut s, "t1", 0.50);
    let plain = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_000, 512);
    fx_add(&mut p, "master", "u", FxKind::Utility);
    fx_set(&mut p, "master", "u", "gain", -6.0206);
    let trimmed = render_routed(&p, &s, &AutomationStore::new(), |_| {}, 3_000, 512);
    assert!((settled(&plain) - 0.50).abs() < 1e-4);
    assert!(
        (settled(&trimmed) - 0.25).abs() < 3e-3,
        "a master Utility at −6 dB did not halve the bounce: {}",
        settled(&trimmed)
    );
}

// ---- §12.6: structural proofs -------------------------------------------

/// Caps are enforced CONTROL-SIDE, with a typed error naming the cap and the
/// count. The audio thread never sees an over-cap session.
#[test]
fn capacities_are_refused_at_compile_by_name_and_count() {
    // 33 routing nodes.
    let (mut p, mut s) = (project_120(), HashMap::new());
    add_dc_track(&mut p, &mut s, "t1", 0.5);
    for i in 0..33 {
        node(&mut p, &format!("n{i}"), NodeKind::Bus);
    }
    let err = compile_session_full(
        &p,
        &s,
        &WarpOverlay::new(),
        &AutomationStore::new(),
        EngineConfig::default().max_tracks,
        DeclickPolicy::None,
    )
    .err()
    .expect("33 routing nodes must be refused");
    assert!(err.contains("33") && err.contains("32"), "{err}");
    assert!(err.contains("routing nodes"), "{err}");

    // 17 effects in one chain.
    let (mut p2, mut s2) = (project_120(), HashMap::new());
    add_dc_track(&mut p2, &mut s2, "t1", 0.5);
    for i in 0..17 {
        fx_add(&mut p2, "track.t1", &format!("f{i}"), FxKind::Utility);
    }
    let err2 = compile_session_full(
        &p2,
        &s2,
        &WarpOverlay::new(),
        &AutomationStore::new(),
        EngineConfig::default().max_tracks,
        DeclickPolicy::None,
    )
    .err()
    .expect("17 effects in one chain must be refused");
    assert!(err2.contains("17") && err2.contains("16"), "{err2}");
    assert!(err2.contains("effects in the chain"), "{err2}");
}

/// The compiled graph is a pure function of the PROJECT, not of edge
/// declaration order: the same topology declared in two orders produces the
/// same schedule, the same edge slots and the same bytes.
#[test]
fn the_compiled_graph_is_independent_of_declaration_order() {
    let build = |reverse: bool| {
        let (mut p, mut s) = (project_120(), HashMap::new());
        add_dc_track(&mut p, &mut s, "t1", 0.25);
        add_dc_track(&mut p, &mut s, "t2", 0.35);
        node(&mut p, "grp", NodeKind::Group);
        if reverse {
            connect(&mut p, "e2", "track.t2", "bus.grp", 0.6, Tap::Post);
            connect(&mut p, "e1", "track.t1", "bus.grp", 0.8, Tap::Post);
        } else {
            connect(&mut p, "e1", "track.t1", "bus.grp", 0.8, Tap::Post);
            connect(&mut p, "e2", "track.t2", "bus.grp", 0.6, Tap::Post);
        }
        (p, s)
    };
    let (pa, sa) = build(false);
    let (pb, sb) = build(true);
    let a = compile_routed(&pa, &sa, &AutomationStore::new());
    let b = compile_routed(&pb, &sb, &AutomationStore::new());
    assert_eq!(a.node_order, b.node_order, "the schedule permuted");
    assert_eq!(a.graph.edge_index, b.graph.edge_index, "edge slots permuted");
    assert_eq!(
        digest_of(&render_routed(&pa, &sa, &AutomationStore::new(), |_| {}, 2_000, 512)),
        digest_of(&render_routed(&pb, &sb, &AutomationStore::new(), |_| {}, 2_000, 512)),
        "the same topology declared in two orders rendered differently"
    );
}

/// A v1 project compiles to the desugared pre-E5 topology and nothing else:
/// every track keeps its implicit unity master feed, the two legacy buses are
/// present as ONE render-side step, and there is not a single explicit edge.
#[test]
fn a_v1_project_desugars_to_exactly_the_pre_e5_topology() {
    let (mut p, mut s) = (project_120(), HashMap::new());
    add_dc_track(&mut p, &mut s, "t1", 0.25);
    add_dc_track(&mut p, &mut s, "t2", 0.35);
    assert!(p.routing.is_empty(), "the fixture declared a routing graph");
    let session = compile_routed(&p, &s, &AutomationStore::new());
    let kinds: Vec<_> = session.node_order.iter().map(|s| s.kind).collect();
    assert_eq!(
        kinds,
        vec![
            render::rt::NodeStepKind::Track(0),
            render::rt::NodeStepKind::Track(1),
            render::rt::NodeStepKind::LegacyReturns,
            render::rt::NodeStepKind::Master,
        ]
    );
    assert_eq!(session.graph.edges.len(), 2, "one implicit feed per track");
    for e in session.graph.edges.iter() {
        assert_eq!(e.dest as usize, ACC_MASTER);
        assert_eq!(e.level_slot, render::routing_rt::IMPLICIT_UNITY);
        assert_eq!(e.comp, 0);
    }
    assert_eq!(session.graph.edge_level_count, 0);
    assert_eq!(session.graph.legacy_comp, [0, 0]);
    assert!(session.graph.fx.is_empty());
}

// ===========================================================================
// §20.2 proof 9 (render half): FX PARAMETER AUTOMATION.
//
// The per-frame seam: `RtFx::lanes` -> `FxNode::set_frame_param`, applied by
// `run_fx_chain` once per FRAME before that frame's `process_frame`. Every
// test below asserts on RENDERED SAMPLES (the file-header rule), and the
// audibility sweep is EXHAUSTIVE over the readable split — a key classified
// `Frame` whose implementation quietly ignores `set_frame_param` fails here,
// which is what keeps `dsp::fx::fx_key_class` honest from the reader side.
//
// Seam honesty (§12.5): these run compile_session_full + render_offline_with —
// model -> snapshot -> the one `RenderCore::render` — and SKIP submit_json /
// sync_after_mutation / the host sync. The host half of proof 9 is
// `agent-surface/tests/fx_param_automation_audible.rs`.
// ===========================================================================

use render::dsp::fx::{FxKindId, FxParamRate, ALL_FX_KINDS};

fn model_kind(kind: FxKindId) -> FxKind {
    match kind {
        FxKindId::Eq => FxKind::Eq,
        FxKindId::Compressor => FxKind::Compressor,
        FxKindId::Gate => FxKind::Gate,
        FxKindId::Delay => FxKind::Delay,
        FxKindId::Reverb => FxKind::Reverb,
        FxKindId::Saturator => FxKind::Saturator,
        FxKindId::Chorus => FxKind::Chorus,
        FxKindId::Utility => FxKind::Utility,
        FxKindId::Limiter => FxKind::Limiter,
    }
}

fn fx_lane_point(a: &mut AutomationStore, track: &str, path: &str, tick: u64, value: f32) {
    a.add_point_path(
        track,
        path,
        render::automation::RawPoint {
            tick,
            value,
            curve: CurveKind::Linear,
        },
    );
}

/// A signal every readable key is audible THROUGH: pulsed (so dynamics keys
/// see above/below-threshold spans and `hold` sees gaps), a continuous sine
/// carrier (so modulated-tap keys see something to shift), and L != R (so
/// `width`/`pan`/`spread` have an image to move).
fn fx_probe_signal(frames: usize) -> Vec<[f32; 2]> {
    (0..frames)
        .map(|i| {
            let t = i as f32 / 48_000.0;
            let burst = (i / 3_000) % 2 == 0;
            let env = if burst { 1.0 } else { 0.02 };
            [
                (2.0 * std::f32::consts::PI * 220.0 * t).sin() * 0.5 * env,
                (2.0 * std::f32::consts::PI * 331.0 * t).sin() * 0.2 * env,
            ]
        })
        .collect()
}

const FX_PROBE_FRAMES: usize = 24_000;

/// (lo, hi) lane values for one key — the spec range, except `spread`, whose
/// range endpoints are aurally the SAME point (an LFO phase offset of 1.0
/// cycle IS 0.0), so it probes the quadrature-vs-inverted half instead.
fn lo_hi(kind: FxKindId, index: usize) -> (f32, f32) {
    let spec = &kind.params()[index];
    if spec.key == "spread" {
        (0.0, 0.5)
    } else {
        (spec.min, spec.max)
    }
}

/// EVERY readable (kind, key) pair, driven by a pinned lane at the two ends
/// of its range, must render DIFFERENT samples — the exhaustive proof that
/// the `Frame` classification never exceeds what `set_frame_param`
/// implementations actually apply. A kind that no-ops a key it declares as
/// `Frame` is an inert lane, and this is the test that catches it.
#[test]
fn every_frame_rate_fx_key_lane_is_audible_kind_by_kind() {
    for kind in ALL_FX_KINDS {
        let frame_keys: Vec<(usize, &str)> = kind
            .params()
            .iter()
            .enumerate()
            .filter(|(_, s)| s.rate == FxParamRate::Frame)
            .map(|(i, s)| (i, s.key))
            .collect();
        if frame_keys.is_empty() {
            assert_eq!(kind, FxKindId::Eq, "only Eq may have zero Frame keys");
            continue;
        }
        for (index, key) in frame_keys {
            // The delay's `feedback`/`tone` are only audible from the SECOND
            // repeat of the default 375 ms tap (~36k frames), so its window
            // renders past the clip and lets the repeats ring out.
            let render_frames: u64 = if kind == FxKindId::Delay {
                48_000
            } else {
                FX_PROBE_FRAMES as u64
            };
            let render_pinned = |value: f32| {
                let (mut p, mut s) = (project_120(), HashMap::new());
                add_synth(&mut p, &mut s, "probe", fx_probe_signal(FX_PROBE_FRAMES));
                add_track(&mut p, "t1");
                place(&mut p, "t1", "c1", "probe", 0, 0, FX_PROBE_FRAMES as u64, 0, 0);
                fx_add(&mut p, "track.t1", "f1", model_kind(kind));
                let mut a = AutomationStore::new();
                fx_lane_point(&mut a, "t1", &format!("track.fx.f1.{key}"), 0, value);
                render_routed(&p, &s, &a, |_| {}, render_frames, 512)
            };
            let (lo, hi) = lo_hi(kind, index);
            let a = render_pinned(lo);
            let b = render_pinned(hi);
            let peak = a
                .iter()
                .chain(b.iter())
                .flat_map(|f| [f[0].abs(), f[1].abs()])
                .fold(0.0_f32, f32::max);
            assert!(
                peak > 0.01,
                "{kind:?}.{key}: both probes are near-silence (peak {peak}) — \
                 the comparison below would be vacuous"
            );
            assert_ne!(
                digest_of(&a),
                digest_of(&b),
                "{kind:?}.{key}: a lane pinned at {lo} renders bit-identically \
                 to one pinned at {hi} — the lane is INERT for this key, so its \
                 `Frame` classification is a lie"
            );
        }
    }
}

/// THE value-mapping and override proof, one key per kind, bit-exact:
///
/// render A: the fx param set in the MODEL to V (atomic path), no lane.
/// render B: the model param set to a DIFFERENT value W, plus a lane pinned
///           at V.
///
/// A == B bit-for-bit proves three things at once: the lane binds to the
/// RIGHT parameter index (a transposed index changes the bytes), the lane's
/// value takes the same conversion + clamp + slew path as the atomic (any
/// divergence changes the bytes), and the lane OVERRIDES the atomic while it
/// exists (W never sounds). The non-vacuity leg proves V vs W is an audible
/// difference, so the equality cannot be two identical silences.
#[test]
fn an_fx_lane_pinned_at_a_value_is_bit_identical_to_the_atomic_at_that_value() {
    let cases: [(FxKindId, &str, f32, f32); 8] = [
        (FxKindId::Compressor, "threshold", -30.0, -5.0),
        (FxKindId::Gate, "threshold", -30.0, -70.0),
        (FxKindId::Delay, "mix", 0.8, 0.1),
        (FxKindId::Reverb, "mix", 0.9, 0.05),
        (FxKindId::Limiter, "ceiling", -12.0, -2.0),
        (FxKindId::Saturator, "drive", 12.0, -6.0),
        (FxKindId::Chorus, "depth", 6.0, 0.5),
        (FxKindId::Utility, "gain", -7.5, 3.0),
    ];
    for (kind, key, v, w) in cases {
        let build = |model_value: Option<f32>, lane_value: Option<f32>| {
            let (mut p, mut s) = (project_120(), HashMap::new());
            add_synth(&mut p, &mut s, "probe", fx_probe_signal(FX_PROBE_FRAMES));
            add_track(&mut p, "t1");
            place(&mut p, "t1", "c1", "probe", 0, 0, FX_PROBE_FRAMES as u64, 0, 0);
            fx_add(&mut p, "track.t1", "f1", model_kind(kind));
            if let Some(mv) = model_value {
                fx_set(&mut p, "track.t1", "f1", key, f64::from(mv));
            }
            let mut a = AutomationStore::new();
            if let Some(lv) = lane_value {
                fx_lane_point(&mut a, "t1", &format!("track.fx.f1.{key}"), 0, lv);
            }
            render_routed(&p, &s, &a, |_| {}, FX_PROBE_FRAMES as u64, 512)
        };
        let atomic_v = build(Some(v), None);
        let overridden = build(Some(w), Some(v));
        assert_eq!(
            digest_of(&atomic_v),
            digest_of(&overridden),
            "{kind:?}.{key}: a lane pinned at {v} over an atomic at {w} must \
             render bit-identically to the atomic at {v} — same conversion, \
             same clamp, same slew, and the lane wins"
        );
        // Non-vacuity: V vs W is audible, so the equality above is meaningful.
        let atomic_w = build(Some(w), None);
        assert_ne!(
            digest_of(&atomic_v),
            digest_of(&atomic_w),
            "{kind:?}.{key}: {v} and {w} render identically — the equality \
             above proves nothing"
        );
    }
}

/// The same seam on the other two host spellings: a lane on a BUS chain's fx
/// and on the MASTER chain's fx each change the render. (The track spelling
/// is exhausted above.)
#[test]
fn fx_lanes_on_bus_and_master_chains_are_audible() {
    let build = |bus_lane: bool, master_lane: bool| {
        let (mut p, mut s) = (project_120(), HashMap::new());
        add_dc_track(&mut p, &mut s, "t1", 0.4);
        node(&mut p, "grp", NodeKind::Group);
        connect(&mut p, "e1", "track.t1", "bus.grp", 1.0, Tap::Post);
        fx_add(&mut p, "bus.grp", "bu", FxKind::Utility);
        fx_add(&mut p, "master", "mu", FxKind::Utility);
        let mut a = AutomationStore::new();
        if bus_lane {
            fx_lane_point(&mut a, "t1", "bus.grp.fx.bu.gain", 0, 0.0);
            fx_lane_point(&mut a, "t1", "bus.grp.fx.bu.gain", 40, -18.0);
        }
        if master_lane {
            fx_lane_point(&mut a, "t1", "master.fx.mu.gain", 0, 0.0);
            fx_lane_point(&mut a, "t1", "master.fx.mu.gain", 40, -12.0);
        }
        render_routed(&p, &s, &a, |_| {}, 3_000, 512)
    };
    let flat = build(false, false);
    assert!(settled(&flat) > 0.3, "fixture silence: {}", settled(&flat));
    let bus = build(true, false);
    let master = build(false, true);
    assert_ne!(
        digest_of(&flat),
        digest_of(&bus),
        "a ramp on bus.grp.fx.bu.gain rendered bit-identically to no automation"
    );
    assert_ne!(
        digest_of(&flat),
        digest_of(&master),
        "a ramp on master.fx.mu.gain rendered bit-identically to no automation"
    );
    // And the ramps genuinely attenuate: the settled level falls.
    assert!(
        settled(&bus) < settled(&flat) * 0.5,
        "the bus fx gain ramp did not attenuate: {} vs {}",
        settled(&bus),
        settled(&flat)
    );
}

/// §20.2 proof 9's invariant leg, at full stretch: fx lanes ramping on a TRACK
/// chain, a BUS chain and the MASTER chain simultaneously — alongside volume,
/// pan, send, edge-level and node-fader lanes, a live sidechain and non-zero
/// PDC — bounce bit-identically at 128 / 417 / 480 / 512.
///
/// A per-BLOCK application of any of those fx lanes (the "hold the lane value
/// for the block" shortcut) makes the rendered value at a given frame depend
/// on where the block boundaries fall, and fails exactly here.
#[test]
fn fx_param_automation_bounces_bit_identically_at_128_417_480_512() {
    let (mut p, mut s) = (project_120(), HashMap::new());
    add_dc_track(&mut p, &mut s, "kick", 0.60);
    add_synth(&mut p, &mut s, "probe", fx_probe_signal(FX_PROBE_FRAMES));
    add_track(&mut p, "pad");
    place(&mut p, "pad", "pad_c", "probe", 0, 0, FX_PROBE_FRAMES as u64, 0, 0);

    node(&mut p, "grp", NodeKind::Group);
    node(&mut p, "lim", NodeKind::Bus);
    connect(&mut p, "e1", "track.pad", "bus.grp", 1.0, Tap::Post);
    connect(&mut p, "e2", "track.kick", "bus.lim", 0.7, Tap::Pre);

    // Latency on a bus so PDC is live under the automation.
    fx_add(&mut p, "bus.lim", "l1", FxKind::Limiter);
    // Track chain: saturator with a drive lane.
    fx_add(&mut p, "track.pad", "sat", FxKind::Saturator);
    // Bus chain: keyed compressor with threshold + makeup lanes.
    fx_add(&mut p, "bus.grp", "cmp", FxKind::Compressor);
    p.apply_cmd(&Cmd::FxSidechainSet {
        target: NodeRef::parse("bus.grp").unwrap(),
        fx_id: "cmp".into(),
        source: NodeRef::parse("track.kick").unwrap(),
    })
    .unwrap();
    // Master chain: utility with gain + width lanes.
    fx_add(&mut p, "master", "mu", FxKind::Utility);

    let mut a = AutomationStore::new();
    for (path, lo, hi) in [
        ("track.fx.sat.drive", 0.0_f32, 18.0_f32),
        ("bus.grp.fx.cmp.threshold", 0.0, -45.0),
        ("bus.grp.fx.cmp.makeup", 0.0, 9.0),
        ("master.fx.mu.gain", 0.0, -9.0),
        ("master.fx.mu.width", 1.0, 0.2),
    ] {
        fx_lane_point(&mut a, "pad", path, 0, lo);
        fx_lane_point(&mut a, "pad", path, 480, hi);
    }
    // The pre-existing lane families ride along so cursor interplay is under
    // test too.
    for (path, lo, hi) in [
        ("track.volume", -6.0_f32, 0.0_f32),
        ("track.pan", -0.6, 0.6),
        ("route.edge.e1.level", 0.4, 1.0),
        ("bus.grp.gain", -9.0, 0.0),
    ] {
        fx_lane_point(&mut a, "pad", path, 0, lo);
        fx_lane_point(&mut a, "pad", path, 480, hi);
    }

    // Guards: PDC live, chains live, lanes actually baked onto the fx.
    let probe = compile_routed(&p, &s, &a);
    assert!(
        probe.graph.edges.iter().any(|e| e.comp > 0),
        "no edge carries compensation — PDC is not under test"
    );
    let bound: usize = probe.graph.fx.iter().map(|f| f.lanes.len()).sum();
    assert_eq!(bound, 5, "expected 5 fx lane bindings, found {bound}");
    drop(probe);

    let reference = render_routed(&p, &s, &a, |_| {}, FX_PROBE_FRAMES as u64, 128);
    let peak = reference
        .iter()
        .flat_map(|f| [f[0].abs(), f[1].abs()])
        .fold(0.0_f32, f32::max);
    assert!(peak > 0.05, "the parity reference is silence (peak {peak})");
    println!(
        "fx-lane parity reference: {} frames, chunk 128, digest {:016x}",
        reference.len(),
        digest_of(&reference)
    );
    for chunk in [417_usize, 480, 512] {
        let got = render_routed(&p, &s, &a, |_| {}, FX_PROBE_FRAMES as u64, chunk);
        println!("fx-lane parity: chunk {chunk}, digest {:016x}", digest_of(&got));
        assert_eq!(
            digest_of(&got),
            digest_of(&reference),
            "fx parameter automation is NOT bit-identical at chunk {chunk} vs \
             128 — an fx lane is being applied per BLOCK somewhere (§6.1)"
        );
    }
}

// (The RT zero-allocation proof for the fx-lane read path lives in
// `null_and_alloc.rs::a_capacity_graph_renders_without_allocating`, which
// installs the counting allocator this file deliberately does not; its
// capacity fixture now carries fx lanes on all three host spellings.)
