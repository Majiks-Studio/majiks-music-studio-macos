//! Schema round-trip and malformed-input properties for every Gen Protocol
//! operation. The YAML operation wiring is mirrored by the standalone JSON
//! schemas, which are the machine-readable source used by both test runners.

use contracts_conformance::{schema_ref, validate};
use proptest::prelude::*;
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;

fn contracts_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .to_path_buf()
}

fn schemas() -> Value {
    serde_json::from_str(
        &fs::read_to_string(contracts_dir().join("gen-protocol.schemas.json")).unwrap(),
    )
    .unwrap()
}

fn ulid() -> Value {
    json!("400000000000000000000008WD")
}

fn samples() -> Vec<(&'static str, Value)> {
    let req = |extra: Value| {
        let mut v = extra.as_object().unwrap().clone();
        v.insert("requestId".into(), ulid());
        Value::Object(v)
    };
    vec![
        (
            "generateRequest",
            req(json!({"caption":"warm","durationSeconds":120})),
        ),
        (
            "reviseRequest",
            req(
                json!({"sourceAudioRef":"clip","regionStartSeconds":1,"regionEndSeconds":2,"instruction":"brighter"}),
            ),
        ),
        (
            "extendRequest",
            req(json!({"sourceAudioRef":"clip","addedDurationSeconds":1.5})),
        ),
        ("layerRequest", req(json!({"instruction":"bass"}))),
        ("retakeRequest", req(json!({"sourceTakeId":"take"}))),
        (
            "autocompleteRequest",
            req(json!({"sourceAudioRef":"clip","caption":"fill drums"})),
        ),
        (
            "coverRequest",
            req(json!({"referenceAudioRef":"clip","caption":"jazz","coverStrength":0.5})),
        ),
        (
            "separateRequest",
            req(json!({"sourceAudioRef":"clip","engine":"demucs"})),
        ),
        (
            "analyzeRequest",
            req(json!({"sourceAudioRef":"clip","mode":"fast"})),
        ),
        (
            "finalizeRequest",
            req(
                json!({"draftTakeId":"take","targetQualityRung":"full","request":{"requestId":"400000000000000000000008WD","sourceAudioRef":"clip","regionStartSeconds":1,"regionEndSeconds":2,"instruction":"full"}}),
            ),
        ),
        (
            "submitResponse",
            json!({"jobId":"400000000000000000000008WD"}),
        ),
        (
            "analyzeResponse",
            json!({"bpm":120.0,"key":"C major","duration":30.0,"downbeats":null,"loudnessLufs":null}),
        ),
        (
            "progressEvent",
            json!({"jobId":"400000000000000000000008WD","stage":"running","percent":50,"message":"working","variant":null}),
        ),
        (
            "terminalState",
            json!({"state":"cancelled","jobId":"400000000000000000000008WD"}),
        ),
        (
            "capabilitiesResponse",
            json!({"endpoints":[{"route":"local-mlx","ops":["generate"],"models":["acestep"],"concurrentSlots":1}]}),
        ),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn every_gen_schema_survives_json_round_trip(jitter in 0u32..64) {
        let document = schemas();
        let _ = jitter; // deterministic repetitions still exercise every definition
        for (def, value) in samples() {
            let schema = schema_ref(&document, &format!("#/$defs/{def}"));
            prop_assert!(validate(&schema, &value).is_empty(), "{def} invalid: {:?}", validate(&schema, &value));
            let encoded = serde_json::to_vec(&value).unwrap();
            let decoded: Value = serde_json::from_slice(&encoded).unwrap();
            prop_assert_eq!(value, decoded.clone());
            prop_assert!(validate(&schema, &decoded).is_empty());
        }
    }

    #[test]
    fn malformed_gen_values_are_rejected_without_panics(_index in 0usize..15) {
        let document = schemas();
        for (def, value) in samples() {
            let schema = schema_ref(&document, &format!("#/$defs/{def}"));
            let mut malformed = value;
            if let Some(object) = malformed.as_object_mut() {
                let required = document["$defs"][def]["required"]
                    .as_array()
                    .and_then(|fields| fields.first())
                    .and_then(Value::as_str);
                if let Some(required) = required {
                    object.remove(required);
                } else {
                    object.insert("unexpectedQaField".into(), Value::Null);
                }
            } else {
                malformed = Value::Null;
            }
            let errors = validate(&schema, &malformed);
            prop_assert!(!errors.is_empty(), "{def} accepted malformed {malformed}");
        }
    }
}
