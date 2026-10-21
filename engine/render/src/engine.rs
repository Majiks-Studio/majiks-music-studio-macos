//! Control-side engine: owns the channels, the params, the meters, the
//! stats, the drop thread, the loudness thread, and (optionally) the cpal
//! output stream.
//!
//! Instance-based by rule: `Engine::new(EngineConfig)`, no singleton.
//!
//! AUDIO SAFETY (P0-B session rule): the output stream is SILENCE-GATED by
//! default. The core renders the full graph every callback (so cadence, stats,
//! cost, and meters are real) into a preallocated scratch buffer, and the
//! device buffer receives zeros unless the stream was built AUDIBLE. Audible is
//! an explicit opt-in via `EngineConfig.audible`: the shipping GUI app sets it
//! (so a user pressing Play is heard), while the CLI, `cargo test`,
//! `swift test`, and any headless/CI run leave it false and never make sound.
//! `MAJIKS_TEST_AUDIBLE=1` in the environment also forces audible, for the
//! attended `engine_proof` check.
//!
//! DEVICE-SWITCH SURVIVAL (DJ P7 lesson): the render core lives OUTSIDE the
//! stream closure until `start_output` moves it in. A device switch drops
//! the old stream (which drops the moved-in core and its command receiver)
//! and rebuilds a fresh core against the SAME shared params/meters/stats.
//! Playback state (position) is preserved by the host: it reads the last
//! position from stats and re-pushes the session + re-seeks after rehydrate.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{BufferSize, SampleFormat, SampleRate, StreamConfig, SupportedBufferSize};
use crossbeam_channel::{bounded, Receiver, Sender};

use crate::loudness::LoudnessMeter;
use crate::params::EngineParams;
use crate::rt::{CaptureBuf, CoreConfig, DropPayload, RenderCommand, RenderCore, ENGINE_SAMPLE_RATE};
use crate::stats::{EngineStats, MeterBank, MeterSnapshot, StatsSnapshot};

#[derive(Debug, Clone)]
pub struct EngineConfig {
    pub sample_rate: u32,
    pub max_tracks: usize,
    pub command_capacity: usize,
    pub drop_capacity: usize,
    /// Scratch capacity per render call; larger device buffers are rendered
    /// in chunks of this size.
    pub max_block_frames: usize,
    /// Requested device buffer size.
    pub requested_buffer_frames: u32,
    /// Loudness meter tap channel capacity (frames). 0 disables the meter.
    pub meter_capacity: usize,
    /// Whether the output stream is AUDIBLE at the device. False by default:
    /// the device hears zeros while the render graph still runs for real
    /// (position, meters, and stats stay honest). The GUI app opts in
    /// explicitly (`StudioHost::set_audible_output`, wired from the Swift app
    /// at launch) BEFORE it goes live; the CLI, `cargo test`, `swift test`,
    /// and any headless/CI run leave it false, so the automated-blast safety
    /// cannot regress. `MAJIKS_TEST_AUDIBLE=1` still forces audible for the
    /// attended `engine_proof` checks.
    pub audible: bool,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            sample_rate: ENGINE_SAMPLE_RATE,
            max_tracks: 64,
            command_capacity: 2048,
            // DJ used 16; the timeline engine swaps whole session snapshots
            // (one defer_drop per edit), and edits queued before the stream
            // starts all drain in one callback, so headroom is cheap
            // insurance against counted leaks.
            drop_capacity: 64,
            max_block_frames: 8192,
            requested_buffer_frames: 128,
            meter_capacity: 48_000,
            // SILENT by default. Only an explicit opt-in (the GUI app) or the
            // legacy attended env flag makes the device audible.
            audible: false,
        }
    }
}

#[derive(Debug, Clone)]
pub struct StreamInfo {
    pub device_name: String,
    pub device_default_rate: u32,
    pub configured_rate: u32,
    pub requested_buffer_frames: u32,
    pub fixed_buffer: bool,
    pub channels: u16,
    pub audible: bool,
    /// How many times the output stream has been (re)started.
    pub generation: u32,
}

