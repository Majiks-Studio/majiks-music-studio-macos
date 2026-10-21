//! Subtractive synth: polyphonic osc -> resonant low-pass -> amp envelope.
//!
//! Signal path per voice, advanced ONE FRAME at a time:
//!
//! ```text
//!   Osc(waveform, midi_to_hz(pitch + transpose + fine))
//!     -> Svf low-pass (cutoff, resonance)   <- automatable per frame
//!     -> * AdsrEnv (attack/decay/sustain/release, snapshotted at note-on)
//!     -> * velocity
//! ```
//!
//! and per node: `sum(voices) * Slew(gain)`.
//!
//! Parameters reach this instrument through the E0 dense lane table by their
//! existing `ParamRef::TrackDeviceParam { device_id, param }` address, so
//! every one of them automates with no contract work. `cutoff`, `resonance`
//! and `gain` are continuous, so they are `Slew`-ramped (arriving EXACTLY on
//! target, which is what keeps a settled value multiplying bit-exactly).
//! `waveform` and the ADSR times are per-note decisions and are read at
//! note-on: modulating an attack time mid-note is meaningless, and making it
//! a ramp would put a transcendental in the hot loop for nothing.

use crate::dsp::env::{AdsrEnv, AdsrSpec};
use crate::dsp::instrument::InstrumentParams;
use crate::dsp::osc::{midi_to_hz, Osc, Waveform};
use crate::dsp::slew::Slew;
use crate::dsp::svf::Svf;
use crate::dsp::voice::{VoiceDsp, VoicePool};

/// Widest cutoff excursion, used to size the cutoff `Slew` step so a full
/// sweep takes exactly one declick window — the strip.rs convention
/// ("full-scale glide time equals the declick window").
const CUTOFF_MIN_HZ: f32 = 20.0;
const CUTOFF_MAX_HZ: f32 = 20_000.0;

/// Per-frame parameter snapshot handed to every voice.
#[derive(Debug, Clone, Copy)]
pub struct SynthVoiceParams {
    pub wave: Waveform,
    pub cutoff_hz: f32,
    pub resonance: f32,
    pub adsr: AdsrSpec,
    /// Semitone offset applied at note-on (transpose + fine/100).
    pub detune_semitones: f32,
}

