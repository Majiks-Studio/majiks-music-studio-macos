//! SAVE, QUIT, REOPEN — AND THE MIX IS THE SAME SAMPLES.
//!
//! `timeline-core/tests/persistence_durability.rs` proves the reopened MODEL is
//! deep-equal. That is necessary and not sufficient, and the insufficiency is
//! the exact bug class this program has spent the day killing: a struct that
//! compares equal over DSP that no longer matches. A dropped fx param, a
//! routing edge that came back at the wrong tap, an automation lane whose
//! points survived but whose `ParamRef` did not — each of those can pass a
//! model assertion and still change what the user hears.
//!
//! So every claim here is about RENDERED SAMPLES, produced by the shipping
//! bounce (`StudioHost::render_master`), from a project built through the real
//! command bus and then genuinely written to and read back off disk.
//!
//! # Hops this seam traverses (§12.5 honesty)
//!
//! `StudioHost::submit` -> catalog schema validation -> `Session::submit` ->
//! journal envelope + hash chain -> `FileJournal` (real bytes) ->
//! `Package::save` / `Package::open` -> `StudioHost::open_package` ->
//! `load_audio_dir` -> `compile_session_full` -> `sync_params` ->
//! `RenderCore::render`.
//!
//! SKIPPED: the cpal device callback (offline bounce, same `RenderCore`), the
//! FFI, and the Swift app's save affordance.

use std::path::PathBuf;
use std::sync::OnceLock;

use serde_json::{json, Value};

use agent_surface::StudioHost;
use timeline_core::Actor;

fn user() -> Actor {
    Actor::user("aaron")
}

