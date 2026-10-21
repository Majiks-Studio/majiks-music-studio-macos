//! Conformance against `engine/contracts/`: the catalog, the fixtures, and the
//! canonicalization/hash-chain spec. These are the tests that let the frozen
//! contracts cross-check this implementation.

#[path = "support.rs"]
mod support;

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde_json::Value;
use timeline_core::catalog::Catalog;
use timeline_core::cmd::Cmd;
use timeline_core::envelope::{canonical_json, Envelope};
use timeline_core::journal::verify_lines;
use timeline_core::package::from_project_json;
use timeline_core::session::Session;
use timeline_core::tempo::Bpm;
use timeline_core::{Project, TempoMap};

fn contracts_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../contracts")
}

fn read(path: PathBuf) -> String {
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

#[test]
fn all_v1_1_catalog_commands_are_covered_and_valid() {
    let catalog = Catalog::get();
    assert_eq!(catalog.len(), 119, "catalog v2 must have 119 commands");

    let reps = support::representative_commands();
    assert_eq!(reps.len(), 119, "coverage table must list all 119 commands");

    let catalog_names: BTreeSet<&str> = catalog.names().iter().map(String::as_str).collect();
    let rep_names: BTreeSet<&str> = reps.iter().map(|(n, _)| *n).collect();
    assert_eq!(
        catalog_names, rep_names,
        "coverage table names must equal the catalog exactly"
    );

    for (name, params) in &reps {
        // params validate against the frozen catalog schema
        catalog
            .validate_params(name, params)
            .unwrap_or_else(|e| panic!("{name} representative params invalid: {e}"));
        // typed parse round-trips and the name matches
        let cmd = Cmd::from_wire(name, params.clone())
            .unwrap_or_else(|e| panic!("{name} does not parse into Cmd: {e}"));
        assert_eq!(cmd.name(), *name, "Cmd::name mismatch for {name}");
        // the emitted params re-validate (round-trip stable)
        catalog
            .validate_params(name, &cmd.params_value())
            .unwrap_or_else(|e| panic!("{name} re-emitted params invalid: {e}"));
    }
}

#[test]
fn canonicalization_is_byte_identical_to_the_contracts_crate() {
    // Cross-check every fixture journal entry's hashed payload, plus a few
    // adversarial values, against the P0-C conformance crate's canonicalizer.
    let journal = read(contracts_dir().join("fixtures/project/minimal-journal.jsonl"));
    let mut samples: Vec<Value> = Vec::new();
    for line in journal.lines().filter(|l| !l.trim().is_empty()) {
        let mut v: Value = serde_json::from_str(line).unwrap();
        if let Value::Object(m) = &mut v {
            m.remove("hash"); // hash the 7-field payload
        }
        samples.push(v);
    }
    samples.push(serde_json::json!({"b": {"z": 1, "a": 2}, "a": 1, "neg": -6}));
    samples.push(serde_json::json!({"nested": [{"k": 2}, {"k": 1}], "s": "a/b"}));
    // Catalog v2 (deferred proposal 1): the cross-language byte-parity test had
    // ZERO float coverage while the two contract canonicalizers hard-rejected
    // floats and this one emitted them. That gap is what let a real project
    // with a fractional gain produce a journal the conformance suite could not
    // hash. Cover it explicitly, including the tokens that normalize.
    for text in [
        "0.1",
        "1.5",
        "-3.5",
        "2.0",
        "1e3",
        "1e-3",
        "0.001",
        "-0.0",
        "120.00000000000003",
        "1.7976931348623157e308",
        "5e-324",
    ] {
        let v: Value = serde_json::from_str(&format!("{{\"value\":{text}}}"))
            .unwrap_or_else(|e| panic!("{text}: {e}"));
        samples.push(v);
    }

    for s in &samples {
        let mine = canonical_json(s).expect("canonicalizes");
        let theirs =
            contracts_conformance::canonical_json_bytes(s).expect("contracts canonicalizes");
        assert_eq!(
            mine.as_bytes(),
            theirs.as_slice(),
            "canonicalization diverged on {s}"
        );
    }
}

#[test]
fn fixture_journal_chain_verifies_with_my_hashing() {
    // Verifying the 30-entry fixture chain with MY envelope/hashing code and
    // landing on the fixture's stored tipHash proves my blake3 + canonical
    // form match P0-C exactly.
    let journal = read(contracts_dir().join("fixtures/project/minimal-journal.jsonl"));
    let lines: Vec<String> = journal
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(String::from)
        .collect();
    let (tip, count) = verify_lines(&lines).expect("fixture chain verifies with my hashing");

    let checkpoint: Value = serde_json::from_str(&read(
        contracts_dir().join("fixtures/project/minimal-project.json"),
    ))
    .unwrap();
    let claimed_tip = checkpoint["journal"]["tipHash"].as_str().unwrap();
    let claimed_count = checkpoint["journal"]["entryCount"].as_u64().unwrap() as usize;
    assert_eq!(count, claimed_count, "entry count");
    assert_eq!(tip, claimed_tip, "tip hash matches the checkpoint pointer");
}

#[test]
fn replaying_the_fixture_journal_reproduces_the_golden_checkpoint() {
    // The P0-C golden: the 30 fixture commands, replayed through the real
    // executor, must reproduce minimal-project.json's tracks/clips/sections/
    // markers/automation (EQ excluded: the v1 checkpoint schema has no EQ
    // field, proposal P2).
    let journal = read(contracts_dir().join("fixtures/project/minimal-journal.jsonl"));
    let envelopes: Vec<Envelope> = journal
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| Envelope::from_line(l).unwrap())
        .collect();
    let base = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    let session = Session::replay(base, envelopes).expect("replay the fixture journal");
    let got = session.project();

    let golden_v: Value = serde_json::from_str(&read(
        contracts_dir().join("fixtures/project/minimal-project.json"),
    ))
    .unwrap();
    let golden = from_project_json(&golden_v).expect("parse golden checkpoint");

    assert_eq!(got.bpm_wire, golden.bpm_wire, "tempo bpm");
    assert_eq!(got.tracks.len(), golden.tracks.len(), "track count");
    for (a, b) in got.tracks.iter().zip(&golden.tracks) {
        assert_eq!(a.id, b.id, "track id/order");
        assert_eq!(a.name, b.name, "track {} name", a.id);
        assert_eq!(a.color, b.color, "track {} color", a.id);
        assert_eq!(a.mute, b.mute, "track {} mute", a.id);
        assert_eq!(a.solo, b.solo, "track {} solo", a.id);
        assert_eq!(a.gain, b.gain, "track {} gain", a.id);
        assert_eq!(a.pan, b.pan, "track {} pan", a.id);
        assert_eq!(a.sends, b.sends, "track {} sends", a.id);
        assert_eq!(a.automation, b.automation, "track {} automation", a.id);
        assert_eq!(a.clips.len(), b.clips.len(), "track {} clip count", a.id);
        for (ca, cb) in a.clips.iter().zip(&b.clips) {
            assert_eq!(ca.id, cb.id, "clip id");
            assert_eq!(ca.start_ticks, cb.start_ticks, "clip {} start", ca.id);
            assert_eq!(ca.length_ticks, cb.length_ticks, "clip {} length", ca.id);
            assert_eq!(ca.source_id, cb.source_id, "clip {} asset", ca.id);
            assert_eq!(ca.gain, cb.gain, "clip {} gain", ca.id);
            assert_eq!(ca.fade_in, cb.fade_in, "clip {} fadeIn", ca.id);
            assert_eq!(ca.fade_out, cb.fade_out, "clip {} fadeOut", ca.id);
        }
    }
    assert_eq!(got.sections.len(), golden.sections.len(), "section count");
    for (a, b) in got.sections.iter().zip(&golden.sections) {
        assert_eq!(
            (&a.id, &a.name, a.start_ticks),
            (&b.id, &b.name, b.start_ticks)
        );
    }
    assert_eq!(got.markers.len(), golden.markers.len(), "marker count");
    for (a, b) in got.markers.iter().zip(&golden.markers) {
        assert_eq!(
            (&a.id, &a.label, a.position_ticks),
            (&b.id, &b.label, b.position_ticks)
        );
    }
}