pub struct Engine {
    cfg: EngineConfig,
    params: Arc<EngineParams>,
    meters: Arc<MeterBank>,
    stats: Arc<EngineStats>,
    command_tx: Sender<RenderCommand>,
    capture_rx: Receiver<CaptureBuf>,
    meter_tx: Option<Sender<[f32; 2]>>,
    core: Option<RenderCore>,
    stream: Option<cpal::Stream>,
    stream_info: Option<StreamInfo>,
    /// Set by the cpal error callback; the owner polls it to rehydrate.
    stream_faulted: Arc<AtomicBool>,
    _loudness: Option<LoudnessMeter>,
}

/// Build a fresh render core plus the control-side ends that talk to it: a
/// new command channel, capture channel, and a drop thread. Shared state
/// (params, meters, stats, the loudness tap) is passed in so it survives a
/// device switch. Used by construction and by rehydrate.
fn build_core(
    cfg: &EngineConfig,
    params: &Arc<EngineParams>,
    meters: &Arc<MeterBank>,
    stats: &Arc<EngineStats>,
    meter_tx: Option<Sender<[f32; 2]>>,
) -> (RenderCore, Sender<RenderCommand>, Receiver<CaptureBuf>) {
    let (command_tx, command_rx) = bounded::<RenderCommand>(cfg.command_capacity);
    let (capture_tx, capture_rx) = bounded::<CaptureBuf>(2);
    let (drop_tx, drop_rx) = bounded::<DropPayload>(cfg.drop_capacity);
    thread::Builder::new()
        .name("majiks-engine-drop".to_string())
        .spawn(move || while drop_rx.recv().is_ok() {})
        .expect("spawn drop thread");
    let core = RenderCore::new(
        CoreConfig {
            sample_rate: cfg.sample_rate,
            max_tracks: cfg.max_tracks,
            // THE one place in the codebase where the monitor path is on.
            // This core drives a real output device, so the metronome click
            // is allowed to reach the buffer here and nowhere else.
            monitor: true,
        },
        Arc::clone(params),
        Arc::clone(meters),
        command_rx,
        drop_tx,
        capture_tx,
        meter_tx,
        Arc::clone(stats),
    );
    (core, command_tx, capture_rx)
}

impl Engine {
    pub fn new(cfg: EngineConfig) -> Self {
        let params = Arc::new(EngineParams::new(cfg.max_tracks));
        let meters = Arc::new(MeterBank::new(cfg.max_tracks));
        let stats = Arc::new(EngineStats::new());

        // The loudness meter thread + its tap channel (optional).
        let (meter_tx, loudness) = if cfg.meter_capacity > 0 {
            let (mtx, mrx) = bounded::<[f32; 2]>(cfg.meter_capacity);
            let meter = LoudnessMeter::spawn(cfg.sample_rate, mrx, Arc::clone(&meters));
            (Some(mtx), Some(meter))
        } else {
            (None, None)
        };

        let (core, command_tx, capture_rx) =
            build_core(&cfg, &params, &meters, &stats, meter_tx.clone());

        Self {
            cfg,
            params,
            meters,
            stats,
            command_tx,
            capture_rx,
            meter_tx,
            core: Some(core),
            stream: None,
            stream_info: None,
            stream_faulted: Arc::new(AtomicBool::new(false)),
            _loudness: loudness,
        }
    }

    pub fn config(&self) -> &EngineConfig {
        &self.cfg
    }

    pub fn params(&self) -> &EngineParams {
        &self.params
    }

    /// Clone the shared params handle. The audio thread creates the engine but
    /// the control side (StudioHost, off-thread) pushes mixer state into these
    /// same atomics, so it needs the `Arc`, not just a borrow.
    pub fn params_arc(&self) -> Arc<EngineParams> {
        Arc::clone(&self.params)
    }

    pub fn meters(&self) -> MeterSnapshot {
        self.meters.snapshot(self.cfg.max_tracks)
    }

    pub fn raw_meters(&self) -> &Arc<MeterBank> {
        &self.meters
    }

    pub fn stats(&self) -> StatsSnapshot {
        self.stats.snapshot()
    }

