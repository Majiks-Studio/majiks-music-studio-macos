//! **`clip.warp.set` must be AUDIBLE through the production path.**
//!
//! The defect these tests exist for: `clip.warp.set` applied to the model,
//! hashed into the journal, survived save/reload and undid correctly — and
//! changed nothing you could hear, because `agent-surface::StudioHost` (the
//! host the shipping Swift app drives through the FFI) handed
//! `compile_session_full` an EMPTY `WarpOverlay` at all four of its compile
//! sites. The stretch DSP was real, tested, and unreachable. Same class as the
//! sine-wave transport meters and the send automation that compiled into a lane
//! slot nothing read.
//!
//! ## What is measured, and why measurement rather than "the bytes differ"
//!
//! "The bytes differ" is satisfied by any bug that perturbs the mix. These
//! tests assert the three numbers that only a real time-stretcher can produce
//! simultaneously:
//!
//! 1. **Duration scales by the ratio.** A 4.000 s clip at 2.0x occupies
//!    8.000 s of timeline.
//! 2. **Pitch does NOT.** A resample — the cheap fake that also doubles the
//!    duration — would drag 440 Hz down to 220 Hz. The measured pitch must stay
//!    440 Hz at every ratio.
//! 3. **A non-simple ratio works.** 1.37x is not a power of two, not a simple
//!    integer fraction, and not a musically convenient number. An
//!    implementation that snapped to octaves, halves or quarters cannot satisfy
//!    it, and neither can one that silently ignored the ratio.
//!
//! 4. **Both engines are covered.** `deterministic_stretcher` uses Signalsmith
//!    up to 2x and WSOLA above it, so 3.0x is swept as well; otherwise the
//!    whole upper half of the supported 0.25x..4x range would be unproven
//!    through the production path.
//!
//! Pitch is measured by zero-crossing rate over an interior window (the source
//! is a clean 440 Hz sine, so this is accurate to well under a percent) and
//! cross-checked against an incoherently averaged Goertzel level at 440 vs its
//! two octaves, which is what actually distinguishes "440 Hz survived" from
//! "everything got quieter".
//!
//! ## Seam honesty — the hops these tests traverse
//!
//! | Hop | Traversed? |
//! |---|---|
//! | `StudioHost::submit` → `bus_submit` → `Session::submit_json` (journal) | YES |
//! | `sync_after_mutation` → `push_live_session` | YES (no-op offline) |
//! | `StudioHost::warp_overlay` → `WarpCache::resolve` → Signalsmith / WSOLA | YES |
//! | `render_master` → `content_end_frame` / `render_to` → `compile_session_full` | YES |
//! | `RenderCommand` channel → `install_session` → `RenderCore::render` | YES |
//! | cpal device callback; real-time deadline | NO — offline bounce, silent |
//!
//! Nothing here pokes the overlay directly. Every warp in this file is set the
//! way the app sets it: a `clip.warp.set` command on the bus.

use std::path::PathBuf;
use std::sync::OnceLock;

use serde_json::json;

use agent_surface::StudioHost;
use timeline_core::Actor;

const RATE: f64 = 48_000.0;
/// The fixture is a 4.000 s, 440 Hz mono tone.
const CLIP_FRAMES: f64 = 192_000.0;
const TONE_HZ: f64 = 440.0;

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

fn digest(audio: &[[f32; 2]]) -> String {
    let mut h = blake3::Hasher::new();
    h.update(&(audio.len() as u64).to_le_bytes());
    for f in audio {
        h.update(&f[0].to_bits().to_le_bytes());
        h.update(&f[1].to_bits().to_le_bytes());
    }
    h.finalize().to_hex().to_string()
}

/// One track, one clip at 0, nothing else. Deliberately bare: any pitch or
/// duration change measured here can only have come from the warp.
fn one_clip_host(name: &str) -> StudioHost {
    let tone = tone_fixture();
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join(format!("{name}.mstudio"));
    let mut host = StudioHost::create_at(&pkg, name).unwrap();
    std::mem::forget(tmp);
    host.submit(user(), "track.add", json!({ "trackId": "t1", "name": "t1" }))
        .unwrap();
    host.import_audio(&tone.display().to_string(), "t1", 0, Some("c1".into()))
        .unwrap();
    host
}

fn set_warp(host: &mut StudioHost, ratio: f64) {
    host.submit(
        user(),
        "clip.warp.set",
        json!({ "clipId": "c1", "mode": "ratio", "stretchRatio": ratio }),
    )
    .unwrap();
}

// ---------------------------------------------------------------------------
// Measurement
// ---------------------------------------------------------------------------

