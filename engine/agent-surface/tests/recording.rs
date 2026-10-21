use agent_surface::StudioHost;
use timeline_core::Actor;

#[test]
fn synthetic_record_lands_media_and_undoes_clip_without_opening_output() {
    // This test deliberately uses only the offline host path. It must remain
    // safe on a workstation with live monitors: no render::Engine/CPAL output
    // is constructed anywhere in this test.
    std::env::remove_var("MAJIKS_TEST_AUDIBLE");
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("recording.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Recording test").unwrap();
    host.submit(Actor::user("test"), "track.add", serde_json::json!({
        "trackId": "track_input", "name": "Input"
    })).unwrap();
    host.submit(Actor::user("test"), "track.arm", serde_json::json!({
        "trackId": "track_input", "armed": true
    })).unwrap();

    let frames = render::recording::SyntheticInput::sine(48_000 * 3, 48_000, 440.0, 0.2);
    let landed = host.record_synthetic_input("track_input", 1, &frames).unwrap();
    assert_eq!(landed.start_ticks, 0, "record position snaps to the bar grid");
    assert!(landed.tiles_ready);
    assert!(landed.loudness_lufs.is_some());
    assert!(pkg.join("audio").join(format!("{}.wav", landed.asset_hash)).exists());
    assert!(pkg.join("tiles").exists());
    let manifest = host.manifest_value();
    assert!(manifest.to_string().contains("record.commit"));
    assert_eq!(host.provenance_brief()["recordedClips"], 1);

    assert!(host.undo(Actor::user("test")).unwrap());
    assert!(!host.snapshot(None).to_string().contains(&landed.clip_id));
}

#[test]
fn record_commands_guard_arming_and_are_safe_no_ops_without_a_device() {
    // Deterministic, device-free assertions about the record.* command surface.
    // It never opens a capture stream, so it is safe on live monitors and in CI
    // (record.start's armed-track guard runs before any device is touched).
    std::env::remove_var("MAJIKS_TEST_AUDIBLE");
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("record-cmds.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Record command test").unwrap();
    host.submit(Actor::user("test"), "track.add", serde_json::json!({
        "trackId": "track_input", "name": "Input"
    })).unwrap();

    // record.start refuses when the target track is not armed (no device opened).
    let unarmed = host.submit(Actor::user("test"), "record.start", serde_json::json!({
        "trackId": "track_input"
    }));
    assert!(unarmed.is_err(), "record.start must refuse an unarmed track");

    // record.stop / record.cancel are safe no-ops when nothing is recording.
    let stop = host.submit(Actor::user("test"), "record.stop", serde_json::json!({})).unwrap();
    assert_eq!(stop["landed"], serde_json::json!(false));
    let cancel = host.submit(Actor::user("test"), "record.cancel", serde_json::json!({})).unwrap();
    assert_eq!(cancel["cancelled"], serde_json::json!(false));

    // The transport read surface reports no recording in progress, and the
    // audioInputs list is always present as an array (empty on a headless host).
    let snap = host.snapshot(None);
    assert_eq!(snap["transport"]["recording"], serde_json::json!(false));
    assert!(snap["audioInputs"].is_array(), "audioInputs is always an array");

    // Arming refreshes the cached input-device list surfaced to the UI picker.
    host.submit(Actor::user("test"), "track.arm", serde_json::json!({
        "trackId": "track_input", "armed": true
    })).unwrap();
    assert!(host.snapshot(None)["audioInputs"].is_array());
}

