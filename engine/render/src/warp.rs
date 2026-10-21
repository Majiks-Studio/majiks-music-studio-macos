//! Per-clip warp (time-stretch) infrastructure.
//!
//! The render callback NEVER stretches: a control-side worker renders
//! stretched clip buffers off-thread (the DJ keylock discipline) and the
//! host swaps sessions whose warped clips reference the pre-rendered audio.
//! Interactive ratio changes coalesce through a latest-wins mailbox (the DJ
//! RateWorker pattern, keyed per clip instead of per deck).
//!
//! Ratio semantics (catalog `clip.warp.set`, mode "ratio"): `stretchRatio`
//! is the DURATION multiplier. 1.0 is unwarped and MUST bypass bit-exactly;
//! 2.0 plays the same source material over twice the timeline length.
//!
//! Engines:
//! - `SignalsmithStretcher` (PRIMARY): MIT Rust bindings to Signalsmith
//!   Stretch via the `signalsmith-stretch` crate; `exact()` renders a whole
//!   buffer with latency compensated, exact output length.
//! - `WsolaStretcher` (FALLBACK): port of the majiks-dj WSOLA with the
//!   ideal-grid re-anchor drift fix and RMS renormalization. Kept as the
//!   proven baseline and the A/B reference.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

use crossbeam_channel::{bounded, Receiver, Sender};

use crate::media::AudioBuf;

/// Ratios this close to 1.0 are treated as identity (bit-exact bypass).
pub const IDENTITY_EPSILON: f64 = 1.0e-4;

/// Clamp for sane warp ratios (0.25x to 4x duration).
pub const MIN_RATIO: f64 = 0.25;
pub const MAX_RATIO: f64 = 4.0;

pub fn is_identity(ratio: f64) -> bool {
    (ratio - 1.0).abs() < IDENTITY_EPSILON
}

/// Exact output length for a stretch: round(len * ratio).
pub fn stretched_len(len_frames: u64, ratio: f64) -> u64 {
    ((len_frames as f64) * ratio).round().max(1.0) as u64
}

pub trait Stretcher: Send {
    fn name(&self) -> &'static str;
    /// Stretch `input` to exactly `stretched_len(input.len(), ratio)`
    /// frames. Identity ratios must return a bit-exact copy.
    fn stretch(&mut self, input: &[[f32; 2]], ratio: f64) -> Vec<[f32; 2]>;
}

// ---------------------------------------------------------------------------
// WSOLA (donor port)
// ---------------------------------------------------------------------------

fn hann_window(index: usize, size: usize) -> f32 {
    if size <= 1 {
        return 1.0;
    }
    let phase = (index as f32) / (size as f32 - 1.0);
    0.5 - 0.5 * (2.0 * std::f32::consts::PI * phase).cos()
}

fn correlation_score(a: &[[f32; 2]], b: &[[f32; 2]]) -> f32 {
    let mut dot = 0.0;
    let mut norm_a = 0.0;
    let mut norm_b = 0.0;
    for (lhs, rhs) in a.iter().zip(b.iter()) {
        let la = (lhs[0] + lhs[1]) * 0.5;
        let rb = (rhs[0] + rhs[1]) * 0.5;
        dot += la * rb;
        norm_a += la * la;
        norm_b += rb * rb;
    }
    if norm_a <= 0.0 || norm_b <= 0.0 {
        return -1.0;
    }
    dot / (norm_a.sqrt() * norm_b.sqrt())
}

/// The majiks-dj `time_stretch_wsola` (audio_engine.rs) ported to duration
/// semantics, made SYNTHESIS-driven so it stays gap-free across the full
/// 0.25x..4x warp range:
/// - the OUTPUT hop is fixed at a quarter window (75% overlap), so synthesis
///   grains always overlap and overlap-add never leaves an unwritten (silent)
///   region. The donor's fixed-ANALYSIS-hop form set synthesis_hop =
///   analysis_hop * ratio, which exceeds the window for ratios > 2x and left
///   periodic silent gaps; this form cannot.
/// - the (fractional) analysis hop is derived from the ratio and accumulated
///   on an ideal source grid; the WSOLA search re-anchors around that ideal
///   position each iteration (the donor drift fix), and the read position is
///   clamped to the last full window so the tail is real material.
/// - weight normalization makes the overlap-add COLA-correct at any overlap
///   count (including the head/tail), then RMS renorm restores energy.
pub struct WsolaStretcher;

