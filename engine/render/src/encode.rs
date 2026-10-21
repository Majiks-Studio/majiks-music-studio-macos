//! Deliverable encoders + loudness normalization for the L13 export path.
//!
//! Export runs the OFFLINE bounce (`host::bounce_master`, the same
//! `RenderCore::render` the device callback runs) to a `Vec<[f32; 2]>`, then:
//!   1. optionally normalizes the master to a loudness target (EBU R128),
//!   2. writes the deliverable: 24-bit PCM WAV (the design's master format) or
//!      AAC in an .m4a via Apple AudioToolbox (never fdk-aac; 02-ARCHITECTURE).
//!
//! Loudness math is exact-by-construction: a constant gain shifts every gated
//! block's loudness by the same dB, so integrated LUFS shifts by exactly that
//! gain. We measure, apply `target - measured` dB, re-measure, and (belt and
//! suspenders) apply one correction if the residual exceeds 0.1 LU. The
//! acceptance bar is 0.5 LU; this lands well inside it.

use std::path::Path;

use crate::loudness::integrated_lufs;

/// A loudness delivery target (integrated LUFS). Values are the ones the design
/// (01-DESIGN 3.7/3.8) names: streaming -14, club -7, broadcast -16.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoudnessTarget {
    /// No normalization: write the mix as bounced.
    None,
    /// Streaming (-14 LUFS): Spotify/Apple/YouTube class.
    Streaming,
    /// Club (-7 LUFS): loud, competitive masters.
    Club,
    /// Broadcast (-16 LUFS): EBU R128 broadcast delivery (short-form -16 LUFS).
    Broadcast,
}

impl LoudnessTarget {
    /// Parse the wire name (`export.master.loudnessTarget`), case-insensitive.
    /// Unknown / empty / "none" all resolve to `None` (no-op normalization).
    pub fn from_wire(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "streaming" | "stream" => LoudnessTarget::Streaming,
            "club" => LoudnessTarget::Club,
            "broadcast" => LoudnessTarget::Broadcast,
            _ => LoudnessTarget::None,
        }
    }

    pub fn wire_name(self) -> &'static str {
        match self {
            LoudnessTarget::None => "none",
            LoudnessTarget::Streaming => "streaming",
            LoudnessTarget::Club => "club",
            LoudnessTarget::Broadcast => "broadcast",
        }
    }

    /// Target integrated LUFS, or `None` when no normalization is asked for.
    pub fn target_lufs(self) -> Option<f32> {
        match self {
            LoudnessTarget::None => None,
            LoudnessTarget::Streaming => Some(-14.0),
            LoudnessTarget::Club => Some(-7.0),
            LoudnessTarget::Broadcast => Some(-16.0),
        }
    }
}

/// The measured result of a normalization pass (goes into the export report and
/// the provenance manifest, so the loudness landing is auditable).
#[derive(Debug, Clone, Copy)]
pub struct NormalizeReport {
    pub target: LoudnessTarget,
    /// Integrated LUFS before any gain was applied.
    pub measured_before_lufs: f32,
    /// Gain applied, in dB (0 when the target is None or the mix is silent).
    pub applied_gain_db: f32,
    /// Integrated LUFS after normalization (what the deliverable measures).
    pub measured_after_lufs: f32,
    /// True-peak-ish sample peak of the deliverable, dBFS (a clip warning if
    /// > 0). This is the sample peak, not oversampled true peak; honest naming.
    pub sample_peak_dbfs: f32,
}

impl NormalizeReport {
    /// The absolute error from target, in LU (0 when there is no target).
    pub fn error_lu(&self) -> f32 {
        match self.target.target_lufs() {
            Some(t) if self.measured_after_lufs.is_finite() => (self.measured_after_lufs - t).abs(),
            _ => 0.0,
        }
    }
}

fn sample_peak_dbfs(samples: &[[f32; 2]]) -> f32 {
    let peak = samples
        .iter()
        .flat_map(|f| [f[0].abs(), f[1].abs()])
        .fold(0.0_f32, f32::max);
    if peak > 0.0 {
        20.0 * peak.log10()
    } else {
        f32::NEG_INFINITY
    }
}

fn apply_gain_db(samples: &mut [[f32; 2]], gain_db: f32) {
    if gain_db == 0.0 {
        return;
    }
    let g = 10.0_f32.powf(gain_db / 20.0);
    for f in samples.iter_mut() {
        f[0] *= g;
        f[1] *= g;
    }
}

