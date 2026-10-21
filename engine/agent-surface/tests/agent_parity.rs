//! AGENT/HUMAN PARITY: the ten things a person does to make a record, driven
//! entirely through `dispatch_tool` — the SAME entry point the MCP server calls
//! (`mcp.rs::run_tool`) — and then READ BACK through the read tools.
//!
//! The product thesis is "usable by human and AI", and the journalled bus
//! delivers the write half by construction: one tool per catalog command means
//! an agent can never be missing a verb the UI has. The half that does NOT fall
//! out for free is the READ half. An agent that can submit `fx.param.set` and
//! cannot then see the parameter it set is flying blind, and no amount of
//! command coverage fixes that.
//!
//! So every case here is a PAIR: act, then observe. A step is only parity if
//! both halves hold. Where the observation is impossible the test says so by
//! name rather than asserting the write alone and calling the step green — that
//! is exactly the "the app knows and does not say" failure this file exists to
//! prevent from regressing.

use serde_json::{json, Value};

use agent_surface::{dispatch_tool, StudioHost};
use timeline_core::Actor;

fn agent() -> Actor {
    Actor {
        kind: timeline_core::envelope::ActorKind::Agent,
        name: "parity".into(),
    }
}

/// Call a tool the way the MCP server does, and fail with the tool name when it
/// refuses — a bare `unwrap()` here prints only the message, and half the point
/// of this file is that an agent must be able to tell WHICH call failed.
fn tool(host: &mut StudioHost, name: &str, args: Value) -> Value {
    dispatch_tool(host, agent(), name, args)
        .unwrap_or_else(|e| panic!("{name} refused: [{}] {}", e.code(), e.message()))
}

fn snapshot(host: &mut StudioHost) -> Value {
    tool(host, "studio_snapshot", json!({}))
}

/// The project half of a snapshot (`studio_snapshot` nests the model under
/// `project`).
fn project(host: &mut StudioHost) -> Value {
    snapshot(host)["project"].clone()
}

fn track<'a>(project: &'a Value, id: &str) -> &'a Value {
    project["tracks"]
        .as_array()
        .expect("snapshot.project.tracks is an array")
        .iter()
        .find(|t| t["id"] == json!(id))
        .unwrap_or_else(|| panic!("no track {id} in the snapshot"))
}

/// A host with one audio fixture already imported, so the steps that need real
/// audio (import, waveform, bounce) have some.
fn fixture_wav() -> std::path::PathBuf {
    let dir = render::fixtures::repo_fixtures_dir();
    render::fixtures::ensure(&dir).expect("fixtures");
    dir.join("click_120bpm_48k_stereo.wav")
}

// ---------------------------------------------------------------------------
// 1. Create/open a project; set tempo, time signature, key.
// ---------------------------------------------------------------------------

#[test]
fn step1_project_tempo_timesig_key_are_writable_and_readable() {
    let mut host = StudioHost::in_memory();

    tool(&mut host, "studio_project_set_tempo", json!({ "bpm": 96 }));
    tool(
        &mut host,
        "studio_project_set_time_sig",
        json!({ "numerator": 3, "denominator": 4 }),
    );
    tool(
        &mut host,
        "studio_project_set_key",
        json!({ "key": "A minor" }),
    );

    let p = project(&mut host);
    // Tempo is carried BOTH as the exact rational the engine computes with and
    // as a float; an agent that reads only `bpm_wire` would miss a tempo map
    // with more than one segment, so the list is what we assert.
    assert_eq!(p["tempoMap"][0]["bpm"], json!(96.0), "tempo not readable");
    assert_eq!(p["timeSignature"]["numerator"], json!(3));
    assert_eq!(p["timeSignature"]["denominator"], json!(4));
    assert_eq!(p["key"], json!("A minor"));
    // The grid origin and the tick resolution ride along, so an agent can turn
    // bars into ticks without hardcoding PPQ.
    assert_eq!(p["ppq"], json!(timeline_core::PPQ));
    assert!(p["phaseAnchorTicks"].is_number());
}

// ---------------------------------------------------------------------------
// 2. Add a track; add an instrument; choose its sound.
// ---------------------------------------------------------------------------

#[test]
fn step2_track_instrument_and_its_sound_are_writable_and_readable() {
    let mut host = StudioHost::in_memory();
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Keys" }),
    );
    tool(
        &mut host,
        "studio_device_add",
        json!({ "trackId": "t1", "deviceId": "d1", "kind": "synth" }),
    );
    // The RAW parameter half of "choose its sound".
    tool(
        &mut host,
        "studio_device_param_set",
        json!({ "trackId": "t1", "deviceId": "d1", "key": "cutoff", "value": 1200 }),
    );

    let p = project(&mut host);
    let t = track(&p, "t1");
    assert_eq!(t["name"], json!("Keys"));
    assert_eq!(t["devices"][0]["id"], json!("d1"));
    assert_eq!(t["devices"][0]["kind"], json!("synth"));
    assert_eq!(
        t["devices"][0]["params"]["cutoff"],
        json!(1200),
        "a device parameter an agent set is not visible in the snapshot"
    );
}

