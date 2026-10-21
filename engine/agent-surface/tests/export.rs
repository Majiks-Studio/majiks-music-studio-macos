//! L13 acceptance: export deliverables (master/region WAV+AAC, stems) run
//! through the offline bounce, land on the loudness target within 0.5 LU, and
//! the provenance manifest validates against its schema and honestly reports
//! the generated/imported split + per-clip lineage + the hash-chain head for a
//! session that has BOTH generated (landed) and imported clips.
//!
//! Silence-gated: nothing here opens an audio device (the bounce is offline).

use std::f64::consts::PI;
use std::path::Path;

use serde_json::Value;

use agent_surface::landing::{build_landing, InterleaveFixtureSeparator, LandingRequest};
use agent_surface::StudioHost;
use render::media::write_wav_f32;
use timeline_core::envelope::ActorKind;
use timeline_core::Actor;

const PROMPT: &str = "warm lofi hip hop with a rhodes and vinyl noise";
const MODEL: &str = "acestep-v15-turbo";
const SEED: i64 = 4242;
const RATE: u32 = 48_000;

/// A percussive click "song" with clear downbeats (the landing test's proven
/// input shape: the beat tracker measures the grid off this, not the tag).
fn synth_song(bpm: f64, bars: u32) -> Vec<[f32; 2]> {
    let beat = 60.0 / bpm;
    let total = beat * (bars * 4) as f64 + 0.5;
    let n = (total * RATE as f64) as usize;
    let mut out = vec![[0.0f32; 2]; n];
    let decay = 0.006;
    for (i, frame) in out.iter_mut().enumerate() {
        let t = i as f64 / RATE as f64;
        let beat_idx = (t / beat).floor();
        let into = t - beat_idx * beat;
        if into < decay {
            let downbeat = (beat_idx as u64).is_multiple_of(4);
            let (freq, amp) = if downbeat { (1500.0, 0.9) } else { (2000.0, 0.55) };
            let env = 1.0 - into / decay;
            let v = (amp * env * env * (2.0 * PI * freq * into).sin()) as f32;
            *frame = [v, v];
        }
    }
    out
}

/// A short imported tone (the VO / imported-audio stand-in).
fn synth_tone(secs: f64, freq: f64) -> Vec<[f32; 2]> {
    let n = (secs * RATE as f64) as usize;
    (0..n)
        .map(|i| {
            let v = (0.3 * (2.0 * PI * freq * i as f64 / RATE as f64).sin()) as f32;
            [v, v]
        })
        .collect()
}

/// Build a session with generated (landed) stems + one imported clip. The mix is
/// synthesized (deterministic beat grid), matching the proven landing setup.
fn mixed_session(dir: &Path) -> StudioHost {
    let mix = dir.join("mix.wav");
    write_wav_f32(&mix, &synth_song(120.0, 8), RATE).unwrap();
    let tone = dir.join("tone.wav");
    write_wav_f32(&tone, &synth_tone(2.0, 220.0), RATE).unwrap();

    let pkg = dir.join("Prov.mstudio");
    let work = dir.join("work");
    let req = LandingRequest {
        mix_path: mix,
        prompt: PROMPT.to_string(),
        declared_bpm: Some(120.0),
        key: Some("A minor".to_string()),
        // 8 bars at 120 bpm = 2 s/bar; sections at bars 0/2/4/6.
        section_tags: vec!["Intro".into(), "Verse".into(), "Chorus".into(), "Outro".into()],
        section_times: vec![0.0, 4.0, 8.0, 12.0],
        seed: Some(SEED),
        gen_model: Some(MODEL.to_string()),
        gen_device: Some("mlx".to_string()),
        source_kind: Some("generated".to_string()),
        project_name: Some("Prov".to_string()),
        truth_section_bars: None,
    };
    let actor = Actor { kind: ActorKind::Agent, name: "open-in-studio".into() };
    build_landing(&pkg, &req, &InterleaveFixtureSeparator, &work, actor).expect("landing");

    let mut host = StudioHost::open_package(&pkg).expect("open landed package");
    // Add an imported clip on a new track (chain of custody begins at import).
    host.submit(Actor::user("app"), "track.add", serde_json::json!({ "trackId": "vo", "name": "VO" }))
        .expect("track.add");
    host.import_audio(&tone.display().to_string(), "vo", 0, Some("vo1".to_string()))
        .expect("import");
    host
}