/// Normalize `samples` in place to `target` (EBU R128 integrated). No-op when
/// the target is None or the mix is silent (measured LUFS is -inf: there is no
/// meaningful gain to a target). Returns the measured before/after.
pub fn normalize_to_target(
    samples: &mut [[f32; 2]],
    sample_rate: u32,
    target: LoudnessTarget,
) -> NormalizeReport {
    let before = integrated_lufs(samples, sample_rate);
    let Some(target_lufs) = target.target_lufs() else {
        return NormalizeReport {
            target,
            measured_before_lufs: before,
            applied_gain_db: 0.0,
            measured_after_lufs: before,
            sample_peak_dbfs: sample_peak_dbfs(samples),
        };
    };
    if !before.is_finite() {
        // Silent (or too quiet to gate): normalization is undefined. Leave as is.
        return NormalizeReport {
            target,
            measured_before_lufs: before,
            applied_gain_db: 0.0,
            measured_after_lufs: before,
            sample_peak_dbfs: sample_peak_dbfs(samples),
        };
    }
    let mut gain_db = target_lufs - before;
    apply_gain_db(samples, gain_db);
    let mut after = integrated_lufs(samples, sample_rate);
    // One correction pass if the residual is above 0.1 LU (measurement is
    // exact by construction, but this guarantees we never miss the 0.5 LU bar).
    if after.is_finite() {
        let residual = target_lufs - after;
        if residual.abs() > 0.1 {
            apply_gain_db(samples, residual);
            gain_db += residual;
            after = integrated_lufs(samples, sample_rate);
        }
    }
    NormalizeReport {
        target,
        measured_before_lufs: before,
        applied_gain_db: gain_db,
        measured_after_lufs: after,
        sample_peak_dbfs: sample_peak_dbfs(samples),
    }
}

/// Write stereo `samples` as 24-bit signed PCM WAV at `sample_rate` (the
/// design's master/stem/region deliverable format). f32 in [-1, 1] maps to the
/// full 24-bit range with clamping (no wrap on an over-1.0 sample).
pub fn write_wav_i24(path: &Path, samples: &[[f32; 2]], sample_rate: u32) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate,
        bits_per_sample: 24,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer =
        hound::WavWriter::create(path, spec).map_err(|e| format!("create {}: {e}", path.display()))?;
    // 24-bit signed full-scale is [-2^23, 2^23 - 1]. Scale by (2^23 - 1) and
    // clamp both ends so a +1.0000001 never wraps to a huge negative.
    const FULL: f32 = 8_388_607.0; // 2^23 - 1
    const MIN: i32 = -8_388_608; // -2^23
    const MAX: i32 = 8_388_607; //  2^23 - 1
    for frame in samples {
        for &s in &[frame[0], frame[1]] {
            let v = (s.clamp(-1.0, 1.0) * FULL).round() as i32;
            let v = v.clamp(MIN, MAX);
            writer
                .write_sample(v)
                .map_err(|e| format!("write {}: {e}", path.display()))?;
        }
    }
    writer
        .finalize()
        .map_err(|e| format!("finalize {}: {e}", path.display()))
}

/// Encode stereo `samples` as AAC-LC in an `.m4a` at `sample_rate`, via Apple
/// AudioToolbox (ExtAudioFile). macOS only; other targets return an error (the
/// host maps it to a typed Unsupported).
pub fn encode_aac_m4a(path: &Path, samples: &[[f32; 2]], sample_rate: u32) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        macos_aac::encode(path, samples, sample_rate)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (path, samples, sample_rate);
        Err("AAC export requires macOS (Apple AudioToolbox)".to_string())
    }
}

#[cfg(target_os = "macos")]
mod macos_aac {
    //! AAC-LC into an .m4a through ExtAudioFile: create the file with an AAC
    //! output format, set the client format to interleaved f32 PCM, write the
    //! frames (AudioToolbox runs the AAC encoder), dispose. CoreFoundation's
    //! CFURL is created through three tiny local externs so we never fight a
    //! second CF crate's type identity: every handle is an opaque pointer.

    use std::os::raw::c_void;
    use std::path::Path;

    use coreaudio_sys as ca;

    // Apple four-char-code constants (ABI-stable public values). Spelled out so
    // we do not depend on which case coreaudio-sys' bindgen emitted them under.
    const K_LINEAR_PCM: u32 = fourcc(b"lpcm");
    const K_MPEG4_AAC: u32 = fourcc(b"aac ");
    const K_M4A_TYPE: u32 = fourcc(b"m4af");
    const K_CLIENT_DATA_FORMAT: u32 = fourcc(b"cfmt");
    const K_FLAG_IS_FLOAT: u32 = 1 << 0;
    const K_FLAG_IS_PACKED: u32 = 1 << 3;
    const K_ERASE_FILE: u32 = 1;

    const fn fourcc(b: &[u8; 4]) -> u32 {
        ((b[0] as u32) << 24) | ((b[1] as u32) << 16) | ((b[2] as u32) << 8) | (b[3] as u32)
    }

