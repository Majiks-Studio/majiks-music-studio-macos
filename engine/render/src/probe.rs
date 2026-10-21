//! Realtime stress probe: the DJ audio_commands.rs run_realtime_stress_probe
//! pattern ported to the timeline engine.
//!
//! Runs against a LIVE (silence-gated) cpal stream. Hammers the control
//! surface from a non-audio thread: track gain/mute params, master gain,
//! seeks, loop set/clear, and full session snapshot swaps, while sampling
//! control-to-callback latency by watching the callback counter advance
//! after a param write (the DJ measurement, kept identical so numbers stay
//! comparable).

use std::time::{Duration, Instant};

use serde::Serialize;

use crate::host::ProjectHost;
use crate::rt::RenderCommand;
use crate::stats::StatsSnapshot;

#[derive(Debug, Serialize)]
pub struct StressReport {
    pub duration_seconds: f64,
    pub iterations: u64,
    pub param_updates: u64,
    pub seeks: u64,
    pub loop_toggles: u64,
    pub mute_toggles: u64,
    pub session_swaps: u64,
    pub mixer_updates: u64,
    pub automation_edits: u64,
    pub warp_submits: u64,
    pub warp_swaps: u64,
    pub callbacks_delta: u64,
    pub frames_rendered_delta: u64,
    pub underruns_delta: u64,
    pub deadline_misses_delta: u64,
    pub command_overruns_delta: u64,
    pub leaked_buffers_delta: u64,
    pub stream_errors_delta: u64,
    pub meter_drops_delta: u64,
    pub alloc_violations_delta: u64,
    pub device_sample_rate: u32,
    pub actual_buffer_frames: u32,
    pub expected_buffer_ms: f64,
    pub latency_samples: usize,
    pub control_to_callback_ms_p50: f64,
    pub control_to_callback_ms_p95: f64,
    pub control_to_callback_ms_max: f64,
    pub callback_ns_max: u64,
    pub callback_ns_mean: u64,
    pub callback_ns_p95: u64,
    pub final_stats: StatsSnapshot,
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((sorted.len() - 1) as f64 * p.clamp(0.0, 1.0)).round() as usize;
    sorted[idx]
}

