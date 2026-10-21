//! THE DESCRIPTION GATE: the catalog has to say what every command and every
//! parameter MEANS, and it has to keep saying it.
//!
//! Why this exists, in the same shape as `StudioHelp.swift` for UI controls:
//! the write half of "usable by human and AI" was complete by construction —
//! one MCP tool per catalog command, so a new command cannot ship without a
//! tool. The READ half was not. 204 of the catalog's 338 declared parameters
//! carried no description at all, which for a person means opening `apply.rs`
//! and for an agent means guessing. This codebase punishes guessing precisely:
//! parameter SHAPE is part of the hash chain, so `track.t1` instead of
//! `track:t1`, or an object where a string belongs, is a hard validation
//! failure and a wasted round trip. An undescribed parameter is a round trip
//! the caller has to spend to learn something the catalog already knew.
//!
//! Descriptions rot silently — nothing breaks when one is missing — so this is
//! a TABLE-DRIVEN test over the whole catalog rather than a convention. Adding
//! a command or a parameter without describing it fails the build BY NAME.
//!
//! The six rules, and what each one is defending against:
//!
//!  1. PRESENT. Every command, every parameter (including nested object
//!     properties and array-item properties), every read-surface entry.
//!  2. NOT A RESTATEMENT. "Sets the track fx param" for `track.fx.param` looks
//!     like coverage and teaches nothing — the same failure `StudioHelpTests`
//!     names for tooltips. A description must introduce at least one content
//!     word its own name does not already contain.
//!  3. LONG ENOUGH TO SAY ANYTHING. "The gain value" satisfies rule 2 on the
//!     word "value" and is still useless. 20 characters is the floor.
//!  4. RANGES MATCH THE SCHEMA. If a parameter is bounded, the description
//!     names both bounds. This is the rule that catches a description claiming
//!     `0..1` on a parameter the schema bounds at `0..127`: the numbers have to
//!     come from the schema, so they cannot drift away from it.
//!  5. ENUMS ARE ENUMERATED. Every value the schema accepts is named in the
//!     prose, including the values of an array's items. A caller must never
//!     have to discover a legal value by having one rejected.
//!  6. OPTIONAL SAYS SO, WITH ITS DEFAULT. A parameter absent from `required`
//!     has to say it is optional (or what omitting it does), and a parameter
//!     carrying a `default` has to name that default.
//!
//! Rules 4-6 are deliberately schema-DERIVED rather than hand-listed: the
//! expected tokens are read out of the same `paramsSchema` the validator uses,
//! so this test cannot pass by comparing a constant against itself.

use std::collections::BTreeSet;

use serde_json::Value;
use timeline_core::catalog::CATALOG_JSON;

/// A description shorter than this cannot carry units, a range and a default,
/// which is the whole job. Chosen to reject "The gain value" (14).
const MIN_DESCRIPTION_CHARS: usize = 20;

/// Words that carry no information about WHAT a thing does, so they do not
/// count toward rule 2. Kept small on purpose: a long stoplist would start
/// failing honest descriptions.
const STOPWORDS: &[&str] = &[
    "a", "an", "and", "the", "of", "to", "for", "on", "in", "at", "is", "are", "be", "it", "its",
    "this", "that", "with", "without", "or", "not", "no", "as", "by", "from", "into", "onto",
    "over", "under", "so", "which", "what", "when", "where", "whether", "than", "then", "you",
    "your", "yours", "each", "every", "any", "all", "one", "two", "both", "same", "other",
    "another", "set", "sets", "setting", "get", "gets", "change", "changes", "changing", "make",
    "makes", "making", "value", "values",
];

/// Ways of admitting a parameter is optional. Any one of them satisfies rule 6.
const OPTIONALITY_WORDS: &[&str] = &["optional", "default", "omitted", "omit ", "omitting", "omits"];

// ---------------------------------------------------------------------------
// Token helpers. No regex: `regex-lite` is a dependency of the crate, not of
// its integration tests, and the matching needed here is a boundary check.
// ---------------------------------------------------------------------------

