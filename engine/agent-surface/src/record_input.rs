//! Live input capture: the !Send cpal input `Stream` owned OFF the shared host,
//! mirroring `live::LiveAudio` for the record path.
//!
//! AUDIO SAFETY (absolute): this module only ever opens an INPUT stream
//! (`render::recording::open_input_stream_multi`). It never builds an output
//! stream and cannot drive a speaker. Monitoring (hearing yourself while
//! tracking) is a separate, double-gated concern
//! (`render::recording::monitoring_allowed`, behind `MAJIKS_TEST_AUDIBLE`) and
//! is deliberately not wired here. Opening a capture stream is an explicit user
//! act (`record.start` or opt-in `record.inputListen`) — never engine startup
//! and never arming a track alone.
//!
//! Threading mirrors `live.rs`: a dedicated audio-host thread OWNS the `!Send`
//! `Stream` for the whole capture; the control side holds only a `Send`
//! `LiveInput` handle (an accumulator `Arc<Mutex<..>>` plus the shared
//! `MultiChannelRing` whose lock-free level atomics the UI reads). The real-time
//! input callback only pushes into the SPSC ring; a writer loop on the owning
//! thread drains that ring into the accumulator (when capturing), so no
//! allocation or lock ever runs in the callback.
//!
//! Multi-channel: the ring stores every device channel. Landing demuxes channel
//! N onto track N via each track's `inputChannel` assignment.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use render::recording::{
    open_input_stream_multi, InputStreamConfig, MultiChannelRing,
};

use crate::error::StudioError;

/// A control-side read of one channel's live input meter.
#[derive(Debug, Clone, Copy)]
pub struct ChannelMeterSnapshot {
    pub channel: u16,
    pub peak: f32,
    pub rms: f32,
    pub clip_latched: bool,
}

/// A control-side read of the live input meter (aggregate + per-channel).
#[derive(Debug, Clone)]
pub struct InputMeterSnapshot {
    /// Falling-peak level across all channels, linear 0..1+.
    pub peak: f32,
    /// Short-term RMS of the loudest channel, linear 0..1+.
    pub rms: f32,
    /// True once any sample on any channel hit full scale; latched until cleared.
    pub clip_latched: bool,
    /// Total frames drained into the accumulator (0 in listen-only mode).
    pub frames: u64,
    /// Ring overflow count (0 on a healthy device); a nonzero value means the
    /// drain loop fell behind, which the UI can surface as a warning.
    pub dropped: usize,
    /// Per-channel meters for identifying which mic is which before a take.
    pub channels: Vec<ChannelMeterSnapshot>,
}

enum InputMsg {
    /// Drain everything currently published by the callback, swap the
    /// writer-side accumulator, and return the completed pass (interleaved
    /// multi-channel samples). The stream remains open while the callback
    /// keeps pushing into the SPSC ring.
    Rotate(Sender<Vec<f32>>),
    /// Switch between listen-only (discard frames, keep metering) and capture
    /// (accumulate for landing).
    SetCapturing(bool),
    ClearClip,
    Stop,
}

struct Bootstrap {
    config: InputStreamConfig,
    ring: Arc<MultiChannelRing>,
}

/// The `Send` control-side handle to a running capture. Dropping it stops the
/// stream (the audio thread joins and the `!Send` `Stream` drops on its own
/// thread). Holds the accumulated capture and shared ring levels.
pub struct LiveInput {
    tx: Sender<InputMsg>,
    /// Interleaved multi-channel samples (channel_count per frame).
    accum: Arc<Mutex<Vec<f32>>>,
    ring: Arc<MultiChannelRing>,
    /// When false, the drain loop discards frames after metering (opt-in
    /// listen). When true, frames accumulate for `finish` / `rotate`.
    capturing: Arc<AtomicBool>,
    frames: Arc<AtomicU64>,
    handle: Option<JoinHandle<()>>,
    config: InputStreamConfig,
    /// True when this handle never opened a real cpal device (test inject).
    virtual_mode: bool,
}

impl LiveInput {
    /// Ring capacity: ~1 s of frames at 48k (rounded up to a power of two
    /// by `MultiChannelRing::new`). Generous, so the ~5 ms drain loop never
    /// overflows on a healthy device.
    const RING_FRAMES: usize = 48_000;
    /// Drain / meter-publish interval. Doubles as the shutdown poll.
    const DRAIN_INTERVAL: Duration = Duration::from_millis(5);

