//! The control-side half of auditioning: what a keyboard key and a piano-roll
//! key press actually DO, and what they are forbidden from doing.
//!
//! Two things are under test here and they are equally load-bearing:
//!
//! 1. **A MIDI keyboard plays notes by default.** The bundled SX-KC211 map
//!    binds sixteen NOTES in the playable range — C2..D4, middle C included —
//!    to transport, record, undo, redo, mixer gain and Sterling instructions.
//!    That collision was invisible only because nothing was audible; the moment
//!    an instrument could be heard, a musician playing middle C would have
//!    fired "Sterling: add a layer" instead. Port roles fix it WITHOUT deleting
//!    anyone's bindings.
//! 2. **Auditioning never opens the audio device.** The house rule is absolute:
//!    live monitoring is attended, explicit, opt-in. Drawing a note or plugging
//!    in a MIDI cable must not be able to grab the output device.
//!
//! NO hardware, NO CoreMIDI, NO audio. Every case drives `midi::feed_event` and
//! the tool dispatcher, exactly like `tests/midi.rs`.

use agent_surface::midi::event::MidiEvent;
use agent_surface::midi::feed_event;
use agent_surface::{dispatch_tool, StudioHost};
use serde_json::{json, Value};
use timeline_core::Actor;

fn user() -> Actor {
    Actor::user("test")
}
fn agent() -> Actor {
    Actor {
        kind: timeline_core::envelope::ActorKind::Agent,
        name: "copilot".into(),
    }
}

/// The cable name the bundled SX-KC211 map auto-matches.
const KC: &str = "usb midi interface";

fn note_on(n: u8) -> MidiEvent {
    MidiEvent::NoteOn {
        note: n,
        velocity: 100,
        channel: 0,
    }
}
fn note_off(n: u8) -> MidiEvent {
    MidiEvent::NoteOff {
        note: n,
        velocity: 0,
        channel: 0,
    }
}

fn playing(host: &StudioHost) -> bool {
    host.snapshot(None)["transport"]["playing"]
        .as_bool()
        .unwrap()
}
fn sterling_pending(host: &StudioHost) -> usize {
    host.snapshot(None)["midi"]["sterling"]["pending"]
        .as_array()
        .map(Vec::len)
        .unwrap_or(0)
}

/// A project with one instrument track, built through the real command bus.
fn host_with_instrument() -> StudioHost {
    let mut host = StudioHost::in_memory();
    host.submit(user(), "track.add", json!({"trackId": "t1", "name": "Keys"}))
        .unwrap();
    host.submit(
        user(),
        "device.add",
        json!({"trackId": "t1", "deviceId": "inst1", "kind": "synth"}),
    )
    .unwrap();
    host
}

// ---------------------------------------------------------------------------
// 1. The keys play
// ---------------------------------------------------------------------------

#[test]
fn a_keyboard_key_no_longer_fires_the_control_binding_bound_to_it() {
    // Every one of these is a real binding in the bundled map, on a note a
    // musician will absolutely play. Under the default `instrument` role NONE
    // of them may fire.
    let mut host = host_with_instrument();

    feed_event(&mut host, KC, &note_on(36)); // C2  -> transport.toggle
    assert!(!playing(&host), "C2 must play a note, not start the transport");

    feed_event(&mut host, KC, &note_on(43)); // G2  -> transport.stop
    feed_event(&mut host, KC, &note_on(60)); // C4  -> Sterling: tighten timing
    feed_event(&mut host, KC, &note_on(62)); // D4  -> Sterling: add a layer
    assert_eq!(
        sterling_pending(&host),
        0,
        "middle C must not queue a Sterling instruction"
    );

    // undo (E2) and redo (F2) are host session verbs, so a stolen keypress
    // would silently rewind the user's work.
    host.submit(user(), "mix.gain", json!({"trackId": "t1", "gainDb": -8.0}))
        .unwrap();
    feed_event(&mut host, KC, &note_on(40)); // E2 -> undo
    assert_eq!(
        host.snapshot(None)["project"]["tracks"][0]["gain"]
            .as_f64()
            .unwrap(),
        -8.0,
        "E2 must play a note, not undo the last edit"
    );
}

#[test]
fn flipping_the_port_to_control_gives_every_binding_back() {
    // The other half of "do not delete anyone's work": one command restores the
    // whole control surface, and it is the SAME sixteen bindings.
    let mut host = host_with_instrument();
    host.submit(
        user(),
        "midi.port.role.set",
        json!({"port": KC, "role": "control"}),
    )
    .unwrap();

    feed_event(&mut host, KC, &note_on(36));
    assert!(playing(&host), "role=control: C2 is the transport toggle again");
    feed_event(&mut host, KC, &note_on(60));
    assert_eq!(sterling_pending(&host), 1, "role=control: C4 queues Sterling again");

    // And back again, in the same session, with no reload.
    host.submit(
        user(),
        "midi.port.role.set",
        json!({"port": KC, "role": "instrument"}),
    )
    .unwrap();
    let before = playing(&host);
    feed_event(&mut host, KC, &note_on(36));
    assert_eq!(
        playing(&host),
        before,
        "role=instrument again: C2 stops driving the transport"
    );
}

