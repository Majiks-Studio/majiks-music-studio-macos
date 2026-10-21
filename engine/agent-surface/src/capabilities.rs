//! THE CAPABILITY CARD: the closed vocabularies an agent has to choose from,
//! answered by the surface instead of by this repository.
//!
//! Everything here already existed and was simply unreachable from a tool call.
//! `device.param.set` documents its key as "an instrument parameter key from
//! DEVICE_PARAM_KEYS" and then REFUSES anything outside that list; `fx.param.set`
//! says the same about FX_PARAM_KEYS. Both lists are Rust constants
//! (`timeline_core::model`), so an MCP client reading the tool schema was told
//! the name of a set it had no way to resolve — it could learn the rule and not
//! the values, which is the "the app knows and does not say" shape.
//!
//! The preset table is the sharper case. Choosing an instrument's sound is one
//! of the ten things a person does to make a record, and a person does it by
//! clicking "Soft Pad" — not by typing eight numbers. A preset IS a set of
//! `device.param.set` commands (`StudioInstrumentPreset::commands` in the Swift
//! half), so the bus could always express one perfectly; what an agent could not
//! do was FIND OUT that presets exist, what they are called, or what they
//! contain. The values live in `contracts/instrument-presets.v1.json`, which the
//! Rust tone proof renders through the real bus and the Swift table is asserted
//! byte-equal to. This module serves that same file — it does not fork it, for
//! exactly the reason the header of that file gives.
//!
//! READ-ONLY and STATIC: nothing here reads or touches a project, so it answers
//! identically before a project is open. That matters because the first thing an
//! agent does after connecting is ask what it is connected to.

use serde_json::{json, Map, Value};

use timeline_core::catalog::Catalog;
use timeline_core::model::{DEVICE_PARAM_KEYS, FX_PARAM_KEYS};

/// The canonical preset table, embedded rather than read from disk so the tool
/// answers the same in a signed .app as in a dev checkout. Same discipline as
/// `catalog::CATALOG_JSON`: contracts are read-only law, loaded and never
/// forked.
pub const INSTRUMENT_PRESETS_JSON: &str =
    include_str!("../../contracts/instrument-presets.v1.json");

/// The `enum` of one property of one catalog command's params schema.
///
/// Derived from the catalog rather than restated, so `deviceKinds` and `fxKinds`
/// cannot drift from the enums the tool schemas already advertise and `apply.rs`
/// already enforces. A restated copy is a second source of truth, and this file
/// exists because a second source of truth is what went wrong with the presets.
fn schema_enum(command: &str, property: &str) -> Value {
    Catalog::get()
        .spec(command)
        .and_then(|s| s.params_schema.get("properties").cloned())
        .and_then(|p| p.get(property).cloned())
        .and_then(|p| p.get("enum").cloned())
        .unwrap_or_else(|| Value::Array(Vec::new()))
}

