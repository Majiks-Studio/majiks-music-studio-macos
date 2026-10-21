//! Beat-tracked tempo estimate.
//!
//! Pipeline: onset detection (spectral flux, adapted from the majiks-dj
//! donor's `beatgrid::detect_onsets`) feeds two passes: (1) autocorrelation
//! of the onset envelope for coarse candidate periods (adapted from the
//! donor's `bpm_detection::detect_bpm_autocorrelation`), refined to
//! sub-hop precision by parabolic interpolation; (2) discrete onset-peak
//! grid-coverage scoring to pick the correct octave among the candidates,
//! then an ordinary-least-squares fit of onset times to the winning grid
//! for sub-millisecond precision. Step (2)'s least-squares refinement
//! mirrors the technique P0-A's harness used against librosa's integer-lag
//! quantization (docs/evidence/p0a-repaint.md, tempo section: "Least-
//! squares fit over about 200 tracked beats ... removes librosa's integer-
//! lag quantization").
//!
//! The donor's own octave-correction ("if bpm<80 double it, if bpm>160
//! halve it", `bpm_detection.rs`) is NOT reused here: it is wrong for
//! tempos outside roughly 80-160 BPM (it would fold a real 174 BPM track
//! down to 87). Octave selection here instead uses grid-coverage against
//! actual detected onsets (see `grid_coverage`), which generalizes past
//! that fixed range.
//!
//! BINDING PRODUCT FACT (P0-A, docs/evidence/p0a-repaint.md section 3 and
//! 9): generated songs drift 1.2-2.9% from their declared/metadata BPM
//! ("the generated audio does NOT run at exactly the declared BPM ...
//! declared BPM is not ground truth"). `TempoMapEstimate::bpm` is always
//! MEASURED from the audio, never copied from a tag or generation request,
//! and is therefore the bar-snap source of truth for the DAW. A caller MAY
//! pass `declared_bpm_hint` (e.g. the generation request's requested BPM,
//! or a file's embedded tag) but it is used ONLY to break near-ties among
//! candidates that are already almost equally well supported by the audio
//! (see `declared_bpm_hint_used`); it can never override a clearly
//! better-supported measurement.
//!
//! Fixed 4/4 assumption for v1, matching timeline-core's tempo.rs fence
//! (02-ARCHITECTURE.md section 3: "Time signature is fixed 4/4 in v1") and
//! the majiks-dj beatgrid.rs donor: downbeats are every 4th tracked beat,
//! with the phase (which of the 4 beats is "beat 1") chosen by which
//! candidate phase has the strongest mean onset-envelope energy, rather
//! than always assuming the first detected beat is a downbeat.

use serde::{Deserialize, Serialize};

use crate::fft::PlannedFft;

const MIN_BPM: f64 = 40.0;
const MAX_BPM: f64 = 300.0;
const ODF_FRAME: usize = 2048;
const ODF_HOP_SECONDS: f64 = 0.010;
/// A candidate tempo must explain at least this fraction of its predicted
/// beat grid with a real detected onset (within tolerance) to be eligible
/// as the winner. See `grid_coverage`.
///
/// 0.72, not something closer to 1.0: synthetic click-track fixtures
/// (tests/golden_tempo.rs) clear ~0.95-1.0 coverage at their true tempo
/// with huge margin, so this gate is calibrated by real material instead,
/// where perfect per-beat onset detection is unrealistic (sustained pads,
/// soft vocal entries, mixing/mastering that softens transients). Verified
/// against docs/evidence/l3-media-analysis.md's P0-A song B: the
/// musically-correct candidate (~93 BPM, matching P0-A's own independent
/// librosa measurement of 93.3) reads 0.743 coverage, while the nearest
/// competing wrong candidate reads 0.695 -- 0.72 is the value in that gap,
/// not a value chosen to force one example to pass with no separation from
/// the alternative it needs to beat.
const COVERAGE_GATE: f64 = 0.72;

