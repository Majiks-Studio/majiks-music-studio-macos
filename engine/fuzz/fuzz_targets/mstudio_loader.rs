#![no_main]

use libfuzzer_sys::fuzz_target;
use serde_json::Value;
use timeline_core::package::from_project_json;

fuzz_target!(|input: &[u8]| {
    if let Ok(value) = serde_json::from_slice::<Value>(input) {
        let _ = from_project_json(&value);
    }
});
