//! The instrument NODE: the thing that consumes the E1 note seam and produces
//! audio, and the flat parameter set that the E0 dense lane table addresses.
//!
//! ## How a parameter reaches an instrument (no new contract needed)
//!
//! E0 already made this work end to end and E2 rebuilds none of it:
//!
//! ```text
//!   ParamRef("track.device.<deviceId>.cutoff")           timeline-core/src/paramref.rs:119,163
//!     -> compile.rs resolves it to a DENSE LANE SLOT      (RtSession::lane_index)
//!     -> Strip::lane_value(lane, slot, frame, default)    render/src/strip.rs (the GENERAL path)
//!     -> InstrumentParams.set(param_index, value)         here, per frame
//!     -> Slew inside the instrument                       arrives exactly on target
//! ```
//!
//! `INSTRUMENT_PARAM_KEYS` is the single source of truth for the `param`
//! segment of that ParamRef. `ParamRef` splits on `.` into exactly four
//! segments, so every key here is one token with no dots — that is a hard
//! constraint from `paramref.rs`, not a style choice.
//!
//! ## Per-frame rule
//!
//! `render_frame` is the ONLY entry point and it advances exactly one frame of
//! everything: the note cursor, every voice, every ramp. There is no
//! block-rate code path in this module, which is what makes an instrument
//! invisible to block size and therefore keeps the bounce bit-identical.

use crate::dsp::drum::DrumRack;
use crate::dsp::note::{NoteEvent, NoteSchedule};
use crate::dsp::sampler::Sampler;
use crate::dsp::synth::Synth;
use crate::dsp::voice::DEFAULT_MAX_VOICES;

/// The `param` segment of `ParamRef::TrackDeviceParam` for every E2
/// instrument parameter, in slot order. ONE token each (no dots) — see the
/// module note.
///
/// The set is deliberately flat and shared across the three instruments
/// rather than per-kind: the lane table is dense and indexed, so a shared
/// layout means the sampler and the drum rack cost nothing extra and a device
/// swap does not invalidate baked lanes. An instrument simply ignores the
/// fields it has no use for.
pub const INSTRUMENT_PARAM_KEYS: [&str; 10] = [
    "waveform",
    "cutoff",
    "resonance",
    "attack",
    "decay",
    "sustain",
    "release",
    "gain",
    "transpose",
    "fine",
];

/// Number of instrument parameter slots. Fixed-size arrays on the audio-thread
/// path (`RtTrack`'s ParamRef->lane-slot map) size themselves off this.
pub const INSTRUMENT_PARAM_COUNT: usize = INSTRUMENT_PARAM_KEYS.len();

pub const PARAM_WAVEFORM: usize = 0;
pub const PARAM_CUTOFF: usize = 1;
pub const PARAM_RESONANCE: usize = 2;
pub const PARAM_ATTACK: usize = 3;
pub const PARAM_DECAY: usize = 4;
pub const PARAM_SUSTAIN: usize = 5;
pub const PARAM_RELEASE: usize = 6;
pub const PARAM_GAIN: usize = 7;
pub const PARAM_TRANSPOSE: usize = 8;
pub const PARAM_FINE: usize = 9;

/// One frame's worth of instrument parameter TARGETS. `Copy`, no allocation.
/// The caller folds automation in before handing it over, exactly as `Strip`
/// does for volume (`target = atomic * lane_value`, then `slew.advance`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InstrumentParams {
    /// 0 sine, 1 saw, 2 square, 3 triangle. Ignored by `sampler` and `drum`,
    /// which play recordings — see `Instrument::render_frame`.
    pub waveform: f32,
    pub cutoff_hz: f32,
    /// 0..=1.
    pub resonance: f32,
    pub attack_s: f32,
    pub decay_s: f32,
    /// 0..=1.
    pub sustain: f32,
    pub release_s: f32,
    pub gain_db: f32,
    /// Semitones.
    pub transpose: f32,
    /// Cents.
    pub fine_cents: f32,
}