#[test]
fn valid_command_fixtures_pass_param_validation() {
    let dir = contracts_dir().join("fixtures/commands/valid");
    let manifest: Value = serde_json::from_str(&read(dir.join("manifest.json"))).unwrap();
    let files = manifest["fixtures"].as_array().unwrap();
    let catalog = Catalog::get();
    let mut checked = 0;
    for f in files {
        let file = f["file"].as_str().unwrap();
        let env: Value = serde_json::from_str(&read(dir.join(file))).unwrap();
        let name = env["name"].as_str().unwrap();
        let params = &env["params"];
        catalog
            .validate_params(name, params)
            .unwrap_or_else(|e| panic!("valid fixture {file} rejected: {e}"));
        // and it parses into a typed Cmd
        Cmd::from_wire(name, params.clone())
            .unwrap_or_else(|e| panic!("valid fixture {file} will not parse: {e}"));
        checked += 1;
    }
    assert!(
        checked >= 13,
        "expected at least 13 valid fixtures, saw {checked}"
    );
}

#[test]
fn invalid_param_fixtures_are_rejected() {
    // The invalid fixtures split into params-level violations (which THIS
    // crate's catalog validator must catch) and envelope-shape violations
    // (which the contracts commandEnvelope schema catches, out of scope here).
    let dir = contracts_dir().join("fixtures/commands/invalid");
    let catalog = Catalog::get();
    let params_level = [
        "params_wrong_type.json",
        "params_missing_required.json",
        "unknown_command_name.json",
    ];
    for file in params_level {
        let env: Value = serde_json::from_str(&read(dir.join(file))).unwrap();
        let name = env["name"].as_str().unwrap();
        let params = env.get("params").cloned().unwrap_or(Value::Null);
        let result = catalog.validate_params(name, &params);
        assert!(result.is_err(), "invalid fixture {file} should be rejected");
    }
}

