use agent_surface::StudioHost;
use serde_json::{json, Value};
use timeline_core::Actor;

fn host() -> (tempfile::TempDir, StudioHost) {
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("placement.mstudio");
    let mut h = StudioHost::create_at(&pkg, "placement").unwrap();
    h.submit(Actor::user("test"), "track.add", json!({"trackId":"trk","name":"Vox"})).unwrap();
    h.submit(Actor::user("test"), "track.arm", json!({"trackId":"trk","armed":true})).unwrap();
    (dir, h)
}

fn ramp(frames: usize) -> Vec<f32> {
    ramp_from(1, frames)
}

fn ramp_from(offset: usize, frames: usize) -> Vec<f32> {
    (0..frames).flat_map(|i| {
        let v = (offset + i) as f32 * 1e-6;
        [v, v]
    }).collect()
}

fn start(h: &mut StudioHost, params: Value) -> Value {
    h.test_begin_virtual_listen(2, 48_000);
    h.submit(Actor::user("test"), "record.start", params).unwrap()
}

fn stop(h: &mut StudioHost, samples: &[f32]) -> (Value, Vec<[f32; 2]>) {
    assert!(h.test_feed_virtual_capture(samples) > 0);
    let out = h.submit(Actor::user("test"), "record.stop", json!({})).unwrap();
    let hash = out["landings"][0]["assetHash"].as_str().unwrap();
    let path = h.package_dir().unwrap().join("audio").join(format!("{hash}.wav"));
    let audio = render::media::load_wav_stereo_48k(&path).unwrap();
    (out, audio.samples.to_vec())
}

#[test]
fn e1_rolling_free_capture_uses_the_capture_origin() {
    let (_dir, mut h) = host();
    h.submit(Actor::user("test"), "transport.seek", json!({"positionTicks":5000})).unwrap();
    h.submit(Actor::user("test"), "transport.play", json!({})).unwrap();
    let out = start(&mut h, json!({"trackId":"trk"}));
    assert_eq!(out["captureOriginTicks"], 5000);
    assert_eq!(out["rolling"], true);
    let (landed, _) = stop(&mut h, &ramp(2_000));
    assert_eq!(landed["landings"][0]["startTicks"], 5000);
}

#[test]
fn e2_stopped_capture_snaps_to_the_phase_anchor() {
    let (_dir, mut h) = host();
    h.submit(Actor::user("test"), "project.setPhaseAnchor", json!({"anchorTicks":1000})).unwrap();
    h.submit(Actor::user("test"), "transport.seek", json!({"positionTicks":8780})).unwrap();
    let out = start(&mut h, json!({"trackId":"trk","startTicks":8780}));
    assert_eq!(out["rolling"], false);
    assert_eq!(out["ignoredParams"], json!([]));
    let (landed, _) = stop(&mut h, &ramp(2_000));
    assert_eq!(landed["landings"][0]["startTicks"], 8680);
}

#[test]
fn e2_anchor_zero_preserves_the_original_bar_grid() {
    let (_dir, mut h) = host();
    h.submit(Actor::user("test"), "project.setPhaseAnchor", json!({"anchorTicks":0})).unwrap();
    h.submit(Actor::user("test"), "transport.seek", json!({"positionTicks":8780})).unwrap();
    start(&mut h, json!({"trackId":"trk","startTicks":8780}));
    let (landed, _) = stop(&mut h, &ramp(2_000));
    assert_eq!(landed["landings"][0]["startTicks"], 7680);
}

#[test]
fn e2_anchor_changes_nearest_bar_rounding() {
    let (_dir, mut h) = host();
    h.submit(Actor::user("test"), "project.setPhaseAnchor", json!({"anchorTicks":1000})).unwrap();
    h.submit(Actor::user("test"), "transport.seek", json!({"positionTicks":2900})).unwrap();
    start(&mut h, json!({"trackId":"trk","startTicks":2900}));
    let (landed, _) = stop(&mut h, &ramp(2_000));
    assert_eq!(landed["landings"][0]["startTicks"], 1000);
}

#[test]
fn e3_rolling_punch_drops_or_pads_to_the_exact_region() {
    let (_dir, mut h) = host();
    h.submit(Actor::user("test"), "transport.seek", json!({"positionTicks":2000})).unwrap();
    h.submit(Actor::user("test"), "transport.play", json!({})).unwrap();
    start(&mut h, json!({"trackId":"trk","startTicks":3840,"punchOutTicks":7680}));
    let (landed, audio) = stop(&mut h, &ramp(150_000));
    assert_eq!(landed["landings"][0]["startTicks"], 3840);
    assert_eq!(audio.len(), 96_000);
    assert!((audio[0][0] - (46_001f32 * 1e-6)).abs() < 1e-7, "first sample {}", audio[0][0]);
}

#[test]
fn e3_rolling_punch_pads_capture_that_started_late() {
    let (_dir, mut h) = host();
    h.submit(Actor::user("test"), "transport.seek", json!({"positionTicks":4000})).unwrap();
    h.submit(Actor::user("test"), "transport.play", json!({})).unwrap();
    start(&mut h, json!({"trackId":"trk","startTicks":3840,"punchOutTicks":7680}));
    let (landed, audio) = stop(&mut h, &ramp(2_000));
    assert_eq!(landed["landings"][0]["startTicks"], 3840);
    assert_eq!(audio.len(), 96_000);
    assert!(audio[..4_000].iter().all(|frame| *frame == [0.0, 0.0]));
    assert!((audio[4_000][0] - 1e-6).abs() < 1e-8);
}

