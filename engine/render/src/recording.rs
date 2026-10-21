//! Input capture primitives for Studio recording.
//!
//! The callback-facing API is deliberately tiny: it only copies samples into
//! a preallocated SPSC ring, updates level atomics, and advances indices.  It
//! never allocates, locks, logs, opens files, or touches the output device.
//! Draining, encoding, analysis, and timeline landing belong to the control
//! / writer side.

use std::sync::atomic::{AtomicU32, AtomicUsize, Ordering};
use std::sync::Mutex;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

/// Lock-free input level state. Updated from the audio callback (or any
/// producer that feeds the ring). Peak is a CAS-max of absolute amplitude;
/// short-term RMS is an exponential mean-square; clip latches until
/// [`InputLevels::clear_clip`].
///
/// All methods are allocation-free and lock-free.
#[derive(Debug, Default)]
pub struct InputLevels {
    peak_bits: AtomicU32,
    /// Exponential mean of (L²+R²)/2 — take sqrt for linear RMS.
    rms_sq_bits: AtomicU32,
    /// 0 = clean, 1 = a sample at or above full scale was observed.
    clip_latched: AtomicU32,
}

impl InputLevels {
    pub fn new() -> Self {
        Self::default()
    }

    /// Callback-safe. Observe one stereo frame.
    #[inline(always)]
    pub fn observe_stereo(&self, left: f32, right: f32) {
        let a = left.abs().max(right.abs());
        self.peak_max(a);
        let sq = 0.5 * (left * left + right * right);
        // ~5 ms-ish ballistics at 48 kHz block rates; pure atomics, no window buffer.
        let prev = f32::from_bits(self.rms_sq_bits.load(Ordering::Relaxed));
        let next = prev.mul_add(0.995, sq * 0.005);
        self.rms_sq_bits.store(next.to_bits(), Ordering::Relaxed);
        if a >= 1.0 {
            self.clip_latched.store(1, Ordering::Relaxed);
        }
    }

    #[inline(always)]
    pub fn observe_mono(&self, sample: f32) {
        self.observe_stereo(sample, sample);
    }

    #[inline(always)]
    fn peak_max(&self, v: f32) {
        let bits = v.to_bits();
        let mut cur = self.peak_bits.load(Ordering::Relaxed);
        while f32::from_bits(cur) < v {
            match self.peak_bits.compare_exchange_weak(
                cur,
                bits,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => break,
                Err(c) => cur = c,
            }
        }
    }

    /// Current peak linear 0..∞ (typically 0..1+).
    #[inline]
    pub fn peak(&self) -> f32 {
        f32::from_bits(self.peak_bits.load(Ordering::Relaxed))
    }

    /// Short-term linear RMS estimate.
    #[inline]
    pub fn rms(&self) -> f32 {
        f32::from_bits(self.rms_sq_bits.load(Ordering::Relaxed)).max(0.0).sqrt()
    }

    /// True once any sample reached full scale; stays true until [`clear_clip`].
    #[inline]
    pub fn clip_latched(&self) -> bool {
        self.clip_latched.load(Ordering::Relaxed) != 0
    }

    /// Clear the latched over indicator (control side / UI reset).
    #[inline]
    pub fn clear_clip(&self) {
        self.clip_latched.store(0, Ordering::Relaxed);
    }

    /// Multiply the stored peak by `factor` (falling-peak ballistics). Control
    /// side only; safe from any thread.
    #[inline]
    pub fn decay_peak(&self, factor: f32) {
        let cur = f32::from_bits(self.peak_bits.load(Ordering::Relaxed));
        self.peak_bits.store((cur * factor).to_bits(), Ordering::Relaxed);
    }

    /// Reset peak + RMS (does not clear the clip latch unless `clear_clip` too).
    #[inline]
    pub fn reset_levels(&self) {
        self.peak_bits.store(0, Ordering::Relaxed);
        self.rms_sq_bits.store(0, Ordering::Relaxed);
    }
}

/// A bounded stereo interleaved SPSC buffer. The producer is the CoreAudio
/// input callback; the consumer is a writer thread.
pub struct InputRing {
    samples: Box<[AtomicU32]>,
    capacity_frames: usize,
    write: AtomicUsize,
    read: AtomicUsize,
    dropped: AtomicUsize,
    /// Levels always update on push, whether or not a capture is landing.
    levels: InputLevels,
}