impl Default for SynthVoiceParams {
    fn default() -> Self {
        Self {
            // MIRRORS `InstrumentParams::default()`, which is the real default
            // and the one every note-on reads. This copy only ever describes a
            // voice's resting state before its first note, but it was written
            // by hand and nothing tested that the two agreed — so it is exactly
            // the shape that silently diverges. Change one, change both.
            wave: Waveform::Triangle,
            cutoff_hz: 12_000.0,
            resonance: 0.15,
            adsr: AdsrSpec::default(),
            detune_semitones: 0.0,
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct SynthVoice {
    osc: Osc,
    env: AdsrEnv,
    filt: Svf,
    /// Phase increment (freq / sample_rate), computed ONCE at note-on.
    inc: f32,
    velocity: f32,
    wave: Waveform,
}

impl VoiceDsp for SynthVoice {
    type Params<'a> = SynthVoiceParams;

    fn note_on(&mut self, pitch: u8, velocity: f32, p: &SynthVoiceParams, sample_rate: u32)
        -> bool {
        let hz = midi_to_hz(pitch as f32 + p.detune_semitones);
        self.inc = hz / sample_rate.max(1) as f32;
        self.velocity = velocity.clamp(0.0, 1.0);
        // The waveform is a per-note decision: switching an oscillator shape
        // under a sounding note is a discontinuity no envelope can hide.
        self.wave = p.wave;
        self.osc.reset();
        self.filt.reset();
        self.env.trigger(p.adsr);
        true
    }

    fn note_off(&mut self) {
        self.env.release();
    }

    fn kill(&mut self) {
        self.env.kill();
        self.filt.reset();
        self.osc.reset();
    }

    #[inline]
    fn render_frame(&mut self, p: &SynthVoiceParams, sample_rate: u32) -> [f32; 2] {
        let e = self.env.advance();
        if self.env.is_idle() {
            return [0.0, 0.0];
        }
        let raw = self.osc.advance(self.wave, self.inc);
        let y = self
            .filt
            .process_lp(raw, p.cutoff_hz, p.resonance, sample_rate);
        let s = y * e * self.velocity;
        [s, s]
    }

    fn is_finished(&self) -> bool {
        self.env.is_idle()
    }

    fn level(&self) -> f32 {
        self.env.level()
    }

    fn is_releasing(&self) -> bool {
        self.env.is_releasing()
    }
}

pub struct Synth {
    pool: VoicePool<SynthVoice>,
    sample_rate: u32,
    cutoff: Slew,
    resonance: Slew,
    gain: Slew,
    // db -> linear cache, the strip.rs `last_vol_db` idiom: db_to_lin is a
    // powf and the target is constant for most of a session's life.
    last_gain_db: f32,
    last_gain_lin: f32,
}

impl Synth {
    pub fn new(sample_rate: u32, voices: usize, ramp_frames: u32) -> Self {
        let ramp = ramp_frames.max(1);
        let step = 1.0 / ramp as f32;
        let d = InstrumentParams::default();
        Self {
            pool: VoicePool::new(voices, sample_rate, ramp, SynthVoice::default),
            sample_rate,
            cutoff: Slew::new(d.cutoff_hz, (CUTOFF_MAX_HZ - CUTOFF_MIN_HZ) * step),
            resonance: Slew::new(d.resonance, step),
            gain: Slew::new(crate::dsp::db_to_lin(d.gain_db), step),
            last_gain_db: d.gain_db,
            last_gain_lin: crate::dsp::db_to_lin(d.gain_db),
        }
    }

    /// Jump every ramp to its target. Control-side only (first install of a
    /// session), never mid-signal — the same rule as `Slew::snap`.
    pub fn snap_to(&mut self, p: &InstrumentParams) {
        self.cutoff.snap(p.cutoff_hz.clamp(CUTOFF_MIN_HZ, CUTOFF_MAX_HZ));
        self.resonance.snap(p.resonance.clamp(0.0, 1.0));
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

    /// Build the per-frame voice snapshot from the CURRENT ramp positions.
    #[inline]
    fn voice_params(&self, p: &InstrumentParams) -> SynthVoiceParams {
        SynthVoiceParams {
            wave: Waveform::from_param(p.waveform),
            cutoff_hz: self.cutoff.get(),
            resonance: self.resonance.get(),
            adsr: AdsrSpec::from_seconds(
                p.attack_s,
                p.decay_s,
                p.sustain,
                p.release_s,
                self.sample_rate,
            ),
            detune_semitones: p.transpose + p.fine_cents / 100.0,
        }
    }

    pub fn note_on(&mut self, pitch: u8, velocity: f32, hint: u32, p: &InstrumentParams) {
        let vp = self.voice_params(p);
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

    pub fn capacity(&self) -> usize {
        self.pool.capacity()
    }

    /// Advance one frame. `p` is the per-frame parameter target set: the
    /// caller folds automation in before calling, exactly as `Strip` does
    /// (`gain_target = atomic * lane_value`, then `slew.advance(target)`).
    #[inline]
    pub fn render_frame(&mut self, p: &InstrumentParams) -> [f32; 2] {
        let cutoff = self
            .cutoff
            .advance(p.cutoff_hz.clamp(CUTOFF_MIN_HZ, CUTOFF_MAX_HZ));
        let resonance = self.resonance.advance(p.resonance.clamp(0.0, 1.0));
        let gain_target = self.gain_lin(p.gain_db);
        let g = self.gain.advance(gain_target);

        let vp = SynthVoiceParams {
            wave: Waveform::from_param(p.waveform),
            cutoff_hz: cutoff,
            resonance,
            adsr: AdsrSpec::from_seconds(
                p.attack_s,
                p.decay_s,
                p.sustain,
                p.release_s,
                self.sample_rate,
            ),
            detune_semitones: p.transpose + p.fine_cents / 100.0,
        };
        let s = self.pool.render_frame(&vp);
        [s[0] * g, s[1] * g]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params() -> InstrumentParams {
        InstrumentParams {
            gain_db: 0.0,
            attack_s: 0.001,
            decay_s: 0.001,
            sustain: 1.0,
            release_s: 0.005,
            ..InstrumentParams::default()
        }
    }

    fn synth() -> Synth {
        let mut s = Synth::new(48_000, 8, 240);
        s.snap_to(&params());
        s
    }

    /// `SynthVoiceParams::default` is a hand-written second copy of the same
    /// three fields `InstrumentParams::default` declares. Nothing tested that
    /// they agreed, which is precisely how a duplicated constant goes wrong: a
    /// default changed in one place, the other left behind, no red anywhere.
    #[test]
    fn the_voice_resting_default_mirrors_the_instrument_default() {
        let d = InstrumentParams::default();
        let v = SynthVoiceParams::default();
        assert_eq!(v.wave, Waveform::from_param(d.waveform), "waveform diverged");
        assert_eq!(v.cutoff_hz, d.cutoff_hz, "cutoff diverged");
        assert_eq!(v.resonance, d.resonance, "resonance diverged");
    }

    /// The first sound a person hears is not the harshest one available.
    ///
    /// This is a taste decision, so it is written down where a change to it has
    /// to be deliberate rather than incidental: a saw is right for someone
    /// subtracting and wrong for someone pressing a key, and until the tone
    /// controls landed it was the only sound the app could make.
    #[test]
    fn the_default_waveform_is_not_the_raw_saw() {
        let d = InstrumentParams::default();
        assert_ne!(
            Waveform::from_param(d.waveform),
            Waveform::Saw,
            "the default instrument sound is back to a raw sawtooth"
        );
    }

    #[test]
    fn silence_until_note_on() {
        let mut s = synth();
        let p = params();
        for _ in 0..1000 {
            assert_eq!(s.render_frame(&p), [0.0, 0.0]);
        }
    }

    #[test]
    fn note_on_produces_signal() {
        let mut s = synth();
        let p = params();
        s.note_on(60, 1.0, 1, &p);
        let mut peak = 0.0f32;
        for _ in 0..2400 {
            let f = s.render_frame(&p);
            peak = peak.max(f[0].abs());
        }
        assert!(peak > 0.1, "audible signal, peak {peak}");
    }

    #[test]
    fn release_decays_to_exact_silence_and_frees_the_voice() {
        let mut s = synth();
        let p = params();
        s.note_on(60, 1.0, 1, &p);
        for _ in 0..480 {
            s.render_frame(&p);
        }
        s.note_off(1);
        // release_s 0.005 -> 240 frames; plus the pool's finish check.
        for _ in 0..300 {
            s.render_frame(&p);
        }
        assert_eq!(s.active_voices(), 0, "voice freed after release");
        for _ in 0..100 {
            assert_eq!(s.render_frame(&p), [0.0, 0.0], "exact silence after release");
        }
    }

    #[test]
    fn cutoff_actually_filters() {
        let bright = {
            let mut s = synth();
            let mut p = params();
            p.cutoff_hz = 18_000.0;
            p.waveform = Waveform::Saw.as_param();
            s.snap_to(&p);
            s.note_on(69, 1.0, 1, &p);
            let mut e = 0.0f64;
            for _ in 0..9600 {
                let f = s.render_frame(&p);
                e += (f[0] * f[0]) as f64;
            }
            e
        };
        let dark = {
            let mut s = synth();
            let mut p = params();
            p.cutoff_hz = 200.0;
            p.waveform = Waveform::Saw.as_param();
            s.snap_to(&p);
            s.note_on(69, 1.0, 1, &p);
            let mut e = 0.0f64;
            for _ in 0..9600 {
                let f = s.render_frame(&p);
                e += (f[0] * f[0]) as f64;
            }
            e
        };
        assert!(
            dark < bright * 0.5,
            "closing the cutoff must remove energy: bright {bright}, dark {dark}"
        );
    }

    #[test]
    fn polyphony_sums_the_individual_voices() {
        let p = params();
        let solo = |pitch: u8| {
            let mut s = synth();
            s.note_on(pitch, 1.0, 1, &p);
            (0..2400).map(|_| s.render_frame(&p)[0]).collect::<Vec<_>>()
        };
        let a = solo(60);
        let b = solo(64);
        let mut s = synth();
        s.note_on(60, 1.0, 1, &p);
        s.note_on(64, 1.0, 2, &p);
        let both: Vec<f32> = (0..2400).map(|_| s.render_frame(&p)[0]).collect();
        for i in 0..2400 {
            assert!(
                (both[i] - (a[i] + b[i])).abs() < 1e-5,
                "frame {i}: {} != {} + {}",
                both[i],
                a[i],
                b[i]
            );
        }
    }

    #[test]
    fn velocity_scales_amplitude() {
        let p = params();
        let peak_at = |v: f32| {
            let mut s = synth();
            s.note_on(60, v, 1, &p);
            (0..2400).fold(0.0f32, |m, _| m.max(s.render_frame(&p)[0].abs()))
        };
        let loud = peak_at(1.0);
        let soft = peak_at(0.25);
        assert!(soft < loud * 0.4, "soft {soft} vs loud {loud}");
        assert!(soft > 0.0);
    }

    #[test]
    fn pitch_tracks_the_note() {
        let p = params();
        let crossings = |pitch: u8| {
            let mut s = Synth::new(48_000, 8, 240);
            let mut pp = p;
            pp.waveform = Waveform::Sine.as_param();
            pp.cutoff_hz = 20_000.0;
            s.snap_to(&pp);
            s.note_on(pitch, 1.0, 1, &pp);
            let out: Vec<f32> = (0..48_000).map(|_| s.render_frame(&pp)[0]).collect();
            out.windows(2).filter(|w| (w[0] < 0.0) != (w[1] < 0.0)).count()
        };
        let a4 = crossings(69);
        let a5 = crossings(81);
        assert!(
            (a5 as f32 / a4 as f32 - 2.0).abs() < 0.05,
            "an octave up doubles the rate: {a4} -> {a5}"
        );
    }
}