fn load_schema() -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../contracts/provenance-manifest.schema.json");
    let text = std::fs::read_to_string(&path).expect("read manifest schema");
    serde_json::from_str(&text).expect("parse manifest schema")
}

#[test]
fn manifest_reports_the_split_lineage_and_hash_chain_head() {
    let tmp = tempfile::tempdir().unwrap();
    let host = mixed_session(tmp.path());
    let manifest = host.manifest_value();

    // 1. It validates against the contract schema.
    let schema = load_schema();
    let errors = timeline_core::schema::validate(&schema, &manifest);
    assert!(errors.is_empty(), "manifest schema errors: {errors:?}\n{manifest:#}");

    // 2. The generated/imported split is honest: both present (mixed session).
    let comp = &manifest["composition"];
    let gen_clips = comp["byClipCount"]["generated"].as_u64().unwrap();
    let imp_clips = comp["byClipCount"]["imported"].as_u64().unwrap();
    assert!(gen_clips >= 4, "expected the 4 landed stems generated, got {gen_clips}");
    assert_eq!(imp_clips, 1, "expected exactly the one imported clip");
    let gen_pct = comp["byDuration"]["generatedPct"].as_f64().unwrap();
    let imp_pct = comp["byDuration"]["importedPct"].as_f64().unwrap();
    assert!(gen_pct > 0.0 && imp_pct > 0.0, "split not populated: {gen_pct}/{imp_pct}");

    // 3. AI disclosure: mixed content -> composite IPTC term, aiGenerated true.
    let ai = &manifest["aiDisclosure"];
    assert_eq!(ai["aiGenerated"], Value::Bool(true));
    assert_eq!(
        ai["digitalSourceType"],
        "http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia"
    );
    assert_eq!(ai["standard"], "EU AI Act Article 50(2)");
    let models = ai["models"].as_array().unwrap();
    assert!(models.iter().any(|m| m == MODEL), "model missing from disclosure: {models:?}");

    // 4. Per-clip lineage: a generated clip carries the prompt + engine identity;
    //    the imported clip reads as imported (digitalCapture).
    let clips = manifest["clips"].as_array().unwrap();
    let gen_clip = clips
        .iter()
        .find(|c| c["origin"] == "generated")
        .expect("a generated clip");
    assert_eq!(gen_clip["digitalSourceType"], "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia");
    let lin = &gen_clip["lineage"];
    assert_eq!(lin["prompt"], PROMPT, "prompt lost from lineage");
    assert_eq!(lin["engine"]["model"], MODEL);
    assert_eq!(lin["engine"]["seed"].as_i64().unwrap(), SEED);
    assert_eq!(lin["engine"]["device"], "mlx");
    assert!(lin["sourceCommand"].as_str().unwrap().starts_with("gen."));

    let imp_clip = clips.iter().find(|c| c["clipId"] == "vo1").expect("imported clip");
    assert_eq!(imp_clip["origin"], "imported");
    assert_eq!(imp_clip["digitalSourceType"], "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture");

    // 5. The hash-chain head matches the live session tip + entry count.
    let hc = &manifest["hashChain"];
    assert_eq!(hc["algorithm"], "blake3");
    assert_eq!(hc["genesisHash"].as_str().unwrap(), "0".repeat(64));
    let snap = host.snapshot(None);
    let seq = snap["seq"].as_u64().unwrap();
    assert_eq!(hc["entryCount"].as_u64().unwrap(), seq, "entryCount != seq");
    let tip = hc["tipHash"].as_str().unwrap();
    assert_eq!(tip.len(), 64);
    assert!(tip.chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn master_export_wav_hits_the_loudness_target_and_journals() {
    let tmp = tempfile::tempdir().unwrap();
    let mut host = mixed_session(tmp.path());
    let out = tmp.path().join("Master.wav");
    let manifest_side = tmp.path().join("Master.manifest.json");

    let res = host
        .submit(
            Actor::user("app"),
            "export.master",
            serde_json::json!({
                "outputPath": out.display().to_string(),
                "format": "wav",
                "loudnessTarget": "streaming",
                "includeManifest": true
            }),
        )
        .expect("export.master");

    assert_eq!(res["ok"], Value::Bool(true));
    assert_eq!(res["format"], "wav");
    assert_eq!(res["bitDepth"].as_u64().unwrap(), 24);
    assert!(out.exists(), "master wav not written");

    // Loudness landed within 0.5 LU of -14 (streaming).
    let loud = &res["loudness"];
    assert_eq!(loud["target"], "streaming");
    let after = loud["integratedLufsAfter"].as_f64().unwrap();
    assert!((after - (-14.0)).abs() <= 0.5, "streaming master at {after} LUFS (want -14 +-0.5)");
    assert!(loud["errorLu"].as_f64().unwrap() <= 0.5);

    // The sidecar manifest was written and validates.
    assert!(manifest_side.exists(), "sidecar manifest missing");
    assert_eq!(res["manifestPath"].as_str().unwrap(), manifest_side.display().to_string());
    let side: Value = serde_json::from_str(&std::fs::read_to_string(&manifest_side).unwrap()).unwrap();
    assert!(timeline_core::schema::validate(&load_schema(), &side).is_empty());

    // The export was journaled (provenance: what was exported, from which state).
    let page = host.journal_page(None, 500);
    let names: Vec<&str> = page["entries"].as_array().unwrap().iter().filter_map(|e| e["name"].as_str()).collect();
    assert!(names.contains(&"export.master"), "export.master not journaled: {names:?}");
}

#[test]
fn master_export_none_target_null_matches_the_offline_bounce() {
    // The 24-bit deliverable is the offline bounce, quantized: reading it back
    // must match render_master() within one 24-bit LSB (the export writes the
    // same samples the null-tested graph produced).
    let tmp = tempfile::tempdir().unwrap();
    let mut host = mixed_session(tmp.path());
    let out = tmp.path().join("Raw.wav");
    host.submit(
        Actor::user("app"),
        "export.master",
        serde_json::json!({ "outputPath": out.display().to_string(), "format": "wav", "loudnessTarget": "none" }),
    )
    .expect("export.master none");

    let rendered = host.render_master().expect("render_master");
    let mut reader = hound::WavReader::open(&out).unwrap();
    assert_eq!(reader.spec().bits_per_sample, 24);
    let read: Vec<i32> = reader.samples::<i32>().map(|x| x.unwrap()).collect();
    assert_eq!(read.len(), rendered.len() * 2, "frame count mismatch");
    let mut max_err = 0.0_f32;
    for (i, frame) in rendered.iter().enumerate() {
        for ch in 0..2 {
            let back = read[i * 2 + ch] as f32 / 8_388_607.0;
            max_err = max_err.max((frame[ch].clamp(-1.0, 1.0) - back).abs());
        }
    }
    assert!(max_err < 2.0 / 8_388_607.0, "deliverable diverges from bounce: {max_err}");
}

#[test]
fn region_and_aac_exports_write_deliverables() {
    let tmp = tempfile::tempdir().unwrap();
    let mut host = mixed_session(tmp.path());

    // Region export (one bar) as WAV.
    let region = tmp.path().join("Region.wav");
    host.submit(
        Actor::user("app"),
        "export.region",
        serde_json::json!({
            "outputPath": region.display().to_string(),
            "startTicks": 0, "endTicks": 3840, "format": "wav"
        }),
    )
    .expect("export.region");
    assert!(region.exists());
    let rr = hound::WavReader::open(&region).unwrap();
    assert_eq!(rr.spec().bits_per_sample, 24);

    // Stems export (24-bit WAV per track) with a manifest.
    let stems_dir = tmp.path().join("stems");
    let res = host
        .submit(
            Actor::user("app"),
            "export.stems",
            serde_json::json!({ "outputDir": stems_dir.display().to_string(), "format": "wav", "includeManifest": true }),
        )
        .expect("export.stems");
    let stems = res["stems"].as_array().unwrap();
    assert!(stems.len() >= 5, "expected >=5 stem files (4 landed + VO)");
    for s in stems {
        assert!(Path::new(s["outputPath"].as_str().unwrap()).exists());
    }

    // AAC master via AudioToolbox (macOS): a decodable, non-trivial .m4a.
    #[cfg(target_os = "macos")]
    {
        let aac = tmp.path().join("Master.m4a");
        let res = host
            .submit(
                Actor::user("app"),
                "export.master",
                serde_json::json!({ "outputPath": aac.display().to_string(), "format": "aac", "loudnessTarget": "club" }),
            )
            .expect("export.master aac");
        assert_eq!(res["format"], "aac");
        assert!(aac.exists());
        assert!(std::fs::metadata(&aac).unwrap().len() > 1_000, "m4a too small");
    }
}

// ---------------------------------------------------------------------------
// Clip origin in the WRITTEN manifest.
//
// These assert on the JSON the user actually ships, read back off disk, not on
// `ClipOrigin`. The bug this covers lived one layer BELOW the enum: every note
// clip - a piece someone wrote in the piano roll AND a take they performed on a
// controller - was written into the shipped manifest as `"origin": "imported"`
// with `"assetHash": ""`, because classification fell through to an
// "no generative record -> imported" default.
// ---------------------------------------------------------------------------

use agent_surface::midi::event::MidiEvent;
use agent_surface::midi::feed_event;

const KEYBOARD: &str = "usb midi interface";

fn instrument_track(host: &mut StudioHost, track_id: &str, name: &str) {
    host.submit(Actor::user("test"), "track.add", serde_json::json!({ "trackId": track_id, "name": name }))
        .expect("track.add");
    host.submit(
        Actor::user("test"),
        "device.add",
        serde_json::json!({ "trackId": track_id, "deviceId": format!("{track_id}_synth"), "kind": "synth" }),
    )
    .expect("device.add");
}

/// (c) A clip WRITTEN in the piano roll: place the note clip, then add notes,
/// both under the app actor - exactly what `RealStudioNoteEngine` submits.
fn author_midi_clip(host: &mut StudioHost, track_id: &str, clip_id: &str) {
    instrument_track(host, track_id, "Keys (written)");
    host.submit(
        Actor::user("app"),
        "clip.placeMidi",
        serde_json::json!({ "clipId": clip_id, "trackId": track_id, "startTicks": 0, "lengthTicks": 3840 }),
    )
    .expect("clip.placeMidi");
    host.submit(
        Actor::user("app"),
        "note.add",
        serde_json::json!({
            "clipId": clip_id,
            "notes": [{ "noteId": "n1", "pitch": 60, "startTicks": 0, "lengthTicks": 480, "velocity": 96 }]
        }),
    )
    .expect("note.add");
}

/// (d) A take the user PLAYED: arm the track and drive the real MIDI capture
/// path (no hardware, no audio device - the clock is driven explicitly).
fn record_midi_take(host: &mut StudioHost, track_id: &str) -> String {
    instrument_track(host, track_id, "Keys (played)");
    host.submit(Actor::user("test"), "track.arm", serde_json::json!({ "trackId": track_id, "armed": true }))
        .expect("track.arm");
    let start = host
        .submit(Actor::user("test"), "record.start", serde_json::json!({ "trackId": track_id, "startTicks": 0 }))
        .expect("record.start");
    assert_eq!(start["kind"], "midi", "expected a MIDI capture on an instrument track");
    for (i, pitch) in [60u8, 64, 67].iter().enumerate() {
        let on = (i as u64) * 960;
        host.midi_record_set_now_ticks(on);
        feed_event(host, KEYBOARD, &MidiEvent::NoteOn { note: *pitch, velocity: 100, channel: 0 });
        host.midi_record_set_now_ticks(on + 480);
        feed_event(host, KEYBOARD, &MidiEvent::NoteOff { note: *pitch, velocity: 0, channel: 0 });
    }
    let stop = host.submit(Actor::user("test"), "record.stop", serde_json::json!({})).expect("record.stop");
    assert_eq!(stop["landed"], true, "MIDI take did not land: {stop:#}");
    stop["clipId"].as_str().expect("landed clipId").to_string()
}

/// A session carrying ALL FOUR origins: generated stems + an imported audio
/// clip (from `mixed_session`), a written note clip, and a performed take.
fn four_origin_session(dir: &Path) -> (StudioHost, String) {
    std::env::remove_var("MAJIKS_TEST_AUDIBLE");
    let mut host = mixed_session(dir);
    author_midi_clip(&mut host, "keys_written", "clip_written");
    let recorded = record_midi_take(&mut host, "keys_played");
    (host, recorded)
}

/// Write the manifest through the real export command and read the FILE back.
fn exported_manifest(host: &mut StudioHost, dir: &Path) -> Value {
    let path = dir.join("Origins.manifest.json");
    host.submit(
        Actor::user("app"),
        "export.manifest",
        serde_json::json!({ "outputPath": path.display().to_string() }),
    )
    .expect("export.manifest");
    assert!(path.exists(), "export.manifest wrote no file");
    serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).expect("parse written manifest")
}

fn clip_by_id<'a>(manifest: &'a Value, id: &str) -> &'a Value {
    manifest["clips"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["clipId"] == id)
        .unwrap_or_else(|| panic!("clip {id} missing from manifest: {manifest:#}"))
}