impl InputRing {
    pub fn new(capacity_frames: usize) -> Self {
        let capacity_frames = capacity_frames.max(1).next_power_of_two();
        let samples = (0..capacity_frames * 2)
            .map(|_| AtomicU32::new(0))
            .collect::<Vec<_>>()
            .into_boxed_slice();
        Self {
            samples,
            capacity_frames,
            write: AtomicUsize::new(0),
            read: AtomicUsize::new(0),
            dropped: AtomicUsize::new(0),
            levels: InputLevels::new(),
        }
    }

    pub fn capacity_frames(&self) -> usize {
        self.capacity_frames
    }

    /// Callback-safe. Returns false when full; the callback remains bounded
    /// and never waits for disk or the writer thread. Levels update even when
    /// the ring is full (gain-staging still works under overflow).
    #[inline(always)]
    pub fn push_stereo(&self, left: f32, right: f32) -> bool {
        self.levels.observe_stereo(left, right);
        let w = self.write.load(Ordering::Relaxed);
        let r = self.read.load(Ordering::Acquire);
        if w.wrapping_sub(r) >= self.capacity_frames {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            return false;
        }
        let slot = (w & (self.capacity_frames - 1)) * 2;
        self.samples[slot].store(left.to_bits(), Ordering::Relaxed);
        self.samples[slot + 1].store(right.to_bits(), Ordering::Relaxed);
        self.write.store(w.wrapping_add(1), Ordering::Release);
        true
    }

    #[inline(always)]
    pub fn push_mono(&self, sample: f32) -> bool {
        self.push_stereo(sample, sample)
    }

    /// Writer-side only; allocation is intentional here.
    pub fn drain(&self, out: &mut Vec<[f32; 2]>) -> usize {
        let w = self.write.load(Ordering::Acquire);
        let r = self.read.load(Ordering::Relaxed);
        let count = w.wrapping_sub(r).min(self.capacity_frames);
        out.reserve(count);
        for i in 0..count {
            let slot = ((r.wrapping_add(i)) & (self.capacity_frames - 1)) * 2;
            out.push([
                f32::from_bits(self.samples[slot].load(Ordering::Relaxed)),
                f32::from_bits(self.samples[slot + 1].load(Ordering::Relaxed)),
            ]);
        }
        self.read.store(r.wrapping_add(count), Ordering::Release);
        count
    }

    pub fn dropped_frames(&self) -> usize {
        self.dropped.load(Ordering::Relaxed)
    }
    pub fn available(&self) -> usize {
        self.write
            .load(Ordering::Acquire)
            .wrapping_sub(self.read.load(Ordering::Relaxed))
    }

    /// Shared level atomics (peak / RMS / clip latch). Safe to read from the
    /// control side while the callback is writing.
    pub fn levels(&self) -> &InputLevels {
        &self.levels
    }
}

/// Multi-channel SPSC ring for interfaces that expose N discrete inputs
/// (Zoom AMS-44 → 4, Scarlett 18i8 → 8, …). The stereo `InputRing` above is
/// kept for legacy synthetic paths; live capture uses this so channel N can
/// land on track N without collapsing the device to L/R at the callback.
///
/// AUDIO THREAD: `push_frame` only writes atomics and advances an index. It
/// never allocates, locks, logs, or waits. Levels update even when the ring
/// is full so per-channel metering still works under overflow.
pub struct MultiChannelRing {
    samples: Box<[AtomicU32]>,
    capacity_frames: usize,
    channel_count: usize,
    write: AtomicUsize,
    read: AtomicUsize,
    dropped: AtomicUsize,
    levels: Box<[InputLevels]>,
}

impl MultiChannelRing {
    pub fn new(capacity_frames: usize, channel_count: usize) -> Self {
        let channel_count = channel_count.max(1);
        let capacity_frames = capacity_frames.max(1).next_power_of_two();
        let samples = (0..capacity_frames * channel_count)
            .map(|_| AtomicU32::new(0))
            .collect::<Vec<_>>()
            .into_boxed_slice();
        let levels = (0..channel_count)
            .map(|_| InputLevels::new())
            .collect::<Vec<_>>()
            .into_boxed_slice();
        Self {
            samples,
            capacity_frames,
            channel_count,
            write: AtomicUsize::new(0),
            read: AtomicUsize::new(0),
            dropped: AtomicUsize::new(0),
            levels,
        }
    }