fn is_word_char(c: char) -> bool {
    c.is_ascii_alphanumeric()
}

/// Does `haystack` contain `token` as a STANDALONE token? `"1"` must not match
/// inside `"16"`, and `"in"` must not match inside `"integer"` — otherwise
/// rules 4 and 5 would pass on prose that never names the value.
fn mentions(haystack: &str, token: &str) -> bool {
    if token.is_empty() {
        return false;
    }
    let bytes = haystack.as_bytes();
    let tok = token.as_bytes();
    let mut i = 0;
    while i + tok.len() <= bytes.len() {
        if &bytes[i..i + tok.len()] == tok {
            let before_ok = i == 0 || !is_word_char(bytes[i - 1] as char);
            let after_idx = i + tok.len();
            let after_ok = after_idx == bytes.len() || !is_word_char(bytes[after_idx] as char);
            if before_ok && after_ok {
                return true;
            }
        }
        i += 1;
    }
    false
}

/// Collapse the inflections English uses to say the same word twice. Rule 2
/// compares MEANING, and "Trims the clip, trimming a clip" carries none that
/// `clip.trim` does not — a mutation that SURVIVED the first version of this
/// gate, because `trims` and `trimming` are not literally `trim`. This is a
/// deliberately blunt suffix strip, not a stemmer: it only has to make an
/// inflected restatement compare equal to the plain one, and over-stemming
/// costs nothing here (both sides go through it).
fn stem(word: &str) -> String {
    for suffix in ["ing", "ed", "s"] {
        let Some(root) = word.strip_suffix(suffix) else {
            continue;
        };
        if root.len() < 3 {
            continue;
        }
        // English doubles the final consonant before -ing/-ed: trim -> trimming.
        // Without this, `trimming` stems to `trimm` and the restatement it is
        // hiding stays invisible.
        let bytes = root.as_bytes();
        let n = bytes.len();
        let doubled = suffix != "s"
            && n >= 2
            && bytes[n - 1] == bytes[n - 2]
            && !b"aeiou".contains(&bytes[n - 1]);
        return if doubled {
            root[..n - 1].to_string()
        } else {
            root.to_string()
        };
    }
    word.to_string()
}

/// Split an identifier into its words: dots and non-alphanumerics separate, and
/// so does a camelCase hump. `clip.setGain` -> {clip, set, gain}.
fn identifier_words(name: &str) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let mut current = String::new();
    let mut prev_lower_or_digit = false;
    for ch in name.chars() {
        if !ch.is_ascii_alphanumeric() {
            if !current.is_empty() {
                out.insert(std::mem::take(&mut current));
            }
            prev_lower_or_digit = false;
            continue;
        }
        if ch.is_ascii_uppercase() && prev_lower_or_digit && !current.is_empty() {
            out.insert(std::mem::take(&mut current));
        }
        current.push(ch.to_ascii_lowercase());
        prev_lower_or_digit = ch.is_ascii_lowercase() || ch.is_ascii_digit();
    }
    if !current.is_empty() {
        out.insert(current);
    }
    out.iter().map(|w| stem(w)).collect()
}

/// The words in a description that actually carry meaning (rule 2), stemmed so
/// an inflected restatement cannot slip past by adding an -s or an -ing.
fn content_words(desc: &str) -> BTreeSet<String> {
    desc.split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|w| w.len() > 1)
        .map(|w| w.to_ascii_lowercase())
        .filter(|w| !STOPWORDS.contains(&w.as_str()))
        .map(|w| stem(&w))
        .collect()
}

/// How a JSON scalar is spelled when a description names it. `1.0` and `1` are
/// the same bound to a reader, so both render as `1`.
fn scalar_token(v: &Value) -> String {
    match v {
        Value::Bool(b) => b.to_string(),
        Value::String(s) => s.clone(),
        Value::Number(n) => {
            if let Some(f) = n.as_f64() {
                if f.fract() == 0.0 && f.abs() < 1e15 {
                    return format!("{}", f as i64);
                }
            }
            n.to_string()
        }
        other => other.to_string(),
    }
}

