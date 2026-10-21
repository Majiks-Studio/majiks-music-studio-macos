//! Metronome click: a synthesised transient and an EXACT-INTEGER beat clock.
//!
//! Two rules govern everything in this file.
//!
//! **1. No float beat math.** `timeline_core::tempo` builds the whole timeline
//! on 960-PPQ integer ticks and round-half-up rational conversion precisely so
//! 92 BPM is as exact as 120. A metronome that accumulated `frames_per_beat`
//! in an f64 phase would drift away from the grid the clips are placed on —
//! and it would drift by a DIFFERENT amount depending on where the block
//! boundaries fell, which is the block-dependence the parity gate exists to
//! catch. [`BeatClock`] therefore computes each beat's frame with the same
//! `ticks * rate * 60 * den / (PPQ * num)` round-half-up division the model
//! uses, in u128, and compares it to the transport position as an integer.
//! The click lands on the frame the timeline says the beat is on, or it is a
//! bug.
//!
//! **2. Everything advances per FRAME.** The envelope is a [`Slew`], the
//! oscillator phase is a per-frame increment, and the beat test is a per-frame
//! integer compare against `position`. Nothing here looks at the block size,
//! so the click is bit-identical at 128 / 417 / 480 / 512.
//!
//! There are no asset files. A click is a decaying sine — nothing to ship,
//! nothing to load, nothing to fail to find, and (because it starts at phase
//! zero, where sin is 0) nothing to click ON the click.

use super::slew::Slew;

/// Pulses per quarter note. Mirrors `timeline_core::tempo::PPQ`; `render` does
/// not depend on `timeline-core`, and this constant is locked by
/// 02-ARCHITECTURE.md section 3 on both sides.
pub const PPQ: u64 = 960;

/// Round-half-up integer division — the same helper `timeline_core::tempo`
/// uses, replicated so the two agree bit for bit on every beat frame.
#[inline]
fn round_div(n: u128, d: u128) -> u128 {
    (n + d / 2) / d
}

/// Accent oscillator frequency (the downbeat) in Hz.
const ACCENT_HZ: f32 = 1600.0;
/// Off-beat oscillator frequency in Hz.
const BEAT_HZ: f32 = 800.0;
/// Accent decay in milliseconds.
const ACCENT_DECAY_MS: f32 = 42.0;
/// Off-beat decay in milliseconds.
const BEAT_DECAY_MS: f32 = 30.0;
/// Off-beats sit below the downbeat so the bar has a shape you can hear.
const BEAT_REL_LEVEL: f32 = 0.62;

/// Beats per bar. v1 is fixed 4/4 (`timeline_core::tempo::TempoMap` documents
/// the same honest fence: `project.setTimeSig` is catalog v1 but out of P0-B
/// scope, and `bar_to_tick` hardcodes 4). When a real time signature lands,
/// this becomes a field on [`MetroConfig`] and nothing else in this file
/// changes — the accent test is already `beat % beats_per_bar == 0`.
pub const BEATS_PER_BAR_V1: u64 = 4;

/// Everything the click needs to know about the project's musical grid.
///
/// `bpm_num` / `bpm_den` are the model's exact rational BPM, NOT a float, so
/// the beat frames computed here are the same integers the model computes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MetroConfig {
    pub sample_rate: u32,
    pub bpm_num: u32,
    pub bpm_den: u32,
    /// The project's phase anchor in ticks: the tick the grid's beat 0 sits
    /// on. Bar 1 is where the music thinks bar 1 is, not where frame 0 is.
    pub phase_anchor_ticks: u64,
    pub beats_per_bar: u64,
    /// Peak linear gain of an accent click.
    pub level: f32,
}

impl Default for MetroConfig {
    fn default() -> Self {
        Self {
            sample_rate: 48_000,
            bpm_num: 120,
            bpm_den: 1,
            phase_anchor_ticks: 0,
            beats_per_bar: BEATS_PER_BAR_V1,
            level: DEFAULT_LEVEL,
        }
    }
}

/// Default click level, linear. -12 dBFS peak: clearly audible over a mix you
/// are playing along to without burying it.
pub const DEFAULT_LEVEL: f32 = 0.251_188_64; // 10^(-12/20)

