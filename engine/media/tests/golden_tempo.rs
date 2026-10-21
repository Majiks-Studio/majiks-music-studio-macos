//! Golden tests: synthetic click tracks at known BPM, exact ground truth.
//!
//! ACCEPTANCE bar (session brief): measured BPM within +/-0.5 BPM of the
//! synthetic ground truth, first beat within +/-20 ms. `tests/real_song_
//! sanity.rs` covers real material with a deliberately looser bar (see that
//! file's docs for why: P0-A already showed declared BPM is not ground
//! truth on generated songs, so a strict bar against DECLARED bpm on real
//! songs would be asserting something already known to be false).
//!
//! This module also writes a JSON summary of every case to stdout when run
//! with `--nocapture`; docs/evidence/l3-media-analysis.md's golden-test
//! table is transcribed from this output.

use media::tempo::estimate_tempo;

const SAMPLE_RATE: u32 = 48_000;

/// Mono click track: an 8ms decaying 2kHz tone burst (a sharper synthetic
/// transient than a bare unit impulse, closer to a real percussive click,
/// enough to exercise the spectral-flux onset detector rather than trivially
/// satisfy it) at `bpm`, starting at `first_beat_offset` seconds, louder
/// every 4th beat (downbeat accent), for `bars` bars of 4/4.
fn synth_click_track(bpm: f64, first_beat_offset: f64, bars: u32, sample_rate: u32) -> (Vec<f32>, Vec<f64>) {
    let period = 60.0 / bpm;
    let total_beats = bars * 4;
    let duration = first_beat_offset + period * total_beats as f64 + 1.0;
    let n = (duration * sample_rate as f64) as usize;
    let mut buf = vec![0.0f32; n];
    let mut beat_times = Vec::with_capacity(total_beats as usize);
    let click_len = (sample_rate as f64 * 0.008) as usize;
    for beat in 0..total_beats {
        let t = first_beat_offset + beat as f64 * period;
        beat_times.push(t);
        let start = (t * sample_rate as f64).round() as usize;
        let amp = if beat % 4 == 0 { 1.0 } else { 0.6 };
        for i in 0..click_len {
            if start + i >= buf.len() {
                break;
            }
            let decay = (-(i as f32) / (click_len as f32 * 0.25)).exp();
            let tone = (2.0 * std::f32::consts::PI * 2000.0 * i as f32 / sample_rate as f32).sin();
            buf[start + i] += amp * decay * tone;
        }
    }
    (buf, beat_times)
}

struct Case {
    bpm: f64,
    first_beat_offset: f64,
}

const CASES: &[Case] = &[
    Case { bpm: 80.0, first_beat_offset: 0.12 },
    Case { bpm: 100.0, first_beat_offset: 0.0 },
    Case { bpm: 120.0, first_beat_offset: 0.237 },
    Case { bpm: 128.0, first_beat_offset: 0.05 },
    Case { bpm: 140.0, first_beat_offset: 0.3 },
    Case { bpm: 174.0, first_beat_offset: 0.09 },
];

#[test]
fn golden_click_tracks_meet_the_accuracy_bar() {
    println!("bpm_declared,first_beat_declared_s,bpm_measured,bpm_err,offset_measured_s,offset_err_ms,confidence");
    let mut failures = Vec::new();
    for case in CASES {
        let (mono, _beats) = synth_click_track(case.bpm, case.first_beat_offset, 16, SAMPLE_RATE);
        let est = estimate_tempo(&mono, SAMPLE_RATE, None);
        let bpm_err = (est.bpm - case.bpm).abs();
        let offset_err_ms = (est.first_beat_offset - case.first_beat_offset).abs() * 1000.0;
        println!(
            "{},{},{:.4},{:.4},{:.4},{:.2},{:.3}",
            case.bpm, case.first_beat_offset, est.bpm, bpm_err, est.first_beat_offset, offset_err_ms, est.confidence
        );
        if bpm_err > 0.5 {
            failures.push(format!("bpm {}: measured {:.4}, err {:.4} > 0.5", case.bpm, est.bpm, bpm_err));
        }
        if offset_err_ms > 20.0 {
            failures.push(format!("bpm {}: first_beat_offset measured {:.4}s, err {:.2}ms > 20ms", case.bpm, est.first_beat_offset, offset_err_ms));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn downbeat_phase_lands_on_every_fourth_beat() {
    let (mono, beats) = synth_click_track(120.0, 0.0, 16, SAMPLE_RATE);
    let est = estimate_tempo(&mono, SAMPLE_RATE, None);
    let expected: Vec<f64> = beats.iter().step_by(4).copied().collect();
    // `estimate_tempo` extrapolates the beat grid across the WHOLE analyzed
    // buffer, which correctly includes `synth_click_track`'s trailing 1s of
    // padding (added so the last click's decay tail isn't truncated) -- so
    // `est.downbeats` may run one entry longer than `expected` (a grid
    // point in the silent pad, no real click there). That is the right
    // behavior for a DAW bar grid (it should span the whole timeline, not
    // stop wherever the last onset happened to be), so this checks a
    // PREFIX match, not an exact count.
    assert!(est.downbeats.len() >= expected.len(), "got {} downbeats, expected at least {}", est.downbeats.len(), expected.len());
    for (m, e) in est.downbeats.iter().zip(expected.iter()) {
        assert!((m - e).abs() * 1000.0 <= 20.0, "downbeat {m} vs expected {e}");
    }
}

#[test]
fn confidence_is_high_on_a_clean_click_track() {
    let (mono, _beats) = synth_click_track(120.0, 0.1, 16, SAMPLE_RATE);
    let est = estimate_tempo(&mono, SAMPLE_RATE, None);
    assert!(est.confidence > 0.7, "expected high confidence on a clean synthetic click track, got {}", est.confidence);
}