#[test]
fn a_continuous_control_still_reaches_its_binding_on_an_instrument_port() {
    // The role splits by MESSAGE TYPE, not by device: a controller with keys
    // AND knobs must keep its knobs while its keys play. (The generic-controller
    // map binds CC 21 to mix.gain.)
    let mut host = host_with_instrument();
    host.submit(
        user(),
        "midi.device.select",
        json!({"device": "fader", "map": "generic-controller"}),
    )
    .unwrap();

    feed_event(
        &mut host,
        "fader",
        &MidiEvent::ControlChange {
            controller: 21,
            value: 64,
            channel: 0,
        },
    );
    let gain = host.snapshot(None)["project"]["tracks"][0]["gain"]
        .as_f64()
        .unwrap();
    assert!(
        (gain - (-60.0 + (64.0 / 127.0) * 72.0)).abs() < 1e-6,
        "a CC binding must still fire on an instrument-role port; gain was {gain}"
    );
}

#[test]
fn the_default_role_is_instrument_and_it_persists_across_a_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let mut host = StudioHost::with_data_dir(dir.path()).unwrap();
    host.midi_declare_port(KC, true);
    let ports = host.snapshot(None)["midi"]["ports"].clone();
    assert_eq!(
        ports[0]["role"], "instrument",
        "a port nobody has configured plays notes"
    );

    host.submit(
        user(),
        "midi.port.role.set",
        json!({"port": KC, "role": "control"}),
    )
    .unwrap();

    // A FRESH host over the same data dir: the role survived to disk.
    let host2 = StudioHost::with_data_dir(dir.path()).unwrap();
    host2.midi_declare_port(KC, true);
    assert_eq!(
        host2.snapshot(None)["midi"]["ports"][0]["role"],
        "control",
        "the role must persist alongside the map overrides"
    );
}

