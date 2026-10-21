//! PLAY A NOTE: the whole first-run path, driven the way hardware drives it.
//!
//! The finding this file exists for: to make a connected MIDI keyboard produce a
//! sound, the shipped app required
//!
//!     Studio -> Instrument -> Play -> Stop -> now play
//!
//! and every one of those clicks was correct by design. Each test below deletes
//! one of them, or pins a property that must survive their deletion.
//!
//! # Which production hops these tests actually traverse
//!
//! Everything MIDI-shaped goes in through `midi::pump::inject`, which hands the
//! event to the RUNNING pump at exactly the point a CoreMIDI callback does — the
//! same channel, the same drain, the same thread hop, the same dispatch. It does
//! NOT use `midi::feed_event`, which calls `dispatch_event` on the caller's
//! thread and therefore goes around the pump; a 15 ms input delay once shipped
//! 100% green precisely because the only seam available was that one.
//!
//! The traversed chain, in order:
//!
//! 1. `pump::inject`                      — the device-callback handoff point
//! 2. the pump's bounded event channel + its own thread's drain
//! 3. `midi::dispatch_event`              — port-role resolution
//! 4. `midi::dispatch_note_to_instrument` — the note branch
//! 5. `StudioHost::ensure_instrument_target` — creates a track on an empty project
//! 6. `StudioHost::midi_record_event`     — the armed-take buffer (inactive here)
//! 7. `StudioHost::preview_note`          — the one note path
//! 8. `StudioHost::performance_note`      — the retro-capture buffer
//! 9. `StudioHost::ensure_live_for_performance` — refuses on this silent host
//! 10. `StudioHost::snapshot`             — what the UI reads
//!
//! NO hardware, NO CoreMIDI connections, NO audio. `MAJIKS_MIDI_PORT_FILTER` is
//! set to a sentinel no port name can contain, so the pump's scan enumerates and
//! connects nothing, and this host never calls `set_audible_output`, so nothing
//! here can open an output device.

use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, Once};
use std::time::{Duration, Instant};

use agent_surface::midi::event::MidiEvent;
use agent_surface::midi::{pump, start_pump};
use agent_surface::{dispatch_tool, StudioHost};
use serde_json::{json, Value};
use timeline_core::{tempo::PPQ, Actor};

/// A name no real MIDI port contains, so `scan` connects zero devices.
const NO_HARDWARE: &str = "__majiks_no_such_midi_port__";

/// The port every test injects on. It matches NO bundled map — which is the
/// point: an ordinary USB keyboard nobody wrote a map for must still play.
const UNMAPPED_PORT: &str = "Some Unremarkable USB Keyboard";

static FILTER: Once = Once::new();

fn agent() -> Actor {
    Actor {
        kind: timeline_core::envelope::ActorKind::Agent,
        name: "copilot".into(),
    }
}

/// A host with a live pump and an EMPTY project — no tracks, no instrument,
/// nothing. This is a person who just opened the app.
fn empty_project_with_pump() -> Arc<Mutex<StudioHost>> {
    FILTER.call_once(|| std::env::set_var("MAJIKS_MIDI_PORT_FILTER", NO_HARDWARE));
    let host = Arc::new(Mutex::new(StudioHost::in_memory()));
    start_pump(&host).expect("start pump");
    // Let the pump reach its steady-state loop (first scan done).
    std::thread::sleep(Duration::from_millis(150));
    host
}

fn note_on(note: u8) -> MidiEvent {
    MidiEvent::NoteOn {
        note,
        velocity: 100,
        channel: 0,
    }
}
fn note_off(note: u8) -> MidiEvent {
    MidiEvent::NoteOff {
        note,
        velocity: 0,
        channel: 0,
    }
}

/// Inject one event through the pump and BLOCK until the pump has finished
/// dispatching it, so the assertions that follow read settled state rather than
/// racing the pump thread.
fn play(host: &Arc<Mutex<StudioHost>>, event: MidiEvent) {
    let shared = host.lock().unwrap().midi_shared();
    let before = shared.dispatched_seq.load(Ordering::Relaxed);
    assert!(
        pump::inject(&shared, UNMAPPED_PORT, event),
        "the pump inlet refused the event; no pump is running"
    );
    let deadline = Instant::now() + Duration::from_secs(2);
    while shared.dispatched_seq.load(Ordering::Relaxed) == before {
        assert!(Instant::now() < deadline, "event never dispatched within 2 s");
        std::thread::yield_now();
    }
}

/// Pin the retro-capture clock to an exact tick for the NEXT event only, so a
/// test can play a melody with real rhythm without sleeping through it.
fn at_tick(host: &Arc<Mutex<StudioHost>>, ticks: u64) {
    host.lock().unwrap().performance_set_now_ticks(ticks);
}

fn snap(host: &Arc<Mutex<StudioHost>>) -> Value {
    host.lock().unwrap().snapshot(None)
}

