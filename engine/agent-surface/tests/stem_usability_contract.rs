//! THE CONTRACT: a separated stem must be usable ALONE.
//!
//! This file exists because the product shipped the opposite. `BandSplit`
//! -- now `InterleaveFixtureSeparator` -- was the DEFAULT separator. It deals
//! every 4th sample into a different stem and zeroes the other three, so the
//! four sum back to the mix bit-exactly. Every check the landing pipeline had
//! was a sum-shaped check (the null test, the pure-sum residual, the asset
//! hashes), so all of them passed at full margin while 75% of every stem was
//! silence and each stem was the whole song decimated to 12 kHz. The owner
//! soloed one and heard a screech. Five lanes then searched the mute/solo
//! render path, which measured clean at 300x margin, because the engine was
//! never the problem.
//!
//! So the assertions here are the OPPOSITE face of "the stems sum to the
//! original", measured on RENDERED SAMPLES -- each stem track soloed and
//! bounced through the real graph, which is exactly what the owner did:
//!
//!   * no stem may be mostly silence-by-construction (exact-zero ratio), and
//!   * no stem may carry the broadband aliasing signature a decimated copy
//!     creates (energy above 0.75 * Nyquist).
//!
//! Both thresholds are calibrated against BOTH populations on real audio; see
//! `agent_surface::stem_usability` for the measured numbers.
//!
//! It is a CONTRACT OVER THE REGISTRY, not over a hand-listed separator, so a
//! separator added later is held to it on arrival. The fixture is exempted BY
//! NAME (it declares `SeparatorKind::Fixture`) and then asserted to FAIL the
//! contract, so the exemption can never quietly become a hole.

use std::f32::consts::PI;
use std::path::{Path, PathBuf};

use agent_surface::landing::{
    build_landing, fixture_refusal, selectable_separator_names, HtdemucsSeparator,
    InterleaveFixtureSeparator, PreSeparated, Separator, SeparatorKind, StemSet,
    DEFAULT_SEPARATOR, INTERLEAVE_FIXTURE_NAME, SEPARATOR_REGISTRY,
};
use agent_surface::stem_usability::{self, StemUsability};
use agent_surface::{dispatch_tool, LandingRequest, StudioHost};
use render::media::write_wav_f32;
use serde_json::json;
use timeline_core::envelope::ActorKind;
use timeline_core::Actor;

const RATE: u32 = 48_000;
const BPM: f64 = 120.0;
const BARS: u32 = 4;

// ---------------------------------------------------------------------------
// A four-part song whose parts are individually listenable
// ---------------------------------------------------------------------------

/// One deterministic pseudo-random value in [-1, 1) (an LCG, so the fixture is
/// byte-stable across machines without pulling a rand crate).
fn noise(state: &mut u32) -> f32 {
    *state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
    ((*state >> 8) as f32 / 8_388_608.0) - 1.0
}