    /// Open an input stream on `device` (system default when None).
    /// `capturing`: when false, frames are metered then discarded (listen-only
    /// gain-staging); when true, frames accumulate for landing.
    /// `channel_hint`: preferred channel count for the ring (device may report more).
    pub fn start(
        device: Option<String>,
        capturing: bool,
        channel_hint: usize,
    ) -> Result<Self, StudioError> {
        let channel_hint = channel_hint.max(1);
        let (tx, rx) = channel::<InputMsg>();
        let (boot_tx, boot_rx) = channel::<Result<Bootstrap, String>>();
        let accum: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::new()));
        let capturing = Arc::new(AtomicBool::new(capturing));
        let frames = Arc::new(AtomicU64::new(0));
        let accum_thread = Arc::clone(&accum);
        let capturing_thread = Arc::clone(&capturing);
        let frames_thread = Arc::clone(&frames);

        let handle = std::thread::Builder::new()
            .name("majiks-studio-input".to_string())
            .spawn(move || {
                // Size the ring for the hint; the device may report more channels
                // and push_frame will truncate, or fewer and pad with silence.
                let ring = Arc::new(MultiChannelRing::new(Self::RING_FRAMES, channel_hint));
                // The !Send input Stream is born, lives, and dies on THIS thread.
                let _stream = match open_input_stream_multi(Arc::clone(&ring), device.as_deref()) {
                    Ok((stream, config)) => {
                        // If the device has more channels than the hint, rebuild
                        // is too late (stream already open). The ring still
                        // captures min(hint, device) correctly; for a full AMS-44
                        // the host passes channel_hint from device enumeration.
                        if boot_tx
                            .send(Ok(Bootstrap {
                                config,
                                ring: Arc::clone(&ring),
                            }))
                            .is_err()
                        {
                            return; // control side gave up; the stream drops here
                        }
                        stream
                    }
                    Err(e) => {
                        let _ = boot_tx.send(Err(e));
                        return;
                    }
                };

                let mut scratch: Vec<f32> = Vec::with_capacity(Self::RING_FRAMES * channel_hint);
                loop {
                    match rx.recv_timeout(Self::DRAIN_INTERVAL) {
                        Ok(InputMsg::Rotate(reply)) => {
                            drain_block(
                                &ring,
                                &mut scratch,
                                &accum_thread,
                                capturing_thread.load(Ordering::Relaxed),
                                &frames_thread,
                            );
                            let _ = reply.send(take_accum(&accum_thread));
                        }
                        Ok(InputMsg::SetCapturing(on)) => {
                            capturing_thread.store(on, Ordering::Relaxed);
                            if on {
                                // Fresh pass: discard any listen-mode residue.
                                let _ = take_accum(&accum_thread);
                                frames_thread.store(0, Ordering::Relaxed);
                            }
                        }
                        Ok(InputMsg::ClearClip) => {
                            ring.clear_all_clips();
                        }
                        Ok(InputMsg::Stop) | Err(RecvTimeoutError::Disconnected) => {
                            drain_block(
                                &ring,
                                &mut scratch,
                                &accum_thread,
                                capturing_thread.load(Ordering::Relaxed),
                                &frames_thread,
                            );
                            break;
                        }
                        Err(RecvTimeoutError::Timeout) => {
                            // Falling-peak ballistics on the control-visible peak.
                            ring.decay_all_peaks(0.85);
                            drain_block(
                                &ring,
                                &mut scratch,
                                &accum_thread,
                                capturing_thread.load(Ordering::Relaxed),
                                &frames_thread,
                            );
                        }
                    }
                }
                // `_stream` drops here, on the thread that built it — the only
                // safe place for a !Send cpal Stream.
            })
            .map_err(|e| StudioError::audio(format!("spawn input thread: {e}")))?;

        match boot_rx.recv() {
            Ok(Ok(boot)) => Ok(Self {
                tx,
                accum,
                ring: boot.ring,
                capturing,
                frames,
                handle: Some(handle),
                config: boot.config,
                virtual_mode: false,
            }),
            Ok(Err(e)) => {
                let _ = handle.join();
                Err(StudioError::audio(format!("open input stream: {e}")))
            }
            Err(_) => {
                let _ = handle.join();
                Err(StudioError::audio("input thread exited before startup"))
            }
        }
    }

    /// Device-free capture handle for tests. Behaves like a live open input
    /// (is_open, meter, finish/rotate demux) without touching CoreAudio. The
    /// host injects this to prove arm ≠ open and multi-channel routing without
    /// a hardware interface.
    #[doc(hidden)]
    pub fn start_virtual(channel_count: usize, sample_rate: u32, capturing: bool) -> Self {
        let channel_count = channel_count.max(1);
        let (tx, rx) = channel::<InputMsg>();
        let accum: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::new()));
        let capturing_flag = Arc::new(AtomicBool::new(capturing));
        let frames = Arc::new(AtomicU64::new(0));
        let ring = Arc::new(MultiChannelRing::new(Self::RING_FRAMES, channel_count));
        let ring_thread = Arc::clone(&ring);
        let accum_thread = Arc::clone(&accum);
        let capturing_thread = Arc::clone(&capturing_flag);
        let frames_thread = Arc::clone(&frames);

        let handle = std::thread::Builder::new()
            .name("majiks-studio-input-virtual".to_string())
            .spawn(move || {
                let mut scratch: Vec<f32> =
                    Vec::with_capacity(Self::RING_FRAMES * channel_count);
                loop {
                    match rx.recv_timeout(Self::DRAIN_INTERVAL) {
                        Ok(InputMsg::Rotate(reply)) => {
                            drain_block(
                                &ring_thread,
                                &mut scratch,
                                &accum_thread,
                                capturing_thread.load(Ordering::Relaxed),
                                &frames_thread,
                            );
                            let _ = reply.send(take_accum(&accum_thread));
                        }
                        Ok(InputMsg::SetCapturing(on)) => {
                            capturing_thread.store(on, Ordering::Relaxed);
                            if on {
                                let _ = take_accum(&accum_thread);
                                frames_thread.store(0, Ordering::Relaxed);
                            }
                        }
                        Ok(InputMsg::ClearClip) => {
                            ring_thread.clear_all_clips();
                        }
                        Ok(InputMsg::Stop) | Err(RecvTimeoutError::Disconnected) => {
                            drain_block(
                                &ring_thread,
                                &mut scratch,
                                &accum_thread,
                                capturing_thread.load(Ordering::Relaxed),
                                &frames_thread,
                            );
                            break;
                        }
                        Err(RecvTimeoutError::Timeout) => {
                            ring_thread.decay_all_peaks(0.85);
                            drain_block(
                                &ring_thread,
                                &mut scratch,
                                &accum_thread,
                                capturing_thread.load(Ordering::Relaxed),
                                &frames_thread,
                            );
                        }
                    }
                }
            })
            .expect("spawn virtual input thread");

        Self {
            tx,
            accum,
            ring,
            capturing: capturing_flag,
            frames,
            handle: Some(handle),
            config: InputStreamConfig {
                sample_rate,
                channels: channel_count as u16,
                device_name: "virtual-input".to_string(),
            },
            virtual_mode: true,
        }
    }

    /// Push interleaved multi-channel frames into a virtual input (test only).
    #[doc(hidden)]
    pub fn feed_virtual(&self, interleaved: &[f32]) -> usize {
        if !self.virtual_mode {
            return 0;
        }
        let ch = self.ring.channel_count();
        let mut n = 0;
        for frame in interleaved.chunks(ch) {
            if self.ring.push_frame(frame) {
                n += 1;
            }
        }
        n
    }

    /// Promote a listen-only stream into a capturing one (or demote).
    pub fn set_capturing(&self, on: bool) {
        self.capturing.store(on, Ordering::Relaxed);
        let _ = self.tx.send(InputMsg::SetCapturing(on));
    }

    pub fn is_capturing(&self) -> bool {
        self.capturing.load(Ordering::Relaxed)
    }

    /// A non-destructive read of the current input meter (for the UI).
    pub fn meter(&self) -> InputMeterSnapshot {
        let channels: Vec<ChannelMeterSnapshot> = self
            .ring
            .all_levels()
            .iter()
            .enumerate()
            .map(|(i, l)| ChannelMeterSnapshot {
                channel: i as u16,
                peak: l.peak(),
                rms: l.rms(),
                clip_latched: l.clip_latched(),
            })
            .collect();
        let peak = channels.iter().map(|c| c.peak).fold(0.0f32, f32::max);
        let rms = channels.iter().map(|c| c.rms).fold(0.0f32, f32::max);
        let clip_latched = channels.iter().any(|c| c.clip_latched);
        InputMeterSnapshot {
            peak,
            rms,
            clip_latched,
            frames: self.frames.load(Ordering::Relaxed),
            dropped: self.ring.dropped_frames(),
            channels,
        }
    }

    pub fn clear_clip_latch(&self) {
        self.ring.clear_all_clips();
        let _ = self.tx.send(InputMsg::ClearClip);
    }

    pub fn sample_rate(&self) -> u32 {
        self.config.sample_rate
    }

    pub fn channel_count(&self) -> u16 {
        self.config.channels.max(self.ring.channel_count() as u16)
    }

    pub fn device_name(&self) -> &str {
        &self.config.device_name
    }

    pub fn is_virtual(&self) -> bool {
        self.virtual_mode
    }

    /// Complete the current pass without stopping or reopening the input
    /// device. Returns interleaved multi-channel samples.
    pub fn rotate(&self) -> Vec<f32> {
        let (reply_tx, reply_rx) = channel();
        if self.tx.send(InputMsg::Rotate(reply_tx)).is_err() {
            return Vec::new();
        }
        reply_rx.recv().unwrap_or_default()
    }

    /// Stop capture and take ownership of everything recorded (interleaved).
    pub fn finish(&mut self) -> Vec<f32> {
        let _ = self.tx.send(InputMsg::Stop);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
        self.accum
            .lock()
            .map(|mut g| std::mem::take(&mut *g))
            .unwrap_or_default()
    }

    /// Demux one device channel from interleaved samples into dual-mono stereo.
    pub fn demux_stereo(interleaved: &[f32], channel_count: usize, channel: usize) -> Vec<[f32; 2]> {
        MultiChannelRing::demux_channel_stereo(interleaved, channel_count, channel)
    }
}