/// The PRESET half of "choose its sound", which is what a person actually does:
/// they click "Soft Pad", not eight numeric fields.
///
/// A preset IS a set of `device.param.set` commands (`StudioInstrumentPreset::
/// commands`), so the bus can express it perfectly — the question is whether an
/// agent can find out that presets exist and what they contain. That vocabulary
/// used to live only in the Swift table and the contracts file, i.e. nowhere an
/// MCP client can see, so an agent could set `cutoff` to a number but could not
/// ask for the sound by name the way every human user does.
#[test]
fn step2_an_agent_can_discover_the_presets_a_person_clicks() {
    let mut host = StudioHost::in_memory();
    let caps = tool(&mut host, "studio_capabilities", json!({}));

    let presets = caps["instrumentPresets"]
        .as_array()
        .expect("capabilities must carry the instrument preset table");
    assert!(
        presets.len() >= 5,
        "the preset table looks empty: {presets:?}"
    );
    let pad = presets
        .iter()
        .find(|p| p["id"] == json!("softPad"))
        .expect("softPad is one of the shipped presets");
    assert!(
        pad["blurb"].as_str().is_some_and(|s| !s.is_empty()),
        "a preset without its plain-language blurb tells an agent less than the UI tells a person"
    );

    // And the discovered values must actually APPLY: read the preset, replay it
    // as the device.param.set commands it is, and see the sound land. This is
    // the half that proves the read tool is not merely decorative.
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Keys" }),
    );
    tool(
        &mut host,
        "studio_device_add",
        json!({ "trackId": "t1", "deviceId": "d1", "kind": "synth" }),
    );
    let params = pad["params"].as_object().expect("preset params object");
    for (key, value) in params {
        tool(
            &mut host,
            "studio_device_param_set",
            json!({ "trackId": "t1", "deviceId": "d1", "key": key, "value": value }),
        );
    }
    let p = project(&mut host);
    let stored = track(&p, "t1")["devices"][0]["params"]
        .as_object()
        .expect("device params")
        .clone();
    for (key, value) in params {
        let got = stored
            .get(key)
            .unwrap_or_else(|| panic!("preset key {key} did not land on the device"));
        assert_eq!(
            got.as_f64(),
            value.as_f64(),
            "preset key {key} landed as {got} instead of {value}"
        );
    }
}

/// The parameter VOCABULARIES. `device.param.set` and `fx.param.set` both
/// document their key as "from DEVICE_PARAM_KEYS" / "from FX_PARAM_KEYS" and
/// then reject anything outside those lists — but the lists are Rust constants,
/// so an MCP client reading the schema is told a name it cannot resolve. Every
/// key the tool advertises must be reachable and must be accepted.
#[test]
fn step2_the_parameter_vocabularies_are_discoverable_and_every_key_is_accepted() {
    let mut host = StudioHost::in_memory();
    let caps = tool(&mut host, "studio_capabilities", json!({}));

    let device_keys: Vec<String> = caps["deviceParamKeys"]
        .as_array()
        .expect("deviceParamKeys")
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    assert_eq!(
        device_keys,
        timeline_core::model::DEVICE_PARAM_KEYS,
        "the advertised device vocabulary drifted from the one apply.rs enforces"
    );
    let fx_keys: Vec<String> = caps["fxParamKeys"]
        .as_array()
        .expect("fxParamKeys")
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    assert_eq!(
        fx_keys,
        timeline_core::model::FX_PARAM_KEYS,
        "the advertised fx vocabulary drifted from the one apply.rs enforces"
    );

    // Advertised is not the same as accepted. Drive every key.
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "T" }),
    );
    tool(
        &mut host,
        "studio_device_add",
        json!({ "trackId": "t1", "deviceId": "d1", "kind": "synth" }),
    );
    tool(
        &mut host,
        "studio_fx_add",
        json!({ "target": "track.t1", "fxId": "f1", "kind": "compressor" }),
    );
    for key in &device_keys {
        tool(
            &mut host,
            "studio_device_param_set",
            json!({ "trackId": "t1", "deviceId": "d1", "key": key, "value": 1 }),
        );
    }
    for key in &fx_keys {
        tool(
            &mut host,
            "studio_fx_param_set",
            json!({ "target": "track.t1", "fxId": "f1", "key": key, "value": 1 }),
        );
    }
    let p = project(&mut host);
    let t = track(&p, "t1");
    assert_eq!(
        t["devices"][0]["params"].as_object().unwrap().len(),
        device_keys.len()
    );
    assert_eq!(t["fx"][0]["params"].as_object().unwrap().len(), fx_keys.len());
}

