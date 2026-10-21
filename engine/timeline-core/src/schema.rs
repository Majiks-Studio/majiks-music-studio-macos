//! Subset JSON Schema validator for the catalog's `paramsSchema` fragments.
//!
//! The contracts freeze what a paramsSchema may contain
//! (`command-catalog.schema.json` `paramsSchemaFragment`): self-contained
//! object schemas, no `$ref`. This validator supports exactly the constructs
//! the catalog v1 uses (type, required, properties, additionalProperties,
//! enum, const, pattern, minLength, minimum, maximum, exclusiveMinimum,
//! minItems, maxItems, uniqueItems, items, minProperties, propertyNames,
//! if/then, oneOf) and returns a loud error for
//! anything it does not recognize, so a future catalog revision cannot be
//! silently half-validated. Native tests cross-check every verdict against
//! the `jsonschema` crate used by `contracts-conformance`.
//!
//! wasm note: pure Rust (`regex-lite` for patterns), no fs, no threads.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use regex_lite::Regex;
use serde_json::Value;

/// Validate `instance` against `schema`. Empty vec = valid.
pub fn validate(schema: &Value, instance: &Value) -> Vec<String> {
    let mut errors = Vec::new();
    walk(schema, instance, "", &mut errors);
    errors
}

fn compiled(pattern: &str) -> Result<Regex, String> {
    static CACHE: OnceLock<Mutex<HashMap<String, Regex>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut map = cache.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(re) = map.get(pattern) {
        return Ok(re.clone());
    }
    let re = Regex::new(pattern).map_err(|e| format!("unsupported pattern {pattern:?}: {e}"))?;
    map.insert(pattern.to_string(), re.clone());
    Ok(re)
}

