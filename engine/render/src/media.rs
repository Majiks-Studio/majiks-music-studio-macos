//! Minimal media loading for the P0-B proof: WAV via hound, sample-rate
//! conversion via rubato windowed-sinc (the DJ linear-interp hazard, fixed).
//!
//! This module seeds the future `media` crate (symphonia decode, tiles,
//! loudness); P0-B only needs WAV fixtures loaded truthfully.
//!
//! Truthful rate stamping (DJ decode_to_stereo_48k lesson): anything not at
//! the engine rate is resampled at load, `sample_rate` is stamped with the
//! rate the samples actually are, and the source rate is kept for provenance.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use rubato::{
    Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction,
};

use crate::rt::ENGINE_SAMPLE_RATE;

pub struct AudioBuf {
    pub samples: Box<[[f32; 2]]>,
    /// The rate `samples` really are (engine rate after load).
    pub sample_rate: u32,
    pub source_sample_rate: u32,
    pub source_channels: u16,
    pub path: PathBuf,
}

impl AudioBuf {
    /// Test/probe helper: wrap synthetic samples already at the engine rate.
    pub fn from_samples(samples: Vec<[f32; 2]>, label: &str) -> Arc<Self> {
        Arc::new(Self {
            samples: samples.into_boxed_slice(),
            sample_rate: ENGINE_SAMPLE_RATE,
            source_sample_rate: ENGINE_SAMPLE_RATE,
            source_channels: 2,
            path: PathBuf::from(label),
        })
    }

    pub fn len_frames(&self) -> u64 {
        self.samples.len() as u64
    }
}

/// Load a WAV file, downmix/upmix to stereo, resample to the engine rate.
pub fn load_wav_stereo_48k(path: &Path) -> Result<AudioBuf, String> {
    let mut reader = hound::WavReader::open(path)
        .map_err(|e| format!("open {}: {e}", path.display()))?;
    let spec = reader.spec();
    let channels = spec.channels.max(1) as usize;

    let interleaved: Vec<f32> = match (spec.sample_format, spec.bits_per_sample) {
        (hound::SampleFormat::Float, 32) => reader
            .samples::<f32>()
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("read {}: {e}", path.display()))?,
        (hound::SampleFormat::Int, bits) if bits > 0 && bits <= 32 => {
            let scale = (1_i64 << (bits - 1)) as f32;
            reader
                .samples::<i32>()
                .map(|s| s.map(|v| v as f32 / scale))
                .collect::<Result<Vec<_>, _>>()
                .map_err(|e| format!("read {}: {e}", path.display()))?
        }
        (format, bits) => {
            return Err(format!(
                "unsupported wav format {format:?}/{bits} bit in {}",
                path.display()
            ))
        }
    };

    let mut frames: Vec<[f32; 2]> = Vec::with_capacity(interleaved.len() / channels + 1);
    for frame in interleaved.chunks(channels) {
        let left = frame.first().copied().unwrap_or(0.0);
        let right = frame.get(1).copied().unwrap_or(left);
        frames.push([left, right]);
    }

    let source_rate = spec.sample_rate;
    let samples = if source_rate == ENGINE_SAMPLE_RATE {
        frames
    } else {
        resample_stereo_sinc(&frames, source_rate, ENGINE_SAMPLE_RATE)?
    };

    Ok(AudioBuf {
        samples: samples.into_boxed_slice(),
        sample_rate: ENGINE_SAMPLE_RATE,
        source_sample_rate: source_rate,
        source_channels: spec.channels,
        path: path.to_path_buf(),
    })
}

/// Windowed-sinc SRC (control thread only, never the render callback).
/// Output is delay-compensated via `Resampler::output_delay` and trimmed to
/// the exact rational length so durations stay truthful.
///
/// Used by the recording lander when the input device rate differs from the
/// project/engine rate (e.g. AMS-44 at 44.1 kHz while the engine runs at
/// 48 kHz). Callers MUST surface that resampling happened — never silent.
pub fn resample_stereo_sinc(
    input: &[[f32; 2]],
    src_rate: u32,
    dst_rate: u32,
) -> Result<Vec<[f32; 2]>, String> {
    if input.is_empty() {
        return Ok(Vec::new());
    }
    let ratio = f64::from(dst_rate) / f64::from(src_rate);
    let params = SincInterpolationParameters {
        sinc_len: 128,
        f_cutoff: 0.95,
        interpolation: SincInterpolationType::Linear,
        oversampling_factor: 256,
        window: WindowFunction::BlackmanHarris2,
    };
    const CHUNK: usize = 1024;
    let mut resampler = SincFixedIn::<f32>::new(ratio, 2.0, params, CHUNK, 2)
        .map_err(|e| format!("resampler init: {e}"))?;
    let delay = resampler.output_delay();
    let expected_len =
        ((input.len() as u128 * u128::from(dst_rate) + u128::from(src_rate) / 2)
            / u128::from(src_rate)) as usize;

    let mut left: Vec<f32> = Vec::with_capacity(input.len());
    let mut right: Vec<f32> = Vec::with_capacity(input.len());
    for frame in input {
        left.push(frame[0]);
        right.push(frame[1]);
    }

    let mut out_left: Vec<f32> = Vec::with_capacity(expected_len + delay + CHUNK);
    let mut out_right: Vec<f32> = Vec::with_capacity(expected_len + delay + CHUNK);
    let mut cursor = 0_usize;
    while cursor + CHUNK <= left.len() {
        let chunk = [&left[cursor..cursor + CHUNK], &right[cursor..cursor + CHUNK]];
        let out = resampler
            .process(&chunk, None)
            .map_err(|e| format!("resample: {e}"))?;
        out_left.extend_from_slice(&out[0]);
        out_right.extend_from_slice(&out[1]);
        cursor += CHUNK;
    }
    if cursor < left.len() {
        let chunk = [&left[cursor..], &right[cursor..]];
        let out = resampler
            .process_partial(Some(&chunk), None)
            .map_err(|e| format!("resample tail: {e}"))?;
        out_left.extend_from_slice(&out[0]);
        out_right.extend_from_slice(&out[1]);
    }
    // Flush the filter tail until we have delay + expected frames.
    while out_left.len() < delay + expected_len {
        let out = resampler
            .process_partial::<&[f32]>(None, None)
            .map_err(|e| format!("resample flush: {e}"))?;
        if out[0].is_empty() {
            break;
        }
        out_left.extend_from_slice(&out[0]);
        out_right.extend_from_slice(&out[1]);
    }

    let end = (delay + expected_len).min(out_left.len());
    let mut result = Vec::with_capacity(end.saturating_sub(delay));
    for idx in delay..end {
        result.push([out_left[idx], out_right[idx]]);
    }
    // Zero-pad the (rare) shortfall so length stays exactly rational.
    while result.len() < expected_len {
        result.push([0.0, 0.0]);
    }
    Ok(result)
}

/// Write a stereo f32 WAV (bounce output, null-test evidence files).
pub fn write_wav_f32(path: &Path, samples: &[[f32; 2]], sample_rate: u32) -> Result<(), String> {
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut writer =
        hound::WavWriter::create(path, spec).map_err(|e| format!("create {}: {e}", path.display()))?;
    for frame in samples {
        writer
            .write_sample(frame[0])
            .and_then(|_| writer.write_sample(frame[1]))
            .map_err(|e| format!("write {}: {e}", path.display()))?;
    }
    writer
        .finalize()
        .map_err(|e| format!("finalize {}: {e}", path.display()))
}