/// The CLOSED enums an agent has to pick from. These are already in the tool
/// schemas as `enum`s, so this asserts the capability card agrees with them
/// rather than inventing a second, driftable source of truth.
#[test]
fn step2_the_closed_kind_enums_match_the_tool_schemas() {
    let mut host = StudioHost::in_memory();
    let caps = tool(&mut host, "studio_capabilities", json!({}));
    let schema_enum = |tool_name: &str, prop: &str| -> Vec<Value> {
        agent_surface::registry::tool_by_name(tool_name)
            .unwrap_or_else(|| panic!("no tool {tool_name}"))
            .input_schema["properties"][prop]["enum"]
            .as_array()
            .unwrap_or_else(|| panic!("{tool_name}.{prop} has no enum"))
            .clone()
    };
    assert_eq!(
        caps["deviceKinds"].as_array().unwrap(),
        &schema_enum("studio_device_add", "kind")
    );
    assert_eq!(
        caps["fxKinds"].as_array().unwrap(),
        &schema_enum("studio_fx_add", "kind")
    );
}

// ---------------------------------------------------------------------------
// 3. Place a MIDI clip; add notes. (Editing them is the note-editing lane's.)
// ---------------------------------------------------------------------------

#[test]
fn step3_midi_clip_and_notes_are_writable_and_readable() {
    let mut host = StudioHost::in_memory();
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Keys" }),
    );
    tool(
        &mut host,
        "studio_clip_place_midi",
        json!({ "clipId": "c1", "trackId": "t1", "startTicks": 0, "lengthTicks": 3840 }),
    );
    tool(
        &mut host,
        "studio_note_add",
        json!({
            "clipId": "c1",
            "notes": [
                { "noteId": "n1", "startTicks": 0, "lengthTicks": 480, "pitch": 60, "velocity": 100 },
                { "noteId": "n2", "startTicks": 480, "lengthTicks": 480, "pitch": 64, "velocity": 90 }
            ]
        }),
    );

    let p = project(&mut host);
    let clip = &track(&p, "t1")["clips"][0];
    assert_eq!(clip["kind"], json!("midi"));
    let notes = clip["notes"].as_array().expect("notes are in the snapshot");
    assert_eq!(notes.len(), 2, "notes an agent added are not readable back");
    assert_eq!(notes[0]["pitch"], json!(60));
    // Velocity must round-trip as an INTEGER: it is journaled as a Num whose
    // integer/float shape the blake3 chain depends on (2 != 2.0).
    assert!(
        notes[0]["velocity"].is_i64(),
        "velocity came back as {} — the wire shape changed",
        notes[0]["velocity"]
    );
}

// ---------------------------------------------------------------------------
// 4. Import audio.
// ---------------------------------------------------------------------------

#[test]
fn step4_imported_audio_is_readable_as_a_clip_and_as_peaks() {
    let tmp = tempfile::tempdir().unwrap();
    let mut host = StudioHost::create_at(tmp.path().join("P.mstudio"), "P").unwrap();
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Audio" }),
    );
    let out = tool(
        &mut host,
        "studio_import_audio",
        json!({
            "sourcePath": fixture_wav().display().to_string(),
            "targetTrackId": "t1",
            "clipId": "c1",
            "startTicks": 0
        }),
    );
    // The import result itself is a read surface: hash, length, measured BPM.
    assert_eq!(out["clipId"], json!("c1"));
    assert!(out["assetHash"].as_str().is_some_and(|h| h.len() == 64));
    assert!(out["lengthTicks"].as_u64().unwrap_or(0) > 0);

    let p = project(&mut host);
    let clip = &track(&p, "t1")["clips"][0];
    assert_eq!(clip["id"], json!("c1"));
    // `origin` is the manifest's OWN classifier, so the preview and the
    // exported artifact cannot disagree.
    assert_eq!(clip["origin"], json!("imported"));

    // And the audio itself is inspectable without shipping raw samples.
    let wave = tool(&mut host, "studio_waveform", json!({ "clipId": "c1" }));
    let peaks = wave["peaks"].as_array().expect("peaks");
    assert!(!peaks.is_empty(), "an imported clip renders no peak tiles");
    assert!(
        peaks.iter().any(|v| v.as_f64().unwrap_or(0.0) > 0.01),
        "every peak tile is silence — the clip read back empty"
    );
}

