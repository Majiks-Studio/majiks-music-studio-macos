//! The two hard P0-B bars, as automated tests:
//! 1. Null test (small frame count): offline bounce vs a manually clocked
//!    "realtime-style" run of the identical command schedule through the
//!    SAME render function, at different block sizes. Bar: < -120 dBFS peak
//!    residual (measured: bit-identical).
//! 2. Allocation-free render: the counting global allocator observes zero
//!    allocator hits inside render scopes across a command-hammered run,
//!    after proving it can see allocations at all (positive control).

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use render::compile::compile_session;
use render::engine::EngineConfig;
use render::fixtures;
use render::guard;
use render::media::{load_wav_stereo_48k, AudioBuf};
use render::offline::{render_offline_with, residual, ManualRenderer, ScheduledCommand};
use render::rt::{RenderCommand, ENGINE_SAMPLE_RATE};
use timeline_core::cmd::{Cmd, NoteSpec};
use timeline_core::model::DeviceKind;
use timeline_core::tempo::PPQ;
use timeline_core::{Bpm, Command, FadeShape, Num, Project, Source, TempoMap};

#[global_allocator]
static ALLOC: guard::CountingAlloc = guard::CountingAlloc;

fn build_null_project() -> (Project, HashMap<String, Arc<AudioBuf>>) {
    build_null_project_with(true)
}

/// E1/E2: a third track carrying a MIDI clip and a synth device, so the null
/// test and the allocation test both run WITH AN INSTRUMENT ACTUALLY PLAYING.
/// The scheduled loop and seek in `schedule_for` then exercise the fold and
/// seek paths of the note cursor as part of the parity gate itself, rather
/// than in a separate suite that could drift away from it.
fn add_instrument_track(project: &mut Project) {
    project
        .apply(&Command::TrackAdd {
            track_id: "t3".into(),
            name: "t3".into(),
            index: None,
        })
        .unwrap();
    project
        .apply_cmd(&Cmd::DeviceAdd {
            track_id: "t3".into(),
            device_id: "inst1".into(),
            kind: DeviceKind::Synth,
        })
        .unwrap();
    project
        .apply_cmd(&Cmd::ClipPlaceMidi {
            clip_id: "cm1".into(),
            track_id: "t3".into(),
            start_ticks: 0,
            length_ticks: PPQ * 16,
        })
        .unwrap();
    let notes: Vec<NoteSpec> = (0..16u64)
        .map(|i| NoteSpec {
            note_id: format!("n{i}"),
            start_ticks: i * (PPQ / 2),
            length_ticks: PPQ,
            pitch: 48 + (i % 13) as u8,
            velocity: Num::int(70 + (i % 40) as i64),
        })
        .collect();
    project
        .apply_cmd(&Cmd::NoteAdd {
            clip_id: "cm1".into(),
            notes,
        })
        .unwrap();
    let d = project.tracks.last_mut().unwrap().devices.first_mut().unwrap();
    for (k, v) in [
        ("attack", 0.002_f64),
        ("decay", 0.08),
        ("sustain", 0.7),
        ("release", 0.05),
        ("cutoff", 6_000.0),
    ] {
        d.params.insert(
            k.into(),
            Num(serde_json::Number::from_f64(v).expect("finite")),
        );
    }
}

fn build_null_project_with(instrument: bool) -> (Project, HashMap<String, Arc<AudioBuf>>) {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("null-fixtures");
    std::fs::create_dir_all(&dir).unwrap();
    fixtures::generate_all(&dir).unwrap();

    let mut project = Project::new(
        ENGINE_SAMPLE_RATE,
        TempoMap::single(Bpm::from_int(92).unwrap()),
    );
    let mut sources: HashMap<String, Arc<AudioBuf>> = HashMap::new();
    for (id, file) in [
        ("click92", "click_92bpm_48k_stereo.wav"),
        ("sweep441", "sweep_44k1_stereo.wav"),
        ("tone", "tone_440_48k_mono.wav"),
    ] {
        let audio = Arc::new(load_wav_stereo_48k(&dir.join(file)).unwrap());
        project
            .add_source(Source {
                id: id.into(),
                path: file.into(),
                len_frames: audio.len_frames(),
            })
            .unwrap();
        sources.insert(id.to_string(), audio);
    }
    for track in ["t1", "t2"] {
        project
            .apply(&Command::TrackAdd {
                track_id: track.into(),
                name: track.into(),
                index: None,
            })
            .unwrap();
    }
    let place = |project: &mut Project, track: &str, clip: &str, source: &str, start: u64, offset: u64, len: u64, gain: f32, fi: u64, fo: u64| {
        project
            .apply(&Command::ClipPlace {
                track_id: track.into(),
                clip_id: clip.into(),
                source_id: source.into(),
                start_tick: None,
                start_frame: Some(start),
                offset_frames: offset,
                len_frames: len,
                gain_db: gain,
                fade_in_frames: fi,
                fade_out_frames: fo,
                fade_shape: FadeShape::EqualPower,
            })
            .unwrap();
    };
    place(&mut project, "t1", "c1", "click92", 0, 0, 90_000, 0.0, 0, 0);
    place(&mut project, "t1", "c2", "tone", 20_000, 5_000, 60_000, -3.0, 2_400, 2_400);
    place(&mut project, "t2", "c3", "sweep441", 10_000, 1_000, 80_000, -6.0, 4_800, 9_600);
    if instrument {
        add_instrument_track(&mut project);
    }
    (project, sources)
}