#[test]
fn written_manifest_names_all_four_origins() {
    let tmp = tempfile::tempdir().unwrap();
    let (mut host, recorded_id) = four_origin_session(tmp.path());
    let manifest = exported_manifest(&mut host, tmp.path());

    // It still validates against the contract.
    let errors = timeline_core::schema::validate(&load_schema(), &manifest);
    assert!(errors.is_empty(), "manifest schema errors: {errors:?}\n{manifest:#}");

    // (a) generated - a landed stem.
    let generated = manifest["clips"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["origin"] == "generated")
        .expect("a generated clip");
    assert_eq!(
        generated["digitalSourceType"],
        "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia"
    );
    assert!(generated["assetHash"].as_str().unwrap().len() == 64);

    // (b) imported audio.
    let imported = clip_by_id(&manifest, "vo1");
    assert_eq!(imported["origin"], "imported", "imported audio misreported: {imported:#}");
    assert_eq!(
        imported["digitalSourceType"],
        "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture"
    );

    // (c) AUTHORED - written in the piano roll. The old manifest said
    // "imported" here, which was a claim about a file that never existed.
    let authored = clip_by_id(&manifest, "clip_written");
    assert_eq!(authored["origin"], "authored", "a clip written in the roll is not imported: {authored:#}");
    assert_eq!(
        authored["digitalSourceType"],
        "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCreation"
    );
    assert_eq!(authored["lineage"]["sourceCommand"], "clip.placeMidi");

    // (d) RECORDED - a performance. The old manifest said "imported" here too:
    // the product's headline claim, false about the one clip a human played.
    let recorded = clip_by_id(&manifest, &recorded_id);
    assert_eq!(recorded["origin"], "recorded", "a performed MIDI take is not imported: {recorded:#}");
    assert_eq!(
        recorded["digitalSourceType"],
        "http://cv.iptc.org/newscodes/digitalsourcetype/digitalCapture"
    );
    assert_eq!(recorded["lineage"]["sourceCommand"], "record.midi");

    // No clip anywhere in a session with two note clips reads "imported"
    // except the one audio file that really was imported.
    let imported_ids: Vec<&str> = manifest["clips"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| c["origin"] == "imported")
        .map(|c| c["clipId"].as_str().unwrap())
        .collect();
    assert_eq!(imported_ids, vec!["vo1"], "only the imported file is imported");
}

