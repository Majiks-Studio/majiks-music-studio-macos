//! Design §6 decided all eight deferred contract proposals. This file is the
//! ledger: one test per proposal, asserting the decision is REALIZED in the
//! tree rather than merely written down.
//!
//! Three of the eight turned out to be already satisfied by catalog v1.1
//! (crossfade-zero at runtime, the gen.revise scope array, take.purge). Those
//! tests assert the existing behaviour instead of adding a duplicate, and say
//! so — a proposal that is already done is a finding, not a task.

use serde_json::json;
use timeline_core::catalog::Catalog;
use timeline_core::cmd::Cmd;
use timeline_core::envelope::canonical_json;
use timeline_core::model::{Project, Track, DEFAULT_TRACK_HEIGHT_PX};
use timeline_core::num::Num;
use timeline_core::package::{from_project_json, to_project_json};
use timeline_core::session::Session;
use timeline_core::tempo::{Bpm, TempoMap};
use timeline_core::ParamRef;

fn project() -> Project {
    Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()))
}

/// 1. Float canonicalization rule — ACCEPT, formalize existing behaviour.
///
/// §9.4 corrected the premise: there WAS no single existing behaviour.
/// `timeline-core` emitted floats while both contract canonicalizers hard
/// rejected them, so a project with a fractional gain produced a journal the
/// conformance suite could not hash. Formalizing meant changing two rejecting
/// implementations and adding float fixtures — done; see
/// `tests/journal_invariants.rs`, `contracts/README.md` rule 4, and
/// `contracts/fixtures/project/float-journal.jsonl`.
#[test]
fn p1_float_canonicalization_is_pinned_in_both_directions() {
    assert_eq!(
        canonical_json(&json!({"gainDb": -3.5})).unwrap(),
        r#"{"gainDb":-3.5}"#
    );
    // Shape preserved, token normalized.
    let one_e3: Num = serde_json::from_str("1e3").unwrap();
    assert_eq!(
        canonical_json(&json!({"v": one_e3})).unwrap(),
        r#"{"v":1000.0}"#
    );
    let thousand: Num = serde_json::from_str("1000").unwrap();
    assert_eq!(
        canonical_json(&json!({"v": thousand})).unwrap(),
        r#"{"v":1000}"#
    );
    assert!(std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../contracts/fixtures/project/float-journal.jsonl")
        .exists());
}

/// 2. First-class `channelEq` — ACCEPT. ParamRef needs to address EQ bands, so
/// EQ cannot stay an implicit namespaced key.
#[test]
fn p2_eq_is_first_class_and_addressable_by_paramref() {
    let mut p = project();
    p.tracks.push(Track::new("t1", "Track 1"));
    p.apply_cmd(&Cmd::MixEq {
        track_id: "t1".into(),
        band: 2,
        freq_hz: Num::int(3000),
        gain_db: Num::int(-4),
        q: None,
    })
    .unwrap();

    let out = to_project_json(&Session::new(p.clone()));
    assert!(
        out["tracks"][0].get("eq").is_some(),
        "eq must be a first-class checkpoint key now: {}",
        out["tracks"][0]
    );
    assert!(
        out["tracks"][0].get("engineEq").is_none(),
        "the v1 namespaced key is no longer written"
    );
    assert_eq!(from_project_json(&out).unwrap().tracks[0].eq, p.tracks[0].eq);

    // The v1 key is still READ, so older checkpoints load unchanged.
    let legacy = json!({
        "formatVersion": 1, "projectId": "00000000000000000000000000", "name": "T",
        "sampleRateHz": 48000, "ppq": 960, "tempo": {"bpm": 120},
        "tracks": [{
            "trackId": "t1", "name": "Track 1", "index": 0,
            "engineEq": [
                {"freqHz": 80, "gainDb": 3, "q": 1},
                {"freqHz": 250, "gainDb": 0, "q": 1},
                {"freqHz": 2500, "gainDb": 0, "q": 1},
                {"freqHz": 8000, "gainDb": 0, "q": 1}
            ]
        }],
        "clips": [],
        "journal": {"entryCount": 0, "tipId": null,
                    "tipHash": "0000000000000000000000000000000000000000000000000000000000000000",
                    "genesisHash": "0000000000000000000000000000000000000000000000000000000000000000"}
    });
    let loaded = from_project_json(&legacy).expect("v1 engineEq still loads");
    assert_eq!(loaded.tracks[0].eq[0].gain_db, Num::int(3));

    // And every EQ band is now an addressable, resolvable ParamRef.
    let mut p2 = project();
    p2.tracks.push(Track::new("t1", "Track 1"));
    for band in 0..4 {
        for field in ["gain", "freq", "q"] {
            let r = ParamRef::parse(&format!("track.eq.{band}.{field}")).unwrap();
            p2.require_param_ref(&r)
                .unwrap_or_else(|e| panic!("track.eq.{band}.{field} must resolve: {e}"));
        }
    }
    assert!(p2
        .require_param_ref(&ParamRef::parse("track.eq.4.gain").unwrap())
        .is_err());
}