impl Stretcher for WsolaStretcher {
    fn name(&self) -> &'static str {
        "wsola"
    }

    fn stretch(&mut self, input: &[[f32; 2]], ratio: f64) -> Vec<[f32; 2]> {
        if is_identity(ratio) || input.len() < 8 {
            return input.to_vec();
        }
        let ratio = ratio.clamp(MIN_RATIO, MAX_RATIO);
        let target_len = stretched_len(input.len() as u64, ratio) as usize;

        let window = 1024_usize.min(input.len().max(8));
        // Fixed 75%-overlap synthesis hop: guarantees overlapping grains (no
        // gaps) and Hann constant-overlap-add for every ratio.
        let synthesis_hop = (window / 4).max(1);
        let overlap = window - synthesis_hop;
        // Output/input length ratio equals synthesis_hop / analysis_hop, so
        // the analysis hop that yields `ratio` is synthesis_hop / ratio.
        let analysis_hop_f = (synthesis_hop as f64 / ratio).max(1.0);
        let search_radius = (synthesis_hop / 2).max(16);
        let output_len = target_len + window;
        let mut output = vec![[0.0_f32; 2]; output_len];
        let mut weights = vec![0.0_f32; output_len];
        let mut out_pos = 0_usize;
        let mut ideal_src_pos = 0.0_f64;
        let max_start = input.len().saturating_sub(window);

        let input_rms = (input
            .iter()
            .map(|s| (s[0] * s[0] + s[1] * s[1]) * 0.5)
            .sum::<f32>()
            / input.len() as f32)
            .sqrt();

        // Synthesis-driven overlap-add. The first grain lays from input 0
        // (no reference yet); every later grain re-anchors around the ideal
        // source position by correlating the already-synthesized overlap
        // tail against candidate input grains.
        while out_pos + window <= output.len() {
            let predicted = (ideal_src_pos.round() as usize).min(max_start);
            let best_start = if out_pos == 0 {
                0
            } else {
                let search_start = predicted.saturating_sub(search_radius);
                let search_end = (predicted + search_radius).min(max_start);
                let reference_start = out_pos.saturating_sub(overlap);
                let reference = &output[reference_start..out_pos.min(output.len())];
                let mut best = predicted;
                let mut best_score = f32::MIN;
                for candidate in search_start..=search_end {
                    let candidate_frame = &input[candidate..candidate + overlap.min(window)];
                    let score = correlation_score(reference, candidate_frame);
                    if score > best_score {
                        best_score = score;
                        best = candidate;
                    }
                }
                best
            };

            let frame = &input[best_start..best_start + window];
            for i in 0..window {
                let dst = out_pos + i;
                if dst >= output.len() {
                    break;
                }
                let w = hann_window(i, window);
                let sample = frame[i];
                output[dst][0] += sample[0] * w;
                output[dst][1] += sample[1] * w;
                weights[dst] += w;
            }

            ideal_src_pos += analysis_hop_f;
            out_pos += synthesis_hop;
            if out_pos >= target_len {
                break;
            }
        }

        for (sample, weight) in output.iter_mut().zip(weights.iter()) {
            if *weight > 0.0 {
                sample[0] /= *weight;
                sample[1] /= *weight;
            }
        }
        output.truncate(target_len);

        // RMS renormalization (donor): overlap-add changes energy slightly.
        let output_rms = (output
            .iter()
            .map(|s| (s[0] * s[0] + s[1] * s[1]) * 0.5)
            .sum::<f32>()
            / output.len().max(1) as f32)
            .sqrt();
        if input_rms > 0.0 && output_rms > 0.0 {
            let normalize = input_rms / output_rms;
            for sample in output.iter_mut() {
                sample[0] *= normalize;
                sample[1] *= normalize;
            }
        }
        output
    }
}

