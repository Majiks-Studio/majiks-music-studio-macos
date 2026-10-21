//! Rational tempo math: 960 PPQ integer ticks, tempo as a num/den rational.
//!
//! No float beat math anywhere. Tick to frame conversion is exact rational
//! arithmetic in u128 with round-half-up at the final division, so 92 BPM is
//! exactly as first-class as 120 BPM.
//!
//! v1 model: a single tempo segment starting at tick 0 (the constructor
//! enforces this), but the type carries a segment list so tempo changes later
//! extend the data, not the API. Multi-segment conversion rounds per segment
//! boundary; when L1 lands real tempo changes it must switch the origin
//! accumulation to exact rational sums (documented TODO, not silent drift).

use serde::{Deserialize, Serialize};

use crate::error::CommandError;

/// Pulses per quarter note. Locked by 02-ARCHITECTURE.md section 3.
pub const PPQ: u64 = 960;

/// Beats per minute as an exact rational (num/den).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Bpm {
    pub num: u32,
    pub den: u32,
}

impl Bpm {
    /// Exact rational from a JSON number's decimal text (the catalog
    /// `project.setTempo` wire form). Integer-shaped numbers map to den 1;
    /// fractional values are taken from their decimal digits ("92.5" ->
    /// 185/2). Precision beyond 6 fractional digits rounds (u32 rational
    /// bounds; documented in the evidence doc, inaudible at < 1e-6 BPM).
    pub fn from_json_number(n: &serde_json::Number) -> Result<Self, CommandError> {
        if let Some(i) = n.as_u64() {
            let v = u32::try_from(i)
                .map_err(|_| CommandError::InvalidParams(format!("bpm {i} out of range")))?;
            return Self::new(v, 1);
        }
        let f = n
            .as_f64()
            .ok_or_else(|| CommandError::InvalidParams("bpm must be a number".into()))?;
        if !f.is_finite() || f <= 0.0 || f > 999.0 {
            return Err(CommandError::InvalidParams(format!(
                "bpm must be in (0, 999], got {f}"
            )));
        }
        // 6 fractional digits: numerator <= 999 * 1e6 fits u32.
        let scaled = (f * 1_000_000.0).round() as u64;
        if scaled == 0 {
            return Err(CommandError::InvalidParams(format!(
                "bpm {f} rounds to zero"
            )));
        }
        let mut num = scaled;
        let mut den: u64 = 1_000_000;
        let g = gcd(num, den);
        num /= g;
        den /= g;
        Self::new(num as u32, den as u32)
    }

    pub fn new(num: u32, den: u32) -> Result<Self, CommandError> {
        if num == 0 || den == 0 {
            return Err(CommandError::InvalidParams(
                "bpm numerator and denominator must be nonzero".to_string(),
            ));
        }
        Ok(Self { num, den })
    }

    pub fn from_int(bpm: u32) -> Result<Self, CommandError> {
        Self::new(bpm, 1)
    }

    /// Display-only float view. Never used in position math.
    pub fn as_f64(&self) -> f64 {
        f64::from(self.num) / f64::from(self.den)
    }
}

/// One tempo region. v1 projects hold exactly one, starting at tick 0.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TempoSegment {
    pub start_tick: u64,
    pub bpm: Bpm,
}

/// The project tempo map. Time signature is fixed 4/4 in v1 (honest fence;
/// `project.setTimeSig` is catalog v1 but out of P0-B scope).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TempoMap {
    segments: Vec<TempoSegment>,
}

/// Round-half-up integer division.
fn round_div(n: u128, d: u128) -> u128 {
    (n + d / 2) / d
}

fn gcd(mut a: u64, mut b: u64) -> u64 {
    while b != 0 {
        let t = a % b;
        a = b;
        b = t;
    }
    a.max(1)
}

impl TempoMap {
    /// The v1 constructor: one segment at tick 0.
    pub fn single(bpm: Bpm) -> Self {
        Self {
            segments: vec![TempoSegment { start_tick: 0, bpm }],
        }
    }

    pub fn segments(&self) -> &[TempoSegment] {
        &self.segments
    }

    /// v1 tempo mutation: replace the single segment's bpm (the API carries a
    /// segment list so tempo CHANGES later extend the data, not the API).
    pub fn set_single(&mut self, bpm: Bpm) {
        self.segments = vec![TempoSegment { start_tick: 0, bpm }];
    }

    /// The bpm of the first (v1: only) segment.
    pub fn first_bpm(&self) -> Bpm {
        self.segments
            .first()
            .map(|s| s.bpm)
            .unwrap_or(Bpm { num: 120, den: 1 })
    }

    /// The segment governing `tick`. Falls back to the first segment; an
    /// empty map is invalid by construction but handled without panic.
    fn segment_at(&self, tick: u64) -> TempoSegment {
        let mut current = self.segments.first().copied().unwrap_or(TempoSegment {
            start_tick: 0,
            bpm: Bpm { num: 120, den: 1 },
        });
        for segment in &self.segments {
            if segment.start_tick <= tick {
                current = *segment;
            } else {
                break;
            }
        }
        current
    }