#[test]
fn loop_record_passes_stack_as_takes_over_one_comp_clip() {
    // Device-free: three synthetic passes over the SAME region land as three
    // auditionable take-only siblings under one comp clip (loop-record comping);
    // a pass over a different region opens a new comp clip.
    std::env::remove_var("MAJIKS_TEST_AUDIBLE");
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("loop.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Loop record").unwrap();
    host.submit(Actor::user("test"), "track.add", serde_json::json!({"trackId": "trk", "name": "Vox"})).unwrap();
    host.submit(Actor::user("test"), "track.arm", serde_json::json!({"trackId": "trk", "armed": true})).unwrap();

    let frames = render::recording::SyntheticInput::sine(48_000, 48_000, 440.0, 0.2);
    for _ in 0..3 {
        host.record_synthetic_input("trk", 0, &frames).unwrap();
    }

    // Exactly one recorded (comp) clip despite three passes: passes 2 and 3 are
    // take-only siblings, not overlapping clips.
    assert_eq!(host.provenance_brief()["recordedClips"], 1);

    // All three passes are auditionable record takes under one comp requestId.
    let takes = host.takes(&serde_json::json!({ "auditionableOnly": true }));
    let list = takes["takes"].as_array().unwrap();
    assert_eq!(list.len(), 3, "three recorded passes are auditionable takes");
    assert!(list.iter().all(|t| t["kind"] == "record"));
    let req = list[0]["requestId"].clone();
    assert!(list.iter().all(|t| t["requestId"] == req), "passes share one comp session requestId");

    // A pass over a DIFFERENT region opens a fresh comp clip.
    host.record_synthetic_input("trk", 3840, &frames).unwrap();
    assert_eq!(host.provenance_brief()["recordedClips"], 2);
}

#[test]
fn loop_record_snapshot_carries_take_lanes() {
    // After three loop-record passes over one region, the snapshot JSON
    // carries a takeLanes array under the track with 3 takes matching the
    // takes() API shape. This exercises the Rust-side injection in
    // project_json() that the real engine's buildSnapshot reads.
    std::env::remove_var("MAJIKS_TEST_AUDIBLE");
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("snap-take-lanes.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Take lane snapshot test").unwrap();
    host.submit(Actor::user("test"), "track.add", serde_json::json!({
        "trackId": "trk", "name": "Vox"
    })).unwrap();
    host.submit(Actor::user("test"), "track.arm", serde_json::json!({
        "trackId": "trk", "armed": true
    })).unwrap();

    let frames = render::recording::SyntheticInput::sine(48_000, 48_000, 440.0, 0.2);
    for _ in 0..3 {
        host.record_synthetic_input("trk", 0, &frames).unwrap();
    }

    let snap = host.snapshot(None);
    let tracks = snap["project"]["tracks"].as_array().unwrap();
    assert!(!tracks.is_empty(), "snapshot has at least one track");
    let take_lanes = tracks[0]["takeLanes"].as_array().unwrap();
    assert_eq!(take_lanes.len(), 1, "one comp clip produces one take lane");

    let lane = &take_lanes[0];
    let clip_id = tracks[0]["clips"][0]["id"].as_str().unwrap().to_string();
    assert_eq!(lane["clipId"].as_str().unwrap(), &clip_id,
        "take lane targets the comp clip");
    assert_eq!(lane["regionStartTicks"].as_u64(), Some(0),
        "region starts at bar 0");
    assert!(lane["regionLengthTicks"].as_u64().unwrap_or(0) > 0,
        "region has a positive length");

    let takes = lane["takes"].as_array().unwrap();
    assert_eq!(takes.len(), 3, "three passes → three takes in the lane");
    assert!(takes.iter().all(|t| t["kind"] == "record"),
        "all takes are record-kind");

    // FNV-1a seeds are odd (bit 0 forced to 1). The last take is picked
    // when nothing is promoted (most recent pass wins).
    for (i, t) in takes.iter().enumerate() {
        let seed = t["seed"].as_u64().unwrap();
        assert!(seed & 1 == 1, "take {i} seed {seed} is odd (FNV-1a contract)");
        assert!(t["takeId"].as_str().unwrap().starts_with("take_"),
            "take {i} has a valid takeId");
        assert_eq!(t["picked"].as_bool().unwrap(), i == 2,
            "take {i} picked is {:?} (only last should be picked)", t["picked"]);
    }

    // The inline lane takes match the independent takes() API view.
    let api_takes = host.takes(&serde_json::json!({"auditionableOnly": true, "includePurged": false}));
    let api_list = api_takes["takes"].as_array().unwrap();
    assert_eq!(api_list.len(), 3, "takes() also reports 3 auditionable takes");
    for (i, t) in takes.iter().enumerate() {
        assert_eq!(t["takeId"], api_list[i]["takeId"],
            "take {i} id matches between lane and takes() API");
    }
}