/// Beat-tracked tempo estimate for one audio asset. See module docs for why
/// this, not declared/tag BPM, is the DAW's bar-snap source of truth.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TempoMapEstimate {
    /// Measured tempo in beats per minute, refined by least-squares fit
    /// over tracked onset times. Not rounded.
    pub bpm: f64,
    /// 0.0-1.0. Combines (a) the fraction of detected onsets that fit the
    /// winning beat grid, (b) how tightly they fit it (least-squares
    /// residual vs. half a beat period), and (c) the winning candidate's
    /// grid-coverage score. Low on ambient/arrhythmic material or very
    /// short clips.
    pub confidence: f64,
    /// Seconds from t=0 to the first tracked beat (grid phase). Always in
    /// `[0, 60/bpm)`.
    pub first_beat_offset: f64,
    /// Downbeat positions in seconds (one per bar; bar = 4 beats).
    pub downbeats: Vec<f64>,
    /// All tracked beat positions in seconds, finer-grained than
    /// `downbeats`. Not part of the brief's minimum
    /// `{bpm, confidence, first_beat_offset, downbeats}` shape but cheap to
    /// carry and useful for UI grid rendering and the golden tests.
    pub beats: Vec<f64>,
    /// Always `"4/4"` in v1: no time-signature detection (see module docs).
    pub time_signature: String,
    /// True only when a `declared_bpm_hint` was supplied AND it actually
    /// changed which near-tied candidate won (see module docs). False
    /// whenever the measurement alone determined the winner, including
    /// when a hint was supplied but agreed with (or was not needed by) the
    /// audio-only choice.
    pub declared_bpm_hint_used: bool,
}

impl Default for TempoMapEstimate {
    /// Used when the input is too short or too quiet to track (see
    /// `estimate_tempo`'s early returns). `bpm: 120.0` mirrors
    /// timeline-core's own tempo.rs fallback default
    /// (`TempoMap::segment_at`'s `unwrap_or` case) so an unset tempo reads
    /// the same neutral value on both sides of the (undependency) mapping;
    /// `confidence: 0.0` is what actually signals "no measurement".
    fn default() -> Self {
        Self {
            bpm: 120.0,
            confidence: 0.0,
            first_beat_offset: 0.0,
            downbeats: Vec::new(),
            beats: Vec::new(),
            time_signature: "4/4".to_string(),
            declared_bpm_hint_used: false,
        }
    }
}

struct OnsetEnvelope {
    values: Vec<f32>,
    hop: usize,
    sample_rate: u32,
    /// Analysis frame size in samples, needed only to correct `time_of`'s
    /// frame-center bias (see below); not used for anything else.
    frame_size: usize,
}

impl OnsetEnvelope {
    /// Hop index -> seconds, corrected for the STFT's inherent onset
    /// latency. A Hann-windowed frame's magnitude for a transient at time
    /// `c`, as a function of frame-start `pos`, traces the window shape
    /// itself: `magnitude(pos) ~ w(c - pos)`, peaking (steepest point zero)
    /// at `pos = c - frame_size/2` (transient centered in the window).
    /// Flux is the (rectified) DERIVATIVE of that curve, and for a Hann
    /// window `w(x) = 0.5 - 0.5*cos(2*pi*x/N)`, `w'(x)`'s magnitude peaks
    /// at `x = N/4` and `x = 3N/4`, not at the center (`x = N/2`, where
    /// `w'` is zero). On the RISING side of the magnitude curve -- the side
    /// flux (rectified to positives only) actually tracks -- that maximum
    /// is at `x = 3N/4`, i.e. flux peaks at `pos = c - 3*frame_size/4`, so
    /// the correct forward correction is `+3*frame_size/4`, not
    /// `+frame_size/2`. Without any correction, onset times measured from
    /// `values[i]` read systematically EARLY by close to a full
    /// `frame_size/2` (empirically ~28 ms at the default 2048-sample
    /// frame); with only the naive frame-CENTER correction
    /// (`+frame_size/2`) a smaller but still consistent ~8 ms bias
    /// remained. Both were caught by `tests/golden_tempo.rs`'s
    /// first-beat-offset assertions, which are sensitive to a constant
    /// shift in a way `bpm` is not (bpm depends only on the SPACING between
    /// onsets, unaffected by shifting every onset time by the same
    /// amount).
    fn time_of(&self, index: f64) -> f64 {
        (index * self.hop as f64 + self.frame_size as f64 * 0.75) / self.sample_rate as f64
    }

    /// Exact inverse of `time_of`.
    fn index_of(&self, time: f64) -> f64 {
        (time * self.sample_rate as f64 - self.frame_size as f64 * 0.75) / self.hop as f64
    }

