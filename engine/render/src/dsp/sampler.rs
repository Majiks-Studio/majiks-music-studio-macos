//! Multi-zone sampler: map a sound across the keyboard, pitch-shift per note.
//!
//! This is the instrument that makes the sounds vault playable, so the two
//! things that matter are (a) the pitch really tracks the key and (b) the
//! read is clean.
//!
//! **Interpolation.** Playback at a non-integer rate needs a reconstruction
//! filter. The clip layer's SRC is rubato windowed-sinc, but that runs
//! OFF-thread into pre-rendered buffers (`warp.rs`) and cannot be used here:
//! a sampler's rate is a per-note, per-frame decision on the audio thread.
//! 4-point 3rd-order Hermite is the honest RT choice — ~30 dB better than
//! linear on musical material, a fixed handful of multiplies, no state, no
//! allocation. Documented rather than silently assumed.
//!
//! **Sample memory.** A voice holds an `Arc<AudioBuf>` cloned from the zone
//! map at note-on. `Arc::clone` is one relaxed atomic increment — no
//! allocation, no lock — and the *map itself* holds a strong reference for
//! the whole life of the node, so a voice's drop can never be the last one
//! and the audio thread can never free. A new sample map therefore arrives
//! the way every other heap payload does: as a whole replacement node moved
//! in control-side, with the old one handed to `defer_drop`. There is no
//! in-place map mutation API on purpose.
//!
//! **Tail.** A zone that ends at non-zero amplitude would click. The last
//! `MICRO_FADE` window of every zone is faded out by a gain that is a pure
//! function of the read position, so it costs no extra state and it lands on
//! exactly 0.0.

use std::sync::Arc;

use crate::dsp::env::{AdsrEnv, AdsrSpec};
use crate::dsp::instrument::InstrumentParams;
use crate::dsp::slew::Slew;
use crate::dsp::voice::{VoiceDsp, VoicePool};
use crate::media::AudioBuf;

/// One keyboard zone: a sound, the key it was recorded at, and the range it
/// covers.
pub struct SampleZone {
    pub audio: Arc<AudioBuf>,
    /// The MIDI note the recording sounds at. Playing this note reads at 1.0.
    pub root_pitch: u8,
    pub lo_pitch: u8,
    pub hi_pitch: u8,
    pub gain_lin: f32,
}

impl SampleZone {
    /// One sound across the whole keyboard — the common case for the vault.
    pub fn full_range(audio: Arc<AudioBuf>, root_pitch: u8) -> Self {
        Self {
            audio,
            root_pitch,
            lo_pitch: 0,
            hi_pitch: 127,
            gain_lin: 1.0,
        }
    }

    #[inline]
    pub fn covers(&self, pitch: u8) -> bool {
        pitch >= self.lo_pitch && pitch <= self.hi_pitch
    }
}

/// Immutable after construction — see the module note on sample memory.
pub struct SampleMap {
    zones: Box<[SampleZone]>,
}

impl SampleMap {
    pub fn new(zones: Vec<SampleZone>) -> Self {
        Self {
            zones: zones.into_boxed_slice(),
        }
    }

    pub fn empty() -> Self {
        Self::new(Vec::new())
    }

    pub fn len(&self) -> usize {
        self.zones.len()
    }

    pub fn is_empty(&self) -> bool {
        self.zones.is_empty()
    }

    /// First zone covering `pitch`, in declaration order. Deterministic by
    /// construction: overlapping zones resolve to the earlier one, always.
    #[inline]
    pub fn zone_for(&self, pitch: u8) -> Option<&SampleZone> {
        self.zones.iter().find(|z| z.covers(pitch))
    }
}

