//! Deterministic WAV fixtures, generated on demand and pinned by blake3
//! hashes in fixtures/MANIFEST.json (committed). The wav files themselves
//! are gitignored; `gen-fixtures` recreates them bit-identically.
//!
//! Set: sine sweeps (48 kHz and a 44.1 kHz one for the SRC path), click
//! tracks at 92/120/174 BPM, and one mono tone (mono upmix path).
//!
//! # Crash- and race-safety
//!
//! Fixture dirs are SHARED: `engine/fixtures` across every test binary in
//! the workspace, `$CARGO_TARGET_TMPDIR/<name>` across the parallel test
//! threads of one binary — and across processes when lanes share a target
//! dir. Two rules keep that safe:
//!
//! - **Writes are atomic.** Every file is streamed to a uniquely named
//!   dot-temp in the same directory and `rename`d into place (atomic on
//!   APFS/POSIX). A reader can observe the old complete file or the new
//!   complete file, NEVER a partial one. Racing generators are benign by
//!   design: generation is deterministic, so every writer renames
//!   byte-identical content — last-writer-wins with identical bytes. A
//!   SIGKILLed writer can only leave a stray dot-temp behind (never a torn
//!   fixture); temps are ignored by every reader and overwritten paths
//!   stay valid.
//! - **`ensure` validates before trusting.** A fixture that is missing,
//!   truncated, unfinalized (hound patches RIFF/data sizes only on
//!   finalize, so a killed writer's file parses as a well-formed EMPTY
//!   wav — the "source click has zero length" incident), or stale is
//!   regenerated instead of surfacing as a misleading downstream error.
//!   Only true divergence between this generator and MANIFEST.json stays
//!   a hard error.

use std::collections::BTreeMap;
use std::f64::consts::TAU;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};

pub struct FixtureSpec {
    pub name: &'static str,
    pub sample_rate: u32,
    pub channels: u16,
    pub seconds: f64,
    pub kind: FixtureKind,
}

pub enum FixtureKind {
    /// Exponential sine sweep f0 -> f1.
    Sweep { f0: f64, f1: f64 },
    /// Click track: short decaying tone bursts on the beat grid, accented
    /// downbeat every 4 beats (4/4).
    Click { bpm: f64 },
    /// Steady tone with 10 ms edge ramps.
    Tone { hz: f64 },
}

pub const FIXTURES: &[FixtureSpec] = &[
    FixtureSpec {
        name: "sweep_48k_stereo.wav",
        sample_rate: 48_000,
        channels: 2,
        seconds: 8.0,
        kind: FixtureKind::Sweep {
            f0: 30.0,
            f1: 8_000.0,
        },
    },
    FixtureSpec {
        name: "sweep_44k1_stereo.wav",
        sample_rate: 44_100,
        channels: 2,
        seconds: 6.0,
        kind: FixtureKind::Sweep {
            f0: 40.0,
            f1: 6_000.0,
        },
    },
    FixtureSpec {
        name: "click_92bpm_48k_stereo.wav",
        sample_rate: 48_000,
        channels: 2,
        seconds: 8.0,
        kind: FixtureKind::Click { bpm: 92.0 },
    },
    FixtureSpec {
        name: "click_120bpm_48k_stereo.wav",
        sample_rate: 48_000,
        channels: 2,
        seconds: 8.0,
        kind: FixtureKind::Click { bpm: 120.0 },
    },
    FixtureSpec {
        name: "click_174bpm_48k_stereo.wav",
        sample_rate: 48_000,
        channels: 2,
        seconds: 8.0,
        kind: FixtureKind::Click { bpm: 174.0 },
    },
    FixtureSpec {
        name: "tone_440_48k_mono.wav",
        sample_rate: 48_000,
        channels: 1,
        seconds: 4.0,
        kind: FixtureKind::Tone { hz: 440.0 },
    },
];

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Manifest {
    pub files: BTreeMap<String, String>,
}

