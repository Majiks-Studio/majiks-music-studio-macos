//! Real-material sanity checks. `#[ignore]`-gated (run with
//! `cargo test -- --ignored`): these read absolute paths on the machine
//! this lane was executed on (P0-A's audition WAVs under
//! `~/Desktop/majiks-daw-p0a-audition/`), not files checked into the repo,
//! so a plain `cargo test` stays portable to a machine/CI without them.
//!
//! These are DELIBERATELY NOT held to the golden click-track bar of
//! +/-0.5 BPM (see tests in src/tempo.rs). P0-A's own measurement
//! (docs/evidence/p0a-repaint.md) is that declared BPM on generated songs
//! is legitimately off by 1.2-2.9% from the true performed tempo -- so a
//! strict +/-0.5 BPM check against DECLARED bpm here would be asserting
//! something P0-A already showed is false. Instead this is a coarse
//! regression trip-wire (catches a gross octave-error bug, not sub-percent
//! drift) plus the data-gathering pass whose numbers are written up in
//! docs/evidence/l3-media-analysis.md's declared-vs-measured table.

use media::report::analyze_file;

fn home_path(rel: &str) -> Option<std::path::PathBuf> {
    let home = std::env::var("HOME").ok()?;
    let path = std::path::PathBuf::from(home).join(rel);
    path.exists().then_some(path)
}

#[test]
#[ignore]
fn p0a_song_a_measured_bpm_is_in_the_right_octave() {
    let Some(path) = home_path("Desktop/majiks-daw-p0a-audition/A_original.wav") else {
        eprintln!("skipping: P0-A audition WAV not present on this machine");
        return;
    };
    let declared = 120.0;
    let report = analyze_file(&path, Some(declared)).unwrap();
    let bpm = report.bpm.expect("bpm should be measured");
    // P0-A's own librosa-based measurement: ~118.6 bpm (+1.2% period vs
    // declared). A generous band around that, not the golden +/-0.5 bar:
    // this is a cross-check between two independent beat trackers
    // (librosa vs this crate's own implementation), not a repeat of the
    // same measurement.
    assert!((bpm - 118.6).abs() < 6.0, "measured {bpm}, expected close to P0-A's librosa reading of ~118.6 (declared {declared})");
    println!("song A: declared={declared} measured={bpm:.3} confidence={:.3}", report.tempo.unwrap().confidence);
}

#[test]
#[ignore]
fn p0a_song_b_measured_bpm_is_in_the_right_octave() {
    let Some(path) = home_path("Desktop/majiks-daw-p0a-audition/B_original.wav") else {
        eprintln!("skipping: P0-A audition WAV not present on this machine");
        return;
    };
    let declared = 96.0;
    let report = analyze_file(&path, Some(declared)).unwrap();
    let bpm = report.bpm.expect("bpm should be measured");
    // P0-A's own librosa-based measurement: ~93.3 bpm (+2.9% period vs
    // declared).
    assert!((bpm - 93.3).abs() < 6.0, "measured {bpm}, expected close to P0-A's librosa reading of ~93.3 (declared {declared})");
    println!("song B: declared={declared} measured={bpm:.3} confidence={:.3}", report.tempo.unwrap().confidence);
}
