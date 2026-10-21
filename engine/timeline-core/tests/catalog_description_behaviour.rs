//! The descriptions are only worth writing if they are TRUE.
//!
//! `catalog_descriptions.rs` proves each description is consistent with its own
//! schema — same numbers, same enum values. That is one link in the chain. This
//! file closes the other one: it drives the real validator and the real
//! executor at each documented boundary and asserts they behave the way the
//! prose says.
//!
//! Two classes are covered, and the second is the reason this file exists:
//!
//!  A. THE SCHEMA IS THE LIMIT. A value at the documented edge is accepted and
//!     one past it is rejected. If someone widens a `maximum` without touching
//!     the description, `catalog_descriptions` catches it; if someone narrows
//!     the DESCRIPTION without touching the schema, this catches it.
//!
//!  B. THE EXECUTOR IS STRICTER THAN THE SCHEMA. Several parameters advertise a
//!     range the schema will let through and `apply.rs` then refuses. Those are
//!     the traps an agent finds by being rejected, so their descriptions say so
//!     in words — and here that claim is executed rather than asserted. If the
//!     executor ever relaxes, the description becomes a lie and this fails.
//!
//! Nothing here compares a constant to itself: every expectation is a call into
//! `Catalog::validate_params` or `Project::apply_cmd`.

use serde_json::{json, Value};
use timeline_core::catalog::Catalog;
use timeline_core::cmd::Cmd;
use timeline_core::{Bpm, Num, Project, Source, TempoMap};

fn accepts(name: &str, params: Value) -> bool {
    Catalog::get().validate_params(name, &params).is_ok()
}

/// A project with one track, one 480 000-frame source and one 4-bar clip on it —
/// enough for every executor probe below.
fn project() -> Project {
    let mut p = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    p.add_source(Source {
        id: "a".repeat(64),
        path: "a.wav".into(),
        len_frames: 480_000,
    })
    .unwrap();
    p.apply_cmd(&Cmd::TrackAdd {
        track_id: "t".into(),
        name: "Track".into(),
        index: None,
    })
    .unwrap();
    p.apply_cmd(&Cmd::ClipPlace {
        clip_id: "c".into(),
        track_id: "t".into(),
        asset_hash: "a".repeat(64),
        start_ticks: 0,
        length_ticks: 3840,
        source_offset_ticks: None,
    })
    .unwrap();
    p
}

// ---------------------------------------------------------------------------
// A. The documented range IS the schema's range, at the edge and just past it.
// ---------------------------------------------------------------------------