/// Mono sample value at frame `i` for a spec (pure f64 math, deterministic).
fn sample_value(spec: &FixtureSpec, i: usize) -> f64 {
    let rate = f64::from(spec.sample_rate);
    let t = i as f64 / rate;
    match &spec.kind {
        FixtureKind::Sweep { f0, f1 } => {
            let duration = spec.seconds;
            let k = (f1 / f0).ln() / duration;
            // Exponential sweep phase: 2*pi*f0*(e^(k t)-1)/k.
            let phase = TAU * f0 * ((k * t).exp() - 1.0) / k;
            0.5 * phase.sin()
        }
        FixtureKind::Click { bpm } => {
            let beat_period = 60.0 / bpm;
            let beat_index = (t / beat_period).floor();
            let beat_time = t - beat_index * beat_period;
            let decay_seconds = 0.006;
            if beat_time < decay_seconds {
                let downbeat = (beat_index as u64) % 4 == 0;
                let (freq, amp) = if downbeat { (1_500.0, 0.9) } else { (2_000.0, 0.55) };
                let env = 1.0 - (beat_time / decay_seconds);
                amp * env * env * (TAU * freq * beat_time).sin()
            } else {
                0.0
            }
        }
        FixtureKind::Tone { hz } => {
            let ramp = 0.010;
            let duration = spec.seconds;
            let mut env = 1.0;
            if t < ramp {
                env = t / ramp;
            }
            if t > duration - ramp {
                env = ((duration - t) / ramp).max(0.0);
            }
            0.4 * env * (TAU * hz * t).sin()
        }
    }
}

/// Frames a complete fixture holds (all specs resolve to exact integers).
fn expected_frames(spec: &FixtureSpec) -> u64 {
    (spec.seconds * f64::from(spec.sample_rate)).round() as u64
}

/// Interleaved samples a complete fixture holds.
fn expected_samples(spec: &FixtureSpec) -> u64 {
    expected_frames(spec) * u64::from(spec.channels)
}

/// hound 3.5 writes a 44-byte canonical header for 16-bit PCM with one or
/// two channels; the byte length of a complete fixture is therefore exact.
/// Pinned by `pinned_generated_byte_lengths` in tests/fixtures_atomicity.rs
/// so a hound upgrade that changes the header layout fails loudly there.
const WAV_HEADER_LEN: u64 = 44;

fn expected_file_len(spec: &FixtureSpec) -> u64 {
    WAV_HEADER_LEN + expected_samples(spec) * 2
}

/// Cheap validity check (one stat + one header read) for trusting an
/// existing file. Catches every shape a killed or torn writer can leave:
/// - short file (hand/OS truncation, killed mid-data): byte length differs;
/// - full-length but unfinalized (killed between the last sample and
///   `finalize`): hound's create-time size placeholders make the header
///   declare 0 samples;
/// - wrong format entirely.
/// Content STALENESS (right shape, wrong bytes) is not this check's job —
/// `ensure` catches that against the blake3 manifest.
fn fixture_valid(spec: &FixtureSpec, path: &Path) -> bool {
    match fs::metadata(path) {
        Ok(meta) if meta.len() == expected_file_len(spec) => {}
        _ => return false,
    }
    let Ok(reader) = hound::WavReader::open(path) else {
        return false;
    };
    let s = reader.spec();
    s.channels == spec.channels
        && s.sample_rate == spec.sample_rate
        && s.bits_per_sample == 16
        && s.sample_format == hound::SampleFormat::Int
        && u64::from(reader.len()) == expected_samples(spec)
}

/// Distinguishes concurrent writers' temp files: pid separates processes,
/// the counter separates threads within one process.
static TMP_SEQ: AtomicU64 = AtomicU64::new(0);

/// A unique dot-temp name in the SAME directory as `path` (rename is only
/// atomic within a filesystem, and dot-names keep temps out of `*.wav`
/// globs and fixture reads).
fn unique_tmp_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("fixture");
    let seq = TMP_SEQ.fetch_add(1, Ordering::Relaxed);
    path.with_file_name(format!(".{name}.tmp-{}-{seq}", std::process::id()))
}

