//! Shared generated fixtures must be crash-safe and race-safe.
//!
//! The incident this pins: `$CARGO_TARGET_TMPDIR/host-fixtures` and the
//! gitignored repo dir `engine/fixtures` are written by several test
//! binaries and threads. The old writer streamed WAVs straight into their
//! final names, so a parallel reader (or the survivor of a killed run)
//! could open a half-written file and fail far away with
//! `invalid params: source click has zero length` — hound patches the RIFF
//! and data chunk sizes only on finalize, so an unfinished file parses as
//! an empty-but-well-formed WAV.
//!
//! Contract under test:
//! - `generate_all` writes tmp-then-rename: a reader NEVER observes a
//!   partial file, only the old or the new complete bytes (identical, since
//!   generation is deterministic — last-writer-wins is benign).
//! - `ensure` validates before trusting and atomically regenerates anything
//!   missing, truncated, torn, or stale — but still fails loud when the
//!   generator and MANIFEST.json truly diverge.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use render::fixtures::{self, FixtureSpec, FIXTURES};
use render::media::load_wav_stereo_48k;

/// hound 3.5 writes a 44-byte canonical header for 16-bit PCM WAVs with one
/// or two channels. `pinned_generated_byte_lengths` keeps this constant
/// honest: if a hound upgrade changes the header layout, THAT test fails
/// loudly instead of the validity check silently mis-judging files.
const WAV_HEADER_LEN: u64 = 44;

fn spec(name: &str) -> &'static FixtureSpec {
    FIXTURES
        .iter()
        .find(|s| s.name == name)
        .expect("known fixture name")
}

fn expected_source_frames(spec: &FixtureSpec) -> u64 {
    (spec.seconds * f64::from(spec.sample_rate)).round() as u64
}

fn expected_bytes(spec: &FixtureSpec) -> u64 {
    WAV_HEADER_LEN + expected_source_frames(spec) * u64::from(spec.channels) * 2
}

/// Frames after `load_wav_stereo_48k` (which resamples 44.1k sources to the
/// 48k engine rate; exact rational lengths for every fixture in the set).
fn expected_loaded_frames(spec: &FixtureSpec) -> u64 {
    expected_source_frames(spec) * 48_000 / u64::from(spec.sample_rate)
}

/// Private per-test scratch dir under this binary's CARGO_TARGET_TMPDIR,
/// wiped at the start so a killed previous run cannot leak state INTO the
/// tests that prove killed runs cannot leak state.
fn tmp(sub: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR"))
        .join("fixtures-atomicity")
        .join(sub);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// Full-strength completeness oracle for the tests (deliberately stronger
/// and slower than the production validity check): exact on-disk byte
/// length AND a full decode through the real media path to the exact
/// spec'd frame count.
fn assert_complete(dir: &Path, name: &str) {
    let s = spec(name);
    let path = dir.join(name);
    let meta = fs::metadata(&path).unwrap_or_else(|e| panic!("stat {name}: {e}"));
    assert_eq!(meta.len(), expected_bytes(s), "{name}: on-disk byte length");
    let buf = load_wav_stereo_48k(&path).unwrap_or_else(|e| panic!("load {name}: {e}"));
    assert_eq!(
        buf.len_frames(),
        expected_loaded_frames(s),
        "{name}: decoded frame count"
    );
}

fn assert_no_tmp_litter(dir: &Path) {
    let litter: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.contains(".tmp-"))
        .collect();
    assert!(
        litter.is_empty(),
        "successful runs must not leave temp files behind: {litter:?}"
    );
}

fn seeded_manifest_dir(sub: &str) -> PathBuf {
    let dir = tmp(sub);
    let manifest = fixtures::generate_all(&dir).unwrap();
    fixtures::write_manifest(&dir, &manifest).unwrap();
    dir
}

// ---------------------------------------------------------------------------
// pins
// ---------------------------------------------------------------------------

/// Every generated fixture has the exact byte length the validity check
/// assumes (44-byte header + 16-bit interleaved data). Guards the
/// WAV_HEADER_LEN assumption against hound upgrades.
#[test]
fn pinned_generated_byte_lengths() {
    let dir = tmp("pinned");
    fixtures::generate_all(&dir).unwrap();
    for s in FIXTURES {
        assert_complete(&dir, s.name);
    }
    assert_no_tmp_litter(&dir);
}

// ---------------------------------------------------------------------------
// self-healing (the "killed prior run" family)
// ---------------------------------------------------------------------------

