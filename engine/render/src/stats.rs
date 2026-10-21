//! Engine stats: atomics written by the render side (relaxed, once per
//! block), snapshotted by control surfaces. The DJ RealtimeEngineStats
//! pattern, extended with callback duration and deadline accounting, strip
//! meters, master true-peak/limiter telemetry, and loudness slots the meter
//! thread publishes into.

use std::sync::atomic::{AtomicU32, AtomicU64, AtomicU8, Ordering};

use serde::Serialize;

/// Histogram bucket width for callback duration, in nanoseconds (100 us).
pub const HIST_BUCKET_NS: u64 = 100_000;
pub const HIST_BUCKETS: usize = 32;

/// E5 §8: meter slots for the routing graph — every explicit node plus the two
/// render-side-only `LegacyFx` returns.
pub const NODE_METER_SLOTS: usize = crate::params::MAX_ROUTE_NODES + 2;
/// Meter slot of the legacy Freeverb return.
pub const LEGACY_FX_A_METER: usize = crate::params::MAX_ROUTE_NODES;
/// Meter slot of the legacy tempo-delay return.
pub const LEGACY_FX_B_METER: usize = crate::params::MAX_ROUTE_NODES + 1;

#[derive(Debug, Default)]
pub struct EngineStats {
    pub callbacks: AtomicU64,
    /// Render faults: a playing session asked for audio that was not
    /// resident (out-of-bounds source read). Must stay 0.
    pub underruns: AtomicU64,
    /// Callback wall time exceeded the block's real-time budget.
    pub deadline_misses: AtomicU64,
    /// Control-side try_send failures on the command channel.
    pub command_overruns: AtomicU64,
    /// Buffers leaked because the drop channel was full (callback never
    /// frees; it forgets and counts).
    pub leaked_buffers: AtomicU64,
    /// cpal stream error callbacks.
    pub stream_errors: AtomicU64,
    /// Meter-tap frames dropped because the meter ring was full.
    pub meter_drops: AtomicU64,
    /// Output stream (re)starts: device-switch survival telemetry.
    pub stream_generation: AtomicU32,
    /// THE CLICK COUNTER. Metronome clicks the render core has TRIGGERED —
    /// grid beats plus count-in beats, both of which fire the same voice.
    ///
    /// The click is deliberately excluded from `master`, the meters, the
    /// true-peak detector and the capture tap (see the monitor block in
    /// `RenderCore::render`), which is exactly what makes a take click-free —
    /// and exactly what leaves a human ear as the ONLY oracle for whether the
    /// thing is running. This counter is the one observable signal on that
    /// path, so "I hear one chirp and then silence" can be split into "the
    /// core is producing clicks" and "the core's output is reaching the
    /// speakers" without asking anyone to listen.
    ///
    /// Written from inside `if self.cfg.monitor`, so an offline bounce cannot
    /// move it: the counter is as inert offline as the click itself.
    pub metronome_clicks: AtomicU64,
    /// Frames the DEVICE callback actually copied out of the render buffer.
    ///
    /// `frames_rendered` counts what the CORE produced; this counts what the
    /// output callback wrote to the device. They diverge only when the silence
    /// gate is closed (`EngineConfig::audible` false), which is the one thing
    /// that can make a perfectly-rendered click inaudible with every other
    /// signal green. One relaxed add per callback, beside the callback's
    /// existing stats writes — not per frame.
    pub device_frames_audible: AtomicU64,
    pub callback_ns_max: AtomicU64,
    pub callback_ns_sum: AtomicU64,
    pub frames_rendered: AtomicU64,
    pub hist: [AtomicU64; HIST_BUCKETS],
    pub position_frame: AtomicU64,
    pub playing: AtomicU8,
    pub device_sample_rate: AtomicU32,
    pub actual_buffer_frames: AtomicU32,
}

impl EngineStats {
    pub fn new() -> Self {
        Self::default()
    }

