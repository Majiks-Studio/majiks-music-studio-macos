//! The journal envelope + canonical JSON + blake3 hash chain.
//!
//! This implements the EXACT algorithm in `engine/contracts/README.md`
//! ("Canonicalization and the hash chain"), so the hashes this crate computes
//! are byte-identical to the P0-C conformance suite's. A dev-dependency test
//! (`tests/canonical_matches_contracts.rs`) cross-checks every byte against
//! `contracts_conformance::canonical_json_bytes`.
//!
//! Number handling: the contract fixes v1 hashed params to integer literals
//! and its own canonicalizer REJECTS floats. This canonicalizer is a superset:
//! integers emit byte-identically to the contract, and floats emit via
//! serde_json's shortest-round-trip Display (which agrees with Python's
//! `json.dumps` for every f64). Real fractional params (a gain of -3.5) are
//! therefore representable and self-consistent here, but the cross-language
//! float rule is not yet PINNED in the contract; see proposal P1 in the lane
//! report. No committed fixture exercises a float, so the fixture cross-check
//! is unaffected.

use std::fmt::Write as _;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::cmd::Cmd;
use crate::error::CommandError;

/// 64 ASCII '0': the reserved "no predecessor" hash for a journal's first
/// entry (contract GENESIS_HASH).
pub const GENESIS_HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";

/// The seven logical fields hashed for a journal entry (`hash` excluded).
pub const ENVELOPE_HASHED_FIELDS: [&str; 7] =
    ["id", "ts", "actor", "name", "params", "inverse", "result"];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ActorKind {
    User,
    Agent,
    Api,
    Copilot,
    System,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Actor {
    pub kind: ActorKind,
    pub name: String,
}

impl Actor {
    pub fn user(name: impl Into<String>) -> Self {
        Actor {
            kind: ActorKind::User,
            name: name.into(),
        }
    }

    pub fn system() -> Self {
        Actor {
            kind: ActorKind::System,
            name: "engine".to_string(),
        }
    }

    fn to_value(&self) -> Value {
        let kind = match self.kind {
            ActorKind::User => "user",
            ActorKind::Agent => "agent",
            ActorKind::Api => "api",
            ActorKind::Copilot => "copilot",
            ActorKind::System => "system",
        };
        let mut m = Map::new();
        m.insert("kind".into(), Value::String(kind.to_string()));
        m.insert("name".into(), Value::String(self.name.clone()));
        Value::Object(m)
    }
}

/// Per-entry identity the caller supplies (the core reads no clock, mints no
/// id): a ULID string, a UTC timestamp string, and the actor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EntryMeta {
    pub id: String,
    pub ts: String,
    pub actor: Actor,
}

/// A journaled command entry. `inverse` is the single-command envelope hint
/// (null when the catalog marks the command non-undoable). `result` is
/// `{ok:true}` for a journaled success (failures never journal).
#[derive(Debug, Clone, PartialEq)]
pub struct Envelope {
    pub id: String,
    pub ts: String,
    pub actor: Actor,
    pub name: String,
    pub params: Value,
    pub inverse: Option<InverseRef>,
    pub result: Value,
    pub hash: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct InverseRef {
    pub name: String,
    pub params: Value,
}

impl InverseRef {
    pub fn from_cmd(cmd: &Cmd) -> Self {
        InverseRef {
            name: cmd.name().to_string(),
            params: cmd.params_value(),
        }
    }
}

impl Envelope {
    /// Build the payload object (7 hashed fields, no `hash`) as JSON.
    fn hashed_payload(&self) -> Value {
        let mut m = Map::new();
        m.insert("id".into(), Value::String(self.id.clone()));
        m.insert("ts".into(), Value::String(self.ts.clone()));
        m.insert("actor".into(), self.actor.to_value());
        m.insert("name".into(), Value::String(self.name.clone()));
        m.insert("params".into(), self.params.clone());
        let inverse = match &self.inverse {
            None => Value::Null,
            Some(iref) => {
                let mut im = Map::new();
                im.insert("name".into(), Value::String(iref.name.clone()));
                im.insert("params".into(), iref.params.clone());
                Value::Object(im)
            }
        };
        m.insert("inverse".into(), inverse);
        m.insert("result".into(), self.result.clone());
        Value::Object(m)
    }

    /// The full on-disk line object (8 fields, with `hash`).
    pub fn to_line_value(&self) -> Value {
        let mut v = self.hashed_payload();
        if let Value::Object(m) = &mut v {
            m.insert("hash".into(), Value::String(self.hash.clone()));
        }
        v
    }

    /// Serialize to a single canonical-key JSONL line (for journal.jsonl).
    /// The on-disk line is itself canonical (sorted keys), so a round-trip is
    /// stable, though only the hashed payload's canonical form is what the
    /// chain commits to.
    pub fn to_jsonl(&self) -> String {
        // hash comes last only for human readability; canonical order sorts
        // it in place. We emit canonical form for determinism.
        let mut out = String::new();
        write_canonical(&self.to_line_value(), &mut out).expect("line has no rejected floats");
        out
    }

