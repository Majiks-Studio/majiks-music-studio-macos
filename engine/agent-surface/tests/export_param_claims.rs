//! The export parameters whose DECLARED schema and REAL behaviour differ, held
//! to what the catalog now says about them in words.
//!
//! Three of `export.*`'s parameters advertise something the host does not do,
//! and none of them could be fixed by narrowing the schema: `apply.rs` runs on
//! replay, so refusing a value a journaled command once accepted breaks
//! reopening any project that ever passed it. That leaves the description as
//! the only place a caller is warned — and a warning nothing executes is a
//! warning that rots.
//!
//! So each claim is executed here:
//!
//!  * `format: "flac"` is in every export enum and is REFUSED at runtime.
//!  * `sampleRateHz` enumerates 44100 and 48000 and accepts only the PROJECT's
//!    own rate.
//!  * `export.stems`'s `stems` filter is read by nothing: the exporter writes
//!    one WAV per TRACK whatever you pass.
//!
//! The third is the `import.audio` `separate`/`conform` class — a parameter the
//! implementation reads NEITHER of while returning `ok: true` — and it is the
//! one an agent cannot notice, because the result is a success.
//!
//! Silence-gated: bounces here are offline, no audio device is opened.

use std::path::Path;

use serde_json::{json, Value};

use agent_surface::StudioHost;
use render::media::write_wav_f32;
use timeline_core::Actor;

const RATE: u32 = 48_000;

fn tone(secs: f64, freq: f64) -> Vec<[f32; 2]> {
    let n = (secs * RATE as f64) as usize;
    (0..n)
        .map(|i| {
            let v = (0.3 * (2.0 * std::f64::consts::PI * freq * i as f64 / RATE as f64).sin()) as f32;
            [v, v]
        })
        .collect()
}

/// Two tracks, one clip each, so "per track" and "per stem" are distinguishable
/// in the stem export's output.
fn two_track_session(dir: &Path) -> StudioHost {
    let a = dir.join("a.wav");
    let b = dir.join("b.wav");
    write_wav_f32(&a, &tone(1.0, 220.0), RATE).unwrap();
    write_wav_f32(&b, &tone(1.0, 440.0), RATE).unwrap();

    let mut host = StudioHost::create_at(&dir.join("Claims.mstudio"), "Claims").unwrap();
    for (id, name, path) in [("t1", "Low", &a), ("t2", "High", &b)] {
        host.submit(Actor::user("t"), "track.add", json!({ "trackId": id, "name": name }))
            .unwrap();
        host.submit(
            Actor::user("t"),
            "import.audio",
            json!({ "sourcePath": path.display().to_string(), "targetTrackId": id, "startTicks": 0 }),
        )
        .unwrap();
    }
    host
}

/// "'flac' is in the enum but the exporter REFUSES it with a typed Unsupported
/// error" — on master, on region, and on stems.
#[test]
fn flac_is_a_legal_enum_value_and_a_runtime_refusal_on_every_export() {
    let tmp = tempfile::tempdir().unwrap();
    let mut host = two_track_session(tmp.path());

    // It really is legal at the contract boundary: the refusal is the HOST's,
    // not the schema's, which is why the schema cannot be read as the answer.
    for cmd in ["export.master", "export.stems", "export.region"] {
        let spec = timeline_core::catalog::Catalog::get().spec(cmd).unwrap();
        let enum_values = spec.params_schema["properties"]["format"]["enum"]
            .as_array()
            .unwrap_or_else(|| panic!("{cmd} format enum"));
        assert!(
            enum_values.iter().any(|v| v == "flac"),
            "{cmd}'s format enum still has to contain flac for this claim to be worth making"
        );
    }

    let out = tmp.path().join("m.flac");
    let err = host
        .submit(
            Actor::user("t"),
            "export.master",
            json!({ "outputPath": out.display().to_string(), "format": "flac" }),
        )
        .expect_err("export.master refuses flac");
    assert!(
        format!("{err}").to_lowercase().contains("flac"),
        "the refusal must name the format: {err}"
    );

    let err = host
        .submit(
            Actor::user("t"),
            "export.region",
            json!({
                "outputPath": tmp.path().join("r.flac").display().to_string(),
                "startTicks": 0, "endTicks": 1920, "format": "flac"
            }),
        )
        .expect_err("export.region refuses flac");
    assert!(format!("{err}").to_lowercase().contains("flac"), "{err}");

    let err = host
        .submit(
            Actor::user("t"),
            "export.stems",
            json!({ "outputDir": tmp.path().join("stems").display().to_string(), "format": "flac" }),
        )
        .expect_err("export.stems refuses anything but wav");
    assert!(format!("{err}").to_lowercase().contains("wav"), "{err}");
}