    pub fn channel_count(&self) -> usize {
        self.channel_count
    }

    /// Callback-safe. `frame` length may exceed `channel_count` (extra device
    /// channels are ignored) or fall short (missing channels read as 0).
    #[inline(always)]
    pub fn push_frame(&self, frame: &[f32]) -> bool {
        for ch in 0..self.channel_count {
            let s = frame.get(ch).copied().unwrap_or(0.0);
            self.levels[ch].observe_mono(s);
        }
        let w = self.write.load(Ordering::Relaxed);
        let r = self.read.load(Ordering::Acquire);
        if w.wrapping_sub(r) >= self.capacity_frames {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            return false;
        }
        let base = (w & (self.capacity_frames - 1)) * self.channel_count;
        for ch in 0..self.channel_count {
            let s = frame.get(ch).copied().unwrap_or(0.0);
            self.samples[base + ch].store(s.to_bits(), Ordering::Relaxed);
        }
        self.write.store(w.wrapping_add(1), Ordering::Release);
        true
    }

    /// Writer-side only. Appends interleaved frames into `out` as
    /// `channel_count` samples per frame. Returns the number of frames drained.
    pub fn drain_interleaved(&self, out: &mut Vec<f32>) -> usize {
        let w = self.write.load(Ordering::Acquire);
        let r = self.read.load(Ordering::Relaxed);
        let count = w.wrapping_sub(r).min(self.capacity_frames);
        out.reserve(count * self.channel_count);
        for i in 0..count {
            let base = ((r.wrapping_add(i)) & (self.capacity_frames - 1)) * self.channel_count;
            for ch in 0..self.channel_count {
                out.push(f32::from_bits(
                    self.samples[base + ch].load(Ordering::Relaxed),
                ));
            }
        }
        self.read.store(r.wrapping_add(count), Ordering::Release);
        count
    }

    /// Extract one device channel as dual-mono stereo frames (the landing
    /// format). Control-side only; allocation is intentional.
    pub fn demux_channel_stereo(interleaved: &[f32], channel_count: usize, channel: usize) -> Vec<[f32; 2]> {
        if channel_count == 0 {
            return Vec::new();
        }
        let ch = channel.min(channel_count - 1);
        interleaved
            .chunks(channel_count)
            .map(|frame| {
                let s = frame.get(ch).copied().unwrap_or(0.0);
                [s, s]
            })
            .collect()
    }

    pub fn dropped_frames(&self) -> usize {
        self.dropped.load(Ordering::Relaxed)
    }

    pub fn available(&self) -> usize {
        self.write
            .load(Ordering::Acquire)
            .wrapping_sub(self.read.load(Ordering::Relaxed))
    }

    pub fn levels(&self, channel: usize) -> &InputLevels {
        &self.levels[channel.min(self.channel_count.saturating_sub(1))]
    }

    pub fn all_levels(&self) -> &[InputLevels] {
        &self.levels
    }

    pub fn clear_all_clips(&self) {
        for l in self.levels.iter() {
            l.clear_clip();
        }
    }

    pub fn decay_all_peaks(&self, factor: f32) {
        for l in self.levels.iter() {
            l.decay_peak(factor);
        }
    }
}

/// Synthetic multi-channel frames for routing tests: each channel carries a
/// unique DC amplitude so a swap is obvious. Channel `i` is amplitude
/// `(i + 1) * step` (default step 0.1 → 0.1, 0.2, 0.3, 0.4).
pub fn synthetic_channel_dc(frames: usize, channel_count: usize, step: f32) -> Vec<f32> {
    let mut out = Vec::with_capacity(frames * channel_count.max(1));
    let n = channel_count.max(1);
    for _ in 0..frames {
        for ch in 0..n {
            out.push((ch as f32 + 1.0) * step);
        }
    }
    out
}

/// Synthetic/offline input used by acceptance tests and headless workflows.
pub struct SyntheticInput;

impl SyntheticInput {
    pub fn sine(frames: usize, sample_rate: u32, hz: f32, amplitude: f32) -> Vec<[f32; 2]> {
        (0..frames)
            .map(|i| {
                let s = (std::f32::consts::TAU * hz * i as f32 / sample_rate as f32).sin() * amplitude;
                [s, s]
            })
            .collect()
    }