/// The beat grid. Answers exactly one question, per frame, with integers:
/// "is `position` a beat frame, and if so which beat is it?"
#[derive(Debug, Clone, Copy)]
pub struct BeatClock {
    cfg: MetroConfig,
    /// Index of the next beat whose frame we are waiting for.
    next_beat: u64,
    /// Frame of `next_beat`. Cached so the hot path is an integer compare and
    /// the u128 division only runs when a beat actually fires (or on a
    /// discontinuity), never per frame.
    next_frame: u64,
    /// Position we expect on the next frame, for discontinuity detection. A
    /// loop fold or a seek moves `position` by something other than +1, and
    /// that is exactly when the cached `next_frame` goes stale.
    expect_position: u64,
    /// False until the first `tick`, so the very first frame resyncs rather
    /// than trusting a zeroed cache.
    synced: bool,
}

impl BeatClock {
    pub fn new(cfg: MetroConfig) -> Self {
        Self {
            cfg,
            next_beat: 0,
            next_frame: 0,
            expect_position: 0,
            synced: false,
        }
    }

    pub fn config(&self) -> &MetroConfig {
        &self.cfg
    }

    /// Re-point the clock at a new grid. Forces a resync on the next frame:
    /// a tempo or anchor change moves every beat frame, so the cache is dead.
    pub fn set_config(&mut self, cfg: MetroConfig) {
        self.cfg = cfg;
        self.synced = false;
    }

    /// Frame of beat `beat`, exactly. Beat `b` sits at tick
    /// `phase_anchor + b * PPQ`; the tick-to-frame conversion is the model's,
    /// term for term.
    #[inline]
    pub fn frame_of_beat(&self, beat: u64) -> u64 {
        let tick = self
            .cfg
            .phase_anchor_ticks
            .saturating_add(beat.saturating_mul(PPQ));
        let n = u128::from(tick)
            * u128::from(self.cfg.sample_rate)
            * 60
            * u128::from(self.cfg.bpm_den.max(1));
        let d = u128::from(PPQ) * u128::from(self.cfg.bpm_num.max(1));
        u64::try_from(round_div(n, d)).unwrap_or(u64::MAX)
    }

    /// Frames per beat, as an exact u64 (the grid spacing). Only used to
    /// bracket the resync search; the beat frames themselves always come from
    /// [`Self::frame_of_beat`].
    #[inline]
    fn frames_per_beat(&self) -> u64 {
        let n = u128::from(PPQ)
            * u128::from(self.cfg.sample_rate)
            * 60
            * u128::from(self.cfg.bpm_den.max(1));
        let d = u128::from(PPQ) * u128::from(self.cfg.bpm_num.max(1));
        u64::try_from(round_div(n, d)).unwrap_or(1).max(1)
    }

    /// Point the clock at the first beat at or after `position`.
    ///
    /// Bounded work: divide to get a close beat index, then walk at most a
    /// couple of steps to land exactly. No allocation, no loop over frames.
    fn resync(&mut self, position: u64) {
        let anchor_frame = self.frame_of_beat(0);
        let mut beat = if position <= anchor_frame {
            0
        } else {
            (position - anchor_frame) / self.frames_per_beat()
        };
        // Walk back while we are past `position` (rounding can put the
        // estimate one beat late), then forward to the first beat >= position.
        while beat > 0 && self.frame_of_beat(beat) > position {
            beat -= 1;
        }
        while self.frame_of_beat(beat) < position {
            beat += 1;
        }
        self.next_beat = beat;
        self.next_frame = self.frame_of_beat(beat);
        self.synced = true;
    }

    /// Advance one FRAME. Returns `Some(beat_index)` when `position` is a beat
    /// frame.
    ///
    /// `position` is the transport position for THIS frame. A loop fold or a
    /// seek is detected here (position did not advance by exactly one) and
    /// resynced, which is what makes the click follow a loop instead of
    /// running off the end of it.
    #[inline]
    pub fn tick(&mut self, position: u64) -> Option<u64> {
        if !self.synced || position != self.expect_position {
            self.resync(position);
        }
        self.expect_position = position.wrapping_add(1);
        if position == self.next_frame {
            let beat = self.next_beat;
            self.next_beat = beat.saturating_add(1);
            self.next_frame = self.frame_of_beat(self.next_beat);
            // Degenerate grids (absurd tempo) could repeat a frame; never
            // fire twice on one frame.
            if self.next_frame <= position {
                self.next_frame = position + 1;
            }
            Some(beat)
        } else {
            None
        }
    }

