use serde_json::{json, Value};
use super::{event::MidiEvent, map::{Binding, Curve, Target, ValueMap}};

#[derive(Debug, Clone, PartialEq)]
pub enum Prepared { Command { name: String, params: Value }, Sterling { instruction: String, binding_id: String } }
#[derive(Debug, Clone, Default)]
pub struct DispatchCtx { pub playing: bool, pub recording: bool, pub metronome: bool, pub armed_track_id: Option<String>, pub track_ids: Vec<String>, pub track_gains_db: Vec<f64> }

pub fn map_value(map: Option<&ValueMap>, raw: f64) -> f64 {
    let Some(m) = map else { return raw / 127.0 };
    let x = ((raw - m.input_min) / (m.input_max - m.input_min)).clamp(0.0, 1.0);
    let y = match m.curve { Curve::Linear => x, Curve::Exponential => x * x, Curve::Logarithmic => (1.0 + 9.0 * x).ln() / 10.0_f64.ln() };
    m.output_min + y * (m.output_max - m.output_min)
}
/// The highest-specificity binding matching `event` (first in file order on a
/// specificity tie), regardless of `enabled`. Callers gate on enabled.
pub fn matched_binding<'a>(event: &MidiEvent, bindings: &'a [Binding]) -> Option<&'a Binding> {
    let mut best: Option<(&Binding, u8)> = None;
    for b in bindings {
        if let Some(s) = b.control.specificity(event) {
            if best.map_or(true, |(_, bs)| s > bs) { best = Some((b, s)); }
        }
    }
    best.map(|(b, _)| b)
}

/// A binding whose command template carries `$value` is a fader: its events
/// coalesce to the latest value (spec 2.4). Everything else is a button.
pub fn binding_is_continuous(b: &Binding) -> bool {
    matches!(&b.target, Target::Command { params, .. } if contains_value(params))
}
fn contains_value(v: &Value) -> bool {
    match v {
        Value::String(s) => s == "$value",
        Value::Array(a) => a.iter().any(contains_value),
        Value::Object(o) => o.values().any(contains_value),
        _ => false,
    }
}

pub fn resolve(event: &MidiEvent, ctx: &DispatchCtx, bindings: &[Binding]) -> Vec<Prepared> {
    let raw = match event { MidiEvent::NoteOn { velocity, .. } | MidiEvent::NoteOff { velocity, .. } => *velocity as f64, MidiEvent::ControlChange { value, .. } => *value as f64, MidiEvent::PitchBend { value, .. } => *value as f64 };
    let Some(b) = matched_binding(event, bindings) else { return vec![] };
    if !b.enabled { return vec![] }
    match &b.target {
        Target::Sterling { instruction } => vec![Prepared::Sterling { instruction: instruction.clone(), binding_id: b.id.clone() }],
        Target::Builtin { name, params } => builtin(name, params, b, ctx),
        Target::Command { name, params } => substitute(name, params, b, ctx, map_value(b.value_map.as_ref(), raw)),
    }
}
fn builtin(name: &str, params: &Value, b: &Binding, ctx: &DispatchCtx) -> Vec<Prepared> {
    match name {
        "transport.toggle" => vec![cmd(if ctx.playing { "transport.stop" } else { "transport.play" }, json!({}))],
        "record.toggle" => if ctx.recording { vec![cmd("record.stop", json!({}))] } else { ctx.armed_track_id.as_ref().map(|id| vec![cmd("record.start", json!({"trackId":id}))]).unwrap_or_default() },
        "metronome.toggle" => vec![cmd("transport.metronome", json!({"enabled": !ctx.metronome}))],
        "undo" | "redo" => vec![cmd(name, json!({}))],
        "mix.gain.nudge" => {
            // Accept "$track:N" (index) or a literal track id (spec 5.3 documents both).
            let track = params.get("trackId").and_then(Value::as_str).and_then(|s| {
                s.strip_prefix("$track:").and_then(|n| n.parse::<usize>().ok())
                    .or_else(|| ctx.track_ids.iter().position(|id| id == s))
            });
            let Some(i) = track.filter(|i| *i < ctx.track_ids.len()) else { return vec![] };
            let delta = params.get("deltaDb").and_then(Value::as_f64).unwrap_or(0.0);
            let gain = ctx.track_gains_db.get(i).copied().unwrap_or(0.0);
            vec![cmd("mix.gain", json!({"trackId":ctx.track_ids[i],"gainDb":(gain + delta).clamp(-60.0, 12.0)}))]
        }
        _ => { let _ = b; vec![] }
    }
}
fn cmd(name: &str, params: Value) -> Prepared { Prepared::Command { name: name.into(), params } }
fn substitute(name: &str, template: &Value, _b: &Binding, ctx: &DispatchCtx, value: f64) -> Vec<Prepared> {
    let mut p = template.clone();
    if !replace(&mut p, ctx, value) { return vec![] }
    vec![cmd(name, p)]
}
fn replace(v: &mut Value, ctx: &DispatchCtx, value: f64) -> bool {
    match v {
        Value::String(s) if s == "$value" => { *v = json!(value); true }
        Value::String(s) if s.starts_with("$track:") => { let Ok(i) = s[7..].parse::<usize>() else { return false }; let Some(id) = ctx.track_ids.get(i) else { return false }; *v = json!(id); true }
        Value::Array(a) => a.iter_mut().all(|x| replace(x, ctx, value)),
        Value::Object(o) => o.values_mut().all(|x| replace(x, ctx, value)),
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*; use crate::midi::map::*;
    fn b(target: Target) -> Binding { Binding { id:"x".into(), label:"x".into(), control:ControlMatch::ControlChange{channel:0,number:7}, target, value_map:None, enabled:true, comment:None } }
    #[test] fn placeholder_and_toggle() { let out=resolve(&MidiEvent::ControlChange{controller:7,value:64,channel:0}, &DispatchCtx{track_ids:vec!["t1".into()] ,..Default::default()}, &[b(Target::Command{name:"mix.gain".into(),params:json!({"trackId":"$track:0","gainDb":"$value"})})]); assert_eq!(out, vec![Prepared::Command{name:"mix.gain".into(),params:json!({"trackId":"t1","gainDb":64.0/127.0})}]); }
    #[test] fn curve_math() { assert_eq!(map_value(None, 127.0), 1.0); }
}
