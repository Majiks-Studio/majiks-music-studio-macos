//! Drum rack: pad -> one-shot, no pitch tracking.
//!
//! Deliberately the simplest of the three. A pad plays its sound from the
//! start at rate 1.0 and runs to the end; velocity scales level; note-off is
//! IGNORED, because a kick that stops when you lift the key is wrong. The
//! only shaping is the shared end-of-sample declick and, per pad, a fixed
//! gain and pan.
//!
//! Choke groups, per-pad pitch, per-pad filters and round-robin layers are
//! explicitly out of E2 scope (design section 6).

use std::sync::Arc;

use crate::dsp::instrument::InstrumentParams;
use crate::dsp::pan::balance_gains;
use crate::dsp::slew::Slew;
use crate::dsp::voice::{VoiceDsp, VoicePool};
use crate::media::AudioBuf;

/// Pads in a rack. 16 is the Ableton grid; the base note is C1 (36), also
/// Ableton's default, so a standard GM-ish kit lands where players expect it.
pub const RACK_PADS: usize = 16;
pub const DEFAULT_BASE_PITCH: u8 = 36;

pub struct DrumPad {
    pub audio: Arc<AudioBuf>,
    pub gain_lin: f32,
    /// -1 = left, +1 = right.
    pub pan: f32,
}

impl DrumPad {
    pub fn new(audio: Arc<AudioBuf>) -> Self {
        Self {
            audio,
            gain_lin: 1.0,
            pan: 0.0,
        }
    }
}

/// Immutable after construction, for the same reason as `SampleMap` — see the
/// sampler module note on sample memory.
pub struct DrumKit {
    pads: Box<[Option<DrumPad>]>,
    base_pitch: u8,
}

impl DrumKit {
    pub fn new(pads: Vec<Option<DrumPad>>, base_pitch: u8) -> Self {
        let mut pads = pads;
        pads.resize_with(RACK_PADS, || None);
        Self {
            pads: pads.into_boxed_slice(),
            base_pitch,
        }
    }

    pub fn empty() -> Self {
        Self::new(Vec::new(), DEFAULT_BASE_PITCH)
    }

    pub fn base_pitch(&self) -> u8 {
        self.base_pitch
    }

    pub fn pad_count(&self) -> usize {
        self.pads.iter().filter(|p| p.is_some()).count()
    }

    /// Pitch -> pad. Outside the rack's range there is simply no pad; a drum
    /// rack is silent on most of the keyboard by design.
    #[inline]
    pub fn pad_for(&self, pitch: u8) -> Option<&DrumPad> {
        if pitch < self.base_pitch {
            return None;
        }
        let idx = (pitch - self.base_pitch) as usize;
        self.pads.get(idx).and_then(Option::as_ref)
    }
}

#[derive(Clone, Copy)]
pub struct DrumVoiceParams<'a> {
    pub kit: &'a DrumKit,
    /// End-of-sample declick window, in source frames.
    pub fade_frames: f64,
}

#[derive(Default)]
pub struct DrumVoice {
    audio: Option<Arc<AudioBuf>>,
    pos: u64,
    gain_l: f32,
    gain_r: f32,
    fade_frames: f64,
    playing: bool,
}

impl VoiceDsp for DrumVoice {
    type Params<'a> = DrumVoiceParams<'a>;

    fn note_on(&mut self, pitch: u8, velocity: f32, p: &Self::Params<'_>, _sr: u32) -> bool {
        let Some(pad) = p.kit.pad_for(pitch) else {
            return false;
        };
        if pad.audio.samples.is_empty() {
            return false;
        }
        let (gl, gr) = balance_gains(pad.pan.clamp(-1.0, 1.0));
        let g = pad.gain_lin * velocity.clamp(0.0, 1.0);
        self.audio = Some(Arc::clone(&pad.audio));
        self.pos = 0;
        self.gain_l = g * gl;
        self.gain_r = g * gr;
        self.fade_frames = p.fade_frames;
        self.playing = true;
        true
    }

    /// One-shot: a drum hit is not sustained, so lifting the key does nothing.
    /// This is the whole point of a rack and the reason `Note.length_ticks`
    /// does not gate a kick.
    fn note_off(&mut self) {}

    fn kill(&mut self) {
        self.playing = false;
        self.audio = None;
        self.pos = 0;
    }