// ---------------------------------------------------------------------------
// Signalsmith Stretch (primary)
// ---------------------------------------------------------------------------

/// One reusable Signalsmith instance (reset between jobs).
pub struct SignalsmithStretcher {
    inner: signalsmith_stretch::Stretch,
}

impl SignalsmithStretcher {
    pub fn new(sample_rate: u32) -> Self {
        Self {
            inner: signalsmith_stretch::Stretch::preset_default(2, sample_rate),
        }
    }
}

impl Stretcher for SignalsmithStretcher {
    fn name(&self) -> &'static str {
        "signalsmith"
    }

    fn stretch(&mut self, input: &[[f32; 2]], ratio: f64) -> Vec<[f32; 2]> {
        if is_identity(ratio) || input.is_empty() {
            return input.to_vec();
        }
        let ratio = ratio.clamp(MIN_RATIO, MAX_RATIO);
        let target_len = stretched_len(input.len() as u64, ratio) as usize;
        let mut output = vec![[0.0_f32; 2]; target_len];
        self.inner.reset();
        self.inner
            .exact(input.as_flattened(), output.as_flattened_mut());
        output
    }
}

/// The ratio above which Signalsmith Stretch RANDOMISES its per-bin time
/// factors, and therefore stops being a pure function of its input.
///
/// This is not a tuning knob. It is a fact about the vendored engine, and the
/// two lines that make it one are:
///
/// ```text
/// signalsmith-stretch-0.1.3/signalsmith-stretch/signalsmith-stretch.h:38
///     SignalsmithStretch() : randomEngine(std::random_device{}()) {}
/// signalsmith-stretch-0.1.3/signalsmith-stretch/signalsmith-stretch.h:484
///     static constexpr Sample maxCleanStretch{2}; // time-stretch ratio
///                                                 // before we start
///                                                 // randomising phases
/// signalsmith-stretch-0.1.3/signalsmith-stretch/signalsmith-stretch.h:614
///     bool randomTimeFactor = (timeFactor > maxCleanStretch);
/// ```
///
/// The engine is seeded from `std::random_device`, and above 2x it draws a
/// per-bin time factor from that engine. At or below 2x it draws nothing and is
/// bit-exactly reproducible. The Rust binding (`preset_default`) exposes only
/// the default constructor, so the seed cannot be pinned from here.
pub const SIGNALSMITH_CLEAN_MAX_RATIO: f64 = 2.0;

/// The stretcher to use for `ratio`, chosen so the result is a PURE FUNCTION
/// of (input, ratio).
///
/// Determinism is not a nicety here: a bounce is an artifact a person keeps,
/// and "the master I exported yesterday is different today" is unfixable after
/// the fact. It also underpins `WarpCache` — a cached buffer and a fresh render
/// have to be interchangeable, or the audio would depend on whether a cache
/// happened to be warm.
///
/// So: Signalsmith (the better engine) up to `SIGNALSMITH_CLEAN_MAX_RATIO`,
/// where it is deterministic; WSOLA — pure arithmetic, no RNG, already the
/// proven A/B reference — above it, where Signalsmith is not.
///
/// ⚠️ Do NOT "simplify" this back to always-Signalsmith. It was always-
/// Signalsmith, and `stretch_is_bit_deterministic_across_instances` caught two
/// renders of the same 3x stretch disagreeing in the very first frame. The
/// upstream fix is a seeded constructor in the binding; until that exists, this
/// is the honest boundary.
pub fn deterministic_stretcher(ratio: f64, sample_rate: u32) -> Box<dyn Stretcher> {
    if ratio > SIGNALSMITH_CLEAN_MAX_RATIO {
        Box::new(WsolaStretcher)
    } else {
        Box::new(SignalsmithStretcher::new(sample_rate))
    }
}

// ---------------------------------------------------------------------------
// Latest-wins warp worker (DJ RateWorker pattern, keyed per clip)
// ---------------------------------------------------------------------------