/// Everything a caller needs in order to name a sound, a parameter, or an
/// effect correctly on the first try.
pub fn capabilities() -> Value {
    let presets: Value = serde_json::from_str(INSTRUMENT_PRESETS_JSON)
        .expect("embedded instrument preset table must parse");
    let preset_list = presets
        .get("presets")
        .cloned()
        .unwrap_or_else(|| Value::Array(Vec::new()));

    let mut root = Map::new();
    root.insert("catalogVersion".into(), json!(Catalog::get().version()));
    root.insert("commandCount".into(), json!(Catalog::get().len()));
    root.insert("toolCount".into(), json!(crate::registry::tool_defs().len()));

    // ---- instruments ------------------------------------------------------
    root.insert("deviceKinds".into(), schema_enum("device.add", "kind"));
    root.insert("deviceParamKeys".into(), json!(&DEVICE_PARAM_KEYS[..]));
    root.insert("instrumentPresets".into(), preset_list);
    // The honesty note travels WITH the presets. "Electric Piano" is a
    // synthesized approximation and the panel tells a person so in words; an
    // agent about to describe the track to someone needs the same sentence, not
    // a preset name it will reasonably read as a sampled piano.
    root.insert(
        "instrumentPresetsNote".into(),
        presets.get("honesty").cloned().unwrap_or(Value::Null),
    );
    // `waveform` is a rounded index on the wire, not an enum, because automation
    // lanes carry f32 — so the mapping is not recoverable from the schema and
    // has to be stated.
    root.insert(
        "deviceParamNotes".into(),
        json!({
            "waveform": "Rounded index: 0 sine, 1 saw, 2 square, 3 triangle.",
            "sparse": "Instrument parameters are SPARSE: a key you never set reads as the DSP default and is absent from the project. Use device.param.clear to return a key to absent; setting it to what you believe the default is instead materializes a value the undo of a later edit cannot remove."
        }),
    );

    // ---- effects ----------------------------------------------------------
    root.insert("fxKinds".into(), schema_enum("fx.add", "kind"));
    root.insert("fxParamKeys".into(), json!(&FX_PARAM_KEYS[..]));
    root.insert(
        "fxParamNotes".into(),
        json!({
            "perKind": "ONE flat key set is shared across all effect kinds and which keys a given kind honours is deliberately NOT validated, because apply.rs runs on REPLAY. Setting a key its kind ignores succeeds and does nothing; automation bound to one is reported by the compile report's inert lanes rather than refused.",
            "eqBands": "EQ band keys are FLAT (band0Gain, not band.0.gain): the ParamRef grammar gives an effect exactly one parameter segment.",
            "sparse": "Effect parameters are SPARSE, exactly like instrument parameters; fx.param.clear returns a key to absent."
        }),
    );

    // ---- addressing -------------------------------------------------------
    //
    // The two grammars an agent has to get right to automate anything. Both are
    // already in the schemas as regex `pattern`s, which state what is LEGAL and
    // not what any of it MEANS.
    root.insert(
        "nodeRefGrammar".into(),
        json!({
            "form": "master | track.<trackId> | bus.<nodeId>",
            "note": "The fx host / routing endpoint vocabulary. Track strips and master are implicit nodes: they are never added or removed with route.node.add. Master can be an fx host and a routing destination, but never a sidechain key source."
        }),
    );
    root.insert(
        "paramRefFamilies".into(),
        json!([
            { "form": "track.volume", "note": "Reserved v1 spelling; a track's fader. Value in dB." },
            { "form": "track.pan", "note": "Reserved v1 spelling; a track's pan. Value -1..1." },
            { "form": "track.device.<deviceId>.<paramKey>", "note": "An instrument parameter. paramKey is one of deviceParamKeys." },
            { "form": "track.fx.<fxId>.<paramKey>", "note": "A track insert-effect parameter. paramKey is one of fxParamKeys." },
            { "form": "bus.<nodeId>.fx.<fxId>.<paramKey>", "note": "A bus/group insert-effect parameter." },
            { "form": "master.fx.<fxId>.<paramKey>", "note": "A master insert-effect parameter." }
        ]),
    );

    // ---- the pipeline ends ------------------------------------------------
    root.insert(
        "exportFormats".into(),
        schema_enum("export.master", "format"),
    );
    root.insert(
        "loudnessTargets".into(),
        schema_enum("export.master", "loudnessTarget"),
    );
    // The SELECTABLE separators only. The interleave test fixture is in the
    // registry and is deliberately not offered: its stems sum back to the mix
    // but each one is 75% silence, so a caller who found it here would get four
    // unusable stems and a green result.
    root.insert(
        "separators".into(),
        json!(crate::landing::SEPARATOR_REGISTRY
            .iter()
            .filter(|s| s.selectable)
            .map(|s| s.name)
            .collect::<Vec<_>>()),
    );
    root.insert(
        "defaultSeparator".into(),
        json!(crate::landing::DEFAULT_SEPARATOR),
    );

    Value::Object(root)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_vocabularies_are_the_ones_apply_enforces() {
        let c = capabilities();
        assert_eq!(c["deviceParamKeys"], json!(&DEVICE_PARAM_KEYS[..]));
        assert_eq!(c["fxParamKeys"], json!(&FX_PARAM_KEYS[..]));
        assert_eq!(c["commandCount"], json!(Catalog::get().len()));
    }

    /// Every preset key must be a key `device.param.set` will actually accept.
    /// A preset naming a key outside `DEVICE_PARAM_KEYS` would be a sound the
    /// UI offers and the bus refuses.
    #[test]
    fn every_preset_names_only_keys_the_bus_accepts() {
        let c = capabilities();
        let presets = c["instrumentPresets"].as_array().unwrap();
        assert!(!presets.is_empty());
        for p in presets {
            let params = p["params"]
                .as_object()
                .unwrap_or_else(|| panic!("preset {} has no params", p["id"]));
            assert!(!params.is_empty());
            for key in params.keys() {
                assert!(
                    DEVICE_PARAM_KEYS.contains(&key.as_str()),
                    "preset {} names {key}, which device.param.set would refuse",
                    p["id"]
                );
            }
        }
    }

    /// The closed enums come FROM the catalog, so this asserts the derivation
    /// works rather than that a copy was kept in step.
    #[test]
    fn the_kind_enums_come_from_the_catalog() {
        let c = capabilities();
        assert_eq!(c["deviceKinds"], json!(["synth", "sampler", "drum"]));
        assert!(c["fxKinds"]
            .as_array()
            .is_some_and(|k| k.contains(&json!("compressor"))));
        assert_eq!(c["exportFormats"], json!(["wav", "flac", "aac"]));
    }
}