/// 3. Crossfade length-0 — ACCEPT. Already true at RUNTIME in v1.1 via a
/// hand-rolled filter in `validate_params`; v2 makes the SCHEMA say it, so the
/// filter is inert.
#[test]
fn p3_crossfade_zero_is_schema_legal_not_a_special_case() {
    let spec = Catalog::get().spec("clip.crossfade.set").unwrap();
    let lt = &spec.params_schema["properties"]["lengthTicks"];
    assert!(
        lt.get("exclusiveMinimum").is_none(),
        "v2 removed the exclusiveMinimum that the self-inverse rule contradicted"
    );
    assert_eq!(lt["minimum"], json!(0));
    assert!(Catalog::get()
        .validate_params(
            "clip.crossfade.set",
            &json!({"clipIdA": "a", "clipIdB": "b", "lengthTicks": 0})
        )
        .is_ok());
    assert!(Catalog::get()
        .validate_params(
            "clip.crossfade.set",
            &json!({"clipIdA": "a", "clipIdB": "b", "lengthTicks": -1})
        )
        .is_err());
}

/// 4. `split`/`take` inverse shapes — ACCEPT. Realized as the `inverseShape`
/// annotation, enforced by `tests/inverse_shape.rs`.
#[test]
fn p4_inverse_shape_is_declared_data() {
    use timeline_core::catalog::InverseShape;
    assert_eq!(
        Catalog::get().spec("clip.split").unwrap().inverse_shape,
        InverseShape::Multi
    );
    // And `inverseRule` itself is untouched — that is v1.1 law.
    assert_eq!(
        Catalog::get().spec("clip.split").unwrap().inverse_mode,
        timeline_core::InverseMode::SelfInverse
    );
}

/// 5. Track height 90-vs-64 — ACCEPT the contract value (90).
#[test]
fn p5_track_height_default_is_the_contract_value() {
    assert_eq!(DEFAULT_TRACK_HEIGHT_PX, 90);
    assert_eq!(Track::new("t", "T").height_px, 90);
    // The UI token was the side that disagreed; it now matches.
    let tokens = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../src/swift/Sources/Theme/StudioTokens.swift"),
    )
    .expect("StudioTokens.swift");
    assert!(
        tokens.contains("trackHeightDefault: CGFloat = 90"),
        "the Swift UI default must match the contract, not 64"
    );
}

/// 6. Project phase anchor (L8) — ACCEPT. New COMMAND NAME, never an optional
/// param on an existing one (§9.2).
#[test]
fn p6_project_phase_anchor_exists_as_a_new_command() {
    assert!(Catalog::get().spec("project.setPhaseAnchor").is_some());
    // The pre-existing clip-level anchor is untouched and unrelated.
    assert!(Catalog::get().spec("clip.phaseAnchor.set").is_some());
    let mut p = project();
    p.apply_cmd(&Cmd::ProjectSetPhaseAnchor { anchor_ticks: 1915 })
        .unwrap();
    assert_eq!(p.phase_anchor_ticks, 1915);
}

/// 7. Scope array (L9) — ACCEPT. ALREADY SHIPPED in catalog v1.1: `gen.revise`
/// `scope` is a `oneOf` of a scalar and an array, and `Cmd::GenRevise` carries
/// it as a raw `Value`, so both forms round-trip. No v2 change was needed; this
/// test pins it so the disposition is verified, not assumed.
#[test]
fn p7_gen_revise_scope_already_accepts_an_array() {
    let spec = Catalog::get().spec("gen.revise").unwrap();
    assert!(spec.params_schema["properties"]["scope"]["oneOf"].is_array());
    let ulid = "01J0000000000000000000000";
    for scope in [json!("all-stems"), json!(["vocals", "drums"])] {
        let params = json!({
            "requestId": format!("0{ulid}"),
            "clipId": "c1",
            "regionStartTicks": 0,
            "regionEndTicks": 960,
            "scope": scope,
            "request": {"instruction": "brighter"}
        });
        Catalog::get()
            .validate_params("gen.revise", &params)
            .unwrap_or_else(|e| panic!("{scope} should validate: {e}"));
        let cmd = Cmd::from_wire("gen.revise", params.clone()).expect("parses");
        assert_eq!(cmd.params_value()["scope"], scope, "both forms round-trip");
    }
}

/// 8. `take.purge` (L10) — ACCEPT, "the contract should reflect reality".
/// ALREADY SHIPPED in catalog v1.1 as a journaled, undoable command paired with
/// `take.restore`. Verified rather than duplicated.
#[test]
fn p8_take_purge_is_already_a_journaled_undoable_command() {
    let purge = Catalog::get().spec("take.purge").expect("take.purge");
    assert!(purge.journaled && purge.undoable);
    let restore = Catalog::get().spec("take.restore").expect("take.restore");
    assert!(restore.journaled && restore.undoable);
    assert_eq!(
        restore.inverse_name.as_deref(),
        Some("take.purge"),
        "the pair completes the undo cycle"
    );
}

