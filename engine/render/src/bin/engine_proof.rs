//! P0-B proof harness (CLI, no UI).
//!
//! Subcommands:
//!   demo                     build the 4-track/8-clip session by commands,
//!                            run the edit script, undo/redo, print evidence
//!   boot-test [--seconds N]  open the (silence-gated) cpal stream, render
//!                            the session live, verify cadence + counters
//!   bounce [--out PATH]      offline bounce through the same graph to WAV
//!   null-test [--seconds N]  offline bounce vs captured realtime run of the
//!                            identical command sequence; residual dBFS
//!   probe [--seconds N] [--json PATH]  realtime stress probe
//!   scale-bench [--json PATH]          32-track/1536-clip scale benchmark
//!
//! AUDIO SAFETY: every subcommand is silent at the device. The audible path
//! exists only behind MAJIKS_TEST_AUDIBLE=1 for the attended check with
//! Aaron; nothing here sets it.

use std::path::PathBuf;
use std::time::Duration;

use render::engine::{Engine, EngineConfig};
use render::fixtures;
use render::host::ProjectHost;
use render::media::write_wav_f32;
use render::offline::{render_offline_with, residual, ManualRenderer, ScheduledCommand};
use render::probe::run_stress_probe;
use render::rt::{CaptureBuf, RenderCommand, ENGINE_SAMPLE_RATE};
use timeline_core::{Bpm, Command, FadeShape, Project, TempoMap, TrimEdge};

#[global_allocator]
static ALLOC: render::guard::CountingAlloc = render::guard::CountingAlloc;

fn flag_value(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn artifacts_dir() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../target/p0b-artifacts");
    std::fs::create_dir_all(&dir).expect("create artifacts dir");
    dir
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let subcommand = args.first().map(String::as_str).unwrap_or("help");
    let result = match subcommand {
        "demo" => demo(),
        "boot-test" => boot_test(&args),
        "bounce" => bounce(&args),
        "null-test" => null_test(&args),
        "probe" => probe(&args),
        "scale-bench" => scale_bench(&args),
        _ => {
            eprintln!(
                "usage: engine-proof <demo|boot-test|bounce|null-test|probe|scale-bench> [--seconds N] [--out PATH] [--json PATH]"
            );
            Ok(())
        }
    };
    if let Err(err) = result {
        eprintln!("engine-proof {subcommand} failed: {err}");
        std::process::exit(1);
    }
}

fn scale_bench(args: &[String]) -> Result<(), String> {
    let tracks = flag_value(args, "--tracks").and_then(|v| v.parse().ok()).unwrap_or(32);
    let clips = flag_value(args, "--clips-per-track").and_then(|v| v.parse().ok()).unwrap_or(48);
    let report = render::scale::run(flag_value(args, "--json").as_deref().map(std::path::Path::new), tracks, clips)?;
    println!("SCALE-BENCH-REPORT {}", serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?);
    if report.tracks < 32 || report.clips < 1000 { return Err("scale benchmark fixture is below the required large-session size".into()); }
    if !report.bounce_bit_identical { return Err("large-session bounce changed with block size".into()); }
    Ok(())
}

