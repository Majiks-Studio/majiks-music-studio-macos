//! Integration tests: load the real files under `engine/contracts/` (schemas
//! + fixtures, not synthetic in-test data) and validate them. Run with
//! `cargo test` from `engine/contracts/conformance/`.
//!
//! The journal hash-chain tests here are also this lane's cross-language
//! proof: `fixtures/project/minimal-journal.jsonl`'s `hash` fields were
//! written by the Python fixture generator
//! (`fixtures/tools/generate_fixtures.py`, using `conformance_py/canonical.py`
//! + the compiled or pure-Python `blake3`). This crate's independently
//! written `canonical_json_bytes`/`compute_entry_hash` (`src/lib.rs`)
//! reproducing those exact stored hashes is the proof the two
//! implementations of "Canonicalization and the hash chain" (README.md)
//! actually agree, not just that each one is internally self-consistent.

use contracts_conformance::{
    compute_entry_hash, schema_ref, validate, verify_chain, GENESIS_HASH,
};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

fn contracts_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..")
}

/// The catalog the engine actually embeds (`timeline-core/src/catalog.rs`
/// `include_str!`). Design §9.6: this suite used to validate
/// `command-catalog.v1.json` while the engine embedded v1.1, so the file
/// that IS law was never schema-checked and had 16 latent violations.
/// Keep this pointed at whatever `catalog.rs` includes.
const EMBEDDED_CATALOG: &str = "command-catalog.v2.json";

fn load_json(rel: &str) -> Value {
    let path = contracts_dir().join(rel);
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parsing {path:?}: {e}"))
}

fn load_journal_lines(rel: &str) -> Vec<Value> {
    let path = contracts_dir().join(rel);
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {path:?}: {e}"));
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("parsing journal line: {e}")))
        .collect()
}

