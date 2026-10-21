//! Offline and manual rendering through the SAME graph code.
//!
//! `ManualRenderer` owns a `RenderCore` (identical construction to the one
//! inside the cpal closure) and lets a caller clock it by hand: the offline
//! bounce, the null test, and the deterministic integration tests all drive
//! this. There is exactly one render function in the codebase
//! (`RenderCore::render`); this module only decides when it runs and with
//! what block sizes.

use std::sync::Arc;
use std::time::Duration;

use crossbeam_channel::{bounded, Receiver, Sender};
use serde::Serialize;

use crate::engine::EngineConfig;
use crate::params::EngineParams;
use crate::rt::{CaptureBuf, CoreConfig, DropPayload, RenderCommand, RenderCore};
use crate::stats::{EngineStats, MeterBank};

pub struct ManualRenderer {
    core: RenderCore,
    command_tx: Sender<RenderCommand>,
    capture_rx: Receiver<CaptureBuf>,
    params: Arc<EngineParams>,
    meters: Arc<MeterBank>,
    stats: Arc<EngineStats>,
}

impl ManualRenderer {
    /// An OFFLINE renderer. `monitor: false` — see [`CoreConfig::monitor`].
    /// Every bounce, stem export, null test and parity test in the codebase
    /// comes through here, so none of them can produce a metronome click no
    /// matter what the params say.
    pub fn new(cfg: &EngineConfig) -> Self {
        Self::build(cfg, false)
    }

    /// A renderer that behaves like the LIVE device path: the metronome click
    /// is summed into the output.
    ///
    /// This exists so the click can be tested at all — `render_offline` cannot
    /// be made to emit one. Nothing in the product calls it; if you find a
    /// bounce path using this constructor, that is the bug.
    pub fn new_monitoring(cfg: &EngineConfig) -> Self {
        Self::build(cfg, true)
    }

    fn build(cfg: &EngineConfig, monitor: bool) -> Self {
        let params = Arc::new(EngineParams::new(cfg.max_tracks));
        let meters = Arc::new(MeterBank::new(cfg.max_tracks));
        let stats = Arc::new(EngineStats::new());
        let (command_tx, command_rx) = bounded::<RenderCommand>(cfg.command_capacity);
        let (capture_tx, capture_rx) = bounded::<CaptureBuf>(2);
        let (drop_tx, drop_rx) = bounded::<DropPayload>(cfg.drop_capacity);
        std::thread::Builder::new()
            .name("majiks-offline-drop".to_string())
            .spawn(move || while drop_rx.recv().is_ok() {})
            .expect("spawn offline drop thread");
        // No loudness tap on the offline path: deterministic bounces measure
        // loudness on the finished buffer (crate::loudness::integrated_lufs).
        let core = RenderCore::new(
            CoreConfig {
                sample_rate: cfg.sample_rate,
                max_tracks: cfg.max_tracks,
                monitor,
            },
            Arc::clone(&params),
            Arc::clone(&meters),
            command_rx,
            drop_tx,
            capture_tx,
            None,
            Arc::clone(&stats),
        );
        Self {
            core,
            command_tx,
            capture_rx,
            params,
            meters,
            stats,
        }
    }

    /// Queue a command; it takes effect at the start of the next block.
    pub fn send(&self, command: RenderCommand) -> bool {
        self.command_tx.try_send(command).is_ok()
    }

    pub fn render(&mut self, out: &mut [[f32; 2]]) {
        self.core.render(out);
    }

    pub fn params(&self) -> &EngineParams {
        &self.params
    }

    pub fn meters(&self) -> &Arc<MeterBank> {
        &self.meters
    }

    pub fn stats(&self) -> &Arc<EngineStats> {
        &self.stats
    }

    pub fn wait_capture(&self, timeout: Duration) -> Option<CaptureBuf> {
        self.capture_rx.recv_timeout(timeout).ok()
    }
}

/// A command applied at an exact frame boundary of an offline render.
pub struct ScheduledCommand {
    pub at_frame: u64,
    pub command: RenderCommand,
}

/// Render `total_frames` offline in blocks of at most `chunk_frames`,
/// splitting blocks at every scheduled command so commands land at exactly
/// their frame. Returns the master output.
pub fn render_offline(
    cfg: &EngineConfig,
    schedule: Vec<ScheduledCommand>,
    total_frames: u64,
    chunk_frames: usize,
) -> Vec<[f32; 2]> {
    let mut renderer = ManualRenderer::new(cfg);
    render_offline_with(&mut renderer, schedule, total_frames, chunk_frames)
}

/// Same as `render_offline` but on a caller-provided renderer (lets tests
/// pre-set params).
pub fn render_offline_with(
    renderer: &mut ManualRenderer,
    mut schedule: Vec<ScheduledCommand>,
    total_frames: u64,
    chunk_frames: usize,
) -> Vec<[f32; 2]> {
    schedule.sort_by_key(|s| s.at_frame);
    schedule.reverse(); // pop() yields earliest first
    let chunk = chunk_frames.max(1);
    let mut out = vec![[0.0_f32; 2]; total_frames as usize];
    let mut rendered = 0_u64;
    while rendered < total_frames {
        while schedule
            .last()
            .map(|s| s.at_frame <= rendered)
            .unwrap_or(false)
        {
            let item = schedule.pop().expect("nonempty");
            let ok = renderer.send(item.command);
            debug_assert!(ok, "offline command channel overflow");
        }
        let next_boundary = schedule
            .last()
            .map(|s| s.at_frame.min(total_frames))
            .unwrap_or(total_frames);
        let n = ((next_boundary - rendered).min(chunk as u64)) as usize;
        let n = n.max(1);
        let start = rendered as usize;
        renderer.render(&mut out[start..start + n]);
        rendered += n as u64;
    }
    out
}

#[derive(Debug, Clone, Serialize)]
pub struct Residual {
    pub frames_compared: usize,
    pub max_abs: f32,
    pub peak_dbfs: f64,
    pub rms_dbfs: f64,
    pub bit_identical: bool,
}

/// Null-test measurement between two renders.
pub fn residual(a: &[[f32; 2]], b: &[[f32; 2]]) -> Residual {
    let frames = a.len().min(b.len());
    let mut max_abs = 0.0_f32;
    let mut sum_sq = 0.0_f64;
    let mut bit_identical = a.len() == b.len();
    for i in 0..frames {
        for ch in 0..2 {
            let d = a[i][ch] - b[i][ch];
            if a[i][ch].to_bits() != b[i][ch].to_bits() {
                bit_identical = false;
            }
            let ad = d.abs();
            if ad > max_abs {
                max_abs = ad;
            }
            sum_sq += f64::from(d) * f64::from(d);
        }
    }
    let rms = if frames > 0 {
        (sum_sq / (frames as f64 * 2.0)).sqrt()
    } else {
        0.0
    };
    Residual {
        frames_compared: frames,
        max_abs,
        peak_dbfs: if max_abs > 0.0 {
            20.0 * f64::from(max_abs).log10()
        } else {
            f64::NEG_INFINITY
        },
        rms_dbfs: if rms > 0.0 {
            20.0 * rms.log10()
        } else {
            f64::NEG_INFINITY
        },
        bit_identical,
    }
}
