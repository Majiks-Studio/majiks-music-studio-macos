//! The embedded command catalog: `engine/contracts/command-catalog.v2.json`
//! compiled into the crate (contracts are read-only law; this module loads,
//! never forks, them). One registry instance, parsed on first use.
//!
//! v2 is a STRICT SUPERSET of v1.1 (`DESIGN-catalog-v2.md` §2). v1.1 stays in
//! tree, frozen, and is never edited again; `tests/catalog_superset.rs` proves
//! every v1.1 command is semantically identical in v2 and that schema widening
//! happened only at the enumerated sites.
//!
//! Compat direction is ASYMMETRIC and the error text must say so: a v2 binary
//! opens v1.1 projects; a v1 binary opening a v2 project that uses new commands
//! hard-fails at `Package::open` (unknown command NAME), which is the safe
//! outcome. See `error.rs::CommandError::UnknownCommand`.

use std::collections::HashMap;
use std::sync::OnceLock;

use serde_json::Value;

use crate::error::CommandError;
use crate::schema;

pub const CATALOG_JSON: &str = include_str!("../../contracts/command-catalog.v2.json");

/// The frozen predecessor, embedded ONLY so the superset test can compare
/// against it without touching the filesystem. Nothing else may read this.
pub const CATALOG_V1_1_JSON: &str = include_str!("../../contracts/command-catalog.v1.1.json");

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InverseMode {
    None,
    SelfInverse,
    Explicit,
}

#[derive(Debug, Clone)]
pub struct CommandSpec {
    pub name: String,
    pub category: String,
    pub journaled: bool,
    pub undoable: bool,
    pub inverse_mode: InverseMode,
    pub inverse_name: Option<String>,
    pub params_schema: Value,
    pub flag: Option<String>,
    pub system_authored: bool,
    /// Catalog v2 annotation: the shape of the undo sequence `apply.rs`
    /// actually produces (`none`/`self`/`explicit`/`multi`). Descriptive only;
    /// `tests/inverse_shape.rs` enforces that it matches reality.
    pub inverse_shape: InverseShape,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InverseShape {
    None,
    SelfShaped,
    Explicit,
    Multi,
}

impl InverseShape {
    pub fn as_str(self) -> &'static str {
        match self {
            InverseShape::None => "none",
            InverseShape::SelfShaped => "self",
            InverseShape::Explicit => "explicit",
            InverseShape::Multi => "multi",
        }
    }
}

pub struct Catalog {
    by_name: HashMap<String, CommandSpec>,
    order: Vec<String>,
    version: String,
}

/// v1/v1.1 wrote `catalogVersion` as a JSON number; v2 onward writes a string.
/// Accept both so the frozen files stay readable by the same loader.
fn catalog_version_string(doc: &Value) -> String {
    match doc.get("catalogVersion") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        other => panic!("catalog has no usable catalogVersion: {other:?}"),
    }
}