    #[inline]
    fn render_frame(&mut self, _p: &Self::Params<'_>, _sr: u32) -> [f32; 2] {
        if !self.playing {
            return [0.0, 0.0];
        }
        let Some(audio) = self.audio.as_ref() else {
            self.playing = false;
            return [0.0, 0.0];
        };
        let samples: &[[f32; 2]] = &audio.samples;
        let n = samples.len() as u64;
        if self.pos >= n {
            self.playing = false;
            self.audio = None;
            return [0.0, 0.0];
        }
        let s = samples[self.pos as usize];
        let remaining = (n - self.pos) as f64;
        let tail = if self.fade_frames > 0.0 && remaining < self.fade_frames {
            (remaining / self.fade_frames) as f32
        } else {
            1.0
        };
        self.pos += 1;
        [s[0] * self.gain_l * tail, s[1] * self.gain_r * tail]
    }

    fn is_finished(&self) -> bool {
        !self.playing
    }

    /// The stealing order needs a "how audible is this voice" scalar. A
    /// one-shot has no envelope, so use how much of it is LEFT to play: a hit
    /// that is nearly over is the cheapest thing to take.
    fn level(&self) -> f32 {
        match (self.playing, self.audio.as_ref()) {
            (true, Some(a)) => {
                let n = a.samples.len() as f32;
                if n <= 0.0 {
                    0.0
                } else {
                    ((n - self.pos as f32) / n).clamp(0.0, 1.0)
                }
            }
            _ => 0.0,
        }
    }

    /// A one-shot is never "releasing" — it is either playing or done. Ranking
    /// it as releasing would make the pool prefer it over a sustaining synth
    /// voice, which is the wrong instinct inside a rack of equals.
    fn is_releasing(&self) -> bool {
        false
    }
}

pub struct DrumRack {
    kit: Arc<DrumKit>,
    pool: VoicePool<DrumVoice>,
    fade_frames: u32,
    gain: Slew,
    last_gain_db: f32,
    last_gain_lin: f32,
}

impl DrumRack {
    pub fn new(kit: Arc<DrumKit>, sample_rate: u32, voices: usize, ramp_frames: u32) -> Self {
        let ramp = ramp_frames.max(1);
        let d = InstrumentParams::default();
        Self {
            kit,
            pool: VoicePool::new(voices, sample_rate, ramp, DrumVoice::default),
            fade_frames: ramp,
            gain: Slew::new(crate::dsp::db_to_lin(d.gain_db), 1.0 / ramp as f32),
            last_gain_db: d.gain_db,
            last_gain_lin: crate::dsp::db_to_lin(d.gain_db),
        }
    }

    pub fn kit(&self) -> &DrumKit {
        &self.kit
    }

    pub fn snap_to(&mut self, p: &InstrumentParams) {
        let g = self.gain_lin(p.gain_db);
        self.gain.snap(g);
    }

    #[inline]
    fn gain_lin(&mut self, gain_db: f32) -> f32 {
        if gain_db != self.last_gain_db {
            self.last_gain_db = gain_db;
            self.last_gain_lin = crate::dsp::db_to_lin(gain_db);
        }
        self.last_gain_lin
    }

