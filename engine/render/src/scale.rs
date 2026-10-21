//! Reproducible large-session scale benchmark.
//!
//! This is deliberately a CLI benchmark rather than a unit-test threshold:
//! it records machine-dependent timings for the same project shape used by
//! the handoff report, while still failing on correctness regressions.

use std::path::Path;
use std::time::Instant;

use serde::Serialize;
use timeline_core::{Bpm, Command, FadeShape, Project, Source, TempoMap};

use crate::host::ProjectHost;
use crate::media::AudioBuf;
use crate::offline::{render_offline_with, ManualRenderer, ScheduledCommand};
use crate::rt::{RenderCommand, ENGINE_SAMPLE_RATE};
use crate::{Engine, EngineConfig};

const SCALE_ASSET: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

#[derive(Debug, Serialize)]
pub struct ScaleReport {
    pub tracks: usize,
    pub clips: usize,
    pub arrangement_seconds: f64,
    pub compile_ms: f64,
    pub cull_p95_ms: f64,
    pub cull_visible_clips: usize,
    pub cull_visible_clips_max: usize,
    pub render_seconds: f64,
    pub render_p95_ms: f64,
    pub bounce_seconds: f64,
    pub bounce_realtime_ratio: f64,
    pub bounce_bit_identical: bool,
    pub save_ms: f64,
    pub load_ms: f64,
    pub journal_entries: usize,
    pub journal_tip: String,
    pub rss_peak_bytes: u64,
}

fn p95(values: &mut [f64]) -> f64 {
    values.sort_by(|a, b| a.total_cmp(b));
    values[((values.len().saturating_sub(1) as f64) * 0.95).round() as usize]
}

fn rss_bytes() -> u64 {
    #[cfg(target_os = "macos")]
    {
        let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
        unsafe {
            libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr());
            return usage.assume_init().ru_maxrss as u64;
        }
    }
    #[cfg(not(target_os = "macos"))]
    { 0 }
}

fn large_host(tracks: usize, clips_per_track: usize) -> Result<ProjectHost, String> {
    let project = Project::new(ENGINE_SAMPLE_RATE, TempoMap::single(Bpm::from_int(120).unwrap()));
    let mut host = ProjectHost::new(project, Engine::new(EngineConfig::default()));
    let samples = vec![[0.0_f32, 0.0_f32]; ENGINE_SAMPLE_RATE as usize * 8];
    host.register_source(SCALE_ASSET, AudioBuf::from_samples(samples, "scale"))?;

    let clip_len = host.project.tempo.bar_to_tick(2);
    let gap = host.project.tempo.bar_to_tick(4);
    for track in 0..tracks {
        host.apply(&Command::TrackAdd {
            track_id: format!("scale-t{track}"), name: format!("Scale {track}"), index: None,
        })?;
        for clip in 0..clips_per_track {
            host.apply(&Command::ClipPlace {
                track_id: format!("scale-t{track}"), clip_id: format!("scale-t{track}-c{clip}"),
                source_id: SCALE_ASSET.into(), start_tick: Some((clip as u64) * gap),
                start_frame: None, offset_frames: 0,
                len_frames: host.project.tempo.tick_to_frame(clip_len, ENGINE_SAMPLE_RATE).max(1),
                gain_db: 0.0, fade_in_frames: 0, fade_out_frames: 0, fade_shape: FadeShape::EqualPower,
            })?;
        }
    }
    Ok(host)
}

