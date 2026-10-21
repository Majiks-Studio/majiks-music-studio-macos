//! `stem_usability`: is a separated stem usable ON ITS OWN?
//!
//! Written after a shipped defect: the default separator was a TEST FIXTURE
//! (`InterleaveFixtureSeparator`) that deals every 4th sample into a different
//! stem and zeroes the other three. Its four stems sum back to the mix
//! BIT-EXACTLY, so every check the landing pipeline had -- the null test, the
//! pure-sum residual, the asset hashes -- passed perfectly. The owner soloed one
//! stem and heard a screech, because "the parts add up" says nothing about
//! whether any one part is listenable. Five lanes then searched the mute/solo
//! render path, which measured clean at 300x margin. The engine was innocent;
//! the CONTENT was broken.
//!
//! So this module measures the opposite face of the same property: the sum
//! test proves the stems RECONSTRUCT, these two measures prove each stem is
//! itself a piece of music rather than a chopped-up copy of the whole.
//!
//! Two oracles, both cheap, both offline, both calibrated against real demucs
//! output AND against the fixture (see the constants for the measured numbers):
//!
//!   1. `zero_ratio` -- the fraction of samples that are EXACTLY 0.0. A real
//!      separator writes a continuous waveform; a decimating fixture leaves
//!      silence by construction. Decisive: 75.0000% for the fixture, at most
//!      6.84% for htdemucs on the owner's own song.
//!   2. `high_band_fraction` -- the fraction of spectral energy above
//!      0.75 * Nyquist. Keeping every 4th sample multiplies the mix by a
//!      period-4 impulse train, which convolves the spectrum with combs at
//!      +/- fs/4 and fs/2: three aliased copies of the whole song fold into the
//!      top of the band. That fold IS the screech, and it is what no
//!      sum-to-the-original assertion can see. 25.0018% for the fixture,
//!      at most 0.064% for htdemucs.
//!
//! Neither number is a runtime gate on the landing pipeline: a genuinely silent
//! stem is legitimate (an instrumental has no vocals, and demucs will hand back
//! a near-zero vocals track). They are the contract every registered separator
//! is held to in tests, and they are reported in the landing report so the
//! numbers are visible rather than inferred.

use std::path::Path;

use media::fft::PlannedFft;
use render::media::load_wav_stereo_48k;

use crate::error::StudioError;

/// Above this fraction of exactly-zero samples, a stem is silence-by-construction
/// rather than a part.
///
/// Calibrated against BOTH sides on the owner's own 49 s song:
///   - htdemucs 4.1.0 stems: vocals 2.19%, drums 6.84%, bass 0.04%, other 0.10%.
///     (The drums figure is quantization to zero between hits in demucs's 16-bit
///     output -- real, legitimate, and the reason this bound is not 1%.)
///   - the interleave fixture: 75.0000%, exactly, in every stem.
/// 0.50 sits ~7x above the worst real stem and 25 points below the fixture, so
/// neither a quiet real part nor a louder mastering choice can drift into it.
pub const MAX_ZERO_RATIO: f64 = 0.50;

/// Above this fraction of energy over 0.75 * Nyquist, a stem is carrying the
/// broadband aliasing signature of a decimated copy, not an instrument.
///
/// Calibrated against BOTH sides on the same song:
///   - htdemucs stems: 0.032%, 0.064%, 0.000%, 0.000%.
///   - the interleave fixture: 25.0018% in every stem (three folded copies of
///     the full-band mix, which is 1/4 of the energy by construction).
/// 0.05 is ~78x above the worst real stem and 5x below the fixture. It is
/// deliberately loose on the real side: bright material (cymbals, distorted
/// guitar, a hi-hat-only stem) genuinely lives up there, and this test must
/// never fire on a real separator that simply sounds bright.
pub const MAX_HIGH_BAND_FRACTION: f64 = 0.05;

/// Where the high band starts, as a fraction of Nyquist. 0.75 of 24 kHz is
/// 18 kHz: above every instrument's fundamental and above most real program
/// content, but squarely inside the fs/4 and fs/2 images a period-4 decimation
/// creates.
const HIGH_BAND_START: f64 = 0.75;

