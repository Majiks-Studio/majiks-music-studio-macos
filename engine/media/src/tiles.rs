//! Waveform peak tiles: min/max per bucket at a given zoom
//! (samples-per-pixel).
//!
//! Everything in this module is pure math over in-memory sample slices --
//! no file I/O, no threads -- so it compiles and runs on
//! wasm32-unknown-unknown as well as native targets. The disk cache and the
//! cancel-safe background job wrapper (which DO need std::fs / std::thread)
//! live in `tile_job` behind the `native` feature.

use serde::{Deserialize, Serialize};

use crate::error::MediaError;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct PeakPair {
    pub min: f32,
    pub max: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WaveformTile {
    pub zoom_samples_per_pixel: u32,
    pub left: Vec<PeakPair>,
    pub right: Vec<PeakPair>,
}

/// Min/max peak pairs for one channel at `samples_per_pixel`.
///
/// Deterministic by construction: bucket boundaries are fixed by sample
/// index (not by thread arrival order), and min/max are exact,
/// order-independent reductions in IEEE 754 (unlike float summation, which
/// is not exactly associative) -- so this would still be deterministic even
/// if parallelized, though it is not (a single pass over one track's peaks
/// at 3 zoom levels is cheap enough not to need it).
pub fn compute_peaks_mono(samples: &[f32], samples_per_pixel: usize) -> Vec<PeakPair> {
    let spp = samples_per_pixel.max(1);
    let mut out = Vec::with_capacity(samples.len() / spp + 1);
    for bucket in samples.chunks(spp) {
        if bucket.is_empty() {
            continue;
        }
        let mut mn = f32::INFINITY;
        let mut mx = f32::NEG_INFINITY;
        for &s in bucket {
            if s < mn {
                mn = s;
            }
            if s > mx {
                mx = s;
            }
        }
        out.push(PeakPair { min: mn, max: mx });
    }
    out
}

/// Stereo convenience wrapper over `compute_peaks_mono`.
pub fn compute_tile(stereo: &[[f32; 2]], samples_per_pixel: u32) -> WaveformTile {
    let left: Vec<f32> = stereo.iter().map(|f| f[0]).collect();
    let right: Vec<f32> = stereo.iter().map(|f| f[1]).collect();
    WaveformTile {
        zoom_samples_per_pixel: samples_per_pixel,
        left: compute_peaks_mono(&left, samples_per_pixel as usize),
        right: compute_peaks_mono(&right, samples_per_pixel as usize),
    }
}

/// Fixed little-endian binary layout for the tile cache: magic, version,
/// zoom, per-channel bucket count, then `[min:f32, max:f32]` pairs, left
/// channel then right. Hand-rolled rather than JSON so a cache file for a
/// long song at a fine zoom stays compact; the layout is simple enough not
/// to need a serialization-framework dependency.
const TILE_MAGIC: &[u8; 4] = b"MMTL";
const TILE_VERSION: u16 = 1;

pub fn encode_tile(tile: &WaveformTile) -> Vec<u8> {
    let mut out = Vec::with_capacity(16 + (tile.left.len() + tile.right.len()) * 8);
    out.extend_from_slice(TILE_MAGIC);
    out.extend_from_slice(&TILE_VERSION.to_le_bytes());
    out.extend_from_slice(&[0u8; 2]); // reserved/alignment
    out.extend_from_slice(&tile.zoom_samples_per_pixel.to_le_bytes());
    out.extend_from_slice(&(tile.left.len() as u32).to_le_bytes());
    out.extend_from_slice(&(tile.right.len() as u32).to_le_bytes());
    for p in &tile.left {
        out.extend_from_slice(&p.min.to_le_bytes());
        out.extend_from_slice(&p.max.to_le_bytes());
    }
    for p in &tile.right {
        out.extend_from_slice(&p.min.to_le_bytes());
        out.extend_from_slice(&p.max.to_le_bytes());
    }
    out
}

pub fn decode_tile(bytes: &[u8]) -> Result<WaveformTile, MediaError> {
    if bytes.len() < 16 {
        return Err(MediaError::TileCache("tile cache: truncated header".to_string()));
    }
    if &bytes[0..4] != TILE_MAGIC {
        return Err(MediaError::TileCache("tile cache: bad magic".to_string()));
    }
    let version = u16::from_le_bytes([bytes[4], bytes[5]]);
    if version != TILE_VERSION {
        return Err(MediaError::TileCache(format!("tile cache: unsupported version {version}")));
    }
    let zoom = u32::from_le_bytes(bytes[8..12].try_into().unwrap());
    let left_len = u32::from_le_bytes(bytes[12..16].try_into().unwrap()) as usize;
    // right_len lives at bytes[16..20]; read it, then the two payload runs.
    if bytes.len() < 20 {
        return Err(MediaError::TileCache("tile cache: truncated header".to_string()));
    }
    let right_len = u32::from_le_bytes(bytes[16..20].try_into().unwrap()) as usize;
    let mut pos = 20usize;
    let read_peaks = |pos: &mut usize, count: usize, bytes: &[u8]| -> Result<Vec<PeakPair>, MediaError> {
        let mut out = Vec::with_capacity(count);
        for _ in 0..count {
            if *pos + 8 > bytes.len() {
                return Err(MediaError::TileCache("tile cache: truncated payload".to_string()));
            }
            let min = f32::from_le_bytes(bytes[*pos..*pos + 4].try_into().unwrap());
            let max = f32::from_le_bytes(bytes[*pos + 4..*pos + 8].try_into().unwrap());
            out.push(PeakPair { min, max });
            *pos += 8;
        }
        Ok(out)
    };
    let left = read_peaks(&mut pos, left_len, bytes)?;
    let right = read_peaks(&mut pos, right_len, bytes)?;
    Ok(WaveformTile { zoom_samples_per_pixel: zoom, left, right })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bucket_boundaries_are_correct() {
        let stereo: Vec<[f32; 2]> = (0..1000).map(|i| [i as f32, -(i as f32)]).collect();
        let tile = compute_tile(&stereo, 100);
        assert_eq!(tile.left.len(), 10);
        assert_eq!(tile.left[0].max, 99.0);
        assert_eq!(tile.left[0].min, 0.0);
        assert_eq!(tile.right[0].min, -99.0);
        assert_eq!(tile.right[0].max, 0.0);
    }

    #[test]
    fn generation_is_deterministic_for_fixed_input_and_zoom() {
        let mut stereo = Vec::new();
        for i in 0..48_000usize {
            let t = i as f32 / 48_000.0;
            let s = (2.0 * std::f32::consts::PI * 220.0 * t).sin() * 0.7;
            stereo.push([s, -s]);
        }
        for zoom in [64u32, 256, 1024] {
            let a = compute_tile(&stereo, zoom);
            let b = compute_tile(&stereo, zoom);
            assert_eq!(encode_tile(&a), encode_tile(&b), "tile bytes must be identical for the same asset+zoom, zoom={zoom}");
        }
    }

    #[test]
    fn encode_decode_round_trips() {
        let stereo: Vec<[f32; 2]> = (0..10_000).map(|i| [(i as f32).sin(), (i as f32).cos()]).collect();
        let tile = compute_tile(&stereo, 256);
        let bytes = encode_tile(&tile);
        let back = decode_tile(&bytes).unwrap();
        assert_eq!(tile, back);
    }

    #[test]
    fn decode_rejects_bad_magic() {
        let bytes = vec![0u8; 20];
        assert!(decode_tile(&bytes).is_err());
    }

    #[test]
    fn empty_input_produces_empty_tile() {
        let tile = compute_tile(&[], 256);
        assert!(tile.left.is_empty());
        assert!(tile.right.is_empty());
    }
}
