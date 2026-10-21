//! L10 acceptance, headless: the Takes system on top of L9's revise engine.
//!
//!  - takes.list classifies each take (revise = auditionable alternative,
//!    landing = provenance anchor) and joins its lineage (prompt/seed/model/
//!    engine + the region it revised), so the browser and any agent read one
//!    rich record;
//!  - per-stem take mixing commits the CHOSEN take per stem (drums from take 1,
//!    other from take 2), composed from L9's variant promotions;
//!  - takes survive save + reopen with their lineage and promoted state;
//!  - purge reclaims candidate take audio (records stay queryable as lineage,
//!    read back offline) and never touches a placed clip or an un-splice;
//!  - a landed song's gen.song take is provenance, not an auditionable take
//!    (the L8 follow-up), while staying queryable;
//!  - the whole read + purge path runs via MCP (dispatch_tool) for agent parity.
//!
//! Silence-gated: low-amplitude tones (<= about 0.05 peak), no audio device.

use std::f32::consts::PI;
use std::path::Path;

use agent_surface::landing::{build_landing, InterleaveFixtureSeparator};
use agent_surface::{dispatch_tool, LandingRequest, StudioHost};
use render::media::write_wav_f32;
use serde_json::{json, Value};
use timeline_core::Actor;

const RATE: u32 = 48_000;
const BPM: f64 = 120.0;
const BAR_TICKS: u64 = 4 * 960; // one bar at 120 bpm = 2 s
const STEMS: [&str; 4] = ["vocals", "drums", "bass", "other"];

fn user() -> Actor {
    Actor::user("test")
}

fn synth_stem(stem: &str, bars: u32) -> Vec<[f32; 2]> {
    let freq = match stem {
        "vocals" => 440.0,
        "drums" => 130.0,
        "bass" => 65.0,
        "other" => 330.0,
        _ => 261.63,
    };
    let n = (bars as f64 * (4.0 * 60.0 / BPM) * RATE as f64) as usize;
    let mut out = vec![[0.0f32; 2]; n];
    for (i, f) in out.iter_mut().enumerate() {
        let t = i as f64 / RATE as f64;
        let v = (0.04 * (2.0 * PI as f64 * freq * t).sin()) as f32;
        *f = [v, v];
    }
    out
}

fn synth_song(bars: u32) -> Vec<[f32; 2]> {
    let n = (bars as f64 * (4.0 * 60.0 / BPM) * RATE as f64) as usize;
    let mut out = vec![[0.0f32; 2]; n];
    for (i, f) in out.iter_mut().enumerate() {
        let t = i as f64 / RATE as f64;
        let v = (0.03 * (2.0 * PI as f64 * 220.0 * t).sin()
            + 0.015 * (2.0 * PI as f64 * 110.0 * t).sin()) as f32;
        *f = [v, v];
    }
    out
}

/// A 4-stem, 4-bar session (one stem clip per track at tick 0).
fn build_session(pkg: &Path) -> StudioHost {
    let mut host = StudioHost::create_at(pkg, "TakesTest").unwrap();
    host.submit(user(), "project.setTempo", json!({ "bpm": 120 })).unwrap();
    let work = pkg.join("_synth");
    std::fs::create_dir_all(&work).unwrap();
    for stem in STEMS {
        let track_id = format!("trk_{stem}");
        host.submit(user(), "track.add", json!({ "trackId": track_id, "name": stem })).unwrap();
        let wav = work.join(format!("{stem}.wav"));
        write_wav_f32(&wav, &synth_stem(stem, 4), RATE).unwrap();
        host.import_audio(&wav.to_string_lossy(), &track_id, 0, Some(format!("clip_{stem}")))
            .unwrap();
    }
    host
}

fn clip_asset(host: &StudioHost, clip_id: &str) -> String {
    host.project().clip(clip_id).unwrap().source_id.clone()
}

/// Run a drums+other revise with `variants` variants over bar 2.
fn revise_drums_other(host: &mut StudioHost, variants: u32) -> Value {
    agent_surface::revise::dispatch_revise(
        host,
        user(),
        &json!({
            "clipIds": ["clip_drums", "clip_other"],
            "regionStartTicks": BAR_TICKS,
            "regionEndTicks": 2 * BAR_TICKS,
            "scope": ["drums", "other"],
            "instruction": "half-time, darker pads",
            "variants": variants,
            "seed": 22,
            "engine": "mock"
        }),
    )
    .unwrap()
}

