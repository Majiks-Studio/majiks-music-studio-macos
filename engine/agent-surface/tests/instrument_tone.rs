//! What the instrument SOUNDS like, proven on rendered samples.
//!
//! ## Why this file exists at all
//!
//! The synth has had four waveforms, a resonant low-pass and a full ADSR since
//! E2, every parameter of it automatable through
//! `track.device.<deviceId>.<paramKey>`. No command in the catalog could write
//! one. So the app's only instrument sound was `Waveform::Saw` — the harshest
//! of the four — permanently, for everyone, and the instrument panel said in a
//! comment that it was "NOT a waveform editor". Built, and unreachable.
//!
//! `device.param.set` is the missing verb, and this file is the proof it is not
//! another inert control. THE house rule here is that every assertion is on
//! RENDERED AUDIO, never on model state: this codebase has already shipped a
//! transport meter that was `abs(sin(t))`, a command palette listing 71
//! commands and wiring 11, and a piano roll wired to a mock. A test asserting
//! "the device stores waveform: 3" would have passed against every one of those.
//!
//! ## Seam honesty — the hops these tests traverse
//!
//! | Hop | Traversed? |
//! |---|---|
//! | `StudioHost::submit` → `Session::submit_json` → `apply.rs` | YES |
//! | `Device::params` → `compile.rs::build_instrument` (`Num` → `InstrumentParams`) | YES |
//! | `render_master` → `compile_session_full` → `ManualRenderer` → `RenderCore::render` | YES |
//! | `NoteSchedule` → `Synth::note_on` → osc/filter/envelope, per frame | YES |
//! | cpal device callback; real-time deadline | NO — offline bounce, silent |
//!
//! The preset numbers are NOT written here. They are read from
//! `engine/contracts/instrument-presets.v1.json`, which is also what the Swift
//! table is asserted equal to, so there is exactly one place either half can
//! change them.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::OnceLock;

use serde_json::{json, Value};

use agent_surface::StudioHost;
use timeline_core::Actor;

/// The one source of truth for the preset numbers, compiled in so this test
/// cannot silently pass against a file that moved.
const PRESETS_JSON: &str = include_str!("../../contracts/instrument-presets.v1.json");

const PPQ: u64 = 960;
const SAMPLE_RATE: f64 = 48_000.0;

fn user() -> Actor {
    Actor::user("tone")
}

// ---------------------------------------------------------------------------
// The preset table
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct Preset {
    id: String,
    name: String,
    blurb: String,
    params: BTreeMap<String, f64>,
}

fn presets() -> &'static Vec<Preset> {
    static P: OnceLock<Vec<Preset>> = OnceLock::new();
    P.get_or_init(|| {
        let doc: Value = serde_json::from_str(PRESETS_JSON).expect("presets contract must parse");
        doc["presets"]
            .as_array()
            .expect("presets array")
            .iter()
            .map(|p| Preset {
                id: p["id"].as_str().unwrap().to_string(),
                name: p["name"].as_str().unwrap().to_string(),
                blurb: p["blurb"].as_str().unwrap().to_string(),
                params: p["params"]
                    .as_object()
                    .unwrap()
                    .iter()
                    .map(|(k, v)| (k.clone(), v.as_f64().unwrap()))
                    .collect(),
            })
            .collect()
    })
}

fn preset(id: &str) -> &'static Preset {
    presets()
        .iter()
        .find(|p| p.id == id)
        .unwrap_or_else(|| panic!("no preset {id}"))
}

// ---------------------------------------------------------------------------
// A project that plays ONE note, long enough to hear an envelope
// ---------------------------------------------------------------------------

/// Ticks the test note is held. Two seconds at 120 BPM — long enough that a
/// Pluck has finished and an Organ has not.
const HOLD_TICKS: u64 = PPQ * 4;

fn tmp_pkg(name: &str) -> PathBuf {
    let tmp = tempfile::tempdir().unwrap();
    let p = tmp.path().join(format!("{name}.mstudio"));
    std::mem::forget(tmp); // the host owns the directory for the run
    p
}