    /// Is `beat` a downbeat (bar 1) on this grid?
    #[inline]
    pub fn is_accent(&self, beat: u64) -> bool {
        let bar = self.cfg.beats_per_bar.max(1);
        beat % bar == 0
    }

    /// Force a resync on the next frame (used when transport starts).
    pub fn desync(&mut self) {
        self.synced = false;
    }
}

/// One click voice: a decaying sine.
///
/// The envelope is a [`Slew`] rather than a one-pole on purpose. A one-pole
/// approaches zero asymptotically and never gets there, so the "silence"
/// between clicks would be a nonzero tail forever and every downstream
/// bit-identity claim would have to be qualified. `Slew` arrives EXACTLY on
/// target, so between clicks this voice outputs a hard, bit-exact 0.0.
#[derive(Debug, Clone, Copy)]
pub struct ClickVoice {
    env: Slew,
    /// Oscillator phase in radians, advanced per frame.
    phase: f32,
    /// Per-frame phase increment for the current click.
    phase_inc: f32,
    /// Peak amplitude of the click currently sounding.
    amp: f32,
    sample_rate: f32,
    accent_step: f32,
    beat_step: f32,
}

impl ClickVoice {
    pub fn new(sample_rate: u32) -> Self {
        let rate = sample_rate.max(1) as f32;
        Self {
            env: Slew::new(0.0, 1.0),
            phase: 0.0,
            phase_inc: 0.0,
            amp: 0.0,
            sample_rate: rate,
            accent_step: 1.0 / (ACCENT_DECAY_MS * 0.001 * rate).max(1.0),
            beat_step: 1.0 / (BEAT_DECAY_MS * 0.001 * rate).max(1.0),
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32) {
        let rate = sample_rate.max(1) as f32;
        self.sample_rate = rate;
        self.accent_step = 1.0 / (ACCENT_DECAY_MS * 0.001 * rate).max(1.0);
        self.beat_step = 1.0 / (BEAT_DECAY_MS * 0.001 * rate).max(1.0);
        self.reset();
    }

    /// Silence the voice immediately and exactly.
    pub fn reset(&mut self) {
        self.env = Slew::new(0.0, self.beat_step);
        self.phase = 0.0;
        self.phase_inc = 0.0;
        self.amp = 0.0;
    }

    /// Start a click. Phase restarts at 0 (sin(0) == 0), so the onset is a
    /// zero-crossing: the transient is the ENVELOPE, not a step discontinuity.
    #[inline]
    pub fn trigger(&mut self, accent: bool, level: f32) {
        let (hz, step, rel) = if accent {
            (ACCENT_HZ, self.accent_step, 1.0)
        } else {
            (BEAT_HZ, self.beat_step, BEAT_REL_LEVEL)
        };
        self.phase = 0.0;
        self.phase_inc = std::f32::consts::TAU * hz / self.sample_rate;
        self.amp = level.clamp(0.0, 4.0) * rel;
        self.env = Slew::new(1.0, step);
    }

    /// Is the voice silent RIGHT NOW (bit-exactly)?
    #[inline]
    pub fn idle(&self) -> bool {
        self.env.get() == 0.0
    }

    /// One FRAME of the click. Returns the mono sample.
    #[inline]
    pub fn next_frame(&mut self) -> f32 {
        // Settled at exactly 0: emit a hard zero and do no work. This is the
        // common case (a click occupies ~30 ms of every beat) and it is what
        // makes the silence between clicks bit-exact rather than merely small.
        if self.env.get() == 0.0 {
            return 0.0;
        }
        let e = self.env.advance(0.0);
        let s = self.phase.sin() * e * self.amp;
        self.phase += self.phase_inc;
        if self.phase >= std::f32::consts::TAU {
            self.phase -= std::f32::consts::TAU;
        }
        s
    }
}

/// The metronome: a beat clock driving a click voice.
///
/// Owned by the render core, which advances it once per FRAME, always — even
/// when disabled — so that enabling it mid-block cannot make the output depend
/// on where the block boundary was.
///
/// COUNT-IN STATE DELIBERATELY LIVES ON THE RENDER CORE, not here. A count-in
/// sounds before the transport rolls, so it is clocked by its own frame
/// counter rather than by this beat grid; keeping one owner for that counter
/// means there is no second implementation to wire by mistake. This type just
/// exposes [`Self::trigger`] so the core can fire the same voice.
#[derive(Debug, Clone, Copy)]
pub struct Metronome {
    clock: BeatClock,
    voice: ClickVoice,
}

impl Metronome {
    pub fn new(cfg: MetroConfig) -> Self {
        Self {
            clock: BeatClock::new(cfg),
            voice: ClickVoice::new(cfg.sample_rate),
        }
    }

