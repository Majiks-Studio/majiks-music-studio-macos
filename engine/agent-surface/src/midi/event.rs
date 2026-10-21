use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum MidiEvent {
    NoteOn { note: u8, velocity: u8, channel: u8 },
    NoteOff { note: u8, velocity: u8, channel: u8 },
    ControlChange { controller: u8, value: u8, channel: u8 },
    PitchBend { value: i16, channel: u8 },
}

impl MidiEvent {
    pub fn from_bytes(bytes: &[u8]) -> Option<Self> {
        if bytes.len() < 3 { return None; }
        let channel = bytes[0] & 0x0f;
        match bytes[0] & 0xf0 {
            0x80 => Some(Self::NoteOff { note: bytes[1], velocity: bytes[2], channel }),
            0x90 if bytes[2] == 0 => Some(Self::NoteOff { note: bytes[1], velocity: 0, channel }),
            0x90 => Some(Self::NoteOn { note: bytes[1], velocity: bytes[2], channel }),
            0xb0 => Some(Self::ControlChange { controller: bytes[1], value: bytes[2], channel }),
            0xe0 => Some(Self::PitchBend { value: (((bytes[2] as i16) << 7) | bytes[1] as i16) - 8192, channel }),
            _ => None,
        }
    }

    pub fn event_id(&self) -> String {
        match self {
            Self::NoteOn { note, channel, .. } => format!("note_on_{channel}_{note}"),
            Self::NoteOff { note, channel, .. } => format!("note_off_{channel}_{note}"),
            Self::ControlChange { controller, channel, .. } => format!("cc_{channel}_{controller}"),
            Self::PitchBend { channel, .. } => format!("pb_{channel}"),
        }
    }

    /// The wire `match.type` label (camelCase), matching the map format.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::NoteOn { .. } => "noteOn",
            Self::NoteOff { .. } => "noteOff",
            Self::ControlChange { .. } => "controlChange",
            Self::PitchBend { .. } => "pitchBend",
        }
    }

    pub fn channel(&self) -> u8 {
        match self {
            Self::NoteOn { channel, .. }
            | Self::NoteOff { channel, .. }
            | Self::ControlChange { channel, .. }
            | Self::PitchBend { channel, .. } => *channel,
        }
    }

    /// Note number or CC number; `None` for the channel-wide pitch bend.
    pub fn number(&self) -> Option<u8> {
        match self {
            Self::NoteOn { note, .. } | Self::NoteOff { note, .. } => Some(*note),
            Self::ControlChange { controller, .. } => Some(*controller),
            Self::PitchBend { .. } => None,
        }
    }

    /// The scalar carried by the event: velocity, CC value, or bend amount.
    pub fn value(&self) -> i64 {
        match self {
            Self::NoteOn { velocity, .. } | Self::NoteOff { velocity, .. } => *velocity as i64,
            Self::ControlChange { value, .. } => *value as i64,
            Self::PitchBend { value, .. } => *value as i64,
        }
    }

    /// A continuous control is one whose value sweeps (CC or pitch bend). Note
    /// events are discrete and dispatch per press (spec 2.4).
    pub fn is_continuous(&self) -> bool {
        matches!(self, Self::ControlChange { .. } | Self::PitchBend { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn parses_wire_messages() {
        assert_eq!(MidiEvent::from_bytes(&[0x90, 36, 100]), Some(MidiEvent::NoteOn { note: 36, velocity: 100, channel: 0 }));
        assert_eq!(MidiEvent::from_bytes(&[0x90, 36, 0]), Some(MidiEvent::NoteOff { note: 36, velocity: 0, channel: 0 }));
        assert_eq!(MidiEvent::from_bytes(&[0xe0, 0, 64]), Some(MidiEvent::PitchBend { value: 0, channel: 0 }));
    }
}