/// Build the proof session: 4 tracks, 8 stereo clips from real WAV fixtures
/// (one 44.1 kHz, one mono), placed at bar positions on a 120 BPM tempo map.
/// Everything goes through the command bus.
fn build_demo_host(verbose: bool) -> Result<ProjectHost, String> {
    let fixtures_dir = fixtures::repo_fixtures_dir();
    fixtures::ensure(&fixtures_dir)?;

    let project = Project::new(
        ENGINE_SAMPLE_RATE,
        TempoMap::single(Bpm::from_int(120).map_err(|e| e.to_string())?),
    );
    let engine = Engine::new(EngineConfig::default());
    let mut host = ProjectHost::new(project, engine);

    for (id, file) in [
        ("click120", "click_120bpm_48k_stereo.wav"),
        ("click92", "click_92bpm_48k_stereo.wav"),
        ("click174", "click_174bpm_48k_stereo.wav"),
        ("sweep48", "sweep_48k_stereo.wav"),
        ("sweep441", "sweep_44k1_stereo.wav"),
        ("tone440", "tone_440_48k_mono.wav"),
    ] {
        host.load_source(id, &fixtures_dir.join(file))?;
    }

    let bar = |n: u64| host.project.tempo.bar_to_tick(n);
    let place = |track: &str,
                 clip: &str,
                 source: &str,
                 start_tick: u64,
                 offset: u64,
                 len: u64,
                 gain: f32,
                 fade_in: u64,
                 fade_out: u64| Command::ClipPlace {
        track_id: track.into(),
        clip_id: clip.into(),
        source_id: source.into(),
        start_tick: Some(start_tick),
        start_frame: None,
        offset_frames: offset,
        len_frames: len,
        gain_db: gain,
        fade_in_frames: fade_in,
        fade_out_frames: fade_out,
        fade_shape: FadeShape::EqualPower,
    };

    let mut commands: Vec<Command> = Vec::new();
    for (id, name) in [
        ("t1", "Drums"),
        ("t2", "Bass"),
        ("t3", "Sweep"),
        ("t4", "Texture"),
    ] {
        commands.push(Command::TrackAdd {
            track_id: id.into(),
            name: name.into(),
            index: None,
        });
    }
    commands.push(place("t1", "c-drums-a", "click120", bar(0), 0, 384_000, 0.0, 0, 0));
    commands.push(place("t1", "c-drums-b", "click120", bar(8), 0, 384_000, 0.0, 0, 0));
    commands.push(place("t2", "c-bass-a", "tone440", bar(2), 0, 96_000, 0.0, 2_400, 2_400));
    commands.push(place("t2", "c-bass-b", "tone440", bar(6), 0, 96_000, -3.0, 2_400, 2_400));
    commands.push(place("t2", "c-bass-c", "tone440", bar(10), 24_000, 144_000, 0.0, 4_800, 4_800));
    commands.push(place("t3", "c-sweep-a", "sweep48", bar(0), 48_000, 288_000, -6.0, 24_000, 48_000));
    commands.push(place("t3", "c-sweep-b", "sweep441", bar(4), 10_000, 240_000, -6.0, 12_000, 12_000));
    commands.push(place("t4", "c-tex-a", "click174", bar(12), 24_000, 192_000, -9.0, 0, 0));

    for command in &commands {
        let applied = host.apply(command)?;
        if verbose {
            println!(
                "apply  {}",
                serde_json::to_string(command).map_err(|e| e.to_string())?
            );
            println!(
                "  inverse {}",
                serde_json::to_string(&applied.inverse).map_err(|e| e.to_string())?
            );
        }
    }
    Ok(host)
}

/// The edit script: every P0-B edit command exercised on the demo session.
fn edit_script(host: &ProjectHost) -> Vec<Command> {
    let bar = |n: u64| host.project.tempo.bar_to_tick(n);
    let bar_frame = |n: u64| {
        host.project
            .tempo
            .tick_to_frame(bar(n), host.project.sample_rate)
    };
    vec![
        Command::ClipTrim {
            clip_id: "c-drums-b".into(),
            edge: TrimEdge::End,
            to_frame: bar_frame(11),
        },
        Command::ClipMove {
            clip_id: "c-tex-a".into(),
            to_track_id: None,
            to_start_tick: Some(bar(13)),
            to_start_frame: None,
        },
        Command::ClipSplit {
            clip_id: "c-sweep-a".into(),
            at_frame: bar_frame(2),
            right_clip_id: "c-sweep-a2".into(),
        },
        Command::ClipFadeSet {
            clip_id: "c-sweep-a2".into(),
            fade_in_frames: Some(4_800),
            fade_out_frames: None,
            fade_shape: None,
        },
        Command::ClipSetGain {
            clip_id: "c-bass-b".into(),
            gain_db: -1.5,
        },
        Command::TrackMute {
            track_id: "t4".into(),
            mute: true,
        },
        Command::TrackMute {
            track_id: "t4".into(),
            mute: false,
        },
    ]
}