/// The trickiest dozen-plus: everything carrying units, a range, an enum or an
/// id format. Each row is (command, param, a value the description says is
/// legal, a value it says is not).
#[test]
fn every_documented_boundary_is_the_boundary_the_validator_enforces() {
    // (command, params-at-the-documented-edge, params-just-past-it, why)
    let rows: Vec<(&str, Value, Value, &str)> = vec![
        (
            "mix.gain",
            json!({"trackId": "t", "gainDb": -60}),
            json!({"trackId": "t", "gainDb": -60.5}),
            "gainDb is documented -60 to 12",
        ),
        (
            "mix.gain",
            json!({"trackId": "t", "gainDb": 12}),
            json!({"trackId": "t", "gainDb": 12.5}),
            "gainDb is documented -60 to 12",
        ),
        (
            "mix.pan",
            json!({"trackId": "t", "pan": -1}),
            json!({"trackId": "t", "pan": -1.01}),
            "pan is documented -1 (hard left) to 1 (hard right)",
        ),
        (
            "mix.send",
            json!({"trackId": "t", "bus": "a", "amount": 1}),
            json!({"trackId": "t", "bus": "a", "amount": 1.5}),
            "send amount is documented 0 to 1, linear",
        ),
        (
            "mix.send",
            json!({"trackId": "t", "bus": "b", "amount": 0}),
            json!({"trackId": "t", "bus": "c", "amount": 0}),
            "the send bus enum is documented as exactly 'a' (reverb) and 'b' (delay)",
        ),
        (
            "mix.eq",
            json!({"trackId": "t", "band": 3, "freqHz": 20000, "gainDb": 24}),
            json!({"trackId": "t", "band": 4, "freqHz": 20000, "gainDb": 24}),
            "band is documented 0 to 3 (four fixed bands)",
        ),
        (
            "mix.eq",
            json!({"trackId": "t", "band": 0, "freqHz": 20, "gainDb": -24, "q": 10}),
            json!({"trackId": "t", "band": 0, "freqHz": 19, "gainDb": -24, "q": 10}),
            "freqHz is documented 20 to 20000 Hz",
        ),
        (
            "mix.limiter.set",
            json!({"enabled": true, "ceilingDb": -6, "releaseMs": 1000}),
            json!({"enabled": true, "ceilingDb": -6.5, "releaseMs": 1000}),
            "ceilingDb is documented -6 to 0 dBFS",
        ),
        (
            "track.setHeight",
            json!({"trackId": "t", "heightPx": 400}),
            json!({"trackId": "t", "heightPx": 401}),
            "heightPx is documented 24 to 400 points",
        ),
        (
            "track.setHeight",
            json!({"trackId": "t", "heightPx": 24}),
            json!({"trackId": "t", "heightPx": 23}),
            "heightPx is documented 24 to 400 points",
        ),
        (
            "project.setTempo",
            json!({"bpm": 999}),
            json!({"bpm": 1000}),
            "bpm is documented as greater than 0 and at most 999",
        ),
        (
            "project.setTimeSig",
            json!({"numerator": 32, "denominator": 32}),
            json!({"numerator": 32, "denominator": 3}),
            "the denominator enum is documented as 1, 2, 4, 8, 16 or 32",
        ),
        (
            "note.add",
            json!({"clipId": "c", "notes": [{"noteId": "n", "startTicks": 0, "lengthTicks": 1, "pitch": 127, "velocity": 127}]}),
            json!({"clipId": "c", "notes": [{"noteId": "n", "startTicks": 0, "lengthTicks": 1, "pitch": 128, "velocity": 127}]}),
            "note pitch is documented 0 to 127",
        ),
        (
            "note.add",
            json!({"clipId": "c", "notes": [{"noteId": "n", "startTicks": 0, "lengthTicks": 1, "pitch": 60, "velocity": 127}]}),
            json!({"clipId": "c", "notes": [{"noteId": "n", "startTicks": 0, "lengthTicks": 1, "pitch": 60, "velocity": 100.5}]}),
            "velocity is documented 0 to 127; a genuinely fractional value is not an integer",
        ),
        (
            "note.quantize",
            json!({"clipId": "c", "noteIds": ["n"], "gridTicks": 960, "strengthPercent": 100, "quantizeEnds": false}),
            json!({"clipId": "c", "noteIds": ["n"], "gridTicks": 960, "strengthPercent": 101, "quantizeEnds": false}),
            "strengthPercent is documented as an INTEGER percent, 0 to 100",
        ),
        (
            "note.quantize",
            json!({"clipId": "c", "noteIds": ["n"], "gridTicks": 960, "strengthPercent": 80, "quantizeEnds": false}),
            json!({"clipId": "c", "noteIds": ["n"], "gridTicks": 960, "strengthPercent": 0.8, "quantizeEnds": false}),
            "strengthPercent is documented as an integer, not a 0..1 float",
        ),
        (
            "route.edge.set",
            json!({"edgeId": "e", "level": 4, "tap": "pre"}),
            json!({"edgeId": "e", "level": 4.5, "tap": "pre"}),
            "edge level is documented linear 0 to 4",
        ),
        (
            "route.edge.set",
            json!({"edgeId": "e", "level": 1, "tap": "post"}),
            json!({"edgeId": "e", "level": 1, "tap": "prefader"}),
            "tap is documented as exactly 'pre' or 'post'",
        ),
        (
            "route.connect",
            json!({"edgeId": "e", "from": "track.t1", "to": "master", "level": 1, "tap": "pre"}),
            json!({"edgeId": "e", "from": "track:t1", "to": "master", "level": 1, "tap": "pre"}),
            "a node ref is documented 'track.<id>' / 'bus.<id>' / 'master' — the dot is the grammar",
        ),
        (
            "device.zone.add",
            json!({"trackId": "t", "deviceId": "d", "zoneId": "z", "sourceId": "s", "rootPitch": 60, "loPitch": 0, "hiPitch": 127}),
            json!({"trackId": "t", "deviceId": "d", "zoneId": "z", "sourceId": "s", "rootPitch": 60, "loPitch": 0, "hiPitch": 128}),
            "zone pitches are documented 0 to 127",
        ),
        (
            "device.add",
            json!({"trackId": "t", "deviceId": "d", "kind": "drum"}),
            json!({"trackId": "t", "deviceId": "d.x", "kind": "drum"}),
            "deviceId is documented as never containing '.', so the ParamRef path stays parseable",
        ),
        (
            "device.add",
            json!({"trackId": "t", "deviceId": "d", "kind": "sampler"}),
            json!({"trackId": "t", "deviceId": "d", "kind": "piano"}),
            "the device kind enum is documented as exactly synth, sampler and drum",
        ),
        (
            "fx.add",
            json!({"target": "master", "fxId": "f", "kind": "limiter"}),
            json!({"target": "master", "fxId": "f", "kind": "exciter"}),
            "the fx kind enum is documented as nine closed values",
        ),
        (
            "clip.setGain",
            json!({"clipId": "c", "gainDb": 12}),
            json!({"clipId": "c", "gainDb": 13}),
            "clip gain trim is documented -60 to 12",
        ),
        (
            "gen.landed",
            json!({"requestId": "01J8Z4G9K2X4Q6R8T0V2W4Y6A8", "sourceCommand": "gen.song", "takeId": "tk", "assetHashes": {"mix": "b".repeat(64)}, "engineIdentity": {"model": "m", "device": "mlx"}}),
            json!({"requestId": "01J8Z4G9K2X4Q6R8T0V2W4Y6A8", "sourceCommand": "gen.song", "takeId": "tk", "assetHashes": {"mix": "b".repeat(64)}, "engineIdentity": {"model": "m", "device": "tpu"}}),
            "engineIdentity.device is documented as mlx, mps, cuda, cpu or remote",
        ),
        (
            "gen.cancel",
            json!({"requestId": "01J8Z4G9K2X4Q6R8T0V2W4Y6A8"}),
            json!({"requestId": "81J8Z4G9K2X4Q6R8T0V2W4Y6A8"}),
            "a requestId is documented as a ULID whose FIRST character is 0-7",
        ),
        (
            "gen.revise",
            json!({"requestId": "01J8Z4G9K2X4Q6R8T0V2W4Y6A8", "clipId": "c", "regionStartTicks": 0, "regionEndTicks": 960, "scope": "all-stems", "request": {"instruction": "x", "variants": 5}}),
            json!({"requestId": "01J8Z4G9K2X4Q6R8T0V2W4Y6A8", "clipId": "c", "regionStartTicks": 0, "regionEndTicks": 960, "scope": "all-stems", "request": {"instruction": "x", "variants": 6}}),
            "revise variants is documented 1 to 5",
        ),
        (
            "gen.revise",
            json!({"requestId": "01J8Z4G9K2X4Q6R8T0V2W4Y6A8", "clipId": "c", "regionStartTicks": 0, "regionEndTicks": 960, "scope": ["vocals", "drums"], "request": {"instruction": "x"}}),
            json!({"requestId": "01J8Z4G9K2X4Q6R8T0V2W4Y6A8", "clipId": "c", "regionStartTicks": 0, "regionEndTicks": 960, "scope": ["all-stems"], "request": {"instruction": "x"}}),
            "'all-stems' is documented as valid only as a SCALAR, never inside the array",
        ),
        (
            "track.setColor",
            json!({"trackId": "t", "color": "#3AA6FF"}),
            json!({"trackId": "t", "color": "#3AA6FF80"}),
            "a colour is documented as six hex digits with no alpha channel",
        ),
        (
            "clip.place",
            json!({"clipId": "c2", "trackId": "t", "assetHash": "a".repeat(64), "startTicks": 0, "lengthTicks": 1}),
            json!({"clipId": "c2", "trackId": "t", "assetHash": "A".repeat(64), "startTicks": 0, "lengthTicks": 1}),
            "an assetHash is documented as 64 LOWERCASE hex characters",
        ),
        (
            "take.auditionMix",
            json!({"takeId": "tk", "stems": ["vocals", "drums", "bass", "other", "mix"]}),
            json!({"takeId": "tk", "stems": ["strings"]}),
            "the audition stem enum is documented as vocals, drums, bass, other and mix",
        ),
        (
            "export.master",
            json!({"outputPath": "/tmp/x.wav", "format": "wav", "loudnessTarget": "broadcast"}),
            json!({"outputPath": "/tmp/x.wav", "format": "wav", "loudnessTarget": "-16"}),
            "loudnessTarget is documented as the four names streaming/club/broadcast/none",
        ),
        (
            "note.velocity.set",
            json!({"clipId": "c", "noteIds": ["n"], "deltaVelocity": -127}),
            json!({"clipId": "c", "noteIds": ["n"], "deltaVelocity": -128}),
            "deltaVelocity is documented -127 to 127",
        ),
    ];

    assert!(
        rows.len() >= 12,
        "the brief asks for the trickiest dozen; this table has {}",
        rows.len()
    );

    let mut wrong = Vec::new();
    for (name, legal, illegal, why) in &rows {
        if !accepts(name, legal.clone()) {
            wrong.push(format!(
                "{name}: the description says {legal} is legal and the validator REJECTS it ({why})"
            ));
        }
        if accepts(name, illegal.clone()) {
            wrong.push(format!(
                "{name}: the description says {illegal} is out of range and the validator ACCEPTS it ({why})"
            ));
        }
    }
    assert!(
        wrong.is_empty(),
        "documented ranges disagree with the validator:\n{}",
        wrong.join("\n")
    );
}