/// The takeId of the promotion for `stem` in variant `v` of a revise result.
fn take_of(result: &Value, v: usize, stem: &str) -> String {
    result["variantTakes"][v]["promotions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["stem"] == json!(stem))
        .unwrap()["takeId"]
        .as_str()
        .unwrap()
        .to_string()
}

/// The stem asset hash of a take, read from takes.list (browser parity path).
fn take_asset(host: &StudioHost, take_id: &str, stem: &str) -> String {
    let takes = host.takes(&json!({}));
    takes["takes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["takeId"] == json!(take_id))
        .unwrap_or_else(|| panic!("take {take_id} not in takes.list"))["assetHashes"][stem]
        .as_str()
        .unwrap()
        .to_string()
}

fn takes_of(list: &Value) -> &Vec<Value> {
    list["takes"].as_array().unwrap()
}

/// Take count of a takes.list value (usable on a temporary, unlike `takes_of`).
fn count(list: &Value) -> usize {
    list["takes"].as_array().unwrap().len()
}

// ---------------------------------------------------------------------------

#[test]
fn revise_takes_classify_as_auditionable_with_joined_lineage() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = build_session(&dir.path().join("Classify.mstudio"));
    revise_drums_other(&mut host, 3);

    let list = host.takes(&json!({}));
    let takes = takes_of(&list);
    assert_eq!(takes.len(), 6, "2 stems x 3 variants = 6 candidate takes");

    for t in takes {
        assert_eq!(t["kind"], json!("revise"));
        assert_eq!(t["status"], json!("candidate"));
        assert_eq!(t["auditionable"], json!(true), "revise candidates are auditionable");
        assert_eq!(t["provenance"], json!(false));
        assert_eq!(t["offline"], json!(false));
        // Joined lineage: prompt (instruction), seed + model (engine identity),
        // and the region the revise touched.
        let lin = &t["lineage"];
        assert_eq!(lin["prompt"], json!("half-time, darker pads"));
        assert!(lin["seed"].is_number(), "seed present in lineage");
        assert!(lin["model"].is_string(), "model present in lineage");
        assert_eq!(lin["regionStartTicks"], json!(BAR_TICKS));
        assert_eq!(lin["regionEndTicks"], json!(2 * BAR_TICKS));
        assert!(t["createdSeq"].is_number(), "creation order recorded");
    }

    // Filters: only the first stem's request, and auditionable-only is a no-op here.
    let req0 = takes[0]["requestId"].clone();
    assert_eq!(count(&host.takes(&json!({ "requestId": req0 }))), 3, "3 variants for the first stem's request");
    assert_eq!(count(&host.takes(&json!({ "auditionableOnly": true }))), 6);
}

#[test]
fn per_stem_mix_commits_the_chosen_take_per_stem() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = build_session(&dir.path().join("Mix.mstudio"));
    let result = revise_drums_other(&mut host, 2);

    // The per-stem mix (01-DESIGN 3.2 step 4): drums from take 1 (variant 0),
    // other from take 2 (variant 1). The two variants are genuinely different.
    let drums_v0 = take_of(&result, 0, "drums");
    let other_v1 = take_of(&result, 1, "other");
    let drums_v0_asset = take_asset(&host, &drums_v0, "drums");
    let other_v1_asset = take_asset(&host, &other_v1, "other");
    let drums_v1_asset = take_asset(&host, &take_of(&result, 1, "drums"), "drums");
    assert_ne!(drums_v0_asset, drums_v1_asset, "the two drums variants differ (a real mix)");

    // Commit the COMPOSED selection, one take per stem, as one undo txn.
    let commit = agent_surface::revise::dispatch_commit(
        &mut host,
        user(),
        &json!({
            "promotions": [
                { "takeId": drums_v0, "clipId": "clip_drums" },
                { "takeId": other_v1, "clipId": "clip_other" },
            ],
            "reason": "per-stem mix: drums take 1, other take 2"
        }),
    )
    .unwrap();
    assert_eq!(commit["undo"], json!("one step"));

    // Each clip carries the asset of the take chosen FOR THAT STEM.
    assert_eq!(clip_asset(&host, "clip_drums"), drums_v0_asset, "drums = variant 0's take");
    assert_eq!(clip_asset(&host, "clip_other"), other_v1_asset, "other = variant 1's take");

    // The two chosen takes read back promoted into their clips.
    let list = host.takes(&json!({}));
    let promoted: Vec<&Value> = takes_of(&list).iter().filter(|t| t["status"] == json!("promoted")).collect();
    assert_eq!(promoted.len(), 2);
    let d = promoted.iter().find(|t| t["takeId"] == json!(drums_v0)).unwrap();
    assert_eq!(d["promotedInto"], json!("clip_drums"));

    // One undo restores both clips (the whole per-stem commit is one step).
    host.undo(user()).unwrap();
    assert_ne!(clip_asset(&host, "clip_drums"), drums_v0_asset, "undo un-spliced drums");
    assert_ne!(clip_asset(&host, "clip_other"), other_v1_asset, "undo un-spliced other");
}