/// `import.audio` declares `separate` ("run htdemucs on import and place stems
/// as separate tracks") and `conform` ("time-stretch to the project tempo") and
/// implements NEITHER: `import_audio_params` reads neither key, so the call
/// returns ok and lands one ordinary clip. A person notices — they watch one
/// clip appear where they asked for four stem tracks. An agent gets `ok: true`
/// and a clip id, and nothing tells it otherwise.
///
/// Neither flag can be refused: `apply.rs` runs on replay, and narrowing what a
/// journaled command accepts would break reopening any project that ever passed
/// one. So the contract is that the RESULT names them. If either is ever
/// actually implemented, this test is the thing that says so out loud.
#[test]
fn step4_import_says_which_of_its_declared_flags_it_ignored() {
    let tmp = tempfile::tempdir().unwrap();
    let mut host = StudioHost::create_at(tmp.path().join("P.mstudio"), "P").unwrap();
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Audio" }),
    );
    let out = tool(
        &mut host,
        "studio_import_audio",
        json!({
            "sourcePath": fixture_wav().display().to_string(),
            "targetTrackId": "t1",
            "clipId": "c1",
            "separate": true,
            "conform": true
        }),
    );
    let ignored = out["ignoredParams"]
        .as_array()
        .expect("import.audio accepted separate/conform and said nothing about ignoring them");
    assert!(ignored.contains(&json!("separate")));
    assert!(ignored.contains(&json!("conform")));
    assert!(out["ignoredParamsNote"]
        .as_str()
        .is_some_and(|s| s.contains("studio_open_in_studio")));

    // The observable reality the note is describing: ONE track, ONE clip,
    // unstretched. If separation ever lands, this is what changes.
    let p = project(&mut host);
    assert_eq!(p["trackCount"], json!(1));
    assert_eq!(p["clipCount"], json!(1));

    // And a plain import says nothing, so the advisory cannot become noise the
    // caller learns to skip.
    let plain = tool(
        &mut host,
        "studio_import_audio",
        json!({
            "sourcePath": fixture_wav().display().to_string(),
            "targetTrackId": "t1",
            "clipId": "c2",
            "startTicks": 30_720
        }),
    );
    assert!(plain.get("ignoredParams").is_none());
}

/// `gen.song` carries the same defect one field over, and it is WORSE placed:
/// `insertAtTicks` is REQUIRED by the tool schema, so every agent must supply a
/// timeline position, and nothing reads it. `apply.rs` matches
/// `Cmd::GenSong { track_id, .. }`; `landing.rs` writes the field and then
/// computes its own lead-in. Sweeping every catalog parameter against the code
/// that destructures it is how this one surfaced — reading `gen.song` alone
/// would not have shown it, because the value is written in one place and read
/// in none.
#[test]
fn step4_gen_song_says_it_ignored_the_position_it_required() {
    let mut host = StudioHost::in_memory();
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Song" }),
    );
    let out = tool(
        &mut host,
        "studio_gen_song",
        json!({
            "requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            "trackId": "t1",
            "insertAtTicks": 15_360,
            "request": { "caption": "lofi beat" }
        }),
    );
    let ignored = out["ignoredParams"]
        .as_array()
        .expect("gen.song required insertAtTicks, read it nowhere, and said nothing");
    assert!(ignored.contains(&json!("insertAtTicks")));
    assert!(out["ignoredParamsNote"]
        .as_str()
        .is_some_and(|s| s.contains("take.promote")));

    // Zero is "no opinion" and must stay quiet, so the advisory cannot become
    // noise on every generation the way a blanket note would.
    let quiet = tool(
        &mut host,
        "studio_gen_song",
        json!({
            "requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAW",
            "trackId": "t1",
            "insertAtTicks": 0,
            "request": { "caption": "lofi beat" }
        }),
    );
    assert!(quiet.get("ignoredParams").is_none());
}

/// The same two flags must not read as ordinary working options in the SCHEMA
/// either — that is where an agent decides to pass one, before any result
/// exists to correct it.
#[test]
fn step4_the_import_tool_schema_does_not_promise_the_flags_it_ignores() {
    let schema = agent_surface::registry::tool_by_name("studio_import_audio")
        .expect("studio_import_audio")
        .input_schema;
    for key in ["separate", "conform"] {
        let desc = schema["properties"][key]["description"]
            .as_str()
            .unwrap_or_else(|| panic!("{key} has no description"));
        assert!(
            desc.contains("NOT IMPLEMENTED"),
            "the schema still advertises {key} as working: {desc}"
        );
    }
}

// ---------------------------------------------------------------------------
// 5. Effects on a track / bus / master; parameters; automation.
// ---------------------------------------------------------------------------

