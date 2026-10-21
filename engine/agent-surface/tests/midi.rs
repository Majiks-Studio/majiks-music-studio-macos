//! MIDI engine (M2) integration tests. NO hardware, NO CoreMIDI, NO audio
//! (spec 11): every case drives `midi::feed_event`, the no-device injection
//! seam, and asserts the tracked transport / mixer / snapshot the SAME bus the
//! UI and agents see. Nothing here sets MAJIKS_TEST_AUDIBLE or opens a device.

use agent_surface::midi::event::MidiEvent;
use agent_surface::midi::feed_event;
use agent_surface::{dispatch_tool, StudioHost};
use serde_json::json;
use timeline_core::{envelope::ActorKind, Actor};

fn user() -> Actor {
    Actor::user("test")
}
fn note_on(n: u8) -> MidiEvent {
    MidiEvent::NoteOn { note: n, velocity: 100, channel: 0 }
}
fn snap(host: &StudioHost) -> serde_json::Value {
    host.snapshot(None)
}
fn playing(host: &StudioHost) -> bool {
    snap(host)["transport"]["playing"].as_bool().unwrap()
}
fn track_gain(host: &StudioHost, i: usize) -> f64 {
    snap(host)["project"]["tracks"][i]["gain"].as_f64().unwrap()
}
fn last_entry(host: &StudioHost) -> serde_json::Value {
    host.journal_page(None, 500)["entries"].as_array().unwrap().last().unwrap().clone()
}

// The SX-KC211 map auto-loads for this cable name (bundled namePatterns).
const KC: &str = "usb midi interface";

/// Declare a port a CONTROL SURFACE, so its note-matched bindings fire.
///
/// Every test below that presses a KEY expecting a transport/mixer/Sterling
/// action has to say this now, and that is the point: the DEFAULT role is
/// `instrument`, so a keyboard's keys play notes. Before roles existed, the
/// bundled SX-KC211 map silently owned C2..D4 — middle C included — and a
/// musician pressing middle C would have fired "Sterling: add a layer".
fn as_control_surface(host: &mut StudioHost, port: &str) {
    host.submit(
        user(),
        "midi.port.role.set",
        json!({ "port": port, "role": "control" }),
    )
    .expect("midi.port.role.set");
}

#[test]
fn note_on_a_transport_binding_dispatches_play_and_stop() {
    let mut host = StudioHost::in_memory();
    as_control_surface(&mut host, KC);
    assert!(!playing(&host));
    // Note 36 is the sx-kc211 transport.toggle builtin.
    let swallowed = feed_event(&mut host, KC, &note_on(36));
    assert!(!swallowed, "no learn session, so the event is not swallowed");
    assert!(playing(&host), "not playing -> transport.play");
    feed_event(&mut host, KC, &note_on(36));
    assert!(!playing(&host), "playing -> transport.stop (toggle)");
}

#[test]
fn cc_with_value_and_track_placeholder_dispatches_mix_gain() {
    let mut host = StudioHost::in_memory();
    host.submit(user(), "track.add", json!({ "trackId": "t1", "name": "Track 1" })).unwrap();
    // Pin the generic map (CC 21 -> mix.gain {trackId:$track:0, gainDb:$value}).
    host.submit(user(), "midi.device.select", json!({ "device": "fader", "map": "generic-controller" })).unwrap();

    feed_event(&mut host, "fader", &MidiEvent::ControlChange { controller: 21, value: 64, channel: 0 });

    // valueMap 0..127 -> -60..12 linear; the $track:0 placeholder resolves to t1.
    let expected = -60.0 + (64.0 / 127.0) * 72.0;
    assert!((track_gain(&host, 0) - expected).abs() < 1e-6, "mapped gain {} != {expected}", track_gain(&host, 0));
}

#[test]
fn mix_gain_nudge_builtin_reads_current_and_clamps() {
    let mut host = StudioHost::in_memory();
    as_control_surface(&mut host, KC);
    host.submit(user(), "track.add", json!({ "trackId": "t1", "name": "Track 1" })).unwrap();
    host.submit(user(), "mix.gain", json!({ "trackId": "t1", "gainDb": -5.0 })).unwrap();
    // sx-kc211 note 50 = track 1 gain nudge +1 dB.
    feed_event(&mut host, KC, &note_on(50));
    assert!((track_gain(&host, 0) - (-4.0)).abs() < 1e-9, "nudge +1 from -5 -> -4");
}