    /// Linearly interpolated envelope value at a fractional hop index.
    /// Out-of-range indices read as 0.0 (silence), never panic.
    fn at(&self, index: f64) -> f32 {
        if self.values.is_empty() {
            return 0.0;
        }
        let i0f = index.floor();
        let frac = (index - i0f) as f32;
        let i0 = i0f as i64;
        let get = |i: i64| -> f32 {
            if i < 0 || i as usize >= self.values.len() {
                0.0
            } else {
                self.values[i as usize]
            }
        };
        get(i0) * (1.0 - frac) + get(i0 + 1) * frac
    }
}

/// Spectral-flux onset strength envelope: log-compressed magnitude
/// spectrum, half-wave-rectified frame-to-frame difference, summed across
/// bins. Adapted from the majiks-dj donor's onset detection
/// (`beatgrid::detect_onsets`), which used raw wideband energy difference;
/// this version uses per-bin spectral flux (log-magnitude), which is less
/// dominated by loud low end and is the standard MIR onset detection
/// function.
fn onset_envelope(mono: &[f32], sample_rate: u32) -> OnsetEnvelope {
    let hop = ((sample_rate as f64) * ODF_HOP_SECONDS).round().max(1.0) as usize;
    let frame_size = ODF_FRAME;
    if mono.len() < frame_size || hop == 0 {
        return OnsetEnvelope { values: Vec::new(), hop: hop.max(1), sample_rate, frame_size };
    }
    let mut fft = PlannedFft::new(frame_size);
    let mut prev_mag = vec![0.0f32; frame_size / 2 + 1];
    let mut values = Vec::new();
    let mut pos = 0usize;
    while pos + frame_size <= mono.len() {
        let mag = fft.magnitude(&mono[pos..pos + frame_size]);
        let mut flux = 0.0f32;
        for (k, &m) in mag.iter().enumerate() {
            let m = (1.0 + m).ln();
            let d = m - prev_mag[k];
            if d > 0.0 {
                flux += d;
            }
            prev_mag[k] = m;
        }
        values.push(flux);
        pos += hop;
    }
    OnsetEnvelope { values, hop, sample_rate, frame_size }
}

/// Sub-sample peak offset in `[-0.5, 0.5]` from three points around a local
/// maximum at the center index (standard 3-point parabolic interpolation).
fn parabolic_offset(left: f32, center: f32, right: f32) -> f64 {
    let denom = (left - 2.0 * center + right) as f64;
    if denom.abs() < 1e-9 {
        return 0.0;
    }
    (0.5 * (left - right) as f64 / denom).clamp(-0.5, 0.5)
}

/// Local-maximum onset peaks above an adaptive local-average threshold
/// (same 1.5x-local-mean rule the donor's `beatgrid::detect_onsets` uses),
/// refined to sub-hop time precision by parabolic interpolation of the
/// envelope around each peak.
fn pick_onset_peaks(env: &OnsetEnvelope) -> Vec<f64> {
    let n = env.values.len();
    if n < 3 {
        return Vec::new();
    }
    let window = 20usize;
    let mut peaks = Vec::new();
    for i in 1..n - 1 {
        let start = i.saturating_sub(window / 2);
        let end = (i + window / 2 + 1).min(n);
        let local_mean: f32 = env.values[start..end].iter().sum::<f32>() / (end - start) as f32;
        let threshold = local_mean * 1.5 + 1e-6;
        let v = env.values[i];
        if v > threshold && v >= env.values[i - 1] && v >= env.values[i + 1] {
            let delta = parabolic_offset(env.values[i - 1], v, env.values[i + 1]);
            peaks.push(env.time_of(i as f64 + delta));
        }
    }
    peaks
}

struct Candidate {
    period: f64,
    autocorr_strength: f64,
}

/// Registers a candidate period (seconds) if its BPM is in range and it is
/// not a near-duplicate of one already collected.
fn push_candidate(lag: f64, strength: f64, hop_seconds: f64, seen: &mut Vec<f64>, out: &mut Vec<Candidate>) {
    let period = lag * hop_seconds;
    if period <= 0.0 {
        return;
    }
    let bpm = 60.0 / period;
    if !(MIN_BPM..=MAX_BPM).contains(&bpm) {
        return;
    }
    if seen.iter().any(|&p| (p - period).abs() < hop_seconds * 0.5) {
        return;
    }
    seen.push(period);
    out.push(Candidate { period, autocorr_strength: strength });
}