fn take_accum(accum: &Mutex<Vec<f32>>) -> Vec<f32> {
    accum
        .lock()
        .map(|mut g| std::mem::take(&mut *g))
        .unwrap_or_default()
}

/// Drain the ring into the accumulator when capturing; otherwise discard after
/// the callback already updated level atomics. Writer-side only.
fn drain_block(
    ring: &MultiChannelRing,
    scratch: &mut Vec<f32>,
    accum: &Mutex<Vec<f32>>,
    capturing: bool,
    frames: &AtomicU64,
) {
    scratch.clear();
    let n = ring.drain_interleaved(scratch);
    if n == 0 {
        return;
    }
    if capturing {
        frames.fetch_add(n as u64, Ordering::Relaxed);
        if let Ok(mut a) = accum.lock() {
            a.extend_from_slice(scratch);
        }
    }
}

impl Drop for LiveInput {
    fn drop(&mut self) {
        let _ = self.tx.send(InputMsg::Stop);
        if let Some(handle) = self.handle.take() {
            // Join so the stream is fully torn down and the device released
            // before we return.
            let _ = handle.join();
        }
    }
}

/// Device-free multi-channel input owner used by recording acceptance tests.
/// Exercises the same callback-facing `MultiChannelRing`, writer-side drain,
/// and accumulator swap as `LiveInput::rotate`, but never opens an OS stream.
#[doc(hidden)]
pub struct VirtualInput {
    ring: MultiChannelRing,
    scratch: Vec<f32>,
    accum: Mutex<Vec<f32>>,
    capturing: bool,
    frames: u64,
    channel_count: usize,
}