// ---------------------------------------------------------------------------
// B. Where the executor is STRICTER than the schema, and the description says
//    so. These are the sentences most likely to rot, because nothing about the
//    schema reminds anyone they exist.
// ---------------------------------------------------------------------------

/// `clip.place.lengthTicks` — "the schema admits 0 but the executor REFUSES it".
#[test]
fn clip_place_length_zero_passes_the_schema_and_is_refused_by_the_executor() {
    let zero = json!({
        "clipId": "z", "trackId": "t", "assetHash": "a".repeat(64),
        "startTicks": 0, "lengthTicks": 0
    });
    assert!(
        accepts("clip.place", zero),
        "the schema's minimum is 0, so a 0 length must still pass validation — \
         if this now fails, clip.place's description must stop saying the schema admits it"
    );

    let mut p = project();
    let err = p
        .apply_cmd(&Cmd::ClipPlace {
            clip_id: "z".into(),
            track_id: "t".into(),
            asset_hash: "a".repeat(64),
            start_ticks: 7680,
            length_ticks: 0,
            source_offset_ticks: None,
        })
        .expect_err("the executor refuses a zero-length clip");
    assert!(
        err.to_string().contains("lengthTicks"),
        "the refusal has to name the parameter: {err}"
    );
}

/// `clip.trim.deltaTicks` — "signed, and it may not be 0", and the direction of
/// a positive delta differs per edge. Both halves are executed.
#[test]
fn clip_trim_delta_is_nonzero_and_the_documented_direction_is_the_real_one() {
    let mut p = project();
    let err = p
        .apply_cmd(&Cmd::ClipTrim {
            clip_id: "c".into(),
            edge: timeline_core::cmd::TrimEdgeWire::End,
            delta_ticks: 0,
        })
        .expect_err("a zero delta is refused");
    assert!(err.to_string().contains("nonzero"), "{err}");

    // "on the 'end' edge a positive value lengthens"
    let before = p.track("t").unwrap().clips[0].length_ticks;
    p.apply_cmd(&Cmd::ClipTrim {
        clip_id: "c".into(),
        edge: timeline_core::cmd::TrimEdgeWire::End,
        delta_ticks: 480,
    })
    .unwrap();
    assert_eq!(
        p.track("t").unwrap().clips[0].length_ticks,
        before + 480,
        "the description says a positive end-edge delta LENGTHENS"
    );

    // "on the 'start' edge a positive value shortens from the front"
    let start_before = p.track("t").unwrap().clips[0].start_ticks;
    let len_before = p.track("t").unwrap().clips[0].length_ticks;
    p.apply_cmd(&Cmd::ClipTrim {
        clip_id: "c".into(),
        edge: timeline_core::cmd::TrimEdgeWire::Start,
        delta_ticks: 480,
    })
    .unwrap();
    let clip = &p.track("t").unwrap().clips[0];
    assert_eq!(clip.start_ticks, start_before + 480);
    assert_eq!(
        clip.length_ticks,
        len_before - 480,
        "the description says a positive start-edge delta SHORTENS from the front"
    );
}