    pub fn set_config(&mut self, cfg: MetroConfig) {
        if cfg.sample_rate != self.clock.config().sample_rate {
            self.voice.set_sample_rate(cfg.sample_rate);
        }
        self.clock.set_config(cfg);
    }

    pub fn config(&self) -> &MetroConfig {
        self.clock.config()
    }

    pub fn desync(&mut self) {
        self.clock.desync();
    }

    /// Advance the beat CLOCK by one frame and trigger a click if this frame
    /// is a beat. Does NOT advance the voice — see [`Self::voice_frame`].
    ///
    /// The split matters: a frame may be both a grid beat and a count-in beat,
    /// and the voice must still advance exactly ONCE on that frame. Folding
    /// the advance into this method made an early version of the count-in age
    /// the envelope twice per frame, which is a per-frame-discipline violation
    /// that only shows up as a block-size dependence.
    ///
    /// `enabled` gates the TRIGGER, never the advance: a click already
    /// sounding when the metronome is switched off still decays out over its
    /// envelope, which is both click-free and block-size independent.
    ///
    /// Returns whether this frame actually FIRED the voice — not whether it
    /// was a beat frame, and not whether the metronome is on. The render core
    /// uses it to count clicks; the click is excluded from every meter and
    /// tap, so a returned `true` is the only evidence that a click happened
    /// short of listening to the room. Reporting the fire (rather than the
    /// beat) is what makes the count mean "a sound was made".
    #[inline]
    pub fn tick_clock(&mut self, position: u64, playing: bool, enabled: bool) -> bool {
        if !playing {
            return false;
        }
        if let Some(beat) = self.clock.tick(position) {
            if enabled {
                let accent = self.clock.is_accent(beat);
                self.voice.trigger(accent, self.clock.config().level);
                return true;
            }
        }
        false
    }

    /// Clock + voice in one call. The convenient form, used by the unit tests;
    /// the render core drives the two halves separately so the count-in can
    /// share the single per-frame voice advance.
    #[inline]
    pub fn tick_frame(&mut self, position: u64, playing: bool, enabled: bool) -> f32 {
        self.tick_clock(position, playing, enabled);
        self.voice.next_frame()
    }

    /// Trigger a click directly (the count-in path, which is not driven by the
    /// transport grid).
    #[inline]
    pub fn trigger(&mut self, accent: bool) {
        self.voice.trigger(accent, self.clock.config().level);
    }