fn schedule_for(session: Box<render::rt::RtSession>) -> Vec<ScheduledCommand> {
    vec![
        ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::SetSession(session),
        },
        ScheduledCommand {
            at_frame: 0,
            command: RenderCommand::Play,
        },
        // Identical mid-render transport work in every run: a loop
        // engages, playback folds through it, the loop clears, then a seek.
        ScheduledCommand {
            at_frame: 24_000,
            command: RenderCommand::LoopSet {
                start_frame: 30_000,
                end_frame: 42_000,
            },
        },
        ScheduledCommand {
            at_frame: 60_000,
            command: RenderCommand::LoopClear,
        },
        ScheduledCommand {
            at_frame: 70_000,
            command: RenderCommand::Seek { frame: 15_000 },
        },
    ]
}

#[test]
fn null_test_small_offline_vs_realtime_style() {
    let (project, sources) = build_null_project();
    let cfg = EngineConfig::default();
    let total = 96_000_u64; // 2 s

    // "Captured realtime" stand-in: the real callback path, clocked
    // manually at the live stream's block size (128).
    let session_rt = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let mut rt = ManualRenderer::new(&cfg);
    let realtime = render_offline_with(&mut rt, schedule_for(session_rt), total, 128);

    // Offline bounce: same graph, bigger blocks (split at command frames).
    let session_off = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let mut off = ManualRenderer::new(&cfg);
    let offline = render_offline_with(&mut off, schedule_for(session_off), total, 512);

    let r = residual(&realtime, &offline);
    assert!(
        r.peak_dbfs < -120.0,
        "null test bar: peak residual {} dBFS (max_abs {})",
        r.peak_dbfs,
        r.max_abs
    );
    assert!(r.bit_identical, "expected bit-identical renders");

    // Odd chunk size as a third witness.
    let session_odd = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let mut odd = ManualRenderer::new(&cfg);
    let odd_out = render_offline_with(&mut odd, schedule_for(session_odd), total, 480);
    let r_odd = residual(&realtime, &odd_out);
    assert!(r_odd.bit_identical, "chunk-size independence (480)");

    // Bounce size 512 vs the live 128 is the headline, but the odd size is
    // where a block-rate note dispatch would show up.
    let session_417 = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    let mut odd417 = ManualRenderer::new(&cfg);
    let out417 = render_offline_with(&mut odd417, schedule_for(session_417), total, 417);
    assert!(
        residual(&realtime, &out417).bit_identical,
        "chunk-size independence (417)"
    );

    // The output is actually audio, not silence.
    let peak = realtime.iter().map(|f| f[0].abs().max(f[1].abs())).fold(0.0_f32, f32::max);
    assert!(peak > 0.2, "render produced real signal, peak {peak}");

    // ...AND the instrument is part of what was compared. Without this the
    // parity gate would be green over a mix that never contained a note —
    // "bit-identical with an instrument playing" would be a claim about
    // silence. Removing the MIDI track must change the render.
    let (no_inst, no_inst_sources) = build_null_project_with(false);
    let session_ni = compile_session(&no_inst, &no_inst_sources, cfg.max_tracks).unwrap();
    let mut ni = ManualRenderer::new(&cfg);
    let without = render_offline_with(&mut ni, schedule_for(session_ni), total, 128);
    assert!(
        !residual(&realtime, &without).bit_identical,
        "the instrument track contributed NOTHING to the null-test render: \
         the parity gate above is vacuous"
    );
}

