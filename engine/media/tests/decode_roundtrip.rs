//! Truthful rate-stamping + decode determinism.
//!
//! Pins the "DJ 44.1k lesson" (see src/decode.rs docs): a 44.1 kHz source
//! must resample to the target rate, never get relabeled/played back 8.8%
//! fast by assuming source rate == target rate. Also covers ACCEPTANCE's
//! "decode round-trip hash-stable": decoding the same file twice produces
//! byte-identical PCM, and hashing the same source file twice produces the
//! same content hash.

use media::decode::decode_to_stereo;
use media::hash::hash_file;

fn write_test_wav(path: &std::path::Path, sample_rate: u32, seconds: f64) {
    let spec = hound::WavSpec { channels: 2, sample_rate, bits_per_sample: 32, sample_format: hound::SampleFormat::Float };
    let mut writer = hound::WavWriter::create(path, spec).unwrap();
    let n = (sample_rate as f64 * seconds) as usize;
    for i in 0..n {
        let t = i as f32 / sample_rate as f32;
        let s = (2.0 * std::f32::consts::PI * 440.0 * t).sin() * 0.5;
        writer.write_sample(s).unwrap();
        writer.write_sample(s).unwrap();
    }
    writer.finalize().unwrap();
}

fn scratch_dir(label: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("media-crate-decode-test-{label}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn a_44_1k_file_resamples_to_48k_truthfully() {
    let dir = scratch_dir("441");
    let path = dir.join("tone_44100.wav");
    write_test_wav(&path, 44_100, 2.0);

    let decoded = decode_to_stereo(&path, 48_000).unwrap();

    assert_eq!(decoded.sample_rate, 48_000, "sample_rate must be stamped with the rate the samples ACTUALLY are");
    assert_eq!(decoded.source_sample_rate, 44_100);

    // If the engine wrongly treated 44.1k samples as 48k without
    // resampling (the DJ lesson bug), 2.0s of 44.1k source (88200 frames)
    // would play back as if it were 88200/48000 = 1.8375s -- 8.84% fast. A
    // correct resample keeps duration truthful (~2.0s at the stamped rate).
    let duration = decoded.duration_seconds();
    let naive_wrong_duration = 88_200.0 / 48_000.0;
    assert!(
        (duration - 2.0).abs() < 0.01,
        "duration drifted to {duration}s (expected ~2.0s); a naive rate-relabel would read ~{naive_wrong_duration:.4}s"
    );
}

#[test]
fn same_rate_decode_needs_no_resample_and_keeps_exact_frame_count() {
    let dir = scratch_dir("48k");
    let path = dir.join("tone_48000.wav");
    write_test_wav(&path, 48_000, 1.0);

    let decoded = decode_to_stereo(&path, 48_000).unwrap();
    assert_eq!(decoded.sample_rate, 48_000);
    assert_eq!(decoded.source_sample_rate, 48_000);
    assert_eq!(decoded.frames.len(), 48_000);
}

#[test]
fn decode_is_deterministic_across_repeated_calls() {
    let dir = scratch_dir("determinism");
    let path = dir.join("tone.wav");
    write_test_wav(&path, 44_100, 0.5);

    let a = decode_to_stereo(&path, 48_000).unwrap();
    let b = decode_to_stereo(&path, 48_000).unwrap();
    assert_eq!(a.frames.len(), b.frames.len());
    assert_eq!(a.frames, b.frames, "decode must be deterministic: same file decoded twice must produce identical PCM");
}

#[test]
fn source_file_content_hash_is_stable() {
    let dir = scratch_dir("hash");
    let path = dir.join("tone.wav");
    write_test_wav(&path, 48_000, 0.25);

    let h1 = hash_file(&path).unwrap();
    let h2 = hash_file(&path).unwrap();
    assert_eq!(h1, h2);
    assert_eq!(h1.len(), 64, "blake3 hex digest should be 64 chars");
}

#[test]
fn mono_source_is_duplicated_to_both_channels() {
    let dir = scratch_dir("mono");
    let path = dir.join("mono.wav");
    let spec = hound::WavSpec { channels: 1, sample_rate: 48_000, bits_per_sample: 32, sample_format: hound::SampleFormat::Float };
    let mut writer = hound::WavWriter::create(&path, spec).unwrap();
    for i in 0..48_000usize {
        let t = i as f32 / 48_000.0;
        writer.write_sample((2.0 * std::f32::consts::PI * 220.0 * t).sin() * 0.5).unwrap();
    }
    writer.finalize().unwrap();

    let decoded = decode_to_stereo(&path, 48_000).unwrap();
    assert_eq!(decoded.source_channels, 1);
    for frame in decoded.frames.iter().take(100) {
        assert_eq!(frame[0], frame[1], "mono source must be duplicated to L and R");
    }
}
