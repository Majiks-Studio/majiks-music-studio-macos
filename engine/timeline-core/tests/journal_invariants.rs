//! Design §9.7: "Unverified claims carried from the survey — confirm before
//! relying on them." Three claims were derived, not tested. Two of them are the
//! hinge of the worst failure mode in the whole design, so they get tests here
//! rather than trust.
//!
//! Plus §9.1's permanent-envelope guard and §6's accepted float
//! canonicalization rule, with the negative cases §9.4 asks for.

use serde_json::{json, Value};
use timeline_core::cmd::Cmd;
use timeline_core::envelope::{canonical_json, Envelope, ENVELOPE_HASHED_FIELDS};
use timeline_core::num::Num;

// ---------------------------------------------------------------------------
// §9.1 — the 7-field envelope is PERMANENT
// ---------------------------------------------------------------------------

#[test]
fn the_hashed_field_set_is_exactly_seven_and_never_grows() {
    // Adding an 8th hashed field re-hashes every historical entry and bricks
    // every existing project. This is the tripwire.
    assert_eq!(
        ENVELOPE_HASHED_FIELDS,
        ["id", "ts", "actor", "name", "params", "inverse", "result"],
        "ENVELOPE_HASHED_FIELDS is PERMANENT. Envelope-level metadata is not \
         available to v2 or any later catalog: put it in the params of a NEW command."
    );
}

// ---------------------------------------------------------------------------
// §9.2 / §9.7 — "write the 10-line test before depending on it"
// ---------------------------------------------------------------------------

#[test]
fn serde_silently_ignores_an_unknown_field_inside_the_adjacently_tagged_content() {
    // THIS is why new semantics must go in NEW command names. `Cmd` is
    // adjacently tagged (`tag = "name", content = "params"`) and nothing in the
    // workspace uses `deny_unknown_fields`, so an older binary parsing a
    // command that gained an optional field DISCARDS that field and builds a
    // wrong model — while the chain still verifies, because the hash is over
    // the raw payload, not the typed value.
    let with_extra = json!({
        "clipId": "c1",
        "trackId": "t1",
        "startTicks": 960,
        "aFieldFromTheFuture": {"whatever": [1, 2, 3]}
    });
    let parsed = Cmd::from_wire("clip.move", with_extra)
        .expect("serde accepts and SILENTLY DROPS the unknown field");
    assert_eq!(
        parsed,
        Cmd::ClipMove {
            clip_id: "c1".into(),
            track_id: "t1".into(),
            start_ticks: 960,
        },
        "the future field vanished without a trace — no error, no signal"
    );

    // The safe alternative: an unknown command NAME hard-fails.
    assert!(
        Cmd::from_wire("route.somethingFromTheFuture", json!({})).is_err(),
        "an unknown command name must fail loudly"
    );
    assert!(
        timeline_core::Catalog::get()
            .validate_params("route.somethingFromTheFuture", &json!({}))
            .is_err()
    );
}

#[test]
fn live_submit_still_rejects_an_unknown_param_at_the_schema_boundary() {
    // Replay does not validate params; LIVE submit does
    // (`additionalProperties: false`). Both halves of §9.2 pinned.
    let cat = timeline_core::Catalog::get();
    assert!(cat
        .validate_params(
            "clip.move",
            &json!({"clipId": "c", "trackId": "t", "startTicks": 0, "zap": 1})
        )
        .is_err());
}