    /// Free function, not a `&self` method: it must borrow ONLY the kit field
    /// so the pool can be borrowed mutably in the same statement.
    #[inline]
    fn voice_params(kit: &DrumKit, fade_frames: u32) -> DrumVoiceParams<'_> {
        DrumVoiceParams {
            kit,
            fade_frames: fade_frames as f64,
        }
    }

    pub fn note_on(&mut self, pitch: u8, velocity: f32, hint: u32, _p: &InstrumentParams) {
        let vp = Self::voice_params(&self.kit, self.fade_frames);
        self.pool.note_on(pitch, velocity, hint, &vp);
    }

    pub fn note_off(&mut self, hint: u32) {
        self.pool.note_off(hint);
    }

    pub fn all_notes_off(&mut self) {
        self.pool.all_notes_off();
    }

    pub fn reset(&mut self) {
        self.pool.reset();
    }

    pub fn active_voices(&self) -> usize {
        self.pool.active_voices()
    }

    pub fn held_voices(&self) -> usize {
        self.pool.held_voices()
    }

    pub fn steal_count(&self) -> u64 {
        self.pool.steal_count()
    }

    pub fn dropped_notes(&self) -> u64 {
        self.pool.dropped_notes()
    }

    #[inline]
    pub fn render_frame(&mut self, p: &InstrumentParams) -> [f32; 2] {
        let gain_target = self.gain_lin(p.gain_db);
        let g = self.gain.advance(gain_target);
        let vp = Self::voice_params(&self.kit, self.fade_frames);
        let s = self.pool.render_frame(&vp);
        [s[0] * g, s[1] * g]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn burst(level: f32, frames: usize) -> Arc<AudioBuf> {
        AudioBuf::from_samples(vec![[level, level]; frames], "burst")
    }

    fn kit() -> Arc<DrumKit> {
        Arc::new(DrumKit::new(
            vec![
                Some(DrumPad::new(burst(1.0, 480))),  // pad 0 -> pitch 36
                Some(DrumPad::new(burst(0.5, 240))),  // pad 1 -> pitch 37
                None,                                 // pad 2 -> pitch 38, empty
            ],
            DEFAULT_BASE_PITCH,
        ))
    }

    fn params() -> InstrumentParams {
        InstrumentParams {
            gain_db: 0.0,
            ..InstrumentParams::default()
        }
    }

    fn rack() -> DrumRack {
        let mut r = DrumRack::new(kit(), 48_000, 8, 240);
        r.snap_to(&params());
        r
    }

    #[test]
    fn pad_maps_from_the_base_pitch() {
        let k = kit();
        assert!(k.pad_for(36).is_some());
        assert!(k.pad_for(37).is_some());
        assert!(k.pad_for(38).is_none(), "empty pad");
        assert!(k.pad_for(35).is_none(), "below the rack");
        assert!(k.pad_for(90).is_none(), "above the rack");
    }

    #[test]
    fn a_hit_produces_signal_then_stops_on_its_own() {
        let mut r = rack();
        let p = params();
        r.note_on(36, 1.0, 1, &p);
        let out: Vec<f32> = (0..600).map(|_| r.render_frame(&p)[0]).collect();
        assert!(out[0].abs() > 0.5, "signal on the very first frame");
        assert!(r.active_voices() == 0, "one-shot ended by itself");
        assert_eq!(out[599], 0.0, "silent after the sample ran out");
    }

    #[test]
    fn note_off_does_not_stop_a_one_shot() {
        let mut r = rack();
        let p = params();
        r.note_on(36, 1.0, 1, &p);
        for _ in 0..10 {
            r.render_frame(&p);
        }
        r.note_off(1);
        let after = r.render_frame(&p)[0];
        assert!(after.abs() > 0.5, "a kick keeps ringing after key-up, got {after}");
    }

    #[test]
    fn no_pitch_tracking() {
        // Both mapped pads read at rate 1.0: pad 1's 240-frame sample must end
        // at exactly 240 frames regardless of which key triggered it.
        let mut r = rack();
        let p = params();
        r.note_on(37, 1.0, 1, &p);
        let out: Vec<f32> = (0..300).map(|_| r.render_frame(&p)[0]).collect();
        let last_nonzero = out.iter().rposition(|v| *v != 0.0).unwrap();
        // 240 source frames read at rate 1.0: frames 0..=239 sound (the last
        // is scaled by the 1/240 tail step), frame 240 onward is silent.
        assert_eq!(last_nonzero, 239, "one-shot played its exact length");
    }

    #[test]
    fn empty_and_out_of_range_pads_are_silent_and_cost_no_voice() {
        let mut r = rack();
        let p = params();
        r.note_on(38, 1.0, 1, &p);
        r.note_on(99, 1.0, 2, &p);
        assert_eq!(r.active_voices(), 0);
        assert_eq!(r.dropped_notes(), 2);
        for _ in 0..100 {
            assert_eq!(r.render_frame(&p), [0.0, 0.0]);
        }
    }

    #[test]
    fn velocity_scales_the_hit() {
        let p = params();
        let peak = |v: f32| {
            let mut r = rack();
            r.note_on(36, v, 1, &p);
            (0..600).fold(0.0f32, |m, _| m.max(r.render_frame(&p)[0].abs()))
        };
        let hard = peak(1.0);
        let soft = peak(0.3);
        assert!((soft / hard - 0.3).abs() < 0.02, "soft {soft} hard {hard}");
    }

    #[test]
    fn overlapping_hits_sum() {
        let mut r = rack();
        let p = params();
        r.note_on(36, 1.0, 1, &p);
        r.render_frame(&p);
        r.note_on(36, 1.0, 2, &p);
        let both = r.render_frame(&p)[0];
        assert!(both > 1.5, "two overlapping hits sum, got {both}");
    }

    #[test]
    fn the_tail_fades_instead_of_cutting() {
        let mut r = rack();
        let p = params();
        r.note_on(36, 1.0, 1, &p);
        let out: Vec<f32> = (0..600).map(|_| r.render_frame(&p)[0]).collect();
        let max_step = out
            .windows(2)
            .skip(1)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0f32, f32::max);
        assert!(max_step < 0.05, "no cliff at the end, max step {max_step}");
    }
}