// ---------------------------------------------------------------------------
// The rules
// ---------------------------------------------------------------------------

/// Rules 1-3, shared by commands, parameters and read-surface entries.
fn check_prose(what: &str, name: &str, desc: Option<&str>, fails: &mut Vec<String>) -> bool {
    let Some(desc) = desc.map(str::trim).filter(|d| !d.is_empty()) else {
        fails.push(format!(
            "{what}: NO DESCRIPTION. Every catalog entry has to say what it means; \
             add one to engine/contracts/command-catalog.v2.json."
        ));
        return false;
    };
    if desc.chars().count() < MIN_DESCRIPTION_CHARS {
        fails.push(format!(
            "{what}: description is {} characters, under the {MIN_DESCRIPTION_CHARS} floor: {desc:?}",
            desc.chars().count()
        ));
        return false;
    }
    let content = content_words(desc);
    if !content.is_empty() && content.is_subset(&identifier_words(name)) {
        fails.push(format!(
            "{what}: the description only restates the name — it introduces no word \
             {name:?} does not already contain. Say what it DOES: {desc:?}"
        ));
        return false;
    }
    true
}

/// Rules 4-6 for one declared parameter, all derived from its own schema.
fn check_parameter(
    what: &str,
    leaf_name: &str,
    schema: &Value,
    required: &BTreeSet<String>,
    fails: &mut Vec<String>,
) {
    if !check_prose(what, leaf_name, schema.get("description").and_then(Value::as_str), fails) {
        return;
    }
    let desc = schema["description"].as_str().unwrap_or_default();

    // Rule 4. A single `minimum: 0` is not worth a sentence — every tick
    // position has one and spelling it out would be noise. Anything else (a
    // real range, or a lone non-zero bound) has to appear in the prose, so a
    // description cannot claim a range the schema does not have.
    let bounds: Vec<&Value> = ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"]
        .iter()
        .filter_map(|k| schema.get(*k))
        .collect();
    let worth_stating = bounds.len() >= 2
        || (bounds.len() == 1 && bounds[0].as_f64().map(|f| f != 0.0).unwrap_or(true));
    if worth_stating {
        for b in &bounds {
            let token = scalar_token(b);
            if !mentions(desc, &token) {
                fails.push(format!(
                    "{what}: the schema bounds this at {token} and the description never \
                     says so. A caller has to learn the range from the text, not from a \
                     rejection: {desc:?}"
                ));
            }
        }
    }

    // Rule 5. The enum a caller must choose from, including an array's items —
    // `stems` is `array<enum>`, and its legal values are as load-bearing as a
    // scalar enum's.
    let enum_values = schema
        .get("enum")
        .and_then(Value::as_array)
        .or_else(|| {
            schema
                .get("items")
                .and_then(Value::as_object)
                .and_then(|it| it.get("enum"))
                .and_then(Value::as_array)
        });
    if let Some(values) = enum_values {
        for v in values {
            let token = scalar_token(v);
            if !mentions(desc, &token) {
                fails.push(format!(
                    "{what}: the schema accepts {token:?} and the description never names it. \
                     Every legal value has to be discoverable without being rejected first: {desc:?}"
                ));
            }
        }
    }

    // Rule 6a. A declared default is part of the contract; a caller deciding
    // whether to send the field needs to know what happens if it does not.
    if let Some(default) = schema.get("default") {
        let token = scalar_token(default);
        if !mentions(desc, &token) {
            fails.push(format!(
                "{what}: the schema defaults this to {token:?} and the description never \
                 says so: {desc:?}"
            ));
        }
    }

    // Rule 6b. Optionality itself. "Is this required?" is the single most
    // common question a tool schema is asked, and `required` alone answers it
    // only for a caller who reads JSON Schema.
    if !required.contains(leaf_name) {
        let lower = desc.to_ascii_lowercase();
        if !OPTIONALITY_WORDS.iter().any(|w| lower.contains(w)) {
            fails.push(format!(
                "{what}: absent from `required`, so it is OPTIONAL, and the description \
                 never says so or says what omitting it does: {desc:?}"
            ));
        }
    }
}