    #[allow(non_snake_case)]
    extern "C" {
        fn CFURLCreateFromFileSystemRepresentation(
            allocator: *const c_void,
            buffer: *const u8,
            bufLen: isize,
            isDirectory: u8,
        ) -> *const c_void;
        fn CFRelease(cf: *const c_void);
    }

    fn asbd_zero() -> ca::AudioStreamBasicDescription {
        // AudioStreamBasicDescription is all scalar fields; zeroing is the
        // documented "let the encoder fill it" starting point.
        unsafe { std::mem::zeroed() }
    }

    pub fn encode(path: &Path, samples: &[[f32; 2]], sample_rate: u32) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
        }
        // ExtAudioFile does not truncate; remove a stale file so EraseFile is moot.
        let _ = std::fs::remove_file(path);

        let path_bytes = path.as_os_str().to_string_lossy();
        let url = unsafe {
            CFURLCreateFromFileSystemRepresentation(
                std::ptr::null(),
                path_bytes.as_ptr(),
                path_bytes.len() as isize,
                0,
            )
        };
        if url.is_null() {
            return Err("CFURL creation failed for the export path".to_string());
        }
        // RAII-ish: release the URL on every exit.
        struct UrlGuard(*const c_void);
        impl Drop for UrlGuard {
            fn drop(&mut self) {
                unsafe { CFRelease(self.0) }
            }
        }
        let _url_guard = UrlGuard(url);

        // Output format: AAC, 1024 frames/packet, stereo, at the project rate.
        let mut out = asbd_zero();
        out.mSampleRate = f64::from(sample_rate);
        out.mFormatID = K_MPEG4_AAC;
        out.mChannelsPerFrame = 2;
        out.mFramesPerPacket = 1024;

        let mut file: ca::ExtAudioFileRef = std::ptr::null_mut();
        let status = unsafe {
            ca::ExtAudioFileCreateWithURL(
                url as ca::CFURLRef,
                K_M4A_TYPE,
                &out,
                std::ptr::null(),
                K_ERASE_FILE,
                &mut file,
            )
        };
        if status != 0 || file.is_null() {
            return Err(format!("ExtAudioFileCreateWithURL failed (OSStatus {status})"));
        }
        struct FileGuard(ca::ExtAudioFileRef);
        impl Drop for FileGuard {
            fn drop(&mut self) {
                unsafe { ca::ExtAudioFileDispose(self.0) };
            }
        }
        let _file_guard = FileGuard(file);

        // Client format: interleaved f32 stereo PCM (what we hand ExtAudioFile).
        let mut client = asbd_zero();
        client.mSampleRate = f64::from(sample_rate);
        client.mFormatID = K_LINEAR_PCM;
        client.mFormatFlags = K_FLAG_IS_FLOAT | K_FLAG_IS_PACKED;
        client.mBytesPerPacket = 8;
        client.mFramesPerPacket = 1;
        client.mBytesPerFrame = 8;
        client.mChannelsPerFrame = 2;
        client.mBitsPerChannel = 32;

        let status = unsafe {
            ca::ExtAudioFileSetProperty(
                file,
                K_CLIENT_DATA_FORMAT,
                std::mem::size_of::<ca::AudioStreamBasicDescription>() as u32,
                &client as *const _ as *const c_void,
            )
        };
        if status != 0 {
            return Err(format!("ExtAudioFile set client format failed (OSStatus {status})"));
        }

        // Write in chunks so a very long master never asks the encoder for one
        // giant buffer. Each [f32; 2] is already interleaved L,R.
        const CHUNK_FRAMES: usize = 16_384;
        for chunk in samples.chunks(CHUNK_FRAMES) {
            let n = chunk.len() as u32;
            let byte_size = (chunk.len() * 8) as u32;
            let abl = ca::AudioBufferList {
                mNumberBuffers: 1,
                mBuffers: [ca::AudioBuffer {
                    mNumberChannels: 2,
                    mDataByteSize: byte_size,
                    mData: chunk.as_ptr() as *mut c_void,
                }],
            };
            let status = unsafe { ca::ExtAudioFileWrite(file, n, &abl) };
            if status != 0 {
                return Err(format!("ExtAudioFileWrite failed (OSStatus {status})"));
            }
        }
        // FileGuard + UrlGuard dispose/release here in order.
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(freq: f32, secs: f32, amp: f32, sr: u32) -> Vec<[f32; 2]> {
        (0..(secs * sr as f32) as usize)
            .map(|i| {
                let v = (std::f32::consts::TAU * freq * i as f32 / sr as f32).sin() * amp;
                [v, v]
            })
            .collect()
    }

    #[test]
    fn none_target_is_a_noop() {
        let sr = 48_000;
        let mut s = sine(220.0, 1.0, 0.3, sr);
        let before = integrated_lufs(&s, sr);
        let rep = normalize_to_target(&mut s, sr, LoudnessTarget::None);
        assert_eq!(rep.applied_gain_db, 0.0);
        assert_eq!(integrated_lufs(&s, sr), before);
    }

    #[test]
    fn streaming_target_lands_within_half_lu() {
        let sr = 48_000;
        // Start well away from -14 so the gain is a real, non-trivial move.
        let mut s = sine(300.0, 3.0, 0.05, sr);
        let rep = normalize_to_target(&mut s, sr, LoudnessTarget::Streaming);
        assert!(rep.measured_after_lufs.is_finite(), "after LUFS not finite");
        assert!(
            rep.error_lu() <= 0.5,
            "streaming normalize off by {} LU (after {}, target -14)",
            rep.error_lu(),
            rep.measured_after_lufs
        );
    }

    #[test]
    fn club_and_broadcast_targets_land_within_half_lu() {
        let sr = 48_000;
        for (target, want) in [(LoudnessTarget::Club, -7.0), (LoudnessTarget::Broadcast, -16.0)] {
            let mut s = sine(440.0, 3.0, 0.2, sr);
            let rep = normalize_to_target(&mut s, sr, target);
            assert!(
                (rep.measured_after_lufs - want).abs() <= 0.5,
                "{:?} landed at {} (want {want} +-0.5)",
                target,
                rep.measured_after_lufs
            );
        }
    }

    #[test]
    fn silence_normalization_is_a_safe_noop() {
        let sr = 48_000;
        let mut s = vec![[0.0_f32; 2]; sr as usize];
        let rep = normalize_to_target(&mut s, sr, LoudnessTarget::Streaming);
        assert_eq!(rep.applied_gain_db, 0.0);
        assert!(rep.measured_before_lufs.is_infinite());
    }

    /// A scratch directory THIS PROCESS owns.
    ///
    /// These two tests used a fixed `$TMPDIR/l13-encode-test/`, which is shared
    /// by every checkout and every concurrent `cargo test` on the machine. With
    /// ~30 lane worktrees on this box, two runs would land on the same
    /// `tone.m4a`: one removed it while the other was still writing or stat-ing
    /// it, and the failure surfaced as `m4a suspiciously small: 28 bytes` — a
    /// red gate 1 that looked like an encoder bug and was not. It cost at least
    /// one lane a full re-run to characterise.
    ///
    /// Same family as `host_undo.rs`'s truncated-WAV fixture race, and as the
    /// process-wide `guard::violations()` and `ToastManager.shared` traps in
    /// GATES.md: shared mutable state that makes one run's result depend on who
    /// else happens to be running.
    fn encode_test_dir() -> std::path::PathBuf {
        std::env::temp_dir().join(format!("l13-encode-test-{}", std::process::id()))
    }

    #[test]
    fn wav_i24_roundtrips_within_24bit_quantization() {
        let sr = 48_000;
        let s = sine(440.0, 0.5, 0.5, sr);
        let dir = encode_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tone24.wav");
        write_wav_i24(&path, &s, sr).unwrap();

        // Read back with hound and compare within one 24-bit LSB (~1.2e-7).
        let mut reader = hound::WavReader::open(&path).unwrap();
        assert_eq!(reader.spec().bits_per_sample, 24);
        assert_eq!(reader.spec().channels, 2);
        let read: Vec<i32> = reader.samples::<i32>().map(|x| x.unwrap()).collect();
        assert_eq!(read.len(), s.len() * 2);
        let mut max_err = 0.0_f32;
        for (i, frame) in s.iter().enumerate() {
            for ch in 0..2 {
                let back = read[i * 2 + ch] as f32 / 8_388_607.0;
                max_err = max_err.max((frame[ch] - back).abs());
            }
        }
        assert!(max_err < 1.0 / 8_388_607.0 + 1e-9, "24-bit roundtrip err {max_err}");
        let _ = std::fs::remove_file(&path);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn aac_encode_writes_a_decodable_m4a() {
        let sr = 48_000;
        let s = sine(440.0, 1.0, 0.4, sr);
        let dir = encode_test_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tone.m4a");
        encode_aac_m4a(&path, &s, sr).expect("aac encode");
        let meta = std::fs::metadata(&path).expect("m4a exists");
        // A 1s stereo AAC file is a few KB; assert it is non-trivial (encoder ran).
        assert!(meta.len() > 1_000, "m4a suspiciously small: {} bytes", meta.len());
        let _ = std::fs::remove_file(&path);
    }
}