/// Coarse candidate periods from autocorrelation of the onset envelope,
/// each refined to sub-hop precision by parabolic interpolation of the
/// correlation peak, PLUS explicit sub-harmonics (period/2, /3, /4, /1.5,
/// and *2/3) of every one of the top local-maximum peaks (not just the
/// single strongest). The sub-harmonics matter because a perfectly
/// periodic onset train correlates strongly at every integer multiple of
/// its fundamental period, so the tallest peak by raw height is not
/// reliably the fundamental; including sub-harmonics as candidates ensures
/// the true beat period is in the set even when it is not the tallest peak.
/// The /1.5 and *2/3 ratios exist for swung/syncopated grooves, where the
/// autocorrelation's tallest peak can be a dotted-note-relationship pulse
/// rather than the literal beat (final octave/ratio selection happens in
/// `estimate_tempo` via `grid_coverage`, not here -- this only ensures the
/// true period is a candidate).
fn autocorrelation_candidates(env: &OnsetEnvelope) -> Vec<Candidate> {
    let n = env.values.len();
    if n < 8 {
        return Vec::new();
    }
    let mean = env.values.iter().map(|&v| v as f64).sum::<f64>() / n as f64;
    let centered: Vec<f64> = env.values.iter().map(|&v| v as f64 - mean).collect();
    let hop_seconds = env.hop as f64 / env.sample_rate as f64;
    let min_lag = ((60.0 / MAX_BPM) / hop_seconds).floor().max(1.0) as usize;
    let max_lag = (((60.0 / MIN_BPM) / hop_seconds).ceil() as usize).min(n.saturating_sub(2));
    if min_lag >= max_lag {
        return Vec::new();
    }

    let mut corr = vec![0.0f64; max_lag + 1];
    for (lag, slot) in corr.iter_mut().enumerate().take(max_lag + 1).skip(min_lag) {
        let len = n - lag;
        let mut acc = 0.0;
        for i in 0..len {
            acc += centered[i] * centered[i + lag];
        }
        *slot = acc / len as f64;
    }

    let mut peaks: Vec<(usize, f64)> = Vec::new();
    for lag in (min_lag + 1)..max_lag {
        if corr[lag] > corr[lag - 1] && corr[lag] >= corr[lag + 1] && corr[lag] > 0.0 {
            peaks.push((lag, corr[lag]));
        }
    }
    peaks.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    peaks.truncate(8);

    let mut candidates = Vec::new();
    let mut seen_periods: Vec<f64> = Vec::new();
    let mut refined_peaks: Vec<(f64, f64)> = Vec::new(); // (lag, strength)
    for &(lag, strength) in &peaks {
        let delta = parabolic_offset(corr[lag - 1] as f32, corr[lag] as f32, corr[lag + 1] as f32);
        let lag_f = lag as f64 + delta;
        refined_peaks.push((lag_f, strength));
        push_candidate(lag_f, strength, hop_seconds, &mut seen_periods, &mut candidates);
    }
    // Sub-harmonics of EVERY top peak (not just the single strongest), plus
    // the 2:3 / 3:2 ratio (swung / syncopated grooves, where the tracked
    // pulse can lock onto a dotted-note feel rather than the literal beat;
    // see docs/evidence/l3-media-analysis.md's P0-A song B finding). A
    // perfectly periodic onset train correlates strongly at every integer
    // multiple of its fundamental, so the tallest peak by raw height is not
    // reliably the fundamental; final octave/ratio selection happens in
    // `estimate_tempo` via `grid_coverage`, not here -- this only ensures
    // the true period is IN the candidate set.
    for &(lag_f, strength) in &refined_peaks {
        for ratio in [2.0, 3.0, 4.0, 1.5] {
            push_candidate(lag_f / ratio, strength, hop_seconds, &mut seen_periods, &mut candidates);
        }
        push_candidate(lag_f * 2.0 / 3.0, strength, hop_seconds, &mut seen_periods, &mut candidates);
    }
    candidates
}