/// One synth track holding one note at A4. Nothing else: no mixer moves, no
/// effects, no automation, so the ONLY thing that can differ between two runs
/// of this is the instrument's own parameters.
fn host_playing_a_note(name: &str) -> StudioHost {
    let mut host = StudioHost::create_at(tmp_pkg(name), name).unwrap();
    host.submit(user(), "track.add", json!({"trackId": "t1", "name": "Keys"}))
        .unwrap();
    host.submit(
        user(),
        "device.add",
        json!({"trackId": "t1", "deviceId": "inst1", "kind": "synth"}),
    )
    .unwrap();
    host.submit(
        user(),
        "clip.placeMidi",
        json!({"clipId": "m1", "trackId": "t1", "startTicks": 0, "lengthTicks": HOLD_TICKS}),
    )
    .unwrap();
    host.submit(
        user(),
        "note.add",
        json!({"clipId": "m1", "notes": [
            {"noteId": "n1", "startTicks": 0, "lengthTicks": HOLD_TICKS,
             "pitch": 69, "velocity": 100}
        ]}),
    )
    .unwrap();
    host
}

/// Apply one preset the way the instrument panel applies it: one
/// `device.param.set` per key, inside one transaction, so it is one undo step.
fn apply_preset(host: &mut StudioHost, p: &Preset) {
    let txn = format!("tone_{}", p.id);
    host.submit(
        user(),
        "txn.begin",
        json!({"txnId": txn, "reason": format!("Sound: {}", p.name)}),
    )
    .unwrap();
    for (key, value) in &p.params {
        host.submit(
            user(),
            "device.param.set",
            json!({"trackId": "t1", "deviceId": "inst1", "key": key, "value": value}),
        )
        .unwrap_or_else(|e| panic!("{}: device.param.set {key} refused: {e}", p.id));
    }
    host.submit(user(), "txn.commit", json!({"txnId": txn}))
        .unwrap();
}

fn render(p: Option<&Preset>, name: &str) -> Vec<[f32; 2]> {
    let mut host = host_playing_a_note(name);
    if let Some(p) = p {
        apply_preset(&mut host, p);
    }
    host.render_master().unwrap()
}

// ---------------------------------------------------------------------------
// Measures. Deliberately crude and dependency-free — the claim being made is
// "these are audibly different", not "these match a reference spectrum".
// ---------------------------------------------------------------------------

fn rms(frames: &[[f32; 2]]) -> f64 {
    if frames.is_empty() {
        return 0.0;
    }
    let sum: f64 = frames.iter().map(|f| (f[0] as f64) * (f[0] as f64)).sum();
    (sum / frames.len() as f64).sqrt()
}

fn peak(frames: &[[f32; 2]]) -> f64 {
    frames.iter().fold(0.0f64, |m, f| m.max(f[0].abs() as f64))
}

/// A first-difference / signal energy ratio: a one-pole high-pass in disguise.
/// Higher means more of the energy is up high, which is what "brighter" means
/// at this resolution. No FFT, no dependency, and monotonic in cutoff — which
/// `a_darker_filter_measurably_lowers_it` pins as a positive control, because a
/// measure nobody has calibrated is not evidence.
fn brightness(frames: &[[f32; 2]]) -> f64 {
    if frames.len() < 2 {
        return 0.0;
    }
    let mut num = 0.0f64;
    let mut den = 0.0f64;
    for w in frames.windows(2) {
        let d = (w[1][0] - w[0][0]) as f64;
        num += d * d;
        den += (w[1][0] as f64) * (w[1][0] as f64);
    }
    if den <= 0.0 {
        0.0
    } else {
        (num / den).sqrt()
    }
}

/// Frames in a window `[from_s, to_s)` of the bounce.
fn window(frames: &[[f32; 2]], from_s: f64, to_s: f64) -> &[[f32; 2]] {
    let a = ((from_s * SAMPLE_RATE) as usize).min(frames.len());
    let b = ((to_s * SAMPLE_RATE) as usize).min(frames.len());
    &frames[a..b.max(a)]
}

/// How much of the note is still sounding one second in, relative to its
/// opening. THE envelope-shape number: an Organ holds, a Pluck is gone.
fn hold_ratio(frames: &[[f32; 2]]) -> f64 {
    let early = rms(window(frames, 0.02, 0.06));
    let late = rms(window(frames, 1.0, 1.2));
    if early <= 0.0 {
        0.0
    } else {
        late / early
    }
}