/// The four parts of a synthetic song, each a real continuous waveform in its
/// own register -- what a working separator hands back.
///
/// The drums part is BAND-LIMITED noise (a one-pole low-pass at ~4 kHz), not
/// white noise, because white noise is spectrally flat and would legitimately
/// put ~25% of its energy above 0.75 * Nyquist. Real percussion does not: the
/// worst real htdemucs drums stem measured 0.064%. Using flat noise here would
/// be testing the fixture's own signature and calling it a drum kit.
fn four_parts() -> [Vec<[f32; 2]>; 4] {
    let beat = 60.0 / BPM;
    let n = ((beat * (BARS * 4) as f64 + 0.5) * RATE as f64) as usize;
    let mut vocals = vec![[0.0f32; 2]; n];
    let mut drums = vec![[0.0f32; 2]; n];
    let mut bass = vec![[0.0f32; 2]; n];
    let mut other = vec![[0.0f32; 2]; n];

    let mut rng = 0x5EED_1234u32;
    // FOUR cascaded one-poles at ~3 kHz for the drum band-limiting. One pole is
    // 6 dB/octave, which still leaves ~6.7% of a noise burst's energy above
    // 18 kHz -- brighter than any real drum stem (htdemucs measured 0.064%) and
    // bright enough to trip the aliasing oracle for the wrong reason. 24
    // dB/octave puts it where real percussion actually sits.
    let mut lp = [0.0f32; 4];
    // a = 1 - exp(-2*pi*fc/fs) at fc = 3 kHz, 48 kHz.
    let a = 0.325f32;

    for i in 0..n {
        let t = i as f64 / RATE as f64;
        let beat_idx = (t / beat).floor();
        let into = t - beat_idx * beat;

        // Vocals: a sung note with vibrato and a slow swell (never silent).
        let vib = 1.0 + 0.01 * (2.0 * PI as f64 * 5.5 * t).sin();
        let v = (0.30 * (2.0 * PI as f64 * 330.0 * vib * t).sin()
            * (0.7 + 0.3 * (2.0 * PI as f64 * 0.25 * t).sin())) as f32;
        vocals[i] = [v, v];

        // Drums: band-limited noise bursts on every beat, accented on the
        // downbeat, so the mix is tempo-trackable (the landing needs a grid).
        // ...over a continuous room-tone bed. A real drum stem is never
        // exactly silent between hits (mic noise, bleed, the tail of the last
        // one), and the zero-ratio oracle is about silence BY CONSTRUCTION, not
        // about quiet. A click track with hard zeros between transients would
        // fail it for reasons that have nothing to do with separation.
        let env = if into < 0.05 { (1.0 - into / 0.05) as f32 } else { 0.0 };
        let accent = if (beat_idx as u64) % 4 == 0 { 0.9 } else { 0.5 };
        let mut n_in = noise(&mut rng);
        for stage in lp.iter_mut() {
            *stage += a * (n_in - *stage);
            n_in = *stage;
        }
        let filtered = lp[3] * 6.0; // make up the cascade's insertion loss
        let d = 0.45 * accent * env * env * filtered + 0.004 * filtered;
        drums[i] = [d, d];

        // Bass: a low sustained tone, an octave-ish walk every bar.
        let bar = (beat_idx as u64) / 4;
        let f = if bar % 2 == 0 { 82.4 } else { 61.7 };
        let b = (0.35 * (2.0 * PI as f64 * f * t).sin()) as f32;
        bass[i] = [b, b];

        // Other: a soft pad, two detuned partials.
        let o = (0.18 * (2.0 * PI as f64 * 523.25 * t).sin()
            + 0.12 * (2.0 * PI as f64 * 659.26 * t).sin()) as f32;
        other[i] = [o, o];
    }
    [vocals, drums, bass, other]
}

/// Write the four parts and their exact sum. Returns (mix, stems).
fn write_song(dir: &Path) -> (PathBuf, StemSet) {
    let parts = four_parts();
    let n = parts[0].len();
    let mut mix = vec![[0.0f32; 2]; n];
    for p in &parts {
        for i in 0..n {
            mix[i][0] += p[i][0];
            mix[i][1] += p[i][1];
        }
    }
    let mix_path = dir.join("song.wav");
    write_wav_f32(&mix_path, &mix, RATE).unwrap();
    let names = ["vocals", "drums", "bass", "other"];
    let mut paths = Vec::new();
    for (k, name) in names.iter().enumerate() {
        let p = dir.join(format!("real_{name}.wav"));
        write_wav_f32(&p, &parts[k], RATE).unwrap();
        paths.push(p);
    }
    (
        mix_path,
        StemSet {
            vocals: paths[0].clone(),
            drums: paths[1].clone(),
            bass: paths[2].clone(),
            other: paths[3].clone(),
        },
    )
}

// ---------------------------------------------------------------------------
// The measurement: land, then SOLO each stem track and measure the bounce
// ---------------------------------------------------------------------------