/// STFT size / hop for the high-band measurement. 2048 at 48 kHz is ~43 ms,
/// long enough for 23 Hz bins (so the band edge is sharp) and short enough that
/// a 4-minute song is a few thousand frames.
const FFT_SIZE: usize = 2048;
const FFT_HOP: usize = 1024;

/// The two numbers, for one stem.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StemUsability {
    /// Fraction of samples (across both channels) that are exactly 0.0.
    pub zero_ratio: f64,
    /// Fraction of spectral energy above `HIGH_BAND_START * Nyquist`. 0.0 for a
    /// stem with no energy at all (a legitimately silent part), which is why
    /// `zero_ratio` is the first oracle and not the only one.
    pub high_band_fraction: f64,
}

impl StemUsability {
    /// `Ok(())` when this stem could be soloed and still sound like music;
    /// `Err(reason)` naming the measurement that failed and BOTH numbers, so a
    /// failing test says what the audio does, not just that a bound tripped.
    pub fn verdict(&self) -> Result<(), String> {
        if self.zero_ratio > MAX_ZERO_RATIO {
            return Err(format!(
                "{:.4}% of samples are exactly zero (bound {:.1}%): this stem is silence by \
                 construction, not a separated part -- soloed, it is a decimated copy of the \
                 whole mix, not an instrument",
                self.zero_ratio * 100.0,
                MAX_ZERO_RATIO * 100.0
            ));
        }
        if self.high_band_fraction > MAX_HIGH_BAND_FRACTION {
            return Err(format!(
                "{:.4}% of energy sits above {:.0}% of Nyquist (bound {:.1}%): that is the \
                 broadband aliasing signature of a decimated mix folding back into the top of \
                 the band -- soloed, this stem screeches",
                self.high_band_fraction * 100.0,
                HIGH_BAND_START * 100.0,
                MAX_HIGH_BAND_FRACTION * 100.0
            ));
        }
        Ok(())
    }

    /// The report shape (`stemUsability` in the landing report JSON).
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "zeroRatio": self.zero_ratio,
            "highBandFraction": self.high_band_fraction,
        })
    }
}

/// Measure one decoded stereo stem. Pure math over the samples already in
/// memory: no io, no allocation per frame beyond the one magnitude buffer the
/// FFT helper returns.
pub fn measure(samples: &[[f32; 2]]) -> StemUsability {
    if samples.is_empty() {
        // Nothing to judge. Report "clean" rather than inventing a failure: an
        // empty buffer is a different defect and a different test's job.
        return StemUsability { zero_ratio: 0.0, high_band_fraction: 0.0 };
    }

    let mut zeros = 0usize;
    for f in samples {
        if f[0] == 0.0 {
            zeros += 1;
        }
        if f[1] == 0.0 {
            zeros += 1;
        }
    }
    let zero_ratio = zeros as f64 / (samples.len() * 2) as f64;

    StemUsability { zero_ratio, high_band_fraction: high_band_fraction(samples) }
}

/// Fraction of STFT energy above `HIGH_BAND_START * Nyquist`, summed over the
/// whole stem (mid channel). Returns 0.0 when the stem has no energy at all.
fn high_band_fraction(samples: &[[f32; 2]]) -> f64 {
    if samples.len() < FFT_SIZE {
        return 0.0;
    }
    let mono: Vec<f32> = samples.iter().map(|f| 0.5 * (f[0] + f[1])).collect();
    let mut fft = PlannedFft::new(FFT_SIZE);
    // Bin k covers k * rate / FFT_SIZE Hz, so the band edge is a fixed bin
    // index regardless of the sample rate (the boundary is a fraction of
    // Nyquist, not an absolute frequency).
    let first_high_bin = (HIGH_BAND_START * (FFT_SIZE / 2) as f64).round() as usize;

    let mut total = 0.0f64;
    let mut high = 0.0f64;
    let mut start = 0usize;
    while start + FFT_SIZE <= mono.len() {
        let mag = fft.magnitude(&mono[start..start + FFT_SIZE]);
        for (k, m) in mag.iter().enumerate() {
            let power = (*m as f64) * (*m as f64);
            total += power;
            if k >= first_high_bin {
                high += power;
            }
        }
        start += FFT_HOP;
    }
    if total <= 0.0 {
        0.0
    } else {
        high / total
    }
}