impl Default for InstrumentParams {
    fn default() -> Self {
        Self {
            // TRIANGLE (3), not saw.
            //
            // A saw is the useful default for someone SUBTRACTING — you start
            // with every harmonic and take them away. It is the worst possible
            // default for someone pressing a key for the first time, which is
            // what actually happens here: this is the sound of every new synth
            // track, including the one `preview_note` auto-creates for a person
            // who has never opened the instrument panel. A raw sawtooth is the
            // harshest of the four waveforms and it was, until the
            // `device.param.set` command landed beside this change, the app's
            // ONLY instrument sound — nothing in the GUI could pick another.
            //
            // Triangle is the soft one: its harmonics fall off as 1/n^2 (see
            // osc.rs), so it is round and flute-like where the saw is buzzy,
            // and it survives the 4K-TV-across-the-room listening position that
            // this product is actually used at.
            //
            // Only `waveform` moves. The ADSR and gain below are deliberately
            // untouched, because `InstrumentParams` is SHARED with the sampler
            // (which reads the same envelope for every recording it plays) and
            // a percussive default here would have silently put a decay on
            // every sampled instrument in the vault. The envelope shaping that
            // makes an Electric Piano or a Pad belongs in a PRESET, which is
            // per-device, not in a default that three instruments share.
            //
            // Safe to move: `e5_params_seam.rs`'s pinned blake3 legacy-null
            // bounce (`7f2d161c…d5ae`, 240,000 frames) contains three imported
            // audio clips and no instrument at all, so no synth voice is inside
            // it. Checked before changing this, not after.
            waveform: 3.0,
            cutoff_hz: 12_000.0,
            resonance: 0.15,
            attack_s: 0.005,
            decay_s: 0.120,
            sustain: 0.75,
            release_s: 0.200,
            // -6 dB, so 32 voices of a full-scale osc do not slam the master.
            gain_db: -6.0,
            transpose: 0.0,
            fine_cents: 0.0,
        }
    }
}

impl InstrumentParams {
    /// ParamRef `param` segment -> dense slot. `None` means "this build does
    /// not know this parameter", which `paramref.rs` already treats as a
    /// normal, preserved outcome rather than an error.
    pub fn index_of(key: &str) -> Option<usize> {
        INSTRUMENT_PARAM_KEYS.iter().position(|k| *k == key)
    }

    pub fn get(&self, slot: usize) -> f32 {
        match slot {
            PARAM_WAVEFORM => self.waveform,
            PARAM_CUTOFF => self.cutoff_hz,
            PARAM_RESONANCE => self.resonance,
            PARAM_ATTACK => self.attack_s,
            PARAM_DECAY => self.decay_s,
            PARAM_SUSTAIN => self.sustain,
            PARAM_RELEASE => self.release_s,
            PARAM_GAIN => self.gain_db,
            PARAM_TRANSPOSE => self.transpose,
            PARAM_FINE => self.fine_cents,
            _ => 0.0,
        }
    }

    pub fn set(&mut self, slot: usize, value: f32) {
        match slot {
            PARAM_WAVEFORM => self.waveform = value,
            PARAM_CUTOFF => self.cutoff_hz = value,
            PARAM_RESONANCE => self.resonance = value,
            PARAM_ATTACK => self.attack_s = value,
            PARAM_DECAY => self.decay_s = value,
            PARAM_SUSTAIN => self.sustain = value,
            PARAM_RELEASE => self.release_s = value,
            PARAM_GAIN => self.gain_db = value,
            PARAM_TRANSPOSE => self.transpose = value,
            PARAM_FINE => self.fine_cents = value,
            _ => {}
        }
    }
}

/// `Device.kind` for E2. Matches the design section 3 vocabulary exactly.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstrumentKind {
    Synth,
    Sampler,
    Drum,
}

impl InstrumentKind {
    pub fn as_str(self) -> &'static str {
        match self {
            InstrumentKind::Synth => "synth",
            InstrumentKind::Sampler => "sampler",
            InstrumentKind::Drum => "drum",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "synth" => Some(InstrumentKind::Synth),
            "sampler" => Some(InstrumentKind::Sampler),
            "drum" => Some(InstrumentKind::Drum),
            _ => None,
        }
    }
}

pub enum Instrument {
    Synth(Synth),
    Sampler(Sampler),
    Drum(DrumRack),
}

impl Instrument {
    pub fn kind(&self) -> InstrumentKind {
        match self {
            Instrument::Synth(_) => InstrumentKind::Synth,
            Instrument::Sampler(_) => InstrumentKind::Sampler,
            Instrument::Drum(_) => InstrumentKind::Drum,
        }
    }

    #[inline]
    pub fn note_on(&mut self, pitch: u8, velocity: f32, hint: u32, p: &InstrumentParams) {
        match self {
            Instrument::Synth(s) => s.note_on(pitch, velocity, hint, p),
            Instrument::Sampler(s) => s.note_on(pitch, velocity, hint, p),
            Instrument::Drum(d) => d.note_on(pitch, velocity, hint, p),
        }
    }