/// Per-frame snapshot handed to every sampler voice. The zone map rides along
/// as a borrow (the `VoiceDsp::Params` GAT) so `note_on` resolves a zone
/// itself and the pool never learns what a sample is.
#[derive(Clone, Copy)]
pub struct SamplerVoiceParams<'a> {
    pub map: &'a SampleMap,
    pub adsr: AdsrSpec,
    /// transpose + fine/100, applied on top of (pitch - root).
    pub detune_semitones: f32,
    /// End-of-sample declick window, in source frames.
    pub fade_frames: f64,
}

/// 4-point, 3rd-order Hermite (Catmull-Rom) interpolation.
#[inline(always)]
fn hermite(xm1: f32, x0: f32, x1: f32, x2: f32, t: f32) -> f32 {
    let c = (x1 - xm1) * 0.5;
    let v = x0 - x1;
    let w = c + v;
    let a = w + v + (x2 - x0) * 0.5;
    let b_neg = w + a;
    (((a * t) - b_neg) * t + c) * t + x0
}

#[derive(Default)]
pub struct SamplerVoice {
    audio: Option<Arc<AudioBuf>>,
    /// Fractional read position in source frames. f64 so a 10-minute sample
    /// still advances exactly at any rate (f32 loses 1-frame resolution past
    /// ~2^24 frames = 5.8 minutes at 48 kHz).
    pos: f64,
    rate: f64,
    zone_gain: f32,
    velocity: f32,
    env: AdsrEnv,
    fade_frames: f64,
}

impl SamplerVoice {
    #[inline]
    fn read(&self, samples: &[[f32; 2]], idx: i64, ch: usize) -> f32 {
        let n = samples.len() as i64;
        if n == 0 {
            return 0.0;
        }
        let i = idx.clamp(0, n - 1) as usize;
        samples[i][ch]
    }
}

impl VoiceDsp for SamplerVoice {
    type Params<'a> = SamplerVoiceParams<'a>;

    /// Resolve pitch -> zone -> playback rate. `Arc::clone` is one atomic
    /// increment (no allocation, no lock) and the map holds a strong reference
    /// for the life of the node, so this voice's eventual drop can never be
    /// the last one and the audio thread can never free. An unmapped pitch
    /// returns false: the pool leaves the slot free rather than burning a
    /// voice on silence.
    fn note_on(&mut self, pitch: u8, velocity: f32, p: &Self::Params<'_>, sr: u32) -> bool {
        let Some(zone) = p.map.zone_for(pitch) else {
            return false;
        };
        let _ = sr;
        let semis = pitch as f64 - zone.root_pitch as f64 + p.detune_semitones as f64;
        self.audio = Some(Arc::clone(&zone.audio));
        self.pos = 0.0;
        self.rate = (semis / 12.0).exp2();
        self.zone_gain = zone.gain_lin;
        self.velocity = velocity.clamp(0.0, 1.0);
        self.fade_frames = p.fade_frames;
        self.env.trigger(p.adsr);
        true
    }

    fn note_off(&mut self) {
        self.env.release();
    }

    fn kill(&mut self) {
        self.env.kill();
        self.audio = None;
        self.pos = 0.0;
    }

