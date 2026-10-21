//! THE REACHABILITY GATE for the sampler and the drum rack.
//!
//! `render/tests/sampler_binding.rs` already proves the DSP: a zone built by
//! hand renders, pitch-tracks, and decays to zero. It proves nothing about
//! whether a person can ever get a sound into one, because it builds the
//! `Project` in Rust. Every zone in this repo, up to now, was born that way.
//!
//! These tests drive the gesture the GUI drives — `StudioHost::bind_samples`,
//! which is what a file picker's OK button reaches — and then assert on:
//!
//!  1. the JOURNAL: the right catalog commands, inside ONE txn bracket, so one
//!     gesture is one Cmd-Z;
//!  2. RENDERED BUFFERS out of `render_master`, the same offline bounce the
//!     device callback runs: signal at the note frame, silence strictly before
//!     it, and a MEASURED frequency — a sampler that ignored `rootPitch` and
//!     read every zone at rate 1.0 would still be audible, and only a period
//!     measurement catches that;
//!  3. the REFUSALS, each of which must leave the journal untouched rather than
//!     half-apply or strand an open transaction.
//!
//! Nothing here opens an output device: `render_master` is the offline bounce.

use std::path::PathBuf;
use std::sync::OnceLock;

use agent_surface::{BindSamplesRequest, SampleBinding, StudioHost};
use serde_json::{json, Value};
use timeline_core::Actor;

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

fn fixtures_dir() -> &'static PathBuf {
    static READY: OnceLock<PathBuf> = OnceLock::new();
    READY.get_or_init(|| {
        let dir = render::fixtures::repo_fixtures_dir();
        render::fixtures::ensure(&dir).expect("engine/fixtures");
        dir
    })
}

/// A 440 Hz sine. 440 Hz is A4 = MIDI 69, which is what makes `root_pitch`
/// MEASURABLE here: play 69 and the output must still be 440 Hz.
fn tone() -> String {
    fixtures_dir()
        .join("tone_440_48k_mono.wav")
        .display()
        .to_string()
}

/// A continuous sweep. Used for the SECOND drum pad, so the two pads are
/// distinguishable and neither has internal silence a measuring window could
/// land in (a click track does, which made an earlier version of this test
/// report "the pad is dead" when the pad was fine).
fn sweep() -> String {
    fixtures_dir()
        .join("sweep_48k_stereo.wav")
        .display()
        .to_string()
}

fn user() -> Actor {
    Actor::user("aaron")
}

/// PPQ is 960 and the fixtures below all run at 120 BPM / 48 kHz, so one
/// quarter note is 24_000 frames.
const QUARTER_FRAMES: u64 = 24_000;
const PPQ: u64 = 960;

/// A host on a real `.mstudio` package with one empty track and a fixed grid.
/// The tempo is pinned so tick -> frame arithmetic in the assertions is exact
/// rather than dependent on whatever the default happens to be.
fn host_with_track() -> (StudioHost, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let pkg = tmp.path().join("SamplerUI.mstudio");
    std::mem::forget(tmp); // the package must outlive this scope
    let mut host = StudioHost::create_at(&pkg, "SamplerUI").unwrap();
    host.submit(user(), "project.setTempo", json!({"bpm": 120}))
        .unwrap();
    host.submit(user(), "track.add", json!({"trackId": "t1", "name": "Keys"}))
        .unwrap();
    (host, pkg)
}

/// The gesture: "load this one sound across the whole keyboard", exactly as the
/// track header's `Sampler` item sends it.
fn full_range(source_path: &str, root: i64) -> BindSamplesRequest {
    BindSamplesRequest {
        track_id: "t1".into(),
        device_id: None,
        kind: Some("sampler".into()),
        remove_zone_ids: Vec::new(),
        bindings: vec![SampleBinding {
            source_path: source_path.to_string(),
            root_pitch: root,
            lo_pitch: 0,
            hi_pitch: 127,
            gain_db: None,
            pan: None,
        }],
        reason: "Load a sound".into(),
    }
}

