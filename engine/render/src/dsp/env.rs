//! ADSR amplitude envelope. Per-FRAME state machine on `Copy` data, no
//! allocation, no branches on anything but its own stage.
//!
//! The release **reaches exactly 0.0** — this is a correctness property, not a
//! nicety: a truncated release is an audible click, and a release that only
//! decays asymptotically holds a voice forever (the pool would never free it
//! and stealing would thrash). Stage transitions are driven by an INTEGER
//! frame counter compared against an integer length, so the terminal value is
//! assigned literally rather than reached by float accumulation.

/// Stage lengths in FRAMES plus the sustain level. Converted from seconds
/// ONCE per frame on the control side of the node (a multiply, no
/// transcendental) and snapshotted into a voice at note-on.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AdsrSpec {
    pub attack_frames: u32,
    pub decay_frames: u32,
    pub sustain: f32,
    pub release_frames: u32,
}

impl Default for AdsrSpec {
    fn default() -> Self {
        Self {
            attack_frames: 1,
            decay_frames: 1,
            sustain: 1.0,
            release_frames: 1,
        }
    }
}

impl AdsrSpec {
    /// Seconds -> frames. Every stage is at least ONE frame: a zero-length
    /// stage would divide by zero and, worse, make "note on" and "note off"
    /// land on the same value regardless of the parameter.
    pub fn from_seconds(
        attack_s: f32,
        decay_s: f32,
        sustain: f32,
        release_s: f32,
        sample_rate: u32,
    ) -> Self {
        let rate = sample_rate.max(1) as f32;
        let to_frames = |s: f32| -> u32 {
            let f = (s.clamp(0.0, 60.0) * rate).round();
            (f as u32).max(1)
        };
        Self {
            attack_frames: to_frames(attack_s),
            decay_frames: to_frames(decay_s),
            sustain: sustain.clamp(0.0, 1.0),
            release_frames: to_frames(release_s),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Idle,
    Attack,
    Decay,
    Sustain,
    Release,
}

#[derive(Debug, Clone, Copy)]
pub struct AdsrEnv {
    stage: Stage,
    elapsed: u32,
    spec: AdsrSpec,
    level: f32,
    release_from: f32,
}

impl Default for AdsrEnv {
    fn default() -> Self {
        Self {
            stage: Stage::Idle,
            elapsed: 0,
            spec: AdsrSpec::default(),
            level: 0.0,
            release_from: 0.0,
        }
    }
}

impl AdsrEnv {
    /// Start (or restart) the envelope from zero with a snapshotted spec.
    /// The spec is captured at note-on: a cutoff sweep automates per frame,
    /// but an attack time that changed mid-note would be nonsense.
    #[inline]
    pub fn trigger(&mut self, spec: AdsrSpec) {
        self.spec = spec;
        self.stage = Stage::Attack;
        self.elapsed = 0;
        self.level = 0.0;
        self.release_from = 0.0;
    }

    /// Enter release from wherever the level currently is. Idempotent, and a
    /// no-op on an idle envelope (a duplicate note-off must not resurrect a
    /// finished voice).
    #[inline]
    pub fn release(&mut self) {
        if self.stage == Stage::Idle || self.stage == Stage::Release {
            return;
        }
        self.release_from = self.level;
        self.stage = Stage::Release;
        self.elapsed = 0;
    }

    /// Hard stop with no ramp. Only for a pool reset / panic; voice STEALING
    /// declicks through the pool's steal fade, never through this.
    #[inline]
    pub fn kill(&mut self) {
        self.stage = Stage::Idle;
        self.elapsed = 0;
        self.level = 0.0;
        self.release_from = 0.0;
    }

    #[inline(always)]
    pub fn is_idle(&self) -> bool {
        self.stage == Stage::Idle
    }

    #[inline(always)]
    pub fn is_releasing(&self) -> bool {
        self.stage == Stage::Release
    }

    #[inline(always)]
    pub fn level(&self) -> f32 {
        self.level
    }

    #[inline(always)]
    pub fn stage(&self) -> Stage {
        self.stage
    }

    /// Advance ONE frame and return the new level.
    #[inline(always)]
    pub fn advance(&mut self) -> f32 {
        match self.stage {
            Stage::Idle => {
                self.level = 0.0;
            }
            Stage::Attack => {
                let n = self.spec.attack_frames;
                self.elapsed += 1;
                if self.elapsed >= n {
                    // Assigned, not accumulated: exactly 1.0.
                    self.level = 1.0;
                    self.stage = Stage::Decay;
                    self.elapsed = 0;
                } else {
                    // Quadratic ease-out: fast off the floor, no corner at the
                    // top. t*(2-t) is exactly 1.0 at t == 1.
                    let t = self.elapsed as f32 / n as f32;
                    self.level = t * (2.0 - t);
                }
            }
            Stage::Decay => {
                let n = self.spec.decay_frames;
                self.elapsed += 1;
                if self.elapsed >= n {
                    self.level = self.spec.sustain;
                    self.stage = Stage::Sustain;
                    self.elapsed = 0;
                } else {
                    let t = self.elapsed as f32 / n as f32;
                    let u = 1.0 - t;
                    self.level = self.spec.sustain + (1.0 - self.spec.sustain) * u * u;
                }
            }
            Stage::Sustain => {
                self.level = self.spec.sustain;
                if self.spec.sustain <= 0.0 {
                    // A percussive patch (sustain 0) must FREE its voice, not
                    // hold a silent one until note-off.
                    self.stage = Stage::Idle;
                    self.level = 0.0;
                }
            }
            Stage::Release => {
                let n = self.spec.release_frames;
                self.elapsed += 1;
                if self.elapsed >= n {
                    // EXACTLY zero, and the voice is now reusable.
                    self.level = 0.0;
                    self.stage = Stage::Idle;
                    self.elapsed = 0;
                } else {
                    let t = self.elapsed as f32 / n as f32;
                    let u = 1.0 - t;
                    self.level = self.release_from * u * u;
                }
            }
        }
        self.level
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(a: u32, d: u32, s: f32, r: u32) -> AdsrSpec {
        AdsrSpec {
            attack_frames: a,
            decay_frames: d,
            sustain: s,
            release_frames: r,
        }
    }

    #[test]
    fn attack_reaches_exactly_one_then_decays_to_sustain() {
        let mut e = AdsrEnv::default();
        e.trigger(spec(100, 50, 0.5, 10));
        let mut peak = 0.0f32;
        for _ in 0..100 {
            peak = peak.max(e.advance());
        }
        assert_eq!(peak, 1.0, "attack lands bit-exactly on 1.0");
        for _ in 0..50 {
            e.advance();
        }
        assert_eq!(e.level(), 0.5, "decay lands bit-exactly on sustain");
        assert_eq!(e.stage(), Stage::Sustain);
    }

    #[test]
    fn release_reaches_exactly_zero_and_frees_the_voice() {
        let mut e = AdsrEnv::default();
        e.trigger(spec(1, 1, 0.8, 240));
        for _ in 0..10 {
            e.advance();
        }
        e.release();
        let mut last = e.level();
        for i in 0..240 {
            let v = e.advance();
            assert!(v <= last + 1e-6, "release is monotone (frame {i})");
            last = v;
        }
        assert_eq!(e.level(), 0.0, "release reaches EXACTLY zero");
        assert!(e.is_idle(), "voice is free after release");
    }

    #[test]
    fn release_is_never_truncated_early() {
        let mut e = AdsrEnv::default();
        e.trigger(spec(1, 1, 1.0, 240));
        e.advance();
        e.release();
        for i in 0..239 {
            let v = e.advance();
            assert!(v > 0.0, "still ringing at release frame {i}, value {v}");
        }
        assert_eq!(e.advance(), 0.0);
    }

    #[test]
    fn zero_sustain_frees_the_voice_without_a_note_off() {
        let mut e = AdsrEnv::default();
        e.trigger(spec(2, 2, 0.0, 10));
        for _ in 0..8 {
            e.advance();
        }
        assert!(e.is_idle(), "sustain 0 releases the voice by itself");
    }

    #[test]
    fn note_off_on_an_idle_envelope_is_a_no_op() {
        let mut e = AdsrEnv::default();
        e.release();
        assert!(e.is_idle());
        assert_eq!(e.advance(), 0.0);
    }

    #[test]
    fn seconds_conversion_never_yields_a_zero_length_stage() {
        let s = AdsrSpec::from_seconds(0.0, 0.0, 0.0, 0.0, 48_000);
        assert_eq!(s.attack_frames, 1);
        assert_eq!(s.decay_frames, 1);
        assert_eq!(s.release_frames, 1);
    }
}