#[test]
fn allocation_guard_positive_control_then_hammered_render_is_clean() {
    // Positive control: the guard sees allocations inside a render scope.
    let before = guard::violations();
    guard::enter_render_scope();
    let v: Vec<u8> = Vec::with_capacity(64);
    drop(v);
    guard::leave_render_scope();
    let after = guard::violations();
    assert!(
        after > before,
        "guard must detect the control allocation (before {before}, after {after})"
    );

    // Real run: hammered render, zero allocator hits inside render().
    let (project, sources) = build_null_project();
    let cfg = EngineConfig::default();
    let mut renderer = ManualRenderer::new(&cfg);
    let session = compile_session(&project, &sources, cfg.max_tracks).unwrap();
    renderer.send(RenderCommand::SetSession(session));
    renderer.send(RenderCommand::Play);

    let mut out = vec![[0.0_f32; 2]; 128];
    // Warm up (first blocks drain the setup commands).
    for _ in 0..4 {
        renderer.render(&mut out);
    }

    let clean_before = guard::violations();
    // Track 2 is the MIDI/synth track: mute the two audio tracks so the level
    // observed below can ONLY have come from the instrument. An alloc test
    // over a silent render path proves nothing.
    renderer.params().set_track_mute(0, true);
    renderer.params().set_track_mute(1, true);
    let mut instrument_peak = 0.0_f32;
    for block in 0..2_000_u64 {
        // Control-side pressure BETWEEN blocks (allocations here are legal
        // and expected; they must never show up inside render()).
        match block % 16 {
            0 => {
                let fresh = compile_session(&project, &sources, cfg.max_tracks).unwrap();
                renderer.send(RenderCommand::SetSession(fresh));
            }
            3 => {
                renderer.send(RenderCommand::Seek {
                    frame: (block * 977) % 90_000,
                });
            }
            5 => {
                renderer.send(RenderCommand::LoopSet {
                    start_frame: 10_000,
                    end_frame: 20_000,
                });
            }
            7 => {
                renderer.send(RenderCommand::LoopClear);
            }
            9 => {
                renderer.params().set_track_gain_db(1, -6.0);
                renderer.params().set_master_gain_db(-1.0);
            }
            _ => {}
        }
        renderer.render(&mut out);
        instrument_peak = instrument_peak.max(
            out.iter()
                .map(|f| f[0].abs().max(f[1].abs()))
                .fold(0.0_f32, f32::max),
        );
    }
    let clean_after = guard::violations();
    assert_eq!(
        clean_after - clean_before,
        0,
        "render() allocated or freed on the render path"
    );
    assert!(
        instrument_peak > 0.01,
        "with both audio tracks muted the instrument must still be audible: \
         the allocation run above rendered silence (peak {instrument_peak})"
    );
    // The run must also be fault-free.
    let stats = renderer.stats().snapshot();
    assert_eq!(stats.underruns, 0);
    assert_eq!(stats.leaked_buffers, 0);
}

// ===========================================================================
// E5-graph §12.7 — the graph walk allocates NOTHING, at capacity.
// ===========================================================================