fn performance(host: &Arc<Mutex<StudioHost>>) -> Value {
    snap(host)["performance"].clone()
}

fn keep(host: &Arc<Mutex<StudioHost>>) -> Result<Value, agent_surface::StudioError> {
    let mut h = host.lock().unwrap();
    dispatch_tool(&mut h, agent(), "studio_performance_keep", json!({}))
}

/// One `u64` field of a snapshot object, accepting either spelling and
/// PANICKING when neither is present.
fn ticks(v: &Value, camel: &str, snake: &str) -> u64 {
    v.get(camel)
        .or_else(|| v.get(snake))
        .and_then(Value::as_u64)
        .unwrap_or_else(|| panic!("neither {camel} nor {snake} is present in {v}"))
}

/// Every note in the project, as `(pitch, absoluteStartTicks, lengthTicks)`.
fn landed_notes(host: &Arc<Mutex<StudioHost>>) -> Vec<(u64, u64, u64)> {
    let s = snap(host);
    let mut out = Vec::new();
    for track in s["project"]["tracks"].as_array().into_iter().flatten() {
        for clip in track["clips"].as_array().into_iter().flatten() {
            let clip_start = ticks(&clip, "startTicks", "start_ticks");
            for note in clip["notes"].as_array().into_iter().flatten() {
                out.push((
                    note["pitch"].as_u64().unwrap(),
                    clip_start + note["startTicks"].as_u64().unwrap(),
                    note["lengthTicks"].as_u64().unwrap(),
                ));
            }
        }
    }
    out.sort();
    out
}

