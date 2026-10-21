//! The load-bearing safety net for catalog v2 (`DESIGN-catalog-v2.md` §2).
//!
//! v2 must be a STRICT SUPERSET of the frozen v1.1 catalog: every v1.1 command
//! is semantically identical in v2 (same `name` / `journaled` / `undoable` /
//! `inverseRule`), and its `paramsSchema` still accepts everything v1.1
//! accepted. Widening is permitted ONLY at the sites enumerated below, so an
//! accidental widening anywhere else fails this test rather than silently
//! loosening the contract boundary.
//!
//! v1.1 itself is never edited again; it is embedded here purely as the
//! comparison baseline.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{json, Value};
use timeline_core::catalog::{CATALOG_JSON, CATALOG_V1_1_JSON};
use timeline_core::schema;

// ---------------------------------------------------------------------------
// The enumerated widening sites. Anything not listed here must be byte-equal
// between v1.1 and v2.
// ---------------------------------------------------------------------------

/// (command name, JSON-pointer prefix into `paramsSchema`) pairs that v2 is
/// allowed to differ at. Design §3 (ParamRef target) and §6 (crossfade zero).
const WIDENING_SITES: &[(&str, &str)] = &[
    // §3 — the one deliberate enum→pattern widening.
    ("autolane.show", "/properties/target"),
    ("autolane.clear", "/properties/target"),
    ("autopoint.add", "/properties/target"),
    ("autopoint.move", "/properties/target"),
    ("autopoint.remove", "/properties/target"),
    // §6 — deferred proposal "Crossfade length-0", accepted.
    ("clip.crossfade.set", "/properties/lengthTicks"),
];

/// Command-entry keys v2 may ADD (never change) relative to v1.1. Both are
/// inert documentation: nothing in `catalog.rs` reads them for semantics.
const ADDITIVE_ENTRY_KEYS: &[&str] = &["nonUndoableReason", "inverseShape"];

/// The exact set of commands v2 adds `nonUndoableReason` to (design §9.6: the
/// engine embedded a catalog that failed its own schema on these).
const REASON_ADDED_TO: &[&str] = &[
    "midi.binding.clear",
    "midi.binding.set",
    "midi.device.select",
    "midi.learn.start",
    "midi.learn.stop",
    "midi.map.export",
    "midi.map.import",
    "midi.reload",
];

fn commands(src: &str) -> BTreeMap<String, Value> {
    let doc: Value = serde_json::from_str(src).expect("catalog parses");
    doc["commands"]
        .as_array()
        .expect("commands array")
        .iter()
        .map(|c| (c["name"].as_str().expect("name").to_string(), c.clone()))
        .collect()
}

/// Strip every `description` from a schema fragment, recursively.
///
/// v2 is a superset of v1.1 in what it ACCEPTS — that is what this file pins,
/// and it is why the diff below is byte-exact everywhere the design did not
/// declare a widening. `description` is inert to acceptance: `schema.rs` lists
/// it in `KNOWN_KEYWORDS` and its `walk` never reads it, so annotating a
/// parameter cannot loosen or tighten the contract boundary by one value.
///
/// The catalog acquired 204 parameter descriptions it had never had (the
/// agent-facing read half of "usable by human and AI"), all on v1.1 commands.
/// Comparing the ANNOTATION-STRIPPED schemas keeps every structural pin exactly
/// as strong as it was — a changed `minimum`, `enum`, `pattern` or `required`
/// still fails — while letting the catalog say what it means.
fn strip_descriptions(v: &Value) -> Value {
    match v {
        Value::Object(map) => Value::Object(
            map.iter()
                .filter(|(k, _)| k.as_str() != "description")
                .map(|(k, val)| (k.clone(), strip_descriptions(val)))
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(strip_descriptions).collect()),
        other => other.clone(),
    }
}