#[test]
fn step5_fx_chains_params_and_automation_are_writable_and_readable() {
    let mut host = StudioHost::in_memory();
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Keys" }),
    );
    tool(
        &mut host,
        "studio_fx_add",
        json!({ "target": "track.t1", "fxId": "f1", "kind": "compressor" }),
    );
    tool(
        &mut host,
        "studio_fx_add",
        json!({ "target": "master", "fxId": "fm", "kind": "limiter" }),
    );
    tool(
        &mut host,
        "studio_fx_param_set",
        json!({ "target": "track.t1", "fxId": "f1", "key": "threshold", "value": -18 }),
    );
    tool(
        &mut host,
        "studio_autopoint_add",
        json!({ "trackId": "t1", "target": "track.fx.f1.threshold", "pointId": "p1", "positionTicks": 0, "value": -18 }),
    );
    tool(
        &mut host,
        "studio_autopoint_add",
        json!({ "trackId": "t1", "target": "track.fx.f1.threshold", "pointId": "p2", "positionTicks": 3840, "value": -30 }),
    );

    let p = project(&mut host);
    let t = track(&p, "t1");
    assert_eq!(t["fx"][0]["id"], json!("f1"));
    assert_eq!(t["fx"][0]["kind"], json!("compressor"));
    assert_eq!(t["fx"][0]["params"]["threshold"], json!(-18));
    // The MASTER chain is a separate host and must be visible too.
    assert_eq!(
        p["master"]["fx"][0]["kind"],
        json!("limiter"),
        "a master-bus effect is invisible to an agent"
    );
    let lane = t["automation"]["lanes"]["track.fx.f1.threshold"]
        .as_array()
        .expect("the fx automation lane is in the snapshot");
    assert_eq!(lane.len(), 2);
}

// ---------------------------------------------------------------------------
// 6. Routing: buses, edges, sends, taps, a sidechain.
// ---------------------------------------------------------------------------

#[test]
fn step6_the_routing_graph_is_writable_and_readable() {
    let mut host = StudioHost::in_memory();
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Keys" }),
    );
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t2", "name": "Kick" }),
    );
    tool(
        &mut host,
        "studio_route_node_add",
        json!({ "nodeId": "verb", "kind": "bus", "name": "Reverb Bus" }),
    );
    tool(
        &mut host,
        "studio_route_connect",
        json!({ "edgeId": "e1", "from": "track.t1", "to": "bus.verb", "level": 0.4, "tap": "post" }),
    );
    tool(
        &mut host,
        "studio_route_connect",
        json!({ "edgeId": "e2", "from": "bus.verb", "to": "master", "level": 1, "tap": "post" }),
    );
    tool(
        &mut host,
        "studio_mix_send",
        json!({ "trackId": "t2", "bus": "a", "amount": 0.3 }),
    );
    tool(
        &mut host,
        "studio_fx_add",
        json!({ "target": "track.t1", "fxId": "f1", "kind": "compressor" }),
    );
    tool(
        &mut host,
        "studio_fx_sidechain_set",
        json!({ "target": "track.t1", "fxId": "f1", "source": "track.t2" }),
    );

    let p = project(&mut host);
    let routing = &p["routing"];
    assert!(
        !routing.is_null(),
        "the routing graph is absent from the snapshot after four routing commands"
    );
    let nodes = routing["nodes"].as_array().expect("routing.nodes");
    assert_eq!(nodes.len(), 1);
    assert_eq!(nodes[0]["id"], json!("verb"));
    let edges = routing["edges"].as_array().expect("routing.edges");
    assert_eq!(edges.len(), 2, "an agent cannot see the edges it connected");
    // The TAP is the part a person sets with a two-state control and an agent
    // has to be able to read back, because pre and post sound different.
    assert!(edges.iter().all(|e| e["tap"].is_string()));
    assert_eq!(track(&p, "t2")["sends"]["a"], json!(0.3));
    assert_eq!(
        track(&p, "t1")["fx"][0]["sidechain"],
        json!("track.t2"),
        "the sidechain key source is not readable"
    );
}

// ---------------------------------------------------------------------------
// 7. Mixer: gain, pan, mute, solo — and the LEVELS those produce.
// ---------------------------------------------------------------------------

#[test]
fn step7_mixer_state_is_writable_and_readable() {
    let mut host = StudioHost::in_memory();
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Keys" }),
    );
    tool(
        &mut host,
        "studio_mix_gain",
        json!({ "trackId": "t1", "gainDb": -3 }),
    );
    tool(
        &mut host,
        "studio_mix_pan",
        json!({ "trackId": "t1", "pan": -0.25 }),
    );
    tool(
        &mut host,
        "studio_track_mute",
        json!({ "trackId": "t1", "muted": true }),
    );
    tool(
        &mut host,
        "studio_track_solo",
        json!({ "trackId": "t1", "soloed": true }),
    );
    tool(
        &mut host,
        "studio_mix_master_gain",
        json!({ "gainDb": -1 }),
    );

    let p = project(&mut host);
    let t = track(&p, "t1");
    assert_eq!(t["gain"], json!(-3));
    assert_eq!(t["pan"], json!(-0.25));
    assert_eq!(t["mute"], json!(true));
    assert_eq!(t["solo"], json!(true));
    assert_eq!(p["master"]["gain_db"], json!(-1));
}