fn apply_edit_script(host: &mut ProjectHost, verbose: bool) -> Result<(), String> {
    for command in edit_script(host) {
        let applied = host.apply(&command)?;
        if verbose {
            println!(
                "apply  {}",
                serde_json::to_string(&command).map_err(|e| e.to_string())?
            );
            println!(
                "  inverse {}",
                serde_json::to_string(&applied.inverse).map_err(|e| e.to_string())?
            );
        }
    }
    Ok(())
}

fn project_hash(project: &Project) -> String {
    let json = serde_json::to_string(project).expect("serialize project");
    blake3::hash(json.as_bytes()).to_hex().to_string()
}

fn demo() -> Result<(), String> {
    let mut host = build_demo_host(true)?;
    let hash_placed = project_hash(&host.project);
    println!("\nproject hash after placement: {hash_placed}");

    apply_edit_script(&mut host, true)?;
    let hash_edited = project_hash(&host.project);
    println!("\nproject hash after edit script: {hash_edited}");

    // Undo the whole edit script, verify restore, redo it, verify again.
    let edits = host.undo_depth();
    let mut undone = 0;
    for _ in 0..7 {
        if host.undo()? {
            undone += 1;
        }
    }
    println!("undo x{undone} (stack had {edits})");
    let hash_undone = project_hash(&host.project);
    println!("project hash after undo: {hash_undone}");
    if hash_undone != hash_placed {
        return Err("undo did not restore the placement state".into());
    }
    let mut redone = 0;
    for _ in 0..7 {
        if host.redo()? {
            redone += 1;
        }
    }
    let hash_redone = project_hash(&host.project);
    println!("redo x{redone}, project hash after redo: {hash_redone}");
    if hash_redone != hash_edited {
        return Err("redo did not reproduce the edited state".into());
    }

    println!("\ntracks:");
    for track in &host.project.tracks {
        println!("  {} ({}) mute={}", track.id, track.name, track.mute);
        for clip in &track.clips {
            println!(
                "    {} src={} start={} offset={} len={} gain={}dB fades={}/{}",
                clip.id,
                clip.source_id,
                clip.start_frame,
                clip.offset_frames,
                clip.len_frames,
                clip.gain_db,
                clip.fade_in_frames,
                clip.fade_out_frames
            );
        }
    }
    println!("\ndemo: PASS (placement, edits, serialization, undo/redo)");
    Ok(())
}

fn boot_test(args: &[String]) -> Result<(), String> {
    let seconds: u64 = flag_value(args, "--seconds")
        .and_then(|v| v.parse().ok())
        .unwrap_or(10);
    let mut host = build_demo_host(false)?;
    apply_edit_script(&mut host, false)?;
    let info = host.engine_mut().start_output()?;
    println!(
        "stream open: device={} default_rate={} configured_rate={} requested_frames={} fixed={} channels={} audible={}",
        info.device_name,
        info.device_default_rate,
        info.configured_rate,
        info.requested_buffer_frames,
        info.fixed_buffer,
        info.channels,
        info.audible
    );
    if info.audible {
        return Err("MAJIKS_TEST_AUDIBLE is set; boot-test must run silent".into());
    }
    host.push_session()?;
    host.engine().command(RenderCommand::Play);

    let before = host.engine().stats();
    std::thread::sleep(Duration::from_secs(seconds));
    let after = host.engine().stats();

    let callbacks = after.callbacks - before.callbacks;
    let frames = after.frames_rendered - before.frames_rendered;
    let cadence = frames as f64 / seconds as f64;
    let expected = f64::from(ENGINE_SAMPLE_RATE);
    println!(
        "boot-test over {seconds}s: callbacks={callbacks} frames={frames} cadence={cadence:.1} frames/s (expected {expected:.0})"
    );
    println!(
        "underruns={} deadline_misses={} command_overruns={} leaked={} stream_errors={} alloc_violations={}",
        after.underruns - before.underruns,
        after.deadline_misses - before.deadline_misses,
        after.command_overruns - before.command_overruns,
        after.leaked_buffers - before.leaked_buffers,
        after.stream_errors - before.stream_errors,
        after.alloc_violations - before.alloc_violations
    );
    println!(
        "callback duration: mean={}us max={}us p95<={}us (buffer={} frames)",
        after.callback_ns_mean / 1000,
        after.callback_ns_max / 1000,
        after.callback_ns_p95 / 1000,
        after.actual_buffer_frames
    );

    let cadence_ok = (cadence - expected).abs() / expected < 0.10;
    let clean = after.underruns == before.underruns
        && after.alloc_violations == before.alloc_violations
        && after.stream_errors == before.stream_errors;
    if cadence_ok && clean {
        println!("boot-test: PASS (device heard zeros; audible attended check deferred)");
        Ok(())
    } else {
        Err(format!(
            "boot-test FAILED: cadence_ok={cadence_ok} clean_counters={clean}"
        ))
    }
}