/// Every JSON pointer at which `a` and `b` differ.
fn diff_paths(a: &Value, b: &Value, at: &str, out: &mut Vec<String>) {
    if a == b {
        return;
    }
    match (a, b) {
        (Value::Object(x), Value::Object(y)) => {
            let keys: BTreeSet<&String> = x.keys().chain(y.keys()).collect();
            for k in keys {
                let l = x.get(k).unwrap_or(&Value::Null);
                let r = y.get(k).unwrap_or(&Value::Null);
                diff_paths(l, r, &format!("{at}/{k}"), out);
            }
        }
        (Value::Array(x), Value::Array(y)) if x.len() == y.len() => {
            for (i, (l, r)) in x.iter().zip(y.iter()).enumerate() {
                diff_paths(l, r, &format!("{at}/{i}"), out);
            }
        }
        _ => out.push(at.to_string()),
    }
}

#[test]
fn v2_is_a_strict_superset_of_v1_1() {
    let v1 = commands(CATALOG_V1_1_JSON);
    let v2 = commands(CATALOG_JSON);

    assert_eq!(v1.len(), 87, "v1.1 is frozen at 87 commands");
    assert!(
        v2.len() >= v1.len(),
        "v2 must not shrink: {} < {}",
        v2.len(),
        v1.len()
    );

    let allowed: BTreeSet<(&str, &str)> = WIDENING_SITES.iter().copied().collect();
    let mut reason_added: BTreeSet<&str> = BTreeSet::new();

    for (name, old) in &v1 {
        let new = v2
            .get(name)
            .unwrap_or_else(|| panic!("v2 dropped v1.1 command {name}"));

        // --- semantic identity -------------------------------------------
        for key in ["name", "category", "journaled", "undoable", "async", "flag", "systemAuthored"]
        {
            assert_eq!(
                old.get(key),
                new.get(key),
                "{name}.{key} changed between v1.1 and v2"
            );
        }
        assert_eq!(
            old["inverseRule"], new["inverseRule"],
            "{name}.inverseRule changed between v1.1 and v2"
        );

        // --- only additive entry keys ------------------------------------
        let old_keys: BTreeSet<&String> = old.as_object().unwrap().keys().collect();
        let new_keys: BTreeSet<&String> = new.as_object().unwrap().keys().collect();
        for k in &old_keys {
            assert!(new_keys.contains(*k), "{name} lost catalog key {k}");
        }
        for k in new_keys.difference(&old_keys) {
            assert!(
                ADDITIVE_ENTRY_KEYS.contains(&k.as_str()),
                "{name} gained non-additive catalog key {k}"
            );
            if k.as_str() == "nonUndoableReason" {
                reason_added.insert(name.as_str());
            }
        }

        // --- paramsSchema: differences only at enumerated sites ----------
        // Compared with descriptions stripped, so documentation is free and
        // structure is not. See `strip_descriptions`.
        let mut paths = Vec::new();
        diff_paths(
            &strip_descriptions(&old["paramsSchema"]),
            &strip_descriptions(&new["paramsSchema"]),
            "",
            &mut paths,
        );
        for p in &paths {
            let ok = allowed
                .iter()
                .any(|(cmd, site)| *cmd == name.as_str() && p.starts_with(site));
            assert!(
                ok,
                "UNDECLARED WIDENING: {name} paramsSchema differs at {p}. \
                 Add it to WIDENING_SITES only if the design says so."
            );
        }
    }

    let expected_reasons: BTreeSet<&str> = REASON_ADDED_TO.iter().copied().collect();
    assert_eq!(
        reason_added, expected_reasons,
        "the set of commands gaining nonUndoableReason changed"
    );
}