#[test]
fn undo_and_redo_builtins_route_to_host_session_verbs() {
    let mut host = StudioHost::in_memory();
    as_control_surface(&mut host, KC);
    host.submit(user(), "track.add", json!({ "trackId": "t1", "name": "Track 1" })).unwrap();
    host.submit(user(), "mix.gain", json!({ "trackId": "t1", "gainDb": -8.0 })).unwrap();
    assert!((track_gain(&host, 0) - (-8.0)).abs() < 1e-9);
    // Note 40 = undo, note 41 = redo (both host verbs, not bus commands).
    feed_event(&mut host, KC, &note_on(40));
    assert!((track_gain(&host, 0) - 0.0).abs() < 1e-9, "undo reverted the gain");
    feed_event(&mut host, KC, &note_on(41));
    assert!((track_gain(&host, 0) - (-8.0)).abs() < 1e-9, "redo reapplied the gain");
}

#[test]
fn learn_capture_then_binding_set_persists_reloads_and_dispatches_then_clear() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = StudioHost::with_data_dir(dir.path()).unwrap();

    host.submit(user(), "midi.learn.start", json!({})).unwrap();
    let swallowed = feed_event(&mut host, "my kbd", &note_on(60));
    assert!(swallowed, "an active learn session captures + swallows the event");

    let cap = snap(&host)["midi"]["learn"]["captured"].clone();
    assert_eq!(cap["device"], "my kbd");
    assert_eq!(cap["type"], "noteOn");
    assert_eq!(cap["number"], 60);
    assert_eq!(snap(&host)["midi"]["learn"]["active"], true);

    // No control/device given: binds the captured control to transport.play.
    host.submit(user(), "midi.binding.set", json!({ "target": { "kind": "command", "name": "transport.play" } })).unwrap();
    host.submit(user(), "midi.learn.stop", json!({})).unwrap();

    // A FRESH host over the same data dir proves the binding persisted to disk
    // and reloads (M2's persistence + registry reload).
    let mut host2 = StudioHost::with_data_dir(dir.path()).unwrap();
    as_control_surface(&mut host2, "my kbd");
    assert!(!playing(&host2));
    feed_event(&mut host2, "my kbd", &note_on(60));
    assert!(playing(&host2), "the persisted binding dispatches after reload");

    // binding.clear removes it from the user overlay.
    host2.submit(user(), "midi.binding.clear", json!({
        "device": "my kbd",
        "control": { "type": "noteOn", "channel": 0, "number": 60 }
    })).unwrap();
    let maps = snap(&host2)["midi"]["maps"].as_array().unwrap().clone();
    let mine = maps.iter().find(|m| m["key"] == "my_kbd").expect("the user map exists");
    assert_eq!(mine["bindingCount"], 0, "clear removed the only binding");
}

#[test]
fn map_import_validates_and_refuses_overwrite() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = StudioHost::with_data_dir(dir.path()).unwrap();

    let src = dir.path().join("incoming.json");
    std::fs::write(&src, r#"{"version":1,"name":"Imported","device":{"namePatterns":["imp"]},
      "bindings":[{"id":"p","label":"Play","match":{"type":"noteOn","channel":0,"number":60},
      "target":{"kind":"command","name":"transport.play"}}]}"#).unwrap();

    let r = host.submit(user(), "midi.map.import", json!({ "sourcePath": src.to_str().unwrap() })).unwrap();
    assert_eq!(r["bindings"], 1);
    assert_eq!(r["file"], "incoming.json");
    assert_eq!(r["replacedFile"], false);

    // A second import of the same file name without overwrite is refused.
    let refused = host.submit(user(), "midi.map.import", json!({ "sourcePath": src.to_str().unwrap() }));
    assert!(refused.is_err(), "re-import without overwrite must be refused");

    // overwrite:true replaces it.
    let ok = host.submit(user(), "midi.map.import", json!({ "sourcePath": src.to_str().unwrap(), "overwrite": true })).unwrap();
    assert_eq!(ok["replacedFile"], true);

    // A map whose command target does not exist fails validation (typo at load,
    // not at first keypress).
    let bad = dir.path().join("bad.json");
    std::fs::write(&bad, r#"{"version":1,"name":"Bad","device":{"namePatterns":["bad"]},
      "bindings":[{"id":"x","label":"X","match":{"type":"noteOn","channel":0,"number":1},
      "target":{"kind":"command","name":"no.such.command"}}]}"#).unwrap();
    let invalid = host.submit(user(), "midi.map.import", json!({ "sourcePath": bad.to_str().unwrap() }));
    assert!(invalid.is_err(), "an unknown target command must fail import validation");
}