    #[inline]
    pub fn note_off(&mut self, hint: u32) {
        match self {
            Instrument::Synth(s) => s.note_off(hint),
            Instrument::Sampler(s) => s.note_off(hint),
            Instrument::Drum(d) => d.note_off(hint),
        }
    }

    #[inline]
    pub fn render_frame(&mut self, p: &InstrumentParams) -> [f32; 2] {
        match self {
            Instrument::Synth(s) => s.render_frame(p),
            Instrument::Sampler(s) => s.render_frame(p),
            Instrument::Drum(d) => d.render_frame(p),
        }
    }

    pub fn all_notes_off(&mut self) {
        match self {
            Instrument::Synth(s) => s.all_notes_off(),
            Instrument::Sampler(s) => s.all_notes_off(),
            Instrument::Drum(d) => d.all_notes_off(),
        }
    }

    pub fn reset(&mut self) {
        match self {
            Instrument::Synth(s) => s.reset(),
            Instrument::Sampler(s) => s.reset(),
            Instrument::Drum(d) => d.reset(),
        }
    }

    pub fn snap_to(&mut self, p: &InstrumentParams) {
        match self {
            Instrument::Synth(s) => s.snap_to(p),
            Instrument::Sampler(s) => s.snap_to(p),
            Instrument::Drum(d) => d.snap_to(p),
        }
    }

    pub fn active_voices(&self) -> usize {
        match self {
            Instrument::Synth(s) => s.active_voices(),
            Instrument::Sampler(s) => s.active_voices(),
            Instrument::Drum(d) => d.active_voices(),
        }
    }

    pub fn held_voices(&self) -> usize {
        match self {
            Instrument::Synth(s) => s.held_voices(),
            Instrument::Sampler(s) => s.held_voices(),
            Instrument::Drum(d) => d.held_voices(),
        }
    }

    pub fn steal_count(&self) -> u64 {
        match self {
            Instrument::Synth(s) => s.steal_count(),
            Instrument::Sampler(s) => s.steal_count(),
            Instrument::Drum(d) => d.steal_count(),
        }
    }
}

/// An instrument plus its baked note schedule: everything a track needs to
/// turn `RtSession` note data into audio.
///
/// This is the unit `RtTrack` will hold (`Option<Box<InstrumentNode>>`), and
/// `render_frame` is the call that slots in exactly where `sum_clips` is
/// called today in `rt.rs` — see the E1 interface note at the bottom of this
/// module.
pub struct InstrumentNode {
    schedule: NoteSchedule,
    instrument: Instrument,
    device_id: String,
}

impl InstrumentNode {
    pub fn new(device_id: impl Into<String>, instrument: Instrument, events: Vec<NoteEvent>)
        -> Self {
        Self {
            schedule: NoteSchedule::new(events),
            instrument,
            device_id: device_id.into(),
        }
    }

    pub fn device_id(&self) -> &str {
        &self.device_id
    }

    pub fn kind(&self) -> InstrumentKind {
        self.instrument.kind()
    }

    pub fn instrument(&self) -> &Instrument {
        &self.instrument
    }

    pub fn instrument_mut(&mut self) -> &mut Instrument {
        &mut self.instrument
    }

    pub fn schedule(&self) -> &NoteSchedule {
        &self.schedule
    }

    pub fn active_voices(&self) -> usize {
        self.instrument.active_voices()
    }

    pub fn held_voices(&self) -> usize {
        self.instrument.held_voices()
    }

    pub fn steal_count(&self) -> u64 {
        self.instrument.steal_count()
    }

    /// Control-side: settle every ramp on install so a fresh session does not
    /// glide in from a stale value (mirrors `install_session`'s `snap`).
    pub fn snap_to(&mut self, p: &InstrumentParams) {
        self.instrument.snap_to(p);
    }

    /// Release everything. The anti-stuck-note lever, for a transport stop or
    /// a loop that the schedule could not close.
    pub fn all_notes_off(&mut self) {
        self.instrument.all_notes_off();
    }

    pub fn reset(&mut self) {
        self.instrument.reset();
        self.schedule.rewind();
    }