/// The mixer's OTHER half: what the faders are doing to the signal. The host
/// has computed per-track/bus/master meters since I1 and the Swift app reads
/// them over `ffi_studio_meters` — so this is a capability the app HAS and only
/// the human half could see. Offline the levels are an honest silence floor
/// rather than a fiction, and `live:false` says which one you are looking at.
#[test]
fn step7_meters_are_readable_by_an_agent_and_say_whether_they_are_live() {
    let mut host = StudioHost::in_memory();
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Keys" }),
    );
    let m = tool(&mut host, "studio_meters", json!({}));
    assert_eq!(
        m["live"],
        json!(false),
        "an offline host must not claim live meters"
    );
    let tracks = m["tracks"].as_array().expect("per-track meters");
    assert_eq!(tracks.len(), 1);
    assert_eq!(tracks[0]["trackId"], json!("t1"));
    // The floor is a NUMBER, not null: "silence" and "no answer" must not look
    // the same to a caller deciding whether a track is passing signal.
    assert!(tracks[0]["peakDb"].as_f64().is_some());
    assert!(m["master"]["peakDb"].as_f64().is_some());
    // No input is open, so there is no input meter to report — and that reads
    // as null rather than as a fabricated zero.
    assert!(m["input"].is_null());
}

/// The meters must carry SIGNAL, not just a shape.
///
/// A meter tool that always answers the silence floor would pass every
/// structural assertion above and be useless — this app has already shipped a
/// meter driven by `abs(sin(t))`, so "there is a number in the field" is not
/// evidence. Two channels are fed deliberately different amplitudes and the
/// tool has to tell them apart, which is exactly the job it exists for: knowing
/// which mic is on which input before a take.
///
/// The samples arrive through `feed_virtual`, which pushes frames into the SAME
/// input ring the CoreAudio callback pushes into and therefore drives the same
/// level accumulators; only the source of the samples is synthetic, so no
/// device is opened and nothing is audible.
#[test]
fn step9_input_meters_carry_real_per_channel_signal() {
    let mut host = StudioHost::in_memory();
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Vocal" }),
    );
    tool(
        &mut host,
        "studio_track_arm",
        json!({ "trackId": "t1", "armed": true }),
    );
    host.test_begin_virtual_capture("t1", 2, 48_000).unwrap();

    // Channel 0 loud, channel 1 twenty dB quieter.
    let mut frames = Vec::new();
    for i in 0..4_800 {
        let phase = (i as f32) * 0.05;
        frames.push(0.8 * phase.sin());
        frames.push(0.08 * phase.sin());
    }
    let pushed = host.test_feed_virtual_capture(&frames);
    assert!(pushed > 0, "the virtual input accepted no frames");

    let m = tool(&mut host, "studio_meters", json!({}));
    let input = &m["input"];
    assert!(
        !input.is_null(),
        "an open input reports no input meter at all"
    );
    assert_eq!(input["channelCount"], json!(2));
    let ch = input["channels"].as_array().expect("per-channel meters");
    assert_eq!(ch.len(), 2);
    let c0 = ch[0]["peakDb"].as_f64().unwrap();
    let c1 = ch[1]["peakDb"].as_f64().unwrap();
    assert!(
        c0 > -6.0,
        "channel 0 was fed near full scale and metered {c0} dB"
    );
    assert!(
        c1 < c0 - 15.0,
        "the two channels were fed 20 dB apart and metered {c0} / {c1} dB — the meter is not \
         following the signal"
    );
    // `capturedFrames` counts what the drain thread has moved into the take
    // accumulator, not what was pushed, so it is deliberately NOT asserted
    // here: it races the feed and a flaky gate is worse than no gate. The peak
    // comparison above is what proves the meter is following the signal.
    assert_eq!(input["sampleRate"], json!(48_000));
    assert!(input["capturedFrames"].is_number());
    assert!(input["dropped"].is_number());
}

// ---------------------------------------------------------------------------
// 8. Transport: play, seek, loop, metronome.
// ---------------------------------------------------------------------------