fn instrument_tracks(host: &Arc<Mutex<StudioHost>>) -> usize {
    snap(host)["project"]["tracks"]
        .as_array()
        .map(|ts| {
            ts.iter()
                .filter(|t| !t["devices"].as_array().map(Vec::is_empty).unwrap_or(true))
                .count()
        })
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// 1. Delete the "Studio -> Instrument" click
// ---------------------------------------------------------------------------

#[test]
fn one_key_press_on_an_empty_project_makes_it_playable() {
    // The app already SEES the key (Settings > MIDI shows a live monitor of
    // exactly these events). It just had nowhere to send it and went quiet.
    let host = empty_project_with_pump();
    assert_eq!(
        snap(&host)["project"]["trackCount"],
        json!(0),
        "precondition: nothing in the project"
    );

    play(&host, note_on(60));

    assert_eq!(
        instrument_tracks(&host),
        1,
        "the first key press must produce an instrument to play"
    );
    let s = snap(&host);
    let track = &s["project"]["tracks"][0];
    assert_eq!(
        track["devices"][0]["kind"],
        json!("synth"),
        "the created track must actually carry an instrument: {track}"
    );
}

#[test]
fn creating_that_instrument_is_exactly_one_undo_step() {
    // Auto-creation is the one journaled thing on the play-a-note path. If it
    // landed as two steps, Cmd-Z would leave a headless track behind.
    let host = empty_project_with_pump();
    let before = snap(&host)["project"]["undoDepth"].as_u64().unwrap();

    play(&host, note_on(60));
    play(&host, note_off(60));

    let after = snap(&host)["project"]["undoDepth"].as_u64().unwrap();
    assert_eq!(after, before + 1, "one key press, one undo step");

    assert!(host.lock().unwrap().undo(agent()).unwrap());
    assert_eq!(
        instrument_tracks(&host),
        0,
        "one undo must remove the whole track, device included"
    );
}

#[test]
fn a_second_key_press_does_not_add_a_second_instrument() {
    let host = empty_project_with_pump();
    for pitch in [60, 62, 64, 67, 72] {
        play(&host, note_on(pitch));
        play(&host, note_off(pitch));
    }
    assert_eq!(
        instrument_tracks(&host),
        1,
        "the project gains ONE instrument however long the performance is"
    );
}

// ---------------------------------------------------------------------------
// 1b. The rule is STATE-BASED, and the state it reads is the PROJECT
// ---------------------------------------------------------------------------
//
// Observed on the shipped 3.4.4 by a human: Remove Instrument worked, and from
// that moment the keyboard was silent with nothing in the GUI to bring it back.
// The doc on `ensure_instrument_target` said the creation "happens at most once
// per project", which — had anyone implemented what it described — is exactly
// the rule that produces that silence. These tests pin the reading the code
// actually has, so nobody can ever make the sentence true.

/// Strip the instrument off `track` through the bus, the way the track header's
/// Remove Instrument does.
fn remove_instrument(host: &Arc<Mutex<StudioHost>>, track: &str, device: &str) {
    let mut h = host.lock().unwrap();
    h.submit(
        agent(),
        "device.remove",
        json!({"trackId": track, "deviceId": device}),
    )
    .expect("device.remove");
}

fn first_instrument(host: &Arc<Mutex<StudioHost>>) -> (String, String) {
    let s = snap(host);
    let track = s["project"]["tracks"]
        .as_array()
        .and_then(|ts| ts.iter().find(|t| !t["devices"].as_array().map(Vec::is_empty).unwrap_or(true)))
        .unwrap_or_else(|| panic!("no instrument track: {s}"))
        .clone();
    (
        track["id"].as_str().unwrap().to_string(),
        track["devices"][0]["id"].as_str().unwrap().to_string(),
    )
}

#[test]
fn removing_the_instrument_and_playing_again_makes_a_sound_again() {
    // AARON'S EXACT FLOW. Play a note (an instrument appears), right-click the
    // track header and Remove Instrument, then play. Under a "once per project"
    // latch this is silence for the rest of the project's life, with no
    // affordance in the GUI to undo it. Under the state-based rule the project
    // is playable again because the project genuinely has no instrument.
    let host = empty_project_with_pump();
    play(&host, note_on(60));
    play(&host, note_off(60));
    let (track, device) = first_instrument(&host);

    remove_instrument(&host, &track, &device);
    assert_eq!(
        instrument_tracks(&host),
        0,
        "precondition: the project now has no instrument at all"
    );

    play(&host, note_on(64));

    assert_eq!(
        instrument_tracks(&host),
        1,
        "a note after Remove Instrument must produce something to play, not silence"
    );
    assert_eq!(
        performance(&host)["sounding"],
        json!([64]),
        "and the note must actually be sounding on it"
    );
}

#[test]
fn the_condition_is_the_project_state_not_a_visit_counter() {
    // The same thing said as a property: three remove/play cycles, three
    // recoveries. A counter latch survives the test above if it allows two.
    let host = empty_project_with_pump();
    for round in 0..3 {
        play(&host, note_on(60 + round));
        play(&host, note_off(60 + round));
        assert_eq!(
            instrument_tracks(&host),
            1,
            "round {round}: playing gives you an instrument"
        );
        let (track, device) = first_instrument(&host);
        remove_instrument(&host, &track, &device);
        assert_eq!(instrument_tracks(&host), 0, "round {round}: removed");
    }
    play(&host, note_on(72));
    assert_eq!(
        instrument_tracks(&host),
        1,
        "the rule reads the project every time, not a counter"
    );
}

#[test]
fn a_recovered_instrument_is_still_exactly_one_undo_step() {
    // The recovery is a mutation, so it obeys the same rule as the first one:
    // one gesture, one undo unit. Two steps would leave a headless track.
    let host = empty_project_with_pump();
    play(&host, note_on(60));
    play(&host, note_off(60));
    let (track, device) = first_instrument(&host);
    remove_instrument(&host, &track, &device);

    let before = snap(&host)["project"]["undoDepth"].as_u64().unwrap();
    play(&host, note_on(64));
    play(&host, note_off(64));
    let after = snap(&host)["project"]["undoDepth"].as_u64().unwrap();
    assert_eq!(after, before + 1, "the recovery is ONE undo step");

    assert!(host.lock().unwrap().undo(agent()).unwrap());
    assert_eq!(
        instrument_tracks(&host),
        0,
        "one undo takes the whole recovery back, device included"
    );
}

// ---------------------------------------------------------------------------
// 1c. The auto-create rule must not FIGHT the undo of an auto-create
// ---------------------------------------------------------------------------
//
// The rule's one failure mode: the user presses Cmd-Z to take back the track a
// played note created, and the note-ons still queued behind their fingers
// rebuild it immediately. The chosen answer is a HELD-KEY hold-off: while the
// keys that were down at the moment of the undo are still down, nothing is
// re-created; the next fresh press creates again. A session-long disarm was
// rejected — "you undid this once so the keyboard is dead now" is the same
// defect wearing a different hat.

#[test]
fn undoing_an_auto_create_while_keys_are_held_does_not_rebuild_it() {
    let host = empty_project_with_pump();
    play(&host, note_on(60)); // creates, and 60 stays DOWN
    assert_eq!(instrument_tracks(&host), 1);
    assert_eq!(performance(&host)["sounding"], json!([60]), "precondition: a key is down");

    assert!(host.lock().unwrap().undo(agent()).unwrap());
    assert_eq!(instrument_tracks(&host), 0, "the undo took the track back");

    // The rest of the chord, arriving under fingers that never left the keys.
    play(&host, note_on(64));
    play(&host, note_on(67));
    assert_eq!(
        instrument_tracks(&host),
        0,
        "notes queued behind a held chord must not rebuild what the user just undid"
    );
    assert_eq!(
        snap(&host)["project"]["undoDepth"],
        json!(0),
        "and nothing was journaled while held off"
    );
}

#[test]
fn lifting_the_keys_re_arms_auto_create() {
    // The hold-off is a hold-off, NOT a disarm. Permanent silence after one
    // Cmd-Z is the bug this whole path exists to kill.
    let host = empty_project_with_pump();
    play(&host, note_on(60));
    assert!(host.lock().unwrap().undo(agent()).unwrap());
    play(&host, note_on(64));
    assert_eq!(instrument_tracks(&host), 0, "precondition: held off");

    // Fingers up. Note-offs never create anything, so this is still 0 tracks.
    play(&host, note_off(60));
    play(&host, note_off(64));
    assert_eq!(
        instrument_tracks(&host),
        0,
        "a key-up must never create, hold-off or not"
    );

    // A FRESH press: the user is asking to hear something again.
    play(&host, note_on(67));
    assert_eq!(
        instrument_tracks(&host),
        1,
        "the next fresh press plays again — the hold-off does not outlive the hands"
    );
    assert_eq!(performance(&host)["sounding"], json!([67]));
}

#[test]
fn an_undo_with_no_keys_down_does_not_hold_anything_off() {
    // The overwhelmingly common shape: play something, take your hands off,
    // Cmd-Z, play again. There is nothing in flight, so there is nothing to
    // protect the user from and the next note must just work.
    let host = empty_project_with_pump();
    play(&host, note_on(60));
    play(&host, note_off(60));
    assert!(host.lock().unwrap().undo(agent()).unwrap());
    assert_eq!(instrument_tracks(&host), 0);

    play(&host, note_on(64));
    assert_eq!(
        instrument_tracks(&host),
        1,
        "hands were off the keys: the next note plays immediately"
    );
}

#[test]
fn redo_brings_the_instrument_back_without_creating_a_second_one() {
    let host = empty_project_with_pump();
    play(&host, note_on(60));
    let (track, _) = first_instrument(&host);
    assert!(host.lock().unwrap().undo(agent()).unwrap());
    assert!(host.lock().unwrap().redo(agent()).unwrap());

    play(&host, note_on(64));
    assert_eq!(
        instrument_tracks(&host),
        1,
        "redo restored the instrument, so nothing new is created"
    );
    assert_eq!(
        snap(&host)["project"]["tracks"][0]["id"].as_str(),
        Some(track.as_str()),
        "and it is the SAME track, not a replacement"
    );
}

#[test]
fn an_on_screen_key_held_off_by_an_undo_reports_why_instead_of_lying() {
    // The UI path. `studio_note_preview` never claims success it did not have:
    // there is no `ok` field, only `audible` + a reason a person can act on.
    let host = empty_project_with_pump();
    play(&host, note_on(60));
    assert!(host.lock().unwrap().undo(agent()).unwrap());

    let out = preview(&host, json!({"pitch": 64}));
    assert_eq!(out["audible"], json!(false), "{out}");
    let reason = out["reason"].as_str().unwrap_or_default();
    assert!(
        reason.contains("undid") && reason.contains("add an instrument"),
        "the reason must name what happened AND the way out: {out}"
    );
    assert_eq!(instrument_tracks(&host), 0);
}

#[test]
fn a_stray_key_up_never_conjures_a_track() {
    // Cables get plugged in mid-note, and a sustain-pedal release or a panic
    // note-off must not create a track out of nothing.
    let host = empty_project_with_pump();
    play(&host, note_off(60));
    assert_eq!(instrument_tracks(&host), 0);
    assert_eq!(snap(&host)["project"]["undoDepth"], json!(0));
}

#[test]
fn an_unmapped_keyboard_plays() {
    // `UNMAPPED_PORT` matches no bundled map. Before this lane, `pump::scan`
    // refused to even CONNECT such a port, so an ordinary USB keyboard was
    // completely inert: no events, an empty MIDI monitor, and nothing to
    // diagnose. A map decides what a controller's KNOBS do; it must not decide
    // whether its KEYS exist.
    let host = empty_project_with_pump();
    let has_map = {
        let h = host.lock().unwrap();
        let shared = h.midi_shared();
        let reg = shared.registry.read().unwrap();
        reg.resolve(UNMAPPED_PORT).is_some()
    };
    assert!(!has_map, "precondition: this port matches no map");

    play(&host, note_on(60));
    assert_eq!(
        performance(&host)["sounding"],
        json!([60]),
        "an unmapped keyboard's keys must reach the instrument"
    );
}

// ---------------------------------------------------------------------------
// 2. Delete the "Play -> Stop" ritual — WITHOUT weakening the safety it hid behind
// ---------------------------------------------------------------------------

#[test]
fn playing_never_starts_the_transport() {
    // The old sequence made a person run the transport to hear a key. Playing an
    // instrument is not a transport operation and must not become one — starting
    // playback under someone's fingers would move the play head and drag the
    // whole arrangement past them.
    let host = empty_project_with_pump();
    play(&host, note_on(60));
    play(&host, note_off(60));
    assert_eq!(
        snap(&host)["transport"]["playing"],
        json!(false),
        "a key press must not roll the transport"
    );
    assert_eq!(
        snap(&host)["transport"]["positionTicks"],
        json!(0),
        "a key press must not move the play head"
    );
}

#[test]
fn a_silent_host_still_opens_no_device_however_much_is_played() {
    // The automated-blast safety, restated at the hardware end. This host never
    // called `set_audible_output`, exactly like every `cargo test`, every
    // headless CLI run, and every MCP-only server.
    let host = empty_project_with_pump();
    for pitch in [60, 62, 64, 67, 72, 76] {
        play(&host, note_on(pitch));
        play(&host, note_off(pitch));
    }
    assert!(
        !host.lock().unwrap().is_live(),
        "a MIDI cable MUST NOT open the output device on a host that never opted into audio"
    );
}

#[test]
fn the_live_mic_monitoring_refusal_is_untouched() {
    // Playing an instrument (a synth voice, one human gesture, no input
    // transducer, no loop to close) and monitoring a microphone (mic -> speakers
    // -> mic, a closed acoustic loop that builds on its own) are different
    // hazards. This lane separated them; it did not weaken the second.
    assert!(
        !render::recording::monitoring_allowed(true),
        "live mic monitoring must still be refused even when explicitly requested"
    );
}

// ---------------------------------------------------------------------------
// 3. Make HEARING and KEEPING different, visible, and neither of them "arm"
// ---------------------------------------------------------------------------

#[test]
fn a_held_key_reads_as_sounding_and_a_released_one_does_not() {
    // This is what lets the UI light a key from the same fact the audio came
    // from, instead of from a parallel guess that can disagree with it.
    let host = empty_project_with_pump();

    play(&host, note_on(60));
    play(&host, note_on(64));
    assert_eq!(
        performance(&host)["sounding"],
        json!([60, 64]),
        "both held keys are sounding"
    );

    play(&host, note_off(60));
    assert_eq!(
        performance(&host)["sounding"],
        json!([64]),
        "a released key stops being sounding"
    );

    play(&host, note_off(64));
    assert_eq!(performance(&host)["sounding"], json!([]));
}

#[test]
fn what_was_played_is_keepable_without_arming_or_recording_anything() {
    // THE finding: "I heard the keyboard, didn't see any notes or anything."
    // Nothing was armed. Nothing was recording. It is kept anyway.
    let host = empty_project_with_pump();

    // Three quarter notes, each an eighth long, at 120 BPM.
    for (i, pitch) in [60u8, 64, 67].iter().enumerate() {
        let on = (i as u64) * PPQ;
        at_tick(&host, on);
        play(&host, note_on(*pitch));
        at_tick(&host, on + PPQ / 2);
        play(&host, note_off(*pitch));
    }

    assert_eq!(
        performance(&host)["keepableNotes"],
        json!(3),
        "the app must be able to say how much is keepable: {}",
        performance(&host)
    );
    assert!(
        landed_notes(&host).is_empty(),
        "nothing is committed to the project until the human asks"
    );

    let out = keep(&host).expect("studio_performance_keep");
    assert_eq!(out["kept"], json!(true), "{out}");
    assert_eq!(out["noteCount"], json!(3), "{out}");

    assert_eq!(
        landed_notes(&host),
        vec![
            (60, 0, PPQ / 2),
            (64, PPQ, PPQ / 2),
            (67, 2 * PPQ, PPQ / 2),
        ],
        "the kept notes must be the notes that were played, at the rhythm they were played"
    );
}

#[test]
fn keeping_a_performance_is_one_undo_step() {
    let host = empty_project_with_pump();
    for (i, pitch) in [60u8, 62, 64, 65].iter().enumerate() {
        at_tick(&host, (i as u64) * PPQ);
        play(&host, note_on(*pitch));
        at_tick(&host, (i as u64) * PPQ + 240);
        play(&host, note_off(*pitch));
    }
    let before = snap(&host)["project"]["undoDepth"].as_u64().unwrap();
    keep(&host).expect("keep");
    let after = snap(&host)["project"]["undoDepth"].as_u64().unwrap();
    assert_eq!(after, before + 1, "a whole take is ONE undo step");

    assert!(host.lock().unwrap().undo(agent()).unwrap());
    assert!(
        landed_notes(&host).is_empty(),
        "one undo must take the whole take back"
    );
}

#[test]
fn a_key_still_down_when_keep_is_pressed_is_kept_too() {
    // A person hits Keep with a chord ringing. Dropping the held notes would
    // silently keep something different from what they heard.
    let host = empty_project_with_pump();
    at_tick(&host, 0);
    play(&host, note_on(60));
    at_tick(&host, 960);
    play(&host, note_on(67)); // still down
    at_tick(&host, 1440);
    play(&host, note_off(60));

    let out = keep(&host).expect("keep");
    assert_eq!(out["kept"], json!(true), "{out}");
    let pitches: Vec<u64> = landed_notes(&host).iter().map(|n| n.0).collect();
    assert_eq!(pitches, vec![60, 67], "the held note is kept, not dropped");
}

#[test]
fn keeping_nothing_says_so_instead_of_landing_an_empty_clip() {
    let host = empty_project_with_pump();
    let out = keep(&host).expect("keep");
    assert_eq!(out["kept"], json!(false), "{out}");
    assert!(
        out["reason"].as_str().unwrap().contains("nothing has been played"),
        "{out}"
    );
    assert!(landed_notes(&host).is_empty());
}

#[test]
fn a_kept_performance_cannot_be_kept_twice() {
    let host = empty_project_with_pump();
    at_tick(&host, 0);
    play(&host, note_on(60));
    at_tick(&host, 480);
    play(&host, note_off(60));

    assert_eq!(keep(&host).expect("keep")["kept"], json!(true));
    let after_first = landed_notes(&host);
    assert_eq!(after_first.len(), 1);

    let second = keep(&host).expect("keep");
    assert_eq!(second["kept"], json!(false), "{second}");
    assert_eq!(
        landed_notes(&host),
        after_first,
        "a second Keep must not duplicate the take"
    );
}

#[test]
fn the_retro_buffer_is_bounded_by_a_window_and_a_note_cap() {
    // An always-on capture with no bound is a leak. The window is in BEATS so it
    // is musically meaningful at any tempo.
    let host = empty_project_with_pump();
    // 128 beats is the window; play well past it and check the old end fell off.
    for i in 0..400u64 {
        at_tick(&host, i * (PPQ / 2));
        play(&host, note_on(60 + (i % 12) as u8));
        at_tick(&host, i * (PPQ / 2) + 100);
        play(&host, note_off(60 + (i % 12) as u8));
    }
    let keepable = performance(&host)["keepableNotes"].as_u64().unwrap();
    assert!(keepable > 0, "the recent past is still keepable");
    assert!(
        keepable < 400,
        "the buffer must not grow without bound: kept {keepable} of 400"
    );
    let start = performance(&host)["startTicks"].as_u64().unwrap();
    assert!(
        start > 0,
        "the oldest notes must have rolled off the front of the window"
    );
}

// ---------------------------------------------------------------------------
// 4. The retro buffer and a real armed take must never both land the same notes
// ---------------------------------------------------------------------------

#[test]
fn keep_refuses_while_an_armed_take_is_recording() {
    let host = empty_project_with_pump();
    play(&host, note_on(60));
    play(&host, note_off(60));
    let track = snap(&host)["project"]["tracks"][0]["id"]
        .as_str()
        .unwrap()
        .to_string();

    {
        let mut h = host.lock().unwrap();
        h.submit(agent(), "track.arm", json!({"trackId": track, "armed": true}))
            .expect("track.arm");
        h.submit(agent(), "record.start", json!({"trackId": track}))
            .expect("record.start");
    }

    let err = keep(&host);
    assert!(
        err.is_err(),
        "Keep must refuse rather than quietly land something other than the take"
    );
}

#[test]
fn an_armed_take_and_the_retro_buffer_never_land_the_same_notes_twice() {
    let host = empty_project_with_pump();
    play(&host, note_on(60));
    play(&host, note_off(60));
    let track = snap(&host)["project"]["tracks"][0]["id"]
        .as_str()
        .unwrap()
        .to_string();

    {
        let mut h = host.lock().unwrap();
        h.submit(agent(), "track.arm", json!({"trackId": track, "armed": true}))
            .expect("track.arm");
        h.submit(agent(), "record.start", json!({"trackId": track}))
            .expect("record.start");
        h.midi_record_set_now_ticks(0);
    }
    play(&host, note_on(72));
    host.lock().unwrap().midi_record_set_now_ticks(480);
    play(&host, note_off(72));
    {
        let mut h = host.lock().unwrap();
        h.submit(agent(), "record.stop", json!({})).expect("record.stop");
    }

    let pitches: Vec<u64> = landed_notes(&host).iter().map(|n| n.0).collect();
    assert_eq!(pitches, vec![72], "the take lands exactly once");

    // And the buffer that was dropped at record.start has nothing stale to
    // re-land afterwards.
    let out = keep(&host).expect("keep");
    assert_eq!(
        out["kept"],
        json!(false),
        "the retro buffer must not re-land a take that record.stop already landed: {out}"
    );
    let pitches_after: Vec<u64> = landed_notes(&host).iter().map(|n| n.0).collect();
    assert_eq!(pitches_after, vec![72]);
}

#[test]
fn arming_a_take_discards_the_retro_buffer_that_preceded_it() {
    // MUTATION-FOUND GAP. The first version of this file asserted only that a
    // landed take is not re-landed by Keep — and that survived deleting the
    // `record.start` clear entirely, because `performance_note`'s runtime guard
    // clears the buffer again on the next note. The two are NOT equivalent, and
    // this is the case that separates them: a take that is CANCELLED never plays
    // another note, so nothing else ever clears the buffer.
    //
    // Without the clear at record.start, hitting Keep after a cancelled take
    // would land whatever the player happened to be noodling BEFORE they armed —
    // material they had already moved on from — and present it as the take.
    let host = empty_project_with_pump();
    at_tick(&host, 0);
    play(&host, note_on(60));
    at_tick(&host, 480);
    play(&host, note_off(60));
    assert_eq!(
        performance(&host)["keepableNotes"],
        json!(1),
        "precondition: something is in the buffer before arming"
    );

    let track = snap(&host)["project"]["tracks"][0]["id"]
        .as_str()
        .unwrap()
        .to_string();
    {
        let mut h = host.lock().unwrap();
        h.submit(agent(), "track.arm", json!({"trackId": track, "armed": true}))
            .expect("track.arm");
        h.submit(agent(), "record.start", json!({"trackId": track}))
            .expect("record.start");
        h.submit(agent(), "record.cancel", json!({})).expect("record.cancel");
    }

    let out = keep(&host).expect("keep");
    assert_eq!(
        out["kept"],
        json!(false),
        "arming must discard the pre-take buffer, so a cancelled take keeps nothing: {out}"
    );
    assert!(landed_notes(&host).is_empty());
}

// ---------------------------------------------------------------------------
// 5. Playing is still feedback: it does not edit anything by itself
// ---------------------------------------------------------------------------

#[test]
fn playing_journals_nothing_except_the_one_track_creation() {
    // Hearing a pitch is feedback. If every key press pushed an undo step,
    // Cmd-Z would start undoing keypresses instead of the user's work.
    let host = empty_project_with_pump();
    play(&host, note_on(60)); // this one creates the track
    let seq_after_create = host.lock().unwrap().seq();
    let undo_after_create = snap(&host)["project"]["undoDepth"].clone();

    play(&host, note_off(60));
    for pitch in [62, 64, 65, 67, 69, 71, 72] {
        play(&host, note_on(pitch));
        play(&host, note_off(pitch));
    }

    assert_eq!(
        host.lock().unwrap().seq(),
        seq_after_create,
        "playing must not bump the journal seq"
    );
    assert_eq!(
        snap(&host)["project"]["undoDepth"],
        undo_after_create,
        "playing must not push an undo step"
    );
}

// ---------------------------------------------------------------------------
// 6. The UI path: "play this pitch" with no track named
// ---------------------------------------------------------------------------
//
// The on-screen keyboard and the piano-roll gutter cannot name a track on an
// empty project — there isn't one. `studio_note_preview` therefore takes an
// OPTIONAL trackId and resolves it the same way a MIDI key does, so both
// surfaces reach the same instrument by the same rule.

fn preview(host: &Arc<Mutex<StudioHost>>, params: Value) -> Value {
    let mut h = host.lock().unwrap();
    dispatch_tool(&mut h, agent(), "studio_note_preview", params).expect("studio_note_preview")
}

#[test]
fn an_on_screen_key_with_no_track_named_reaches_the_instrument() {
    let host = empty_project_with_pump();
    let out = preview(&host, json!({"pitch": 60, "velocity": 96}));
    assert_eq!(
        instrument_tracks(&host),
        1,
        "an on-screen key on an empty project must produce something to play: {out}"
    );
    assert_eq!(
        out["trackId"].as_str(),
        snap(&host)["project"]["tracks"][0]["id"].as_str(),
        "the report must name the track it actually played: {out}"
    );
}

#[test]
fn an_on_screen_key_and_a_midi_key_land_in_the_same_buffer() {
    // One note path. If clicking a key and pressing a key were kept separately,
    // a performance played with both hands — one on the hardware, one on the
    // screen — would be split in half by Keep.
    let host = empty_project_with_pump();
    at_tick(&host, 0);
    play(&host, note_on(60));
    at_tick(&host, 240);
    play(&host, note_off(60));

    // A clicked key: a one-shot, because a click has no key-up.
    host.lock().unwrap().performance_set_now_ticks(480);
    let out = preview(&host, json!({"pitch": 67, "holdMs": 250}));
    assert_eq!(out["gate"], json!("oneShot"), "{out}");

    assert_eq!(
        performance(&host)["keepableNotes"],
        json!(2),
        "both surfaces feed one buffer: {}",
        performance(&host)
    );
    keep(&host).expect("keep");
    let pitches: Vec<u64> = landed_notes(&host).iter().map(|n| n.0).collect();
    assert_eq!(pitches, vec![60, 67], "Keep takes both");
}

#[test]
fn a_note_off_with_no_track_named_never_creates_one() {
    let host = empty_project_with_pump();
    let out = preview(&host, json!({"pitch": 60, "gate": "off"}));
    assert_eq!(out["audible"], json!(false), "{out}");
    assert_eq!(instrument_tracks(&host), 0);
    assert_eq!(snap(&host)["project"]["undoDepth"], json!(0));
}

// ---------------------------------------------------------------------------
// 8. THE APP SAYS SO
//
// Auto-creation is right and it stays. What was wrong is that it happened in
// silence: a row appeared in the arrangement and nothing in the product ever
// explained where it came from. Two wrong public claims were made about this
// behaviour before anybody read the journal — and the journal had the answer
// the whole time, because `ensure_instrument_target` stamps every command it
// submits with `Actor::user("performance")` and nothing else in the tree
// submits under that name.
//
// So the snapshot now CARRIES that answer, per track, derived from the chain
// rather than from a flag beside it. These tests are the contract the UI's
// sentence is drawn from: it must be there when the app made the track, and
// absent when the user did — the second half being the one that catches a
// message wired to fire always.
// ---------------------------------------------------------------------------

/// `origin` for the first track in the project, or `None` when the key is
/// absent — which is the ordinary case and must stay distinguishable from a
/// present-but-empty value.
fn first_track_origin(host: &Arc<Mutex<StudioHost>>) -> Option<String> {
    snap(host)["project"]["tracks"][0]
        .get("origin")
        .and_then(Value::as_str)
        .map(str::to_string)
}

/// A track made the ordinary way — the "+ Track" gesture, an agent, anything
/// that is not a played key.
fn add_a_track_by_hand(host: &Arc<Mutex<StudioHost>>, id: &str) {
    host.lock()
        .unwrap()
        .submit(agent(), "track.add", json!({"trackId": id, "name": "Made by hand", "index": 0}))
        .expect("track.add");
}

#[test]
fn the_snapshot_says_a_played_track_was_made_by_playing() {
    let host = empty_project_with_pump();
    play(&host, note_on(60));

    assert_eq!(
        first_track_origin(&host).as_deref(),
        Some("played"),
        "the track a key press created must say so in the snapshot: {}",
        snap(&host)["project"]["tracks"][0]
    );
}

#[test]
fn a_track_the_user_made_carries_no_origin_at_all() {
    // THE assertion that catches a message wired to fire unconditionally. A
    // track someone asked for needs no explanation, and offering one is the
    // same defect as offering none — the app describing something that did not
    // happen.
    let host = empty_project_with_pump();
    add_a_track_by_hand(&host, "t_by_hand");

    assert_eq!(
        first_track_origin(&host),
        None,
        "a hand-made track must carry no origin: {}",
        snap(&host)["project"]["tracks"][0]
    );
}

#[test]
fn only_the_played_track_is_marked_when_both_kinds_are_present() {
    // Not "the project contains a played track" — WHICH track. A classifier
    // that marked every track would pass a one-track test.
    let host = empty_project_with_pump();
    add_a_track_by_hand(&host, "t_by_hand");
    play(&host, note_on(60));

    let s = snap(&host);
    let tracks = s["project"]["tracks"].as_array().expect("tracks");
    assert_eq!(tracks.len(), 2, "precondition: one of each: {s}");

    let marked: Vec<&str> = tracks
        .iter()
        .filter(|t| t.get("origin").and_then(Value::as_str) == Some("played"))
        .filter_map(|t| t["id"].as_str())
        .collect();
    assert_eq!(marked.len(), 1, "exactly one track was played into: {tracks:?}");
    assert_ne!(marked[0], "t_by_hand", "the hand-made track must not be the marked one");
    // And the marked one is the one that actually carries the instrument the
    // key press created.
    let marked_track = tracks.iter().find(|t| t["id"].as_str() == Some(marked[0])).unwrap();
    assert_eq!(marked_track["devices"][0]["kind"], json!("synth"), "{marked_track}");
}

#[test]
fn undo_takes_the_track_and_its_explanation_away_together() {
    // The whole reason this is a view over the journal and not a field: there
    // is no second thing to clean up. One undo step removes the track, and the
    // sentence the UI drew from it goes with the row.
    let host = empty_project_with_pump();
    play(&host, note_on(60));
    play(&host, note_off(60));
    assert_eq!(first_track_origin(&host).as_deref(), Some("played"));

    assert!(host.lock().unwrap().undo(agent()).unwrap());
    assert_eq!(
        snap(&host)["project"]["tracks"].as_array().map(Vec::len),
        Some(0),
        "one undo must take the whole thing back"
    );
}

#[test]
fn redo_brings_the_track_back_still_saying_where_it_came_from() {
    // Redo re-applies `track.add` with the same id, so the original entry still
    // names it. A track that came back is still the track that was made when
    // you played, and the header must not go quiet about it.
    let host = empty_project_with_pump();
    play(&host, note_on(60));
    play(&host, note_off(60));
    assert!(host.lock().unwrap().undo(agent()).unwrap());
    assert!(host.lock().unwrap().redo(agent()).unwrap());

    assert_eq!(
        first_track_origin(&host).as_deref(),
        Some("played"),
        "the explanation must survive undo/redo: {}",
        snap(&host)["project"]["tracks"][0]
    );
}