    /// Compute and attach `hash` from the predecessor hash.
    pub fn finalize(mut self, prev_hash_hex: &str) -> Result<Envelope, CommandError> {
        self.hash = compute_entry_hash(prev_hash_hex, &self.hashed_payload())?;
        Ok(self)
    }

    /// Parse one journal.jsonl line into an Envelope (tolerant of key order).
    pub fn from_line(line: &str) -> Result<Envelope, CommandError> {
        let v: Value = serde_json::from_str(line)
            .map_err(|e| CommandError::Envelope(format!("bad journal line: {e}")))?;
        let obj = v
            .as_object()
            .ok_or_else(|| CommandError::Envelope("journal line is not an object".into()))?;
        let get_str = |k: &str| -> Result<String, CommandError> {
            obj.get(k)
                .and_then(Value::as_str)
                .map(String::from)
                .ok_or_else(|| CommandError::Envelope(format!("journal line missing {k}")))
        };
        let actor_v = obj
            .get("actor")
            .and_then(Value::as_object)
            .ok_or_else(|| CommandError::Envelope("journal line missing actor".into()))?;
        let actor = Actor {
            kind: match actor_v.get("kind").and_then(Value::as_str) {
                Some("user") => ActorKind::User,
                Some("agent") => ActorKind::Agent,
                Some("api") => ActorKind::Api,
                Some("copilot") => ActorKind::Copilot,
                Some("system") => ActorKind::System,
                other => {
                    return Err(CommandError::Envelope(format!(
                        "unknown actor.kind {other:?}"
                    )))
                }
            },
            name: actor_v
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        };
        let inverse = match obj.get("inverse") {
            None | Some(Value::Null) => None,
            Some(Value::Object(im)) => Some(InverseRef {
                name: im
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string(),
                params: im
                    .get("params")
                    .cloned()
                    .unwrap_or(Value::Object(Map::new())),
            }),
            Some(_) => return Err(CommandError::Envelope("inverse is not object|null".into())),
        };
        Ok(Envelope {
            id: get_str("id")?,
            ts: get_str("ts")?,
            actor,
            name: get_str("name")?,
            params: obj
                .get("params")
                .cloned()
                .unwrap_or(Value::Object(Map::new())),
            inverse,
            result: obj.get("result").cloned().unwrap_or_else(|| {
                let mut m = Map::new();
                m.insert("ok".into(), Value::Bool(true));
                Value::Object(m)
            }),
            hash: get_str("hash").unwrap_or_default(),
        })
    }

    /// Recompute this entry's hash from `prev` and check it matches `hash`.
    pub fn verify(&self, prev_hash_hex: &str) -> Result<(), CommandError> {
        let expected = compute_entry_hash(prev_hash_hex, &self.hashed_payload())?;
        if expected != self.hash {
            return Err(CommandError::Envelope(format!(
                "hash mismatch on {}: stored {}, computed {expected}",
                self.id, self.hash
            )));
        }
        Ok(())
    }
}

/// `{"ok":true}` result value.
pub fn result_ok() -> Value {
    let mut m = Map::new();
    m.insert("ok".into(), Value::Bool(true));
    Value::Object(m)
}

/// `hash(n) = blake3_hex(ascii(prev) ++ utf8(canonical(payload)))`.
pub fn compute_entry_hash(prev_hash_hex: &str, payload: &Value) -> Result<String, CommandError> {
    let mut out = String::new();
    write_canonical(payload, &mut out)
        .map_err(|e| CommandError::Envelope(format!("canonicalization failed: {e}")))?;
    let mut hasher = blake3::Hasher::new();
    hasher.update(prev_hash_hex.as_bytes());
    hasher.update(out.as_bytes());
    Ok(hasher.finalize().to_hex().to_string())
}

/// Canonical JSON bytes per the contract (sorted keys at every level, compact
/// separators, ensure_ascii escaping, arrays in source order, no trailing
/// newline). Integers emit as plain digits; floats emit shortest-round-trip.
pub fn canonical_json(value: &Value) -> Result<String, String> {
    let mut out = String::new();
    write_canonical(value, &mut out)?;
    Ok(out)
}

fn write_canonical(value: &Value, out: &mut String) -> Result<(), String> {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => {
            // serde_json's Display: integers -> plain digits (matches the
            // contract exactly); f64 -> shortest round-trip (matches Python
            // json.dumps for every f64). See module note + proposal P1.
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
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort(); // byte-wise ascending
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
        }
    }
    Ok(())
}

/// JSON string escaping matching Python's `json.dumps(..., ensure_ascii=True)`.
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
