//! Symphonia-based decode service: wav/flac/mp3/aac-lc/alac/ogg -> stereo
//! f32 at a caller-chosen target rate, with truthful rate stamping.
//!
//! Truthful rate stamping (the DJ 44.1k lesson, carried into this crate
//! from `engine/render/src/media.rs`'s P0-B seed module): a 44.1 kHz file
//! must never be treated as if it were already at the target rate. Anything
//! not already at `target_sample_rate` is resampled with rubato
//! windowed-sinc at load; `DecodedAudio::sample_rate` is always the rate
//! the samples in `frames` ACTUALLY are, and `source_sample_rate` is kept
//! separately for provenance. See `tests/decode_roundtrip.rs` for the
//! pinned regression test.
//!
//! Multichannel note (documented simplification, not a silent gap): mono
//! sources are duplicated to both channels; sources with more than 2
//! channels take the first two (L/R) and drop the rest. A full ITU
//! downmix matrix for surround sources is out of v1 scope -- flagged in
//! this lane's report, not invented.

use std::path::{Path, PathBuf};

use rubato::{Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction};
use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;

use crate::error::MediaError;

pub struct DecodedAudio {
    pub frames: Vec<[f32; 2]>,
    /// The rate `frames` ACTUALLY are (== the requested target rate).
    pub sample_rate: u32,
    /// The source file's native rate, kept for provenance even though the
    /// samples have already been converted to `sample_rate`.
    pub source_sample_rate: u32,
    pub source_channels: u16,
    pub path: PathBuf,
}

impl DecodedAudio {
    pub fn duration_seconds(&self) -> f64 {
        self.frames.len() as f64 / self.sample_rate as f64
    }
}

pub fn decode_to_stereo(path: &Path, target_sample_rate: u32) -> Result<DecodedAudio, MediaError> {
    let file = std::fs::File::open(path).map_err(|e| MediaError::Io(format!("open {}: {e}", path.display())))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let fmt_opts = FormatOptions::default();
    let meta_opts = MetadataOptions::default();
    let dec_opts = AudioDecoderOptions::default();

    let mut format = symphonia::default::get_probe()
        .probe(&hint, mss, fmt_opts, meta_opts)
        .map_err(|e| MediaError::Decode(format!("probe {}: {e}", path.display())))?;

    let track = format
        .default_track(TrackType::Audio)
        .ok_or_else(|| MediaError::Decode(format!("no audio track in {}", path.display())))?;
    let audio_params = track
        .codec_params
        .as_ref()
        .and_then(|p| p.audio())
        .ok_or_else(|| MediaError::Decode(format!("no audio codec params in {}", path.display())))?;
    let source_sample_rate =
        audio_params.sample_rate.ok_or_else(|| MediaError::Decode(format!("unknown sample rate in {}", path.display())))?;
    let source_channels = audio_params.channels.as_ref().map(|c| c.count() as u16).unwrap_or(1);
    let mut decoder = symphonia::default::get_codecs()
        .make_audio_decoder(audio_params, &dec_opts)
        .map_err(|e| MediaError::Decode(format!("no decoder for {}: {e}", path.display())))?;
    // `track` (and the codec_params/audio_params borrows of `format`
    // derived from it) must not outlive this point: `format.next_packet()`
    // below needs `&mut format`. `track_id` is copied out so nothing keeps
    // borrowing `format`.
    let track_id = track.id;

    let mut interleaved: Vec<f32> = Vec::new();
    let mut scratch: Vec<f32> = Vec::new();
    loop {
        let packet = match format.next_packet() {
            Ok(Some(p)) => p,
            Ok(None) => break,
            Err(SymphoniaError::IoError(_)) => break,
            Err(e) => return Err(MediaError::Decode(format!("demux {}: {e}", path.display()))),
        };
        if packet.track_id != track_id {
            continue;
        }
        match decoder.decode(&packet) {
            Ok(audio_buf) => {
                scratch.clear();
                scratch.resize(audio_buf.samples_interleaved(), 0.0);
                audio_buf.copy_to_slice_interleaved(&mut scratch);
                interleaved.extend_from_slice(&scratch);
            }
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(e) => return Err(MediaError::Decode(format!("decode {}: {e}", path.display()))),
        }
    }

    if interleaved.is_empty() {
        return Err(MediaError::Decode(format!("no samples decoded from {}", path.display())));
    }

    let channels = source_channels.max(1) as usize;
    let mut stereo_frames: Vec<[f32; 2]> = Vec::with_capacity(interleaved.len() / channels + 1);
    for frame in interleaved.chunks(channels) {
        let left = frame.first().copied().unwrap_or(0.0);
        let right = if channels >= 2 { frame.get(1).copied().unwrap_or(left) } else { left };
        stereo_frames.push([left, right]);
    }

    let frames = if source_sample_rate == target_sample_rate {
        stereo_frames
    } else {
        resample_stereo_sinc(&stereo_frames, source_sample_rate, target_sample_rate)?
    };

    Ok(DecodedAudio { frames, sample_rate: target_sample_rate, source_sample_rate, source_channels, path: path.to_path_buf() })
}

/// Windowed-sinc SRC (control-thread only, never a render callback).
/// Delay-compensated via `Resampler::output_delay` and trimmed to the exact
/// rational length so durations stay truthful. Adapted in spirit from
/// `engine/render/src/media.rs::resample_stereo_sinc` (read-only reference,
/// owned by lane L2/L1): this is an independent reimplementation inside
/// `engine/media`, not a shared dependency, since this lane may not edit
/// `render`.
fn resample_stereo_sinc(input: &[[f32; 2]], src_rate: u32, dst_rate: u32) -> Result<Vec<[f32; 2]>, MediaError> {
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
    let mut resampler =
        SincFixedIn::<f32>::new(ratio, 2.0, params, CHUNK, 2).map_err(|e| MediaError::Decode(format!("resampler init: {e}")))?;
    let delay = resampler.output_delay();
    let expected_len = ((input.len() as u128 * u128::from(dst_rate) + u128::from(src_rate) / 2) / u128::from(src_rate)) as usize;

    let mut left: Vec<f32> = Vec::with_capacity(input.len());
    let mut right: Vec<f32> = Vec::with_capacity(input.len());
    for frame in input {
        left.push(frame[0]);
        right.push(frame[1]);
    }

    let mut out_left: Vec<f32> = Vec::with_capacity(expected_len + delay + CHUNK);
    let mut out_right: Vec<f32> = Vec::with_capacity(expected_len + delay + CHUNK);
    let mut cursor = 0usize;
    while cursor + CHUNK <= left.len() {
        let chunk = [&left[cursor..cursor + CHUNK], &right[cursor..cursor + CHUNK]];
        let out = resampler.process(&chunk, None).map_err(|e| MediaError::Decode(format!("resample: {e}")))?;
        out_left.extend_from_slice(&out[0]);
        out_right.extend_from_slice(&out[1]);
        cursor += CHUNK;
    }
    if cursor < left.len() {
        let chunk = [&left[cursor..], &right[cursor..]];
        let out = resampler.process_partial(Some(&chunk), None).map_err(|e| MediaError::Decode(format!("resample tail: {e}")))?;
        out_left.extend_from_slice(&out[0]);
        out_right.extend_from_slice(&out[1]);
    }
    while out_left.len() < delay + expected_len {
        let out = resampler.process_partial::<&[f32]>(None, None).map_err(|e| MediaError::Decode(format!("resample flush: {e}")))?;
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
    while result.len() < expected_len {
        result.push([0.0, 0.0]);
    }
    Ok(result)
}