#[test]
fn sterling_binding_pushes_to_the_ring_with_monotonic_seq() {
    let mut host = StudioHost::in_memory();
    as_control_surface(&mut host, KC);
    feed_event(&mut host, KC, &note_on(60)); // sterling-revise-tighten
    feed_event(&mut host, KC, &note_on(62)); // sterling-add-layer

    let st = snap(&host)["midi"]["sterling"].clone();
    assert_eq!(st["nextSeq"], 2, "two triggers assigned seq 0 and 1; next is 2");
    let pending = st["pending"].as_array().unwrap();
    assert_eq!(pending.len(), 2);
    assert_eq!(pending[0]["seq"], 0);
    assert_eq!(pending[1]["seq"], 1);
    assert_eq!(pending[0]["bindingId"], "sterling-revise-tighten");
    assert_eq!(pending[1]["port"], KC);
    assert!(pending[1]["instruction"].as_str().unwrap().contains("complementary layer"));
    // No transport moved: a sterling press produces no bus command (spec 8.2).
    assert!(!playing(&host));
}

#[test]
fn sterling_ring_is_bounded_and_drops_the_oldest() {
    let mut host = StudioHost::in_memory();
    as_control_surface(&mut host, KC);
    // Fire the sterling-revise-tighten trigger (note 60) more times than the ring
    // holds (STERLING_RING_MAX = 16). Each press pushes one item with a monotonic
    // seq; the ring keeps only the newest 16 and drops the oldest.
    for _ in 0..20 {
        feed_event(&mut host, KC, &note_on(60));
    }
    let st = snap(&host)["midi"]["sterling"].clone();
    assert_eq!(st["nextSeq"], 20, "20 triggers assigned seq 0..19; next is 20");
    let pending = st["pending"].as_array().unwrap();
    assert_eq!(pending.len(), 16, "the ring is bounded to 16");
    assert_eq!(pending[0]["seq"], 4, "the oldest surviving item is seq 4 (0..3 evicted)");
    assert_eq!(pending[15]["seq"], 19, "the newest item is seq 19");
    assert!(!playing(&host), "no press moved transport (spec 8.2)");
}

#[test]
fn provenance_splits_human_midi_from_the_sterling_agent() {
    // Spec 8.2: a human-played MIDI command is the person's edit (user/midi); a
    // Sterling trigger produces NO bus command at press time (it only queues an
    // instruction); and when the agent later acts on the drained instruction the
    // edit is the agent's (agent/sterling). Human performance is never the agent.
    let mut host = StudioHost::in_memory();
    host.submit(user(), "track.add", json!({ "trackId": "t1", "name": "Track 1" })).unwrap();
    host.submit(user(), "midi.device.select", json!({ "device": "fader", "map": "generic-controller" })).unwrap();
    as_control_surface(&mut host, KC);

    // 1. A Sterling trigger is silent: it queues an instruction, journals nothing.
    let before = host.journal_page(None, 500)["total"].as_u64().unwrap();
    feed_event(&mut host, KC, &note_on(60)); // sterling-revise-tighten
    assert_eq!(
        host.journal_page(None, 500)["total"].as_u64().unwrap(),
        before,
        "a sterling press must not journal a bus command (spec 8.2)"
    );
    assert_eq!(
        snap(&host)["midi"]["sterling"]["pending"].as_array().unwrap().len(),
        1,
        "the instruction waits in the ring for the copilot to drain"
    );

    // 2. A human-played MIDI command journals as the person, never the agent.
    feed_event(&mut host, "fader", &MidiEvent::ControlChange { controller: 21, value: 64, channel: 0 });
    let tip = last_entry(&host);
    assert_eq!(tip["name"], "mix.gain", "the CC drove a mix.gain");
    assert_eq!(tip["actor"]["kind"], "user", "human MIDI is the person");
    assert_eq!(tip["actor"]["name"], "midi");

    // 3. The agent acting on a drained instruction (the copilot's tool call, the
    //    same path the Swift consumer submits into) journals as the agent, not the
    //    human. This uses the same agent/sterling actor a Sterling turn stamps;
    //    that copilot::sterling_actor() equals this actor is pinned by the
    //    sterling_actor_is_the_spec_agent unit test in copilot.rs.
    let sterling = Actor { kind: ActorKind::Agent, name: "sterling".into() };
    dispatch_tool(
        &mut host,
        sterling,
        "studio_section_set",
        json!({ "sectionId": "s1", "name": "OUTRO", "startTicks": 0 }),
    )
    .unwrap();
    let tip = last_entry(&host);
    assert_eq!(tip["actor"]["kind"], "agent", "the agent's edit is attributed to the agent");
    assert_eq!(tip["actor"]["name"], "sterling");
}