#[test]
fn a_clip_with_no_asset_omits_asset_hash_rather_than_claiming_an_empty_one() {
    let tmp = tempfile::tempdir().unwrap();
    let (mut host, recorded_id) = four_origin_session(tmp.path());
    let manifest = exported_manifest(&mut host, tmp.path());

    for id in ["clip_written", recorded_id.as_str()] {
        let clip = clip_by_id(&manifest, id);
        assert!(
            clip.get("assetHash").is_none(),
            "note clip {id} must OMIT assetHash, not carry \"\": {clip:#}"
        );
    }
    // The audio clips still carry theirs - omission is about absence of an
    // asset, not about dropping the field.
    assert_eq!(clip_by_id(&manifest, "vo1")["assetHash"].as_str().unwrap().len(), 64);
}

#[test]
fn the_composition_split_counts_note_clips_as_themselves() {
    let tmp = tempfile::tempdir().unwrap();
    let (mut host, _) = four_origin_session(tmp.path());
    let manifest = exported_manifest(&mut host, tmp.path());
    let by_count = &manifest["composition"]["byClipCount"];

    assert_eq!(by_count["authored"].as_u64().unwrap(), 1, "one written note clip");
    assert_eq!(by_count["recorded"].as_u64().unwrap(), 1, "one performed take");
    assert_eq!(by_count["imported"].as_u64().unwrap(), 1, "only the imported audio file");
    assert!(by_count["generated"].as_u64().unwrap() >= 4);

    // The four buckets account for every clip, and the tick split does too.
    let total: u64 = ["generated", "imported", "recorded", "authored"]
        .iter()
        .map(|k| by_count[*k].as_u64().unwrap())
        .sum();
    assert_eq!(total, manifest["composition"]["clipCount"].as_u64().unwrap());
    let by_dur = &manifest["composition"]["byDuration"];
    let ticks: u64 = ["generatedTicks", "importedTicks", "recordedTicks", "authoredTicks"]
        .iter()
        .map(|k| by_dur[*k].as_u64().unwrap())
        .sum();
    assert_eq!(ticks, by_dur["totalTicks"].as_u64().unwrap());
    assert!(by_dur["authoredTicks"].as_u64().unwrap() > 0);
}