    /// Called once per rendered block from the render thread.
    pub fn record_block(&self, frames: usize, elapsed_ns: u64, budget_ns: u64) {
        self.callbacks.fetch_add(1, Ordering::Relaxed);
        self.frames_rendered.fetch_add(frames as u64, Ordering::Relaxed);
        self.callback_ns_sum.fetch_add(elapsed_ns, Ordering::Relaxed);
        self.callback_ns_max.fetch_max(elapsed_ns, Ordering::Relaxed);
        let bucket = ((elapsed_ns / HIST_BUCKET_NS) as usize).min(HIST_BUCKETS - 1);
        self.hist[bucket].fetch_add(1, Ordering::Relaxed);
        if budget_ns > 0 && elapsed_ns > budget_ns {
            self.deadline_misses.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub fn snapshot(&self) -> StatsSnapshot {
        let callbacks = self.callbacks.load(Ordering::Relaxed);
        let sum = self.callback_ns_sum.load(Ordering::Relaxed);
        let hist: Vec<u64> = self.hist.iter().map(|b| b.load(Ordering::Relaxed)).collect();
        StatsSnapshot {
            callbacks,
            underruns: self.underruns.load(Ordering::Relaxed),
            deadline_misses: self.deadline_misses.load(Ordering::Relaxed),
            command_overruns: self.command_overruns.load(Ordering::Relaxed),
            leaked_buffers: self.leaked_buffers.load(Ordering::Relaxed),
            stream_errors: self.stream_errors.load(Ordering::Relaxed),
            meter_drops: self.meter_drops.load(Ordering::Relaxed),
            stream_generation: self.stream_generation.load(Ordering::Relaxed),
            metronome_clicks: self.metronome_clicks.load(Ordering::Relaxed),
            device_frames_audible: self.device_frames_audible.load(Ordering::Relaxed),
            alloc_violations: crate::guard::violations(),
            callback_ns_max: self.callback_ns_max.load(Ordering::Relaxed),
            callback_ns_mean: if callbacks > 0 { sum / callbacks } else { 0 },
            callback_ns_p95: percentile_from_hist(&hist, callbacks, 0.95),
            frames_rendered: self.frames_rendered.load(Ordering::Relaxed),
            position_frame: self.position_frame.load(Ordering::Relaxed),
            playing: self.playing.load(Ordering::Relaxed) != 0,
            device_sample_rate: self.device_sample_rate.load(Ordering::Relaxed),
            actual_buffer_frames: self.actual_buffer_frames.load(Ordering::Relaxed),
        }
    }
}

/// Upper edge of the bucket containing the requested percentile.
fn percentile_from_hist(hist: &[u64], total: u64, p: f64) -> u64 {
    if total == 0 {
        return 0;
    }
    let threshold = (total as f64 * p).ceil() as u64;
    let mut seen = 0_u64;
    for (idx, count) in hist.iter().enumerate() {
        seen += count;
        if seen >= threshold {
            return (idx as u64 + 1) * HIST_BUCKET_NS;
        }
    }
    (hist.len() as u64) * HIST_BUCKET_NS
}

#[derive(Debug, Clone, Serialize)]
pub struct StatsSnapshot {
    pub callbacks: u64,
    pub underruns: u64,
    pub deadline_misses: u64,
    pub command_overruns: u64,
    pub leaked_buffers: u64,
    pub stream_errors: u64,
    pub meter_drops: u64,
    pub stream_generation: u32,
    /// Metronome clicks triggered on the monitor path (grid + count-in). Zero
    /// on every offline render, by construction.
    pub metronome_clicks: u64,
    /// Frames the device callback copied out of the render buffer. Zero while
    /// the silence gate is closed, however busy the core is.
    pub device_frames_audible: u64,
    pub alloc_violations: u64,
    pub callback_ns_max: u64,
    pub callback_ns_mean: u64,
    /// Upper bucket edge estimate (100 us resolution).
    pub callback_ns_p95: u64,
    pub frames_rendered: u64,
    pub position_frame: u64,
    pub playing: bool,
    pub device_sample_rate: u32,
    pub actual_buffer_frames: u32,
}

// ---------------------------------------------------------------------------
// Meters
// ---------------------------------------------------------------------------

/// Positive-float atomic max: IEEE positive floats order like their bit
/// patterns, so fetch_max on the bits is a lock-free running peak.
#[derive(Debug, Default)]
struct PeakSlot(AtomicU32);

impl PeakSlot {
    #[inline]
    fn update(&self, v: f32) {
        self.0.fetch_max(v.max(0.0).to_bits(), Ordering::Relaxed);
    }

    /// Read and reset (control side, per meter poll).
    fn take(&self) -> f32 {
        f32::from_bits(self.0.swap(0, Ordering::Relaxed))
    }

    fn read(&self) -> f32 {
        f32::from_bits(self.0.load(Ordering::Relaxed))
    }
}

#[derive(Debug, Default)]
struct TrackMeterAtomic {
    peak_l: PeakSlot,
    peak_r: PeakSlot,
    /// RMS of the most recent block (store, not accumulate: UI ballistics
    /// live control-side).
    block_rms: AtomicU32,
}

/// Meter spine written from the render thread with relaxed atomics: per
/// strip post-EQ peak + block RMS, master peak/RMS, master input/output
/// true-peak and limiter gain reduction, and LUFS slots that the meter
/// thread (control side, fed by the meter ring) publishes into.
#[derive(Debug)]
pub struct MeterBank {
    tracks: Box<[TrackMeterAtomic]>,
    /// E5 §8: one meter slot per routing node, PLUS the two render-side-only
    /// `LegacyFx` nodes, so the reverb and delay returns finally meter. Sized
    /// `MAX_ROUTE_NODES + 2` and preallocated with everything else — a bus
    /// fader with no meter is what E5-ui would otherwise have to ship.
    ///
    /// Written by the `Node` / `LegacyReturns` steps exactly where
    /// `strip.meter_frame` is written for a track, and flushed once per block
    /// through the existing block epilogue. **Never a per-frame atomic write**:
    /// accumulation is block-local on `RenderCore`, the same pattern
    /// `Strip::take_block_meters` uses.
    nodes: Box<[TrackMeterAtomic]>,
    master_peak_l: PeakSlot,
    master_peak_r: PeakSlot,
    master_block_rms: AtomicU32,
    master_true_peak: PeakSlot,
    limiter_input_tp: PeakSlot,
    /// Max gain reduction (stored as POSITIVE dB reduction) since last take.
    limiter_gr_db: PeakSlot,
    /// LUFS published by the meter thread (bits of f32; NaN until known).
    lufs_integrated: AtomicU32,
    lufs_short_term: AtomicU32,
    /// Latest-block master stereo correlation (bits of f32; NaN when silent or
    /// not yet computed). Signed [-1, 1], so it is a store, not a peak slot.
    master_correlation: AtomicU32,
}

impl MeterBank {
    pub fn new(max_tracks: usize) -> Self {
        Self {
            tracks: (0..max_tracks).map(|_| TrackMeterAtomic::default()).collect(),
            nodes: (0..NODE_METER_SLOTS)
                .map(|_| TrackMeterAtomic::default())
                .collect(),
            master_peak_l: PeakSlot::default(),
            master_peak_r: PeakSlot::default(),
            master_block_rms: AtomicU32::new(0),
            master_true_peak: PeakSlot::default(),
            limiter_input_tp: PeakSlot::default(),
            limiter_gr_db: PeakSlot::default(),
            lufs_integrated: AtomicU32::new(f32::NAN.to_bits()),
            lufs_short_term: AtomicU32::new(f32::NAN.to_bits()),
            master_correlation: AtomicU32::new(f32::NAN.to_bits()),
        }
    }

    // ---- render side ----

    #[inline]
    pub fn track_frame(&self, track: usize, l: f32, r: f32) {
        if let Some(t) = self.tracks.get(track) {
            t.peak_l.update(l.abs());
            t.peak_r.update(r.abs());
        }
    }

    #[inline]
    pub fn track_block_rms(&self, track: usize, rms: f32) {
        if let Some(t) = self.tracks.get(track) {
            t.block_rms.store(rms.to_bits(), Ordering::Relaxed);
        }
    }

    /// Flush ONE routing node's block meters (§8). `node` is
    /// `0..MAX_ROUTE_NODES` for an explicit node, then `LEGACY_FX_A_METER` /
    /// `LEGACY_FX_B_METER`.
    #[inline]
    pub fn node_block(&self, node: usize, peak_l: f32, peak_r: f32, rms: f32) {
        if let Some(n) = self.nodes.get(node) {
            n.peak_l.update(peak_l.abs());
            n.peak_r.update(peak_r.abs());
            n.block_rms.store(rms.to_bits(), Ordering::Relaxed);
        }
    }

    #[inline]
    pub fn master_frame(&self, l: f32, r: f32) {
        self.master_peak_l.update(l.abs());
        self.master_peak_r.update(r.abs());
    }

    #[inline]
    pub fn master_block(&self, rms: f32, true_peak: f32, limiter_in_tp: f32, gr_db: f32, corr: f32) {
        self.master_block_rms.store(rms.to_bits(), Ordering::Relaxed);
        self.master_true_peak.update(true_peak);
        self.limiter_input_tp.update(limiter_in_tp);
        self.limiter_gr_db.update(gr_db);
        self.master_correlation
            .store(corr.to_bits(), Ordering::Relaxed);
    }

    // ---- meter thread ----

    pub fn publish_lufs(&self, integrated: f32, short_term: f32) {
        self.lufs_integrated.store(integrated.to_bits(), Ordering::Relaxed);
        self.lufs_short_term.store(short_term.to_bits(), Ordering::Relaxed);
    }

    // ---- control side ----

    /// Peak read-and-reset + latest block RMS for every strip and the
    /// master section.
    pub fn snapshot(&self, track_count: usize) -> MeterSnapshot {
        let tracks = self
            .tracks
            .iter()
            .take(track_count.min(self.tracks.len()))
            .map(|t| TrackMeter {
                peak_l: t.peak_l.take(),
                peak_r: t.peak_r.take(),
                block_rms: f32::from_bits(t.block_rms.load(Ordering::Relaxed)),
            })
            .collect();
        MeterSnapshot {
            tracks,
            master_peak_l: self.master_peak_l.take(),
            master_peak_r: self.master_peak_r.take(),
            master_block_rms: f32::from_bits(self.master_block_rms.load(Ordering::Relaxed)),
            master_true_peak: self.master_true_peak.take(),
            limiter_input_tp: self.limiter_input_tp.take(),
            limiter_gr_db: self.limiter_gr_db.take(),
            lufs_integrated: f32::from_bits(self.lufs_integrated.load(Ordering::Relaxed)),
            lufs_short_term: f32::from_bits(self.lufs_short_term.load(Ordering::Relaxed)),
            master_correlation: f32::from_bits(self.master_correlation.load(Ordering::Relaxed)),
        }
    }

    /// Peak read-and-reset + latest block RMS for the first `count` routing
    /// node meter slots (§8). The accessor signature is the one E5-params and
    /// E5-graph agreed before either started; §23.3 then moved the whole file
    /// to E5-graph so the writer and the field land together.
    ///
    /// `count` is clamped to the bank, so a caller that asks for
    /// `MAX_ROUTE_NODES + 2` always gets the legacy reverb/delay returns as
    /// the last two entries.
    pub fn node_meters(&self, count: usize) -> Vec<(f32, f32, f32)> {
        self.nodes
            .iter()
            .take(count.min(self.nodes.len()))
            .map(|n| {
                (
                    n.peak_l.take(),
                    n.peak_r.take(),
                    f32::from_bits(n.block_rms.load(Ordering::Relaxed)),
                )
            })
            .collect()
    }

    /// Non-destructive master true-peak read (tests).
    pub fn master_true_peak_hold(&self) -> f32 {
        self.master_true_peak.read()
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct TrackMeter {
    pub peak_l: f32,
    pub peak_r: f32,
    pub block_rms: f32,
}

#[derive(Debug, Clone, Serialize)]
pub struct MeterSnapshot {
    pub tracks: Vec<TrackMeter>,
    pub master_peak_l: f32,
    pub master_peak_r: f32,
    pub master_block_rms: f32,
    pub master_true_peak: f32,
    pub limiter_input_tp: f32,
    pub limiter_gr_db: f32,
    pub lufs_integrated: f32,
    pub lufs_short_term: f32,
    /// Master stereo correlation over the most recent block, [-1, 1] (NaN when
    /// silent). +1 is a mono/centered mix, 0 is fully decorrelated, negative is
    /// out-of-phase (a mono-fold cancellation risk the master strip warns on).
    pub master_correlation: f32,
}