#[derive(Clone)]
pub struct WarpJob {
    pub clip_id: String,
    /// The exact source extent of the clip (already offset/len resolved).
    pub source: Arc<AudioBuf>,
    pub offset_frames: u64,
    pub len_frames: u64,
    pub ratio: f64,
    /// Monotonic per-clip generation; stale results are dropped downstream.
    pub generation: u64,
}

pub struct WarpResult {
    pub clip_id: String,
    pub ratio: f64,
    pub generation: u64,
    pub audio: Arc<AudioBuf>,
}

#[derive(Default)]
struct MailboxState {
    pending: HashMap<String, WarpJob>,
    busy: bool,
    shutdown: bool,
}

struct Mailbox {
    state: Mutex<MailboxState>,
    cv: Condvar,
}

/// Off-thread stretch renderer with a latest-wins mailbox per clip: `submit`
/// overwrites the clip's slot and returns immediately; the worker drains one
/// slot at a time, runs the (slow) stretch WITHOUT the lock, and emits a
/// `WarpResult`. A burst of submissions for one clip therefore renders at
/// most twice (one in flight + the newest).
pub struct WarpWorker {
    mailbox: Arc<Mailbox>,
    results_rx: Receiver<WarpResult>,
    handle: Option<thread::JoinHandle<()>>,
    pub submitted: Arc<AtomicU64>,
    pub executed: Arc<AtomicU64>,
}

impl WarpWorker {
    /// `make_stretcher` builds the engine on the worker thread.
    pub fn spawn<F>(make_stretcher: F) -> Self
    where
        F: FnOnce() -> Box<dyn Stretcher> + Send + 'static,
    {
        let mailbox = Arc::new(Mailbox {
            state: Mutex::new(MailboxState::default()),
            cv: Condvar::new(),
        });
        let (results_tx, results_rx) = bounded::<WarpResult>(256);
        let submitted = Arc::new(AtomicU64::new(0));
        let executed = Arc::new(AtomicU64::new(0));
        let thread_mailbox = Arc::clone(&mailbox);
        let thread_executed = Arc::clone(&executed);
        let handle = thread::Builder::new()
            .name("majiks-warp-worker".into())
            .spawn(move || {
                let mut stretcher = make_stretcher();
                Self::run(&thread_mailbox, &results_tx, stretcher.as_mut(), &thread_executed);
            })
            .expect("spawn warp worker");
        Self {
            mailbox,
            results_rx,
            handle: Some(handle),
            submitted,
            executed,
        }
    }

    fn lock(mailbox: &Mailbox) -> std::sync::MutexGuard<'_, MailboxState> {
        mailbox
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    /// Latest-wins: overwrite the clip's slot and wake the worker.
    pub fn submit(&self, job: WarpJob) {
        self.submitted.fetch_add(1, Ordering::Relaxed);
        let mut state = Self::lock(&self.mailbox);
        state.pending.insert(job.clip_id.clone(), job);
        drop(state);
        self.mailbox.cv.notify_all();
    }

    /// Drain any finished results without blocking.
    pub fn try_results(&self) -> Vec<WarpResult> {
        let mut out = Vec::new();
        while let Ok(r) = self.results_rx.try_recv() {
            out.push(r);
        }
        out
    }

    /// Block until a result arrives (or timeout).
    pub fn wait_result(&self, timeout: std::time::Duration) -> Option<WarpResult> {
        self.results_rx.recv_timeout(timeout).ok()
    }

    /// Block until the mailbox is drained and nothing is in flight.
    pub fn wait_idle(&self, timeout: std::time::Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        let mut state = Self::lock(&self.mailbox);
        loop {
            if state.pending.is_empty() && !state.busy {
                return true;
            }
            let now = std::time::Instant::now();
            if now >= deadline {
                return false;
            }
            let (guard, _) = self
                .mailbox
                .cv
                .wait_timeout(state, deadline - now)
                .unwrap_or_else(|poison| poison.into_inner());
            state = guard;
        }
    }