impl VirtualInput {
    /// Stereo (2-channel) virtual input — the shape existing loop-record tests use.
    pub fn new(capacity_frames: usize) -> Self {
        Self::with_channels(capacity_frames, 2)
    }

    pub fn with_channels(capacity_frames: usize, channel_count: usize) -> Self {
        let channel_count = channel_count.max(1);
        Self {
            ring: MultiChannelRing::new(capacity_frames, channel_count),
            scratch: Vec::with_capacity(capacity_frames * channel_count),
            accum: Mutex::new(Vec::new()),
            capturing: true,
            frames: 0,
            channel_count,
        }
    }

    /// Simulate the input callback with interleaved multi-channel frames.
    pub fn feed_interleaved(&mut self, interleaved: &[f32]) -> usize {
        let mut n = 0;
        for frame in interleaved.chunks(self.channel_count) {
            if self.ring.push_frame(frame) {
                n += 1;
            }
        }
        n
    }

    /// Stereo convenience: feed L/R as a 2-channel frame stream.
    pub fn feed(&mut self, frames: &[[f32; 2]]) -> usize {
        let mut n = 0;
        for f in frames {
            if self.ring.push_frame(f) {
                n += 1;
            }
        }
        n
    }

    /// Simulate the owner-side boundary handoff. Returns interleaved samples.
    pub fn rotate_interleaved(&mut self) -> Vec<f32> {
        let frames_counter = AtomicU64::new(self.frames);
        drain_block(
            &self.ring,
            &mut self.scratch,
            &self.accum,
            self.capturing,
            &frames_counter,
        );
        self.frames = frames_counter.load(Ordering::Relaxed);
        take_accum(&self.accum)
    }