fn report(label: &str, frames: &[[f32; 2]]) {
    println!(
        "{label:<16} peak {:.4}  rms {:.4}  bright {:.5}  hold {:.4}",
        peak(frames),
        rms(frames),
        brightness(frames),
        hold_ratio(frames),
    );
}

// ---------------------------------------------------------------------------
// 1. The command reaches the renderer at all
// ---------------------------------------------------------------------------

/// The single most important assertion in this file: setting an instrument
/// parameter changes the SAMPLES, not just the model.
///
/// Deliberately a parameter with nowhere to hide — the waveform — driven
/// through `StudioHost::submit`, which is the same entry point the GUI button
/// and an MCP agent both use.
#[test]
fn device_param_set_changes_the_rendered_audio() {
    let mut a = host_playing_a_note("ToneWaveA");
    let saw = {
        a.submit(
            user(),
            "device.param.set",
            json!({"trackId": "t1", "deviceId": "inst1", "key": "waveform", "value": 1}),
        )
        .unwrap();
        a.render_master().unwrap()
    };
    let mut b = host_playing_a_note("ToneWaveB");
    let sine = {
        b.submit(
            user(),
            "device.param.set",
            json!({"trackId": "t1", "deviceId": "inst1", "key": "waveform", "value": 0}),
        )
        .unwrap();
        b.render_master().unwrap()
    };

    report("saw", &saw);
    report("sine", &sine);
    assert_eq!(saw.len(), sine.len(), "same note, same length");
    assert!(peak(&saw) > 0.01 && peak(&sine) > 0.01, "both are audible");
    assert_ne!(saw, sine, "the two waveforms rendered identical samples");
    // A sawtooth carries every harmonic; a sine carries one. If this ever fails
    // while the buffers still differ, the parameter is reaching SOMETHING but
    // not the oscillator.
    assert!(
        brightness(&saw) > brightness(&sine) * 1.5,
        "a saw must be measurably brighter than a sine: saw {:.5}, sine {:.5}",
        brightness(&saw),
        brightness(&sine)
    );
}

/// The positive control for `brightness`. Without this, every brightness
/// assertion below is comparing a number nobody has shown means anything.
#[test]
fn a_darker_filter_measurably_lowers_the_brightness_measure() {
    let mut open = host_playing_a_note("ToneOpen");
    open.submit(
        user(),
        "device.param.set",
        json!({"trackId": "t1", "deviceId": "inst1", "key": "waveform", "value": 1}),
    )
    .unwrap();
    open.submit(
        user(),
        "device.param.set",
        json!({"trackId": "t1", "deviceId": "inst1", "key": "cutoff", "value": 16000}),
    )
    .unwrap();
    let bright = open.render_master().unwrap();

    let mut shut = host_playing_a_note("ToneShut");
    shut.submit(
        user(),
        "device.param.set",
        json!({"trackId": "t1", "deviceId": "inst1", "key": "waveform", "value": 1}),
    )
    .unwrap();
    shut.submit(
        user(),
        "device.param.set",
        json!({"trackId": "t1", "deviceId": "inst1", "key": "cutoff", "value": 400}),
    )
    .unwrap();
    let dark = shut.render_master().unwrap();

    report("cutoff 16k", &bright);
    report("cutoff 400", &dark);
    assert!(
        brightness(&dark) < brightness(&bright) * 0.6,
        "closing the filter must lower the measure: open {:.5}, closed {:.5}",
        brightness(&bright),
        brightness(&dark)
    );
}