/// `clip.split.atTicks` — "STRICTLY inside the clip ... a split exactly on an
/// edge is refused rather than silently ignored".
#[test]
fn clip_split_refuses_both_edges_and_accepts_strictly_inside() {
    for at in [0u64, 3840] {
        let mut p = project();
        let err = p
            .apply_cmd(&Cmd::ClipSplit {
                clip_id: "c".into(),
                at_ticks: at,
                new_clip_id: "r".into(),
            })
            .expect_err("a split on an edge is refused");
        assert!(err.to_string().contains("strictly inside"), "{err}");
    }
    let mut p = project();
    p.apply_cmd(&Cmd::ClipSplit {
        clip_id: "c".into(),
        at_ticks: 1920,
        new_clip_id: "r".into(),
    })
    .expect("a split strictly inside is accepted");
}

/// `mix.eq.q` and `mix.limiter.set.ceilingDb`/`releaseMs` — "OMITTING it leaves
/// the stored value exactly as it was rather than resetting it". This is the
/// least obvious sentence in the whole catalog and the easiest to get wrong.
#[test]
fn omitting_an_optional_mixer_field_leaves_the_stored_value_alone() {
    let mut p = project();
    p.apply_cmd(&Cmd::MixEq {
        track_id: "t".into(),
        band: 0,
        freq_hz: Num::int(100),
        gain_db: Num::int(3),
        q: Some(Num::int(7)),
    })
    .unwrap();
    assert_eq!(p.track("t").unwrap().eq[0].q, Num::int(7));
    p.apply_cmd(&Cmd::MixEq {
        track_id: "t".into(),
        band: 0,
        freq_hz: Num::int(200),
        gain_db: Num::int(1),
        q: None,
    })
    .unwrap();
    assert_eq!(
        p.track("t").unwrap().eq[0].q,
        Num::int(7),
        "omitting q must leave it at 7, not reset it to the band default of 1"
    );

    p.apply_cmd(&Cmd::MixLimiterSet {
        enabled: true,
        ceiling_db: Some(Num::int(-3)),
        release_ms: Some(Num::int(200)),
    })
    .unwrap();
    p.apply_cmd(&Cmd::MixLimiterSet {
        enabled: false,
        ceiling_db: None,
        release_ms: None,
    })
    .unwrap();
    assert_eq!(p.master.limiter.ceiling_db, Num::int(-3));
    assert_eq!(
        p.master.limiter.release_ms,
        Num::int(200),
        "omitting releaseMs must leave it at 200, not reset it to the 50 default"
    );
}