#[test]
fn a_failed_landing_aborts_the_txn_and_does_not_wedge_the_session() {
    // Recording onto a region that already holds a clip fails with Overlap. That
    // failure MUST abort the record txn, not leave it open: a leaked open txn
    // would wedge undo/redo and every future recording for the session. This also
    // exercises the stale-comp-session guard (undo removes the anchor clip, so a
    // re-record over that region places a fresh comp clip, not a headless take).
    std::env::remove_var("MAJIKS_TEST_AUDIBLE");
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("atomic.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Atomicity").unwrap();
    host.submit(Actor::user("test"), "track.add", serde_json::json!({"trackId": "trk", "name": "Vox"})).unwrap();
    host.submit(Actor::user("test"), "track.arm", serde_json::json!({"trackId": "trk", "armed": true})).unwrap();

    let frames = render::recording::SyntheticInput::sine(48_000, 48_000, 440.0, 0.2);
    // Pass 1 places a comp clip at bar 0.
    host.record_synthetic_input("trk", 0, &frames).unwrap();

    // A landing with a DIFFERENT session key (start 100) but the SAME bar-snapped
    // position (bar 0) forces place_clip=true onto the occupied region -> Overlap.
    let overlap = host.record_synthetic_input("trk", 100, &frames);
    assert!(overlap.is_err(), "recording over an existing clip fails with Overlap");

    // Not wedged: undo still works (an open txn would make undo Err) ...
    assert!(host.undo(Actor::user("test")).unwrap(), "undo works after the failed landing");
    // ... and a fresh recording on the now-clear region still lands (an open txn
    // would make its txn.begin Err, and a stale session would land headless).
    host.record_synthetic_input("trk", 0, &frames).unwrap();
    assert_eq!(host.provenance_brief()["recordedClips"], 1);
}

#[test]
fn record_start_accepts_optional_punch_out() {
    // Device-free: the contract accepts the punch region on record.start and
    // still rejects unknown params (additionalProperties: false).
    use timeline_core::catalog::Catalog;
    let cat = Catalog::get();
    assert!(cat
        .validate_params("record.start", &serde_json::json!({"trackId": "t", "punchOutTicks": 3840}))
        .is_ok());
    assert!(cat
        .validate_params(
            "record.start",
            &serde_json::json!({"trackId": "t", "startTicks": 0, "punchOutTicks": 3840, "deviceId": "Mic"})
        )
        .is_ok());
    assert!(cat
        .validate_params("record.start", &serde_json::json!({"trackId": "t", "nope": 1}))
        .is_err());
}