/// Land `mix` with `separator`, then for each of the four stem tracks: solo it,
/// render the master through the real offline graph, and measure the result.
///
/// Measuring the RENDER (not the stem file) is the point: it is the audio the
/// listener hears when they press S, which is what went wrong.
///
/// Only the AUDIBLE SPAN is measured -- from the bounce's first non-silent
/// sample to its last. The bar-line lead-in the landing prepends and the
/// arrangement tail after the last clip are silence the TIMELINE added, not
/// something the separator did, and counting them would move every separator's
/// number for a reason that has nothing to do with separation. Everything
/// between those two samples is measured, including any silence inside.
fn solo_render_usability(
    mix: &Path,
    separator: &dyn Separator,
    dir: &Path,
    tag: &str,
) -> Vec<(String, StemUsability)> {
    let pkg = dir.join(format!("{tag}.mstudio"));
    let work = dir.join(format!("{tag}.work"));
    let req = LandingRequest {
        mix_path: mix.to_path_buf(),
        prompt: "stem usability contract".into(),
        ..Default::default()
    };
    let report = build_landing(&pkg, &req, separator, &work, Actor::user("contract"))
        .unwrap_or_else(|e| panic!("{tag}: landing must build to be measurable: {e}"));

    let mut host = StudioHost::open_package(&pkg).expect("reopen the landed session");
    let actor = Actor::user("contract");
    let mut out = Vec::new();
    for track_id in report.track_ids.clone() {
        host.submit(actor.clone(), "track.solo", json!({ "trackId": track_id, "soloed": true }))
            .expect("solo");
        let rendered = host.render_master().expect("bounce the soloed stem");
        host.submit(actor.clone(), "track.solo", json!({ "trackId": track_id, "soloed": false }))
            .expect("un-solo");
        let first = rendered.iter().position(|f| f[0] != 0.0 || f[1] != 0.0);
        let last = rendered.iter().rposition(|f| f[0] != 0.0 || f[1] != 0.0);
        let audible = match (first, last) {
            (Some(a), Some(b)) if b >= a => &rendered[a..=b],
            // A bounce with no non-zero sample at all is its own defect; hand
            // the whole thing to the oracle rather than silently measuring an
            // empty slice.
            _ => &rendered[..],
        };
        out.push((track_id, stem_usability::measure(audible)));
    }
    assert_eq!(out.len(), 4, "{tag}: four stem tracks");
    out
}

// ---------------------------------------------------------------------------
// 1. The registry itself
// ---------------------------------------------------------------------------

#[test]
fn the_only_exempt_separator_is_the_fixture_and_it_is_exempt_by_name() {
    let fixtures: Vec<&str> = SEPARATOR_REGISTRY
        .iter()
        .filter(|s| s.kind == SeparatorKind::Fixture)
        .map(|s| s.name)
        .collect();
    // Exempt BY NAME, not by omission: adding a second fixture, or renaming
    // this one without updating the contract, fails right here.
    assert_eq!(
        fixtures,
        vec![INTERLEAVE_FIXTURE_NAME],
        "exactly one registered separator may be a fixture, and it is {INTERLEAVE_FIXTURE_NAME}"
    );
    for spec in SEPARATOR_REGISTRY {
        match spec.kind {
            SeparatorKind::Fixture => assert!(
                !spec.selectable,
                "{}: a fixture must never be selectable by an ordinary caller",
                spec.name
            ),
            SeparatorKind::Real => assert!(
                spec.selectable,
                "{}: a real separator that no caller can select is dead code",
                spec.name
            ),
        }
    }
}

#[test]
fn the_default_separator_is_a_real_one() {
    // The whole defect in one assertion: a caller who names no separator must
    // get real separation. The old default was the fixture.
    let spec = SEPARATOR_REGISTRY
        .iter()
        .find(|s| s.name == DEFAULT_SEPARATOR)
        .unwrap_or_else(|| panic!("the default '{DEFAULT_SEPARATOR}' must be registered"));
    assert_eq!(
        spec.kind,
        SeparatorKind::Real,
        "the default separator is '{}', which is a {:?} -- a caller who names none would be \
         handed unusable stems",
        spec.name,
        spec.kind
    );
    assert_eq!(DEFAULT_SEPARATOR, "htdemucs");
    assert!(spec.selectable);
}