fn demo_total_frames(host: &ProjectHost) -> u64 {
    let bar = host
        .project
        .tempo
        .tick_to_frame(host.project.tempo.bar_to_tick(1), host.project.sample_rate);
    host.project.content_end_frame() + bar
}

fn bounce(args: &[String]) -> Result<(), String> {
    let out = flag_value(args, "--out")
        .map(PathBuf::from)
        .unwrap_or_else(|| artifacts_dir().join("bounce.wav"));
    let mut host = build_demo_host(false)?;
    apply_edit_script(&mut host, false)?;
    let total = demo_total_frames(&host);
    let session = host.compile()?;
    let mut renderer = ManualRenderer::new(host.engine().config());
    host.project
        .tracks
        .iter()
        .enumerate()
        .for_each(|(i, t)| renderer.params().set_track_mute(i, t.mute));
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
        512,
    );
    write_wav_f32(&out, &audio, ENGINE_SAMPLE_RATE)?;
    let peak = audio
        .iter()
        .flat_map(|f| [f[0].abs(), f[1].abs()])
        .fold(0.0_f32, f32::max);
    println!(
        "bounce: {} frames ({:.1}s) -> {} (peak {:.3})",
        total,
        total as f64 / f64::from(ENGINE_SAMPLE_RATE),
        out.display(),
        peak
    );
    Ok(())
}

fn null_test(args: &[String]) -> Result<(), String> {
    let mut host = build_demo_host(false)?;
    apply_edit_script(&mut host, false)?;
    let mut total = demo_total_frames(&host);
    if let Some(seconds) = flag_value(args, "--seconds").and_then(|v| v.parse::<u64>().ok()) {
        total = total.min(seconds * u64::from(ENGINE_SAMPLE_RATE));
    }

    // Offline render A: chunk 512. Track params mirror the model exactly
    // like the live engine's params do (apply() keeps those in sync).
    let sync_mutes = |renderer: &ManualRenderer, host: &ProjectHost| {
        for (i, t) in host.project.tracks.iter().enumerate() {
            renderer.params().set_track_mute(i, t.mute);
        }
    };
    let session_a = host.compile()?;
    let mut renderer_a = ManualRenderer::new(host.engine().config());
    sync_mutes(&renderer_a, &host);
    let offline_512 = render_offline_with(
        &mut renderer_a,
        vec![
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::SetSession(session_a),
            },
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::Play,
            },
        ],
        total,
        512,
    );

    // Offline render B: chunk 128 (block-size independence).
    let session_b = host.compile()?;
    let mut renderer_b = ManualRenderer::new(host.engine().config());
    sync_mutes(&renderer_b, &host);
    let offline_128 = render_offline_with(
        &mut renderer_b,
        vec![
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::SetSession(session_b),
            },
            ScheduledCommand {
                at_frame: 0,
                command: RenderCommand::Play,
            },
        ],
        total,
        128,
    );
    let chunk_residual = residual(&offline_512, &offline_128);
    println!(
        "offline 512 vs offline 128: peak {} dBFS, rms {} dBFS, bit_identical={}",
        chunk_residual.peak_dbfs, chunk_residual.rms_dbfs, chunk_residual.bit_identical
    );

    // Captured realtime run: real cpal stream, silence-gated at the device,
    // capture tap records the rendered master. CaptureStart carries
    // start_transport so captured frame 0 is play frame 0.
    let info = host.engine_mut().start_output()?;
    if info.audible {
        return Err("MAJIKS_TEST_AUDIBLE is set; null-test must run silent".into());
    }
    host.push_session()?;
    let capture = CaptureBuf::new(total as usize);
    host.engine().command(RenderCommand::CaptureStart {
        capture,
        start_transport: true,
    });
    let wall = Duration::from_secs_f64(total as f64 / f64::from(ENGINE_SAMPLE_RATE) + 15.0);
    println!(
        "capturing {} frames from the live (silent) stream, ~{:.0}s...",
        total,
        total as f64 / f64::from(ENGINE_SAMPLE_RATE)
    );
    let captured = host
        .engine()
        .wait_capture(wall)
        .ok_or_else(|| "capture did not complete in time".to_string())?;
    host.engine().command(RenderCommand::Stop);
    let realtime: Vec<[f32; 2]> = captured.data.to_vec();

    let null = residual(&offline_512, &realtime);
    println!(
        "offline vs captured realtime: {} frames, peak {} dBFS, rms {} dBFS, max_abs {}, bit_identical={}",
        null.frames_compared, null.peak_dbfs, null.rms_dbfs, null.max_abs, null.bit_identical
    );

    let dir = artifacts_dir();
    write_wav_f32(&dir.join("null_offline.wav"), &offline_512, ENGINE_SAMPLE_RATE)?;
    write_wav_f32(&dir.join("null_realtime.wav"), &realtime, ENGINE_SAMPLE_RATE)?;
    println!("wavs written to {}", dir.display());

    let stats = host.engine().stats();
    println!(
        "live stream stats: callbacks={} underruns={} deadline_misses={} alloc_violations={}",
        stats.callbacks, stats.underruns, stats.deadline_misses, stats.alloc_violations
    );

    if null.peak_dbfs < -120.0 && chunk_residual.peak_dbfs < -120.0 && stats.underruns == 0 {
        println!("null-test: PASS (bar: peak residual < -120 dBFS)");
        Ok(())
    } else {
        Err(format!(
            "null-test FAILED: realtime peak {} dBFS, chunk peak {} dBFS, underruns {}",
            null.peak_dbfs, chunk_residual.peak_dbfs, stats.underruns
        ))
    }
}