/// `track.add.index` — "may equal the current track count (append), and
/// anything larger is refused" — versus `track.reorder.newIndex`, "strictly
/// LESS than the current track count". The two descriptions claim DIFFERENT
/// bounds for what looks like the same number, which is exactly the kind of
/// thing a caller gets wrong once.
#[test]
fn add_index_and_reorder_index_have_the_different_bounds_they_advertise() {
    let mut p = project(); // one track
    let count = p.tracks.len() as u32;

    p.apply_cmd(&Cmd::TrackAdd {
        track_id: "appended".into(),
        name: "n".into(),
        index: Some(count),
    })
    .expect("track.add accepts index == track count (append)");

    let count = p.tracks.len() as u32;
    let err = p
        .apply_cmd(&Cmd::TrackAdd {
            track_id: "toofar".into(),
            name: "n".into(),
            index: Some(count + 1),
        })
        .expect_err("track.add refuses an index past the end");
    assert!(err.to_string().contains("out of range"), "{err}");

    let err = p
        .apply_cmd(&Cmd::TrackReorder {
            track_id: "t".into(),
            new_index: count,
        })
        .expect_err("track.reorder refuses newIndex == track count");
    assert!(err.to_string().contains("out of range"), "{err}");
    p.apply_cmd(&Cmd::TrackReorder {
        track_id: "t".into(),
        new_index: count - 1,
    })
    .expect("track.reorder accepts the last slot");
}

/// `device.add.trackId` — "a second device is accepted here (only a duplicate
/// deviceId is refused)". A description that warned about a refusal the engine
/// does not perform would send a caller looking for an error that never comes.
#[test]
fn device_add_accepts_a_second_device_and_refuses_only_a_duplicate_id() {
    let mut p = project();
    for id in ["d1", "d2"] {
        p.apply_cmd(&Cmd::DeviceAdd {
            track_id: "t".into(),
            device_id: id.into(),
            kind: timeline_core::model::DeviceKind::Synth,
        })
        .unwrap_or_else(|e| panic!("device.add must accept {id}: {e}"));
    }
    assert_eq!(
        p.track("t").unwrap().devices.len(),
        2,
        "the description says a second device is ACCEPTED at the bus and only \
         breaks later, in the render compile"
    );
    let err = p
        .apply_cmd(&Cmd::DeviceAdd {
            track_id: "t".into(),
            device_id: "d1".into(),
            kind: timeline_core::model::DeviceKind::Synth,
        })
        .expect_err("a duplicate deviceId IS refused");
    assert!(err.to_string().contains("d1"), "{err}");
}

