//! M4b - table-driven validation of the SHIPPED bundled MIDI maps.
//!
//! `midi.rs` (M2/M5) drives whole controls through `StudioHost` but hand-codes a
//! handful of note numbers, so most of the 21 shipped bindings are never proven
//! and the JSON assets can drift from the engine's reading of them. This suite
//! closes that: it loads the real `sx-kc211.json` and `generic-controller.json`
//! via `MapRegistry::bundled()`, runs `validate_map` on each (bundled() only
//! PARSES - it never validates, so a malformed shipped map would ship silently),
//! and then a table with one row per binding asserts a synthetic matching event
//! resolves to exactly the command / builtin expansion / sterling item that
//! binding declares. The table is a two-way lock: every shipped binding must
//! have a row, and every row must name a real binding, so adding, removing, or
//! renumbering a control in the JSON fails this test until the intent is
//! restated here.
//!
//! Pure resolver (spec 11 tier 1): no CoreMIDI, no device, no audio, no
//! `MAJIKS_TEST_AUDIBLE`. It calls `resolve(event, ctx, &bindings)` directly.

use std::collections::HashMap;

use serde_json::{json, Value};

use agent_surface::midi::event::MidiEvent;
use agent_surface::midi::map::{match_specificity, validate_map, ControlMatch, Curve, ValueMap};
use agent_surface::midi::registry::MapRegistry;
use agent_surface::midi::resolve::{binding_is_continuous, map_value, resolve, DispatchCtx, Prepared};

/// The canonical context every table row resolves against. It is chosen so that
/// each stateful builtin has ONE deterministic expansion: not playing (toggle ->
/// play), not recording with an armed track (record.toggle -> record.start), and
/// metronome off (toggle -> enabled:true). Three tracks at 0 dB let the gain
/// nudges resolve `$track:0..2`.
fn ctx() -> DispatchCtx {
    DispatchCtx {
        playing: false,
        recording: false,
        metronome: false,
        armed_track_id: Some("trk-a".into()),
        track_ids: vec!["trk-a".into(), "trk-b".into(), "trk-c".into()],
        track_gains_db: vec![0.0, 0.0, 0.0],
    }
}

/// Build the synthetic wire event a binding's `match` clause listens for, at a
/// given scalar (velocity for notes, value for CCs, bend amount for pitch bend).
fn event_for(control: &ControlMatch, raw: u8) -> MidiEvent {
    match *control {
        ControlMatch::NoteOn { channel, number } => MidiEvent::NoteOn { note: number, velocity: raw, channel },
        ControlMatch::NoteOff { channel, number } => MidiEvent::NoteOff { note: number, velocity: raw, channel },
        ControlMatch::ControlChange { channel, number } => MidiEvent::ControlChange { controller: number, value: raw, channel },
        ControlMatch::PitchBend { channel } => MidiEvent::PitchBend { value: ((raw as i16) << 7) - 8192, channel },
    }
}