#[test]
fn the_snapshot_says_which_bindings_the_role_is_swallowing() {
    // "16 active bindings" while all 16 are being suppressed is a green signal
    // on the wrong axis — it reads as a hardware fault. The row must say so.
    let host = StudioHost::in_memory();
    host.midi_declare_port(KC, true);
    let bindings = host.snapshot(None)["midi"]["activeBindings"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    assert!(!bindings.is_empty(), "the bundled map resolved for this port");
    assert!(
        bindings.iter().all(|b| b["suppressedByRole"] == json!(true)),
        "every sx-kc211 binding is on a NOTE, so role=instrument suppresses all of them"
    );

    let mut host = host;
    host.submit(
        user(),
        "midi.port.role.set",
        json!({"port": KC, "role": "control"}),
    )
    .unwrap();
    let bindings = host.snapshot(None)["midi"]["activeBindings"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    assert!(
        bindings.iter().all(|b| b["suppressedByRole"] == json!(false)),
        "role=control suppresses nothing"
    );
}

#[test]
fn keys_target_the_armed_instrument_track_and_fall_back_to_the_only_one() {
    let mut host = StudioHost::in_memory();
    host.submit(user(), "track.add", json!({"trackId": "t1", "name": "Gtr"}))
        .unwrap();
    assert_eq!(
        host.midi_instrument_target(),
        None,
        "a project with no instrument has nothing for the keys to play"
    );

    host.submit(user(), "track.add", json!({"trackId": "t2", "name": "Keys"}))
        .unwrap();
    host.submit(
        user(),
        "device.add",
        json!({"trackId": "t2", "deviceId": "inst1", "kind": "synth"}),
    )
    .unwrap();
    assert_eq!(
        host.midi_instrument_target().as_deref(),
        Some("t2"),
        "the only instrument track is unambiguous"
    );

    host.submit(user(), "track.add", json!({"trackId": "t3", "name": "Pad"}))
        .unwrap();
    host.submit(
        user(),
        "device.add",
        json!({"trackId": "t3", "deviceId": "inst2", "kind": "synth"}),
    )
    .unwrap();
    host.submit(user(), "track.arm", json!({"trackId": "t3", "armed": true}))
        .unwrap();
    assert_eq!(
        host.midi_instrument_target().as_deref(),
        Some("t3"),
        "arming picks the track the keys play"
    );
}

// ---------------------------------------------------------------------------
// 2. Auditioning never opens the device, and never edits the project
// ---------------------------------------------------------------------------

fn preview(host: &mut StudioHost, params: Value) -> Value {
    dispatch_tool(host, agent(), "studio_note_preview", params).expect("studio_note_preview")
}

#[test]
fn auditioning_on_a_host_that_never_opted_into_audio_reports_it_and_opens_nothing() {
    // THE audio-safety gate, restated for what it actually protects.
    //
    // It used to read "auditioning never opens the device, full stop" — which
    // also meant a person with a keyboard had to press Play and then Stop before
    // any key made a sound. That is not a safety property, it is a ritual, and
    // the ritual is gone.
    //
    // What this now pins is the property that matters and that the whole
    // automated-blast safety rests on: a host whose GUI never called
    // `set_audible_output` opens NOTHING, no matter how many notes are played at
    // it. Every `cargo test`, every headless CLI run, and every MCP-only host is
    // that host. If this ever returns audible:true, an agent can make an
    // unattended machine sing.
    let mut host = host_with_instrument();
    assert!(!host.is_live(), "precondition: no live session");

    let out = preview(&mut host, json!({"trackId": "t1", "pitch": 60}));
    assert_eq!(out["audible"], json!(false));
    assert!(
        out["reason"].as_str().unwrap().contains("audible output"),
        "the reason must name the cause, not just fail quietly: {out}"
    );
    assert!(
        !host.is_live(),
        "a host that never opted into audio MUST NOT open the live output stream"
    );
}

#[test]
fn a_midi_key_press_cannot_open_the_audio_device_on_a_silent_host_either() {
    // The same rule, reached through the hardware path rather than the UI one.
    // A cable being plugged into a headless host must never grab the output.
    let mut host = host_with_instrument();
    feed_event(&mut host, KC, &note_on(60));
    feed_event(&mut host, KC, &note_off(60));
    assert!(
        !host.is_live(),
        "a MIDI keypress MUST NOT open the live output stream on a silent host"
    );
}

#[test]
fn the_live_microphone_monitoring_refusal_is_untouched_by_the_play_a_note_path() {
    // The play-a-note lane deliberately separated two things that had been
    // conflated under the word "monitoring":
    //
    //   - PLAYING AN INSTRUMENT: a synth voice, driven by a discrete human
    //     gesture, with no input transducer in the path. No feedback loop can
    //     form. This now opens the output device on a GUI host (above).
    //   - MONITORING A MICROPHONE: mic -> speakers -> mic, a closed acoustic
    //     loop that builds to a howl with no further user action. Still refused.
    //
    // If a later lane "simplifies" these back together, this fails.
    assert!(
        !render::recording::monitoring_allowed(true),
        "live mic monitoring must still be refused even when explicitly requested"
    );
}

#[test]
fn auditioning_a_track_with_no_instrument_says_so() {
    let mut host = StudioHost::in_memory();
    host.submit(user(), "track.add", json!({"trackId": "t1", "name": "Gtr"}))
        .unwrap();
    let out = preview(&mut host, json!({"trackId": "t1", "pitch": 60}));
    assert_eq!(out["audible"], json!(false));
    assert!(out["reason"]
        .as_str()
        .unwrap()
        .contains("no instrument device"));
}

#[test]
fn auditioning_is_not_journaled_and_not_undoable() {
    // Hearing a pitch is feedback, not an edit. If a gutter key pushed an undo
    // step, Cmd-Z would start undoing keypresses instead of the user's work.
    let mut host = host_with_instrument();
    let seq_before = host.seq();
    let undo_before = host.snapshot(None)["project"]["undoDepth"].clone();

    for pitch in [60, 64, 67] {
        preview(&mut host, json!({"trackId": "t1", "pitch": pitch}));
    }
    feed_event(&mut host, KC, &note_on(72));
    feed_event(&mut host, KC, &note_off(72));

    assert_eq!(host.seq(), seq_before, "an audition must not bump the journal seq");
    assert_eq!(
        host.snapshot(None)["project"]["undoDepth"], undo_before,
        "an audition must not push an undo step"
    );
}

#[test]
fn the_audition_tool_rejects_an_out_of_range_pitch() {
    let mut host = host_with_instrument();
    let err = dispatch_tool(
        &mut host,
        agent(),
        "studio_note_preview",
        json!({"trackId": "t1", "pitch": 200}),
    );
    assert!(err.is_err(), "pitch 200 is not a MIDI note");
}

#[test]
fn the_audition_tool_exists_on_the_agent_surface() {
    // An agent driving the roll needs the same audition a person gets, or the
    // two surfaces diverge the moment anyone automates a part.
    assert!(
        agent_surface::tool_defs()
            .iter()
            .any(|t| t.name == "studio_note_preview"),
        "studio_note_preview must be a registered tool"
    );
}