/// A 32-node / 512-edge graph, with insert chains, a sidechain and non-zero
/// PDC, renders with **zero** allocator hits inside render scopes.
///
/// ⚠️ **The positive control comes FIRST.** `render/tests/solo.rs:29-31`
/// documents the trap this file already installs `#[global_allocator]` for: a
/// counting allocator that is not the binary's global allocator observes
/// nothing, and the negative assertion is then vacuously green. This test
/// deliberately allocates inside a render scope and asserts the counter MOVES
/// before it asserts that the real render leaves it still.
#[test]
fn a_capacity_graph_renders_without_allocating() {
    use timeline_core::cmd::Cmd;
    use timeline_core::model::FxKind;
    use timeline_core::routing::{NodeKind, NodeRef, Tap};

    // ---- positive control ------------------------------------------------
    let before_control = guard::violations();
    guard::enter_render_scope();
    let deliberate: Vec<u8> = Vec::with_capacity(4_096);
    guard::leave_render_scope();
    assert!(
        !deliberate.is_empty() || deliberate.capacity() >= 4_096,
        "the control allocation was optimised away"
    );
    assert!(
        guard::violations() > before_control,
        "THE GUARD IS BLIND: a deliberate allocation inside a render scope was \
         not counted, so the zero-allocation assertion below would be vacuous"
    );

    // ---- the graph -------------------------------------------------------
    const TRACKS: usize = 16;
    const NODES: usize = 32;
    let mut project = Project::new(
        ENGINE_SAMPLE_RATE,
        TempoMap::single(Bpm::from_int(120).unwrap()),
    );
    let mut sources: HashMap<String, Arc<AudioBuf>> = HashMap::new();
    let audio = AudioBuf::from_samples(vec![[0.05, 0.05]; 8_000], "dc");
    project
        .add_source(Source {
            id: "dc".into(),
            path: "synthetic:dc".into(),
            len_frames: audio.len_frames(),
        })
        .unwrap();
    sources.insert("dc".into(), audio);
    for t in 0..TRACKS {
        let id = format!("t{t}");
        project
            .apply(&Command::TrackAdd {
                track_id: id.clone(),
                name: id.clone(),
                index: None,
            })
            .unwrap();
        project
            .apply(&Command::ClipPlace {
                track_id: id.clone(),
                clip_id: format!("c{t}"),
                source_id: "dc".into(),
                start_tick: None,
                start_frame: Some(0),
                offset_frames: 0,
                len_frames: 8_000,
                gain_db: 0.0,
                fade_in_frames: 0,
                fade_out_frames: 0,
                fade_shape: FadeShape::EqualPower,
            })
            .unwrap();
    }
    for n in 0..NODES {
        project
            .apply_cmd(&Cmd::RouteNodeAdd {
                node_id: format!("n{n}"),
                kind: NodeKind::Bus,
                name: format!("n{n}"),
            })
            .unwrap();
    }
    // Fill to the 512-edge cap: every track feeds every node with a PRE tap
    // (a send, so the implicit master feeds survive and the graph stays a DAG).
    let mut edge = 0_usize;
    'outer: for t in 0..TRACKS {
        for n in 0..NODES {
            project
                .apply_cmd(&Cmd::RouteConnect {
                    edge_id: format!("e{edge}"),
                    from: NodeRef::parse(&format!("track.t{t}")).unwrap(),
                    to: NodeRef::parse(&format!("bus.n{n}")).unwrap(),
                    level: Num::int(1),
                    tap: Tap::Pre,
                })
                .unwrap();
            edge += 1;
            if edge == 512 {
                break 'outer;
            }
        }
    }
    assert_eq!(project.routing.edges.len(), 512);
    assert_eq!(project.routing.nodes.len(), 32);

    // Insert chains, a latency-bearing bus (so PDC rings are live), and a
    // sidechain (so the keyed read path is exercised).
    for (target, fx_id, kind) in [
        ("track.t0", "sat", FxKind::Saturator),
        ("bus.n0", "cmp", FxKind::Compressor),
        ("bus.n1", "lim", FxKind::Limiter),
        ("master", "mu", FxKind::Utility),
    ] {
        project
            .apply_cmd(&Cmd::FxAdd {
                target: NodeRef::parse(target).unwrap(),
                fx_id: fx_id.into(),
                kind,
            })
            .unwrap();
    }
    project
        .apply_cmd(&Cmd::FxSidechainSet {
            target: NodeRef::parse("bus.n0").unwrap(),
            fx_id: "cmp".into(),
            source: NodeRef::parse("track.t1").unwrap(),
        })
        .unwrap();

    // Fx parameter lanes on all three host spellings, so the per-frame
    // `RtFx::lanes` -> `set_frame_param` read path is inside the measured
    // window (a lane read that allocated — or a dB cache that reconverted by
    // allocating — would trip the guard below).
    let mut automation = render::automation::AutomationStore::new();
    for (path, lo, hi) in [
        ("track.fx.sat.drive", 0.0_f32, 18.0_f32),
        ("bus.n0.fx.cmp.threshold", -6.0, -40.0),
        ("master.fx.mu.gain", 0.0, -9.0),
    ] {
        for (tick, v) in [(0_u64, lo), (240, hi)] {
            automation.add_point_path(
                "t0",
                path,
                render::automation::RawPoint {
                    tick,
                    value: v,
                    curve: render::automation::CurveKind::Linear,
                },
            );
        }
    }

    let session = render::compile::compile_session_full(
        &project,
        &sources,
        &render::warp::WarpOverlay::new(),
        &automation,
        EngineConfig::default().max_tracks,
        render::compile::DeclickPolicy::None,
    )
    .expect("a capacity graph must COMPILE, not be refused");
    assert!(
        session.graph.edges.iter().any(|e| e.comp > 0),
        "no compensation ring is live, so the PDC read path is not under test"
    );
    assert_eq!(
        session.graph.fx.iter().map(|f| f.lanes.len()).sum::<usize>(),
        3,
        "the fx lanes did not bake, so the lane read path is not under test"
    );

    let cfg = EngineConfig::default();
    let mut renderer = ManualRenderer::new(&cfg);
    render::compile::sync_graph_params(&project, renderer.params());
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
        6_000,
        512,
    );
    assert_eq!(
        guard::violations() - before,
        0,
        "the graph walk allocated on the audio thread"
    );
    assert!(out.iter().any(|f| f[0].abs() > 1e-6), "the render was silent");
}