    pub fn push(ring: &InputRing, frames: &[[f32; 2]]) -> usize {
        frames
            .iter()
            .filter(|f| ring.push_stereo(f[0], f[1]))
            .count()
    }
}

/// Monitoring is opt-in and is additionally disabled unless the attended test
/// gate is present. This helper does not open either an input or output stream.
///
/// # House rule (absolute)
///
/// Live monitoring (hearing the mic through the speakers) is **never** enabled
/// by arming, recording, or any other incidental action. The double-gate here
/// is intentional: even when the UI requests monitoring, nothing is audible
/// unless `MAJIKS_TEST_AUDIBLE=1`. Production monitoring stays off until a
/// feedback-safe path exists (headphones acknowledgement + I/O device check).
/// Do not weaken this function to "make something audible".
pub fn monitoring_allowed(requested: bool) -> bool {
    requested && std::env::var("MAJIKS_TEST_AUDIBLE").as_deref() == Ok("1")
}

/// The negotiated shape of an opened input stream, handed back to the control
/// side so it can land the capture at the true device rate.
#[derive(Debug, Clone)]
pub struct InputStreamConfig {
    pub sample_rate: u32,
    pub channels: u16,
    pub device_name: String,
}

/// One enumerated input device (name + channel count + preferred rate).
/// Enumeration only; nothing is opened.
#[derive(Debug, Clone)]
pub struct InputDeviceInfo {
    pub name: String,
    pub input_channels: u16,
    pub sample_rate: u32,
}

/// Enumerate the names of the available audio INPUT devices (for a device
/// picker). This only lists devices; it never opens a stream, so it makes no
/// sound and is safe to call at any time. Returns an empty list on a headless
/// host or when enumeration fails.
pub fn list_input_devices() -> Vec<String> {
    list_input_device_info()
        .into_iter()
        .map(|d| d.name)
        .collect()
}

/// Enumerate input devices with channel counts. Safe, silent, control-side only.
pub fn list_input_device_info() -> Vec<InputDeviceInfo> {
    // CoreAudio's device-list proxy can deadlock when several host instances
    // enumerate concurrently (parallel recording tests reproduce this). This
    // is a control-side operation, never a callback, so serialize enumeration.
    static ENUM_LOCK: Mutex<()> = Mutex::new(());
    let _guard = ENUM_LOCK.lock().ok();
    match cpal::default_host().input_devices() {
        Ok(devices) => devices
            .filter_map(|d| {
                let name = d.name().ok()?;
                let cfg = d.default_input_config().ok()?;
                Some(InputDeviceInfo {
                    name,
                    input_channels: cfg.channels(),
                    sample_rate: cfg.sample_rate().0,
                })
            })
            .collect(),
        Err(_) => Vec::new(),
    }
}