/// Measure a stem WAV on disk, decoded through the SAME loader the timeline
/// import uses (so the numbers describe the audio the user actually hears when
/// they solo the track, not the file's bytes).
pub fn measure_wav(path: &Path) -> Result<StemUsability, StudioError> {
    let buf = load_wav_stereo_48k(path).map_err(StudioError::audio)?;
    Ok(measure(&buf.samples))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI;

    /// A 220 Hz sine at 48 kHz: real, continuous, band-limited program content.
    fn tone(n: usize) -> Vec<[f32; 2]> {
        (0..n)
            .map(|i| {
                let v = 0.5 * (2.0 * PI * 220.0 * i as f32 / 48_000.0).sin();
                [v, v]
            })
            .collect()
    }

    #[test]
    fn a_continuous_tone_passes_both_oracles() {
        let m = measure(&tone(48_000));
        // A sine crosses zero exactly twice per cycle at most; 220 Hz over 1 s
        // is well under one in a thousand samples.
        assert!(m.zero_ratio < 0.001, "zero ratio {}", m.zero_ratio);
        assert!(m.high_band_fraction < 0.0001, "high band {}", m.high_band_fraction);
        assert!(m.verdict().is_ok(), "{:?}", m.verdict());
    }

    #[test]
    fn the_interleave_fixture_shape_fails_both_oracles_at_the_known_numbers() {
        // Exactly what BandSplit/InterleaveFixture does: keep every 4th frame.
        let src = tone(48_000);
        let mut stem = vec![[0.0f32; 2]; src.len()];
        for i in (0..src.len()).step_by(4) {
            stem[i] = src[i];
        }
        let m = measure(&stem);
        // 3 of every 4 frames zeroed -> 75%, and the tone's own zero crossings
        // add a hair on top. Hardcoded expectation, not a re-derivation.
        assert!(
            (m.zero_ratio - 0.75).abs() < 0.001,
            "expected ~75.0% exact zeros, got {:.4}%",
            m.zero_ratio * 100.0
        );
        // Three aliased copies of a low tone fold in above 18 kHz: half of the
        // four images land in the top quarter of the band.
        assert!(
            m.high_band_fraction > 0.20,
            "expected the aliased quarter-band energy (>20%), got {:.4}%",
            m.high_band_fraction * 100.0
        );
        let why = m.verdict().expect_err("the fixture shape must be refused");
        assert!(why.contains("exactly zero"), "verdict names the zero ratio first: {why}");
    }

    #[test]
    fn silence_is_not_flagged_as_aliasing() {
        // A legitimately silent stem (an instrumental's vocals track) has no
        // energy, so the spectral oracle must report 0, not divide by zero.
        let m = measure(&vec![[0.0f32; 2]; 48_000]);
        assert_eq!(m.high_band_fraction, 0.0);
        assert_eq!(m.zero_ratio, 1.0);
    }

    #[test]
    fn the_thresholds_straddle_both_measured_populations() {
        // Guards the calibration itself: if someone loosens a bound to make a
        // failing separator pass, this fails first and says why. The numbers
        // are the measured htdemucs worst case and the measured fixture value.
        const HTDEMUCS_WORST_ZERO_RATIO: f64 = 0.0684; // drums, owner's song
        const HTDEMUCS_WORST_HIGH_BAND: f64 = 0.00064; // drums, owner's song
        const FIXTURE_ZERO_RATIO: f64 = 0.75;
        const FIXTURE_HIGH_BAND: f64 = 0.250018;
        assert!(MAX_ZERO_RATIO > HTDEMUCS_WORST_ZERO_RATIO * 5.0);
        assert!(MAX_ZERO_RATIO < FIXTURE_ZERO_RATIO * 0.75);
        assert!(MAX_HIGH_BAND_FRACTION > HTDEMUCS_WORST_HIGH_BAND * 20.0);
        assert!(MAX_HIGH_BAND_FRACTION < FIXTURE_HIGH_BAND * 0.25);
    }
}