/// `take.auditionMix.stems` and `autolane.show.visible` — both described as NOT
/// IMPLEMENTED. That claim is only safe to publish if the engine really does
/// nothing, so it is executed: the commands succeed, mutate nothing, and leave
/// the project byte-identical.
#[test]
fn the_parameters_documented_as_not_implemented_really_do_nothing() {
    let mut p = project();
    p.takes.push(timeline_core::model::TakeRecord {
        take_id: "tk".into(),
        request_id: "01J8Z4G9K2X4Q6R8T0V2W4Y6A8".into(),
        source_command: "gen.revise".into(),
        asset_hashes: std::collections::BTreeMap::from([(
            String::from("vocals"),
            "b".repeat(64),
        )]),
        engine_identity: json!({"model": "m"}),
        status: timeline_core::model::TakeStatus::Candidate,
        promoted_into: None,
        prior_asset: None,
    });
    let before = p.clone();

    let effect = p
        .apply_cmd(&Cmd::TakeAuditionMix {
            take_id: "tk".into(),
            stems: vec!["vocals".into()],
        })
        .expect("take.auditionMix returns ok");
    assert!(!effect.mutated, "it reports mutated:false");
    assert_eq!(p, before, "and it changes nothing at all");

    let effect = p
        .apply_cmd(&Cmd::AutolaneShow {
            track_id: "t".into(),
            target: timeline_core::paramref::ParamRef::parse("track.volume").expect("ParamRef"),
            visible: true,
        })
        .expect("autolane.show returns ok");
    assert!(!effect.mutated, "it reports mutated:false");
    assert_eq!(p, before, "and it stores no visibility anywhere");
}

/// `studio.importStemSession` — described as adding ONE empty placeholder track
/// with no audio and no clips, rather than importing a session. Executed,
/// because the honest description is the only warning a caller gets.
#[test]
fn import_stem_session_adds_one_empty_track_and_nothing_else() {
    let mut p = project();
    let tracks_before = p.tracks.len();
    p.apply_cmd(&Cmd::StudioImportStemSession {
        stem_session_id: "ss1".into(),
    })
    .expect("studio.importStemSession succeeds");
    assert_eq!(p.tracks.len(), tracks_before + 1, "exactly one track appears");
    let landed = p.tracks.last().unwrap();
    assert_eq!(landed.id, "trk_stems_ss1");
    assert_eq!(landed.name, "Stem Session ss1");
    assert!(
        landed.clips.is_empty(),
        "and it carries no clips: nothing was imported"
    );
}

/// THE COMMENT THAT WAS WRONG. `cmd.rs` asserted for the life of the note
/// commands that the catalog's `"type": "integer"` means `100.0` "is rejected at
/// the contract boundary". It is not: JSON Schema defines an integer as any
/// number with a zero fractional part, so `100.0` validates, deserializes into
/// `Num`, and is journaled with the FLOAT shape it arrived in — the same musical
/// edit under a different hash, with nothing anywhere saying so.
///
/// Nothing can be tightened without narrowing a journaled command, so the
/// catalog description is where a caller is warned, and this test is what keeps
/// that warning true. If a future build really does start rejecting `100.0`,
/// this fails and the description gets to change with it.
#[test]
fn an_integer_typed_velocity_accepts_a_float_shaped_hundred_and_the_catalog_says_so() {
    let float_shaped = json!({
        "clipId": "c",
        "notes": [{"noteId": "n", "startTicks": 0, "lengthTicks": 1, "pitch": 60, "velocity": 100.0}]
    });
    assert!(
        accepts("note.add", float_shaped),
        "JSON Schema integer accepts a zero-fraction float; if this ever stops being \
         true, note.add's velocity description must stop warning about it"
    );
    assert!(
        !accepts(
            "note.add",
            json!({"clipId": "c", "notes": [{"noteId": "n", "startTicks": 0, "lengthTicks": 1, "pitch": 60, "velocity": 100.5}]})
        ),
        "a genuinely fractional velocity IS rejected"
    );

    // And the warning is actually in the catalog, in words, where a caller reads
    // it — not only here.
    let doc: Value = serde_json::from_str(timeline_core::catalog::CATALOG_JSON).unwrap();
    let velocity = doc["commands"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == "note.add")
        .expect("note.add")["paramsSchema"]["properties"]["notes"]["items"]["properties"]
        ["velocity"]["description"]
        .as_str()
        .expect("velocity description");
    assert!(
        velocity.contains("100.0"),
        "note.add's velocity description must name the float shape it cannot reject: {velocity}"
    );
}