/// Open an input-only CoreAudio/cpal stream into a multi-channel ring,
/// optionally on a named device (the system default input when `device_name`
/// is None or not found). Calling this is an explicit user action
/// (`record.start` or opt-in input listen) — never arming alone, never engine
/// startup. The callback only performs bounded atomic ring writes.
pub fn open_input_stream_multi(
    ring: std::sync::Arc<MultiChannelRing>,
    device_name: Option<&str>,
) -> Result<(cpal::Stream, InputStreamConfig), String> {
    let host = cpal::default_host();
    let device = match device_name {
        Some(want) => host
            .input_devices()
            .map_err(|e| format!("enumerate input devices: {e}"))?
            .find(|d| d.name().map(|n| n == want).unwrap_or(false))
            .or_else(|| host.default_input_device())
            .ok_or_else(|| "no input device available".to_string())?,
        None => host
            .default_input_device()
            .ok_or_else(|| "no input device available".to_string())?,
    };
    let resolved_name = device.name().unwrap_or_else(|_| "input".to_string());
    let supported = device
        .default_input_config()
        .map_err(|e| format!("input config: {e}"))?;
    let config: cpal::StreamConfig = supported.clone().into();
    let info = InputStreamConfig {
        sample_rate: config.sample_rate.0,
        channels: config.channels,
        device_name: resolved_name,
    };
    let channels = config.channels.max(1) as usize;
    // Ring may have been sized for fewer channels than the device reports
    // (e.g. UI asked for 4, device is stereo). push_frame pads/truncates.
    let stream = match supported.sample_format() {
        cpal::SampleFormat::F32 => device
            .build_input_stream(
                &config,
                move |data: &[f32], _| {
                    for frame in data.chunks(channels) {
                        let _ = ring.push_frame(frame);
                    }
                },
                |e| eprintln!("record input stream error: {e}"),
                None,
            )
            .map_err(|e| format!("build input stream: {e}"))?,
        cpal::SampleFormat::I16 => device
            .build_input_stream(
                &config,
                move |data: &[i16], _| {
                    // Small stack buffer: channel counts on consumer interfaces
                    // stay well under 64. No heap in the callback.
                    let mut tmp = [0.0f32; 64];
                    let n = channels.min(64);
                    for frame in data.chunks(channels) {
                        for (i, s) in frame.iter().take(n).enumerate() {
                            tmp[i] = *s as f32 / 32768.0;
                        }
                        let _ = ring.push_frame(&tmp[..n]);
                    }
                },
                |e| eprintln!("record input stream error: {e}"),
                None,
            )
            .map_err(|e| format!("build input stream: {e}"))?,
        cpal::SampleFormat::U16 => device
            .build_input_stream(
                &config,
                move |data: &[u16], _| {
                    let mut tmp = [0.0f32; 64];
                    let n = channels.min(64);
                    for frame in data.chunks(channels) {
                        for (i, s) in frame.iter().take(n).enumerate() {
                            tmp[i] = *s as f32 / 32768.0 - 1.0;
                        }
                        let _ = ring.push_frame(&tmp[..n]);
                    }
                },
                |e| eprintln!("record input stream error: {e}"),
                None,
            )
            .map_err(|e| format!("build input stream: {e}"))?,
        format => return Err(format!("unsupported input sample format: {format:?}")),
    };
    stream
        .play()
        .map_err(|e| format!("start input stream: {e}"))?;
    Ok((stream, info))
}