/// `ensure` must regenerate — not mis-trust, not fail with a misleading
/// hash error — every corruption shape a killed or torn run can leave:
/// hand/OS truncation, hound's unfinalized header, a missing file, and a
/// stale complete file whose bytes no longer match the manifest.
#[test]
fn ensure_self_heals_truncated_torn_missing_and_stale_fixtures() {
    let dir = seeded_manifest_dir("heal");

    // 1) Hand truncation: finalized header, third of the bytes (what a
    //    `truncate -s` or a killed copy leaves).
    let click = dir.join("click_120bpm_48k_stereo.wav");
    let orig = fs::metadata(&click).unwrap().len();
    let f = fs::File::options().write(true).open(&click).unwrap();
    f.set_len(orig / 3).unwrap();
    drop(f);
    fixtures::ensure(&dir).expect("heals a truncated fixture");
    assert_complete(&dir, "click_120bpm_48k_stereo.wav");

    // 2) Killed-mid-write artifact: hound patches RIFF/data sizes only on
    //    finalize, so a killed writer leaves the create-time placeholders
    //    (0) — the file parses as a well-formed EMPTY wav. This is the
    //    exact shape behind "source click has zero length".
    let tone = dir.join("tone_440_48k_mono.wav");
    let mut bytes = fs::read(&tone).unwrap();
    bytes[4..8].fill(0); // RIFF chunk size placeholder
    bytes[40..44].fill(0); // data chunk size placeholder
    fs::write(&tone, &bytes[..bytes.len() / 2]).unwrap();
    fixtures::ensure(&dir).expect("heals an unfinalized fixture");
    assert_complete(&dir, "tone_440_48k_mono.wav");

    // 3) Missing file (fresh clone / manual rm).
    fs::remove_file(dir.join("sweep_48k_stereo.wav")).unwrap();
    fixtures::ensure(&dir).expect("regenerates a missing fixture");
    assert_complete(&dir, "sweep_48k_stereo.wav");

    // 4) Stale-but-complete: structurally valid, right length, wrong bytes
    //    (e.g. left behind by an older generator). Only the manifest hash
    //    can catch this; it must heal, not hard-fail.
    let sweep = dir.join("sweep_44k1_stereo.wav");
    let mut bytes = fs::read(&sweep).unwrap();
    let mid = bytes.len() / 2;
    bytes[mid] ^= 0x55;
    fs::write(&sweep, &bytes).unwrap();
    fixtures::ensure(&dir).expect("heals a stale complete fixture");
    assert_complete(&dir, "sweep_44k1_stereo.wav");

    // Healed state is stable and clean.
    fixtures::ensure(&dir).expect("idempotent after healing");
    assert_no_tmp_litter(&dir);
}

/// Self-healing must NOT paper over true divergence: if the generator code
/// and MANIFEST.json disagree, regeneration cannot converge and `ensure`
/// must still fail loudly for that file.
#[test]
fn ensure_still_fails_loud_when_generator_and_manifest_diverge() {
    let dir = tmp("diverge");
    let mut manifest = fixtures::generate_all(&dir).unwrap();
    manifest.files.insert(
        "tone_440_48k_mono.wav".to_string(),
        "0".repeat(64), // a hash the generator can never produce
    );
    fixtures::write_manifest(&dir, &manifest).unwrap();
    let err = fixtures::ensure(&dir).expect_err("divergence stays an error");
    assert!(
        err.contains("tone_440_48k_mono.wav") && err.contains("mismatch"),
        "error names the diverged file: {err}"
    );
}

// ---------------------------------------------------------------------------
// atomicity (the "parallel lanes" family)
// ---------------------------------------------------------------------------

/// Readers hammer one fixture while a writer regenerates the whole set 20
/// times over it. With tmp-then-rename a reader can only ever observe a
/// COMPLETE file (old or new, identical bytes); with a direct writer the
/// truncate-on-create window is observed within a few iterations. This is
/// the deterministic stand-in for two lanes' test binaries colliding in
/// $CARGO_TARGET_TMPDIR/host-fixtures.
#[test]
fn concurrent_regeneration_never_exposes_a_partial_wav() {
    let dir = tmp("race");
    fixtures::generate_all(&dir).unwrap();

    let name = "click_174bpm_48k_stereo.wav";
    let target = dir.join(name);
    let want_bytes = expected_bytes(spec(name));
    let want_frames = expected_loaded_frames(spec(name));

    let stop = Arc::new(AtomicBool::new(false));
    let violations: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
    let record = |v: &Arc<Mutex<Vec<String>>>, msg: String| {
        let mut g = v.lock().unwrap();
        if g.len() < 20 {
            g.push(msg);
        }
    };

    let readers: Vec<_> = (0..2)
        .map(|_| {
            let stop = Arc::clone(&stop);
            let violations = Arc::clone(&violations);
            let target = target.clone();
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    match fs::metadata(&target) {
                        Ok(m) if m.len() == want_bytes => {}
                        Ok(m) => record(
                            &violations,
                            format!("partial byte length {} (want {want_bytes})", m.len()),
                        ),
                        Err(e) => record(&violations, format!("stat failed: {e}")),
                    }
                    match load_wav_stereo_48k(&target) {
                        Ok(buf) if buf.len_frames() == want_frames => {}
                        Ok(buf) => record(
                            &violations,
                            format!(
                                "decoded {} frames (want {want_frames})",
                                buf.len_frames()
                            ),
                        ),
                        Err(e) => record(&violations, format!("load failed: {e}")),
                    }
                }
            })
        })
        .collect();

    for _ in 0..20 {
        fixtures::generate_all(&dir).unwrap();
    }
    stop.store(true, Ordering::Relaxed);
    for r in readers {
        r.join().unwrap();
    }

    let seen = violations.lock().unwrap();
    assert!(
        seen.is_empty(),
        "a reader observed a partial fixture during regeneration:\n{}",
        seen.join("\n")
    );
    assert_no_tmp_litter(&dir);
}

/// Several threads race `ensure` from the missing-files state (the fresh
/// clone / first run shape). Every caller must come back Ok with valid
/// files on disk — racing generators produce identical bytes, rename is
/// atomic, so last-writer-wins converges.
#[test]
fn concurrent_ensure_from_missing_state_converges() {
    let dir = seeded_manifest_dir("converge");
    for s in FIXTURES {
        fs::remove_file(dir.join(s.name)).unwrap();
    }

    let results: Vec<Result<(), String>> = std::thread::scope(|scope| {
        (0..4)
            .map(|_| {
                let dir = dir.clone();
                scope.spawn(move || fixtures::ensure(&dir))
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect()
    });
    for (i, r) in results.iter().enumerate() {
        assert!(r.is_ok(), "racing ensure #{i} failed: {r:?}");
    }
    for s in FIXTURES {
        assert_complete(&dir, s.name);
    }
    assert_no_tmp_litter(&dir);
}