fn catalog_by_name(catalog: &Value) -> HashMap<String, Value> {
    catalog["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| (c["name"].as_str().unwrap().to_string(), c.clone()))
        .collect()
}

/// Mirrors `test_conformance.py`'s `full_validate_envelope`: envelope shape,
/// then catalog cross-reference (name exists, params match that command's
/// paramsSchema), then undoable/inverse consistency.
fn full_validate_envelope(
    envelope: &Value,
    catalog_schema: &Value,
    by_name: &HashMap<String, Value>,
) -> Vec<String> {
    let envelope_schema = schema_ref(catalog_schema, "#/$defs/commandEnvelope");
    let shape_errors = validate(&envelope_schema, envelope);
    if !shape_errors.is_empty() {
        return shape_errors.iter().map(|e| format!("shape: {e}")).collect();
    }

    let name = envelope["name"].as_str().unwrap();
    let cmd = match by_name.get(name) {
        Some(c) => c,
        None => return vec![format!("catalog: unknown command name '{name}'")],
    };

    let mut errors = Vec::new();
    for e in validate(&cmd["paramsSchema"], &envelope["params"]) {
        errors.push(format!("params: {e}"));
    }

    let undoable = cmd["undoable"].as_bool().unwrap();
    let inverse = &envelope["inverse"];
    if undoable && inverse.is_null() {
        errors.push("inverse: catalog says undoable=true but envelope inverse is null".to_string());
    }
    if !undoable && !inverse.is_null() {
        errors.push("inverse: catalog says undoable=false but envelope inverse is non-null".to_string());
    }
    if !inverse.is_null() {
        let inv_name = inverse["name"].as_str().unwrap_or("");
        match by_name.get(inv_name) {
            None => errors.push(format!("inverse: inverse.name '{inv_name}' is not a catalog command")),
            Some(inv_cmd) => {
                for e in validate(&inv_cmd["paramsSchema"], &inverse["params"]) {
                    errors.push(format!("inverse.params: {e}"));
                }
            }
        }
    }
    errors
}

// ---------------------------------------------------------------------------
// command-catalog.v2.json (the file the engine EMBEDS) / .schema.json
// ---------------------------------------------------------------------------

#[test]
fn catalog_validates_against_schema() {
    let schema = load_json("command-catalog.schema.json");
    let catalog = load_json(EMBEDDED_CATALOG);
    let sub = schema_ref(&schema, "#/$defs/catalogDocument");
    let errors = validate(&sub, &catalog);
    assert!(errors.is_empty(), "{errors:#?}");
}

#[test]
fn catalog_has_no_duplicate_names() {
    let catalog = load_json(EMBEDDED_CATALOG);
    let names: Vec<&str> = catalog["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap())
        .collect();
    let unique: std::collections::HashSet<&str> = names.iter().copied().collect();
    assert_eq!(names.len(), unique.len(), "duplicate command name(s) in catalog");
}

#[test]
fn catalog_has_expected_command_count() {
    // v1:   67 bulleted in 02-ARCH section 4 + gen.landed + txn.begin/txn.commit
    //       (all named in section 4's prose) + marker.remove (P0-C proposal 1,
    //       APPROVED by the coordinating session 2026-07-11) = 71.
    // v1.1: + clip.phaseAnchor.set, take.purge, take.restore, the midi.* wave
    //       and the record.* wave = 87.
    // v2:   + project.setPhaseAnchor and the five route.* commands = 93.
    assert_eq!(
        load_json("command-catalog.v1.json")["commands"]
            .as_array()
            .unwrap()
            .len(),
        71,
        "v1 is frozen"
    );
    assert_eq!(
        load_json("command-catalog.v1.1.json")["commands"]
            .as_array()
            .unwrap()
            .len(),
        87,
        "v1.1 is frozen"
    );
    let catalog = load_json(EMBEDDED_CATALOG);
    assert_eq!(catalog["commands"].as_array().unwrap().len(), 119);
}

/// Design §9.6: the FROZEN predecessors must keep validating too, so a schema
/// edit made for v2 cannot quietly invalidate history. v1.1 is the known
/// exception — see `v1_1_has_a_known_pre_existing_schema_violation`.
#[test]
fn frozen_v1_catalog_still_validates() {
    let schema = load_json("command-catalog.schema.json");
    let sub = schema_ref(&schema, "#/$defs/catalogDocument");
    let errors = validate(&sub, &load_json("command-catalog.v1.json"));
    assert!(errors.is_empty(), "{errors:#?}");
}

/// v1.1 fails its own schema: the 8 `midi.*` commands are `undoable:false`,
/// non-transport, and omit the conditionally-required `nonUndoableReason`.
/// This was invisible because the suite validated v1.json while the engine
/// embedded v1.1.json. v1.1 is frozen, so v2 carries the fix; this test pins
/// the defect so it cannot be "fixed" by editing the frozen file.
#[test]
fn v1_1_has_a_known_pre_existing_schema_violation() {
    let schema = load_json("command-catalog.schema.json");
    let sub = schema_ref(&schema, "#/$defs/catalogDocument");
    let errors = validate(&sub, &load_json("command-catalog.v1.1.json"));
    assert_eq!(
        errors.len(),
        8,
        "expected exactly the 8 midi nonUndoableReason violations, got {errors:#?}"
    );
    assert!(
        errors
            .iter()
            .all(|e| e.contains("nonUndoableReason")),
        "{errors:#?}"
    );
}

#[test]
fn every_params_schema_compiles() {
    let catalog = load_json(EMBEDDED_CATALOG);
    for c in catalog["commands"].as_array().unwrap() {
        let errors = validate(&c["paramsSchema"], &Value::Object(Default::default()));
        // We don't care whether {} is valid against this particular params
        // schema (most require fields); we only care that `validate` did not
        // report a *compile* failure, which is the one error string it
        // synthesizes itself rather than getting from the validator.
        let compile_failed = errors.iter().any(|e| e.starts_with("schema failed to compile"));
        assert!(!compile_failed, "{}: {:?}", c["name"], errors);
    }
}

#[test]
fn undoable_inverse_mode_consistency() {
    let catalog = load_json(EMBEDDED_CATALOG);
    for c in catalog["commands"].as_array().unwrap() {
        let undoable = c["undoable"].as_bool().unwrap();
        let mode = c["inverseRule"]["mode"].as_str().unwrap();
        if undoable {
            assert!(mode == "self" || mode == "explicit", "{}", c["name"]);
        } else {
            assert_eq!(mode, "none", "{}", c["name"]);
        }
    }
}

#[test]
fn transport_commands_unjournaled_and_not_undoable() {
    let catalog = load_json(EMBEDDED_CATALOG);
    for c in catalog["commands"].as_array().unwrap() {
        if c["category"] == "transport" {
            assert_eq!(c["journaled"], false, "{}", c["name"]);
            assert_eq!(c["undoable"], false, "{}", c["name"]);
        }
    }
}

// ---------------------------------------------------------------------------
// project.schema.json
// ---------------------------------------------------------------------------

#[test]
fn project_schema_is_forward_compatible() {
    let schema = load_json("project.schema.json");
    assert_eq!(schema["additionalProperties"], true);
}

#[test]
fn project_fixture_validates() {
    let schema = load_json("project.schema.json");
    let project = load_json("fixtures/project/minimal-project.json");
    let errors = validate(&schema, &project);
    assert!(errors.is_empty(), "{errors:#?}");
}

#[test]
fn project_fixture_tolerates_unknown_fields() {
    let schema = load_json("project.schema.json");
    let mut project = load_json("fixtures/project/minimal-project.json");
    project
        .as_object_mut()
        .unwrap()
        .insert("futureFieldFromV2".to_string(), serde_json::json!({"anything": true}));
    let errors = validate(&schema, &project);
    assert!(errors.is_empty(), "forward-compat broke: {errors:#?}");
}

// ---------------------------------------------------------------------------
// fixtures/project/: the hash chain (cross-language proof)
// ---------------------------------------------------------------------------

#[test]
fn journal_has_30_entries() {
    let entries = load_journal_lines("fixtures/project/minimal-journal.jsonl");
    assert_eq!(entries.len(), 30);
}

#[test]
fn journal_hash_chain_verifies_against_python_generated_hashes() {
    let entries = load_journal_lines("fixtures/project/minimal-journal.jsonl");
    match verify_chain(&entries) {
        Ok((tip, count)) => {
            assert_eq!(count, 30);
            assert_eq!(tip.len(), 64);
        }
        Err((index, expected)) => {
            panic!(
                "chain broke at entry {index}: Rust recomputed {expected} but the \
                 Python-generated fixture stored a different hash there"
            );
        }
    }
}

/// Catalog v2, deferred proposal 1 (ACCEPTED) + design §9.4.
///
/// The float half of the canonicalization rule used to be DEFERRED, and both
/// this crate and `conformance_py` hard-rejected floats — so a real project
/// with a fractional gain produced a journal this suite could not hash at all,
/// while `timeline-core` happily emitted one. That is a cross-language
/// integrity gap, not a doc nicety.
///
/// `float-journal.jsonl`'s hashes were written by `conformance_py`. This crate
/// reaching the same tip with its own independent canonicalizer is the proof
/// the two implementations agree on floats, not just on integers.
#[test]
fn float_journal_chain_verifies_against_python_generated_hashes() {
    let entries = load_journal_lines("fixtures/project/float-journal.jsonl");
    assert_eq!(entries.len(), 8);
    match verify_chain(&entries) {
        Ok((tip, count)) => {
            assert_eq!(count, 8);
            assert_eq!(
                tip, "58436fe927fa6097a17536a2ac25cc8f1aa379f65dd4736637e4ac28abf9b799",
                "Rust and Python disagree on canonical float text"
            );
        }
        Err((index, expected)) => panic!(
            "float chain broke at entry {index}: Rust recomputed {expected} but the \
             Python-generated fixture stored a different hash there"
        ),
    }
}

#[test]
fn float_journal_entries_validate_against_the_catalog() {
    let schema = load_json("command-catalog.schema.json");
    let catalog = load_json(EMBEDDED_CATALOG);
    let by_name = catalog_by_name(&catalog);
    for e in load_journal_lines("fixtures/project/float-journal.jsonl") {
        let errors = full_validate_envelope(&e, &schema, &by_name);
        assert!(errors.is_empty(), "{}: {errors:#?}", e["id"]);
    }
}

#[test]
fn canonical_float_rule_normalizes_the_token_but_never_the_shape() {
    use contracts_conformance::canonical_json_bytes;
    let c = |v: Value| String::from_utf8(canonical_json_bytes(&v).unwrap()).unwrap();
    // Shortest round-trip.
    assert_eq!(c(serde_json::json!({"v": 1e3})), r#"{"v":1000.0}"#);
    assert_eq!(c(serde_json::json!({"v": 1.50})), r#"{"v":1.5}"#);
    // The integer/float SHAPE is never changed.
    assert_eq!(
        c(serde_json::from_str::<Value>(r#"{"v":2}"#).unwrap()),
        r#"{"v":2}"#
    );
    assert_eq!(
        c(serde_json::from_str::<Value>(r#"{"v":2.0}"#).unwrap()),
        r#"{"v":2.0}"#
    );
    // -0.0 is a distinct token and therefore a distinct hash.
    assert_eq!(c(serde_json::json!({"v": -0.0})), r#"{"v":-0.0}"#);
    assert_ne!(
        c(serde_json::json!({"v": -0.0})),
        c(serde_json::json!({"v": 0.0}))
    );
}

#[test]
fn journal_first_entry_chains_from_genesis() {
    let entries = load_journal_lines("fixtures/project/minimal-journal.jsonl");
    let first = entries[0].as_object().unwrap();
    let recomputed = compute_entry_hash(GENESIS_HASH, first).unwrap();
    assert_eq!(recomputed, first["hash"].as_str().unwrap());
}

#[test]
fn journal_tamper_detection() {
    let mut entries = load_journal_lines("fixtures/project/minimal-journal.jsonl");
    entries[5]["params"]["color"] = Value::String("#000000".to_string());
    let result = verify_chain(&entries);
    match result {
        Ok(_) => panic!("tampering with entry 5 should have broken the chain"),
        Err((index, _)) => assert_eq!(index, 5),
    }
}

#[test]
fn journal_checkpoint_matches_project_json() {
    let entries = load_journal_lines("fixtures/project/minimal-journal.jsonl");
    let project = load_json("fixtures/project/minimal-project.json");
    let (tip, count) = verify_chain(&entries).expect("chain must verify");
    let j = &project["journal"];
    assert_eq!(j["entryCount"].as_u64().unwrap() as usize, count);
    assert_eq!(j["tipHash"].as_str().unwrap(), tip);
    assert_eq!(j["tipId"].as_str().unwrap(), entries.last().unwrap()["id"].as_str().unwrap());
    assert_eq!(j["genesisHash"].as_str().unwrap(), GENESIS_HASH);
}

#[test]
fn journal_txn_begin_commit_pairing() {
    let entries = load_journal_lines("fixtures/project/minimal-journal.jsonl");
    let mut open_txn: Option<String> = None;
    for e in &entries {
        let name = e["name"].as_str().unwrap();
        if name == "txn.begin" {
            assert!(open_txn.is_none(), "nested txn.begin while {open_txn:?} still open");
            open_txn = Some(e["params"]["txnId"].as_str().unwrap().to_string());
        } else if name == "txn.commit" {
            let id = e["params"]["txnId"].as_str().unwrap().to_string();
            assert_eq!(open_txn.as_deref(), Some(id.as_str()));
            open_txn = None;
        }
    }
    assert!(open_txn.is_none(), "journal ends with an unclosed txn: {open_txn:?}");
}

#[test]
fn every_journal_entry_is_a_journaled_catalog_command() {
    let catalog = load_json(EMBEDDED_CATALOG);
    let by_name = catalog_by_name(&catalog);
    let entries = load_journal_lines("fixtures/project/minimal-journal.jsonl");
    for e in &entries {
        let name = e["name"].as_str().unwrap();
        let cmd = by_name.get(name).unwrap_or_else(|| panic!("{name} not in catalog"));
        assert_eq!(cmd["journaled"], true, "{name} appears in journal but is journaled:false");
    }
}

#[test]
fn every_journal_entry_fully_validates() {
    let catalog_schema = load_json("command-catalog.schema.json");
    let catalog = load_json(EMBEDDED_CATALOG);
    let by_name = catalog_by_name(&catalog);
    let entries = load_journal_lines("fixtures/project/minimal-journal.jsonl");
    for e in &entries {
        let errors = full_validate_envelope(e, &catalog_schema, &by_name);
        assert!(errors.is_empty(), "{}: {:?}", e["id"], errors);
    }
}

// ---------------------------------------------------------------------------
// fixtures/commands/valid/ + invalid/
// ---------------------------------------------------------------------------

#[test]
fn valid_command_fixtures_all_pass() {
    let catalog_schema = load_json("command-catalog.schema.json");
    let catalog = load_json(EMBEDDED_CATALOG);
    let by_name = catalog_by_name(&catalog);
    let manifest = load_json("fixtures/commands/valid/manifest.json");
    let fixtures = manifest["fixtures"].as_array().unwrap();
    // 12 original + marker_remove.json (P0-C proposal 1, APPROVED 2026-07-11).
    assert_eq!(fixtures.len(), 13);

    for item in fixtures {
        let file = item["file"].as_str().unwrap();
        let envelope = load_json(&format!("fixtures/commands/valid/{file}"));
        let errors = full_validate_envelope(&envelope, &catalog_schema, &by_name);
        assert!(errors.is_empty(), "{file}: {errors:?}");
    }
}

#[test]
fn gen_finalize_valid_fixture_has_draft_take_id_and_quality_rung() {
    let envelope = load_json("fixtures/commands/valid/gen_finalize.json");
    assert_eq!(envelope["name"], "gen.finalize");
    assert!(envelope["params"]["draftTakeId"].is_string());
    assert!(envelope["params"]["targetQualityRung"].is_string());
}

#[test]
fn invalid_command_fixtures_all_fail_for_the_expected_reason() {
    let catalog_schema = load_json("command-catalog.schema.json");
    let catalog = load_json(EMBEDDED_CATALOG);
    let by_name = catalog_by_name(&catalog);
    let manifest = load_json("fixtures/commands/invalid/manifest.json");
    let fixtures = manifest["fixtures"].as_array().unwrap();
    assert_eq!(fixtures.len(), 12);

    let mut expected_tag: BTreeMap<&str, &str> = BTreeMap::new();
    expected_tag.insert("unknown_command_name.json", "catalog:");
    expected_tag.insert("missing_required_field.json", "shape:");
    expected_tag.insert("bad_id_format.json", "shape:");
    expected_tag.insert("bad_hash_format.json", "shape:");
    expected_tag.insert("bad_timestamp_format.json", "shape:");
    expected_tag.insert("bad_actor_kind.json", "shape:");
    expected_tag.insert("params_wrong_type.json", "params:");
    expected_tag.insert("params_missing_required.json", "params:");
    expected_tag.insert("undoable_missing_inverse.json", "inverse:");
    expected_tag.insert("nonundoable_has_inverse.json", "inverse:");
    expected_tag.insert("additional_properties_rejected.json", "shape:");
    expected_tag.insert("result_ok_false_missing_error.json", "shape:");
    assert_eq!(expected_tag.len(), 12);

    for item in fixtures {
        let file = item["file"].as_str().unwrap();
        let envelope = load_json(&format!("fixtures/commands/invalid/{file}"));
        let errors = full_validate_envelope(&envelope, &catalog_schema, &by_name);
        assert!(!errors.is_empty(), "{file} was expected to be invalid but validated cleanly");
        let tag = expected_tag.get(file).unwrap_or_else(|| panic!("no expected tag registered for {file}"));
        assert!(
            errors.iter().any(|e| e.starts_with(*tag)),
            "{file}: expected an error tagged '{tag}', got {errors:?}"
        );
    }
}

// ---------------------------------------------------------------------------
// fixtures/gen-protocol/
// ---------------------------------------------------------------------------

#[test]
fn gen_protocol_schemas_compile() {
    let schemas = load_json("gen-protocol.schemas.json");
    // A schema that trivially fails to compile would error on every $ref;
    // spot check a few defs compile and validate a minimal instance.
    for def in ["generateRequest", "reviseRequest", "analyzeResponse", "finalizeRequest", "submitResponse"] {
        let sub = schema_ref(&schemas, &format!("#/$defs/{def}"));
        // Validating `null` should never itself panic or report a compile error.
        let errors = validate(&sub, &Value::Null);
        let compile_failed = errors.iter().any(|e| e.starts_with("schema failed to compile"));
        assert!(!compile_failed, "{def}: {errors:?}");
    }
}

#[test]
fn gen_protocol_fixture_pairs_validate() {
    let schemas = load_json("gen-protocol.schemas.json");
    let manifest = load_json("fixtures/gen-protocol/manifest.json");
    let pairs = manifest["pairs"].as_array().unwrap();
    assert_eq!(pairs.len(), 3);

    let req_def_by_op: HashMap<&str, &str> = HashMap::from([
        ("generate", "generateRequest"),
        ("revise", "reviseRequest"),
        ("analyze", "analyzeRequest"),
    ]);
    let resp_def_by_op: HashMap<&str, &str> = HashMap::from([
        ("generate", "submitResponse"),
        ("revise", "submitResponse"),
        ("analyze", "analyzeResponse"),
    ]);

    for pair in pairs {
        let op = pair["op"].as_str().unwrap();
        let req_file = pair["request"].as_str().unwrap();
        let resp_file = pair["response"].as_str().unwrap();
        let req = load_json(&format!("fixtures/gen-protocol/{req_file}"));
        let resp = load_json(&format!("fixtures/gen-protocol/{resp_file}"));

        let req_schema = schema_ref(&schemas, &format!("#/$defs/{}", req_def_by_op[op]));
        let resp_schema = schema_ref(&schemas, &format!("#/$defs/{}", resp_def_by_op[op]));
        let req_errors = validate(&req_schema, &req);
        let resp_errors = validate(&resp_schema, &resp);
        assert!(req_errors.is_empty(), "{op} request: {req_errors:?}");
        assert!(resp_errors.is_empty(), "{op} response: {resp_errors:?}");

        if resp.get("jobId").is_some() {
            assert_eq!(resp["jobId"], req["requestId"], "{op}: jobId must echo requestId");
        }
    }
}

#[test]
fn analyze_response_gap_fields_are_null() {
    let manifest = load_json("fixtures/gen-protocol/manifest.json");
    let pairs = manifest["pairs"].as_array().unwrap();
    let analyze_pair = pairs.iter().find(|p| p["op"] == "analyze").unwrap();
    let resp = load_json(&format!(
        "fixtures/gen-protocol/{}",
        analyze_pair["response"].as_str().unwrap()
    ));
    assert!(resp["downbeats"].is_null());
    assert!(resp["loudnessLufs"].is_null());
}