impl Catalog {
    pub fn get() -> &'static Catalog {
        static INSTANCE: OnceLock<Catalog> = OnceLock::new();
        INSTANCE.get_or_init(|| {
            let doc: Value =
                serde_json::from_str(CATALOG_JSON).expect("embedded catalog must parse");
            let commands = doc
                .get("commands")
                .and_then(Value::as_array)
                .expect("catalog has commands array");
            let mut by_name = HashMap::new();
            let mut order = Vec::new();
            for c in commands {
                let name = c["name"].as_str().expect("command name").to_string();
                let rule = &c["inverseRule"];
                let mode = match rule["mode"].as_str() {
                    Some("self") => InverseMode::SelfInverse,
                    Some("explicit") => InverseMode::Explicit,
                    _ => InverseMode::None,
                };
                let spec = CommandSpec {
                    name: name.clone(),
                    category: c["category"].as_str().unwrap_or("").to_string(),
                    journaled: c["journaled"].as_bool().unwrap_or(false),
                    undoable: c["undoable"].as_bool().unwrap_or(false),
                    inverse_mode: mode,
                    inverse_name: rule.get("name").and_then(Value::as_str).map(String::from),
                    params_schema: c["paramsSchema"].clone(),
                    flag: c.get("flag").and_then(Value::as_str).map(String::from),
                    system_authored: c
                        .get("systemAuthored")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    inverse_shape: match c.get("inverseShape").and_then(Value::as_str) {
                        Some("self") => InverseShape::SelfShaped,
                        Some("explicit") => InverseShape::Explicit,
                        Some("multi") => InverseShape::Multi,
                        Some("none") | None => InverseShape::None,
                        Some(other) => panic!("unknown inverseShape {other:?} for {name}"),
                    },
                };
                order.push(name.clone());
                by_name.insert(name, spec);
            }
            Catalog {
                by_name,
                order,
                version: catalog_version_string(&doc),
            }
        })
    }

    /// The catalog's declared version, read from the embedded JSON rather than
    /// hardcoded (v1.1 duplicated it as a literal in two places and stored it
    /// as a JSON *number*, which is lossy: `1.10 == 1.1`). v2 onward is a
    /// string so `2.10` is distinguishable from `2.1`.
    pub fn version(&self) -> &str {
        &self.version
    }

    pub fn spec(&self, name: &str) -> Option<&CommandSpec> {
        self.by_name.get(name)
    }

    pub fn names(&self) -> &[String] {
        &self.order
    }

    pub fn len(&self) -> usize {
        self.order.len()
    }

    pub fn is_empty(&self) -> bool {
        self.order.is_empty()
    }

    /// Validate a wire params object against the catalog schema for `name`.
    ///
    /// HISTORICAL v1 deviation, now INERT: `clip.crossfade.set` accepts
    /// `lengthTicks: 0` meaning "no crossfade", which v1.1's `exclusiveMinimum`
    /// forbade but the self-inverse rule requires (the pre-state of a first
    /// crossfade is "none"). Catalog v2 accepted the deferred proposal and
    /// widened the schema to `minimum: 0`, so the filter below no longer has
    /// anything to remove. It is kept as a belt-and-braces guard in case the
    /// catalog is ever rolled back, and `crossfade_zero_is_schema_legal_in_v2`
    /// asserts the schema itself now permits zero.
    pub fn validate_params(&self, name: &str, params: &Value) -> Result<(), CommandError> {
        let spec = self
            .spec(name)
            .ok_or_else(|| CommandError::UnknownCommand(name.to_string()))?;
        let mut errors = schema::validate(&spec.params_schema, params);
        let crossfade_zero = name == "clip.crossfade.set"
            && params.get("lengthTicks").and_then(Value::as_u64) == Some(0);
        if crossfade_zero {
            errors.retain(|e| {
                !(e.contains("not above exclusiveMinimum") && e.contains("/lengthTicks"))
            });
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(CommandError::SchemaViolation(format!(
                "{name}: {}",
                errors.join("; ")
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn catalog_loads_all_v2_commands() {
        let cat = Catalog::get();
        assert_eq!(
            cat.len(),
            119,
            "catalog v2 is 119 commands (87 v1.1 + 7 E0/E5 routing/anchor + 7 E1 note + 2 device \
             + 2 device zone + 2 device param + 1 midi port role + 7 E5 fx \
             + track.setInputChannel + record.inputListen + note.timing.set + note.quantize)"
        );
        assert!(cat.spec("clip.place").is_some());
        assert!(cat.spec("marker.remove").is_some());
        assert!(cat.spec("route.connect").is_some());
        assert!(cat.spec("route.node.set").is_some());
        assert!(cat.spec("project.setPhaseAnchor").is_some());
        assert!(cat.spec("clip.placeMidi").is_some());
        assert!(cat.spec("note.add").is_some());
        assert!(cat.spec("note.velocity.set").is_some());
        assert!(cat.spec("note.timing.set").is_some());
        assert!(cat.spec("note.quantize").is_some());
        assert!(cat.spec("midi.port.role.set").is_some());
        assert!(cat.spec("nope.nothing").is_none());
    }

    #[test]
    fn version_is_read_from_the_catalog_not_hardcoded() {
        assert_eq!(Catalog::get().version(), "2.0");
        // A string, so 2.10 would not collapse to 2.1 the way the v1.1 JSON
        // number did.
        let doc: Value = serde_json::from_str(CATALOG_JSON).unwrap();
        assert!(doc["catalogVersion"].is_string());
    }

    #[test]
    fn crossfade_zero_is_schema_legal_in_v2() {
        // Not merely tolerated by the validate_params filter: the v2 schema
        // itself accepts it, so the filter is inert.
        let spec = Catalog::get().spec("clip.crossfade.set").unwrap();
        let errors = schema::validate(
            &spec.params_schema,
            &json!({"clipIdA": "a", "clipIdB": "b", "lengthTicks": 0}),
        );
        assert!(errors.is_empty(), "{errors:?}");
    }

    #[test]
    fn validate_rejects_wrong_type_and_extra_props() {
        let cat = Catalog::get();
        assert!(cat
            .validate_params(
                "clip.move",
                &json!({"clipId": "c", "trackId": "t", "startTicks": "0"})
            )
            .is_err());
        assert!(cat
            .validate_params(
                "clip.move",
                &json!({"clipId": "c", "trackId": "t", "startTicks": 0, "zap": 1})
            )
            .is_err());
        assert!(cat
            .validate_params(
                "clip.move",
                &json!({"clipId": "c", "trackId": "t", "startTicks": 0})
            )
            .is_ok());
    }

    #[test]
    fn warp_conditional_required_is_enforced() {
        let cat = Catalog::get();
        assert!(cat
            .validate_params("clip.warp.set", &json!({"clipId": "c", "mode": "ratio"}))
            .is_err());
        assert!(cat
            .validate_params(
                "clip.warp.set",
                &json!({"clipId": "c", "mode": "ratio", "stretchRatio": 1.5})
            )
            .is_ok());
        assert!(cat
            .validate_params("clip.warp.set", &json!({"clipId": "c", "mode": "conform"}))
            .is_ok());
    }

    #[test]
    fn crossfade_zero_length_is_the_documented_deviation() {
        let cat = Catalog::get();
        assert!(cat
            .validate_params(
                "clip.crossfade.set",
                &json!({"clipIdA": "a", "clipIdB": "b", "lengthTicks": 0})
            )
            .is_ok());
        assert!(cat
            .validate_params(
                "clip.crossfade.set",
                &json!({"clipIdA": "a", "clipIdB": "b", "lengthTicks": -1})
            )
            .is_err());
    }
}