/// Stereo convenience path: opens the device and copies only the first two
/// channels into a stereo `InputRing`. Prefer [`open_input_stream_multi`] for
/// multi-track capture that must preserve discrete channels.
pub fn open_input_stream(
    ring: std::sync::Arc<InputRing>,
    device_name: Option<&str>,
) -> Result<(cpal::Stream, InputStreamConfig), String> {
    let host = cpal::default_host();
    let device = match device_name {
        Some(want) => host
            .input_devices()
            .map_err(|e| format!("enumerate input devices: {e}"))?
            .find(|d| d.name().map(|n| n == want).unwrap_or(false))
            .or_else(|| host.default_input_device())
            .ok_or_else(|| "no input device available".to_string())?,
        None => host
            .default_input_device()
            .ok_or_else(|| "no input device available".to_string())?,
    };
    let resolved_name = device.name().unwrap_or_else(|_| "input".to_string());
    let supported = device
        .default_input_config()
        .map_err(|e| format!("input config: {e}"))?;
    let config: cpal::StreamConfig = supported.clone().into();
    let info = InputStreamConfig {
        sample_rate: config.sample_rate.0,
        channels: config.channels,
        device_name: resolved_name,
    };
    let channels = config.channels.max(1) as usize;
    let stream = match supported.sample_format() {
        cpal::SampleFormat::F32 => device
            .build_input_stream(
                &config,
                move |data: &[f32], _| {
                    for frame in data.chunks(channels) {
                        let l = frame.first().copied().unwrap_or(0.0);
                        let r = frame.get(1).copied().unwrap_or(l);
                        let _ = ring.push_stereo(l, r);
                    }
                },
                |e| eprintln!("record input stream error: {e}"),
                None,
            )
            .map_err(|e| format!("build input stream: {e}"))?,
        cpal::SampleFormat::I16 => device
            .build_input_stream(
                &config,
                move |data: &[i16], _| {
                    for frame in data.chunks(channels) {
                        let l = frame.first().copied().unwrap_or(0) as f32 / 32768.0;
                        let r = frame.get(1).copied().unwrap_or(frame.first().copied().unwrap_or(0))
                            as f32
                            / 32768.0;
                        let _ = ring.push_stereo(l, r);
                    }
                },
                |e| eprintln!("record input stream error: {e}"),
                None,
            )
            .map_err(|e| format!("build input stream: {e}"))?,
        cpal::SampleFormat::U16 => device
            .build_input_stream(
                &config,
                move |data: &[u16], _| {
                    for frame in data.chunks(channels) {
                        let l = frame.first().copied().unwrap_or(32768) as f32 / 32768.0 - 1.0;
                        let r = frame
                            .get(1)
                            .copied()
                            .unwrap_or(frame.first().copied().unwrap_or(32768))
                            as f32
                            / 32768.0
                            - 1.0;
                        let _ = ring.push_stereo(l, r);
                    }
                },
                |e| eprintln!("record input stream error: {e}"),
                None,
            )
            .map_err(|e| format!("build input stream: {e}"))?,
        format => return Err(format!("unsupported input sample format: {format:?}")),
    };
    stream
        .play()
        .map_err(|e| format!("start input stream: {e}"))?;
    Ok((stream, info))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_round_trip_and_overflow_are_bounded() {
        let ring = InputRing::new(2);
        assert!(ring.push_stereo(0.25, -0.25));
        assert!(ring.push_mono(0.5));
        assert!(!ring.push_mono(1.0));
        let mut out = Vec::new();
        assert_eq!(ring.drain(&mut out), 2);
        assert_eq!(out, vec![[0.25, -0.25], [0.5, 0.5]]);
        assert_eq!(ring.dropped_frames(), 1);
    }

    #[test]
    fn synthetic_input_never_requires_output() {
        let ring = InputRing::new(128);
        let input = SyntheticInput::sine(64, 48_000, 440.0, 0.25);
        assert_eq!(SyntheticInput::push(&ring, &input), 64);
        assert!(!monitoring_allowed(true));
    }

    #[test]
    fn input_levels_track_peak_rms_and_latch_clip() {
        let levels = InputLevels::new();
        levels.observe_stereo(0.5, -0.25);
        assert!((levels.peak() - 0.5).abs() < 1e-6);
        assert!(levels.rms() > 0.0);
        assert!(!levels.clip_latched());

        // Transient over: latch must survive later quiet frames.
        levels.observe_stereo(1.2, 0.0);
        assert!(levels.clip_latched());
        levels.observe_stereo(0.01, 0.01);
        assert!(levels.clip_latched(), "clip latch must not clear on quiet frames");
        levels.clear_clip();
        assert!(!levels.clip_latched());
    }

    #[test]
    fn ring_push_updates_levels_even_when_full() {
        let ring = InputRing::new(1);
        assert!(ring.push_stereo(0.1, 0.1));
        assert!(!ring.push_stereo(0.9, 0.9)); // full — drop, but levels still update
        assert!((ring.levels().peak() - 0.9).abs() < 1e-6);
        assert_eq!(ring.dropped_frames(), 1);
    }

    #[test]
    fn multi_channel_ring_preserves_channel_identity() {
        // Four distinguishable DCs: channel i carries (i+1)*0.1. A demux that
        // hardcodes channel 0 or swaps two channels fails this by construction.
        let ring = MultiChannelRing::new(8, 4);
        let frame = [0.1f32, 0.2, 0.3, 0.4];
        for _ in 0..4 {
            assert!(ring.push_frame(&frame));
        }
        let mut interleaved = Vec::new();
        assert_eq!(ring.drain_interleaved(&mut interleaved), 4);
        for ch in 0..4 {
            let stereo = MultiChannelRing::demux_channel_stereo(&interleaved, 4, ch);
            assert_eq!(stereo.len(), 4);
            let expected = (ch as f32 + 1.0) * 0.1;
            for s in &stereo {
                assert!((s[0] - expected).abs() < 1e-6, "ch {ch} left");
                assert!((s[1] - expected).abs() < 1e-6, "ch {ch} right");
            }
            assert!((ring.levels(ch).peak() - expected).abs() < 1e-6);
        }
    }

    #[test]
    fn synthetic_channel_dc_is_distinguishable_per_channel() {
        let interleaved = synthetic_channel_dc(16, 4, 0.1);
        for ch in 0..4 {
            let stereo = MultiChannelRing::demux_channel_stereo(&interleaved, 4, ch);
            let expected = (ch as f32 + 1.0) * 0.1;
            assert!(stereo.iter().all(|s| (s[0] - expected).abs() < 1e-6));
        }
    }
}