#[test]
fn the_snapshot_reports_the_same_origin_the_manifest_does() {
    // The export dialog's pre-export preview reads the snapshot. A preview that
    // disagrees with the artifact it previews is its own bug, so the snapshot
    // carries the manifest's OWN classification rather than a second guess.
    let tmp = tempfile::tempdir().unwrap();
    let (mut host, _) = four_origin_session(tmp.path());
    let manifest = exported_manifest(&mut host, tmp.path());
    let snap = host.snapshot(None);

    let mut checked = 0;
    for track in snap["project"]["tracks"].as_array().unwrap() {
        for clip in track["clips"].as_array().unwrap() {
            let id = clip["id"].as_str().unwrap();
            let snap_origin = clip["origin"].as_str().unwrap_or_else(|| {
                panic!("snapshot clip {id} carries no origin: {clip:#}")
            });
            assert_eq!(
                snap_origin,
                clip_by_id(&manifest, id)["origin"].as_str().unwrap(),
                "snapshot and manifest disagree about clip {id}"
            );
            checked += 1;
        }
    }
    assert!(checked >= 6, "expected the whole four-origin session, saw {checked} clips");
}

#[test]
fn manifests_exported_before_authored_existed_still_validate() {
    // BACKWARD COMPATIBILITY, proven against a real shipped artifact rather
    // than by reading the diff: `docs/evidence/l13-sample-manifest.json` was
    // exported when `origin` had three values, `assetHash` was required, and
    // `byClipCount` had no `authored` key. Adding an enum value and adding
    // OPTIONAL properties are widenings; adding to `required` would not be,
    // and this test is what stops the next lane from doing it.
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/evidence/l13-sample-manifest.json");
    let text = std::fs::read_to_string(&path).expect("read shipped sample manifest");
    let old: Value = serde_json::from_str(&text).expect("parse shipped sample manifest");

    // It really is a pre-`authored` document.
    assert!(old["composition"]["byClipCount"].get("authored").is_none());
    assert!(old["composition"]["byDuration"].get("authoredTicks").is_none());
    assert!(old["clips"].as_array().unwrap().iter().all(|c| c.get("assetHash").is_some()));

    let errors = timeline_core::schema::validate(&load_schema(), &old);
    assert!(errors.is_empty(), "a shipped manifest no longer validates: {errors:?}");
}