#[test]
fn e4_rotate_reports_resampling_and_lands_project_rate() {
    let (_dir, mut h) = host();
    let (out, hash) = {
        h.test_begin_virtual_listen(2, 44_100);
        h.submit(Actor::user("test"), "record.start", json!({"trackId":"trk"})).unwrap();
        h.test_feed_virtual_capture(&ramp(44_100));
        let rotated = h.submit(Actor::user("test"), "record.rotate", json!({})).unwrap();
        assert_eq!(rotated["resampled"], true);
        assert_eq!(rotated["deviceSampleRate"], 44_100);
        let landed: Vec<_> = h.wait_for_record_landings().into_iter().map(Result::unwrap).collect();
        (rotated, landed[0].asset_hash.clone())
    };
    assert_eq!(out["landedSampleRate"], 48_000);
    let path = h.package_dir().unwrap().join("audio").join(format!("{hash}.wav"));
    let audio = render::media::load_wav_stereo_48k(&path).unwrap();
    assert!((audio.samples.len() as isize - 48_000).abs() <= 1);
}

#[test]
fn e5_rolling_past_punch_region_becomes_a_free_take() {
    let (_dir, mut h) = host();
    h.submit(Actor::user("test"), "transport.seek", json!({"positionTicks":8000})).unwrap();
    h.submit(Actor::user("test"), "transport.play", json!({})).unwrap();
    let out = start(&mut h, json!({"trackId":"trk","startTicks":3840,"punchOutTicks":7680}));
    assert_eq!(out["ignoredParams"], json!(["startTicks", "punchOutTicks"]));
    assert_eq!(out["startTicks"], 8000);
    let (landed, audio) = stop(&mut h, &ramp(2_000));
    assert_eq!(landed["landings"][0]["startTicks"], 8000);
    assert_eq!(audio.len(), 2_000);
    assert_eq!(audio[0], [1e-6, 1e-6]);
}

#[test]
fn e5_rolling_start_ticks_is_ignored_but_origin_lands() {
    let (_dir, mut h) = host();
    h.submit(Actor::user("test"), "transport.seek", json!({"positionTicks":5000})).unwrap();
    h.submit(Actor::user("test"), "transport.play", json!({})).unwrap();
    let out = start(&mut h, json!({"trackId":"trk","startTicks":3840}));
    assert_eq!(out["ignoredParams"], json!(["startTicks"]));
    let (landed, _) = stop(&mut h, &ramp(2_000));
    assert_eq!(landed["landings"][0]["startTicks"], 5000);
}

#[test]
fn e5_stopped_punch_out_defaults_to_the_transport_origin() {
    let (_dir, mut h) = host();
    h.submit(Actor::user("test"), "transport.seek", json!({"positionTicks":3840})).unwrap();
    let out = start(&mut h, json!({"trackId":"trk","punchOutTicks":7680}));
    assert_eq!(out["ignoredParams"], json!([]));
    let (landed, audio) = stop(&mut h, &ramp(2_000));
    assert_eq!(landed["landings"][0]["startTicks"], 3840);
    assert_eq!(audio.len(), 96_000);
}

#[test]
fn e6_loop_pass_one_uses_origin_and_later_passes_use_region_start() {
    let (_dir, mut h) = host();
    h.submit(Actor::user("test"), "transport.seek", json!({"positionTicks":2000})).unwrap();
    h.submit(Actor::user("test"), "transport.play", json!({})).unwrap();
    start(&mut h, json!({"trackId":"trk","startTicks":3840,"punchOutTicks":7680}));
    h.test_feed_virtual_capture(&ramp(150_000));
    h.submit(Actor::user("test"), "record.rotate", json!({})).unwrap();
    let first = h.wait_for_record_landings();
    assert_eq!(first.len(), 1);
    let first = first[0].as_ref().unwrap();
    assert_eq!(first.start_ticks, 3840);
    let first_wav = h.package_dir().unwrap().join("audio").join(format!("{}.wav", first.asset_hash));
    let first_audio = render::media::load_wav_stereo_48k(&first_wav).unwrap();
    assert_eq!(first_audio.samples.len(), 96_000);
    assert!((first_audio.samples[0][0] - 46_001e-6).abs() < 1e-7);

    h.test_feed_virtual_capture(&ramp_from(1_000_000, 96_000));
    let stopped = h.submit(Actor::user("test"), "record.stop", json!({})).unwrap();
    assert_eq!(stopped["landings"][0]["startTicks"], 3840);
    let hash = stopped["landings"][0]["assetHash"].as_str().unwrap();
    let wav = h.package_dir().unwrap().join("audio").join(format!("{hash}.wav"));
    let audio = render::media::load_wav_stereo_48k(&wav).unwrap();
    assert_eq!(audio.samples.len(), 96_000);
    assert!((audio.samples[0][0] - 1_000_000usize as f32 * 1e-6).abs() < 1e-7,
        "pass 2 first sample {}", audio.samples[0][0]);
}
