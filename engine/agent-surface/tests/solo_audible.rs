//! End-to-end proof that `track.solo` changes the AUDIO, not just the model.
//!
//! The command already round-tripped through the journaled bus (S lit up, the
//! snapshot carried `solo: true`, undo restored it) -- and the mix was
//! identical. So these tests drive the real `StudioHost` command bus and then
//! compare RENDERED BOUNCE BUFFERS. A model-flag assertion passes either way
//! and is deliberately not the evidence here.
//!
//! Silent: `render_master` is the offline bounce through the same
//! `RenderCore::render` the device callback runs; no device is opened.

use std::path::PathBuf;
use std::sync::OnceLock;

use serde_json::json;

use agent_surface::StudioHost;
use timeline_core::Actor;

fn tone_fixture() -> PathBuf {
    static READY: OnceLock<PathBuf> = OnceLock::new();
    READY
        .get_or_init(|| {
            let dir = render::fixtures::repo_fixtures_dir();
            render::fixtures::ensure(&dir).expect("fixtures");
            dir
        })
        .join("tone_440_48k_mono.wav")
}

fn user() -> Actor {
    Actor::user("aaron")
}

/// Two tracks, both carrying the tone at tick 0, t2 offset in level by -6 dB
/// so each track's contribution to the master sum is distinguishable.
fn host_with_two_tracks() -> StudioHost {
    let tone = tone_fixture();
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("SoloAudible.mstudio");
    let mut host = StudioHost::create_at(&pkg, "SoloAudible").unwrap();
    std::mem::forget(tmp);
    for (track, clip) in [("t1", "c1"), ("t2", "c2")] {
        host.submit(user(), "track.add", json!({ "trackId": track, "name": track }))
            .unwrap();
        host.import_audio(&tone.display().to_string(), track, 0, Some(clip.into()))
            .unwrap();
    }
    host.submit(user(), "mix.gain", json!({ "trackId": "t2", "gainDb": -6 }))
        .unwrap();
    host
}

fn to_bytes(audio: &[[f32; 2]]) -> Vec<u8> {
    audio
        .iter()
        .flat_map(|f| [f[0].to_bits(), f[1].to_bits()])
        .flat_map(u32::to_le_bytes)
        .collect()
}

fn rms(audio: &[[f32; 2]]) -> f64 {
    if audio.is_empty() {
        return 0.0;
    }
    let sumsq: f64 = audio
        .iter()
        .map(|f| f64::from(f[0]) * f64::from(f[0]) + f64::from(f[1]) * f64::from(f[1]))
        .sum();
    (sumsq / (audio.len() as f64 * 2.0)).sqrt()
}

/// Soloing t1 through the command bus must remove t2 from the bounce, and the
/// result must be exactly what muting t2 produces (solo == implicit mute of
/// the non-soloed tracks).
#[test]
fn track_solo_command_changes_the_bounced_audio() {
    let mut host = host_with_two_tracks();
    let mix = host.render_master().unwrap();
    assert!(rms(&mix) > 0.01, "the two-track mix must produce signal");

    host.submit(user(), "track.solo", json!({ "trackId": "t1", "soloed": true }))
        .unwrap();
    let soloed = host.render_master().unwrap();

    assert_eq!(soloed.len(), mix.len(), "bounce lengths differ");
    assert_ne!(
        to_bytes(&soloed),
        to_bytes(&mix),
        "solo did not change the audio at all -- the S button lied (the shipped bug)"
    );
    assert!(
        rms(&soloed) < rms(&mix) * 0.95,
        "soloing t1 must drop t2's energy: solo rms {:.6} vs mix rms {:.6}",
        rms(&soloed),
        rms(&mix)
    );

    // Exactly equivalent to muting the non-soloed track.
    let mut muted_host = host_with_two_tracks();
    muted_host
        .submit(user(), "track.mute", json!({ "trackId": "t2", "muted": true }))
        .unwrap();
    let muted = muted_host.render_master().unwrap();
    assert_eq!(
        to_bytes(&soloed),
        to_bytes(&muted),
        "solo(t1) must bounce bit-identically to mute(t2)"
    );

    // Undoing the solo restores the original mix bit-exactly.
    assert!(host.undo(user()).unwrap(), "solo must be undoable");
    let restored = host.render_master().unwrap();
    assert_eq!(
        to_bytes(&restored),
        to_bytes(&mix),
        "un-soloing must restore the original mix bit-exactly"
    );
}

/// Mute wins over solo on the same track (Ableton Live convention): a muted
/// track that is also soloed contributes nothing, and every other track is
/// still gated by the active solo -> silence.
#[test]
fn muted_and_soloed_track_bounces_silent() {
    let mut host = host_with_two_tracks();
    host.submit(user(), "track.solo", json!({ "trackId": "t1", "soloed": true }))
        .unwrap();
    host.submit(user(), "track.mute", json!({ "trackId": "t1", "muted": true }))
        .unwrap();
    let out = host.render_master().unwrap();
    let peak = out.iter().map(|f| f[0].abs().max(f[1].abs())).fold(0.0_f32, f32::max);
    assert!(
        peak < 1e-6,
        "muted+soloed t1 plus solo-gated t2 must bounce silent, peak {peak}"
    );
}

/// Stem export isolates by mute and must ignore the model's solo state: a stem
/// for t2 while t1 is soloed still contains t2.
#[test]
fn stem_export_ignores_solo() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = host_with_two_tracks();
    host.submit(user(), "track.solo", json!({ "trackId": "t1", "soloed": true }))
        .unwrap();
    let out = host
        .submit(
            user(),
            "export.stems",
            json!({ "outputDir": dir.path().display().to_string(), "format": "wav" }),
        )
        .expect("stem export runs");
    let stems = out
        .get("stems")
        .and_then(|s| s.as_array())
        .expect("stem list");
    assert_eq!(stems.len(), 2, "one stem per track");
    for stem in stems {
        let path = stem["outputPath"].as_str().unwrap();
        let mut reader = hound::WavReader::open(path).unwrap();
        let bits = reader.spec().bits_per_sample as i64;
        let full = (1_i64 << (bits - 1)) as f64;
        let peak = reader
            .samples::<i32>()
            .map(|s| (f64::from(s.unwrap()) / full).abs())
            .fold(0.0_f64, f64::max);
        assert!(
            peak > 1e-4,
            "every stem must carry its own audio regardless of solo: {path} peak {peak}"
        );
    }
}