/// Undo of a preset returns the instrument to the DEFAULT sound, and the sound
/// it returns to is the same samples as a synth that was never touched. This is
/// the sparsity rule audible: undoing a first `device.param.set` clears the key
/// rather than writing a default over it.
#[test]
fn undoing_a_preset_renders_identically_to_a_synth_that_was_never_touched() {
    let untouched = render(None, "ToneUntouched");

    let mut host = host_playing_a_note("ToneUndo");
    apply_preset(&mut host, preset("pluck"));
    let with_preset = host.render_master().unwrap();
    assert_ne!(with_preset, untouched, "the preset did nothing");

    host.undo(user()).unwrap();
    let after_undo = host.render_master().unwrap();
    assert_eq!(
        after_undo, untouched,
        "one Cmd-Z did not return the instrument to its untouched sound"
    );
    // ... and the model agrees it is sparse again, which is the mechanism
    // behind the audible claim above.
    let snap = host.snapshot(None);
    let params = &snap["project"]["tracks"][0]["devices"][0]["params"];
    assert!(
        params.is_null() || params.as_object().is_some_and(|m| m.is_empty()),
        "undo left a written default behind instead of clearing the keys: {params}"
    );
}

// ---------------------------------------------------------------------------
// 2. Every named preset is a distinct, audible sound
// ---------------------------------------------------------------------------

/// Every preset in the contract renders, is audible, and is different from
/// every other preset AND from the untouched default.
///
/// Table-driven over the contract file, so adding a preset to the JSON without
/// making it sound like anything fails HERE rather than shipping a button that
/// does nothing.
#[test]
fn every_preset_renders_a_distinct_audible_sound() {
    assert!(
        presets().len() >= 5,
        "the preset contract has shrunk to {} entries",
        presets().len()
    );

    let mut rendered: Vec<(String, Vec<[f32; 2]>)> =
        vec![("(default)".to_string(), render(None, "ToneDefault"))];
    for p in presets() {
        rendered.push((p.name.clone(), render(Some(p), &format!("Tone{}", p.id))));
    }

    for (name, buf) in &rendered {
        report(name, buf);
        assert!(
            peak(buf) > 0.005,
            "{name} is inaudible (peak {:.5}) — a preset nobody can hear is a preset that \
             does not exist",
            peak(buf)
        );
    }

    for i in 0..rendered.len() {
        for j in (i + 1)..rendered.len() {
            assert_ne!(
                rendered[i].1, rendered[j].1,
                "{} and {} render byte-identical audio, so one of them is not reaching the DSP",
                rendered[i].0, rendered[j].0
            );
        }
    }
}

/// The presets do the specific musical things their names and their help text
/// promise. This is the assertion that catches "the numbers changed but the
/// sound did not", and it is written against the BLURB the user reads: if the
/// tuning drifts so the blurb becomes a lie, this goes red.
#[test]
fn each_preset_does_what_its_help_text_says_it_does() {
    let organ = render(Some(preset("organ")), "ToneOrgan");
    let pluck = render(Some(preset("pluck")), "TonePluck");
    let pad = render(Some(preset("softPad")), "TonePad");
    let ep = render(Some(preset("electricPiano")), "ToneEP");
    let bass = render(Some(preset("bass")), "ToneBass");
    for (n, b) in [
        ("organ", &organ),
        ("pluck", &pluck),
        ("pad", &pad),
        ("ep", &ep),
        ("bass", &bass),
    ] {
        report(n, b);
    }

    // "Holds dead steady for as long as you hold the key."
    assert!(
        hold_ratio(&organ) > 0.85,
        "Organ does not hold: {:.3} of its opening level is left at 1 s",
        hold_ratio(&organ)
    );
    // "Gone in a fifth of a second however long you hold the key."
    assert!(
        hold_ratio(&pluck) < 0.02,
        "Pluck is still sounding at 1 s ({:.3}), so it is not a pluck",
        hold_ratio(&pluck)
    );
    // "Loudest the instant you press the key, then it fades on its own."
    assert!(
        hold_ratio(&ep) < 0.45 && hold_ratio(&ep) > 0.02,
        "Electric Piano should fade a long way without vanishing: {:.3}",
        hold_ratio(&ep)
    );
    // "It swells in over about half a second." The opening 40 ms of a Pad must
    // be far quieter than the same window of a percussive sound.
    let pad_open = rms(window(&pad, 0.0, 0.04));
    let pad_body = rms(window(&pad, 0.6, 0.8));
    assert!(
        pad_open < pad_body * 0.25,
        "Soft Pad has no swell: opening {:.5} vs body {:.5}",
        pad_open,
        pad_body
    );
    assert!(
        rms(window(&ep, 0.0, 0.04)) > rms(window(&pad, 0.0, 0.04)) * 4.0,
        "the Electric Piano's attack is not measurably faster than the Pad's"
    );
    // "The bright half of the sound is filtered away so it sits under
    // everything else." Bass must be the darkest of the five.
    let bass_b = brightness(window(&bass, 0.0, 0.5));
    // Compared against the three BRIGHT presets, with a real margin. The
    // Electric Piano is deliberately not in this list: it is a triangle, whose
    // harmonics fall off as 1/n^2, so it is intrinsically dark and a couple of
    // percent either way against it would be noise, not evidence.
    for (name, buf) in [("Organ", &organ), ("Pluck", &pluck), ("Soft Pad", &pad)] {
        let other = brightness(window(buf, 0.0, 0.5));
        assert!(
            bass_b < other * 0.85,
            "Bass ({bass_b:.5}) is not measurably darker than {name} ({other:.5})"
        );
    }
    // ...and its darkness comes from its OWN filter setting rather than from
    // the note it happens to be playing: the same preset with the filter opened
    // is measurably brighter. This is the claim the blurb actually makes.
    let mut open = host_playing_a_note("ToneBassOpen");
    apply_preset(&mut open, preset("bass"));
    open.submit(
        user(),
        "device.param.set",
        json!({"trackId": "t1", "deviceId": "inst1", "key": "cutoff", "value": 16000}),
    )
    .unwrap();
    let bass_open = open.render_master().unwrap();
    report("bass (open)", &bass_open);
    assert!(
        bass_b < brightness(window(&bass_open, 0.0, 0.5)) * 0.7,
        "Bass's filter is not removing the bright half of its own sound: filtered {bass_b:.5}, \
         open {:.5}",
        brightness(window(&bass_open, 0.0, 0.5))
    );
}

