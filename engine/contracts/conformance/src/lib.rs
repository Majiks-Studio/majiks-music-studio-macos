//! Conformance library for `engine/contracts/`: canonical JSON + the journal
//! hash chain, plus small JSON Schema validation helpers. No engine behavior
//! lives here — this crate only proves the contract artifacts (schemas +
//! fixtures) are internally consistent. See `../README.md`
//! "Canonicalization and the hash chain" for the algorithm this module
//! implements; `conformance_py/canonical.py` is the same algorithm in Python
//! and the two are cross-checked (see `tests/conformance.rs`).

use serde_json::{Map, Value};
use std::fmt::Write as _;

/// 64 ASCII '0' characters: the reserved "no predecessor" hash for a
/// journal's first entry.
pub const GENESIS_HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";

/// The seven logical fields of a command envelope that get hashed (`hash`
/// itself is excluded, since it cannot include its own output).
pub const ENVELOPE_HASHED_FIELDS: [&str; 7] =
    ["id", "ts", "actor", "name", "params", "inverse", "result"];

/// Canonicalize `value` to its hashed byte form: object keys sorted
/// byte-for-byte ascending at every nesting level, compact separators, every
/// non-ASCII code point escaped as `\uXXXX` (matching Python's
/// `json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True)`
/// byte-for-byte), arrays left in source order, no trailing newline.
///
/// Deliberately implemented by hand (not `serde_json::to_string`, whose
/// default `Value::Object` map does happen to iterate in sorted order when
/// serde_json's `preserve_order` feature is off, but which does NOT
/// ASCII-escape non-ASCII text) so this crate's output is guaranteed
/// byte-identical to the Python implementation for every input, not just the
/// ASCII-only inputs this lane's own fixtures happen to use.
///
/// Numbers follow README.md rule 4 ("Numbers"): integer-shaped literals emit as
/// plain digits, float-shaped literals emit as the shortest round-trip decimal.
/// Catalog v2 pinned the float half of that rule (deferred proposal 1); before
/// it, this function REJECTED every float, so a project with a fractional gain
/// produced a journal the conformance suite could not hash.
pub fn canonical_json_bytes(value: &Value) -> Result<Vec<u8>, String> {
    let mut out = String::new();
    write_canonical(value, &mut out)?;
    Ok(out.into_bytes())
}

fn write_canonical(value: &Value, out: &mut String) -> Result<(), String> {
    match value {
        Value::Null => {
            out.push_str("null");
        }
        Value::Bool(b) => {
            out.push_str(if *b { "true" } else { "false" });
        }
        Value::Number(n) => {
            // Catalog v2 (deferred proposal 1, ACCEPTED): the float rule is now
            // PINNED rather than deferred, because a real project with a
            // fractional gain used to produce a journal this suite could not
            // hash at all. See README.md rule 4.
            //
            // - integer-shaped (i64/u64-backed): Display prints plain decimal
            //   digits, matching Python's str(int) / json.dumps(int) exactly.
            // - float-shaped (f64-backed): serde_json's Display is the
            //   shortest round-trip decimal (ryu), which is byte-identical to
            //   Python's repr(float) / json.dumps(float) for every finite f64.
            //   NaN and +/-inf are unrepresentable in JSON and cannot reach
            //   here: serde_json::Number::from_f64 returns None for them and
            //   the parser rejects the literals.
            //
            // Note this NORMALIZES the float token: `1e3` canonicalizes to
            // `1000.0`. That is the rule, not a bug — shortest round-trip is
            // the only cross-language-safe choice, and both languages agree on
            // it. Integer-shaped literals are never normalized to floats.
            write!(out, "{n}").map_err(|e| e.to_string())?;
        }
        Value::String(s) => write_canonical_string(s, out),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_canonical(item, out)?;
            }
            out.push(']');
        }
        Value::Object(map) => write_canonical_object(map, out)?,
    }
    Ok(())
}

fn write_canonical_object(map: &Map<String, Value>, out: &mut String) -> Result<(), String> {
    let mut keys: Vec<&String> = map.keys().collect();
    keys.sort(); // byte-wise ascending (Rust's default str/String Ord)
    out.push('{');
    for (i, k) in keys.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        write_canonical_string(k, out);
        out.push(':');
        write_canonical(&map[*k], out)?;
    }
    out.push('}');
    Ok(())
}

/// JSON string escaping matching Python's `json.dumps(..., ensure_ascii=True)`:
/// the mandatory escapes for `"`, `\`, and control characters (with the
/// standard short forms for \b \f \n \r \t, \u00XX for the rest), and every
/// code point above U+007E escaped as `\uXXXX` (lowercase hex), with astral
/// characters (beyond U+FFFF) split into a UTF-16 surrogate pair the same way
/// Python's encoder does, since JSON string escapes are defined over UTF-16
/// code units.
fn write_canonical_string(s: &str, out: &mut String) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                write!(out, "\\u{:04x}", c as u32).unwrap();
            }
            c if (c as u32) <= 0x7E => out.push(c),
            c => {
                let cp = c as u32;
                if cp <= 0xFFFF {
                    write!(out, "\\u{cp:04x}").unwrap();
                } else {
                    let v = cp - 0x10000;
                    let high = 0xD800 + (v >> 10);
                    let low = 0xDC00 + (v & 0x3FF);
                    write!(out, "\\u{high:04x}\\u{low:04x}").unwrap();
                }
            }
        }
    }
    out.push('"');
}