#[test]
fn step8_transport_is_writable_and_readable() {
    let mut host = StudioHost::in_memory();
    // Transport commands answer with the whole transport view, so an agent
    // learns the result from the same call that caused it.
    let seeked = tool(
        &mut host,
        "studio_transport_seek",
        json!({ "positionTicks": 1920 }),
    );
    assert_eq!(seeked["transport"]["positionTicks"], json!(1920));
    tool(
        &mut host,
        "studio_transport_loop_set",
        json!({ "startTicks": 0, "endTicks": 7680 }),
    );
    tool(
        &mut host,
        "studio_transport_metronome",
        json!({ "enabled": true }),
    );
    let played = tool(&mut host, "studio_transport_play", json!({}));
    assert_eq!(played["transport"]["playing"], json!(true));

    // ...and it is on the snapshot too, so a poller does not have to have been
    // the one who moved it.
    let s = snapshot(&mut host);
    assert_eq!(s["transport"]["positionTicks"], json!(1920));
    assert_eq!(s["transport"]["loop"]["endTicks"], json!(7680));
    assert_eq!(s["transport"]["metronomeEnabled"], json!(true));
    assert_eq!(s["transport"]["playing"], json!(true));
}

// ---------------------------------------------------------------------------
// 9. Record: arm, choose an input channel, see the input.
// ---------------------------------------------------------------------------

#[test]
fn step9_arming_and_input_channel_choice_are_writable_and_readable() {
    let mut host = StudioHost::in_memory();
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Vocal" }),
    );
    tool(
        &mut host,
        "studio_track_set_input_channel",
        json!({ "trackId": "t1", "channel": 1 }),
    );
    tool(
        &mut host,
        "studio_track_arm",
        json!({ "trackId": "t1", "armed": true }),
    );

    let s = snapshot(&mut host);
    let t = track(&s["project"], "t1");
    assert_eq!(t["armed"], json!(true));
    assert_eq!(
        t["inputChannel"],
        json!(1),
        "the channel an agent chose is not readable back"
    );
    // Arming must NOT have opened the mic (that is `record.inputListen`'s job),
    // and the snapshot has to say which state it is in.
    assert_eq!(s["transport"]["inputOpen"], json!(false));
    assert!(s["audioInputDevices"].is_array());
}

// ---------------------------------------------------------------------------
// 10. Bounce/export, and read back what happened.
// ---------------------------------------------------------------------------

#[test]
fn step10_export_and_its_provenance_are_readable() {
    let tmp = tempfile::tempdir().unwrap();
    let mut host = StudioHost::create_at(tmp.path().join("P.mstudio"), "P").unwrap();
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Audio" }),
    );
    tool(
        &mut host,
        "studio_import_audio",
        json!({
            "sourcePath": fixture_wav().display().to_string(),
            "targetTrackId": "t1",
            "clipId": "c1",
            "startTicks": 0
        }),
    );

    let wav = tmp.path().join("master.wav");
    let out = tool(
        &mut host,
        "studio_export_master",
        json!({ "outputPath": wav.display().to_string(), "format": "wav", "confirm": true }),
    );
    assert!(wav.exists(), "export.master reported ok and wrote no file");
    assert!(out["frames"].as_u64().unwrap_or(0) > 0);
    // The disclosure split rides the export result, so an agent does not have
    // to open the artifact to know what went into it.
    assert_eq!(out["provenance"]["importedClips"], json!(1));

    // Lineage: which journal entries produced this clip's audio.
    let lineage = tool(&mut host, "studio_lineage", json!({ "clipId": "c1" }));
    let chain = lineage["chain"].as_array().expect("lineage chain");
    assert!(
        chain.iter().any(|e| e["name"] == json!("import.audio")),
        "the import that created this clip is missing from its lineage"
    );

    // The journal itself, hash-chained, is a read tool.
    let page = tool(&mut host, "studio_journal", json!({ "limit": 500 }));
    assert!(page["entries"].as_array().is_some_and(|e| !e.is_empty()));

    // And the full provenance manifest WITHOUT having to write a file first.
    // `export.manifest` is Manage tier because it writes outside the project;
    // reading what it would contain is not a destructive act and must not
    // require pretending it is one.
    let manifest = tool(&mut host, "studio_manifest", json!({}));
    assert_eq!(manifest["composition"]["byClipCount"]["imported"], json!(1));
    assert!(
        manifest["hashChain"]["tipHash"]
            .as_str()
            .is_some_and(|h| !h.is_empty()),
        "the manifest read back with no hash-chain head"
    );
    // And it must be the SAME content export.manifest writes, or the preview
    // and the artifact are two different claims about one project.
    let file = tmp.path().join("m.json");
    tool(
        &mut host,
        "studio_export_manifest",
        json!({ "outputPath": file.display().to_string(), "confirm": true }),
    );
    let written: Value =
        serde_json::from_str(&std::fs::read_to_string(&file).expect("manifest file")).unwrap();
    assert_eq!(
        written, manifest,
        "studio_manifest and export.manifest disagree about the same project"
    );
}