    #[inline]
    fn render_frame(&mut self, _p: &Self::Params<'_>, _sr: u32) -> [f32; 2] {
        let e = self.env.advance();
        if self.env.is_idle() {
            self.audio = None;
            return [0.0, 0.0];
        }
        let Some(audio) = self.audio.as_ref() else {
            return [0.0, 0.0];
        };
        let samples: &[[f32; 2]] = &audio.samples;
        let n = samples.len() as f64;
        if self.pos >= n {
            self.env.kill();
            return [0.0, 0.0];
        }
        let i = self.pos.floor() as i64;
        let t = (self.pos - i as f64) as f32;
        let l = hermite(
            self.read(samples, i - 1, 0),
            self.read(samples, i, 0),
            self.read(samples, i + 1, 0),
            self.read(samples, i + 2, 0),
            t,
        );
        let r = hermite(
            self.read(samples, i - 1, 1),
            self.read(samples, i, 1),
            self.read(samples, i + 1, 1),
            self.read(samples, i + 2, 1),
            t,
        );
        // End-of-sample fade: a pure function of position, so it costs no
        // state and it reaches exactly 0.0 at the last frame.
        let remaining = n - self.pos;
        let tail = if self.fade_frames > 0.0 && remaining < self.fade_frames {
            (remaining / self.fade_frames).max(0.0) as f32
        } else {
            1.0
        };
        self.pos += self.rate;
        let g = e * self.velocity * self.zone_gain * tail;
        [l * g, r * g]
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

/// Keyboard-mapped, pitch-shifting sample instrument. One shared
/// `VoicePool` — same stealing policy, same 5 ms steal declick, same pending
/// slot as the synth.
pub struct Sampler {
    map: Arc<SampleMap>,
    pool: VoicePool<SamplerVoice>,
    sample_rate: u32,
    fade_frames: u32,
    gain: Slew,
    last_gain_db: f32,
    last_gain_lin: f32,
}

impl Sampler {
    pub fn new(map: Arc<SampleMap>, sample_rate: u32, voices: usize, ramp_frames: u32) -> Self {
        let ramp = ramp_frames.max(1);
        let d = InstrumentParams::default();
        Self {
            map,
            pool: VoicePool::new(voices, sample_rate, ramp, SamplerVoice::default),
            sample_rate,
            fade_frames: ramp,
            gain: Slew::new(crate::dsp::db_to_lin(d.gain_db), 1.0 / ramp as f32),
            last_gain_db: d.gain_db,
            last_gain_lin: crate::dsp::db_to_lin(d.gain_db),
        }
    }

    pub fn map(&self) -> &SampleMap {
        &self.map
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

    /// Free function, not a `&self` method: it must borrow ONLY the map field
    /// so the pool can be borrowed mutably in the same statement.
    #[inline]
    fn voice_params<'a>(
        map: &'a SampleMap,
        sample_rate: u32,
        fade_frames: u32,
        p: &InstrumentParams,
    ) -> SamplerVoiceParams<'a> {
        SamplerVoiceParams {
            map,
            adsr: AdsrSpec::from_seconds(
                p.attack_s,
                p.decay_s,
                p.sustain,
                p.release_s,
                sample_rate,
            ),
            detune_semitones: p.transpose + p.fine_cents / 100.0,
            fade_frames: fade_frames as f64,
        }
    }

    pub fn note_on(&mut self, pitch: u8, velocity: f32, hint: u32, p: &InstrumentParams) {
        let vp = Self::voice_params(&self.map, self.sample_rate, self.fade_frames, p);
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
        let vp = Self::voice_params(&self.map, self.sample_rate, self.fade_frames, p);
        let s = self.pool.render_frame(&vp);
        [s[0] * g, s[1] * g]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::TAU;

    fn sine_buf(hz: f32, frames: usize) -> Arc<AudioBuf> {
        let samples: Vec<[f32; 2]> = (0..frames)
            .map(|i| {
                let v = (TAU * hz * i as f32 / 48_000.0).sin();
                [v, v]
            })
            .collect();
        AudioBuf::from_samples(samples, "sine")
    }

    fn params() -> InstrumentParams {
        InstrumentParams {
            gain_db: 0.0,
            attack_s: 0.0005,
            decay_s: 0.0005,
            sustain: 1.0,
            release_s: 0.005,
            ..InstrumentParams::default()
        }
    }

    fn sampler(root: u8) -> Sampler {
        let map = Arc::new(SampleMap::new(vec![SampleZone::full_range(
            sine_buf(440.0, 48_000),
            root,
        )]));
        let mut s = Sampler::new(map, 48_000, 8, 240);
        s.snap_to(&params());
        s
    }

    fn crossings(out: &[f32]) -> usize {
        out.windows(2).filter(|w| (w[0] < 0.0) != (w[1] < 0.0)).count()
    }

    #[test]
    fn root_note_plays_at_the_recorded_pitch() {
        let mut s = sampler(69);
        let p = params();
        s.note_on(69, 1.0, 1, &p);
        let out: Vec<f32> = (0..24_000).map(|_| s.render_frame(&p)[0]).collect();
        let c = crossings(&out);
        // 440 Hz over 0.5 s = 440 crossings.
        assert!(c.abs_diff(440) <= 4, "expected ~440 crossings, got {c}");
    }

    #[test]
    fn an_octave_up_doubles_the_pitch() {
        let p = params();
        let count = |pitch: u8| {
            let mut s = sampler(69);
            s.note_on(pitch, 1.0, 1, &p);
            let out: Vec<f32> = (0..12_000).map(|_| s.render_frame(&p)[0]).collect();
            crossings(&out)
        };
        let root = count(69);
        let up = count(81);
        let down = count(57);
        assert!(
            (up as f32 / root as f32 - 2.0).abs() < 0.05,
            "+12 semitones: {root} -> {up}"
        );
        assert!(
            (down as f32 / root as f32 - 0.5).abs() < 0.05,
            "-12 semitones: {root} -> {down}"
        );
    }

    #[test]
    fn unmapped_pitch_is_silent_and_costs_no_voice() {
        let map = Arc::new(SampleMap::new(vec![SampleZone {
            audio: sine_buf(440.0, 4800),
            root_pitch: 60,
            lo_pitch: 60,
            hi_pitch: 64,
            gain_lin: 1.0,
        }]));
        let mut s = Sampler::new(map, 48_000, 4, 240);
        let p = params();
        s.snap_to(&p);
        s.note_on(90, 1.0, 1, &p);
        assert_eq!(s.active_voices(), 0);
        assert_eq!(s.dropped_notes(), 1);
        for _ in 0..1000 {
            assert_eq!(s.render_frame(&p), [0.0, 0.0]);
        }
    }

    #[test]
    fn zones_resolve_in_declaration_order() {
        let map = SampleMap::new(vec![
            SampleZone {
                audio: sine_buf(220.0, 100),
                root_pitch: 60,
                lo_pitch: 0,
                hi_pitch: 127,
                gain_lin: 0.25,
            },
            SampleZone::full_range(sine_buf(440.0, 100), 60),
        ]);
        assert_eq!(map.zone_for(60).unwrap().gain_lin, 0.25);
    }

    #[test]
    fn sample_end_fades_out_instead_of_clicking() {
        // A DC-ish buffer that would slam to zero without the tail fade.
        let samples: Vec<[f32; 2]> = (0..4800).map(|_| [1.0, 1.0]).collect();
        let map = Arc::new(SampleMap::new(vec![SampleZone::full_range(
            AudioBuf::from_samples(samples, "dc"),
            60,
        )]));
        let mut s = Sampler::new(map, 48_000, 4, 240);
        let mut p = params();
        p.release_s = 1.0; // do not let the env end it first
        s.snap_to(&p);
        s.note_on(60, 1.0, 1, &p);
        let out: Vec<f32> = (0..5200).map(|_| s.render_frame(&p)[0]).collect();
        // Measure the TAIL only: the envelope attack at the head is a
        // deliberate ramp, not a cliff.
        let max_step = out[4000..]
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0f32, f32::max);
        assert!(max_step < 0.05, "no cliff at the sample end, max step {max_step}");
        assert_eq!(*out.last().unwrap(), 0.0, "ends at exact silence");
    }

    #[test]
    fn release_frees_the_voice() {
        let mut s = sampler(69);
        let p = params();
        s.note_on(69, 1.0, 1, &p);
        for _ in 0..1000 {
            s.render_frame(&p);
        }
        assert_eq!(s.active_voices(), 1);
        s.note_off(1);
        for _ in 0..400 {
            s.render_frame(&p);
        }
        assert_eq!(s.active_voices(), 0);
    }
}