/// What a binding is expected to dispatch. Commands assert exact equality;
/// Sterling triggers assert the kind, the binding id, and a keyword in the
/// instruction (the full instruction is tunable product copy, the intent is not).
enum Want {
    Command { name: &'static str, params: Value },
    Sterling { binding_id: &'static str, contains: &'static str },
}

/// (binding id, scalar to feed, expected outcome). The scalar is arbitrary for
/// buttons and matters only for `$value` faders, where it is fed at full scale so
/// the mapped output is the valueMap's declared max.
fn check_map(key: &str, rows: Vec<(&'static str, u8, Want)>) {
    let reg = MapRegistry::bundled();
    let loaded = reg
        .maps
        .get(key)
        .unwrap_or_else(|| panic!("bundled map '{key}' is missing from the registry"));
    assert!(loaded.error.is_none(), "bundled map '{key}' failed to load: {:?}", loaded.error);

    // The real validity gate: bundled() only deserializes, so an unknown builtin,
    // an unknown command target, a duplicate id, an out-of-range channel, or a
    // lifecycle target would parse fine and ship. validate_map catches all of it.
    validate_map(&loaded.map).unwrap_or_else(|e| panic!("bundled map '{key}' fails M0 validation: {e}"));

    // No two shipped bindings may share a control: matched_binding breaks a
    // specificity tie by file order, so a duplicate note/CC would leave the later
    // binding permanently unreachable (dead config that this table cannot see,
    // since its row would resolve the earlier binding). Rule it out explicitly.
    let mut controls = std::collections::HashSet::new();
    for b in &loaded.map.bindings {
        let c = serde_json::to_string(&b.control).unwrap();
        assert!(controls.insert(c.clone()), "map '{key}' binds two controls the same ({c}); the later one can never fire");
    }

    // A duplicate id in the table would be silently collapsed by the HashMap and
    // quietly weaken the two-way lock, so reject it while building.
    let mut table: HashMap<&'static str, (u8, Want)> = HashMap::new();
    for (id, raw, want) in rows {
        assert!(table.insert(id, (raw, want)).is_none(), "duplicate expectation row for '{id}' in the '{key}' table");
    }

    for b in &loaded.map.bindings {
        let (raw, want) = table.remove(b.id.as_str()).unwrap_or_else(|| {
            panic!("map '{key}' binding '{}' has no expectation row - add one so no shipped control is left unproven", b.id)
        });
        assert!(b.enabled, "map '{key}' binding '{}' is disabled; the table assumes shipped bindings are enabled", b.id);

        // Resolve against the WHOLE binding slice, so specificity picks the
        // intended binding (the distinct-control guard above rules out shadowing).
        let out = resolve(&event_for(&b.control, raw), &ctx(), &loaded.map.bindings);

        match want {
            Want::Command { name, params } => {
                let expected = vec![Prepared::Command { name: name.to_string(), params }];
                assert_eq!(out, expected, "map '{key}' binding '{}' did not dispatch the declared command", b.id);
            }
            Want::Sterling { binding_id, contains } => {
                assert_eq!(out.len(), 1, "map '{key}' binding '{}' produced {} items, want 1", b.id, out.len());
                match &out[0] {
                    Prepared::Sterling { instruction, binding_id: got } => {
                        assert_eq!(got.as_str(), binding_id, "map '{key}' binding '{}' sterling binding id", b.id);
                        assert!(
                            instruction.to_lowercase().contains(contains),
                            "map '{key}' binding '{}' instruction '{instruction}' should mention '{contains}'",
                            b.id
                        );
                    }
                    other => panic!("map '{key}' binding '{}' wanted a sterling trigger, resolved {other:?}", b.id),
                }
            }
        }
    }

    assert!(
        table.is_empty(),
        "map '{key}' has expectation rows for bindings that are not in the shipped file: {:?}",
        table.keys().collect::<Vec<_>>()
    );
}

#[test]
fn sx_kc211_every_binding_dispatches_the_declared_command() {
    // 16 keys on the SX-KC211: transport + edit builtins on C2..G2, three tracks
    // of +/-1 dB gain nudges, and two Sterling triggers on C4/D4. Every row is
    // driven through the resolver; none may be silently missing (see check_map).
    check_map(
        "sx-kc211",
        vec![
            ("transport-toggle", 100, Want::Command { name: "transport.play", params: json!({}) }),
            ("record-toggle", 100, Want::Command { name: "record.start", params: json!({ "trackId": "trk-a" }) }),
            ("transport-seek-start", 100, Want::Command { name: "transport.seek", params: json!({ "positionTicks": 0 }) }),
            ("metronome-toggle", 100, Want::Command { name: "transport.metronome", params: json!({ "enabled": true }) }),
            ("undo", 100, Want::Command { name: "undo", params: json!({}) }),
            ("redo", 100, Want::Command { name: "redo", params: json!({}) }),
            ("transport-loop-clear", 100, Want::Command { name: "transport.loop.clear", params: json!({}) }),
            ("transport-stop", 100, Want::Command { name: "transport.stop", params: json!({}) }),
            ("t1-gain-nudge-down", 100, Want::Command { name: "mix.gain", params: json!({ "trackId": "trk-a", "gainDb": -1.0 }) }),
            ("t1-gain-nudge-up", 100, Want::Command { name: "mix.gain", params: json!({ "trackId": "trk-a", "gainDb": 1.0 }) }),
            ("t2-gain-nudge-down", 100, Want::Command { name: "mix.gain", params: json!({ "trackId": "trk-b", "gainDb": -1.0 }) }),
            ("t2-gain-nudge-up", 100, Want::Command { name: "mix.gain", params: json!({ "trackId": "trk-b", "gainDb": 1.0 }) }),
            ("t3-gain-nudge-down", 100, Want::Command { name: "mix.gain", params: json!({ "trackId": "trk-c", "gainDb": -1.0 }) }),
            ("t3-gain-nudge-up", 100, Want::Command { name: "mix.gain", params: json!({ "trackId": "trk-c", "gainDb": 1.0 }) }),
            ("sterling-revise-tighten", 100, Want::Sterling { binding_id: "sterling-revise-tighten", contains: "tighten" }),
            ("sterling-add-layer", 100, Want::Sterling { binding_id: "sterling-add-layer", contains: "layer" }),
        ],
    );
}

#[test]
fn generic_controller_every_binding_dispatches_the_declared_command() {
    // The bare fallback map: three transport notes and two CC faders. The faders
    // are fed at 127, so the 0..127 -> -60..+12 valueMap yields exactly +12 dB.
    check_map(
        "generic-controller",
        vec![
            ("transport-toggle", 100, Want::Command { name: "transport.play", params: json!({}) }),
            ("transport-stop", 100, Want::Command { name: "transport.stop", params: json!({}) }),
            ("transport-play", 100, Want::Command { name: "transport.play", params: json!({}) }),
            ("master-gain", 127, Want::Command { name: "mix.master.gain", params: json!({ "gainDb": 12.0 }) }),
            ("track-1-gain", 127, Want::Command { name: "mix.gain", params: json!({ "trackId": "trk-a", "gainDb": 12.0 }) }),
        ],
    );
}

#[test]
fn value_map_curve_math_matches_the_spec() {
    // No valueMap -> the raw is normalized to 0..1 (spec 5.5 default).
    assert_eq!(map_value(None, 0.0), 0.0);
    assert_eq!(map_value(None, 127.0), 1.0);
    assert!((map_value(None, 63.5) - 0.5).abs() < 1e-12);

    // Linear, the shipped fader mapping 0..127 -> -60..+12 dB.
    let lin = ValueMap { input_min: 0.0, input_max: 127.0, output_min: -60.0, output_max: 12.0, curve: Curve::Linear };
    assert!((map_value(Some(&lin), 0.0) - (-60.0)).abs() < 1e-9);
    assert!((map_value(Some(&lin), 127.0) - 12.0).abs() < 1e-9);
    assert!((map_value(Some(&lin), 63.5) - (-24.0)).abs() < 1e-9, "midpoint -> (-60+12)/2");

    // Out-of-range raw clamps to the endpoints, never extrapolates.
    assert!((map_value(Some(&lin), -10.0) - (-60.0)).abs() < 1e-9);
    assert!((map_value(Some(&lin), 200.0) - 12.0).abs() < 1e-9);

    // Exponential: y = x^2 on the normalized input.
    let ex = ValueMap { input_min: 0.0, input_max: 127.0, output_min: 0.0, output_max: 1.0, curve: Curve::Exponential };
    assert!((map_value(Some(&ex), 0.0) - 0.0).abs() < 1e-9);
    assert!((map_value(Some(&ex), 127.0) - 1.0).abs() < 1e-9);
    assert!((map_value(Some(&ex), 63.5) - 0.25).abs() < 1e-9, "x=0.5 -> 0.25");

    // Logarithmic: y = ln(1 + 9x) / ln(10), concave so the midpoint sits high.
    let lg = ValueMap { input_min: 0.0, input_max: 127.0, output_min: 0.0, output_max: 1.0, curve: Curve::Logarithmic };
    assert!((map_value(Some(&lg), 0.0) - 0.0).abs() < 1e-9);
    assert!((map_value(Some(&lg), 127.0) - 1.0).abs() < 1e-9);
    // Pin the exact shipped curve at two interior points so the coefficient (9)
    // and base (ln 10) cannot drift silently: the endpoints above are
    // curve-invariant (every self-normalizing taper hits 0 and 1 at 0/127), so a
    // loose midpoint gate alone would accept a different logarithm.
    assert!((map_value(Some(&lg), 31.75) - (3.25_f64.ln() / 10.0_f64.ln())).abs() < 1e-12, "log x=0.25 -> ln(1+9*0.25)/ln(10)");
    assert!((map_value(Some(&lg), 63.5) - (5.5_f64.ln() / 10.0_f64.ln())).abs() < 1e-12, "log x=0.5 -> ln(1+9*0.5)/ln(10)");
    // And concave: the midpoint sits well above the linear 0.5.
    assert!(map_value(Some(&lg), 63.5) > 0.6, "log curve is concave");
}

#[test]
fn shipped_controls_split_faders_from_buttons() {
    // Spec 2.4 coalescing: a $value command is a fader (events coalesce to the
    // latest); everything else is a button (dispatches per press). Proven over
    // the real shipped bindings, not fabricated ones.
    let reg = MapRegistry::bundled();

    let gen = &reg.maps["generic-controller"].map;
    for id in ["master-gain", "track-1-gain"] {
        let b = gen.bindings.iter().find(|b| b.id == id).unwrap();
        assert!(binding_is_continuous(b), "'{id}' carries $value -> a coalescing fader");
    }
    for id in ["transport-toggle", "transport-stop", "transport-play"] {
        let b = gen.bindings.iter().find(|b| b.id == id).unwrap();
        assert!(!binding_is_continuous(b), "'{id}' is a discrete button");
    }

    // The SX-KC211 is keys only: every binding is a per-press button.
    let kc = &reg.maps["sx-kc211"].map;
    assert!(kc.bindings.iter().all(|b| !binding_is_continuous(b)), "the keyboard map has no continuous faders");
}

#[test]
fn device_name_patterns_auto_match_the_cable() {
    let reg = MapRegistry::bundled();

    // The SX-KC211 reaches the Mac as a generic "USB MIDI Interface" cable; the
    // "kc211" pattern also matches. Both auto-resolve to the keyboard map.
    assert_eq!(reg.resolve("USB MIDI Interface").map(|m| m.key.as_str()), Some("sx-kc211"));
    assert_eq!(reg.resolve("Some KC211 Keyboard").map(|m| m.key.as_str()), Some("sx-kc211"));

    // The generic map has empty namePatterns: it never auto-loads, so an
    // unrecognized controller matches NOTHING (the port shows "no map" until the
    // user pins one) rather than falling back to generic.
    assert_eq!(match_specificity(&reg.maps["generic-controller"].map, "any controller"), 0);
    assert!(reg.resolve("Roland A-88 MkII").is_none(), "an unrecognized cable auto-matches no map");

    // Longest matching pattern wins: "usb midi interface" (18) beats "kc211" (5).
    assert_eq!(
        match_specificity(&reg.maps["sx-kc211"].map, "usb midi interface"),
        "usb midi interface".len()
    );
}

#[test]
fn mix_gain_nudge_saturates_at_the_gain_limits() {
    // Spec 11 lists "gain clamp edges" as a tier-1 target. The per-binding table
    // above nudges from 0 dB (clamp is a no-op there), so exercise the ceiling and
    // floor here with the real shipped nudge bindings (note 50 = track 1 +1 dB,
    // note 48 = track 1 -1 dB).
    let reg = MapRegistry::bundled();
    let kc = &reg.maps["sx-kc211"].map;

    // Track 1 already at +11.5 dB, nudge +1 -> clamp to +12.0, not +12.5.
    let ceil = DispatchCtx { track_ids: vec!["trk-a".into()], track_gains_db: vec![11.5], ..Default::default() };
    let out = resolve(&MidiEvent::NoteOn { note: 50, velocity: 100, channel: 0 }, &ceil, &kc.bindings);
    assert_eq!(
        out,
        vec![Prepared::Command { name: "mix.gain".into(), params: json!({ "trackId": "trk-a", "gainDb": 12.0 }) }],
        "nudge up saturates at the +12 dB ceiling"
    );

    // Track 1 at -59.5 dB, nudge -1 -> clamp to -60.0, not -60.5.
    let floor = DispatchCtx { track_ids: vec!["trk-a".into()], track_gains_db: vec![-59.5], ..Default::default() };
    let out = resolve(&MidiEvent::NoteOn { note: 48, velocity: 100, channel: 0 }, &floor, &kc.bindings);
    assert_eq!(
        out,
        vec![Prepared::Command { name: "mix.gain".into(), params: json!({ "trackId": "trk-a", "gainDb": -60.0 }) }],
        "nudge down saturates at the -60 dB floor"
    );
}

#[test]
fn shipped_faders_declare_and_apply_the_documented_calibration() {
    // Feeding the faders at raw=127 (the table) pins only outputMax. Lock the rest
    // of the mapping here: the shipped valueMap must stay 0..127 -> -60..+12 dB
    // LINEAR, and it must be APPLIED at the far end (raw 0 -> the -60 dB floor). An
    // edit to outputMin, the curve, or the input range fails this immediately.
    let reg = MapRegistry::bundled();
    let gen = &reg.maps["generic-controller"].map;
    let want = ValueMap { input_min: 0.0, input_max: 127.0, output_min: -60.0, output_max: 12.0, curve: Curve::Linear };

    for id in ["master-gain", "track-1-gain"] {
        let b = gen.bindings.iter().find(|b| b.id == id).unwrap_or_else(|| panic!("fader '{id}' missing"));
        assert_eq!(b.value_map.as_ref(), Some(&want), "fader '{id}' must keep the documented -60..+12 dB linear valueMap");

        let out = resolve(&event_for(&b.control, 0), &ctx(), &gen.bindings);
        let Prepared::Command { params, .. } = &out[0] else { panic!("fader '{id}' did not resolve to a command") };
        assert_eq!(params["gainDb"], json!(-60.0), "fader '{id}' at raw 0 must map to the -60 dB floor");
    }
}

#[test]
fn stateful_builtins_flip_with_transport_state() {
    // The per-binding table resolves each builtin in ONE state, where its output is
    // byte-identical to a plain command (toggle-from-stopped == play). Prove the
    // shipped bindings are genuinely STATEFUL builtins - not plain commands that
    // happen to match - by resolving them in the opposite state.
    let reg = MapRegistry::bundled();
    let kc = &reg.maps["sx-kc211"].map;

    // transport.toggle while PLAYING -> transport.stop (not play).
    let playing = DispatchCtx { playing: true, ..Default::default() };
    let out = resolve(&MidiEvent::NoteOn { note: 36, velocity: 100, channel: 0 }, &playing, &kc.bindings);
    assert_eq!(out, vec![Prepared::Command { name: "transport.stop".into(), params: json!({}) }], "toggle while playing stops");

    // metronome.toggle while ON -> enabled:false.
    let metro = DispatchCtx { metronome: true, ..Default::default() };
    let out = resolve(&MidiEvent::NoteOn { note: 39, velocity: 100, channel: 0 }, &metro, &kc.bindings);
    assert_eq!(out, vec![Prepared::Command { name: "transport.metronome".into(), params: json!({ "enabled": false }) }], "metronome toggles off");

    // record.toggle while RECORDING -> record.stop (regardless of the armed track).
    let rec = DispatchCtx { recording: true, ..Default::default() };
    let out = resolve(&MidiEvent::NoteOn { note: 37, velocity: 100, channel: 0 }, &rec, &kc.bindings);
    assert_eq!(out, vec![Prepared::Command { name: "record.stop".into(), params: json!({}) }], "record toggle stops while recording");
}

#[test]
fn every_bundled_map_parses_and_validates() {
    // Future-proof the drift lock beyond the two maps the tables name explicitly:
    // any map added to registry::BUNDLED must load AND pass validate_map. bundled()
    // only deserializes, so without this a new bundled map could ship malformed.
    let reg = MapRegistry::bundled();
    assert!(reg.maps.len() >= 2, "the two shipped maps must both be present");
    for (key, lm) in &reg.maps {
        assert!(lm.error.is_none(), "bundled map '{key}' failed to load: {:?}", lm.error);
        validate_map(&lm.map).unwrap_or_else(|e| panic!("bundled map '{key}' fails M0 validation: {e}"));
    }
}