/// One declared parameter, as the traversal found it.
struct Declared<'a> {
    /// Dotted path within the command's paramsSchema, e.g. `notes[].velocity`.
    path: String,
    /// The last segment, which is the name the schema keys it by.
    leaf: String,
    schema: &'a Value,
    /// The `required` list of the object this property belongs to.
    required: BTreeSet<String>,
}

/// THE traversal. Every declared property, including nested objects and array
/// items.
///
/// There is exactly one of these and both tests below call it. The first
/// version of this file had the coverage test carry its OWN copy of the walk,
/// which meant a mutation deleting the array-item descent from the real walk
/// left BOTH tests green: the gate stopped checking `notes[].velocity`, and the
/// coverage test still counted it, because it was counting with the copy. A
/// coverage assertion over a duplicate of the code it is meant to police is
/// decoration. That mutation SURVIVED the first pass; this shape is the fix.
fn declared_parameters<'a>(schema: &'a Value, prefix: &str, out: &mut Vec<Declared<'a>>) {
    let Some(props) = schema.get("properties").and_then(Value::as_object) else {
        return;
    };
    let required: BTreeSet<String> = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();

    for (key, sub) in props {
        let path = format!("{prefix}{key}");
        out.push(Declared {
            path: path.clone(),
            leaf: key.clone(),
            schema: sub,
            required: required.clone(),
        });

        if sub.get("type").and_then(Value::as_str) == Some("object") {
            declared_parameters(sub, &format!("{path}."), out);
        }
        if sub.get("type").and_then(Value::as_str) == Some("array") {
            if let Some(items) = sub.get("items") {
                declared_parameters(items, &format!("{path}[]."), out);
            }
        }
    }
}

fn catalog() -> Value {
    serde_json::from_str(CATALOG_JSON).expect("embedded catalog must parse")
}

// ---------------------------------------------------------------------------
// The gate
// ---------------------------------------------------------------------------

#[test]
fn every_command_and_parameter_is_described_and_the_description_matches_the_schema() {
    let doc = catalog();
    let mut fails = Vec::new();

    for cmd in doc["commands"].as_array().expect("commands array") {
        let name = cmd["name"].as_str().expect("command name");
        check_prose(
            &format!("command {name}"),
            name,
            cmd.get("description").and_then(Value::as_str),
            &mut fails,
        );
        let mut declared = Vec::new();
        declared_parameters(&cmd["paramsSchema"], "", &mut declared);
        for d in &declared {
            check_parameter(
                &format!("{name} :: {}", d.path),
                &d.leaf,
                d.schema,
                &d.required,
                &mut fails,
            );
        }
    }

    for read in doc["readSurface"].as_array().expect("readSurface array") {
        let name = read["name"].as_str().expect("read name");
        check_prose(
            &format!("read surface {name}"),
            name,
            read.get("description").and_then(Value::as_str),
            &mut fails,
        );
    }

    assert!(
        fails.is_empty(),
        "THE DESCRIPTION GATE FAILED ({} problems). An undescribed or wrong parameter \
         costs every agent caller a round trip:\n{}",
        fails.len(),
        fails.join("\n")
    );
}