#[test]
fn takes_survive_save_and_reopen_with_lineage() {
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("Persist.mstudio");
    let promoted_take;
    {
        let mut host = build_session(&pkg);
        let result = revise_drums_other(&mut host, 2);
        promoted_take = take_of(&result, 0, "drums");
        agent_surface::revise::dispatch_commit(
            &mut host,
            user(),
            &json!({ "promotions": [{ "takeId": promoted_take, "clipId": "clip_drums" }], "reason": "commit" }),
        )
        .unwrap();
        host.save().unwrap();
    }

    // Reopen from disk: the takes + their lineage + promoted state survive.
    let host = StudioHost::open_package(&pkg).expect("reopen");
    let list = host.takes(&json!({}));
    let takes = takes_of(&list);
    assert_eq!(takes.len(), 4, "2 stems x 2 variants survive save/reopen");

    let promoted = takes.iter().find(|t| t["takeId"] == json!(promoted_take)).unwrap();
    assert_eq!(promoted["status"], json!("promoted"), "committed take is still promoted");
    assert_eq!(promoted["promotedInto"], json!("clip_drums"));
    assert_eq!(promoted["lineage"]["prompt"], json!("half-time, darker pads"), "lineage survived");
    assert!(promoted["lineage"]["model"].is_string());
    // The committed clip still resolves its promoted asset (not offline).
    assert_eq!(promoted["offline"], json!(false));
}

#[test]
fn purge_reclaims_candidate_audio_keeps_lineage_and_protects_placed() {
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("Purge.mstudio");
    let mut host = build_session(&pkg);
    let result = revise_drums_other(&mut host, 2);
    // Commit variant 0 (drums + other): 2 takes promoted, 2 candidates remain.
    let drums_v0 = take_of(&result, 0, "drums");
    let other_v0 = take_of(&result, 0, "other");
    agent_surface::revise::dispatch_commit(
        &mut host,
        user(),
        &json!({ "promotions": [
            { "takeId": drums_v0, "clipId": "clip_drums" },
            { "takeId": other_v0, "clipId": "clip_other" },
        ], "reason": "commit v0" }),
    )
    .unwrap();
    let committed_drums_asset = clip_asset(&host, "clip_drums");

    // No confirm -> refused (destructive).
    assert!(host.purge_takes(&json!({})).is_err(), "purge needs confirm");

    // Purge with confirm: reclaims the 2 remaining candidate assets only.
    let report = host.purge_takes(&json!({ "confirm": true })).unwrap();
    assert_eq!(report["assetsDeleted"], json!(2), "the 2 un-promoted candidate assets");
    assert!(report["bytesReclaimed"].as_u64().unwrap() > 0, "space reclaimed on disk");
    assert_eq!(report["purgedTakeIds"].as_array().unwrap().len(), 2);

    // The take RECORDS stay (queryable as lineage); purged candidates read offline.
    let list = host.takes(&json!({}));
    let takes = takes_of(&list);
    assert_eq!(takes.len(), 4, "all four take records remain");
    let candidates: Vec<&Value> = takes.iter().filter(|t| t["status"] == json!("candidate")).collect();
    assert_eq!(candidates.len(), 2);
    for c in &candidates {
        assert_eq!(c["offline"], json!(true), "purged candidate reads offline");
        assert_eq!(c["auditionable"], json!(false), "purged is not auditionable");
        assert!(c["lineage"]["prompt"].is_string(), "lineage kept after purge");
    }
    // auditionableOnly now drops the purged candidates.
    assert_eq!(count(&host.takes(&json!({ "auditionableOnly": true }))), 0);

    // The committed clip's audio was NEVER purged (still on disk + resolvable).
    assert_eq!(clip_asset(&host, "clip_drums"), committed_drums_asset);
    let audio_file = pkg.join("audio").join(format!("{committed_drums_asset}.wav"));
    assert!(audio_file.exists(), "the placed clip's audio is protected from purge");
    // And the promoted take is not offline.
    let promoted_drums = takes.iter().find(|t| t["takeId"] == json!(drums_v0)).unwrap();
    assert_eq!(promoted_drums["offline"], json!(false));
}