/// Phase (offset in `[0, period)`) maximizing the sum of the onset envelope
/// sampled at the predicted beat grid, searched at hop/8 resolution and
/// refined by parabolic interpolation of the score curve around its peak.
fn best_phase(env: &OnsetEnvelope, period: f64, duration: f64) -> f64 {
    let hop_seconds = env.hop as f64 / env.sample_rate as f64;
    let steps = (((period / hop_seconds) * 8.0).round().max(8.0)) as usize;
    let mut scores = vec![0.0f64; steps];
    for (s, score) in scores.iter_mut().enumerate() {
        let offset = period * s as f64 / steps as f64;
        let mut sum = 0.0;
        let mut beat = 0.0;
        while offset + beat < duration {
            sum += env.at(env.index_of(offset + beat)) as f64;
            beat += period;
        }
        *score = sum;
    }
    let best_s = scores.iter().enumerate().max_by(|a, b| a.1.partial_cmp(b.1).unwrap()).map(|(i, _)| i).unwrap_or(0);
    let prev = scores[(best_s + steps - 1) % steps];
    let next = scores[(best_s + 1) % steps];
    let delta = parabolic_offset(prev as f32, scores[best_s] as f32, next as f32);
    period * (best_s as f64 + delta) / steps as f64
}

/// Fraction (and raw count) of grid beats `offset, offset+period, ...` that
/// land within `tolerance` seconds of a detected onset peak.
///
/// This is the octave-disambiguation signal. A candidate period that is
/// too FAST (shorter than the true beat period) predicts grid points
/// between real onsets, so its coverage collapses toward 0.5 or lower. A
/// candidate that is exactly right, OR any integer-multiple-slower alias of
/// it (half tempo, third tempo, ...), predicts a grid that is a SUBSET of
/// real beats, so both read near-total coverage -- coverage alone cannot
/// tell them apart. `estimate_tempo` resolves that remaining ambiguity by
/// picking the SMALLEST period among candidates that clear the coverage
/// gate: the true period is the finest grid that is still fully
/// corroborated by onsets, and both a too-fast alias (fails the gate) and
/// a too-slow alias (passes the gate but with a larger period) lose to it.
fn grid_coverage(onsets: &[f64], offset: f64, period: f64, duration: f64, tolerance: f64) -> (f64, usize) {
    if onsets.is_empty() || period <= 0.0 {
        return (0.0, 0);
    }
    let mut hits = 0usize;
    let mut total = 0usize;
    let mut beat = offset;
    while beat < duration {
        total += 1;
        if onsets.iter().any(|&o| (o - beat).abs() <= tolerance) {
            hits += 1;
        }
        beat += period;
    }
    if total == 0 {
        (0.0, 0)
    } else {
        (hits as f64 / total as f64, hits)
    }
}

/// Ordinary least-squares fit of onset times to `offset + n * period`, over
/// onsets within `tolerance` of their nearest grid line (outliers -- missed
/// beats, spurious extra onsets -- are excluded, not down-weighted).
/// Mirrors the refinement P0-A's harness used to remove librosa's
/// integer-lag quantization (docs/evidence/p0a-repaint.md, tempo section).
/// Returns `(offset, period, residual_rms, inlier_count)`.
fn refine_least_squares(onsets: &[f64], offset0: f64, period0: f64, tolerance: f64) -> (f64, f64, f64, usize) {
    let mut xs = Vec::new();
    let mut ys = Vec::new();
    for &o in onsets {
        let n = ((o - offset0) / period0).round();
        let predicted = offset0 + n * period0;
        if (o - predicted).abs() <= tolerance {
            xs.push(n);
            ys.push(o);
        }
    }
    if xs.len() < 2 {
        return (offset0, period0, tolerance, xs.len());
    }
    let n_mean = xs.iter().sum::<f64>() / xs.len() as f64;
    let t_mean = ys.iter().sum::<f64>() / ys.len() as f64;
    let mut num = 0.0;
    let mut den = 0.0;
    for (&x, &y) in xs.iter().zip(ys.iter()) {
        num += (x - n_mean) * (y - t_mean);
        den += (x - n_mean) * (x - n_mean);
    }
    if den.abs() < 1e-12 {
        return (offset0, period0, tolerance, xs.len());
    }
    let period = num / den;
    let offset = t_mean - period * n_mean;
    let sum_sq: f64 = xs.iter().zip(ys.iter()).map(|(&x, &y)| { let pred = offset + period * x; (y - pred) * (y - pred) }).sum();
    let residual_rms = (sum_sq / xs.len() as f64).sqrt();
    (offset, period, residual_rms, xs.len())
}