#[test]
fn the_fixture_cannot_be_named_by_an_ordinary_caller() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    std::fs::create_dir_all(&data).unwrap();
    let (mix, _) = write_song(dir.path());
    let mut host = StudioHost::with_data_dir(&data).expect("host");

    // The MCP tool is the surface the coordinator who shipped the broken stems
    // was reading. Two independent layers stop it now; this asserts both.
    //
    // Layer 1 -- the published schema does not contain the name at all, so the
    // request is rejected before any audio is touched.
    for name in [INTERLEAVE_FIXTURE_NAME, "bandsplit"] {
        let out = dispatch_tool(
            &mut host,
            Actor { kind: ActorKind::Agent, name: "coordinator".into() },
            "studio_open_in_studio",
            json!({ "sourceAudioRef": mix.to_string_lossy(), "separator": name }),
        );
        let err = match out {
            Ok(v) => panic!("separator '{name}' must be refused, not honoured (got {v})"),
            Err(e) => e.to_string(),
        };
        assert!(
            err.contains("not in enum"),
            "'{name}' must not be a value the schema accepts: {err}"
        );
    }

    // Layer 2 -- the manifest an agent reads to DISCOVER options offers only
    // real separators, so the fixture cannot be found by browsing either.
    let manifest = agent_surface::registry::tools_manifest_pretty();
    assert!(
        !manifest.contains(INTERLEAVE_FIXTURE_NAME),
        "the tool manifest must not advertise the fixture"
    );
    assert!(
        !manifest.contains("bandsplit"),
        "the tool manifest must not advertise the old lying name either"
    );
    assert!(manifest.contains("\"htdemucs\""), "real separators are still offered");

    // And when a surface WITHOUT a schema (the CLI) sees the name, the refusal
    // it prints names what would happen to the audio -- so nobody has to guess
    // why it was refused. (The wiring is unit-tested next to the parser in
    // `landing.rs`; this asserts the words themselves.)
    let refusal = fixture_refusal(INTERLEAVE_FIXTURE_NAME);
    assert!(refusal.contains("TEST FIXTURE"), "{refusal}");
    assert!(refusal.contains("75%"), "{refusal}");
    assert!(refusal.contains("12 kHz"), "{refusal}");
    assert!(refusal.contains("screech"), "{refusal}");
    assert!(
        refusal.contains(&selectable_separator_names()),
        "the refusal must point at the real separators: {refusal}"
    );
}

// ---------------------------------------------------------------------------
// 2. The contract, over the registry, on rendered samples
// ---------------------------------------------------------------------------

#[test]
fn every_real_registered_separator_produces_stems_that_survive_being_soloed() {
    let dir = tempfile::tempdir().unwrap();
    let (mix, real_stems) = write_song(dir.path());

    let mut covered = 0;
    for spec in SEPARATOR_REGISTRY.iter().filter(|s| s.kind == SeparatorKind::Real) {
        match spec.name {
            "provided" => {
                let sep = PreSeparated { stems: real_stems.clone(), model: "contract".into() };
                for (track, m) in solo_render_usability(&mix, &sep, dir.path(), "provided") {
                    m.verdict().unwrap_or_else(|why| {
                        panic!("separator 'provided', {track} soloed: {why}")
                    });
                }
                covered += 1;
            }
            "htdemucs" => {
                // The real model. It is not installed everywhere, and this test
                // refuses to SKIP: either it runs and is held to the contract,
                // or its absence is asserted to be a clean, actionable refusal.
                // A silent skip is the bug class this whole file exists for.
                match HtdemucsSeparator::discover(None) {
                    Ok(sep) => {
                        for (track, m) in
                            solo_render_usability(&mix, &sep, dir.path(), "htdemucs")
                        {
                            m.verdict().unwrap_or_else(|why| {
                                panic!("separator 'htdemucs', {track} soloed: {why}")
                            });
                        }
                    }
                    Err(e) => {
                        let msg = e.to_string();
                        assert!(
                            msg.contains("unavailable"),
                            "an absent separator must say it is unavailable: {msg}"
                        );
                        assert!(
                            msg.contains("pip install") || msg.contains("MAJIKS_PYTHON"),
                            "an absent separator must say how to fix it: {msg}"
                        );
                    }
                }
                covered += 1;
            }
            other => panic!(
                "separator '{other}' is registered as Real but this contract does not know how \
                 to run it. Add it here -- a real separator that no test exercises is exactly \
                 how the broken one shipped."
            ),
        }
    }
    assert_eq!(covered, 2, "both real separators were covered");
}