    /// One FRAME of the voice only, no grid.
    ///
    /// The render core calls this exactly once per frame, after deciding
    /// whether the grid or a count-in wanted a trigger on it.
    #[inline]
    pub fn voice_frame(&mut self) -> f32 {
        self.voice.next_frame()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(bpm: u32) -> MetroConfig {
        MetroConfig {
            sample_rate: 48_000,
            bpm_num: bpm,
            bpm_den: 1,
            ..MetroConfig::default()
        }
    }

    #[test]
    fn beat_frames_are_the_models_beat_frames() {
        // 120 BPM at 48 kHz: a beat is exactly 24000 frames.
        let c = BeatClock::new(cfg(120));
        assert_eq!(c.frame_of_beat(0), 0);
        assert_eq!(c.frame_of_beat(1), 24_000);
        assert_eq!(c.frame_of_beat(4), 96_000);
        // 92 BPM is not a round number of frames per beat; the exact rational
        // must not drift. Beat 100 at 92 BPM = 100 * 60 * 48000 / 92.
        let c = BeatClock::new(cfg(92));
        let want = ((100u128 * 60 * 48_000) + 46) / 92; // round-half-up
        assert_eq!(u128::from(c.frame_of_beat(100)), want);
    }

    #[test]
    fn a_float_accumulator_would_have_drifted() {
        // The bug this file exists to avoid: 1000 beats at 92 BPM.
        let c = BeatClock::new(cfg(92));
        let exact = c.frame_of_beat(1000);
        let mut acc = 0.0_f32;
        let per = 60.0_f32 * 48_000.0 / 92.0;
        for _ in 0..1000 {
            acc += per;
        }
        let drift = (acc as i64 - exact as i64).abs();
        assert!(drift > 0, "f32 accumulation drifted {drift} frames — that is the point");
    }

    #[test]
    fn the_phase_anchor_moves_the_grid() {
        let mut c = cfg(120);
        c.phase_anchor_ticks = 480; // an eighth note in
        let clock = BeatClock::new(c);
        assert_eq!(clock.frame_of_beat(0), 12_000);
        assert_eq!(clock.frame_of_beat(1), 36_000);
    }

    #[test]
    fn ticks_fire_exactly_on_beat_frames() {
        let mut c = BeatClock::new(cfg(120));
        let mut fired = Vec::new();
        for pos in 0..96_001u64 {
            if let Some(b) = c.tick(pos) {
                fired.push((pos, b));
            }
        }
        assert_eq!(
            fired,
            vec![(0, 0), (24_000, 1), (48_000, 2), (72_000, 3), (96_000, 4)]
        );
    }

    #[test]
    fn a_loop_fold_resyncs_the_grid() {
        let mut c = BeatClock::new(cfg(120));
        // Play 0..30000, then fold back to 24000 (a one-beat loop is silly but
        // the fold is what matters).
        for pos in 0..30_000u64 {
            c.tick(pos);
        }
        // Fold: position jumps backwards. The next beat frame must be 48000
        // relative to the new position, i.e. the clock must not still be
        // pointing at a stale cached frame behind us.
        let mut fired = Vec::new();
        for pos in 24_000..48_001u64 {
            if let Some(b) = c.tick(pos) {
                fired.push((pos, b));
            }
        }
        assert_eq!(fired, vec![(24_000, 1), (48_000, 2)]);
    }

    #[test]
    fn accents_land_on_the_bar() {
        let c = BeatClock::new(cfg(120));
        assert!(c.is_accent(0));
        assert!(!c.is_accent(1));
        assert!(!c.is_accent(3));
        assert!(c.is_accent(4));
        assert!(c.is_accent(8));
    }

    #[test]
    fn the_voice_returns_to_exact_zero() {
        let mut v = ClickVoice::new(48_000);
        v.trigger(true, DEFAULT_LEVEL);
        let mut peak = 0.0_f32;
        for _ in 0..48_000 {
            peak = peak.max(v.next_frame().abs());
        }
        assert!(peak > 0.05, "click had signal, peak {peak}");
        assert!(v.idle(), "envelope settled");
        assert_eq!(v.next_frame(), 0.0, "bit-exact silence between clicks");
    }

    #[test]
    fn the_voice_starts_at_a_zero_crossing() {
        let mut v = ClickVoice::new(48_000);
        v.trigger(true, DEFAULT_LEVEL);
        assert_eq!(v.next_frame(), 0.0, "first sample is sin(0) — no step edge");
    }

    #[test]
    fn accent_is_louder_than_an_off_beat() {
        let peak = |accent: bool| {
            let mut v = ClickVoice::new(48_000);
            v.trigger(accent, DEFAULT_LEVEL);
            (0..8_000).map(|_| v.next_frame().abs()).fold(0.0_f32, f32::max)
        };
        assert!(peak(true) > peak(false) * 1.2, "the downbeat is accented");
    }

    #[test]
    fn disabled_metronome_is_bit_exact_silence() {
        let mut m = Metronome::new(cfg(120));
        for pos in 0..96_000u64 {
            assert_eq!(m.tick_frame(pos, true, false), 0.0);
        }
    }
}
