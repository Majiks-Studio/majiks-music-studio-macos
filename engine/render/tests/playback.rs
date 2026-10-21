//! Deterministic playback tests: sample-locked placement, loop folding,
//! declick ramps, fades, SRC truthfulness. All manual-clock rendering (no
//! audio device, nothing audible).

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use render::compile::compile_session;
use render::engine::EngineConfig;
use render::fixtures;
use render::media::{load_wav_stereo_48k, AudioBuf};
use render::offline::{render_offline_with, residual, ManualRenderer, ScheduledCommand};
use render::rt::{CaptureBuf, RenderCommand, ENGINE_SAMPLE_RATE, MICRO_FADE_FRAMES};
use timeline_core::{Bpm, Command, FadeShape, Project, Source, TempoMap};

fn tmp_dir(name: &str) -> std::path::PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn project_120() -> Project {
    Project::new(ENGINE_SAMPLE_RATE, TempoMap::single(Bpm::from_int(120).unwrap()))
}

fn add_synth_source(project: &mut Project, sources: &mut HashMap<String, Arc<AudioBuf>>, id: &str, samples: Vec<[f32; 2]>) {
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

fn place_frame(
    project: &mut Project,
    track: &str,
    clip: &str,
    source: &str,
    start_frame: u64,
    offset: u64,
    len: u64,
    gain_db: f32,
    fade_in: u64,
    fade_out: u64,
) {
    project
        .apply(&Command::ClipPlace {
            track_id: track.into(),
            clip_id: clip.into(),
            source_id: source.into(),
            start_tick: None,
            start_frame: Some(start_frame),
            offset_frames: offset,
            len_frames: len,
            gain_db,
            fade_in_frames: fade_in,
            fade_out_frames: fade_out,
            fade_shape: FadeShape::EqualPower,
        })
        .unwrap();
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

fn render_project(
    project: &Project,
    sources: &HashMap<String, Arc<AudioBuf>>,
    total: u64,
    chunk: usize,
    extra: Vec<ScheduledCommand>,
) -> Vec<[f32; 2]> {
    let cfg = EngineConfig::default();
    let session = compile_session(project, sources, cfg.max_tracks).unwrap();
    let mut renderer = ManualRenderer::new(&cfg);
    for (i, t) in project.tracks.iter().enumerate() {
        renderer.params().set_track_mute(i, t.mute);
    }
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
    render_offline_with(&mut renderer, schedule, total, chunk)
}

#[test]
fn impulse_lands_sample_exact_at_bar_position() {
    let mut project = project_120();
    let mut sources = HashMap::new();
    // Impulse at source frame 0.
    let mut samples = vec![[0.0_f32; 2]; 1000];
    samples[0] = [1.0, -1.0];
    add_synth_source(&mut project, &mut sources, "imp", samples);
    add_track(&mut project, "t1");
    // Bar 1 at 120 BPM 48k = frame 96000 exactly (rational tick math).
    let start = project.tempo.tick_to_frame(project.tempo.bar_to_tick(1), 48_000);
    assert_eq!(start, 96_000);
    place_frame(&mut project, "t1", "c1", "imp", start, 0, 1000, 0.0, 0, 0);

    let out = render_project(&project, &sources, 97_000, 128, vec![]);
    assert_eq!(out[96_000], [1.0, -1.0], "impulse exactly at bar 1");
    assert_eq!(out[95_999], [0.0, 0.0]);
    assert_eq!(out[96_001], [0.0, 0.0]);
}

#[test]
fn clip_gain_and_offset_apply() {
    let mut project = project_120();
    let mut sources = HashMap::new();
    let mut samples = vec![[0.0_f32; 2]; 2000];
    samples[500] = [1.0, 1.0];
    add_synth_source(&mut project, &mut sources, "imp", samples);
    add_track(&mut project, "t1");
    // Offset 400: source frame 500 appears at rel 100 -> abs 10_100.
    place_frame(&mut project, "t1", "c1", "imp", 10_000, 400, 1_000, -6.0, 0, 0);
    let out = render_project(&project, &sources, 11_000, 128, vec![]);
    let expected = 10.0_f32.powf(-6.0 / 20.0);
    assert!((out[10_100][0] - expected).abs() < 1e-6);
    assert_eq!(out[10_099], [0.0, 0.0]);
}

#[test]
fn equal_power_fades_shape_the_clip() {
    let mut project = project_120();
    let mut sources = HashMap::new();
    add_synth_source(&mut project, &mut sources, "dc", vec![[1.0, 1.0]; 10_000]);
    add_track(&mut project, "t1");
    let fade = 1_000_u64;
    place_frame(&mut project, "t1", "c1", "dc", 2_000, 0, 8_000, 0.0, fade, fade);
    let out = render_project(&project, &sources, 11_000, 128, vec![]);

    // First clip frame is silent (x = 0).
    assert_eq!(out[2_000], [0.0, 0.0]);
    // Halfway through the fade-in: sin(pi/4).
    let expected_mid = (std::f32::consts::FRAC_PI_2 * 0.5).sin();
    assert!((out[2_000 + 500][0] - expected_mid).abs() < 1e-4);
    // Fade-in done: unity.
    assert!((out[2_000 + 1_500][0] - 1.0).abs() < 1e-6);
    // Fade-out mirrors: frame at from_end = 500 -> sin(pi/4).
    assert!((out[2_000 + 8_000 - 500][0] - expected_mid).abs() < 1e-4);
    // Monotonic rise across the fade-in.
    for w in out[2_000..2_000 + fade as usize].windows(2) {
        assert!(w[1][0] >= w[0][0] - 1e-6);
    }
    // Past the clip end: silence again.
    assert_eq!(out[2_000 + 8_000 + 1], [0.0, 0.0]);
}

#[test]
fn loop_region_folds_sample_exact() {
    let mut project = project_120();
    let mut sources = HashMap::new();
    // Identifiable ramp content.
    let samples: Vec<[f32; 2]> = (0..48_000)
        .map(|i| {
            let v = (i % 977) as f32 / 977.0;
            [v, -v]
        })
        .collect();
    add_synth_source(&mut project, &mut sources, "ramp", samples);
    add_track(&mut project, "t1");
    place_frame(&mut project, "t1", "c1", "ramp", 0, 0, 48_000, 0.0, 0, 0);

    let out = render_project(
        &project,
        &sources,
        10_000,
        128,
        vec![ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::LoopSet {
                start_frame: 1_000,
                end_frame: 2_000,
            },
        }],
    );
    // Position folds AT loop end: frame 2000 plays source frame 1000.
    assert_eq!(out[2_000], out[1_000]);
    // Successive passes are identical (compare well past the play ramp).
    assert_eq!(out[2_000..3_000], out[3_000..4_000]);
    assert_eq!(out[3_000..4_000], out[4_000..5_000]);
}

#[test]
fn seek_declicks_with_ramp() {
    let mut project = project_120();
    let mut sources = HashMap::new();
    add_synth_source(&mut project, &mut sources, "dc", vec![[1.0, 1.0]; 48_000]);
    add_track(&mut project, "t1");
    place_frame(&mut project, "t1", "c1", "dc", 0, 0, 48_000, 0.0, 0, 0);

    let seek_at = 4_096_u64;
    let out = render_project(
        &project,
        &sources,
        8_192,
        128,
        vec![ScheduledCommand {
            at_frame: seek_at,
            command: RenderCommand::Seek { frame: 20_000 },
        }],
    );
    let i = seek_at as usize;
    let ramp = MICRO_FADE_FRAMES as usize;
    let slope = 1.0 / MICRO_FADE_FRAMES as f32 + 1e-6;

    // ⚠️ THIS TEST USED TO REQUIRE THE CLICK IT IS NAMED AFTER.
    //
    // It asserted `out[i][0] < 0.02` -- "the first frame after the jump starts
    // the ramp near zero" -- which is a full-scale STEP from the steady 1.0 one
    // sample earlier, on DC material, i.e. the loudest discontinuity this
    // engine can produce. `RenderCommand::Seek` assigned `transport_gain = 0.0`
    // outright, and this line pinned it. "Landing in silence" is only
    // click-free if you ARRIVE at silence; stepping to it is the same edge
    // wearing the opposite sign.
    //
    // The seek is now deferred behind the declick that already existed: the
    // gain glides DOWN to exactly zero, the position moves on that frame, and
    // the gain glides back up. So the contract asserted here is the one that
    // was meant all along -- a bounded slope THROUGH the seek, in both
    // directions -- rather than a step in one of them.

    // Steady 1.0 before the seek.
    assert!((out[i - 1][0] - 1.0).abs() < 1e-6);

    // NO STEP ANYWHERE ACROSS THE WHOLE EVENT. This is the assertion the old
    // shape could not make, and it is the reason the rest of it changed.
    for (n, w) in out[i - 1..i + 2 * ramp + 8].windows(2).enumerate() {
        let step = (w[1][0] - w[0][0]).abs();
        assert!(
            step <= slope,
            "seek stepped by {step} at frame {} (declick slope is {slope})",
            i - 1 + n
        );
    }

    // Down to EXACTLY zero within one declick window, monotonically. The
    // arrival frame is found rather than hard-coded: the command lands at the
    // next block boundary, so its exact index depends on the block size, and
    // pinning it would make this test about the scheduler instead of about the
    // fade. `Slew`-style arrival is exact, so `== 0.0` is a real assertion --
    // the jump happens on the frame the gain IS zero, and a content change at
    // a merely-small gain is still a content change.
    let zero_at = (i..i + ramp + 8)
        .find(|&n| out[n][0] == 0.0)
        .unwrap_or_else(|| {
            panic!(
                "the fade must ARRIVE at exactly zero; nearest was {:e}",
                out[i..i + ramp + 8]
                    .iter()
                    .map(|f| f[0])
                    .fold(f32::MAX, f32::min)
            )
        });
    for w in out[i..=zero_at].windows(2) {
        assert!(w[1][0] <= w[0][0] + 1e-6, "the fade-out must not rise");
    }

    // Then monotonically back to unity within the next window.
    for w in out[zero_at..zero_at + ramp].windows(2) {
        assert!(w[1][0] >= w[0][0] - 1e-6, "the fade-in must not fall");
    }
    assert!(
        (out[zero_at + ramp][0] - 1.0).abs() < 1e-3,
        "unity must be restored one declick window after the jump, got {}",
        out[zero_at + ramp][0]
    );
}

#[test]
fn mute_glides_without_steps() {
    let mut project = project_120();
    let mut sources = HashMap::new();
    add_synth_source(&mut project, &mut sources, "dc", vec![[1.0, 1.0]; 48_000]);
    add_track(&mut project, "t1");
    place_frame(&mut project, "t1", "c1", "dc", 0, 0, 48_000, 0.0, 0, 0);

    let cfg = EngineConfig::default();
    let session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let mut renderer = ManualRenderer::new(&cfg);
    renderer.send(RenderCommand::SetSession(session));
    renderer.send(RenderCommand::Play);
    let mut warmup = vec![[0.0_f32; 2]; 2_048];
    renderer.render(&mut warmup);
    assert!((warmup[2_000][0] - 1.0).abs() < 1e-6);

    renderer.params().set_track_mute(0, true);
    let mut out = vec![[0.0_f32; 2]; 512];
    renderer.render(&mut out);
    // Glide to silence within 5 ms, no per-frame step larger than the slope.
    let step = 1.0 / MICRO_FADE_FRAMES as f32;
    for w in out.windows(2) {
        assert!((w[0][0] - w[1][0]) <= step + 1e-6, "step too large");
    }
    assert_eq!(out[300], [0.0, 0.0], "silent after the glide");
}

#[test]
fn capture_tap_records_exactly_what_was_rendered() {
    let mut project = project_120();
    let mut sources = HashMap::new();
    let samples: Vec<[f32; 2]> = (0..9_600).map(|i| {
        let v = ((i as f32) * 0.001).sin() * 0.5;
        [v, v]
    }).collect();
    add_synth_source(&mut project, &mut sources, "tone", samples);
    add_track(&mut project, "t1");
    place_frame(&mut project, "t1", "c1", "tone", 0, 0, 9_600, 0.0, 100, 100);

    let cfg = EngineConfig::default();
    let session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let mut renderer = ManualRenderer::new(&cfg);
    renderer.send(RenderCommand::SetSession(session));
    let total = 4_096_usize;
    renderer.send(RenderCommand::CaptureStart {
        capture: CaptureBuf::new(total),
        start_transport: true,
    });
    let mut out = vec![[0.0_f32; 2]; total];
    for chunk in out.chunks_mut(128) {
        renderer.render(chunk);
    }
    let captured = renderer
        .wait_capture(std::time::Duration::from_millis(100))
        .expect("capture completed");
    let r = residual(&out, &captured.data);
    assert!(r.bit_identical, "capture must be bit-identical to output");
}

#[test]
fn src_is_truthful_for_44k1_and_mono() {
    let dir = tmp_dir("src-fixtures");
    fixtures::generate_all(&dir).unwrap();

    let buf = load_wav_stereo_48k(&dir.join("sweep_44k1_stereo.wav")).unwrap();
    // 6 s at 44.1 kHz resamples to exactly 288000 frames at 48 kHz.
    assert_eq!(buf.sample_rate, 48_000, "stamped rate is the real rate");
    assert_eq!(buf.source_sample_rate, 44_100);
    assert_eq!(buf.len_frames(), 288_000);
    // Content actually present (not zeros).
    let peak = buf.samples.iter().map(|s| s[0].abs()).fold(0.0_f32, f32::max);
    assert!(peak > 0.3, "resampled sweep has energy, peak {peak}");

    let mono = load_wav_stereo_48k(&dir.join("tone_440_48k_mono.wav")).unwrap();
    assert_eq!(mono.source_channels, 1);
    assert_eq!(mono.len_frames(), 192_000);
    for frame in mono.samples.iter().step_by(1_000) {
        assert_eq!(frame[0], frame[1], "mono upmix duplicates the channel");
    }
}

#[test]
fn fixtures_are_deterministic() {
    let dir_a = tmp_dir("fixtures-a");
    let dir_b = tmp_dir("fixtures-b");
    let a = fixtures::generate_all(&dir_a).unwrap();
    let b = fixtures::generate_all(&dir_b).unwrap();
    assert_eq!(a, b, "two generations hash identically");
}