#[test]
fn the_exempt_fixture_really_does_fail_the_contract_it_is_exempt_from() {
    // Proves the exemption is load-bearing and the oracle is live. If this ever
    // passes, the measurement has gone blind and every assertion above it is
    // worthless.
    let dir = tempfile::tempdir().unwrap();
    let (mix, real_stems) = write_song(dir.path());
    let measured =
        solo_render_usability(&mix, &InterleaveFixtureSeparator, dir.path(), "fixture");

    for (track, m) in &measured {
        assert!(
            m.verdict().is_err(),
            "{track}: the fixture must FAIL the usability contract, got zeros={:.4}% \
             highBand={:.4}%",
            m.zero_ratio * 100.0,
            m.high_band_fraction * 100.0
        );
        // Hardcoded expectations, not a re-derivation of the implementation:
        // three of every four frames are zeroed, and a quarter of the energy
        // folds above 18 kHz.
        assert!(
            m.zero_ratio > 0.70,
            "{track}: expected ~75% exact zeros, measured {:.4}%",
            m.zero_ratio * 100.0
        );
        assert!(
            m.high_band_fraction > 0.15,
            "{track}: expected the ~25% aliased quarter-band, measured {:.4}%",
            m.high_band_fraction * 100.0
        );
    }

    // And the contrast that makes the numbers mean something: the SAME
    // measurement, the same render path, on a real four-part song.
    let sep = PreSeparated { stems: real_stems, model: "contract".into() };
    for (track, m) in solo_render_usability(&mix, &sep, dir.path(), "contrast") {
        assert!(
            m.zero_ratio < 0.02,
            "{track}: a real stem is continuous, measured {:.4}% zeros",
            m.zero_ratio * 100.0
        );
        assert!(
            m.high_band_fraction < 0.01,
            "{track}: a real stem is not broadband-aliased, measured {:.4}%",
            m.high_band_fraction * 100.0
        );
    }
}

// ---------------------------------------------------------------------------
// 2b. The CLI, driven as a real process
//
// The CLI has its OWN default and its OWN refusal, in a `bin` target no unit
// test can reach. A mutation that restored the fixture as `land`'s default and
// re-accepted the name compiled and left the whole suite green -- the surface
// the coordinator actually read (`--separator bandsplit`, straight out of the
// usage text) had nothing behind it. So drive the binary.
// ---------------------------------------------------------------------------

/// An "interpreter" that fails every import, so these run in milliseconds and
/// do not depend on what is installed on the machine.
fn cli_env_without_demucs(dir: &Path) -> String {
    interpreter_without_demucs(dir)
}

fn run_cli(dir: &Path, python: &str, args: &[&str]) -> (bool, String) {
    // Point the CLI at the repo's real backend tree and at an interpreter that
    // cannot separate, so the run exercises the FULL htdemucs path -- discovery
    // succeeds, the import probe fails -- rather than stopping at "no backend
    // dir" and never reaching the interesting refusal.
    let python_src = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../src/python");
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_majiks-studio-cli"))
        .args(args)
        .env("MAJIKS_PYTHON", python)
        .env("MAJIKS_PYTHON_SRC", &python_src)
        .current_dir(dir)
        .output()
        .expect("the CLI binary runs");
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    (out.status.success(), text)
}