/// Put one note on the track's own MIDI clip, starting at `start_ticks`.
fn note(host: &mut StudioHost, start_ticks: u64, len_ticks: u64, pitch: u8) {
    if host.project().tracks[0].clips.is_empty() {
        host.submit(
            user(),
            "clip.placeMidi",
            json!({"clipId": "cm1", "trackId": "t1", "startTicks": 0,
                   "lengthTicks": PPQ * 16}),
        )
        .unwrap();
    }
    host.submit(
        user(),
        "note.add",
        json!({"clipId": "cm1", "notes": [{
            "noteId": format!("n{start_ticks}_{pitch}"),
            "startTicks": start_ticks, "lengthTicks": len_ticks,
            "pitch": pitch, "velocity": 100,
        }]}),
    )
    .unwrap();
}

/// A snappy amp envelope, so "silence before" and "sound at" are separated by
/// one millisecond of attack rather than by the default's slow rise.
fn snappy(host: &mut StudioHost) {
    for (key, v) in [
        ("attack", 0.001),
        ("decay", 0.05),
        ("sustain", 1.0),
        ("release", 0.02),
    ] {
        let device_id = host.project().tracks[0].devices[0].id.clone();
        host.submit(
            user(),
            "autopoint.add",
            json!({
                "trackId": "t1",
                "target": format!("track.device.{device_id}.{key}"),
                "pointId": format!("p_{key}"),
                "positionTicks": 0,
                "value": v,
            }),
        )
        .unwrap();
    }
}

// ---------------------------------------------------------------------------
// measurement helpers
// ---------------------------------------------------------------------------

fn peak(audio: &[[f32; 2]]) -> f32 {
    audio.iter().fold(0.0f32, |m, f| m.max(f[0].abs()).max(f[1].abs()))
}

/// Fundamental frequency of `audio`, by counting rising zero crossings over a
/// whole number of periods. Crude on purpose: it has no window, no FFT, and no
/// way to be fooled into agreeing with the expected answer.
fn measured_hz(audio: &[[f32; 2]]) -> f32 {
    let mono: Vec<f32> = audio.iter().map(|f| (f[0] + f[1]) * 0.5).collect();
    let mut first = None;
    let mut last = None;
    let mut crossings = 0usize;
    for i in 1..mono.len() {
        if mono[i - 1] <= 0.0 && mono[i] > 0.0 {
            if first.is_none() {
                first = Some(i);
            }
            last = Some(i);
            crossings += 1;
        }
    }
    match (first, last) {
        (Some(a), Some(b)) if crossings > 2 && b > a => {
            (crossings - 1) as f32 * 48_000.0 / (b - a) as f32
        }
        _ => 0.0,
    }
}