#[test]
fn gapless_virtual_input_rotates_two_exact_contiguous_comp_passes() {
    std::env::remove_var("MAJIKS_TEST_AUDIBLE");
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("gapless.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Gapless loop").unwrap();
    host.submit(Actor::user("test"), "track.add", serde_json::json!({"trackId": "trk", "name": "Vox"})).unwrap();
    host.submit(Actor::user("test"), "track.arm", serde_json::json!({"trackId": "trk", "armed": true})).unwrap();

    // At 120 BPM / 48 kHz, 960 ticks is exactly 24,000 frames.
    let region_frames = 24_000;
    let continuous: Vec<[f32; 2]> = (0..region_frames * 2).map(|i| {
        let sample = i as f32 / (region_frames * 2) as f32 * 0.5 - 0.25;
        [sample, -sample]
    }).collect();
    let mut input = agent_surface::record_input::VirtualInput::new(region_frames * 3);
    assert_eq!(input.feed(&continuous[..region_frames]), region_frames);
    let first = input.rotate();
    assert_eq!(input.feed(&continuous[region_frames..]), region_frames);
    let second = input.rotate();
    assert_eq!(input.dropped_frames(), 0);
    let joined: Vec<[f32; 2]> = first.iter().chain(&second).copied().collect();
    assert_eq!(joined, continuous, "rotation drops or duplicates no boundary frame");

    // Both passes queue before waiting, so pass 2 is captured while pass 1's
    // media and tiles prepare off the capture path.
    host.queue_synthetic_loop_pass("trk", 0, 960, first).unwrap();
    host.queue_synthetic_loop_pass("trk", 0, 960, second).unwrap();
    let landed: Vec<_> = host.wait_for_record_landings().into_iter().map(Result::unwrap).collect();
    assert_eq!(landed.len(), 2);
    assert!(landed.iter().all(|outcome| outcome.length_ticks == 960));
    assert_eq!(host.provenance_brief()["recordedClips"], 1);
    let takes = host.takes(&serde_json::json!({"auditionableOnly": true}));
    let takes = takes["takes"].as_array().unwrap();
    assert_eq!(takes.len(), 2);
    assert_eq!(takes[0]["requestId"], takes[1]["requestId"]);

    // Persisted pass assets reconstruct the continuous input exactly.
    let a = render::media::load_wav_stereo_48k(
        &pkg.join("audio").join(format!("{}.wav", landed[0].asset_hash))).unwrap();
    let b = render::media::load_wav_stereo_48k(
        &pkg.join("audio").join(format!("{}.wav", landed[1].asset_hash))).unwrap();
    let decoded: Vec<[f32; 2]> = a.samples.iter().chain(b.samples.iter()).copied().collect();
    assert_eq!(decoded, continuous);
}

#[test]
fn failed_async_pass_aborts_without_killing_continuous_capture_or_comp_session() {
    std::env::remove_var("MAJIKS_TEST_AUDIBLE");
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("gapless-failure.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Gapless failure").unwrap();
    host.submit(Actor::user("test"), "track.add", serde_json::json!({"trackId": "trk", "name": "Vox"})).unwrap();
    host.submit(Actor::user("test"), "track.arm", serde_json::json!({"trackId": "trk", "armed": true})).unwrap();

    // Occupy the punch region so pass 1 fails at clip.place after txn.begin.
    let blocker_hash = host.ingest_asset(&vec![[0.0, 0.0]; 24_000]).unwrap();
    host.submit(Actor::user("test"), "clip.place", serde_json::json!({
        "clipId": "blocker", "trackId": "trk", "assetHash": blocker_hash,
        "startTicks": 0, "lengthTicks": 960
    })).unwrap();

    let continuous: Vec<[f32; 2]> = (0..48_000).map(|i| {
        let sample = (i as f32 * 0.001).sin() * 0.2;
        [sample, sample]
    }).collect();
    let mut input = agent_surface::record_input::VirtualInput::new(72_000);
    input.feed(&continuous[..24_000]);
    host.queue_synthetic_loop_pass("trk", 0, 960, input.rotate()).unwrap();

    // Pass 2 crosses the boundary before pass 1's worker or txn is awaited.
    input.feed(&continuous[24_000..]);
    let recovery_pass = input.rotate();
    assert_eq!(input.dropped_frames(), 0);
    let failed = host.wait_for_record_landings();
    assert_eq!(failed.len(), 1);
    assert!(failed[0].is_err());

    // The failed pass was aborted, so the bus and comp request remain usable.
    host.submit(Actor::user("test"), "clip.remove", serde_json::json!({"clipId": "blocker"})).unwrap();
    host.queue_synthetic_loop_pass("trk", 0, 960, recovery_pass).unwrap();
    let recovered = host.wait_for_record_landings();
    assert_eq!(recovered.len(), 1);
    assert!(recovered[0].is_ok());
    assert_eq!(host.provenance_brief()["recordedClips"], 1);
    assert!(host.undo(Actor::user("test")).unwrap(), "undo remains usable");
}
