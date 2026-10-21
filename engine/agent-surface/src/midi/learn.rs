use serde_json::{json, Value};
use super::event::MidiEvent;

#[derive(Debug, Clone, Default)]
pub struct LearnSession { pub active: bool, pub device: Option<String>, pub captured: Option<Value>, pub started: Option<std::time::Instant> }
impl LearnSession {
    pub fn start(&mut self, device: Option<String>) { self.active = true; self.device = device; self.captured = None; self.started = Some(std::time::Instant::now()); }
    pub fn stop(&mut self) { self.active = false; self.device = None; self.started = None; }
    pub fn offer(&mut self, device: &str, event: &MidiEvent) -> bool {
        if !self.active || self.device.as_deref().is_some_and(|d| d != device) { return false; }
        self.captured = Some(describe(device, event)); true
    }
    pub fn consume(&mut self) -> Option<Value> { self.captured.take() }
    pub fn json(&self) -> Value {
        let age = if self.active { self.started.map(|t| t.elapsed().as_secs_f64()) } else { None };
        json!({"active": self.active, "device": self.device, "ageSeconds": age, "captured": self.captured, "current": self.captured})
    }
}
fn describe(device: &str, event: &MidiEvent) -> Value {
    match event {
        MidiEvent::NoteOn { note, velocity, channel } | MidiEvent::NoteOff { note, velocity, channel } => json!({"device":device,"type":"noteOn","channel":channel,"number":note,"value":velocity,"valueShape":"button"}),
        MidiEvent::ControlChange { controller, value, channel } => json!({"device":device,"type":"controlChange","channel":channel,"number":controller,"value":value,"valueShape":"continuous"}),
        MidiEvent::PitchBend { value, channel } => json!({"device":device,"type":"pitchBend","channel":channel,"number":null,"value":value,"valueShape":"bipolar14"}),
    }
}