/// `strip_descriptions` must be load-bearing in BOTH directions, or the test
/// above quietly turns into "compare two things that were already equal".
///
/// Direction 1: it removes something real — v2 annotates v1.1 commands, so the
/// stripped and unstripped diffs are NOT the same set.
/// Direction 2: it removes ONLY annotations — the stripped diff outside the
/// enumerated widening sites is empty, which is what makes ignoring
/// descriptions safe rather than convenient.
#[test]
fn stripping_descriptions_hides_annotations_and_nothing_else() {
    let v1 = commands(CATALOG_V1_1_JSON);
    let v2 = commands(CATALOG_JSON);

    let mut annotated: Vec<String> = Vec::new();
    for (name, old) in &v1 {
        let new = &v2[name];
        let mut raw = Vec::new();
        diff_paths(&old["paramsSchema"], &new["paramsSchema"], "", &mut raw);
        let mut stripped = Vec::new();
        diff_paths(
            &strip_descriptions(&old["paramsSchema"]),
            &strip_descriptions(&new["paramsSchema"]),
            "",
            &mut stripped,
        );

        for p in &raw {
            if !stripped.contains(p) {
                assert!(
                    p.ends_with("/description"),
                    "{name}: stripping descriptions hid a NON-description difference at {p}. \
                     The strip must only remove annotations."
                );
                annotated.push(format!("{name}{p}"));
            }
        }
    }

    assert!(
        annotated.len() >= 100,
        "only {} annotated sites: the strip is not hiding anything real, so the superset \
         diff above is not actually exercising it",
        annotated.len()
    );
}

#[test]
fn every_declared_widening_site_actually_widened() {
    // Guards the other direction: a site listed as widened but left untouched
    // means the enumeration has gone stale and is no longer pinning anything.
    let v1 = commands(CATALOG_V1_1_JSON);
    let v2 = commands(CATALOG_JSON);
    for (name, site) in WIDENING_SITES {
        // Descriptions stripped here too, or a site could stay on this list
        // purely because someone annotated it — which is not a widening and
        // would leave the enumeration pinning nothing.
        let mut paths = Vec::new();
        diff_paths(
            &strip_descriptions(&v1[*name]["paramsSchema"]),
            &strip_descriptions(&v2[*name]["paramsSchema"]),
            "",
            &mut paths,
        );
        assert!(
            paths.iter().any(|p| p.starts_with(site)),
            "{name} {site} is declared as a widening site but v1.1 and v2 are identical there"
        );
    }
}

#[test]
fn widened_schemas_still_accept_every_v1_1_value() {
    let v1 = commands(CATALOG_V1_1_JSON);
    let v2 = commands(CATALOG_JSON);

    // Automation target: both legacy spellings, byte-identical.
    for cmd in [
        "autolane.show",
        "autolane.clear",
        "autopoint.add",
        "autopoint.move",
        "autopoint.remove",
    ] {
        for target in ["track.volume", "track.pan"] {
            let params = representative_for(cmd, target);
            let old = schema::validate(&v1[cmd]["paramsSchema"], &params);
            let new = schema::validate(&v2[cmd]["paramsSchema"], &params);
            assert!(old.is_empty(), "{cmd}/{target} invalid under v1.1: {old:?}");
            assert!(new.is_empty(), "{cmd}/{target} invalid under v2: {new:?}");
        }
        // And the widening genuinely admits a path v1.1 rejected.
        let params = representative_for(cmd, "track.device.dev1.cutoff");
        assert!(
            !schema::validate(&v1[cmd]["paramsSchema"], &params).is_empty(),
            "{cmd} v1.1 should have rejected a device path"
        );
        assert!(
            schema::validate(&v2[cmd]["paramsSchema"], &params).is_empty(),
            "{cmd} v2 should accept a device path"
        );
        // The pattern is not "anything": a dot-adjacent empty segment fails.
        let bad = representative_for(cmd, "track..volume");
        assert!(
            !schema::validate(&v2[cmd]["paramsSchema"], &bad).is_empty(),
            "{cmd} v2 must still reject a malformed path"
        );
    }

    // Crossfade: every length v1.1 accepted is still accepted, plus zero.
    let cf = "clip.crossfade.set";
    for n in [1u64, 2, 480, 96_000] {
        let params = json!({"clipIdA": "a", "clipIdB": "b", "lengthTicks": n});
        assert!(schema::validate(&v1[cf]["paramsSchema"], &params).is_empty());
        assert!(schema::validate(&v2[cf]["paramsSchema"], &params).is_empty());
    }
    let zero = json!({"clipIdA": "a", "clipIdB": "b", "lengthTicks": 0});
    assert!(
        !schema::validate(&v1[cf]["paramsSchema"], &zero).is_empty(),
        "v1.1 rejected zero (that was the deviation)"
    );
    assert!(
        schema::validate(&v2[cf]["paramsSchema"], &zero).is_empty(),
        "v2 accepts zero (deferred proposal accepted)"
    );
    let neg = json!({"clipIdA": "a", "clipIdB": "b", "lengthTicks": -1});
    assert!(
        !schema::validate(&v2[cf]["paramsSchema"], &neg).is_empty(),
        "v2 must still reject a negative length"
    );
}