    /// Advance exactly ONE frame at absolute session frame `frame`.
    ///
    /// Order matters and is fixed: dispatch this frame's note boundaries
    /// FIRST, then render. A note-on at frame F is therefore audible at frame
    /// F, and a note-off at F stops contributing from F — both are asserted by
    /// the integration tests, because "the note sounds one block late" is
    /// exactly the class of bug a UI-state test cannot see.
    #[inline]
    pub fn render_frame(&mut self, frame: u64, p: &InstrumentParams) -> [f32; 2] {
        let inst = &mut self.instrument;
        self.schedule.drain_frame(frame, |e| {
            if e.on {
                inst.note_on(e.pitch, e.velocity, e.voice_hint, p);
            } else {
                inst.note_off(e.voice_hint);
            }
        });
        self.instrument.render_frame(p)
    }
}

/// Default voice count for a node built without an explicit capacity.
pub const NODE_VOICES: usize = DEFAULT_MAX_VOICES;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dsp::synth::Synth;
    use crate::rt::{ENGINE_SAMPLE_RATE, MICRO_FADE_FRAMES};

    fn node(events: Vec<NoteEvent>) -> InstrumentNode {
        let synth = Synth::new(ENGINE_SAMPLE_RATE, 8, MICRO_FADE_FRAMES as u32);
        let mut n = InstrumentNode::new("dev1", Instrument::Synth(synth), events);
        n.snap_to(&InstrumentParams::default());
        n
    }

    #[test]
    fn param_keys_are_single_token_and_unique() {
        for k in INSTRUMENT_PARAM_KEYS {
            assert!(!k.contains('.'), "{k} would break ParamRef's 4-segment split");
            assert!(!k.is_empty());
        }
        let mut sorted = INSTRUMENT_PARAM_KEYS.to_vec();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), INSTRUMENT_PARAM_KEYS.len(), "keys must be unique");
    }

    #[test]
    fn param_slots_round_trip() {
        let mut p = InstrumentParams::default();
        for (slot, key) in INSTRUMENT_PARAM_KEYS.iter().enumerate() {
            assert_eq!(InstrumentParams::index_of(key), Some(slot));
            p.set(slot, 0.125 * slot as f32 + 1.0);
            assert_eq!(p.get(slot), 0.125 * slot as f32 + 1.0, "slot {slot} ({key})");
        }
        assert_eq!(InstrumentParams::index_of("nope"), None);
    }

    #[test]
    fn param_ref_wire_form_matches_paramref() {
        // The exact string E1 bakes and `paramref.rs` parses.
        let wire = format!("track.device.{}.{}", "dev1", INSTRUMENT_PARAM_KEYS[PARAM_CUTOFF]);
        assert_eq!(wire, "track.device.dev1.cutoff");
        let seg: Vec<&str> = wire.split('.').collect();
        assert_eq!(seg.len(), 4, "ParamRef::kind matches exactly 4 segments");
    }

    #[test]
    fn note_on_is_audible_on_its_own_frame_and_not_before() {
        let p = InstrumentParams {
            attack_s: 0.0002,
            ..InstrumentParams::default()
        };
        let mut n = node(vec![NoteEvent::on(100, 60, 1.0, 1)]);
        for f in 0..100 {
            assert_eq!(n.render_frame(f, &p), [0.0, 0.0], "silent at frame {f}");
        }
        let mut any = false;
        for f in 100..140 {
            if n.render_frame(f, &p)[0] != 0.0 {
                any = true;
                break;
            }
        }
        assert!(any, "signal starts at the note-on frame");
    }

    #[test]
    fn every_note_on_is_matched_and_nothing_is_left_held() {
        let p = InstrumentParams::default();
        let mut events = Vec::new();
        for i in 0..40u32 {
            let f = 100 + i as u64 * 50;
            events.push(NoteEvent::on(f, 48 + (i % 24) as u8, 0.8, i));
            events.push(NoteEvent::off(f + 30, 48 + (i % 24) as u8, i));
        }
        let mut n = node(events);
        for f in 0..4000u64 {
            n.render_frame(f, &p);
        }
        assert_eq!(n.held_voices(), 0, "no stuck notes");
    }

    #[test]
    fn a_loop_that_replays_the_region_does_not_strand_voices() {
        let p = InstrumentParams::default();
        // A region [0, 1000) with an on at 100 and its off at 900 — the E1
        // contract's "emit the off at the loop wrap" shape.
        let mut n = node(vec![
            NoteEvent::on(100, 60, 1.0, 1),
            NoteEvent::off(900, 60, 1),
        ]);
        for _ in 0..6 {
            for f in 0..1000u64 {
                n.render_frame(f, &p);
            }
        }
        assert_eq!(n.held_voices(), 0, "every wrap released its note");
        assert!(n.active_voices() <= 1, "loops do not accumulate voices");
    }
}