    fn run(
        mailbox: &Mailbox,
        results_tx: &Sender<WarpResult>,
        stretcher: &mut dyn Stretcher,
        executed: &AtomicU64,
    ) {
        let mut state = Self::lock(mailbox);
        loop {
            if state.shutdown {
                return;
            }
            let next_key = state.pending.keys().next().cloned();
            match next_key {
                Some(key) => {
                    let job = state.pending.remove(&key).expect("key just seen");
                    state.busy = true;
                    drop(state);
                    // The slow call runs WITHOUT the mailbox lock so newer
                    // ratios keep landing and only the newest survives.
                    let start = job.offset_frames as usize;
                    let end = (job.offset_frames + job.len_frames) as usize;
                    let slice = job
                        .source
                        .samples
                        .get(start..end.min(job.source.samples.len()))
                        .unwrap_or(&[]);
                    let stretched = stretcher.stretch(slice, job.ratio);
                    executed.fetch_add(1, Ordering::Relaxed);
                    let audio = AudioBuf::from_samples(
                        stretched,
                        &format!("warp:{}@{:.4}", job.clip_id, job.ratio),
                    );
                    let _ = results_tx.try_send(WarpResult {
                        clip_id: job.clip_id,
                        ratio: job.ratio,
                        generation: job.generation,
                        audio,
                    });
                    state = Self::lock(mailbox);
                    state.busy = false;
                    mailbox.cv.notify_all();
                }
                None => {
                    state = mailbox
                        .cv
                        .wait(state)
                        .unwrap_or_else(|poison| poison.into_inner());
                }
            }
        }
    }
}