/// "the enum admits 44100 and 48000, but v1 always exports at the PROJECT rate
/// and refuses any value that differs from it".
#[test]
fn sample_rate_hz_accepts_only_the_projects_own_rate() {
    let tmp = tempfile::tempdir().unwrap();
    let mut host = two_track_session(tmp.path());
    assert_eq!(host.project().sample_rate, RATE, "this session runs at 48 kHz");

    host.submit(
        Actor::user("t"),
        "export.master",
        json!({
            "outputPath": tmp.path().join("ok.wav").display().to_string(),
            "format": "wav", "sampleRateHz": 48000
        }),
    )
    .expect("the project's own rate is accepted");

    let err = host
        .submit(
            Actor::user("t"),
            "export.master",
            json!({
                "outputPath": tmp.path().join("no.wav").display().to_string(),
                "format": "wav", "sampleRateHz": 44100
            }),
        )
        .expect_err("the other enum value is refused");
    assert!(
        format!("{err}").contains("44100"),
        "the refusal must name the rate that was asked for: {err}"
    );
}

/// "NOT IMPLEMENTED: the exporter ignores it and always writes one WAV per
/// TRACK". The dangerous half of this is that it SUCCEEDS.
#[test]
fn the_stems_filter_is_ignored_and_the_export_is_per_track() {
    let tmp = tempfile::tempdir().unwrap();
    let mut host = two_track_session(tmp.path());

    let filtered = host
        .submit(
            Actor::user("t"),
            "export.stems",
            json!({
                "outputDir": tmp.path().join("filtered").display().to_string(),
                "format": "wav",
                "stems": ["vocals"]
            }),
        )
        .expect("asking for one stem SUCCEEDS, which is the problem");

    let stems = filtered["stems"].as_array().expect("stems array");
    assert_eq!(
        stems.len(),
        2,
        "a one-stem filter still wrote every TRACK: {filtered}"
    );
    let ids: Vec<&str> = stems.iter().filter_map(|s| s["trackId"].as_str()).collect();
    assert_eq!(
        ids,
        vec!["t1", "t2"],
        "the outputs are keyed by trackId, not by stem name — there is no vocals/drums/bass/other \
         axis in this exporter at all"
    );

    // Byte-identical to the unfiltered run: proof the parameter changes nothing
    // rather than merely producing the same count.
    let unfiltered = host
        .submit(
            Actor::user("t"),
            "export.stems",
            json!({
                "outputDir": tmp.path().join("unfiltered").display().to_string(),
                "format": "wav"
            }),
        )
        .expect("the unfiltered run");
    for (f, u) in stems.iter().zip(unfiltered["stems"].as_array().unwrap()) {
        let fa = std::fs::read(f["outputPath"].as_str().unwrap()).unwrap();
        let ua = std::fs::read(u["outputPath"].as_str().unwrap()).unwrap();
        assert_eq!(
            fa, ua,
            "the filtered and unfiltered exports of {} differ; if that is now true the \
             description must stop calling the filter unimplemented",
            f["trackId"]
        );
    }
}

/// The precedent this lane's findings follow: `import.audio` declares `separate`
/// and `conform`, reads NEITHER, and says so in the result. That disclosure is
/// the only thing standing between an agent and believing four stem tracks
/// exist, so it is executed here too — and the catalog description now carries
/// the same warning for callers who read the schema instead of the result.
#[test]
fn import_audio_still_discloses_the_flags_it_ignores() {
    let tmp = tempfile::tempdir().unwrap();
    let src = tmp.path().join("s.wav");
    write_wav_f32(&src, &tone(1.0, 330.0), RATE).unwrap();
    let mut host = StudioHost::create_at(&tmp.path().join("Imp.mstudio"), "Imp").unwrap();
    host.submit(Actor::user("t"), "track.add", json!({ "trackId": "t1", "name": "T" }))
        .unwrap();

    let out = host
        .submit(
            Actor::user("t"),
            "import.audio",
            json!({
                "sourcePath": src.display().to_string(),
                "targetTrackId": "t1",
                "separate": true,
                "conform": true
            }),
        )
        .expect("it returns ok: that is exactly the failure mode");

    let ignored: Vec<&str> = out["ignoredParams"]
        .as_array()
        .expect("the result must name what it ignored")
        .iter()
        .filter_map(Value::as_str)
        .collect();
    assert_eq!(ignored, vec!["separate", "conform"]);
    assert_eq!(
        host.project().tracks.len(),
        1,
        "separate:true landed ONE ordinary clip on ONE track, not four stem tracks"
    );

    // ...and the catalog says so as well, for a caller reading the tool schema.
    let spec = timeline_core::catalog::Catalog::get().spec("import.audio").unwrap();
    for flag in ["separate", "conform"] {
        let desc = spec.params_schema["properties"][flag]["description"]
            .as_str()
            .unwrap_or_else(|| panic!("{flag} description"));
        assert!(
            desc.contains("NOT IMPLEMENTED"),
            "import.audio's {flag} description must say it is not implemented: {desc}"
        );
    }
}