    /// Stereo boundary handoff (L/R from the first two channels). Matches the
    /// historical `rotate` contract used by gapless loop-record tests.
    pub fn rotate(&mut self) -> Vec<[f32; 2]> {
        let interleaved = self.rotate_interleaved();
        interleaved
            .chunks(self.channel_count)
            .map(|f| {
                let l = f.first().copied().unwrap_or(0.0);
                let r = f.get(1).copied().unwrap_or(l);
                [l, r]
            })
            .collect()
    }

    /// Rotate and demux one channel to dual-mono stereo.
    pub fn rotate_stereo_channel(&mut self, channel: usize) -> Vec<[f32; 2]> {
        let interleaved = self.rotate_interleaved();
        MultiChannelRing::demux_channel_stereo(&interleaved, self.channel_count, channel)
    }

    pub fn channel_count(&self) -> usize {
        self.channel_count
    }

    pub fn levels_peak(&self) -> f32 {
        self.ring
            .all_levels()
            .iter()
            .map(|l| l.peak())
            .fold(0.0f32, f32::max)
    }

    pub fn levels_peak_channel(&self, channel: usize) -> f32 {
        self.ring.levels(channel).peak()
    }

    pub fn levels_clip_latched(&self) -> bool {
        self.ring.all_levels().iter().any(|l| l.clip_latched())
    }

    pub fn dropped_frames(&self) -> usize {
        self.ring.dropped_frames()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The point of this module: the handle is `Send` (so `StudioHost`, hence
    /// the MCP server's `Arc<Mutex<StudioHost>>`, stays `Send`) even though the
    /// cpal input `Stream` it drives is not. A regression that pulled a `!Send`
    /// type into `LiveInput` would fail HERE, at compile time.
    #[test]
    fn input_handle_is_send() {
        fn assert_send<T: Send>() {}
        assert_send::<LiveInput>();
    }

    #[test]
    fn virtual_input_levels_follow_feed() {
        let mut v = VirtualInput::new(256);
        let frames = render::recording::SyntheticInput::sine(64, 48_000, 440.0, 0.5);
        assert_eq!(v.feed(&frames), 64);
        assert!(v.levels_peak() > 0.4);
        assert!(!v.levels_clip_latched());
        let hot = [[1.1f32, 1.1]];
        let _ = v.feed(&hot);
        assert!(v.levels_clip_latched());
    }

    #[test]
    fn virtual_input_preserves_four_channel_identity() {
        let mut v = VirtualInput::with_channels(256, 4);
        let interleaved = render::recording::synthetic_channel_dc(32, 4, 0.1);
        assert_eq!(v.feed_interleaved(&interleaved), 32);
        for ch in 0..4 {
            assert!((v.levels_peak_channel(ch) - (ch as f32 + 1.0) * 0.1).abs() < 1e-6);
        }
        let ch2 = v.rotate_stereo_channel(2);
        assert_eq!(ch2.len(), 32);
        assert!(ch2.iter().all(|s| (s[0] - 0.3).abs() < 1e-6));
    }
}