fn fixture(name: &str) -> PathBuf {
    static READY: OnceLock<PathBuf> = OnceLock::new();
    READY
        .get_or_init(|| {
            let dir = render::fixtures::repo_fixtures_dir();
            render::fixtures::ensure(&dir).expect("fixtures");
            dir
        })
        .join(name)
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

fn peak(audio: &[[f32; 2]]) -> f32 {
    audio.iter().fold(0f32, |m, f| m.max(f[0].abs()).max(f[1].abs()))
}

/// Every persisted thing that can move a sample, applied through the real bus.
fn script() -> Vec<(&'static str, Value)> {
    vec![
        // Strip: gain, pan, four EQ bands, sends, master, limiter.
        ("mix.gain", json!({"trackId": "t1", "gainDb": -3.5})),
        ("mix.pan", json!({"trackId": "t1", "pan": -0.25})),
        ("mix.eq", json!({"trackId": "t1", "band": 0, "freqHz": 80, "gainDb": 4, "q": 0.7})),
        ("mix.eq", json!({"trackId": "t1", "band": 1, "freqHz": 400, "gainDb": -2.5, "q": 1.2})),
        ("mix.eq", json!({"trackId": "t1", "band": 2, "freqHz": 2500, "gainDb": 3, "q": 2})),
        ("mix.eq", json!({"trackId": "t1", "band": 3, "freqHz": 9000, "gainDb": -1, "q": 0.5})),
        ("mix.send", json!({"trackId": "t2", "bus": "a", "amount": 0.35})),
        ("mix.master.gain", json!({"gainDb": -1.5})),
        ("mix.limiter.set", json!({"enabled": true, "ceilingDb": -0.3, "releaseMs": 120})),
        // Clip edits.
        ("clip.setGain", json!({"clipId": "c1", "gainDb": -4})),
        ("clip.fade.set", json!({"clipId": "c1", "edge": "in", "lengthTicks": 240, "shape": "equalPower"})),
        ("clip.fade.set", json!({"clipId": "c2", "edge": "out", "lengthTicks": 480, "shape": "logarithmic"})),
        // Routing: nodes, edges, taps, bus faders.
        ("route.node.add", json!({"nodeId": "grpDrums", "kind": "group", "name": "Drum Bus"})),
        ("route.node.add", json!({"nodeId": "busRev", "kind": "bus", "name": "Reverb"})),
        ("route.connect", json!({"edgeId": "e1", "from": "track.t1", "to": "bus.grpDrums", "level": 1, "tap": "post"})),
        ("route.connect", json!({"edgeId": "e2", "from": "bus.grpDrums", "to": "master", "level": 0.8, "tap": "post"})),
        ("route.connect", json!({"edgeId": "e3", "from": "track.t2", "to": "bus.busRev", "level": 0.42, "tap": "pre"})),
        ("route.connect", json!({"edgeId": "e4", "from": "bus.busRev", "to": "master", "level": 0.9, "tap": "post"})),
        ("route.node.set", json!({"nodeId": "grpDrums", "gainDb": -2.5})),
        ("route.node.set", json!({"nodeId": "busRev", "gainDb": -6})),
        // Fx chains on all three host kinds, with params and chain ORDER.
        ("fx.add", json!({"target": "track.t1", "fxId": "fxComp", "kind": "compressor"})),
        ("fx.add", json!({"target": "track.t1", "fxId": "fxSat", "kind": "saturator"})),
        ("fx.add", json!({"target": "bus.busRev", "fxId": "fxVerb", "kind": "reverb"})),
        ("fx.add", json!({"target": "master", "fxId": "fxLim", "kind": "limiter"})),
        ("fx.param.set", json!({"target": "track.t1", "fxId": "fxComp", "key": "threshold", "value": -18})),
        ("fx.param.set", json!({"target": "track.t1", "fxId": "fxComp", "key": "ratio", "value": 4})),
        ("fx.param.set", json!({"target": "track.t1", "fxId": "fxSat", "key": "mix", "value": 0.3})),
        ("fx.param.set", json!({"target": "bus.busRev", "fxId": "fxVerb", "key": "mix", "value": 0.45})),
        ("fx.param.set", json!({"target": "master", "fxId": "fxLim", "key": "threshold", "value": -0.5})),
        ("fx.move", json!({"target": "track.t1", "fxId": "fxSat", "index": 0})),
        // Automation that MOVES inside the bounce window.
        ("autopoint.add", json!({"trackId": "t1", "target": "track.volume", "pointId": "p1", "positionTicks": 0, "value": -12})),
        ("autopoint.add", json!({"trackId": "t1", "target": "track.volume", "pointId": "p2", "positionTicks": 1920, "value": 0})),
        ("autopoint.add", json!({"trackId": "t1", "target": "track.pan", "pointId": "p3", "positionTicks": 960, "value": 0.5})),
        ("autopoint.add", json!({"trackId": "t1", "target": "track.fx.fxComp.threshold", "pointId": "p4", "positionTicks": 480, "value": -24})),
        // Instrument + sampler zones + notes.
        ("device.add", json!({"trackId": "t3", "deviceId": "dev1", "kind": "sampler"})),
        ("clip.placeMidi", json!({"clipId": "cm1", "trackId": "t3", "startTicks": 0, "lengthTicks": 7680})),
        ("note.add", json!({"clipId": "cm1", "notes": (0..12).map(|i| json!({
            "noteId": format!("n{i:02}"),
            "startTicks": i as u64 * 240,
            "lengthTicks": 200,
            "pitch": 48 + i as u8,
            "velocity": 64 + i,
        })).collect::<Vec<_>>()})),
    ]
}

/// A host on a real `.mstudio` package carrying the full feature set. Returns
/// the package dir so the test can reopen it.
fn built(tag: &str) -> (StudioHost, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join(format!("{tag}.mstudio"));
    std::mem::forget(tmp); // keep the dir alive past this scope
    let mut host = StudioHost::create_at(&pkg, tag).unwrap();

    // Tempo/meter/anchor FIRST: `import.audio` sizes the clip in TICKS from the
    // grid in force at import, so changing the grid afterwards would ask the
    // clip to read past the end of its own source.
    for (name, params) in [
        ("project.setTempo", json!({"bpm": 92})),
        ("project.setTimeSig", json!({"numerator": 7, "denominator": 8})),
        ("project.setPhaseAnchor", json!({"anchorTicks": 480})),
    ] {
        host.submit(user(), name, params).unwrap();
    }

    for (id, name) in [("t1", "Drums"), ("t2", "Bass"), ("t3", "Keys")] {
        host.submit(user(), "track.add", json!({"trackId": id, "name": name}))
            .unwrap();
    }
    // REAL audio, content-addressed into the package's audio/ dir -- so the
    // reopen path exercises `load_audio_dir` rather than an in-memory shortcut.
    host.import_audio(
        &fixture("tone_440_48k_mono.wav").display().to_string(),
        "t1",
        0,
        Some("c1".into()),
    )
    .unwrap();
    host.import_audio(
        &fixture("sweep_48k_stereo.wav").display().to_string(),
        "t2",
        0,
        Some("c2".into()),
    )
    .unwrap();

    for (name, params) in script() {
        host.submit(user(), name, params.clone())
            .unwrap_or_else(|e| panic!("{name} {params}: {e}"));
    }
    // Devices need a zone bound to a real asset id; take the one import.audio
    // minted rather than guessing a hash.
    let asset = host
        .project()
        .tracks
        .iter()
        .flat_map(|t| t.clips.iter())
        .find(|c| !c.source_id.is_empty())
        .map(|c| c.source_id.clone())
        .expect("an imported clip");
    host.submit(
        user(),
        "device.zone.add",
        json!({"trackId": "t3", "deviceId": "dev1", "zoneId": "z1", "sourceId": asset,
               "rootPitch": 60, "loPitch": 48, "hiPitch": 72, "gainDb": -2, "pan": 0.4}),
    )
    .unwrap();

    (host, pkg)
}

// ---------------------------------------------------------------------------
// THE load-bearing assertion.
// ---------------------------------------------------------------------------

#[test]
fn a_saved_and_reopened_project_bounces_bit_identically() {
    let (mut host, pkg) = built("RoundTrip");

    let live = host.render_master().unwrap();
    // Non-vacuous: comparing two silences would be green and meaningless.
    assert!(
        peak(&live) > 0.01,
        "the bounce is silent (peak {}); a bit-identical claim over silence \
         proves nothing",
        peak(&live)
    );
    assert!(live.len() > 48_000, "bounce is too short to be meaningful");

    // The affordance the app now has: the catalog command, through the bus.
    host.submit(user(), "project.save", json!({})).unwrap();
    // Model AppKit's exit(): the process ends without running Drop.
    std::mem::forget(host);

    let reopened = StudioHost::open_package(&pkg).unwrap();
    let after = reopened.render_master().unwrap();

    assert_eq!(live.len(), after.len(), "bounce length changed across a reopen");
    assert_eq!(
        digest(&live),
        digest(&after),
        "save + reopen changed the MIX -- the model may compare equal while the \
         audio does not, which is the failure this test exists for"
    );
}

/// The same, with NO save at all. Quit-then-relaunch is the flow the user
/// actually performs, and it must not need ceremony to survive.
#[test]
fn a_project_recovered_from_the_journal_alone_bounces_bit_identically() {
    let (host, pkg) = built("JournalOnly");
    let live = host.render_master().unwrap();
    assert!(peak(&live) > 0.01, "silent bounce");
    // No project.save, no Drop.
    std::mem::forget(host);

    let reopened = StudioHost::open_package(&pkg).unwrap();
    let after = reopened.render_master().unwrap();
    assert_eq!(
        digest(&live),
        digest(&after),
        "journal-only recovery changed the mix"
    );
}

/// Work done AFTER a save must also survive: `Package::save` swaps a new
/// `journal.jsonl` inode into place, and before this lane the session kept
/// appending to the orphaned one.
#[test]
fn edits_made_after_a_save_survive_the_next_reopen() {
    let (mut host, pkg) = built("AfterSave");
    host.submit(user(), "project.save", json!({})).unwrap();

    // A change that is unmistakable in the audio.
    host.submit(user(), "mix.master.gain", json!({"gainDb": -24}))
        .unwrap();
    let expected = host.render_master().unwrap();
    std::mem::forget(host);

    let reopened = StudioHost::open_package(&pkg).unwrap();
    assert_eq!(
        digest(&reopened.render_master().unwrap()),
        digest(&expected),
        "a post-save edit was lost -- the journal sink was still bound to the \
         inode Package::save unlinked"
    );
}

// ---------------------------------------------------------------------------
// Guard the guard.
// ---------------------------------------------------------------------------

/// "Bit-identical" is only worth what the comparison can detect. Each mutation
/// below changes exactly one persisted value through the real bus and requires
/// the bounce to diverge; anything it cannot see is reported by name, because a
/// round-trip that lost such a value would still report identical above.
#[test]
fn the_bounce_is_sensitive_to_each_persisted_value_it_claims_to_protect() {
    let probes: Vec<(&str, &str, Value)> = vec![
        ("track strip gain", "mix.gain", json!({"trackId": "t1", "gainDb": -30})),
        ("track pan", "mix.pan", json!({"trackId": "t1", "pan": 0.9})),
        ("track EQ band", "mix.eq", json!({"trackId": "t1", "band": 0, "freqHz": 120, "gainDb": -20, "q": 3})),
        ("send amount", "mix.send", json!({"trackId": "t2", "bus": "a", "amount": 0.95})),
        ("master gain", "mix.master.gain", json!({"gainDb": -30})),
        ("master limiter", "mix.limiter.set", json!({"enabled": true, "ceilingDb": -6, "releaseMs": 5})),
        ("clip gain", "clip.setGain", json!({"clipId": "c1", "gainDb": -30})),
        ("clip fade", "clip.fade.set", json!({"clipId": "c1", "edge": "in", "lengthTicks": 3840, "shape": "linear"})),
        ("routing edge level", "route.edge.set", json!({"edgeId": "e2", "level": 0.05, "tap": "post"})),
        ("routing bus fader", "route.node.set", json!({"nodeId": "grpDrums", "gainDb": -30})),
        // NOT fxComp/threshold: the fixture automates `track.fx.fxComp.threshold`,
        // and the lane overrides the atomic, so that probe would be blind for a
        // reason that has nothing to do with persistence. Probe an un-automated
        // param instead.
        ("fx param", "fx.param.set", json!({"target": "track.t1", "fxId": "fxSat", "key": "mix", "value": 1})),
        ("fx chain membership", "fx.remove", json!({"target": "track.t1", "fxId": "fxSat"})),
        ("automation point", "autopoint.move", json!({"trackId": "t1", "target": "track.volume", "pointId": "p1", "positionTicks": 0, "value": -60})),
        ("track mute", "track.mute", json!({"trackId": "t1", "muted": true})),
        ("track solo", "track.solo", json!({"trackId": "t2", "soloed": true})),
        ("project tempo", "project.setTempo", json!({"bpm": 140})),
    ];

    // Build ONCE, save, and probe the REOPENED package. That is both the
    // cheaper shape (open + bounce instead of import + decode per probe) and
    // the more relevant one: what must be sensitive is the project as
    // persistence reconstructed it.
    let (mut host, pkg) = built("Sensitivity");
    host.submit(user(), "project.save", json!({})).unwrap();
    std::mem::forget(host);

    let baseline = digest(
        &StudioHost::open_package(&pkg)
            .unwrap()
            .render_master()
            .unwrap(),
    );

    let mut blind: Vec<&str> = Vec::new();
    let mut refused: Vec<(&str, String)> = Vec::new();
    for (label, name, params) in probes {
        let mut probe = StudioHost::open_package(&pkg).unwrap();
        match probe.submit(user(), name, params.clone()) {
            Err(e) => refused.push((label, e.to_string())),
            Ok(_) => {
                if digest(&probe.render_master().unwrap()) == baseline {
                    blind.push(label);
                }
            }
        }
        // Never save a probe: each one must start from the same package.
        std::mem::forget(probe);
    }
    assert!(
        refused.is_empty(),
        "a probe was refused by the bus, so it proves nothing: {refused:?}"
    );
    assert!(
        blind.is_empty(),
        "the bounce comparison is BLIND to these persisted values -- a \
         round-trip that lost one would still report bit-identical: {blind:?}"
    );
}