    /// Frame origin of a segment: the frame position of its start tick.
    /// v1: single segment at tick 0, origin 0. Multi-segment maps accumulate
    /// with per-boundary rounding (TODO L1: exact rational accumulation).
    fn segment_frame_origin(&self, segment_start_tick: u64, sample_rate: u32) -> u128 {
        let mut origin: u128 = 0;
        let mut prev_tick: u64 = 0;
        let mut prev_bpm: Option<Bpm> = None;
        for segment in &self.segments {
            if segment.start_tick >= segment_start_tick {
                break;
            }
            if let Some(bpm) = prev_bpm {
                origin += Self::span_frames(segment.start_tick - prev_tick, bpm, sample_rate);
            }
            prev_tick = segment.start_tick;
            prev_bpm = Some(segment.bpm);
        }
        if let Some(bpm) = prev_bpm {
            origin += Self::span_frames(segment_start_tick - prev_tick, bpm, sample_rate);
        }
        origin
    }

    /// Exact frames for a tick span at one tempo, round-half-up:
    /// frames = ticks * rate * 60 * den / (PPQ * num).
    fn span_frames(ticks: u64, bpm: Bpm, sample_rate: u32) -> u128 {
        let n = u128::from(ticks) * u128::from(sample_rate) * 60 * u128::from(bpm.den);
        let d = u128::from(PPQ) * u128::from(bpm.num);
        round_div(n, d)
    }

    /// Timeline tick to sample frame at `sample_rate`.
    pub fn tick_to_frame(&self, tick: u64, sample_rate: u32) -> u64 {
        let segment = self.segment_at(tick);
        let origin = self.segment_frame_origin(segment.start_tick, sample_rate);
        let frames =
            origin + Self::span_frames(tick - segment.start_tick, segment.bpm, sample_rate);
        u64::try_from(frames).unwrap_or(u64::MAX)
    }

    /// Sample frame back to the nearest timeline tick.
    pub fn frame_to_tick(&self, frame: u64, sample_rate: u32) -> u64 {
        // v1: single segment; multi-segment inversion arrives with L1.
        let segment = self.segment_at(0);
        let n = u128::from(frame) * u128::from(PPQ) * u128::from(segment.bpm.num);
        let d = u128::from(sample_rate) * 60 * u128::from(segment.bpm.den);
        u64::try_from(round_div(n, d)).unwrap_or(u64::MAX)
    }

    /// Bar index (0-based) to tick. 4/4 fixed in v1.
    pub fn bar_to_tick(&self, bar: u64) -> u64 {
        bar * 4 * PPQ
    }

    /// Beat index (0-based, quarter notes) to tick.
    pub fn beat_to_tick(&self, beat: u64) -> u64 {
        beat * PPQ
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(bpm: u32) -> TempoMap {
        TempoMap::single(Bpm::from_int(bpm).unwrap())
    }

    #[test]
    fn tick_to_frame_is_exact_at_120() {
        let m = map(120);
        // 120 BPM at 48 kHz: exactly 25 frames per tick, 24000 per beat.
        assert_eq!(m.tick_to_frame(0, 48_000), 0);
        assert_eq!(m.tick_to_frame(1, 48_000), 25);
        assert_eq!(m.tick_to_frame(PPQ, 48_000), 24_000);
        assert_eq!(m.tick_to_frame(m.bar_to_tick(1), 48_000), 96_000);
        assert_eq!(m.tick_to_frame(m.bar_to_tick(1000), 48_000), 96_000_000);
    }

    #[test]
    fn tick_to_frame_rounds_rationally_at_92_and_174() {
        let m92 = map(92);
        // frames = ticks * 3000 / 92 (48k, PPQ 960): one bar = 3840 ticks.
        // 3840 * 3000 / 92 = 125217.391..., round half up = 125217.
        assert_eq!(m92.tick_to_frame(3840, 48_000), 125_217);
        // One beat: 960 * 3000 / 92 = 31304.34... -> 31304.
        assert_eq!(m92.tick_to_frame(960, 48_000), 31_304);

        let m174 = map(174);
        // 3840 * 3000 / 174 = 66206.896... -> 66207.
        assert_eq!(m174.tick_to_frame(3840, 48_000), 66_207);
    }

    #[test]
    fn fractional_bpm_is_supported_exactly() {
        // 87.5 BPM as 175/2.
        let m = TempoMap::single(Bpm::new(175, 2).unwrap());
        // frames per beat = 48000 * 60 * 2 / 175 = 32914.28..., beat 7 =
        // 960*7 ticks -> 6720 * 3000 * 2 / 175 = 230400.0 exactly.
        assert_eq!(m.tick_to_frame(6720, 48_000), 230_400);
    }

    #[test]
    fn frame_round_trip_holds_across_tempos() {
        for bpm in [92_u32, 120, 174, 63, 141] {
            let m = map(bpm);
            for tick in [0_u64, 1, 7, 959, 960, 3840, 10_000, 123_456, 3_840_000] {
                let frame = m.tick_to_frame(tick, 48_000);
                assert_eq!(
                    m.frame_to_tick(frame, 48_000),
                    tick,
                    "round trip failed at {bpm} bpm tick {tick}"
                );
            }
        }
    }

    #[test]
    fn tick_to_frame_is_monotonic() {
        let m = map(174);
        let mut last = 0;
        for tick in 0..20_000_u64 {
            let frame = m.tick_to_frame(tick, 48_000);
            assert!(frame >= last, "not monotonic at tick {tick}");
            last = frame;
        }
    }

    #[test]
    fn sample_rate_is_a_parameter_not_an_assumption() {
        let m = map(120);
        assert_eq!(m.tick_to_frame(PPQ, 44_100), 22_050);
        assert_eq!(m.tick_to_frame(PPQ, 96_000), 48_000);
    }

    #[test]
    fn bpm_validation_rejects_zero() {
        assert!(Bpm::new(0, 1).is_err());
        assert!(Bpm::new(120, 0).is_err());
    }
}
