//! Regression (L8 "Open in Studio" + package io): a landed session whose
//! `gen.song` carries a measured bpm that is a serde_json float-parse edge value
//! must still reopen with a valid journal hash chain.
//!
//! Reproduced originally by landing the repo click fixture
//! (`click_120bpm_48k_stereo.wav`): its measured bpm was `120.00000000000003`,
//! and `Package::open` failed with "chain broken at entry 15" on reopen. Here
//! that exact value is driven through the SAME command bus + `Package` save/open
//! the landing uses, so the regression is deterministic and needs no audio
//! fixture (the analysis fixtures are gitignored). Fails without the workspace's
//! serde_json `float_roundtrip` feature.

use agent_surface::StudioHost;
use serde_json::json;
use timeline_core::Actor;

#[test]
fn landed_gen_song_with_edge_case_bpm_reopens_with_valid_chain() {
    let dir = tempfile::tempdir().unwrap();
    let pkg = dir.path().join("Edge.mstudio");
    let mut host = StudioHost::create_at(&pkg, "Edge").expect("create package");
    let actor = Actor::user("test");

    // The exact f64 the click fixture's tempo analysis produced (bits ...0002),
    // which serde_json's default parser misrounds by 1 ULP.
    let bpm = f64::from_bits(0x405e000000000002);
    assert_eq!(format!("{bpm}"), "120.00000000000003");

    host.submit(actor.clone(), "project.setTempo", json!({ "bpm": bpm }))
        .expect("setTempo");
    host.submit(actor.clone(), "track.add", json!({ "trackId": "trk_vocals", "name": "Vocals" }))
        .expect("track.add");
    host.submit(
        actor,
        "gen.song",
        json!({
            "requestId": "01KXAV2V4BK87JV6A2JYG416Q7",
            "trackId": "trk_vocals",
            "insertAtTicks": 0,
            "request": {
                "bpm": bpm,
                "caption": "generated song",
                "durationSeconds": 8.0,
                "generated": true,
            },
        }),
    )
    .expect("gen.song");
    host.save().expect("save");

    // Reopen: Package::open verifies the whole chain up front. This is the exact
    // path that failed with "chain broken at entry N" before float_roundtrip.
    let reopened = StudioHost::open_package(&pkg).expect("reopen with valid chain");
    assert_eq!(reopened.seq(), host.seq(), "reopened session has the whole chain");
}
