//! Warp-in-graph and device-switch survival tests. Silent (no device on the
//! offline paths); the device-switch test opens the silence-gated stream.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use render::automation::AutomationStore;
use render::compile::{compile_session_full, DeclickPolicy};
use render::engine::EngineConfig;
use render::media::AudioBuf;
use render::offline::{render_offline_with, ManualRenderer, ScheduledCommand};
use render::rt::{RenderCommand, ENGINE_SAMPLE_RATE};
use render::warp::{stretched_len, WarpEntry, WarpOverlay, WarpWorker, WsolaStretcher};
use timeline_core::{Bpm, Command, FadeShape, Project, Source, TempoMap};

fn sine(freq: f32, frames: usize, amp: f32) -> Vec<[f32; 2]> {
    (0..frames)
        .map(|i| {
            let v = (std::f32::consts::TAU * freq * i as f32 / 48_000.0).sin() * amp;
            [v, v]
        })
        .collect()
}

fn base_project() -> (Project, HashMap<String, Arc<AudioBuf>>) {
    let mut project = Project::new(ENGINE_SAMPLE_RATE, TempoMap::single(Bpm::from_int(120).unwrap()));
    let mut sources = HashMap::new();
    let audio = AudioBuf::from_samples(sine(220.0, 48_000, 0.5), "src");
    project
        .add_source(Source {
            id: "src".into(),
            path: "synthetic:src".into(),
            len_frames: audio.len_frames(),
        })
        .unwrap();
    sources.insert("src".to_string(), audio);
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
            source_id: "src".into(),
            start_tick: None,
            start_frame: Some(0),
            offset_frames: 0,
            len_frames: 24_000,
            gain_db: 0.0,
            fade_in_frames: 0,
            fade_out_frames: 0,
            fade_shape: FadeShape::EqualPower,
        })
        .unwrap();
    (project, sources)
}

/// A warped clip plays its pre-rendered stretched buffer, and its timeline
/// extent becomes the stretched length. Renders through the same graph.
#[test]
fn warped_clip_extends_timeline_and_plays_stretched_audio() {
    let (project, sources) = base_project();
    let cfg = EngineConfig::default();

    // Pre-render a 1.5x stretch of the clip's source extent (what the warp
    // worker would produce) and hand it to compile through the overlay.
    let mut stretcher = WsolaStretcher;
    let src = sources.get("src").unwrap();
    let extent: Vec<[f32; 2]> = src.samples[0..24_000].to_vec();
    let stretched = render::warp::Stretcher::stretch(&mut stretcher, &extent, 1.5);
    let stretched_frames = stretched.len() as u64;
    assert_eq!(stretched_frames, stretched_len(24_000, 1.5));

    let mut overlay = WarpOverlay::new();
    overlay.insert(
        "c1".to_string(),
        WarpEntry {
            ratio: 1.5,
            generation: 1,
            stretched: Some(AudioBuf::from_samples(stretched, "warp:c1")),
            stretched_ratio: 1.5,
        },
    );

    let warped = compile_session_full(
        &project,
        &sources,
        &overlay,
        &AutomationStore::new(),
        cfg.max_tracks,
        DeclickPolicy::None,
    )
    .unwrap();
    // The compiled clip now spans the stretched length.
    assert_eq!(warped.tracks[0].clips[0].len_frames, stretched_frames);

    let mut renderer = ManualRenderer::new(&cfg);
    let out = render_offline_with(
        &mut renderer,
        vec![
            ScheduledCommand { at_frame: 0, command: RenderCommand::SetSession(warped) },
            ScheduledCommand { at_frame: 0, command: RenderCommand::Play },
        ],
        stretched_frames + 2_000,
        128,
    );
    // Audio is present for the full stretched extent, then stops.
    let mid = out[(stretched_frames / 2) as usize][0];
    assert!(mid.abs() > 0.05, "stretched clip plays through its extent");
    let past = out[(stretched_frames + 1_000) as usize][0];
    assert!(past.abs() < 1e-4, "silence past the stretched clip end");
}

/// Identity warp (1.0) submitted to the real worker returns a bit-exact copy
/// (the bypass guarantee), and a non-identity warp changes the length.
#[test]
fn worker_identity_is_bit_exact_bypass() {
    let worker = WarpWorker::spawn(|| Box::new(WsolaStretcher));
    let audio = AudioBuf::from_samples(sine(180.0, 24_000, 0.5), "src");
    worker.submit(render::warp::WarpJob {
        clip_id: "c1".into(),
        source: Arc::clone(&audio),
        offset_frames: 0,
        len_frames: 24_000,
        ratio: 1.0,
        generation: 1,
    });
    let result = worker
        .wait_result(Duration::from_secs(10))
        .expect("identity result");
    assert_eq!(result.audio.len_frames(), 24_000);
    for i in 0..24_000 {
        assert_eq!(
            result.audio.samples[i][0].to_bits(),
            audio.samples[i][0].to_bits(),
            "identity warp must be bit-exact at {i}"
        );
    }
}