/// One past the last frame above `thresh` — the audible extent of the bounce.
fn audible_end(audio: &[[f32; 2]], thresh: f32) -> usize {
    audio
        .iter()
        .rposition(|f| f[0].abs() > thresh || f[1].abs() > thresh)
        .map(|i| i + 1)
        .unwrap_or(0)
}

/// Dominant frequency by zero-crossing rate over `[from, to)`. Exact for a
/// clean sine and immune to amplitude, which is what makes it the right probe
/// for "did the pitch move" as opposed to "did anything change".
fn zero_cross_hz(audio: &[[f32; 2]], from: usize, to: usize) -> f64 {
    let to = to.min(audio.len());
    assert!(to > from + 1_000, "measurement window too short");
    let mut crossings = 0usize;
    let mut prev = audio[from][0];
    for f in &audio[from + 1..to] {
        let cur = f[0];
        if (prev <= 0.0 && cur > 0.0) || (prev >= 0.0 && cur < 0.0) {
            crossings += 1;
        }
        prev = cur;
    }
    let seconds = (to - from) as f64 / RATE;
    crossings as f64 / 2.0 / seconds
}

/// Goertzel magnitude of `hz` over one window.
fn goertzel_win(win: &[[f32; 2]], hz: f64) -> f64 {
    let n = win.len() as f64;
    let k = (n * hz / RATE).round();
    let w = std::f64::consts::TAU * k / n;
    let coeff = 2.0 * w.cos();
    let (mut s1, mut s2) = (0.0_f64, 0.0_f64);
    for f in win {
        let s0 = f[0] as f64 + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    ((s1 * s1 + s2 * s2 - coeff * s1 * s2).max(0.0)).sqrt() / n
}

/// Energy at `hz`, averaged INCOHERENTLY over short windows.
///
/// Coherent integration over the whole clip is the obvious implementation and
/// it is the wrong one: WSOLA overlap-adds grains, so the 440 Hz component's
/// PHASE steps at every synthesis hop, and a multi-second Goertzel sums those
/// steps to near zero even though the tone is plainly there and plainly at
/// pitch. Averaging the magnitude of many short windows measures how much
/// energy sits at that frequency without caring what its phase is doing —
/// which is the question actually being asked.
const BAND_WINDOW: usize = 4_096;
fn band_level(audio: &[[f32; 2]], from: usize, to: usize, hz: f64) -> f64 {
    let to = to.min(audio.len());
    let mut sum = 0.0;
    let mut n = 0usize;
    let mut at = from;
    while at + BAND_WINDOW <= to {
        sum += goertzel_win(&audio[at..at + BAND_WINDOW], hz);
        n += 1;
        at += BAND_WINDOW;
    }
    assert!(n > 0, "band_level window too short");
    sum / n as f64
}

/// Largest sample-to-sample step in the bounce. A 440 Hz sine at amplitude A
/// steps at most A * 2*pi*440/48000 ~= 0.058*A per frame; an un-declicked cut
/// from peak to zero steps by A. This is how the 5 ms `MICRO_FADE_FRAMES`
/// declick at the warped clip's (new, longer) end is proven to still apply.
fn max_step(audio: &[[f32; 2]]) -> f32 {
    audio
        .windows(2)
        .map(|w| (w[1][0] - w[0][0]).abs().max((w[1][1] - w[0][1]).abs()))
        .fold(0.0_f32, f32::max)
}

fn peak(audio: &[[f32; 2]]) -> f32 {
    audio
        .iter()
        .flat_map(|f| [f[0].abs(), f[1].abs()])
        .fold(0.0_f32, f32::max)
}

// ---------------------------------------------------------------------------
// The proof
// ---------------------------------------------------------------------------

/// **THE AUDIBILITY PROOF.** A clip warped through `submit_json` renders
/// measurably different audio: the timeline extent scales by the ratio and the
/// pitch does not move.
///
/// Ratios chosen on purpose:
/// * `2.0`  — the headline case, and the one a naive resampler also lengthens
///            (it would halve the pitch; asserted that it does not).
/// * `0.5`  — compression, the opposite direction.
/// * `1.37` — NOT a power of two, NOT a simple fraction. An implementation that
///            snapped to convenient ratios, or ignored the ratio and always
///            used some default, fails here and nowhere else.
/// * `3.0`  — ABOVE `SIGNALSMITH_CLEAN_MAX_RATIO`, so it exercises the WSOLA
///            engine that `deterministic_stretcher` selects there. Without this
///            case the whole >2x half of the supported range would be unproven
///            through the production path.
#[test]
fn warp_set_through_submit_json_changes_the_rendered_audio() {
    let host = one_clip_host("WarpAudible");

    let dry = host.render_master().unwrap();
    let dry_end = audible_end(&dry, 0.01);
    let dry_hz = zero_cross_hz(&dry, 24_000, 168_000);
    println!(
        "unwarped: audible {} frames ({:.4} s), {:.2} Hz, peak {:.4}",
        dry_end,
        dry_end as f64 / RATE,
        dry_hz,
        peak(&dry)
    );
    assert!(
        (dry_end as f64 - CLIP_FRAMES).abs() < 600.0,
        "baseline clip should occupy ~{CLIP_FRAMES} frames, got {dry_end}"
    );
    assert!(
        (dry_hz - TONE_HZ).abs() < 2.0,
        "baseline fixture should measure ~440 Hz, got {dry_hz}"
    );

    for ratio in [2.0_f64, 0.5, 1.37, 3.0] {
        let mut host = one_clip_host("WarpAudibleCase");
        set_warp(&mut host, ratio);
        let wet = host.render_master().unwrap();

        let end = audible_end(&wet, 0.01);
        let expected = CLIP_FRAMES * ratio;
        // Interior window, clear of both micro-fades, for the pitch probe.
        let lo = (expected * 0.15) as usize;
        let hi = (expected * 0.85) as usize;
        let hz = zero_cross_hz(&wet, lo, hi);
        let mag_440 = band_level(&wet, lo, hi, TONE_HZ);
        let mag_220 = band_level(&wet, lo, hi, TONE_HZ / 2.0);
        let mag_880 = band_level(&wet, lo, hi, TONE_HZ * 2.0);

        println!(
            "ratio {ratio}: audible {} frames ({:.4} s, expected {:.4} s), \
             {:.2} Hz, |440|={:.5} |220|={:.5} |880|={:.5}, peak {:.4}, maxStep {:.5}",
            end,
            end as f64 / RATE,
            expected / RATE,
            hz,
            mag_440,
            mag_220,
            mag_880,
            peak(&wet),
            max_step(&wet)
        );

        // 1. DURATION scales by the ratio (within 25 ms of slop for the
        //    stretcher's edge handling and the declick tail).
        let err = (end as f64 - expected).abs();
        assert!(
            err < 1_200.0,
            "ratio {ratio}: expected ~{expected} audible frames, got {end} \
             (off by {err} frames = {:.1} ms)",
            err / RATE * 1000.0
        );

        // 2. PITCH is preserved. This is the assertion a resample fails.
        assert!(
            (hz - TONE_HZ).abs() < 6.0,
            "ratio {ratio}: pitch moved to {hz} Hz (a resampler would give {:.1} Hz)",
            TONE_HZ / ratio
        );
        assert!(
            mag_440 > 8.0 * mag_220 && mag_440 > 8.0 * mag_880,
            "ratio {ratio}: 440 Hz must dominate its octaves \
             (|440|={mag_440} |220|={mag_220} |880|={mag_880})"
        );

        // 3. It is still a real signal, not a smeared or gated one.
        assert!(
            peak(&wet) > 0.2,
            "ratio {ratio}: stretched output nearly silent (peak {})",
            peak(&wet)
        );

        // 4. The 5 ms MICRO_FADE_FRAMES declick still lands on the warped
        //    clip's new boundaries — no click at the (moved) end.
        assert!(
            max_step(&wet) < 0.10,
            "ratio {ratio}: sample step {} implies an un-declicked edge",
            max_step(&wet)
        );

        // 5. And the audio genuinely differs from the unwarped bounce. Weakest
        //    of the five on purpose: it is the one that used to be proposed as
        //    "proof", and on its own it proves only that something moved.
        assert_ne!(digest(&wet), digest(&dry), "ratio {ratio}: bytes identical");
    }
}

/// The stretch is a pure function of (source extent, ratio), so the SAME warp
/// bounces identically twice — once from a cold cache, once warm — and two
/// hosts that reached the same warp by different routes agree bit-for-bit.
///
/// Without this, a warped project's bounce would depend on whether a cache
/// happened to be populated, which is a reproducibility bug that would only
/// ever show up as "the master I exported yesterday sounds different".
#[test]
fn a_warped_bounce_is_reproducible_and_cache_backed() {
    let mut host = one_clip_host("WarpRepro");
    set_warp(&mut host, 1.75);

    let cold_renders_before = host.warp_renders();
    let first = host.render_master().unwrap();
    let second = host.render_master().unwrap();
    assert_eq!(
        digest(&first),
        digest(&second),
        "two bounces of the same warped project must be bit-identical"
    );
    // Each bounce compiles three times (content_end_frame, render_to, and the
    // live push on the mutation), so a cache that were not a cache would show
    // renders climbing with every call.
    assert!(
        host.warp_renders() >= cold_renders_before + 1,
        "the first warp must actually run the stretcher"
    );
    assert_eq!(
        host.warp_renders(),
        1,
        "one content address must render exactly once, however many times it \
         is compiled (got {} renders)",
        host.warp_renders()
    );

    // A second host reaching the same (source, extent, ratio) by a different
    // command order must produce the same samples.
    let mut other = one_clip_host("WarpReproB");
    set_warp(&mut other, 3.0);
    set_warp(&mut other, 1.0);
    set_warp(&mut other, 1.75);
    let elsewhere = other.render_master().unwrap();
    assert_eq!(
        digest(&first),
        digest(&elsewhere),
        "the same warp reached by a different route must render identically"
    );

    // The >2x half of the range, on two INDEPENDENT hosts (so two cold caches
    // and two freshly constructed stretch engines). This is the case that was
    // silently non-reproducible until `deterministic_stretcher` existed: with
    // always-Signalsmith these two bounces disagreed.
    let mut big_a = one_clip_host("WarpReproBigA");
    set_warp(&mut big_a, 3.0);
    let mut big_b = one_clip_host("WarpReproBigB");
    set_warp(&mut big_b, 3.0);
    assert_eq!(
        digest(&big_a.render_master().unwrap()),
        digest(&big_b.render_master().unwrap()),
        "a 3x warp must bounce identically on two independent hosts \
         (signalsmith randomises above 2x; wsola must be selected there)"
    );
}

/// Warp is undoable AUDIBLY, not just structurally: undo returns the bounce to
/// the byte-for-byte unwarped render, and redo returns it to the warped one.
///
/// This is the assertion that ties the model half (which already worked) to the
/// render half (which did not). It also pins the identity bypass through the
/// public path: `stretchRatio: 1.0` must produce no overlay entry at all, so
/// the compile takes the same branch an un-warped project takes.
#[test]
fn undo_and_identity_return_to_the_bit_exact_unwarped_bounce() {
    let mut host = one_clip_host("WarpUndo");
    let dry = digest(&host.render_master().unwrap());

    set_warp(&mut host, 2.0);
    let wet = digest(&host.render_master().unwrap());
    assert_ne!(wet, dry, "warp must change the bounce");

    assert!(host.undo(user()).unwrap(), "warp is undoable");
    assert_eq!(
        digest(&host.render_master().unwrap()),
        dry,
        "undo must restore the BIT-EXACT unwarped bounce"
    );

    assert!(host.redo(user()).unwrap(), "warp is redoable");
    assert_eq!(
        digest(&host.render_master().unwrap()),
        wet,
        "redo must restore the BIT-EXACT warped bounce"
    );

    // Explicit identity through the public path, not via undo.
    set_warp(&mut host, 1.0);
    assert_eq!(
        digest(&host.render_master().unwrap()),
        dry,
        "stretchRatio 1.0 must bypass bit-exactly"
    );
}

/// A warp set through the bus survives a save/reload round-trip AUDIBLY. The
/// old defect made this vacuous: the ratio round-tripped in the checkpoint and
/// the audio was unwarped both before and after.
#[test]
fn a_reopened_project_still_renders_its_warp() {
    let tone = tone_fixture();
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("WarpReload.mstudio");

    let warped_digest = {
        let mut host = StudioHost::create_at(&pkg, "WarpReload").unwrap();
        host.submit(user(), "track.add", json!({ "trackId": "t1", "name": "t1" }))
            .unwrap();
        host.import_audio(&tone.display().to_string(), "t1", 0, Some("c1".into()))
            .unwrap();
        set_warp(&mut host, 2.0);
        host.save().unwrap();
        digest(&host.render_master().unwrap())
    };

    let reopened = StudioHost::open_package(&pkg).unwrap();
    let after = reopened.render_master().unwrap();
    assert_eq!(
        (after.iter().rposition(|f| f[0].abs() > 0.01).unwrap() + 1) as f64 / RATE > 7.5,
        true,
        "the reopened project must still occupy ~8 s of timeline"
    );
    assert_eq!(
        digest(&after),
        warped_digest,
        "a reopened warped project must render the same audio it did before \
         the save"
    );
}

/// **THE NULL GATE.** A project with no warp anywhere must compile through the
/// new overlay path to a byte-identical bounce, and must not run the stretcher
/// even once.
///
/// The pinned legacy digest lives in `e5_params_seam.rs`; this is the cheap
/// local companion that says *why* it is still green — the overlay is empty, so
/// `compile` takes the identical branch.
#[test]
fn an_unwarped_project_builds_an_empty_overlay_and_never_stretches() {
    let host = one_clip_host("WarpNull");
    let a = host.render_master().unwrap();
    let b = host.render_master().unwrap();
    assert_eq!(digest(&a), digest(&b));
    assert_eq!(
        host.warp_renders(),
        0,
        "an unwarped project must never invoke the stretcher"
    );
    assert_eq!(a.len(), 240_000, "unwarped bounce length is unchanged");
}