#[test]
fn the_cli_never_lands_the_fixture_by_default_or_by_name() {
    let dir = tempfile::tempdir().unwrap();
    let (mix, _) = write_song(dir.path());
    let mix = mix.to_string_lossy().to_string();
    let python = cli_env_without_demucs(dir.path());

    // 1. No --separator at all: the exact call the coordinator would make. With
    //    no separator available it must REFUSE and leave nothing behind. It
    //    must never quietly land four unusable stems, which is what the old
    //    default did.
    let pkg = dir.path().join("Default.mstudio");
    let (ok, text) = run_cli(
        dir.path(),
        &python,
        &["land", "--mix", &mix, "--out", &pkg.to_string_lossy(), "--work",
          &dir.path().join("dw").to_string_lossy()],
    );
    assert!(!ok, "land with no --separator must not succeed without a separator:\n{text}");
    assert!(text.contains("unavailable"), "{text}");
    assert!(text.contains("pip install"), "the refusal must carry the fix:\n{text}");
    assert!(
        !pkg.join("project.json").exists(),
        "a refused landing must leave no session behind"
    );

    // 2. Naming the fixture: refused, loudly, with what it would do to the audio.
    let pkg2 = dir.path().join("Named.mstudio");
    let (ok2, text2) = run_cli(
        dir.path(),
        &python,
        &["land", "--mix", &mix, "--out", &pkg2.to_string_lossy(),
          "--separator", INTERLEAVE_FIXTURE_NAME],
    );
    assert!(!ok2, "the CLI must refuse the fixture by name:\n{text2}");
    assert!(text2.contains("TEST FIXTURE"), "{text2}");
    assert!(text2.contains("75%"), "{text2}");
    assert!(text2.contains("screech"), "{text2}");
    assert!(!pkg2.join("project.json").exists());

    // 3. The old lying name resolves to nothing.
    let (ok3, text3) = run_cli(
        dir.path(),
        &python,
        &["land", "--mix", &mix, "--out", &dir.path().join("Old.mstudio").to_string_lossy(),
          "--separator", "bandsplit"],
    );
    assert!(!ok3, "'bandsplit' must not resolve:\n{text3}");
    assert!(text3.contains("unknown --separator bandsplit"), "{text3}");

    // 4. The usage text a caller reads offers only real separators. This is the
    //    document that caused the incident.
    let (_, usage) = run_cli(dir.path(), &python, &["help"]);
    assert!(
        !usage.contains("bandsplit") && !usage.contains(INTERLEAVE_FIXTURE_NAME),
        "the CLI usage must not advertise the fixture:\n{usage}"
    );
    assert!(
        usage.contains(&format!("--separator {}", selectable_separator_names())),
        "the usage must list the real separators:\n{usage}"
    );
    assert!(
        usage.contains(&format!("(default {DEFAULT_SEPARATOR})")),
        "the usage must state the default, so nobody has to guess it:\n{usage}"
    );
}

// ---------------------------------------------------------------------------
// 3. Missing separation refuses; it never falls back
// ---------------------------------------------------------------------------

/// A stand-in "interpreter" that fails every import, so the missing-demucs path
/// is exercised without depending on what is or is not installed here.
fn interpreter_without_demucs(dir: &Path) -> String {
    let p = dir.join("python-no-demucs");
    std::fs::write(&p, "#!/bin/sh\necho \"ModuleNotFoundError\" >&2\nexit 1\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    p.to_string_lossy().to_string()
}

#[test]
fn landing_refuses_with_a_fix_when_separation_is_unavailable_and_never_falls_back() {
    let dir = tempfile::tempdir().unwrap();
    let (mix, _) = write_song(dir.path());
    let sep = HtdemucsSeparator {
        python: interpreter_without_demucs(dir.path()),
        python_src: dir.path().to_path_buf(),
    };

    // The separator itself refuses, with the fix in the message.
    let err = sep
        .separate(&mix, &dir.path().join("w"))
        .expect_err("no demucs must be a refusal, not stems");
    let msg = err.to_string();
    assert!(msg.contains("unavailable"), "{msg}");
    assert!(msg.contains("pip install numpy"), "the fix names the FIRST missing import: {msg}");
    assert!(
        msg.contains("No fallback"),
        "the refusal must state that nothing was substituted: {msg}"
    );

    // And the whole pipeline refuses: no package, no stems, no silent fixture.
    let pkg = dir.path().join("NoDemucs.mstudio");
    let req = LandingRequest {
        mix_path: mix.clone(),
        prompt: "should not land".into(),
        ..Default::default()
    };
    let e2 = build_landing(&pkg, &req, &sep, &dir.path().join("w2"), Actor::user("u"))
        .expect_err("landing must not complete without a separator");
    assert!(e2.to_string().contains("pip install"), "{}", e2);
    assert!(
        !pkg.join("project.json").exists(),
        "a refused landing must leave no session behind"
    );
}

#[test]
fn a_missing_python_backend_refuses_by_name_rather_than_guessing() {
    // Discovery pointed at a directory with no majik_backend: the caller is
    // told what is missing and given two ways out, instead of a traceback.
    let dir = tempfile::tempdir().unwrap();
    let msg = match HtdemucsSeparator::discover(Some(dir.path().join("nope"))) {
        Ok(_) => panic!("a --python-src with no majik_backend in it must refuse"),
        Err(e) => e.to_string(),
    };
    assert!(msg.contains("majik_backend"), "{msg}");
    assert!(msg.contains("MAJIKS_PYTHON_SRC"), "{msg}");
    assert!(msg.contains("--separator provided"), "{msg}");
}