/// The counts this gate walks, pinned. Without this a refactor that stopped
/// descending into nested objects or array items would leave the gate green
/// while checking a fraction of the surface — the `--filter`-reports-zero-tests
/// failure one level down, and exactly the shape `GATES.md` warns about.
#[test]
fn the_gate_actually_walks_the_whole_declared_surface() {
    let doc = catalog();
    let commands = doc["commands"].as_array().expect("commands array");

    // Counted with THE traversal the gate uses, never a copy of it.
    let mut declared = Vec::new();
    for cmd in commands {
        declared_parameters(&cmd["paramsSchema"], "", &mut declared);
    }
    let visited: Vec<String> = declared.iter().map(|d| d.path.clone()).collect();

    assert_eq!(commands.len(), 119, "catalog v2 is 119 commands");
    assert_eq!(
        visited.len(),
        338,
        "the catalog declares 338 parameters (including nested object and array-item \
         properties). If you added or removed one, update this count in the SAME commit; \
         if this dropped without the catalog changing, the walk stopped descending."
    );
    assert!(
        visited.iter().any(|p| p.contains("[].")),
        "the walk must descend into array items (note.add's notes[] carry five parameters \
         of their own)"
    );
    assert!(
        visited.iter().any(|p| p.contains('.') && !p.contains("[]")),
        "the walk must descend into nested objects (midi.binding.set's control/target/valueMap)"
    );
}

// ---------------------------------------------------------------------------
// Self-tests for the rules. A gate whose matcher is wrong is decoration, and
// `mentions` in particular is the kind of helper that passes for every input
// if it is written slightly wrong.
// ---------------------------------------------------------------------------

#[test]
fn mentions_requires_a_standalone_token() {
    assert!(mentions("Range 0 to 127.", "127"));
    assert!(mentions("-60 to +12 dB", "-60"));
    assert!(mentions("one of 1, 2, 4, 8, 16 or 32", "1"));
    assert!(mentions("'equalPower' is the default", "equalPower"));
    // The failures that matter: a substring inside a longer token is NOT a
    // mention, or rule 5 would pass on prose that never names the value.
    assert!(!mentions("one of 16 or 32", "1"));
    assert!(!mentions("an integer position", "in"));
    assert!(!mentions("clipIdA and clipIdB", "clipId"));
    assert!(!mentions("", "0"));
}

#[test]
fn identifier_words_splits_dots_and_camel_humps() {
    let w = identifier_words("clip.setGain");
    assert_eq!(
        w.iter().cloned().collect::<Vec<_>>(),
        vec!["clip".to_string(), "gain".to_string(), "set".to_string()]
    );
    assert!(identifier_words("positionTicks").contains("tick"));
    assert!(identifier_words("track.fx.param").contains("fx"));
}

/// The stemmer only exists to close the inflection hole, so it is checked in
/// both directions: it must fold the inflections and must NOT merge two words
/// that merely look alike.
#[test]
fn the_stemmer_folds_inflections_without_merging_unrelated_words() {
    for (word, root) in [
        ("trims", "trim"),
        ("trimming", "trim"),
        ("moves", "move"),
        ("removed", "remov"),
        ("ticks", "tick"),
    ] {
        assert_eq!(stem(word), root, "{word}");
    }
    // Short roots are left alone rather than mangled into nothing.
    assert_eq!(stem("is"), "is");
    assert_eq!(stem("ends"), "end");
    // And unrelated words stay unrelated.
    assert_ne!(stem("clip"), stem("clap"));
    assert_ne!(stem("gain"), stem("gate"));
}

/// The exact restatement that SURVIVED the first version of this gate.
#[test]
fn an_inflected_restatement_is_still_a_restatement() {
    let mut fails = Vec::new();
    assert!(
        !check_prose(
            "command clip.trim",
            "clip.trim",
            Some("Trims the clip, trimming a clip."),
            &mut fails
        ),
        "an inflected restatement must be rejected"
    );
    assert!(fails[0].contains("only restates the name"), "{fails:?}");

    // The brief's own example, for good measure.
    let mut fails = Vec::new();
    assert!(!check_prose(
        "command track.fx.param",
        "track.fx.param",
        Some("Sets the track fx param."),
        &mut fails
    ));

    // ...and a short-but-real description still passes: rule 2 is about
    // meaning, not length, and rule 3 owns length.
    let mut fails = Vec::new();
    assert!(check_prose(
        "command transport.stop",
        "transport.stop",
        Some("Stop playback and leave the playhead where it is."),
        &mut fails
    ));
}