/// Design §4's flagged second-order risk: "if any future dependency enables
/// serde_json's `preserve_order`, feature unification would silently change
/// `project.json` bytes. Add a build-time guard."
///
/// This is that guard. With `preserve_order` OFF, `serde_json::Map` IS a
/// `BTreeMap` and iterates in sorted key order; with it ON it becomes an
/// IndexMap and iterates in insertion order. Nothing errors — the checkpoint
/// just starts serializing different bytes for the same project, which is
/// exactly the silent-degradation class this design exists to prevent.
///
/// (The hash chain itself is safe either way: `write_canonical` sorts keys
/// explicitly at every level. This protects `project.json` byte-stability and
/// the `extra`-map round-trips.)
#[test]
fn serde_json_preserve_order_is_off() {
    let v: Value = serde_json::from_str(r#"{"z":1,"a":2,"m":3}"#).unwrap();
    let keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
    assert_eq!(
        keys,
        ["a", "m", "z"],
        "serde_json's `preserve_order` feature has been enabled somewhere in the \
         dependency graph. Map iteration is now insertion-ordered, so project.json \
         will silently serialize different bytes for the same project. Find the \
         dependency that turned it on and turn it back off."
    );
}

// ---------------------------------------------------------------------------
// §6 proposal 1 / §9.4 — float canonicalization, formalized
// ---------------------------------------------------------------------------

#[test]
fn num_preserves_the_exact_token_so_2_is_not_2_point_0() {
    // `Num` wraps serde_json::Number and preserves what the wire said. This is
    // the rule, written down: parameter values on the wire are Num, never
    // f32/f64, and an integer-shaped literal never becomes "2.0".
    let two: Num = serde_json::from_str("2").unwrap();
    let two_point_oh: Num = serde_json::from_str("2.0").unwrap();
    assert_eq!(serde_json::to_string(&two).unwrap(), "2");
    assert_eq!(serde_json::to_string(&two_point_oh).unwrap(), "2.0");
    assert_ne!(
        serde_json::to_string(&two).unwrap(),
        serde_json::to_string(&two_point_oh).unwrap(),
        "the TOKEN differs, which is what the hash sees"
    );
    // CORRECTION to design §9.4, which states "Num's PartialEq compares
    // as_f64() (num.rs:47)". That is only the BOTH-FLOAT branch. `Num`'s
    // PartialEq is SHAPE-AWARE: a cross-shape comparison returns false
    // outright (num.rs:39-49). So `2` and `2.0` are unequal in the model too,
    // and model equality already tracks hash identity across the integer/float
    // boundary.
    assert_ne!(two, two_point_oh, "shape-aware equality: 2 is not 2.0");
    assert!(two.is_integer_shaped());
    assert!(!two_point_oh.is_integer_shaped());
}

#[test]
fn the_negative_zero_hazard_is_real_between_floats_and_does_not_reach_the_omit_path() {
    // §9.7 flags this as DERIVED, not test-covered, and asks for verification
    // "before writing it into law". Verified — and the derivation is HALF right.
    //
    // TRUE: two FLOAT-shaped values -0.0 and 0.0 are model-equal but hash
    // differently.
    let zero: Num = serde_json::from_str("0.0").unwrap();
    let neg_zero: Num = serde_json::from_str("-0.0").unwrap();
    assert_eq!(zero, neg_zero, "both float-shaped, so PartialEq goes via as_f64");
    assert_ne!(
        serde_json::to_string(&zero).unwrap(),
        serde_json::to_string(&neg_zero).unwrap(),
        "but the canonical TEXT differs, so the two hash differently"
    );
    assert_eq!(serde_json::to_string(&neg_zero).unwrap(), "-0.0");

    // FALSE at the site §9.4 names: the "omit when equal to default" paths in
    // package.rs compare against INTEGER-shaped defaults (`Num::int(0)`), and
    // Num's PartialEq is shape-aware, so a -0.0 is NOT dropped as if it were 0.
    assert_ne!(
        Num::int(0),
        neg_zero,
        "an integer-shaped default never compares equal to a float -0.0, so the \
         checkpoint writer keeps it"
    );
}

#[test]
fn a_negative_zero_gain_survives_the_checkpoint_rather_than_being_omitted() {
    // The end-to-end form of the claim above, at the actual site.
    use timeline_core::model::{Project, Track};
    use timeline_core::package::{from_project_json, to_project_json};
    use timeline_core::session::Session;
    use timeline_core::tempo::{Bpm, TempoMap};

    let mut p = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    let mut t = Track::new("t1", "Track 1");
    t.gain = serde_json::from_str("-0.0").unwrap();
    p.tracks.push(t);

    let out = to_project_json(&Session::new(p));
    assert_eq!(
        out["tracks"][0]["gainDb"],
        json!(-0.0),
        "a -0.0 gain must not be dropped as 'equal to the default'"
    );
    let back = from_project_json(&out).unwrap();
    assert_eq!(
        serde_json::to_string(&back.tracks[0].gain).unwrap(),
        "-0.0",
        "and it must survive the reload with its sign"
    );
}

#[test]
fn nan_and_infinity_are_unrepresentable_on_the_wire() {
    // §9.7 lists this as derived. serde_json::Number::from_f64 returns None for
    // non-finite values, so a NaN/±inf can never reach a journal payload.
    assert!(serde_json::Number::from_f64(f64::NAN).is_none());
    assert!(serde_json::Number::from_f64(f64::INFINITY).is_none());
    assert!(serde_json::Number::from_f64(f64::NEG_INFINITY).is_none());
    // And they do not parse either.
    for text in ["NaN", "Infinity", "-Infinity", "nan", "inf"] {
        assert!(
            serde_json::from_str::<Num>(text).is_err(),
            "{text} must not parse as a Num"
        );
    }
    // -0.0 DOES survive from_f64, which is exactly why it needs its own test.
    assert!(serde_json::Number::from_f64(-0.0).is_some());
}

#[test]
fn the_pinned_float_rule_normalizes_the_token_but_never_the_shape() {
    // Deferred proposal 1 was "formalize EXISTING behavior", and §9.4 warned
    // there was no single existing behavior. This is what it actually is, now
    // written into contracts/README.md rule 4 and enforced in both languages:
    //
    //   integer-shaped -> plain digits, byte-for-byte unchanged
    //   float-shaped   -> SHORTEST ROUND-TRIP decimal (so the token IS
    //                     normalized: 1e3 becomes 1000.0)
    //
    // What is preserved is the SHAPE, not the spelling.
    for (text, expected) in [
        // integer-shaped: never touched, never floated
        ("1000", "1000"),
        ("-6", "-6"),
        ("0", "0"),
        // float-shaped: shortest round-trip
        ("1e3", "1000.0"),
        ("1.0e3", "1000.0"),
        ("1.50", "1.5"),
        ("0.001", "0.001"),
        ("1e-3", "0.001"),
        ("-0.0", "-0.0"),
        ("2.0", "2.0"),
    ] {
        let n: Num = serde_json::from_str(text)
            .unwrap_or_else(|e| panic!("{text} should parse: {e}"));
        let canon = canonical_json(&json!({ "value": n })).expect("finite floats canonicalize");
        assert_eq!(
            canon,
            format!("{{\"value\":{expected}}}"),
            "canonical form of {text}"
        );
    }
}

#[test]
fn a_fractional_param_survives_the_journal_round_trip_bit_exactly() {
    // The float_roundtrip feature is load-bearing: the journal hashes the
    // canonical text on append and RE-PARSES it on reopen, so a 1-ULP parse
    // asymmetry breaks the chain. This is the property, at the envelope level.
    for text in [
        "120.00000000000003",
        "0.1",
        "1.7976931348623157e308",
        "5e-324",
        "-0.0",
    ] {
        let params: Value = serde_json::from_str(&format!("{{\"bpm\":{text}}}")).unwrap();
        let env = Envelope {
            id: "10000000000000000000000001".into(),
            ts: "2026-07-24T00:00:00Z".into(),
            actor: timeline_core::Actor::user("t"),
            name: "project.setTempo".into(),
            params: params.clone(),
            inverse: None,
            result: json!({"ok": true}),
            hash: String::new(),
        }
        .finalize(timeline_core::GENESIS_HASH)
        .expect("finalizes");
        let line = env.to_jsonl();
        let back = Envelope::from_line(&line).expect("reparses");
        assert_eq!(back.hash, env.hash, "{text}: hash changed on reopen");
        assert_eq!(back.to_jsonl(), line, "{text}: bytes changed on reopen");
    }
}
