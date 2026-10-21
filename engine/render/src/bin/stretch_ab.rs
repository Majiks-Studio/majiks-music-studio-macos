//! Stretch A/B evidence generator (CLI, no UI, SILENT).
//!
//! Runs the same source material through both stretch engines
//! (Signalsmith = primary, WSOLA = fallback/baseline) at 0.85x, 1.0x, and
//! 1.15x, prints an objective metrics table, and writes short listening
//! excerpts to docs/evidence/l2-stretch-ab/.
//!
//! AUDIO SAFETY: nothing here opens an audio device. The excerpts are FILES
//! for later inspection; they are never played by this tool.
//!
//! Excerpt format: ~4 s MONO 16-bit WAV at 48 kHz (about 375 KB, under the
//! 400 KB cap) — full engine bandwidth, no resampling artifacts to confound
//! the comparison. The sources are mono-summed synthetic fixtures, so a mono
//! excerpt loses nothing about the stretch quality.

use std::path::{Path, PathBuf};

use render::fixtures;
use render::media::load_wav_stereo_48k;
use render::warp::{is_identity, stretched_len, SignalsmithStretcher, Stretcher, WsolaStretcher};

const RATIOS: [f64; 3] = [0.85, 1.0, 1.15];
const EXCERPT_SECONDS: usize = 4;
const RATE: u32 = 48_000;

fn evidence_dir() -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../docs/evidence/l2-stretch-ab");
    std::fs::create_dir_all(&dir).expect("create evidence dir");
    dir
}

/// Crest factor (peak / RMS) in dB: high for sharp transients, low when a
/// stretch smears them. Measured on the left channel.
fn crest_db(samples: &[[f32; 2]]) -> f32 {
    let mut peak = 0.0_f32;
    let mut sumsq = 0.0_f64;
    for s in samples {
        peak = peak.max(s[0].abs());
        sumsq += f64::from(s[0]) * f64::from(s[0]);
    }
    let rms = (sumsq / samples.len().max(1) as f64).sqrt() as f32;
    if rms > 0.0 && peak > 0.0 {
        20.0 * (peak / rms).log10()
    } else {
        0.0
    }
}

fn rms(samples: &[[f32; 2]]) -> f32 {
    let sumsq: f64 = samples.iter().map(|s| f64::from(s[0]) * f64::from(s[0])).sum();
    (sumsq / samples.len().max(1) as f64).sqrt() as f32
}

/// Crude high-band energy fraction (energy above ~6 kHz via a one-pole HP
/// difference proxy): a warbly/dull stretch loses HF; a clean one keeps it.
fn hf_fraction(samples: &[[f32; 2]]) -> f32 {
    let mut prev = 0.0_f32;
    let mut hf = 0.0_f64;
    let mut total = 0.0_f64;
    for s in samples {
        let x = s[0];
        let d = x - prev; // first difference emphasizes highs
        prev = x;
        hf += f64::from(d) * f64::from(d);
        total += f64::from(x) * f64::from(x);
    }
    if total > 0.0 {
        (hf / total) as f32
    } else {
        0.0
    }
}

fn write_excerpt(dir: &Path, name: &str, samples: &[[f32; 2]]) -> Result<u64, String> {
    let frames = (EXCERPT_SECONDS * RATE as usize).min(samples.len());
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: RATE,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let path = dir.join(name);
    let mut w = hound::WavWriter::create(&path, spec).map_err(|e| e.to_string())?;
    for s in &samples[..frames] {
        // Mono sum, dithered-free straight quantization (evidence only).
        let v = ((s[0] + s[1]) * 0.5).clamp(-1.0, 1.0);
        w.write_sample((v * 32_767.0).round() as i16)
            .map_err(|e| e.to_string())?;
    }
    w.finalize().map_err(|e| e.to_string())?;
    let bytes = std::fs::metadata(&path).map_err(|e| e.to_string())?.len();
    Ok(bytes)
}

fn run_source(dir: &Path, label: &str, input: &[[f32; 2]]) -> Result<(), String> {
    println!("\n== source: {label} ({} frames, {:.2}s) ==", input.len(), input.len() as f32 / RATE as f32);
    println!("  in  crest={:.1}dB rms={:.3} hf={:.4}", crest_db(input), rms(input), hf_fraction(input));
    for ratio in RATIOS {
        let mut ss = SignalsmithStretcher::new(RATE);
        let mut ws = WsolaStretcher;
        let ss_out = ss.stretch(input, ratio);
        let ws_out = ws.stretch(input, ratio);

        let want = if is_identity(ratio) {
            input.len() as u64
        } else {
            stretched_len(input.len() as u64, ratio)
        };
        assert_eq!(ss_out.len() as u64, want, "signalsmith length at {ratio}");
        assert_eq!(ws_out.len() as u64, want, "wsola length at {ratio}");

        // Identity MUST be bit-exact bypass for both.
        if is_identity(ratio) {
            let ss_exact = ss_out.iter().zip(input).all(|(a, b)| a[0].to_bits() == b[0].to_bits());
            let ws_exact = ws_out.iter().zip(input).all(|(a, b)| a[0].to_bits() == b[0].to_bits());
            println!(
                "  1.00x IDENTITY  signalsmith bit_exact={ss_exact}  wsola bit_exact={ws_exact}"
            );
            assert!(ss_exact && ws_exact, "identity must be bit-exact bypass");
            continue;
        }

        println!(
            "  {ratio:.2}x  signalsmith: crest={:.1}dB rms={:.3} hf={:.4} | wsola: crest={:.1}dB rms={:.3} hf={:.4}",
            crest_db(&ss_out), rms(&ss_out), hf_fraction(&ss_out),
            crest_db(&ws_out), rms(&ws_out), hf_fraction(&ws_out),
        );
        let rtag = format!("{:03}", (ratio * 100.0).round() as u32);
        let b1 = write_excerpt(dir, &format!("{label}_signalsmith_{rtag}.wav"), &ss_out)?;
        let b2 = write_excerpt(dir, &format!("{label}_wsola_{rtag}.wav"), &ws_out)?;
        for (n, b) in [(format!("{label}_signalsmith_{rtag}.wav"), b1), (format!("{label}_wsola_{rtag}.wav"), b2)] {
            if b > 400 * 1024 {
                return Err(format!("excerpt {n} is {b} bytes, over the 400 KB cap"));
            }
        }
    }
    Ok(())
}

fn main() -> Result<(), String> {
    let fixtures_dir = fixtures::repo_fixtures_dir();
    fixtures::ensure(&fixtures_dir)?;
    let dir = evidence_dir();

    // Two hard cases: a click track (transients: reveals smear/pre-echo) and
    // an exponential sweep (tonal: reveals warble/phasiness).
    let click = load_wav_stereo_48k(&fixtures_dir.join("click_120bpm_48k_stereo.wav"))?;
    let sweep = load_wav_stereo_48k(&fixtures_dir.join("sweep_48k_stereo.wav"))?;

    // ~7 s input windows so 0.85x output still fills the 4 s excerpt.
    let take = 7 * RATE as usize;
    let click_in = &click.samples[..take.min(click.samples.len())];
    let sweep_in = &sweep.samples[..take.min(sweep.samples.len())];

    run_source(&dir, "click120", click_in)?;
    run_source(&dir, "sweep", sweep_in)?;

    println!("\nexcerpts written to {}", dir.display());
    Ok(())
}
