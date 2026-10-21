//! Checks the claim made in src/types.rs's doc comment and in MAPPING.md:
//! `AnalyzeReport`'s JSON serialization contains the same field names as
//! `engine/contracts/gen-protocol.schemas.json`'s `analyzeResponse`
//! (`bpm`, `key`, `duration`, `downbeats`, `loudnessLufs`), so a consumer
//! can project one onto the other without a translation layer.
//!
//! This crate intentionally does NOT depend on `engine/contracts` (see
//! MAPPING.md), so this test hardcodes the five field names rather than
//! reading the schema file; if `analyzeResponse` changes at the next
//! contract revision, this is the test that will need a matching edit.

use media::types::AnalyzeReport;

#[test]
fn analyze_report_json_carries_every_gen_protocol_analyze_response_field() {
    let report = AnalyzeReport {
        bpm: Some(118.6),
        key: Some("E minor".to_string()),
        duration: Some(112.0),
        downbeats: Some(vec![0.5, 2.5]),
        loudness_lufs: Some(-14.2),
        content_hash: "deadbeef".to_string(),
        sample_rate: 48_000,
        source_sample_rate: 48_000,
        channels: 2,
        true_peak_dbtp: Some(-0.3),
        tempo: None,
        key_estimate: None,
        declared_bpm: Some(120.0),
        declared_vs_measured_pct: Some(-1.17),
    };

    let value = serde_json::to_value(&report).unwrap();
    let obj = value.as_object().expect("AnalyzeReport must serialize to a JSON object");

    for field in ["bpm", "key", "duration", "downbeats", "loudnessLufs"] {
        assert!(obj.contains_key(field), "AnalyzeReport JSON is missing gen-protocol analyzeResponse field {field:?}: {obj:?}");
    }

    assert_eq!(obj["bpm"], serde_json::json!(118.6));
    assert_eq!(obj["key"], serde_json::json!("E minor"));
    assert_eq!(obj["duration"], serde_json::json!(112.0));
    assert_eq!(obj["downbeats"], serde_json::json!([0.5, 2.5]));
    assert_eq!(obj["loudnessLufs"], serde_json::json!(-14.2));
}

#[test]
fn analyze_response_fields_are_null_when_absent_not_missing() {
    // gen-protocol.schemas.json declares bpm/key/duration/downbeats/
    // loudnessLufs as `oneOf [null, <type>]`, i.e. present-but-null, not
    // omitted. `Option<T>` with serde's default behavior (no
    // `skip_serializing_if`) serializes `None` as JSON `null`, matching
    // that contract.
    let report = AnalyzeReport {
        bpm: None,
        key: None,
        duration: None,
        downbeats: None,
        loudness_lufs: None,
        content_hash: "deadbeef".to_string(),
        sample_rate: 48_000,
        source_sample_rate: 48_000,
        channels: 2,
        true_peak_dbtp: None,
        tempo: None,
        key_estimate: None,
        declared_bpm: None,
        declared_vs_measured_pct: None,
    };
    let value = serde_json::to_value(&report).unwrap();
    let obj = value.as_object().unwrap();
    for field in ["bpm", "key", "duration", "downbeats", "loudnessLufs"] {
        assert!(obj.contains_key(field), "field {field:?} must be present-as-null, not omitted");
        assert!(obj[field].is_null(), "field {field:?} should serialize to null when absent");
    }
}