pub fn run(out: Option<&Path>, tracks: usize, clips_per_track: usize) -> Result<ScaleReport, String> {
    let host = large_host(tracks, clips_per_track)?;
    let clips = tracks * clips_per_track;
    let arrangement_frames = host.project.content_end_frame() + ENGINE_SAMPLE_RATE as u64;
    let arrangement_seconds = arrangement_frames as f64 / ENGINE_SAMPLE_RATE as f64;

    let started = Instant::now();
    let session = host.compile()?;
    let compile_ms = started.elapsed().as_secs_f64() * 1000.0;

    // The UI's hot operation is viewport culling. This mirrors the Canvas
    // interval predicate over the real project model and samples pan/zoom.
    let mut cull_times = Vec::with_capacity(240);
    let mut visible = 0;
    let mut visible_max = 0;
    for sample in 0..240_u64 {
        let t = Instant::now();
        let scroll = sample * host.project.tempo.bar_to_tick(2);
        let end = scroll + host.project.tempo.bar_to_tick(16);
        visible = host.project.tracks.iter().flat_map(|t| &t.clips)
            .filter(|c| c.start_ticks < end && c.end_ticks() > scroll).count();
        visible_max = visible_max.max(visible);
        cull_times.push(t.elapsed().as_secs_f64() * 1000.0);
    }

    let render_frames = (ENGINE_SAMPLE_RATE as u64 * 10).min(arrangement_frames);
    let mut renderer = ManualRenderer::new(host.engine().config());
    let schedule = vec![ScheduledCommand { at_frame: 0, command: RenderCommand::SetSession(session) }, ScheduledCommand { at_frame: 0, command: RenderCommand::Play }];
    let t = Instant::now();
    let audio = render_offline_with(&mut renderer, schedule, render_frames, 512);
    let bounce_seconds = t.elapsed().as_secs_f64();
    let mut renderer2 = ManualRenderer::new(host.engine().config());
    let session2 = host.compile()?;
    let t = Instant::now();
    let audio2 = render_offline_with(&mut renderer2, vec![ScheduledCommand { at_frame: 0, command: RenderCommand::SetSession(session2) }, ScheduledCommand { at_frame: 0, command: RenderCommand::Play }], render_frames, 128);
    let _bounce_seconds_128 = t.elapsed().as_secs_f64();
    let residual = crate::offline::residual(&audio, &audio2);

    // Per-block render timings use the same render core, without device I/O.
    let session3 = host.compile()?;
    let mut timed = ManualRenderer::new(host.engine().config());
    timed.send(RenderCommand::SetSession(session3)); timed.send(RenderCommand::Play);
    let mut render_times = Vec::new(); let mut block = vec![[0.0; 2]; 512];
    for _ in 0..(render_frames / 512) { let t = Instant::now(); timed.render(&mut block); render_times.push(t.elapsed().as_secs_f64() * 1000.0); }

    let dir = std::env::temp_dir().join(format!("majiks-scale-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir); // benchmark-owned temp directory only
    let mut base = Project::new(ENGINE_SAMPLE_RATE, TempoMap::single(Bpm::from_int(120).unwrap()));
    base.add_source(Source { id: SCALE_ASSET.into(), path: "synthetic:scale".into(), len_frames: ENGINE_SAMPLE_RATE as u64 * 8 }).map_err(|e| e.to_string())?;
    let mut journal = timeline_core::Session::new(base);
    // A compact, valid journal with one command per generated track/clip.
    let actor = timeline_core::Actor::system();
    let mut seq = 0;
    for track in &host.project.tracks {
        let cmd = timeline_core::Cmd::TrackAdd { track_id: track.id.clone(), name: track.name.clone(), index: None };
        journal.submit(timeline_core::EntryMeta { id: format!("scale-{seq:08}"), ts: "2026-01-01T00:00:00Z".into(), actor: actor.clone() }, cmd).map_err(|e| e.to_string())?; seq += 1;
        for clip in &track.clips { let cmd = timeline_core::Cmd::ClipPlace { clip_id: clip.id.clone(), track_id: track.id.clone(), asset_hash: clip.source_id.clone(), start_ticks: clip.start_ticks, length_ticks: clip.length_ticks, source_offset_ticks: Some(clip.source_offset_ticks) }; journal.submit(timeline_core::EntryMeta { id: format!("scale-{seq:08}"), ts: "2026-01-01T00:00:00Z".into(), actor: actor.clone() }, cmd).map_err(|e| e.to_string())?; seq += 1; }
    }
    let t = Instant::now(); timeline_core::package::Package::create(&dir, journal.project().clone()).map_err(|e| e.to_string())?; timeline_core::package::Package::save(&dir, &mut journal).map_err(|e| e.to_string())?; let save_ms = t.elapsed().as_secs_f64() * 1000.0;
    let t = Instant::now(); let reopened = timeline_core::package::Package::open(&dir).map_err(|e| e.to_string())?; let load_ms = t.elapsed().as_secs_f64() * 1000.0;
    let report = ScaleReport { tracks, clips, arrangement_seconds, compile_ms, cull_p95_ms: p95(&mut cull_times), cull_visible_clips: visible, cull_visible_clips_max: visible_max, render_seconds: render_frames as f64 / ENGINE_SAMPLE_RATE as f64, render_p95_ms: p95(&mut render_times), bounce_seconds, bounce_realtime_ratio: (render_frames as f64 / ENGINE_SAMPLE_RATE as f64) / bounce_seconds.max(f64::MIN_POSITIVE), bounce_bit_identical: residual.bit_identical, save_ms, load_ms, journal_entries: reopened.journal().len(), journal_tip: reopened.tip_hash().to_string(), rss_peak_bytes: rss_bytes() };
    if let Some(path) = out { std::fs::write(path, serde_json::to_vec_pretty(&report).unwrap()).map_err(|e| e.to_string())?; }
    let _ = std::fs::remove_dir_all(&dir);
    Ok(report)
}