/// Run the probe for `seconds` against a host whose engine already has a
/// running output stream and a compiled session. Returns the report.
pub fn run_stress_probe(host: &mut ProjectHost, seconds: u64) -> Result<StressReport, String> {
    let seconds = seconds.clamp(1, 30 * 60);
    let content_end = host.project.content_end_frame().max(1);
    let track_count = host.project.tracks.len().max(1);
    let bar_frames = host
        .project
        .tempo
        .tick_to_frame(host.project.tempo.bar_to_tick(1), host.project.sample_rate)
        .max(1);

    host.push_session()?;
    host.engine().command(RenderCommand::Seek { frame: 0 });
    host.engine().command(RenderCommand::Play);

    // A clip id to hammer with warp changes (first clip on track 0, if any).
    let warp_clip: Option<String> = host
        .project
        .tracks
        .first()
        .and_then(|t| t.clips.first())
        .map(|c| c.id.clone());
    // A track id for automation edits.
    let auto_track: Option<String> = host.project.tracks.first().map(|t| t.id.clone());

    let before = host.engine().stats();
    let started = Instant::now();
    let mut iterations = 0_u64;
    let mut param_updates = 0_u64;
    let mut seeks = 0_u64;
    let mut loop_toggles = 0_u64;
    let mut mute_toggles = 0_u64;
    let mut session_swaps = 0_u64;
    let mut mixer_updates = 0_u64;
    let mut automation_edits = 0_u64;
    let mut warp_submits = 0_u64;
    let mut warp_swaps = 0_u64;
    let mut latencies_ms: Vec<f64> = Vec::new();

    while started.elapsed() < Duration::from_secs(seconds) {
        let phase = (iterations % 400) as f32 / 399.0;
        let track = (iterations as usize) % track_count;

        // Continuous param pressure (every iteration): gain + master + the
        // full strip surface (pan, EQ band, sends) so every DSP path is
        // being retargeted while audio runs.
        host.engine()
            .params()
            .set_track_gain_db(track, -12.0 + 18.0 * phase);
        host.engine()
            .params()
            .set_master_gain_db(-6.0 + 6.0 * phase);
        param_updates += 2;
        host.engine()
            .params()
            .set_track_pan(track, -1.0 + 2.0 * phase);
        host.engine().params().set_track_eq(
            track,
            (iterations % 4) as usize,
            200.0 + 4_000.0 * phase,
            -12.0 + 24.0 * phase,
            0.5 + 2.0 * phase,
        );
        host.engine()
            .params()
            .set_track_send(track, iterations % 2 == 0, phase);
        mixer_updates += 3;

        if iterations % 13 == 0 {
            host.engine()
                .params()
                .set_limiter(true, -1.0, 20.0 + 200.0 * phase);
            host.engine()
                .params()
                .set_delay(6_000 + (12_000.0 * phase) as u32, 0.3 + 0.4 * phase, phase);
            host.engine().params().set_reverb(phase, 0.5 + 0.4 * phase);
            mixer_updates += 3;
        }

        // Automation edits (recompile + swap through the store). Capped so
        // the store stays small; the baked lanes keep being evaluated every
        // swap for the whole run (automation rendering stays under load).
        if iterations % 37 == 0 && automation_edits < 64 {
            if let Some(tid) = auto_track.as_ref() {
                use crate::automation::AutoTarget;
                let tick = (iterations % 8) * host.project.tempo.bar_to_tick(1) / 8;
                host.add_automation_point(tid, AutoTarget::Volume, tick, -12.0 + 18.0 * phase)?;
                automation_edits += 1;
            }
        }

        // Interactive warp changes: latest-wins coalescing under load. The
        // off-thread worker renders; the swap lands when ready.
        if iterations % 23 == 0 {
            if let Some(cid) = warp_clip.as_ref() {
                let ratio = 0.85 + 0.30 * phase as f64;
                host.set_warp_ratio(cid, ratio)?;
                warp_submits += 1;
            }
        }
        warp_swaps += host.pump_warp_results()? as u64;

        if iterations % 7 == 0 {
            let mute = (iterations / 7) % 2 == 0;
            host.engine().params().set_track_mute(track, mute);
            mute_toggles += 1;
        }

        // Solo rides the same strip-gain gate as mute; hammer it on a
        // different period so the two gates interleave under load.
        if iterations % 13 == 0 {
            let solo = (iterations / 13) % 2 == 0;
            host.engine().params().set_track_solo(track, solo);
        }

        if iterations % 5 == 0 {
            let frame = (iterations.wrapping_mul(48_119)) % content_end;
            host.engine().command(RenderCommand::Seek { frame });
            seeks += 1;
        }

        if iterations % 11 == 0 {
            if (iterations / 11) % 2 == 0 {
                let start_bar = (iterations / 11) % 8;
                host.engine().command(RenderCommand::LoopSet {
                    start_frame: start_bar * bar_frames,
                    end_frame: (start_bar + 2) * bar_frames,
                });
            } else {
                host.engine().command(RenderCommand::LoopClear);
            }
            loop_toggles += 1;
        }

        // Session snapshot swap under load: proves the drop-thread buffer
        // lifecycle (control-side rebuild, RT-side pointer swap, drop-thread
        // free) for the whole probe duration.
        if iterations % 50 == 0 {
            host.push_session()?;
            session_swaps += 1;
        }

        // Control-to-callback latency sample (DJ methodology: write a param,
        // spin until the callback counter advances).
        if iterations % 1000 == 0 {
            let callbacks_before = host.engine().stats().callbacks;
            let sent = Instant::now();
            host.engine()
                .params()
                .set_track_gain_db(track, -3.0 + 3.0 * phase);
            param_updates += 1;
            while host.engine().stats().callbacks == callbacks_before {
                if sent.elapsed() > Duration::from_millis(250) {
                    break;
                }
                std::thread::sleep(Duration::from_micros(250));
            }
            latencies_ms.push(sent.elapsed().as_secs_f64() * 1000.0);
        }

        iterations += 1;
        std::thread::sleep(Duration::from_millis(1));
    }

    host.engine().command(RenderCommand::LoopClear);
    host.engine().command(RenderCommand::Stop);

    let after = host.engine().stats();
    latencies_ms.sort_by(|a, b| a.partial_cmp(b).expect("finite latencies"));
    let device_rate = after.device_sample_rate;
    let buffer_frames = after.actual_buffer_frames;

    Ok(StressReport {
        duration_seconds: started.elapsed().as_secs_f64(),
        iterations,
        param_updates,
        seeks,
        loop_toggles,
        mute_toggles,
        session_swaps,
        mixer_updates,
        automation_edits,
        warp_submits,
        warp_swaps,
        callbacks_delta: after.callbacks.saturating_sub(before.callbacks),
        frames_rendered_delta: after.frames_rendered.saturating_sub(before.frames_rendered),
        underruns_delta: after.underruns.saturating_sub(before.underruns),
        deadline_misses_delta: after.deadline_misses.saturating_sub(before.deadline_misses),
        command_overruns_delta: after
            .command_overruns
            .saturating_sub(before.command_overruns),
        leaked_buffers_delta: after.leaked_buffers.saturating_sub(before.leaked_buffers),
        stream_errors_delta: after.stream_errors.saturating_sub(before.stream_errors),
        meter_drops_delta: after.meter_drops.saturating_sub(before.meter_drops),
        alloc_violations_delta: after
            .alloc_violations
            .saturating_sub(before.alloc_violations),
        device_sample_rate: device_rate,
        actual_buffer_frames: buffer_frames,
        expected_buffer_ms: f64::from(buffer_frames) / f64::from(device_rate.max(1)) * 1000.0,
        latency_samples: latencies_ms.len(),
        control_to_callback_ms_p50: percentile(&latencies_ms, 0.50),
        control_to_callback_ms_p95: percentile(&latencies_ms, 0.95),
        control_to_callback_ms_max: latencies_ms.iter().copied().fold(0.0, f64::max),
        callback_ns_max: after.callback_ns_max,
        callback_ns_mean: after.callback_ns_mean,
        callback_ns_p95: after.callback_ns_p95,
        final_stats: after,
    })
}