// ---------------------------------------------------------------------------
// Cross-cutting: undo, and the errors an agent has to reason about.
// ---------------------------------------------------------------------------

/// One gesture is one undo step, and the depth is on the snapshot so an agent
/// can tell whether there is anything to undo before asking.
#[test]
fn undo_is_readable_before_and_after() {
    let mut host = StudioHost::in_memory();
    assert_eq!(project(&mut host)["undoDepth"], json!(0));
    tool(
        &mut host,
        "studio_track_add",
        json!({ "trackId": "t1", "name": "Keys" }),
    );
    assert_eq!(project(&mut host)["undoDepth"], json!(1));
    let undone = tool(&mut host, "studio_undo", json!({}));
    assert_eq!(undone["undone"], json!(true));
    assert_eq!(project(&mut host)["trackCount"], json!(0));
    assert_eq!(project(&mut host)["redoDepth"], json!(1));
}

/// A refusal must carry a machine code, not just prose, and must name the thing
/// that was wrong. An agent branching on `err.contains("track")` is a bug.
#[test]
fn refusals_carry_a_machine_code_an_agent_can_branch_on() {
    let mut host = StudioHost::in_memory();

    let unknown_track = dispatch_tool(
        &mut host,
        agent(),
        "studio_mix_gain",
        json!({ "trackId": "nope", "gainDb": 0 }),
    )
    .expect_err("mixing a track that does not exist must fail");
    assert_eq!(unknown_track.code(), "unknown_track");
    assert!(unknown_track.message().contains("nope"));

    let bad_schema = dispatch_tool(
        &mut host,
        agent(),
        "studio_mix_gain",
        json!({ "trackId": "t1", "gainDb": 99 }),
    )
    .expect_err("a gain outside the catalog range must fail");
    assert_eq!(bad_schema.code(), "invalid_argument");

    let unconfirmed = dispatch_tool(
        &mut host,
        agent(),
        "studio_track_remove",
        json!({ "trackId": "t1" }),
    )
    .expect_err("a Manage tool without confirm must fail");
    assert_eq!(unconfirmed.code(), "invalid_argument");

    let unknown_tool = dispatch_tool(&mut host, agent(), "studio_nope", json!({}))
        .expect_err("an unknown tool must fail");
    assert_eq!(unknown_tool.code(), "invalid_argument");
    assert!(unknown_tool.message().contains("studio_nope"));
}

/// Every READ tool must document every parameter it takes.
///
/// The read half is where an agent is most alone: a write tool that is misused
/// refuses and says why, but a read tool called with a misunderstood argument
/// answers successfully with the wrong data, and nothing anywhere says so.
/// `sinceSeq`, `afterId`, `zoom`, `startBin` and `maxBins` are all cursors or
/// resolutions whose meaning is not recoverable from a name and a numeric
/// range, and all five shipped with a type and nothing else.
///
/// Scoped to the read tools deliberately: 210 of the 393 parameters across the
/// whole surface carry no description, but the command tools' schemas are the
/// CATALOG's, taken verbatim, and documenting those is a contract edit rather
/// than a registry one.
#[test]
fn every_read_tool_documents_every_parameter_it_takes() {
    for def in agent_surface::registry::tool_defs() {
        if def.tier != agent_surface::registry::ToolTier::Read {
            continue;
        }
        let Some(props) = def.input_schema["properties"].as_object() else {
            continue;
        };
        for (key, spec) in props {
            let desc = spec["description"].as_str().unwrap_or("");
            assert!(
                desc.len() > 15,
                "read tool {} takes `{key}` and does not say what it means: {desc:?}",
                def.name
            );
        }
    }
}

/// Every READ tool must be callable on a bare, empty host without panicking or
/// refusing. An agent's first act after connecting is to look around, and a
/// read surface that only works once the project is already populated cannot
/// answer "what am I connected to?".
#[test]
fn every_read_tool_answers_on_an_empty_project() {
    let mut host = StudioHost::in_memory();
    let reads: Vec<String> = agent_surface::registry::tool_defs()
        .into_iter()
        .filter(|d| d.tier == agent_surface::registry::ToolTier::Read)
        // studio_waveform and studio_audition address a clip / a bar region and
        // cannot be called without one; they are exercised in steps 4 and 9.
        .filter(|d| d.input_schema["required"].as_array().is_some_and(|r| r.is_empty()))
        .map(|d| d.name)
        .collect();
    assert!(
        reads.len() >= 6,
        "expected the no-argument read tools, got {reads:?}"
    );
    for name in reads {
        let out = dispatch_tool(&mut host, agent(), &name, json!({}))
            .unwrap_or_else(|e| panic!("read tool {name} refused on an empty project: {e}"));
        assert!(
            out.is_object(),
            "read tool {name} answered with a non-object: {out}"
        );
    }
}