#[test]
fn the_rules_reject_the_descriptions_they_exist_to_reject() {
    let required: BTreeSet<String> = ["gainDb".to_string()].into_iter().collect();

    // Rule 1: absent.
    let mut fails = Vec::new();
    check_parameter(
        "x :: gainDb",
        "gainDb",
        &serde_json::json!({ "type": "number" }),
        &required,
        &mut fails,
    );
    assert!(fails[0].contains("NO DESCRIPTION"), "{fails:?}");

    // Rule 2: restates the name.
    let mut fails = Vec::new();
    check_parameter(
        "x :: gainDb",
        "gainDb",
        &serde_json::json!({ "type": "number", "description": "The gain db, a gain db." }),
        &required,
        &mut fails,
    );
    assert!(fails[0].contains("only restates the name"), "{fails:?}");

    // Rule 3: too short to say anything.
    let mut fails = Vec::new();
    check_parameter(
        "x :: gainDb",
        "gainDb",
        &serde_json::json!({ "type": "number", "description": "The level knob." }),
        &required,
        &mut fails,
    );
    assert!(fails[0].contains("under the"), "{fails:?}");

    // Rule 4: THE ONE THIS LANE EXISTS FOR — a description claiming a range
    // the schema does not have. `0..1` on a `0..127` parameter passes every
    // other rule and sends the caller to a rejection.
    let mut fails = Vec::new();
    check_parameter(
        "x :: velocity",
        "velocity",
        &serde_json::json!({
            "type": "integer", "minimum": 0, "maximum": 127,
            "description": "How hard the note is struck, 0 to 1 where 1 is loudest."
        }),
        &["velocity".to_string()].into_iter().collect(),
        &mut fails,
    );
    assert_eq!(fails.len(), 1, "{fails:?}");
    assert!(fails[0].contains("bounds this at 127"), "{fails:?}");

    // ...and the same text passes once it names the real bound.
    let mut fails = Vec::new();
    check_parameter(
        "x :: velocity",
        "velocity",
        &serde_json::json!({
            "type": "integer", "minimum": 0, "maximum": 127,
            "description": "How hard the note is struck, 0 to 127 where 127 is loudest."
        }),
        &["velocity".to_string()].into_iter().collect(),
        &mut fails,
    );
    assert!(fails.is_empty(), "{fails:?}");

    // Rule 5: an unnamed legal value.
    let mut fails = Vec::new();
    check_parameter(
        "x :: format",
        "format",
        &serde_json::json!({
            "type": "string", "enum": ["wav", "flac", "aac"],
            "description": "Container to write: 'wav' or 'aac' for the deliverable."
        }),
        &["format".to_string()].into_iter().collect(),
        &mut fails,
    );
    assert_eq!(fails.len(), 1, "{fails:?}");
    assert!(fails[0].contains("\"flac\""), "{fails:?}");

    // Rule 6a: an unnamed default.
    let mut fails = Vec::new();
    check_parameter(
        "x :: shape",
        "shape",
        &serde_json::json!({
            "type": "string", "enum": ["linear"], "default": "linear",
            "description": "Optional curve for the crossfade; 'linear' ramps straight."
        }),
        &BTreeSet::new(),
        &mut fails,
    );
    assert!(fails.is_empty(), "a named default passes: {fails:?}");
    let mut fails = Vec::new();
    check_parameter(
        "x :: shape",
        "shape",
        &serde_json::json!({
            "type": "string", "default": "equalPower",
            "description": "Optional curve applied where the two clips overlap."
        }),
        &BTreeSet::new(),
        &mut fails,
    );
    assert!(fails[0].contains("defaults this to"), "{fails:?}");

    // Rule 6b: optional, never says so.
    let mut fails = Vec::new();
    check_parameter(
        "x :: reason",
        "reason",
        &serde_json::json!({
            "type": "string",
            "description": "A human-readable label shown in the undo history."
        }),
        &BTreeSet::new(),
        &mut fails,
    );
    assert!(fails[0].contains("OPTIONAL"), "{fails:?}");
}