fn probe(args: &[String]) -> Result<(), String> {
    let seconds: u64 = flag_value(args, "--seconds")
        .and_then(|v| v.parse().ok())
        .unwrap_or(300);
    let mut host = build_demo_host(false)?;
    apply_edit_script(&mut host, false)?;
    // Attach the production warp engine (Signalsmith) so the probe hammers
    // the real off-thread stretch path with latest-wins coalescing.
    host.attach_warp_worker(render::warp::WarpWorker::spawn(|| {
        Box::new(render::warp::SignalsmithStretcher::new(ENGINE_SAMPLE_RATE))
    }));
    let info = host.engine_mut().start_output()?;
    if info.audible {
        return Err("MAJIKS_TEST_AUDIBLE is set; probe must run silent".into());
    }
    println!(
        "probe: {seconds}s against device '{}' (silence-gated), buffer request {} frames",
        info.device_name, info.requested_buffer_frames
    );
    let report = run_stress_probe(&mut host, seconds)?;
    let json = serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?;
    println!("STRESS-PROBE-REPORT {json}");
    if let Some(path) = flag_value(args, "--json") {
        std::fs::write(&path, &json).map_err(|e| format!("write {path}: {e}"))?;
        println!("report written to {path}");
    }

    println!(
        "probe: mixer_updates={} automation_edits={} warp_submits={} warp_swaps={} meter_drops={} callback_ns_p95={}",
        report.mixer_updates,
        report.automation_edits,
        report.warp_submits,
        report.warp_swaps,
        report.meter_drops_delta,
        report.callback_ns_p95,
    );
    let pass = report.underruns_delta == 0
        && report.alloc_violations_delta == 0
        && report.command_overruns_delta == 0
        && report.control_to_callback_ms_p95 < 3.0;
    if pass {
        println!("probe: PASS (0 underruns, 0 alloc violations, 0 overruns, p95 < 3 ms)");
        Ok(())
    } else {
        Err(format!(
            "probe FAILED: underruns={} alloc={} overruns={} p95={:.3}ms",
            report.underruns_delta,
            report.alloc_violations_delta,
            report.command_overruns_delta,
            report.control_to_callback_ms_p95
        ))
    }
}