fn representative_for(cmd: &str, target: &str) -> Value {
    match cmd {
        "autolane.show" => json!({"trackId": "t1", "target": target, "visible": true}),
        "autolane.clear" => json!({"trackId": "t1", "target": target}),
        "autopoint.add" | "autopoint.move" => {
            json!({"trackId": "t1", "target": target, "pointId": "p1",
                   "positionTicks": 0, "value": 0})
        }
        "autopoint.remove" => json!({"trackId": "t1", "target": target, "pointId": "p1"}),
        other => panic!("no representative params for {other}"),
    }
}

#[test]
fn catalog_version_is_a_string_and_bumped() {
    let doc: Value = serde_json::from_str(CATALOG_JSON).unwrap();
    let v = doc["catalogVersion"]
        .as_str()
        .expect("v2 catalogVersion must be a STRING (1.10 != 1.1)");
    assert_eq!(v, "2.0");

    let old: Value = serde_json::from_str(CATALOG_V1_1_JSON).unwrap();
    assert!(
        old["catalogVersion"].is_number(),
        "v1.1 stays frozen with its lossy numeric version"
    );
}

/// Design §9.6: the conformance suites used to validate `command-catalog.v1.json`
/// while `catalog.rs` embedded v1.1, so the file that IS law went unchecked and
/// accumulated 16 schema violations. This test makes that class of drift fail CI:
/// the embedded bytes must be exactly the on-disk file, and both conformance
/// suites must name that same file.
#[test]
fn the_embedded_catalog_is_the_one_the_conformance_suites_check() {
    let contracts = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../contracts");

    let on_disk = std::fs::read_to_string(contracts.join("command-catalog.v2.json"))
        .expect("v2 catalog on disk");
    assert_eq!(
        on_disk, CATALOG_JSON,
        "catalog.rs embeds bytes that differ from contracts/command-catalog.v2.json"
    );

    for suite in [
        "conformance/tests/conformance.rs",
        "conformance_py/test_conformance.py",
    ] {
        let src = std::fs::read_to_string(contracts.join(suite))
            .unwrap_or_else(|e| panic!("read {suite}: {e}"));
        assert!(
            src.contains("EMBEDDED_CATALOG = \"command-catalog.v2.json\"")
                || src.contains("EMBEDDED_CATALOG: &str = \"command-catalog.v2.json\""),
            "{suite} does not point at the catalog catalog.rs embeds. \
             Repointing include_str! without repointing the suites recreates the \
             §9.6 gap: the file that is law goes unvalidated."
        );
    }
}

#[test]
fn frozen_v1_1_file_is_untouched() {
    // A blunt guard against "just tweak v1.1" — the whole superset argument
    // rests on v1.1 being immutable.
    let v1 = commands(CATALOG_V1_1_JSON);
    assert_eq!(v1.len(), 87);
    let names: BTreeSet<&str> = v1.keys().map(String::as_str).collect();
    assert!(names.contains("marker.remove"));
    assert!(names.contains("take.restore"));
    assert!(
        !names.contains("route.connect"),
        "v1.1 must never gain a v2 command"
    );
    // The midi entries in v1.1 still lack nonUndoableReason. That is a real
    // (pre-existing) schema violation, fixed in v2 rather than by editing the
    // frozen file. Asserted so the fix cannot be "solved" by mutating v1.1.
    for name in REASON_ADDED_TO {
        assert!(
            v1[*name].get("nonUndoableReason").is_none(),
            "v1.1 was edited: {name} gained nonUndoableReason"
        );
    }
}