/// The 7-field object that gets canonicalized+hashed for a journal entry:
/// every field in `entry` except `hash`.
pub fn envelope_hashed_payload(entry: &Map<String, Value>) -> Map<String, Value> {
    let mut payload = Map::new();
    for &field in ENVELOPE_HASHED_FIELDS.iter() {
        if let Some(v) = entry.get(field) {
            payload.insert(field.to_string(), v.clone());
        }
    }
    payload
}

/// `hash(n) = blake3_hex(ascii(prev_hash_hex) ++ utf8(canonical_json(entry_without_hash)))`
pub fn compute_entry_hash(prev_hash_hex: &str, entry: &Map<String, Value>) -> Result<String, String> {
    let payload = envelope_hashed_payload(entry);
    let canonical = canonical_json_bytes(&Value::Object(payload))?;
    let mut hasher = blake3::Hasher::new();
    hasher.update(prev_hash_hex.as_bytes());
    hasher.update(&canonical);
    Ok(hasher.finalize().to_hex().to_string())
}

/// Recomputes the hash chain over a sequence of parsed journal entries.
/// Returns `Ok((tip_hash, count))` if every stored `hash` matches the
/// recomputed value; `Err((index, expected))` at the first mismatch (index is
/// 0-based into `entries`).
pub fn verify_chain(entries: &[Value]) -> Result<(String, usize), (usize, String)> {
    let mut prev = GENESIS_HASH.to_string();
    for (i, entry) in entries.iter().enumerate() {
        let map = entry.as_object().expect("journal entry must be a JSON object");
        let expected = compute_entry_hash(&prev, map).expect("hashing a journal fixture entry must not fail");
        let stored = map.get("hash").and_then(Value::as_str).unwrap_or("");
        if expected != stored {
            return Err((i, expected));
        }
        prev = expected;
    }
    Ok((prev, entries.len()))
}

/// Compile `schema` (a JSON Schema document, already `serde_json::Value`) and
/// validate `instance` against it. Returns the list of error messages (empty
/// = valid).
pub fn validate(schema: &Value, instance: &Value) -> Vec<String> {
    let validator = match jsonschema::validator_for(schema) {
        Ok(v) => v,
        Err(e) => return vec![format!("schema failed to compile: {e}")],
    };
    validator
        .iter_errors(instance)
        .map(|e| format!("{e} at {}", e.instance_path))
        .collect()
}

/// Build `{ ...schema, "$ref": fragment }` the same way the Python suite's
/// `sub_validator` helper does, so a single multi-`$defs` schema document can
/// be pointed at one definition for validation.
pub fn schema_ref(schema: &Value, fragment: &str) -> Value {
    let mut obj = schema.as_object().expect("schema must be a JSON object").clone();
    obj.insert("$ref".to_string(), Value::String(fragment.to_string()));
    Value::Object(obj)
}

#[cfg(test)]
mod unit_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn genesis_hash_is_64_zero_chars() {
        assert_eq!(GENESIS_HASH.len(), 64);
        assert!(GENESIS_HASH.chars().all(|c| c == '0'));
    }

    #[test]
    fn canonical_sorts_keys_recursively() {
        let v = json!({"b": {"z": 1, "a": 2}, "a": 1});
        let bytes = canonical_json_bytes(&v).unwrap();
        assert_eq!(String::from_utf8(bytes).unwrap(), r#"{"a":1,"b":{"a":2,"z":1}}"#);
    }

    #[test]
    fn canonical_accepts_float_as_shortest_round_trip() {
        // Catalog v2 pinned the float rule (deferred proposal 1). This used to
        // assert rejection, which is exactly what made a project with a
        // fractional gain unhashable by this suite.
        let v = json!({"bpm": 92.5});
        assert_eq!(
            String::from_utf8(canonical_json_bytes(&v).unwrap()).unwrap(),
            r#"{"bpm":92.5}"#
        );
    }

    #[test]
    fn canonical_accepts_integer_shaped_number() {
        let v = json!({"bpm": 92});
        let bytes = canonical_json_bytes(&v).unwrap();
        assert_eq!(String::from_utf8(bytes).unwrap(), r#"{"bpm":92}"#);
    }

    #[test]
    fn canonical_escapes_non_ascii_and_control_chars() {
        // Input built entirely from \u{..} escapes so no raw non-ASCII bytes
        // appear in this source file: 'h' + LATIN SMALL LETTER E WITH ACUTE
        // (U+00E9) + "llo" + TAB + 'world"quote"'. Expected output generated
        // from Python's json.dumps(s, ensure_ascii=True) as ground truth (see
        // docs/evidence/p0c-contracts.md) and transcribed via escapes, not by
        // pasting literal characters, so nothing here depends on eyeballing.
        let v = json!("h\u{e9}llo\tworld\"quote\"");
        let bytes = canonical_json_bytes(&v).unwrap();
        let text = String::from_utf8(bytes).unwrap();
        assert_eq!(text, "\"h\\u00e9llo\\tworld\\\"quote\\\"\"");
    }

    #[test]
    fn canonical_escapes_astral_char_as_surrogate_pair() {
        // U+1F600 GRINNING FACE, input via \u{..} escape (no raw bytes in
        // source). Expected UTF-16 surrogate pair (😀) likewise
        // generated from Python's json.dumps ground truth.
        let v = json!("\u{1F600}");
        let bytes = canonical_json_bytes(&v).unwrap();
        let text = String::from_utf8(bytes).unwrap();
        assert_eq!(text, "\"\\ud83d\\ude00\"");
    }

    #[test]
    fn known_blake3_vector_empty_string() {
        let h = blake3::hash(b"").to_hex().to_string();
        assert_eq!(h, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262");
    }
}