fn command_names(host: &StudioHost) -> Vec<String> {
    let page = host.journal_page(None, 500);
    page["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["name"].as_str().unwrap_or_default().to_string())
        .collect()
}

/// The command names inside the LAST txn bracket, which is the undo unit the
/// gesture just created.
fn last_txn_body(host: &StudioHost) -> Vec<String> {
    let names = command_names(host);
    let begin = names.iter().rposition(|n| n == "txn.begin");
    match begin {
        Some(b) => names[b + 1..]
            .iter()
            .take_while(|n| *n != "txn.commit")
            .cloned()
            .collect(),
        None => Vec::new(),
    }
}

fn zones(host: &StudioHost) -> &[timeline_core::model::DeviceZone] {
    &host.project().tracks[0].devices[0].zones
}

// ---------------------------------------------------------------------------
// 1. THE load-bearing test: one gesture, one undo step, real sound.
// ---------------------------------------------------------------------------

#[test]
fn loading_one_sound_across_the_keyboard_makes_a_sampler_that_sounds() {
    let (mut host, _pkg) = host_with_track();

    let before = command_names(&host).len();
    let out = host.bind_samples(full_range(&tone(), 69)).expect("bind");
    assert!(out.created_device, "the gesture had to create the instrument");
    assert_eq!(out.kind, "sampler");
    assert_eq!(out.zones.len(), 1);

    // (a) THE JOURNAL. Exactly the two catalog commands the design says, and
    //     nothing else, inside one bracket. A gesture that quietly also placed
    //     a clip (the old "import then delete it" workaround) shows up here.
    assert_eq!(
        last_txn_body(&host),
        vec!["device.add".to_string(), "device.zone.add".to_string()],
        "the load gesture must journal device.add + device.zone.add and nothing else"
    );
    let names = command_names(&host);
    assert_eq!(
        names[before..].iter().filter(|n| *n == "txn.begin").count(),
        1,
        "one gesture opens exactly one transaction"
    );
    assert_eq!(zones(&host)[0].source_id, out.zones[0].source_id);
    assert_eq!(
        host.sources().get(&out.zones[0].source_id).is_some(),
        true,
        "the zone's source_id must resolve in the SAME sources map a clip uses"
    );

    // (b) THE AUDIO. A note two beats in, on the zone's root key.
    snappy(&mut host);
    let note_frame = 2 * QUARTER_FRAMES;
    note(&mut host, 2 * PPQ, PPQ * 2, 69);
    let audio = host.render_master().expect("the bound sampler must compile");
    assert!(
        audio.len() as u64 > note_frame + QUARTER_FRAMES,
        "bounce too short to contain the note: {} frames",
        audio.len()
    );

    let before_note = &audio[..note_frame as usize];
    let quiet = peak(before_note);
    assert!(
        quiet < 1e-6,
        "audio before the note-on frame ({note_frame}) is not silent: peak {quiet}"
    );

    // A window well inside the note, past the 1 ms attack.
    let start = (note_frame + 2_400) as usize;
    let window = &audio[start..start + 12_000];
    let loud = peak(window);
    assert!(
        loud > 0.05,
        "the note rendered (near-)silence: peak {loud} — a sampler nobody can hear \
         is the failure this whole feature exists to close"
    );

    // (c) THE PITCH. 440 Hz recorded, played at its own root key, must come out
    //     at 440 Hz. This is what proves `rootPitch` survived the whole path
    //     (picker -> host -> journal -> compile -> voice) rather than being
    //     defaulted somewhere: a wrong root is audible, in tune with nothing.
    let hz = measured_hz(window);
    let ratio = hz / 440.0;
    assert!(
        (ratio - 1.0).abs() < 0.02,
        "playing the root key rendered {hz} Hz, not the recorded 440 Hz (ratio {ratio})"
    );

}

/// ONE Cmd-Z. The device AND its zone go together, because they landed as one
/// unit — a two-step undo would leave a zoneless sampler, which is a hard
/// compile error, so the project would be unrenderable between the two presses.
///
/// Its own test on purpose: the undo has to be the FIRST thing after the
/// gesture. Asserting it at the end of the audio test undid the last note
/// instead, which passed for the wrong reason until it didn't.
#[test]
fn one_undo_takes_back_the_whole_load_gesture() {
    let (mut host, _pkg) = host_with_track();
    host.bind_samples(full_range(&tone(), 69)).expect("bind");
    assert_eq!(host.project().tracks[0].devices.len(), 1);

    assert!(host.undo(user()).unwrap());
    assert!(
        host.project().tracks[0].devices.is_empty(),
        "one undo must take back the whole gesture, instrument included"
    );
    assert!(
        host.render_master().is_ok(),
        "the project must still render after the undo — a leftover zoneless \
         sampler would refuse to compile"
    );

    assert!(host.redo(user()).unwrap());
    assert_eq!(host.project().tracks[0].devices.len(), 1);
    assert_eq!(zones(&host).len(), 1, "redo must bring the sound back too");
    assert_eq!(zones(&host)[0].lo_pitch, timeline_core::Num::int(0));
    assert_eq!(zones(&host)[0].hi_pitch, timeline_core::Num::int(127));
}

/// The octave relationship, measured. Separate from the root test above because
/// they fail for different reasons: a constant root offset leaves this ratio
/// perfect, and a broken rate calculation leaves the root test perfect.
#[test]
fn a_key_an_octave_up_renders_at_twice_the_frequency() {
    let (mut host, _pkg) = host_with_track();
    host.bind_samples(full_range(&tone(), 69)).expect("bind");
    snappy(&mut host);
    // Two notes, two beats apart, so each is measured on its own.
    note(&mut host, 2 * PPQ, PPQ, 69);
    note(&mut host, 4 * PPQ, PPQ, 81);
    let audio = host.render_master().expect("compile");

    let win = |beat: u64| {
        let s = (beat * QUARTER_FRAMES + 2_400) as usize;
        &audio[s..s + 12_000]
    };
    let low = measured_hz(win(2));
    let high = measured_hz(win(4));
    let ratio = high / low;
    assert!(
        (ratio - 2.0).abs() < 0.02,
        "+12 semitones measured {high} Hz against {low} Hz, ratio {ratio}, expected 2.00"
    );
}

// ---------------------------------------------------------------------------
// 2. The drum rack: a pad is one key, and only its own key.
// ---------------------------------------------------------------------------

fn pads(paths: &[(&str, i64)]) -> BindSamplesRequest {
    BindSamplesRequest {
        track_id: "t1".into(),
        device_id: None,
        kind: Some("drum".into()),
        remove_zone_ids: Vec::new(),
        bindings: paths
            .iter()
            .map(|(p, key)| SampleBinding {
                source_path: p.to_string(),
                root_pitch: *key,
                lo_pitch: *key,
                hi_pitch: *key,
                gain_db: None,
                pan: None,
            })
            .collect(),
        reason: "Load drum sounds".into(),
    }
}

#[test]
fn a_drum_pad_sounds_on_its_own_key_and_an_unbound_key_stays_silent() {
    let (mut host, _pkg) = host_with_track();
    // GM kick = 36, GM snare = 38. 37 is deliberately left empty.
    let out = host
        .bind_samples(pads(&[(&tone(), 36), (&sweep(), 38)]))
        .expect("bind pads");
    assert_eq!(out.kind, "drum");
    assert_eq!(out.zones.len(), 2);
    assert_eq!(
        last_txn_body(&host),
        vec![
            "device.add".to_string(),
            "device.zone.add".to_string(),
            "device.zone.add".to_string()
        ],
        "two pads in one gesture is one device.add and two zone adds, one undo unit"
    );

    snappy(&mut host);
    // The UNBOUND key goes FIRST, deliberately. A pad is a one-shot: it plays
    // its whole sample regardless of note length, and these fixtures are
    // seconds long, so a bound pad struck earlier is still ringing over any
    // later window. Measuring key 37 before anything has been struck is the
    // only window in which "silent" means the mapping refused it.
    note(&mut host, 2 * PPQ, PPQ, 37); // NOT bound
    note(&mut host, 6 * PPQ, PPQ, 36); // bound
    note(&mut host, 10 * PPQ, PPQ, 38); // bound
    let audio = host.render_master().expect("compile");

    let win = |beat: u64| {
        let s = (beat * QUARTER_FRAMES + 480) as usize;
        peak(&audio[s..s + 8_000])
    };
    let empty = win(2);
    assert!(
        empty < 1e-6,
        "key 37 has no pad, yet it rendered audio (peak {empty}); a rack that answers \
         every key is a rack whose pad mapping does not exist"
    );
    let bound_a = win(6);
    assert!(bound_a > 0.02, "pad 36 rendered nothing: peak {bound_a}");
    // Pad 38 is measured against what pad 36 alone was doing at the same point
    // in its own tail, so "louder" is the strike and not the ring-out.
    let bound_b = win(10);
    assert!(bound_b > 0.02, "pad 38 rendered nothing: peak {bound_b}");
}

// ---------------------------------------------------------------------------
// 3. Replacing and clearing a pad — still one undo step each.
// ---------------------------------------------------------------------------

#[test]
fn replacing_a_pads_sound_is_one_step_and_never_stacks_two_on_a_key() {
    let (mut host, _pkg) = host_with_track();
    let out = host.bind_samples(pads(&[(&tone(), 36)])).expect("bind");
    let device_id = out.device_id.clone();
    let first_zone = out.zones[0].zone_id.clone();
    let first_source = out.zones[0].source_id.clone();

    let replaced = host
        .bind_samples(BindSamplesRequest {
            track_id: "t1".into(),
            device_id: Some(device_id.clone()),
            kind: None,
            remove_zone_ids: vec![first_zone.clone()],
            bindings: vec![SampleBinding {
                source_path: sweep(),
                root_pitch: 36,
                lo_pitch: 36,
                hi_pitch: 36,
                gain_db: None,
                pan: None,
            }],
            reason: "Change a pad's sound".into(),
        })
        .expect("replace");
    assert!(!replaced.created_device);
    assert_eq!(
        last_txn_body(&host),
        vec![
            "device.zone.remove".to_string(),
            "device.zone.add".to_string()
        ],
        "a replacement removes then adds, in that order, in one unit"
    );
    assert_eq!(zones(&host).len(), 1, "the key must still hold exactly one pad");
    assert_ne!(zones(&host)[0].source_id, first_source);

    // One Cmd-Z puts the old sound back.
    assert!(host.undo(user()).unwrap());
    assert_eq!(zones(&host).len(), 1);
    assert_eq!(zones(&host)[0].source_id, first_source);
    assert_eq!(zones(&host)[0].id, first_zone);
}

// ---------------------------------------------------------------------------
// 4. THE REFUSALS. Each must be loud, and must leave the journal untouched —
//    a refusal that half-applied, or that stranded an open transaction, would
//    be worse than the missing feature.
// ---------------------------------------------------------------------------

fn refuses(host: &mut StudioHost, req: BindSamplesRequest, needle: &str) {
    let before = command_names(host);
    let err = host.bind_samples(req).expect_err("this must be refused");
    let msg = err.to_string();
    assert!(
        msg.to_lowercase().contains(needle),
        "the refusal never says \"{needle}\": {msg}"
    );
    assert_eq!(
        command_names(host),
        before,
        "a refused gesture wrote to the journal: {msg}"
    );
    // The bus must still work afterwards — i.e. no transaction was left open.
    host.submit(user(), "project.setTempo", json!({"bpm": 121}))
        .expect("the command bus must still accept work after a refusal");
}

#[test]
fn a_rack_wider_than_sixteen_keys_is_refused_loudly() {
    let (mut host, _pkg) = host_with_track();
    refuses(
        &mut host,
        pads(&[(&tone(), 36), (&sweep(), 60)]),
        "wider than",
    );
    assert!(host.project().tracks[0].devices.is_empty());
}

#[test]
fn a_drum_pad_spanning_more_than_one_key_is_refused() {
    let (mut host, _pkg) = host_with_track();
    let mut req = pads(&[(&tone(), 36)]);
    req.bindings[0].hi_pitch = 40;
    refuses(&mut host, req, "exactly one key");
}

#[test]
fn two_pads_on_the_same_key_are_refused() {
    let (mut host, _pkg) = host_with_track();
    refuses(
        &mut host,
        pads(&[(&tone(), 36), (&tone(), 36)]),
        "same key",
    );
}

#[test]
fn a_synth_cannot_be_given_a_sound() {
    let (mut host, _pkg) = host_with_track();
    host.submit(
        user(),
        "device.add",
        json!({"trackId": "t1", "deviceId": "d1", "kind": "synth"}),
    )
    .unwrap();
    let mut req = full_range(&sweep(), 60);
    req.device_id = Some("d1".into());
    req.kind = None;
    refuses(&mut host, req, "synth");
}

#[test]
fn a_track_that_already_plays_something_refuses_a_second_instrument() {
    let (mut host, _pkg) = host_with_track();
    host.bind_samples(full_range(&sweep(), 60)).expect("first");
    // A second creation would compile-fail ("one instrument per track"), so the
    // gesture has to refuse before it journals anything.
    refuses(&mut host, full_range(&sweep(), 60), "already plays");
}

#[test]
fn emptying_an_instrument_of_every_sound_is_refused_with_the_remedy() {
    let (mut host, _pkg) = host_with_track();
    let out = host.bind_samples(pads(&[(&tone(), 36)])).expect("bind");
    refuses(
        &mut host,
        BindSamplesRequest {
            track_id: "t1".into(),
            device_id: Some(out.device_id.clone()),
            kind: None,
            remove_zone_ids: vec![out.zones[0].zone_id.clone()],
            bindings: Vec::new(),
            reason: "Clear the last pad".into(),
        },
        "remove the instrument instead",
    );
    assert_eq!(zones(&host).len(), 1, "the last pad must still be there");
}

#[test]
fn a_file_that_cannot_be_read_refuses_before_anything_is_journaled() {
    let (mut host, _pkg) = host_with_track();
    // The io runs BEFORE txn.begin precisely so this leaves nothing behind.
    refuses(
        &mut host,
        full_range("/nonexistent/definitely-not-a-sound.wav", 60),
        "read",
    );
    assert!(host.project().tracks[0].devices.is_empty());
}

// ---------------------------------------------------------------------------
// 5. Durability. The ingest is deliberately NOT journaled — what makes it last
//    is the bytes under audio/. If that claim is wrong, a reopened project has
//    a zone pointing at nothing and the sampler stops compiling, which is
//    exactly the silent-degradation class this program keeps catching.
// ---------------------------------------------------------------------------

#[test]
fn a_bound_sampler_still_sounds_after_a_save_and_reopen() {
    let (mut host, pkg) = host_with_track();
    host.bind_samples(full_range(&tone(), 69)).expect("bind");
    snappy(&mut host);
    note(&mut host, 2 * PPQ, PPQ * 2, 69);
    let live = host.render_master().expect("compile");
    host.save().expect("save");
    drop(host);

    let reopened = StudioHost::open_package(&pkg).expect("reopen");
    let after = reopened
        .render_master()
        .expect("a reopened project's sampler must still compile — its asset lives in audio/");
    assert!(
        peak(&after) > 0.05,
        "the reopened sampler renders silence (peak {})",
        peak(&after)
    );
    assert_eq!(
        live.len(),
        after.len(),
        "the reopened bounce changed length"
    );
    assert_eq!(
        live, after,
        "the reopened project must bounce bit-identically"
    );
}

// ---------------------------------------------------------------------------
// 6. The read surface the UI names a sound with.
// ---------------------------------------------------------------------------

#[test]
fn the_snapshot_names_the_file_behind_every_bound_source() {
    let (mut host, _pkg) = host_with_track();
    let out = host.bind_samples(full_range(&tone(), 69)).expect("bind");
    let snap: Value = host.snapshot(None);
    let loaded = &snap["project"]["loadedSources"][&out.zones[0].source_id];
    assert!(
        !loaded.is_null(),
        "the bound source is missing from loadedSources, so the UI can only show a hash"
    );
    let path = loaded["path"].as_str().unwrap_or_default();
    assert!(
        path.ends_with("tone_440_48k_mono.wav"),
        "loadedSources names {path}, not the file the user picked"
    );
    // And the zone the UI reads is in the snapshot with the same id.
    let zone = &snap["project"]["tracks"][0]["devices"][0]["zones"][0];
    assert_eq!(zone["source_id"], json!(out.zones[0].source_id));
    assert_eq!(zone["lo_pitch"], json!(0));
    assert_eq!(zone["hi_pitch"], json!(127));
    assert_eq!(zone["root_pitch"], json!(69));
}