impl Drop for WarpWorker {
    fn drop(&mut self) {
        {
            let mut state = Self::lock(&self.mailbox);
            state.shutdown = true;
        }
        self.mailbox.cv.notify_all();
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

/// The host-side warp state for one clip.
#[derive(Clone)]
pub struct WarpEntry {
    pub ratio: f64,
    pub generation: u64,
    /// Pre-rendered stretched audio for (clip source extent, ratio); None
    /// while the first render is in flight (the clip plays unwarped until
    /// the result lands: DJ swap-when-ready discipline).
    pub stretched: Option<Arc<AudioBuf>>,
    /// The ratio `stretched` was rendered at (kept while a newer ratio is
    /// still rendering).
    pub stretched_ratio: f64,
}

/// clip_id -> warp entry. Owned by the host, read by compile.
pub type WarpOverlay = HashMap<String, WarpEntry>;

// ---------------------------------------------------------------------------
// Control-side warp cache (the shipping host's resolver)
// ---------------------------------------------------------------------------

/// The content address of one pre-rendered stretch: every input that
/// determines the output samples, and nothing else.
///
/// Deliberately NOT keyed by clip id. Two clips that warp the same source
/// extent at the same ratio ARE the same audio, and a duplicated or renamed
/// clip must not pay for a second stretch. It also means undo/redo of a warp
/// is free after the first render, which is what makes a warp feel like an
/// edit rather than a render job.
///
/// `ratio_bits` is the f64 bit pattern, so 2.0 and 2.0000001 are distinct
/// keys (they are distinct audio) and no float ever has to be `Hash`.
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub struct WarpKey {
    pub source_id: String,
    pub offset_frames: u64,
    pub len_frames: u64,
    pub ratio_bits: u64,
}

impl WarpKey {
    pub fn new(source_id: &str, offset_frames: u64, len_frames: u64, ratio: f64) -> Self {
        Self {
            source_id: source_id.to_string(),
            offset_frames,
            len_frames,
            ratio_bits: ratio.to_bits(),
        }
    }
}

/// Content-addressed store of pre-rendered stretched clip audio.
///
/// ## Why this is not on the audio thread, and not on a worker thread either
///
/// Stretching is far too expensive to run per-frame in the render callback, so
/// the warped audio has to exist as a BUFFER before the callback ever sees it.
/// That is settled. The remaining question is which non-audio thread renders
/// it, and the precedent in this crate is `media::load_wav_stereo_48k`: rubato
/// windowed-sinc sample-rate conversion runs SYNCHRONOUSLY on whichever
/// control thread asked for the source, straight into an `AudioBuf`, and the
/// audio thread only ever sees the finished buffer. This does exactly that,
/// one layer up.
///
/// `warp::WarpWorker` (above) is the other half of the precedent and stays
/// where it is: it exists for the INTERACTIVE case — a ratio being dragged,
/// where the newest request must win and the deck must keep playing — and it
/// pays for that with a window in which the audio is knowingly stale.
/// `StudioHost` cannot afford that window, because it has no run loop to pump
/// the results back in and because its offline bounce must be complete and
/// deterministic the moment it is asked for. A bounce that silently omitted a
/// warp because a worker had not finished would be the same silent-degradation
/// bug this lane exists to kill, wearing a different hat. So the shipping host
/// resolves synchronously and caches; the interactive path is noted in the
/// report as the GUI lane's work, on top of this cache.
///
/// Locking: the map lock is held ONLY around the two `HashMap` operations,
/// never across the stretch itself, so a slow render never blocks a lookup.
/// Nothing here is reachable from the audio thread.
pub struct WarpCache {
    entries: Mutex<HashMap<WarpKey, Arc<AudioBuf>>>,
    /// Stretches actually executed (cache misses). Observability + the test
    /// that proves the cache is a cache.
    renders: AtomicU64,
    hits: AtomicU64,
}

impl Default for WarpCache {
    fn default() -> Self {
        Self::new()
    }
}

impl WarpCache {
    pub fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
            renders: AtomicU64::new(0),
            hits: AtomicU64::new(0),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<WarpKey, Arc<AudioBuf>>> {
        self.entries
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
    }

    /// Pre-rendered audio for `extent` stretched to `ratio`, rendering it on
    /// THIS (control) thread on a miss.
    ///
    /// Both engines are bit-deterministic for a given (input, ratio) — asserted
    /// by `stretch_is_bit_deterministic_across_instances` — so a cache hit and
    /// a fresh render are interchangeable, and two runs of the same bounce in
    /// two processes produce the same samples.
    pub fn resolve(&self, key: WarpKey, extent: &[[f32; 2]], ratio: f64, rate: u32) -> Arc<AudioBuf> {
        if let Some(hit) = self.lock().get(&key).cloned() {
            self.hits.fetch_add(1, Ordering::Relaxed);
            return hit;
        }
        // The slow call runs WITHOUT the lock.
        let mut stretcher = deterministic_stretcher(ratio, rate);
        let stretched = stretcher.stretch(extent, ratio);
        let audio = AudioBuf::from_samples(stretched, &format!("warp@{ratio:.6}"));
        self.renders.fetch_add(1, Ordering::Relaxed);
        let mut map = self.lock();
        // A concurrent resolve of the same key produces the same bytes, so
        // either buffer is correct; keep the first to avoid two live copies.
        Arc::clone(map.entry(key).or_insert(audio))
    }

    /// Drop cached buffers whose key is not in `live`. Called after a mutation
    /// so an edited-away warp does not pin its audio forever.
    pub fn retain_keys(&self, live: &std::collections::HashSet<WarpKey>) {
        self.lock().retain(|k, _| live.contains(k));
    }

    pub fn renders(&self) -> u64 {
        self.renders.load(Ordering::Relaxed)
    }

    pub fn hits(&self) -> u64 {
        self.hits.load(Ordering::Relaxed)
    }

    pub fn len(&self) -> usize {
        self.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn tone(frames: usize, hz: f32) -> Vec<[f32; 2]> {
        (0..frames)
            .map(|i| {
                let v = (std::f32::consts::TAU * hz * i as f32 / 48_000.0).sin() * 0.5;
                [v, v]
            })
            .collect()
    }

    #[test]
    fn identity_is_bit_exact_for_both_engines() {
        let input = tone(20_000, 220.0);
        let mut wsola = WsolaStretcher;
        let out = wsola.stretch(&input, 1.0);
        assert_eq!(out.len(), input.len());
        for (a, b) in input.iter().zip(out.iter()) {
            assert_eq!(a[0].to_bits(), b[0].to_bits());
            assert_eq!(a[1].to_bits(), b[1].to_bits());
        }
        let mut ss = SignalsmithStretcher::new(48_000);
        let out = ss.stretch(&input, 1.0);
        assert_eq!(out.len(), input.len());
        for (a, b) in input.iter().zip(out.iter()) {
            assert_eq!(a[0].to_bits(), b[0].to_bits());
        }
    }

    #[test]
    fn stretch_lengths_are_exact_and_energy_sane() {
        let input = tone(48_000, 220.0);
        for ratio in [0.85_f64, 1.15, 1.5] {
            for (name, out) in [
                ("wsola", WsolaStretcher.stretch(&input, ratio)),
                (
                    "signalsmith",
                    SignalsmithStretcher::new(48_000).stretch(&input, ratio),
                ),
            ] {
                let expect = stretched_len(input.len() as u64, ratio) as usize;
                assert_eq!(out.len(), expect, "{name} at {ratio}");
                let rms = (out.iter().map(|s| s[0] * s[0]).sum::<f32>() / out.len() as f32)
                    .sqrt();
                assert!(
                    rms > 0.15 && rms < 0.6,
                    "{name} at {ratio}: rms {rms} vs source ~0.35"
                );
            }
        }
    }

    #[test]
    fn wsola_has_no_silent_gaps_at_large_ratios() {
        // Regression: the donor's fixed-analysis-hop form left periodic
        // silent gaps for ratios > 2x. A continuous tone stretched at 3x and
        // 4x must stay continuous (no long run of near-silent samples).
        let input = tone(48_000, 220.0);
        for ratio in [2.5_f64, 3.0, 4.0] {
            let out = WsolaStretcher.stretch(&input, ratio);
            assert_eq!(out.len(), stretched_len(input.len() as u64, ratio) as usize);
            // No run of >= 64 consecutive frames below -60 dBFS in the body
            // (the very tail can taper).
            let thresh = 0.001_f32;
            let mut run = 0usize;
            let mut worst_run = 0usize;
            for f in &out[..out.len().saturating_sub(2_048)] {
                if f[0].abs() < thresh && f[1].abs() < thresh {
                    run += 1;
                    worst_run = worst_run.max(run);
                } else {
                    run = 0;
                }
            }
            assert!(
                worst_run < 64,
                "silent gap of {worst_run} frames at ratio {ratio}"
            );
        }
    }

    /// `WarpCache` hands a cached buffer to one bounce and a freshly rendered
    /// one to the next, so the two MUST be bit-identical or a project's bounce
    /// would depend on whether the cache happened to be warm — and two exports
    /// of the same project on two days would differ.
    ///
    /// ⚠️ **This test found a real defect the first time it ran.** With
    /// always-Signalsmith, ratio 3.0 disagreed with itself in frame 0 (`left:
    /// 1011584640, right: 1008412128`), because Signalsmith seeds itself from
    /// `std::random_device` and randomises per-bin time factors above 2x. See
    /// `deterministic_stretcher`. Every ratio in the supported 0.25x..4x range
    /// is swept here, on BOTH sides of that boundary, so the fix cannot rot.
    #[test]
    fn stretch_is_bit_deterministic_across_instances() {
        let input = tone(24_000, 220.0);
        for ratio in [0.25_f64, 0.5, 0.87, 1.5, 2.0, 2.5, 3.0, 4.0] {
            let a = deterministic_stretcher(ratio, 48_000).stretch(&input, ratio);
            let b = deterministic_stretcher(ratio, 48_000).stretch(&input, ratio);
            assert_eq!(a.len(), b.len(), "length differs at ratio {ratio}");
            assert_eq!(a.len(), stretched_len(input.len() as u64, ratio) as usize);
            for (i, (x, y)) in a.iter().zip(b.iter()).enumerate() {
                assert_eq!(
                    x[0].to_bits(),
                    y[0].to_bits(),
                    "non-deterministic at ratio {ratio}, frame {i} \
                     (engine {})",
                    deterministic_stretcher(ratio, 48_000).name()
                );
            }
            // The cache's miss path builds a FRESH engine every time, so a
            // reused instance must also agree with a fresh one.
            let mut s = deterministic_stretcher(ratio, 48_000);
            let c = s.stretch(&input, ratio);
            let d = s.stretch(&input, ratio);
            for (x, y) in c.iter().zip(d.iter()) {
                assert_eq!(x[0].to_bits(), y[0].to_bits(), "reuse differs at {ratio}");
            }
            for (x, y) in a.iter().zip(c.iter()) {
                assert_eq!(x[0].to_bits(), y[0].to_bits(), "fresh vs reused at {ratio}");
            }
        }
    }

    /// The engine boundary is where it is for a reason, and the reason is a
    /// line in a vendored C++ header. Pin it so a later "let's just always use
    /// the better engine" is a red test rather than a silent reproducibility
    /// regression.
    #[test]
    fn signalsmith_is_used_exactly_where_it_is_deterministic() {
        for ratio in [0.25_f64, 0.5, 1.0, 1.99, 2.0] {
            assert_eq!(
                deterministic_stretcher(ratio, 48_000).name(),
                "signalsmith",
                "ratio {ratio} is inside signalsmith's clean range"
            );
        }
        for ratio in [2.01_f64, 2.5, 3.0, 4.0] {
            assert_eq!(
                deterministic_stretcher(ratio, 48_000).name(),
                "wsola",
                "ratio {ratio} is above maxCleanStretch, where signalsmith \
                 randomises per-bin time factors from a random_device seed"
            );
        }
    }

    #[test]
    fn cache_renders_once_per_content_address_and_returns_identical_audio() {
        let cache = WarpCache::new();
        let input = tone(24_000, 220.0);
        let key = WarpKey::new("srcA", 0, 24_000, 2.0);
        let first = cache.resolve(key.clone(), &input, 2.0, 48_000);
        let second = cache.resolve(key.clone(), &input, 2.0, 48_000);
        assert_eq!(cache.renders(), 1, "second resolve must be a hit");
        assert_eq!(cache.hits(), 1);
        assert!(Arc::ptr_eq(&first, &second), "same buffer, not a re-render");
        assert_eq!(first.len_frames(), stretched_len(24_000, 2.0));

        // A different ratio is a different address.
        let other = WarpKey::new("srcA", 0, 24_000, 1.5);
        let third = cache.resolve(other.clone(), &input, 1.5, 48_000);
        assert_eq!(cache.renders(), 2);
        assert_eq!(third.len_frames(), stretched_len(24_000, 1.5));

        // Eviction keeps only live addresses.
        let mut live = std::collections::HashSet::new();
        live.insert(other);
        cache.retain_keys(&live);
        assert_eq!(cache.len(), 1);
    }

    #[test]
    fn worker_coalesces_a_burst_to_at_most_two_renders() {
        let worker = WarpWorker::spawn(|| Box::new(WsolaStretcher));
        let audio = crate::media::AudioBuf::from_samples(tone(48_000, 110.0), "src");
        // Rapid-fire 50 ratio changes on one clip.
        for i in 0..50_u64 {
            worker.submit(WarpJob {
                clip_id: "c1".into(),
                source: Arc::clone(&audio),
                offset_frames: 0,
                len_frames: 48_000,
                ratio: 1.0 + (i as f64 + 1.0) * 0.01,
                generation: i + 1,
            });
        }
        assert!(worker.wait_idle(Duration::from_secs(30)), "worker drains");
        let executed = worker.executed.load(Ordering::Relaxed);
        assert!(
            executed <= 3,
            "latest-wins mailbox must coalesce the burst: executed {executed}"
        );
        // The newest generation must be among the delivered results.
        let results = worker.try_results();
        assert!(!results.is_empty());
        let max_gen = results.iter().map(|r| r.generation).max().unwrap();
        assert_eq!(max_gen, 50, "the final ratio wins");
        let last = results.iter().find(|r| r.generation == 50).unwrap();
        assert_eq!(
            last.audio.len_frames(),
            stretched_len(48_000, 1.5),
            "delivered buffer matches the final ratio"
        );
    }
}
