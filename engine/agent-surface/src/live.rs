//! Live audio: the !Send half of the studio, owned OFF the shared host.
//!
//! `render::Engine` holds the cpal output `Stream`, which is `!Send` on macOS.
//! `StudioHost` sits inside an `Arc<Mutex<..>>` (the MCP server shares it) and
//! must stay `Send`, so it can NOT own the engine. This is exactly the hazard
//! the DJ engine hit and solved by going global; here we solve it by rule
//! instead of a singleton:
//!
//! - a dedicated audio-host thread OWNS the `render::Engine` (and its `!Send`
//!   `Stream`) for the whole live session; the engine never crosses a thread,
//!   never sits in the shared lock;
//! - the control side (`StudioHost`) holds only a `Send` `LiveAudio` handle:
//!   a command `Sender` plus the shared param/meter/stat `Arc`s the render side
//!   also holds;
//! - transport + compiled-session commands cross the bounded channel as
//!   `RenderCommand`s (all `Send`: the heap-shaped `Box<RtSession>` is built on
//!   the control thread and moved in, then freed on the engine's own drop
//!   thread, never inline in the callback);
//! - meters, stats, and the play position are read lock-free from the shared
//!   atomics the render thread publishes into.
//!
//! AUDIO SAFETY (absolute, inherited from render::engine): the cpal stream is
//! SILENCE-GATED. The render graph runs every callback for real (so position,
//! meters, and stats are honest) but the DEVICE receives zeros unless the
//! engine config was built AUDIBLE — an explicit opt-in the GUI app makes
//! (`StudioHost::set_audible_output`, wired from the Swift app at launch), or
//! the legacy `MAJIKS_TEST_AUDIBLE=1` env flag. Opening a live session is
//! itself an explicit act (`StudioHost::start_live`, a user pressing play in
//! the app); nothing auto-opens a device, and no test or headless run starts
//! one or sets the audible flag.

use std::sync::atomic::Ordering;
use std::sync::mpsc::{channel, Sender};
use std::sync::Arc;
use std::thread::JoinHandle;

use render::params::EngineParams;
use render::stats::{EngineStats, MeterBank, MeterSnapshot, StatsSnapshot};
use render::{Engine, EngineConfig, RenderCommand, StreamInfo};

use crate::error::StudioError;

/// What the control side sends to the audio-host thread. `RenderCommand` is the
/// engine's own command type (transport + `SetSession`); `Shutdown` unwinds the
/// thread so the `Stream` drops on the thread that built it.
enum LiveMsg {
    Command(RenderCommand),
    Shutdown,
}

/// Handed back over the bootstrap channel once the audio thread has built the
/// engine and opened (or failed to open) the output stream. Carries the shared
/// handles the control side reads without ever touching the engine.
struct Bootstrap {
    params: Arc<EngineParams>,
    meters: Arc<MeterBank>,
    stats: Arc<EngineStats>,
    info: StreamInfo,
}

/// The `Send` control-side handle to a running live audio session. Dropping it
/// stops the stream (the audio thread joins, and the `!Send` `Stream` drops on
/// its own thread).
pub struct LiveAudio {
    tx: Sender<LiveMsg>,
    params: Arc<EngineParams>,
    meters: Arc<MeterBank>,
    stats: Arc<EngineStats>,
    info: StreamInfo,
    handle: Option<JoinHandle<()>>,
    /// Track capacity the engine was built with (compile must not exceed it).
    max_tracks: usize,
}

