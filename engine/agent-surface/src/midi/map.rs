use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MidiMap {
    pub version: u8,
    pub name: String,
    pub device: DeviceMatch,
    #[serde(default)] pub author: Option<String>,
    #[serde(default)] pub tested: bool,
    #[serde(default, rename = "sourceUrl")] pub source_url: Option<String>,
    #[serde(default, rename = "unsupportedReason")] pub unsupported_reason: Option<String>,
    pub bindings: Vec<Binding>,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DeviceMatch { #[serde(rename = "namePatterns", default)] pub name_patterns: Vec<String> }
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Binding {
    pub id: String,
    pub label: String,
    #[serde(rename = "match")] pub control: ControlMatch,
    pub target: Target,
    #[serde(default, rename = "valueMap")] pub value_map: Option<ValueMap>,
    #[serde(default = "enabled")] pub enabled: bool,
    #[serde(default)] pub comment: Option<String>,
}
fn enabled() -> bool { true }
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type")]
pub enum ControlMatch {
    #[serde(rename = "noteOn")] NoteOn { channel: u8, number: u8 },
    #[serde(rename = "noteOff")] NoteOff { channel: u8, number: u8 },
    #[serde(rename = "controlChange")] ControlChange { channel: u8, number: u8 },
    #[serde(rename = "pitchBend")] PitchBend { channel: u8 },
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind")]
pub enum Target {
    // params defaults to `{}` so a no-argument command (transport.stop,
    // transport.loop.clear, transport.play) may omit it in a map file.
    #[serde(rename = "command")] Command { name: String, #[serde(default = "empty_params")] params: Value },
    #[serde(rename = "builtin")] Builtin { name: String, #[serde(default = "empty_params")] params: Value },
    #[serde(rename = "sterling")] Sterling { instruction: String },
}
fn empty_params() -> Value { Value::Object(serde_json::Map::new()) }
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ValueMap {
    // All four ranges are optional-with-defaults in the catalog schema
    // (0/127/0/1), so a partial or empty valueMap must deserialize, not error.
    #[serde(rename = "inputMin", default = "vm_in_min")] pub input_min: f64,
    #[serde(rename = "inputMax", default = "vm_in_max")] pub input_max: f64,
    #[serde(rename = "outputMin", default = "vm_out_min")] pub output_min: f64,
    #[serde(rename = "outputMax", default = "vm_out_max")] pub output_max: f64,
    #[serde(default)] pub curve: Curve,
}
fn vm_in_min() -> f64 { 0.0 }
fn vm_in_max() -> f64 { 127.0 }
fn vm_out_min() -> f64 { 0.0 }
fn vm_out_max() -> f64 { 1.0 }
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "lowercase")]
pub enum Curve { #[default] Linear, Exponential, Logarithmic }

impl ControlMatch {
    pub fn specificity(&self, event: &crate::midi::event::MidiEvent) -> Option<u8> {
        use crate::midi::event::MidiEvent::*;
        match (self, event) {
            (Self::NoteOn { channel, number }, NoteOn { channel: c, note, .. }) if channel == c && number == note => Some(3),
            (Self::NoteOff { channel, number }, NoteOff { channel: c, note, .. }) if channel == c && number == note => Some(3),
            (Self::ControlChange { channel, number }, ControlChange { channel: c, controller, .. }) if channel == c && number == controller => Some(3),
            (Self::PitchBend { channel }, PitchBend { channel: c, .. }) if channel == c => Some(2),
            _ => None,
        }
    }
}
pub fn validate_map(map: &MidiMap) -> Result<(), String> {
    if map.version != 1 { return Err("version must be 1".into()); }
    let mut ids = std::collections::HashSet::new();
    for b in &map.bindings {
        if !ids.insert(&b.id) { return Err(format!("duplicate binding id {}", b.id)); }
        let channel = match b.control { ControlMatch::NoteOn { channel, .. } | ControlMatch::NoteOff { channel, .. } | ControlMatch::ControlChange { channel, .. } | ControlMatch::PitchBend { channel } => channel };
        if channel > 15 { return Err(format!("binding {} channel out of range", b.id)); }
        if let Target::Builtin { name, .. } = &b.target {
            if !matches!(name.as_str(), "transport.toggle" | "record.toggle" | "metronome.toggle" | "undo" | "redo" | "mix.gain.nudge") { return Err(format!("unknown builtin {name}")); }
        }
        if let Target::Command { name, params } = &b.target {
            if name.starts_with("gen.") || name.starts_with("txn.") || matches!(name.as_str(), "project.new" | "project.open" | "studio.importStemSession") { return Err(format!("lifecycle/protocol target {name} is not allowed")); }
            timeline_core::catalog::Catalog::get().validate_params(name, &probe_params(params)).map_err(|e| format!("binding {} target: {e}", b.id))?;
        }
    }
    Ok(())
}

fn probe_params(value: &Value) -> Value {
    match value {
        Value::String(s) if s == "$value" => Value::from(0.0),
        Value::String(s) if s.starts_with("$track:") => Value::from("probe-track"),
        Value::Array(a) => Value::Array(a.iter().map(probe_params).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k,v)|(k.clone(),probe_params(v))).collect()),
        _ => value.clone(),
    }
}

pub fn match_specificity(map: &MidiMap, port: &str) -> usize {
    map.device.name_patterns.iter().filter(|p| port.to_ascii_lowercase().contains(&p.to_ascii_lowercase())).map(|p| p.len()).max().unwrap_or(0)
}