#[test]
fn landing_song_take_is_provenance_not_auditionable() {
    // L8 follow-up: a landed song's gen.song take is a provenance ANCHOR, not
    // an alternative take. It is classified landing/provenance (out of the
    // auditionable list) but stays queryable as lineage.
    let dir = tempfile::tempdir().unwrap();
    let mix = dir.path().join("mysong.wav");
    write_wav_f32(&mix, &synth_song(8), RATE).unwrap();
    let pkg = dir.path().join("Landed.mstudio");
    let req = LandingRequest {
        mix_path: mix,
        prompt: "warm lofi with a sax hook".into(),
        section_tags: vec!["Intro".into(), "Verse".into(), "Chorus".into()],
        gen_model: Some("acestep-v15-turbo".into()),
        seed: Some(4242),
        ..Default::default()
    };
    build_landing(&pkg, &req, &InterleaveFixtureSeparator, &dir.path().join("work"), user()).unwrap();

    let host = StudioHost::open_package(&pkg).expect("reopen landed");
    let list = host.takes(&json!({}));
    let takes = takes_of(&list);
    assert_eq!(takes.len(), 1, "the landing records one gen.song provenance take");
    let landing = &takes[0];
    assert_eq!(landing["kind"], json!("landing"));
    assert_eq!(landing["provenance"], json!(true));
    assert_eq!(landing["auditionable"], json!(false), "the whole placed song is not an alternative take");
    assert_eq!(landing["offline"], json!(false), "its stems resolve (only the mix blob is undecoded)");
    // Still queryable as lineage: prompt + model + seed joined.
    assert_eq!(landing["lineage"]["prompt"], json!("warm lofi with a sax hook"));
    assert_eq!(landing["lineage"]["model"], json!("acestep-v15-turbo"));
    assert_eq!(landing["lineage"]["seed"], json!(4242));

    // The auditionable Takes list is EMPTY (no clutter), the L8 decision.
    assert_eq!(count(&host.takes(&json!({ "auditionableOnly": true }))), 0);
    // But filtering by kind still surfaces it for a lineage view.
    assert_eq!(count(&host.takes(&json!({ "kind": "landing" }))), 1);
}

#[test]
fn takes_browser_reads_and_purges_via_mcp_for_agent_parity() {
    // Agent parity: the browser's reads + purge run through the same
    // dispatch_tool path an MCP agent uses.
    let dir = tempfile::tempdir().unwrap();
    let mut host = build_session(&dir.path().join("Parity.mstudio"));
    revise_drums_other(&mut host, 2);

    let list = dispatch_tool(&mut host, user(), "studio_takes", json!({ "auditionableOnly": true })).unwrap();
    assert_eq!(takes_of(&list).len(), 4, "4 auditionable candidate takes via MCP");
    assert!(list["takes"][0]["lineage"]["prompt"].is_string(), "lineage over MCP");

    // Purge over MCP requires confirm (the Manage gate).
    assert!(dispatch_tool(&mut host, user(), "studio_purge_takes", json!({})).is_err());
    let report = dispatch_tool(&mut host, user(), "studio_purge_takes", json!({ "confirm": true })).unwrap();
    assert_eq!(report["assetsDeleted"], json!(4), "all four un-committed candidates reclaimed");
    // After purge, nothing is auditionable but the records remain queryable.
    let after = dispatch_tool(&mut host, user(), "studio_takes", json!({})).unwrap();
    assert_eq!(takes_of(&after).len(), 4);
    assert_eq!(count(&dispatch_tool(&mut host, user(), "studio_takes", json!({ "auditionableOnly": true })).unwrap()), 0);
}