fn type_name(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(n) => {
            if n.is_f64() {
                "number"
            } else {
                "integer"
            }
        }
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn matches_type(want: &str, v: &Value) -> bool {
    match want {
        "object" => v.is_object(),
        "array" => v.is_array(),
        "string" => v.is_string(),
        "boolean" => v.is_boolean(),
        "null" => v.is_null(),
        "number" => v.is_number(),
        // JSON Schema: an integer is any number with a zero fractional part.
        "integer" => match v.as_f64() {
            Some(f) => v.is_number() && f.fract() == 0.0,
            None => v.is_i64() || v.is_u64(),
        },
        other => {
            // Unknown type keyword: treated as mismatch, reported by caller.
            let _ = other;
            false
        }
    }
}

const KNOWN_KEYWORDS: [&str; 22] = [
    "type",
    "required",
    "properties",
    "additionalProperties",
    "enum",
    "const",
    "pattern",
    "minLength",
    "minimum",
    "maximum",
    "exclusiveMinimum",
    "minItems",
    "items",
    "minProperties",
    "if",
    "then",
    "default",
    "description",
    "oneOf",
    // Catalog v2. `uniqueItems` and `maxItems` were already USED by v1.1's
    // gen.revise scope array (the L9 proposal), but this validator did not
    // know them, so the array branch of that oneOf failed to compile and the
    // whole oneOf matched zero schemas. Result: a shipped v1.1 feature was
    // rejected at the live-submit boundary while the real jsonschema crate
    // accepted it. See tests/deferred_proposals.rs::p7_*.
    "uniqueItems",
    "maxItems",
    "propertyNames",
];

fn walk(schema: &Value, instance: &Value, path: &str, errors: &mut Vec<String>) {
    let Some(obj) = schema.as_object() else {
        if let Some(true) = schema.as_bool() {
            return;
        }
        if let Some(false) = schema.as_bool() {
            errors.push(format!("{path}: schema false permits nothing"));
            return;
        }
        errors.push(format!("{path}: unsupported schema form"));
        return;
    };

    for key in obj.keys() {
        if !KNOWN_KEYWORDS.contains(&key.as_str()) {
            errors.push(format!(
                "{path}: schema keyword {key:?} is outside the supported catalog subset"
            ));
            return;
        }
    }

    if let Some(options) = obj.get("oneOf").and_then(Value::as_array) {
        let matches = options
            .iter()
            .filter(|option| validate(option, instance).is_empty())
            .count();
        if matches != 1 {
            errors.push(format!(
                "{path}: oneOf requires exactly one matching schema, got {matches}"
            ));
        }
        return;
    }

    if let Some(t) = obj.get("type") {
        let ok = match t {
            Value::String(s) => matches_type(s, instance),
            Value::Array(list) => list
                .iter()
                .filter_map(|x| x.as_str())
                .any(|s| matches_type(s, instance)),
            _ => false,
        };
        if !ok {
            errors.push(format!(
                "{path}: expected type {t}, got {}",
                type_name(instance)
            ));
            return;
        }
    }

    if let Some(expected) = obj.get("const") {
        if !json_eq(expected, instance) {
            errors.push(format!("{path}: value must equal const {expected}"));
        }
    }

    if let Some(options) = obj.get("enum").and_then(Value::as_array) {
        if !options.iter().any(|o| json_eq(o, instance)) {
            errors.push(format!("{path}: value {instance} not in enum"));
        }
    }

    match instance {
        Value::String(s) => {
            if let Some(min) = obj.get("minLength").and_then(Value::as_u64) {
                if (s.chars().count() as u64) < min {
                    errors.push(format!("{path}: string shorter than minLength {min}"));
                }
            }
            if let Some(pattern) = obj.get("pattern").and_then(Value::as_str) {
                match compiled(pattern) {
                    Ok(re) => {
                        if !re.is_match(s) {
                            errors
                                .push(format!("{path}: {s:?} does not match pattern {pattern:?}"));
                        }
                    }
                    Err(e) => errors.push(format!("{path}: {e}")),
                }
            }
        }
        Value::Number(n) => {
            let v = n.as_f64().unwrap_or(0.0);
            if let Some(min) = obj.get("minimum").and_then(Value::as_f64) {
                if v < min {
                    errors.push(format!("{path}: {v} below minimum {min}"));
                }
            }
            if let Some(max) = obj.get("maximum").and_then(Value::as_f64) {
                if v > max {
                    errors.push(format!("{path}: {v} above maximum {max}"));
                }
            }
            if let Some(xmin) = obj.get("exclusiveMinimum").and_then(Value::as_f64) {
                if v <= xmin {
                    errors.push(format!("{path}: {v} not above exclusiveMinimum {xmin}"));
                }
            }
        }
        Value::Array(items) => {
            if let Some(min) = obj.get("minItems").and_then(Value::as_u64) {
                if (items.len() as u64) < min {
                    errors.push(format!("{path}: fewer than minItems {min}"));
                }
            }
            if let Some(max) = obj.get("maxItems").and_then(Value::as_u64) {
                if (items.len() as u64) > max {
                    errors.push(format!("{path}: more than maxItems {max}"));
                }
            }
            if obj.get("uniqueItems").and_then(Value::as_bool) == Some(true) {
                for i in 1..items.len() {
                    if items[..i].contains(&items[i]) {
                        errors.push(format!("{path}[{i}]: duplicate, uniqueItems is true"));
                    }
                }
            }
            if let Some(item_schema) = obj.get("items") {
                for (i, item) in items.iter().enumerate() {
                    walk(item_schema, item, &format!("{path}[{i}]"), errors);
                }
            }
        }
        Value::Object(map) => {
            if let Some(names) = obj.get("propertyNames") {
                for k in map.keys() {
                    walk(
                        names,
                        &Value::String(k.clone()),
                        &format!("{path}/{k} (propertyNames)"),
                        errors,
                    );
                }
            }
            if let Some(min) = obj.get("minProperties").and_then(Value::as_u64) {
                if (map.len() as u64) < min {
                    errors.push(format!("{path}: fewer than minProperties {min}"));
                }
            }
            if let Some(required) = obj.get("required").and_then(Value::as_array) {
                for r in required.iter().filter_map(Value::as_str) {
                    if !map.contains_key(r) {
                        errors.push(format!("{path}: missing required property {r:?}"));
                    }
                }
            }
            let props = obj.get("properties").and_then(Value::as_object);
            if let Some(props) = props {
                for (k, sub) in props {
                    if let Some(v) = map.get(k) {
                        walk(sub, v, &format!("{path}/{k}"), errors);
                    }
                }
            }
            match obj.get("additionalProperties") {
                Some(Value::Bool(false)) => {
                    for k in map.keys() {
                        let declared = props.map(|p| p.contains_key(k)).unwrap_or(false);
                        if !declared {
                            errors.push(format!("{path}: additional property {k:?} not allowed"));
                        }
                    }
                }
                Some(Value::Object(_)) => {
                    let ap = obj.get("additionalProperties").unwrap();
                    for (k, v) in map {
                        let declared = props.map(|p| p.contains_key(k)).unwrap_or(false);
                        if !declared {
                            walk(ap, v, &format!("{path}/{k}"), errors);
                        }
                    }
                }
                _ => {}
            }
        }
        _ => {}
    }

    // if/then (the catalog uses it for conditional requireds, e.g.
    // clip.warp.set: mode == "ratio" requires stretchRatio).
    if let Some(cond) = obj.get("if") {
        let mut cond_errors = Vec::new();
        walk(cond, instance, path, &mut cond_errors);
        if cond_errors.is_empty() {
            if let Some(then) = obj.get("then") {
                walk(then, instance, path, errors);
            }
        }
    }
}

/// JSON equality where integer-shaped and float-shaped numbers compare by
/// numeric value (matching JSON Schema semantics for enum/const).
fn json_eq(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        _ => a == b,
    }
}