/// Estimate tempo, beat grid, and downbeats from a mono signal. See module
/// docs for the algorithm and for why the result -- not any declared/tag
/// BPM -- is the DAW's bar-snap source of truth.
pub fn estimate_tempo(mono: &[f32], sample_rate: u32, declared_bpm_hint: Option<f64>) -> TempoMapEstimate {
    let env = onset_envelope(mono, sample_rate);
    if env.values.is_empty() {
        return TempoMapEstimate::default();
    }
    let onsets = pick_onset_peaks(&env);
    let duration = mono.len() as f64 / sample_rate as f64;
    let candidates = autocorrelation_candidates(&env);
    if candidates.is_empty() || onsets.len() < 2 {
        return TempoMapEstimate::default();
    }

    struct Scored {
        period: f64,
        offset: f64,
        coverage: f64,
        hits: usize,
        autocorr_strength: f64,
    }
    let scored: Vec<Scored> = candidates
        .iter()
        .map(|c| {
            let offset = best_phase(&env, c.period, duration);
            let tolerance = (c.period * 0.12).max(0.01);
            let (coverage, hits) = grid_coverage(&onsets, offset, c.period, duration, tolerance);
            Scored { period: c.period, offset, coverage, hits, autocorr_strength: c.autocorr_strength }
        })
        .collect();

    let mut passing_idx: Vec<usize> = (0..scored.len()).filter(|&i| scored[i].coverage >= COVERAGE_GATE).collect();
    passing_idx.sort_by(|&a, &b| scored[a].period.partial_cmp(&scored[b].period).unwrap());

    let hint_period = declared_bpm_hint.filter(|b| *b > 0.0).map(|b| 60.0 / b);
    let mut declared_bpm_hint_used = false;

    let winner_idx: usize = if let Some(&smallest_idx) = passing_idx.first() {
        let best_hits = scored[smallest_idx].hits;
        let tie_band: Vec<usize> =
            passing_idx.iter().copied().filter(|&i| (scored[i].hits as f64) >= best_hits as f64 * 0.95).collect();
        if tie_band.len() > 1 {
            if let Some(hp) = hint_period {
                let chosen = *tie_band
                    .iter()
                    .min_by(|&&a, &&b| {
                        (scored[a].period.ln() - hp.ln())
                            .abs()
                            .partial_cmp(&(scored[b].period.ln() - hp.ln()).abs())
                            .unwrap()
                    })
                    .unwrap();
                if chosen != smallest_idx {
                    declared_bpm_hint_used = true;
                }
                chosen
            } else {
                smallest_idx
            }
        } else {
            smallest_idx
        }
    } else {
        // No candidate cleared the coverage gate (sparse/ambient onsets):
        // fall back to the strongest raw autocorrelation peak. Confidence
        // below reflects this weaker evidence honestly.
        (0..scored.len()).max_by(|&a, &b| scored[a].autocorr_strength.partial_cmp(&scored[b].autocorr_strength).unwrap()).unwrap()
    };

    let winner_period = scored[winner_idx].period;
    let winner_offset = scored[winner_idx].offset;
    let winner_coverage = scored[winner_idx].coverage;

    let tolerance = (winner_period * 0.12).max(0.01);
    let (offset_fit, period_fit, residual_rms, inliers) = refine_least_squares(&onsets, winner_offset, winner_period, tolerance);

    // Wrap `offset_fit` into [0, period_fit) RELATIVE to `winner_offset`
    // (already inside that range, from the coverage-gated phase search),
    // not via a plain `%`. `winner_offset` anchors which grid line the fit
    // is a refinement OF: when the true phase sits right at the wrap
    // boundary (near 0 == near period), least-squares noise can nudge
    // `offset_fit` a hair negative (or a hair past `period_fit`), and a
    // plain non-negative modulo would then report a beat a FULL PERIOD
    // later than the one the fit actually found (observed: an 8ms
    // regression noise turning into a reported 592ms offset at 100 BPM,
    // caught by golden_tempo.rs). Anchoring to `winner_offset` picks the
    // SAME grid point the fit refined, then a small epsilon clamp handles
    // only genuine floating-point overshoot right at 0 or period_fit.
    let cycles = ((offset_fit - winner_offset) / period_fit).round();
    let mut first_beat_offset = offset_fit - cycles * period_fit;
    if first_beat_offset < 0.0 {
        first_beat_offset = 0.0;
    } else if first_beat_offset >= period_fit {
        first_beat_offset = period_fit - 1e-9;
    }

    let mut beats = Vec::new();
    let mut t = first_beat_offset;
    while t < duration {
        beats.push(t);
        t += period_fit;
    }

    // Downbeat phase: of the 4 beat-index residues mod 4, the one with the
    // highest mean onset-envelope strength (4/4 fixed for v1; see module
    // docs).
    let mut best_phase_idx = 0usize;
    let mut best_strength = f64::MIN;
    for phase in 0..4 {
        let subset: Vec<f64> = beats.iter().skip(phase).step_by(4).copied().collect();
        if subset.is_empty() {
            continue;
        }
        let strength: f64 = subset.iter().map(|&b| env.at(env.index_of(b)) as f64).sum::<f64>() / subset.len() as f64;
        if strength > best_strength {
            best_strength = strength;
            best_phase_idx = phase;
        }
    }
    let downbeats: Vec<f64> = beats.iter().skip(best_phase_idx).step_by(4).copied().collect();

    let inlier_fraction = (inliers as f64 / onsets.len().max(1) as f64).min(1.0);
    let alignment_quality = (1.0 - (residual_rms / (period_fit * 0.5)).min(1.0)).max(0.0);
    let confidence = (inlier_fraction * alignment_quality * winner_coverage).clamp(0.0, 1.0);

    TempoMapEstimate {
        bpm: 60.0 / period_fit,
        confidence,
        first_beat_offset,
        downbeats,
        beats,
        time_signature: "4/4".to_string(),
        declared_bpm_hint_used,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn synth_click_track(bpm: f64, first_beat_offset: f64, bars: u32, sample_rate: u32) -> Vec<f32> {
        let period = 60.0 / bpm;
        let total_beats = bars * 4;
        let duration = first_beat_offset + period * total_beats as f64 + 1.0;
        let n = (duration * sample_rate as f64) as usize;
        let mut buf = vec![0.0f32; n];
        let click_len = (sample_rate as f64 * 0.008) as usize;
        for beat in 0..total_beats {
            let t = first_beat_offset + beat as f64 * period;
            let start = (t * sample_rate as f64).round() as usize;
            let amp = if beat % 4 == 0 { 1.0 } else { 0.6 };
            for i in 0..click_len {
                if start + i >= buf.len() {
                    break;
                }
                let decay = (-(i as f32) / (click_len as f32 * 0.25)).exp();
                let tone = (2.0 * std::f32::consts::PI * 2000.0 * i as f32 / sample_rate as f32).sin();
                buf[start + i] += amp * decay * tone;
            }
        }
        buf
    }

    #[test]
    fn silence_returns_zero_confidence_default() {
        let mono = vec![0.0f32; 48_000 * 2];
        let est = estimate_tempo(&mono, 48_000, None);
        assert_eq!(est.confidence, 0.0);
        assert!(est.beats.is_empty());
    }

    #[test]
    fn very_short_clip_does_not_panic() {
        let mono = vec![0.1f32; 100];
        let est = estimate_tempo(&mono, 48_000, None);
        assert_eq!(est.confidence, 0.0);
    }

    // The full BPM-range golden table (80-174 BPM, including the
    // donor-breaking 174 BPM octave case) lives in
    // ../tests/golden_tempo.rs, which doubles as this lane's evidence-doc
    // data source. These inline tests stay narrow: fast unit-level checks
    // that don't belong in the golden table.

    #[test]
    fn declared_hint_does_not_override_a_clear_measurement() {
        let mono = synth_click_track(120.0, 0.0, 16, 48_000);
        // A wildly wrong hint must not move a clean, unambiguous reading.
        let est = estimate_tempo(&mono, 48_000, Some(200.0));
        assert!((est.bpm - 120.0).abs() <= 0.5, "measured {}", est.bpm);
    }
}