#[test]
fn catalog_undoable_and_inverse_flags_are_self_consistent() {
    // The acceptance hook "every command has an inverse or is explicitly
    // tagged non-undoable" as a total check over the catalog: undoable
    // commands declare a self/explicit inverse mode; non-undoable ones declare
    // none. (Inverse CORRECTNESS on real state is proven by the undo/redo
    // round-trip property test in properties.rs.)
    use timeline_core::catalog::InverseMode;
    let catalog = Catalog::get();
    for name in catalog.names() {
        let spec = catalog.spec(name).unwrap();
        if spec.undoable {
            assert!(
                matches!(
                    spec.inverse_mode,
                    InverseMode::SelfInverse | InverseMode::Explicit
                ),
                "{name} is undoable but declares inverse mode none"
            );
            assert!(spec.journaled, "{name} is undoable but not journaled");
        } else {
            assert!(
                matches!(spec.inverse_mode, InverseMode::None),
                "{name} is non-undoable but declares an inverse mode"
            );
        }
    }
}

#[test]
fn command_reference_matches_catalog() {
    let catalog_count = Catalog::get().len();
    let md_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../contracts/COMMAND-REFERENCE.md");
    let md = std::fs::read_to_string(&md_path)
        .unwrap_or_else(|e| panic!("COMMAND-REFERENCE.md not found at {}: {e}", md_path.display()));
    let md_command_count = md.lines()
        .filter(|l| l.starts_with("### "))
        .count();
    assert_eq!(
        md_command_count, catalog_count,
        "COMMAND-REFERENCE.md has {md_command_count} commands but the catalog has {catalog_count}. \
         Regenerate with: python3 scripts/generate-command-reference.py"
    );
    // Every catalog command name must appear in the reference.
    for name in Catalog::get().names() {
        assert!(
            md.contains(&format!("### {name}")),
            "COMMAND-REFERENCE.md is missing entry for {name}. \
             Regenerate with: python3 scripts/generate-command-reference.py"
        );
    }
}