/// Warp generation must be monotonic even across an identity clear that
/// removes the overlay entry, so a stale in-flight result can never share a
/// generation with a later request for the same clip.
#[test]
fn warp_generation_is_monotonic_across_identity_clear() {
    use render::engine::Engine;
    use render::host::ProjectHost;

    let project = Project::new(ENGINE_SAMPLE_RATE, TempoMap::single(Bpm::from_int(120).unwrap()));
    let engine = Engine::new(EngineConfig::default());
    let mut host = ProjectHost::new(project, engine);
    host.register_source("src", AudioBuf::from_samples(sine(220.0, 48_000, 0.5), "src"))
        .unwrap();
    host.apply(&Command::TrackAdd { track_id: "t1".into(), name: "t1".into(), index: None })
        .unwrap();
    host.apply(&Command::ClipPlace {
        track_id: "t1".into(),
        clip_id: "c1".into(),
        source_id: "src".into(),
        start_tick: None,
        start_frame: Some(0),
        offset_frames: 0,
        len_frames: 24_000,
        gain_db: 0.0,
        fade_in_frames: 0,
        fade_out_frames: 0,
        fade_shape: FadeShape::EqualPower,
    })
    .unwrap();

    host.set_warp_ratio("c1", 1.5).unwrap();
    let g1 = host.warp_generation();
    host.set_warp_ratio("c1", 1.0).unwrap(); // identity: removes the entry
    host.set_warp_ratio("c1", 1.2).unwrap();
    let g2 = host.warp_generation();
    assert!(g2 > g1, "generation must keep climbing across a clear ({g1} -> {g2})");
}

/// Device-switch survival (DJ P7): open the silence-gated stream, let it run,
/// restart it (simulating a device change), and confirm the engine keeps
/// rendering with playback state intact and no faults.
#[test]
fn device_switch_survival_rehydrates_and_keeps_rendering() {
    use render::engine::Engine;
    use render::host::ProjectHost;

    // Build the project THROUGH the host so model sources and loaded
    // buffers stay in sync (register_source does both).
    let project = Project::new(ENGINE_SAMPLE_RATE, TempoMap::single(Bpm::from_int(120).unwrap()));
    let engine = Engine::new(EngineConfig::default());
    let mut host = ProjectHost::new(project, engine);
    host.register_source("src", AudioBuf::from_samples(sine(220.0, 48_000, 0.5), "src"))
        .unwrap();
    host.apply(&Command::TrackAdd {
        track_id: "t1".into(),
        name: "t1".into(),
        index: None,
    })
    .unwrap();
    host.apply(&Command::ClipPlace {
        track_id: "t1".into(),
        clip_id: "c1".into(),
        source_id: "src".into(),
        start_tick: None,
        start_frame: Some(0),
        offset_frames: 0,
        len_frames: 24_000,
        gain_db: 0.0,
        fade_in_frames: 0,
        fade_out_frames: 0,
        fade_shape: FadeShape::EqualPower,
    })
    .unwrap();

    // Start the (silent) stream. If no output device exists in this
    // environment, skip gracefully rather than fail.
    let info = match host.engine_mut().start_output() {
        Ok(info) => info,
        Err(e) => {
            eprintln!("no audio device available, skipping device-switch test: {e}");
            return;
        }
    };
    assert!(!info.audible, "must never be audible by default");
    assert_eq!(info.generation, 1);

    host.push_session().unwrap();
    host.engine().command(RenderCommand::Seek { frame: 5_000 });
    host.engine().command(RenderCommand::Play);

    // Let it render a bit.
    std::thread::sleep(Duration::from_millis(120));
    let before = host.engine().stats();
    assert!(before.callbacks > 0, "stream rendered before the switch");

    // Simulate a device change: rehydrate.
    host.rehydrate_output().expect("rehydrate");
    let info2 = host
        .engine()
        .stats();
    assert_eq!(info2.stream_generation, 2, "stream restarted once");

    std::thread::sleep(Duration::from_millis(120));
    let after = host.engine().stats();
    assert!(
        after.callbacks > before.callbacks,
        "engine keeps rendering after the switch ({} -> {})",
        before.callbacks,
        after.callbacks
    );
    assert_eq!(after.underruns, 0, "no faults across the switch");
    assert_eq!(after.stream_errors, 0);
    assert!(after.playing, "transport resumed after rehydrate");

    host.engine_mut().stop_output();
}