// ---------------------------------------------------------------------------
// 3. Honesty about what these are
// ---------------------------------------------------------------------------

/// This app ships NO instrument samples — the sounds vault is drum one-shots
/// and stems — so nothing synthesized here may be presented as a piano, a
/// guitar or a string section. "Electric Piano" is honest (it names a synth
/// sound that imitates one); "Piano" would not be.
#[test]
fn no_preset_claims_to_be_a_real_acoustic_instrument() {
    const FORBIDDEN: &[&str] = &[
        "grand", "acoustic", "violin", "cello", "strings", "guitar", "trumpet", "sax", "flute",
        "choir",
    ];
    for p in presets() {
        let name = p.name.to_lowercase();
        for word in FORBIDDEN {
            assert!(
                !name.contains(word),
                "preset {:?} claims to be a sampled acoustic instrument, and this app has no \
                 instrument samples to be one with",
                p.name
            );
        }
        assert!(
            name != "piano",
            "a bare \"Piano\" is a promise of a sampled acoustic piano this app cannot keep; \
             \"Electric Piano\" is the honest name for a synthesized approximation"
        );
        assert!(
            !p.blurb.is_empty() && p.blurb.len() > 40,
            "preset {} has no usable help text",
            p.id
        );
    }
}

/// The DEFAULT sound of a brand-new synth is not the raw sawtooth any more.
/// Asserted on audio through the whole host path, not on the constant — a
/// constant assertion would still pass if `build_instrument` stopped reading it.
#[test]
fn a_brand_new_synth_no_longer_sounds_like_a_raw_sawtooth() {
    let fresh = render(None, "ToneFresh");

    let mut saw = host_playing_a_note("ToneSaw");
    saw.submit(
        user(),
        "device.param.set",
        json!({"trackId": "t1", "deviceId": "inst1", "key": "waveform", "value": 1}),
    )
    .unwrap();
    let saw = saw.render_master().unwrap();

    report("fresh synth", &fresh);
    report("forced saw", &saw);
    assert!(peak(&fresh) > 0.01, "a fresh synth must still be audible");
    assert_ne!(
        fresh, saw,
        "a brand-new synth still renders exactly a sawtooth"
    );
    assert!(
        brightness(&fresh) < brightness(&saw),
        "the new default is no softer than the saw it replaced: fresh {:.5}, saw {:.5}",
        brightness(&fresh),
        brightness(&saw)
    );
}