impl LiveAudio {
    /// Spawn the audio-host thread, build the engine, and open the output
    /// stream. Blocks until the stream is up (or the open failed). The device
    /// is SILENT by default (see the module note); this never makes sound.
    pub fn start(cfg: EngineConfig) -> Result<Self, StudioError> {
        let max_tracks = cfg.max_tracks;
        let (tx, rx) = channel::<LiveMsg>();
        let (boot_tx, boot_rx) = channel::<Result<Bootstrap, String>>();

        let handle = std::thread::Builder::new()
            .name("majiks-studio-audio".to_string())
            .spawn(move || {
                // The engine (and its !Send Stream) is born, lives, and dies on
                // THIS thread. It is never moved out.
                let mut engine = Engine::new(cfg);
                match engine.start_output() {
                    Ok(info) => {
                        let boot = Bootstrap {
                            params: engine.params_arc(),
                            meters: Arc::clone(engine.raw_meters()),
                            stats: Arc::clone(engine.raw_stats()),
                            info,
                        };
                        // If the control side already gave up, tear down.
                        if boot_tx.send(Ok(boot)).is_err() {
                            engine.stop_output();
                            return;
                        }
                    }
                    Err(e) => {
                        let _ = boot_tx.send(Err(e));
                        return;
                    }
                }

                // Command pump: forward everything to the engine until asked to
                // stop or the control side hangs up.
                while let Ok(msg) = rx.recv() {
                    match msg {
                        LiveMsg::Command(cmd) => {
                            engine.command(cmd);
                        }
                        LiveMsg::Shutdown => break,
                    }
                }
                engine.stop_output();
                // `engine` drops here: the cpal Stream drops on the thread that
                // created it, which is the only safe place for it.
            })
            .map_err(|e| StudioError::audio(format!("spawn audio thread: {e}")))?;

        match boot_rx.recv() {
            Ok(Ok(boot)) => Ok(Self {
                tx,
                params: boot.params,
                meters: boot.meters,
                stats: boot.stats,
                info: boot.info,
                handle: Some(handle),
                max_tracks,
            }),
            Ok(Err(e)) => {
                let _ = handle.join();
                Err(StudioError::audio(format!("open output stream: {e}")))
            }
            Err(_) => {
                let _ = handle.join();
                Err(StudioError::audio("audio thread exited before startup"))
            }
        }
    }

    /// Send a render command (transport or a freshly compiled session) to the
    /// audio thread. Best-effort: a dead thread just means the next read shows
    /// a stale position, never a panic.
    pub fn command(&self, cmd: RenderCommand) {
        let _ = self.tx.send(LiveMsg::Command(cmd));
    }

    /// The shared params the render side reads each block. The control side
    /// pushes mixer/master state into these (same atomics, off-thread).
    pub fn params(&self) -> &EngineParams {
        &self.params
    }

    /// Per-poll meter read (peaks are read-and-reset by the render-side spec).
    pub fn meters_snapshot(&self, track_count: usize) -> MeterSnapshot {
        self.meters.snapshot(track_count)
    }

    /// Per-poll routing-node meter read (E5 §8): `(peak_l, peak_r, block_rms)`
    /// for the first `count` node slots, in `routing.nodes` index order — the
    /// same index the compiled walk meters into. Pass-through to
    /// `MeterBank::node_meters`; peaks are read-and-reset exactly like
    /// `meters_snapshot`, so keep ONE poller (the host's `meters()` read).
    pub fn node_meters(&self, count: usize) -> Vec<(f32, f32, f32)> {
        self.meters.node_meters(count)
    }

    /// Non-destructive engine health read.
    pub fn stats_snapshot(&self) -> StatsSnapshot {
        self.stats.snapshot()
    }

    /// Current play head in frames (the render thread advances it per frame).
    pub fn position_frame(&self) -> u64 {
        self.stats.position_frame.load(Ordering::Relaxed)
    }

    /// Whether the render core is currently advancing the transport.
    pub fn playing(&self) -> bool {
        self.stats.playing.load(Ordering::Relaxed) != 0
    }

    pub fn stream_info(&self) -> &StreamInfo {
        &self.info
    }

    pub fn max_tracks(&self) -> usize {
        self.max_tracks
    }
}

impl Drop for LiveAudio {
    fn drop(&mut self) {
        let _ = self.tx.send(LiveMsg::Shutdown);
        if let Some(handle) = self.handle.take() {
            // Join so the stream is fully torn down before we return; the
            // device is released deterministically.
            let _ = handle.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The entire point of this module: the handle is `Send` (so `StudioHost`,
    /// hence the MCP server's `Arc<Mutex<StudioHost>>`, stays `Send`) even
    /// though the engine it drives is not. A regression that pulled a `!Send`
    /// type into `LiveAudio` (e.g. the `Stream` itself) would fail HERE, at
    /// compile time, not as a spooky runtime crash.
    #[test]
    fn live_handle_is_send() {
        fn assert_send<T: Send>() {}
        assert_send::<LiveAudio>();
        assert_send::<crate::host::StudioHost>();
    }
}