/// All eight, additive, and none alters a v1.1 command's accepted inputs.
/// The superset test proves the second half; this pins the first.
#[test]
fn every_v2_addition_is_a_new_command_name() {
    let v1: std::collections::BTreeSet<String> = serde_json::from_str::<serde_json::Value>(
        timeline_core::catalog::CATALOG_V1_1_JSON,
    )
    .unwrap()["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap().to_string())
        .collect();
    let added: Vec<&str> = Catalog::get()
        .names()
        .iter()
        .filter(|n| !v1.contains(*n))
        .map(String::as_str)
        .collect();
    let mut sorted = added.clone();
    sorted.sort_unstable();
    assert_eq!(
        sorted,
        [
            // E1 (notes). `clip.placeMidi` is the load-bearing one: making
            // `clip.place`'s assetHash optional instead would let an older
            // binary verify the chain and silently build an audio clip.
            // (Sorted, so the E0/E1/device groups interleave.)
            "clip.placeMidi",
            "device.add",
            // The instrument parameter setter E1/E2 refused to ship, on the
            // grounds that "its inverse cannot be exact without per-parameter
            // defaults that the DSP lane owns". E5 disproved that for
            // `fx.param.set` and the disproof transfers verbatim: params stay
            // SPARSE, so setting an absent key undoes to ABSENT via
            // `device.param.clear` and no default is ever invented. Until this
            // landed, the synth's four waveforms and its whole ADSR were
            // reachable by AUTOMATION and by nothing else — the app's one
            // instrument sound was a raw sawtooth, permanently.
            "device.param.clear",
            "device.param.set",
            "device.remove",
            // E2 source binding. Same load-bearing reason as clip.placeMidi:
            // an optional `sourceId` on `device.add` would let an older binary
            // verify the chain and silently build a sampler with no audio.
            "device.zone.add",
            "device.zone.remove",
            // E5 §16.4 — the effect registry. SEVEN new NAMES, and the reason
            // is the same one every time: `device.add`'s `kind` enum is NOT
            // widened and `Device`/`DeviceKind` are untouched, because
            // `build_instrument` hard-errors on a track with more than one
            // device — an effect in `Track::devices` would break the compile of
            // every instrument track that also carries an effect (§16.1). A
            // separate registry costs ZERO enum widening sites.
            //
            // `fx.param.set` in particular is the setter E1/E2 refused to ship
            // for `Device` ("its inverse cannot be exact without per-parameter
            // defaults that the DSP lane owns"). It is safe here because params
            // stay SPARSE: setting an absent key undoes to ABSENT via
            // `fx.param.clear`, so no default is ever invented.
            "fx.add",
            "fx.move",
            "fx.param.clear",
            "fx.param.set",
            "fx.remove",
            "fx.sidechain.clear",
            "fx.sidechain.set",
            // Port ROLE. What a MIDI port's keys do is new semantics, so it is
            // a new name rather than an optional param on `midi.device.select`
            // — an older binary would accept the unknown param, ignore it, and
            // silently keep stealing every key the map binds.
            "midi.port.role.set",
            "note.add",
            "note.duplicate",
            "note.move",
            // Quantize. A NEW name, and so is the absolute setter its inverse
            // rides on: widening `note.move` with a per-note delta array would
            // let an older binary verify the chain, ignore the array, and
            // silently build a project whose notes are somewhere else. The
            // owner's own take is deliberately off the grid, so "somewhere
            // else" here means the performance is gone.
            "note.quantize",
            "note.remove",
            "note.resize",
            "note.timing.set",
            "note.velocity.set",
            "project.setPhaseAnchor",
            // Opt-in input open for metering. NEW name rather than a flag on
            // track.arm: arming is a destination statement, not a request to
            // open the mic. Widening track.arm would also re-open the privacy
            // bug this command exists to keep closed.
            "record.inputListen",
            "route.connect",
            "route.disconnect",
            "route.edge.set",
            "route.node.add",
            "route.node.remove",
            // The node FADER (§4.3's "buses with their own fader"). A new
            // name, not a `gainDb` param on `route.node.add`: an older binary
            // would verify the chain, ignore the unknown param, and silently
            // open every bus at unity — the exact §9.2 failure. NOT the
            // reserved `route.node.solo` (§7.2), and NOT a
            // `route.node.<id>.gain` ParamRef (§2.2: automation spells it
            // `bus.<id>.gain`; this command is the fader's static half).
            "route.node.set",
            // Per-track hardware input channel. NEW name rather than widening
            // track.arm with an optional channel: an older binary would ignore
            // the channel and silently record every track from input 0.
            "track.setInputChannel",
        ],
        "v2 adds exactly these NEW NAMES — never an optional param on a v1 command"
    );
}