    pub fn raw_stats(&self) -> &Arc<EngineStats> {
        &self.stats
    }

    /// True after the cpal error callback fired: the owner should call
    /// `restart_output` to rehydrate onto the current default device.
    pub fn stream_faulted(&self) -> bool {
        self.stream_faulted.load(Ordering::Relaxed)
    }

    /// Last position the render core published (device-switch resume point).
    pub fn position_frame(&self) -> u64 {
        self.stats.position_frame.load(Ordering::Relaxed)
    }

    /// Send a command to the render core. try_send only; a full channel is
    /// counted as a command overrun (DJ pattern), never blocks.
    pub fn command(&self, command: RenderCommand) -> bool {
        match self.command_tx.try_send(command) {
            Ok(()) => true,
            Err(_) => {
                self.stats.command_overruns.fetch_add(1, Ordering::Relaxed);
                false
            }
        }
    }

    /// Wait for a finished capture buffer.
    pub fn wait_capture(&self, timeout: Duration) -> Option<CaptureBuf> {
        self.capture_rx.recv_timeout(timeout).ok()
    }

    fn take_core(&mut self) -> Result<RenderCore, String> {
        self.core
            .take()
            .ok_or_else(|| "engine core already consumed (stream running?)".to_string())
    }

    /// Open the cpal output stream and start rendering. Silent by default:
    /// the device hears zeros. The GUI app opts into audible output via
    /// `EngineConfig.audible` (set explicitly before it goes live); the legacy
    /// `MAJIKS_TEST_AUDIBLE=1` env flag also unmutes for attended runs.
    pub fn start_output(&mut self) -> Result<StreamInfo, String> {
        if self.stream.is_some() {
            return self
                .stream_info
                .clone()
                .ok_or_else(|| "stream running without info".to_string());
        }
        // AUDIBLE is an explicit, opt-in decision carried on the engine config:
        // the GUI app sets `audible: true` BEFORE the live stream is built. It
        // stays false by default, so the CLI, headless runs, `cargo test`, and
        // `swift test` never open an audible device (no automated-blast risk).
        // The legacy `MAJIKS_TEST_AUDIBLE=1` env var remains honored for the
        // attended `engine_proof` checks.
        let audible =
            self.cfg.audible || std::env::var("MAJIKS_TEST_AUDIBLE").as_deref() == Ok("1");

        let host = cpal::default_host();
        let device = host
            .default_output_device()
            .ok_or_else(|| "no default output device".to_string())?;
        let device_name = device.name().unwrap_or_else(|_| "unknown".to_string());
        let supported = device
            .default_output_config()
            .map_err(|e| format!("default output config: {e}"))?;
        if supported.sample_format() != SampleFormat::F32 {
            return Err(format!(
                "P0-B supports f32 output only, device offers {:?}",
                supported.sample_format()
            ));
        }
        let device_default_rate = supported.sample_rate().0;
        let channels = supported.channels().max(2);

        let fixed_ok = match supported.buffer_size() {
            SupportedBufferSize::Range { min, max } => {
                self.cfg.requested_buffer_frames >= *min
                    && self.cfg.requested_buffer_frames <= *max
            }
            SupportedBufferSize::Unknown => false,
        };
        let config = StreamConfig {
            channels,
            sample_rate: SampleRate(self.cfg.sample_rate),
            buffer_size: if fixed_ok {
                BufferSize::Fixed(self.cfg.requested_buffer_frames)
            } else {
                BufferSize::Default
            },
        };

        self.stats
            .device_sample_rate
            .store(device_default_rate, Ordering::Relaxed);
        let generation = self.stats.stream_generation.fetch_add(1, Ordering::Relaxed) + 1;
        self.stream_faulted.store(false, Ordering::Relaxed);
        // A new stream may land a different callback size; let it re-latch.
        self.stats.actual_buffer_frames.store(0, Ordering::Relaxed);

        let mut core = self.take_core()?;
        let stats = Arc::clone(&self.stats);
        let max_block = self.cfg.max_block_frames.max(1);
        let mut scratch: Box<[[f32; 2]]> = vec![[0.0; 2]; max_block].into_boxed_slice();
        let ch = channels as usize;

        let err_stats = Arc::clone(&self.stats);
        let err_faulted = Arc::clone(&self.stream_faulted);
        // `core` is moved into the closure here; if the build or play fails,
        // cpal drops the closure (and the core with it). Rebuild a fresh core
        // on the error paths so a failed (re)start never bricks the engine —
        // otherwise every later start_output would fail at take_core forever.
        let stream = match device.build_output_stream(
            &config,
            move |data: &mut [f32], _| {
                let frames = data.len() / ch;
                stats
                    .actual_buffer_frames
                    .compare_exchange(0, frames as u32, Ordering::Relaxed, Ordering::Relaxed)
                    .ok();
                let mut done = 0_usize;
                while done < frames {
                    let n = (frames - done).min(max_block);
                    core.render(&mut scratch[..n]);
                    for i in 0..n {
                        let out = &mut data[(done + i) * ch..(done + i + 1) * ch];
                        if audible {
                            out[0] = scratch[i][0];
                            if ch > 1 {
                                out[1] = scratch[i][1];
                            }
                            for extra in out.iter_mut().skip(2) {
                                *extra = 0.0;
                            }
                        } else {
                            // SILENCE GATE: the graph rendered above for
                            // real; the device hears zeros.
                            for sample in out.iter_mut() {
                                *sample = 0.0;
                            }
                        }
                    }
                    done += n;
                }
                // WHAT THE DEVICE ACTUALLY GOT. `frames_rendered` says what the
                // core produced; this says what left this callback as signal
                // rather than as zeros. The two diverge exactly when the
                // silence gate above is closed, which is the one failure that
                // leaves every other stat green while the room stays quiet.
                // One relaxed add per CALLBACK, beside the callback's other
                // stats writes — never per frame.
                if audible {
                    stats
                        .device_frames_audible
                        .fetch_add(frames as u64, Ordering::Relaxed);
                }
            },
            move |err| {
                err_stats.stream_errors.fetch_add(1, Ordering::Relaxed);
                err_faulted.store(true, Ordering::Relaxed);
                eprintln!("cpal stream error: {err}");
            },
            None,
        ) {
            Ok(stream) => stream,
            Err(e) => {
                self.install_fresh_core();
                return Err(format!("build output stream: {e}"));
            }
        };
        if let Err(e) = stream.play() {
            drop(stream); // drops the moved-in core; rebuild a fresh one
            self.install_fresh_core();
            return Err(format!("start stream: {e}"));
        }

        let info = StreamInfo {
            device_name,
            device_default_rate,
            configured_rate: self.cfg.sample_rate,
            requested_buffer_frames: self.cfg.requested_buffer_frames,
            fixed_buffer: fixed_ok,
            channels,
            audible,
            generation,
        };
        self.stream = Some(stream);
        self.stream_info = Some(info.clone());
        Ok(info)
    }

    /// Rebuild a fresh core (and its control-side channels) on the shared
    /// params/meters/stats. The old core is gone (moved into a dropped
    /// stream, or never built); the host re-pushes the session afterward.
    fn install_fresh_core(&mut self) {
        let (core, command_tx, capture_rx) = build_core(
            &self.cfg,
            &self.params,
            &self.meters,
            &self.stats,
            self.meter_tx.clone(),
        );
        self.command_tx = command_tx;
        self.capture_rx = capture_rx;
        self.core = Some(core);
        self.stream_info = None;
    }

    /// Drop the stream (and the core moved into it) and rebuild a fresh core,
    /// ready for a new stream.
    fn reclaim_core(&mut self) {
        if self.stream.take().is_some() {
            self.install_fresh_core();
        }
    }

    pub fn stop_output(&mut self) {
        self.reclaim_core();
    }

    /// Rehydrate the output onto the current default device after a fault or
    /// a device change. The core is rebuilt with fresh channels but the same
    /// params/meters/stats; the caller (host) re-pushes the session and
    /// re-seeks to the last known position (`position_frame`).
    pub fn restart_output(&mut self) -> Result<StreamInfo, String> {
        self.reclaim_core();
        self.start_output()
    }
}