#[test]
fn device_select_override_beats_auto_detect() {
    let mut host = StudioHost::in_memory();
    as_control_surface(&mut host, KC);
    // Auto-detect would map this cable to sx-kc211 (note 36 -> play). Pin the
    // generic map instead (note 60 -> play; note 36 unmapped there).
    host.submit(user(), "midi.device.select", json!({ "device": KC, "map": "generic-controller" })).unwrap();

    feed_event(&mut host, KC, &note_on(36));
    assert!(!playing(&host), "note 36 is unmapped under the generic override");
    feed_event(&mut host, KC, &note_on(60));
    assert!(playing(&host), "note 60 is the generic transport toggle; the override won");
}

#[test]
fn map_export_writes_the_map_body_to_a_path() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = StudioHost::with_data_dir(dir.path()).unwrap();
    let out = dir.path().join("exported-sx.json");

    let r = host.submit(user(), "midi.map.export", json!({ "map": "sx-kc211", "outputPath": out.to_str().unwrap() })).unwrap();
    assert_eq!(r["name"], "SX-KC211 (Studio)");

    let parsed: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&out).unwrap()).unwrap();
    assert_eq!(parsed["name"], "SX-KC211 (Studio)");
    assert!(parsed["bindings"].as_array().unwrap().len() >= 16, "the full map body was written");
}

#[test]
fn snapshot_midi_block_has_the_spec6_shape() {
    let host = StudioHost::in_memory();
    let m = snap(&host)["midi"].clone();
    for k in ["enabled", "ports", "maps", "activeBindings", "learn", "lastEvent", "sterling"] {
        assert!(m.get(k).is_some(), "midi snapshot missing key {k}");
    }
    assert!(m["maps"].as_array().unwrap().iter().any(|x| x["key"] == "sx-kc211"), "bundled maps populate");
    assert_eq!(m["sterling"]["nextSeq"], 0);
    assert_eq!(m["learn"]["active"], false);
    assert!(m["ports"].as_array().unwrap().is_empty(), "no hardware -> no ports");
}

#[test]
fn continuous_faders_coalesce_but_buttons_do_not() {
    // The coalescing decision (spec 2.4): a $value command is a fader; a builtin
    // toggle is a button. Pure classification, no threads.
    use agent_surface::midi::map::{Binding, ControlMatch, Target};
    use agent_surface::midi::resolve::binding_is_continuous;

    let fader = Binding {
        id: "f".into(), label: "f".into(),
        control: ControlMatch::ControlChange { channel: 0, number: 21 },
        target: Target::Command { name: "mix.gain".into(), params: json!({ "trackId": "$track:0", "gainDb": "$value" }) },
        value_map: None, enabled: true, comment: None,
    };
    let button = Binding {
        id: "b".into(), label: "b".into(),
        control: ControlMatch::NoteOn { channel: 0, number: 36 },
        target: Target::Builtin { name: "transport.toggle".into(), params: serde_json::Value::Null },
        value_map: None, enabled: true, comment: None,
    };
    assert!(binding_is_continuous(&fader));
    assert!(!binding_is_continuous(&button));
}

#[test]
fn valuemap_partial_deserializes_with_schema_defaults() {
    // The catalog schema declares all four ranges optional-with-defaults
    // (0/127/0/1), so a partial or empty valueMap must load, not hard-error and
    // drop the whole map to zero bindings.
    use agent_surface::midi::map::ValueMap;
    let vm: ValueMap = serde_json::from_value(json!({"outputMin": -60.0, "outputMax": 12.0})).unwrap();
    assert_eq!(vm.input_min, 0.0);
    assert_eq!(vm.input_max, 127.0);
    let empty: ValueMap = serde_json::from_value(json!({})).unwrap();
    assert_eq!(empty.output_max, 1.0);
}

#[test]
fn midi_subsystem_survives_project_switch() {
    // Creating/opening a project replaces the StudioHost in place. The MIDI
    // subsystem (app-level config + the live pump) must carry over, not drop:
    // dropping it would kill MIDI on every project open and deadlock on the
    // pump's join under the host lock. A live learn session (in-memory state)
    // that survives project.new proves the subsystem was preserved.
    let dir = tempfile::tempdir().unwrap();
    let mut host = StudioHost::with_data_dir(dir.path()).unwrap();
    host.submit(user(), "midi.learn.start", json!({})).unwrap();
    assert_eq!(snap(&host)["midi"]["learn"]["active"], json!(true));
    host.submit(user(), "project.new", json!({"name": "Switch"})).unwrap();
    assert_eq!(
        snap(&host)["midi"]["learn"]["active"], json!(true),
        "in-memory MIDI state (and the pump) must survive the host swap"
    );
}