/// Stream the WAV for `spec` into `out` (temp location; not atomic itself).
fn write_wav(spec: &FixtureSpec, out: &Path) -> Result<(), String> {
    let wav_spec = hound::WavSpec {
        channels: spec.channels,
        sample_rate: spec.sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(out, wav_spec)
        .map_err(|e| format!("create {}: {e}", out.display()))?;
    let frames = expected_frames(spec) as usize;
    for i in 0..frames {
        let v = sample_value(spec, i);
        let q = (v.clamp(-1.0, 1.0) * 32_767.0).round() as i16;
        for _ in 0..spec.channels {
            writer
                .write_sample(q)
                .map_err(|e| format!("write {}: {e}", out.display()))?;
        }
    }
    writer
        .finalize()
        .map_err(|e| format!("finalize {}: {e}", out.display()))
}

/// Atomic fixture write: stream to a unique dot-temp in the same directory,
/// then `rename` over the final name. Readers can never observe a partial
/// file; racing writers converge because the content is deterministic
/// (last-writer-wins with identical bytes). On failure the temp is
/// best-effort removed; a SIGKILL can strand one, which no reader ever
/// opens.
fn generate_file(spec: &FixtureSpec, path: &Path) -> Result<(), String> {
    let tmp = unique_tmp_path(path);
    let result = write_wav(spec, &tmp).and_then(|()| {
        fs::rename(&tmp, path)
            .map_err(|e| format!("rename {} -> {}: {e}", tmp.display(), path.display()))
    });
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

fn hash_file(path: &Path) -> Result<String, String> {
    let bytes = fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    Ok(blake3::hash(&bytes).to_hex().to_string())
}

/// The repo fixtures directory (engine/fixtures), resolved from this crate.
pub fn repo_fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../fixtures")
}

/// Generate every fixture into `dir`, returning (name, blake3) pairs.
///
/// Always regenerates (atomically), never trusts what is on disk — so
/// `gen-fixtures --write-manifest` can never publish stale hashes and a
/// target-dir fixture set can never lag the generator code. Concurrent
/// callers (parallel test threads/processes sharing `dir`) are safe: every
/// write lands by atomic rename with byte-identical content.
pub fn generate_all(dir: &Path) -> Result<Manifest, String> {
    fs::create_dir_all(dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    let mut files = BTreeMap::new();
    for spec in FIXTURES {
        let path = dir.join(spec.name);
        generate_file(spec, &path)?;
        files.insert(spec.name.to_string(), hash_file(&path)?);
    }
    Ok(Manifest { files })
}

pub fn manifest_path(dir: &Path) -> PathBuf {
    dir.join("MANIFEST.json")
}

pub fn write_manifest(dir: &Path, manifest: &Manifest) -> Result<(), String> {
    let json = serde_json::to_string_pretty(manifest).map_err(|e| e.to_string())?;
    let path = manifest_path(dir);
    // Same tmp-then-rename discipline as the wav files.
    let tmp = unique_tmp_path(&path);
    let result = fs::write(&tmp, json + "\n")
        .map_err(|e| e.to_string())
        .and_then(|()| {
            fs::rename(&tmp, &path)
                .map_err(|e| format!("rename {} -> {}: {e}", tmp.display(), path.display()))
        });
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

pub fn load_manifest(dir: &Path) -> Result<Manifest, String> {
    let raw = fs::read_to_string(manifest_path(dir))
        .map_err(|e| format!("read manifest: {e}"))?;
    serde_json::from_str(&raw).map_err(|e| format!("parse manifest: {e}"))
}

/// Ensure fixtures exist in `dir` and match the committed manifest —
/// self-healing, then strict:
///
/// 1. A file that fails the cheap validity check (missing, truncated by a
///    killed run, torn, wrong format) is regenerated instead of trusted.
/// 2. Every file is then hashed against MANIFEST.json. A mismatch gets ONE
///    regeneration (heals a stale-but-complete file from an older
///    generator, or a writer we raced); if the hash still disagrees after
///    regenerating, the fixture code and manifest have truly diverged and
///    that stays a hard error (they must move together).
///
/// Safe to race from parallel test binaries: all writes are atomic renames
/// of byte-identical content.
pub fn ensure(dir: &Path) -> Result<(), String> {
    fs::create_dir_all(dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    let manifest = load_manifest(dir)?;
    for spec in FIXTURES {
        let path = dir.join(spec.name);
        let expected = manifest.files.get(spec.name).ok_or_else(|| {
            format!("fixture {} missing from MANIFEST.json", spec.name)
        })?;
        if !fixture_valid(spec, &path) {
            generate_file(spec, &path)?;
        }
        let mut actual = hash_file(&path)?;
        if &actual != expected {
            generate_file(spec, &path)?;
            actual = hash_file(&path)?;
        }
        if &actual != expected {
            return Err(format!(
                "fixture hash mismatch for {} even after regeneration: manifest \
                 {expected}, got {actual} — the fixture generator and \
                 MANIFEST.json have diverged (run gen-fixtures --write-manifest \
                 and commit the diff if the change is intentional)",
                spec.name
            ));
        }
    }
    Ok(())
}
