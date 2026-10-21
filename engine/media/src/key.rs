//! Key estimate via chroma correlation against the Krumhansl-Kessler
//! probe-tone key profiles (Krumhansl, C. L., 1990, "Cognitive Foundations
//! of Musical Pitch"; the profile numbers below are the standard published
//! values, widely reused as the reference key-detection profile in MIR
//! research and tooling). Pure math, no I/O; wasm32-safe.
//!
//! No numeric accuracy bar is specified for key estimation in the program
//! brief (unlike tempo's +/-0.5 BPM / +/-20 ms). Treat `confidence` as a
//! rough ranking signal, not a calibrated probability.

use serde::{Deserialize, Serialize};

use crate::fft::PlannedFft;

const PITCH_CLASSES: [&str; 12] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];

// Krumhansl-Kessler major/minor key profiles, indexed by scale degree
// relative to the tonic (index 0 = tonic).
const KK_MAJOR: [f64; 12] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88];
const KK_MINOR: [f64; 12] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17];

const CHROMA_FRAME: usize = 8192;
const CHROMA_HOP: usize = 4096;
const MIN_HZ: f32 = 80.0;
const MAX_HZ: f32 = 4000.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Mode {
    Major,
    Minor,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct KeyEstimate {
    // Owned `String`, not `&'static str`: `#[derive(Deserialize)]` cannot
    // produce a `'static` borrow from an arbitrary deserializer, and this
    // type is not hot-path enough to justify a manual Deserialize impl
    // just to keep a borrowed field.
    pub tonic: String,
    pub mode: Mode,
    /// 0.0-1.0, the winning rotation's Pearson correlation rescaled from
    /// `[-1, 1]`.
    pub confidence: f64,
}

impl std::fmt::Display for KeyEstimate {
    /// Matches the Gen Protocol `analyzeResponse.key` string convention
    /// (see fixtures/gen-protocol/analyze.response.json: `"D minor"`).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mode = match self.mode {
            Mode::Major => "major",
            Mode::Minor => "minor",
        };
        write!(f, "{} {}", self.tonic, mode)
    }
}

/// Sum of magnitude spectrum energy per pitch class (0=C .. 11=B) across
/// the whole signal, restricted to `[MIN_HZ, MAX_HZ]` to avoid rumble and
/// unpitched high-frequency noise dominating the profile.
fn chroma_vector(mono: &[f32], sample_rate: u32) -> [f64; 12] {
    let mut chroma = [0.0f64; 12];
    if mono.len() < CHROMA_FRAME {
        return chroma;
    }
    let mut fft = PlannedFft::new(CHROMA_FRAME);
    let bin_hz = sample_rate as f32 / CHROMA_FRAME as f32;
    let mut pos = 0usize;
    while pos + CHROMA_FRAME <= mono.len() {
        let mag = fft.magnitude(&mono[pos..pos + CHROMA_FRAME]);
        for (k, &m) in mag.iter().enumerate() {
            let freq = k as f32 * bin_hz;
            if freq < MIN_HZ || freq > MAX_HZ {
                continue;
            }
            let midi = 69.0 + 12.0 * (freq / 440.0).log2();
            let pitch_class = (midi.round().rem_euclid(12.0)) as usize % 12;
            chroma[pitch_class] += m as f64;
        }
        pos += CHROMA_HOP;
    }
    chroma
}

/// Rotates a tonic-C profile so index `pc` holds the weight for absolute
/// pitch class `pc` when the hypothesized tonic is `shift`:
/// `out[pc] = profile[(pc - shift) mod 12]`.
fn rotate(profile: &[f64; 12], shift: usize) -> [f64; 12] {
    let mut out = [0.0; 12];
    for (i, slot) in out.iter_mut().enumerate() {
        *slot = profile[(i + 12 - shift) % 12];
    }
    out
}

fn pearson(a: &[f64; 12], b: &[f64; 12]) -> f64 {
    let ma = a.iter().sum::<f64>() / 12.0;
    let mb = b.iter().sum::<f64>() / 12.0;
    let mut num = 0.0;
    let mut da = 0.0;
    let mut db = 0.0;
    for i in 0..12 {
        let x = a[i] - ma;
        let y = b[i] - mb;
        num += x * y;
        da += x * x;
        db += y * y;
    }
    if da <= 0.0 || db <= 0.0 {
        return 0.0;
    }
    num / (da.sqrt() * db.sqrt())
}

pub fn estimate_key(mono: &[f32], sample_rate: u32) -> KeyEstimate {
    let chroma = chroma_vector(mono, sample_rate);
    let mut best_tonic = 0usize;
    let mut best_mode = Mode::Major;
    let mut best_score = f64::MIN;
    for tonic in 0..12 {
        let major_score = pearson(&chroma, &rotate(&KK_MAJOR, tonic));
        if major_score > best_score {
            best_score = major_score;
            best_tonic = tonic;
            best_mode = Mode::Major;
        }
        let minor_score = pearson(&chroma, &rotate(&KK_MINOR, tonic));
        if minor_score > best_score {
            best_score = minor_score;
            best_tonic = tonic;
            best_mode = Mode::Minor;
        }
    }
    KeyEstimate {
        tonic: PITCH_CLASSES[best_tonic].to_string(),
        mode: best_mode,
        confidence: ((best_score + 1.0) / 2.0).clamp(0.0, 1.0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn silence_is_low_confidence_but_does_not_panic() {
        let mono = vec![0.0f32; 48_000 * 2];
        let est = estimate_key(&mono, 48_000);
        assert!(PITCH_CLASSES.contains(&est.tonic.as_str()));
        assert!((0.0..=1.0).contains(&est.confidence));
    }

    #[test]
    fn c_major_scale_biases_toward_a_closely_related_key() {
        let sample_rate = 48_000u32;
        // C major scale tones, played as sustained sine mixtures.
        let scale_hz = [261.63f32, 293.66, 329.63, 349.23, 392.0, 440.0, 493.88];
        let mut mono = vec![0.0f32; sample_rate as usize * 4];
        for (i, s) in mono.iter_mut().enumerate() {
            let t = i as f32 / sample_rate as f32;
            *s = scale_hz.iter().map(|f| (2.0 * std::f32::consts::PI * f * t).sin()).sum::<f32>() / scale_hz.len() as f32;
        }
        let est = estimate_key(&mono, sample_rate);
        // Loose, structural assertion (no numeric bar specified for key):
        // C major's relative/closely-related keys are C, G, F, A minor, E
        // minor, D minor. A random unrelated key would be a real bug.
        let plausible = matches!(
            (est.tonic.as_str(), est.mode),
            ("C", Mode::Major) | ("G", Mode::Major) | ("F", Mode::Major) | ("A", Mode::Minor) | ("E", Mode::Minor) | ("D", Mode::Minor)
        );
        assert!(plausible, "got {} {:?} confidence {}", est.tonic, est.mode, est.confidence);
    }

    #[test]
    fn display_matches_gen_protocol_key_string_convention() {
        let est = KeyEstimate { tonic: "D".to_string(), mode: Mode::Minor, confidence: 0.5 };
        assert_eq!(est.to_string(), "D minor");
    }
}
