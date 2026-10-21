#![no_main]

use contracts_conformance::{schema_ref, validate};
use libfuzzer_sys::fuzz_target;
use serde_json::Value;

const DEFS: &[&str] = &[
    "generateRequest",
    "reviseRequest",
    "extendRequest",
    "layerRequest",
    "retakeRequest",
    "autocompleteRequest",
    "coverRequest",
    "separateRequest",
    "analyzeRequest",
    "finalizeRequest",
    "submitResponse",
    "analyzeResponse",
    "progressEvent",
    "terminalState",
    "capabilitiesResponse",
];

fuzz_target!(|input: &[u8]| {
    if let Ok(value) = serde_json::from_slice::<Value>(input) {
        // The schema is loaded once per process by the target harness. Invalid
        // JSON never reaches the validator, and validator errors are data.
        let schema_text = include_str!("../../contracts/gen-protocol.schemas.json");
        if let Ok(document) = serde_json::from_str::<Value>(schema_text) {
            for def in DEFS {
                let _ = validate(&schema_ref(&document, &format!("#/$defs/{def}")), &value);
            }
        }
    }
});
