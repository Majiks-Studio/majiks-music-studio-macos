//! Honest RBJ cookbook biquads (low shelf, peaking bell, high shelf) in
//! Direct Form 2 Transposed, with per-frame coefficient ramping for
//! zipper-free parameter changes.
//!
//! Bit-exactness contract (the P0-B playback tests depend on it): a band at
//! 0 dB gain produces coefficients where b0 == 1 and b1 == a1, b2 == a2, so
//! with zero state y == x exactly. `BandKind` at 0 dB is therefore a true
//! bypass, and `EqBank` additionally short-circuits when every band is flat
//! and its state has decayed to zero.

use crate::dsp::flush_denormal;

pub const EQ_BANDS: usize = 4;

/// Fixed band layout per the catalog (`mix.eq`: 4 bands, index 0-3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BandKind {
    LowShelf,
    Bell,
    HighShelf,
}

pub const BAND_KINDS: [BandKind; EQ_BANDS] = [
    BandKind::LowShelf,
    BandKind::Bell,
    BandKind::Bell,
    BandKind::HighShelf,
];

/// Default band frequencies (Hz): low shelf, low-mid bell, hi-mid bell,
/// high shelf.
pub const BAND_DEFAULT_HZ: [f32; EQ_BANDS] = [80.0, 400.0, 2_500.0, 8_000.0];
pub const BAND_DEFAULT_Q: f32 = 0.71;

/// Normalized biquad coefficients (a0 divided out).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Coeffs {
    pub b0: f32,
    pub b1: f32,
    pub b2: f32,
    pub a1: f32,
    pub a2: f32,
}

pub const IDENTITY: Coeffs = Coeffs {
    b0: 1.0,
    b1: 0.0,
    b2: 0.0,
    a1: 0.0,
    a2: 0.0,
};

/// RBJ cookbook coefficients for one band. `gain_db` is the shelf/bell gain,
/// `q` shapes the bell width / shelf slope.
pub fn compute(kind: BandKind, sample_rate: u32, freq_hz: f32, gain_db: f32, q: f32) -> Coeffs {
    let rate = sample_rate.max(1) as f32;
    // Clamp frequency into a stable range below Nyquist.
    let f = freq_hz.clamp(10.0, rate * 0.45);
    let q = q.clamp(0.05, 10.0);
    let a = 10.0_f32.powf(gain_db / 40.0);
    let w0 = 2.0 * std::f32::consts::PI * f / rate;
    let (sin_w0, cos_w0) = w0.sin_cos();
    let alpha = sin_w0 / (2.0 * q);
    let root_a = a.sqrt();

    let (b0, b1, b2, a0, a1, a2) = match kind {
        BandKind::Bell => {
            let b0 = 1.0 + alpha * a;
            let b1 = -2.0 * cos_w0;
            let b2 = 1.0 - alpha * a;
            let a0 = 1.0 + alpha / a;
            let a1 = -2.0 * cos_w0;
            let a2 = 1.0 - alpha / a;
            (b0, b1, b2, a0, a1, a2)
        }
        BandKind::LowShelf => {
            let two_root_a_alpha = 2.0 * root_a * alpha;
            let b0 = a * ((a + 1.0) - (a - 1.0) * cos_w0 + two_root_a_alpha);
            let b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cos_w0);
            let b2 = a * ((a + 1.0) - (a - 1.0) * cos_w0 - two_root_a_alpha);
            let a0 = (a + 1.0) + (a - 1.0) * cos_w0 + two_root_a_alpha;
            let a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cos_w0);
            let a2 = (a + 1.0) + (a - 1.0) * cos_w0 - two_root_a_alpha;
            (b0, b1, b2, a0, a1, a2)
        }
        BandKind::HighShelf => {
            let two_root_a_alpha = 2.0 * root_a * alpha;
            let b0 = a * ((a + 1.0) + (a - 1.0) * cos_w0 + two_root_a_alpha);
            let b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cos_w0);
            let b2 = a * ((a + 1.0) + (a - 1.0) * cos_w0 - two_root_a_alpha);
            let a0 = (a + 1.0) - (a - 1.0) * cos_w0 + two_root_a_alpha;
            let a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cos_w0);
            let a2 = (a + 1.0) - (a - 1.0) * cos_w0 - two_root_a_alpha;
            (b0, b1, b2, a0, a1, a2)
        }
    };
    Coeffs {
        b0: b0 / a0,
        b1: b1 / a0,
        b2: b2 / a0,
        a1: a1 / a0,
        a2: a2 / a0,
    }
}

/// DF2T state for one channel.
#[derive(Debug, Clone, Copy, Default)]
pub struct BiquadState {
    s1: f32,
    s2: f32,
}

impl BiquadState {
    #[inline(always)]
    pub fn process(&mut self, c: &Coeffs, x: f32) -> f32 {
        let y = c.b0 * x + self.s1;
        self.s1 = c.b1 * x - c.a1 * y + self.s2;
        self.s2 = c.b2 * x - c.a2 * y;
        y
    }

    #[inline]
    pub fn is_quiet(&self) -> bool {
        self.s1.abs() < 1.0e-10 && self.s2.abs() < 1.0e-10
    }

    #[inline]
    pub fn reset(&mut self) {
        self.s1 = 0.0;
        self.s2 = 0.0;
    }

    #[inline]
    pub fn flush(&mut self) {
        self.s1 = flush_denormal(self.s1);
        self.s2 = flush_denormal(self.s2);
    }
}

/// One EQ band: current + target coefficients with a linear per-frame ramp
/// (full transition in `ramp_frames`), stereo filter state, and a cached
/// flat flag for the bit-exact bypass.
#[derive(Debug, Clone)]
pub struct Band {
    pub kind: BandKind,
    cur: Coeffs,
    from: Coeffs,
    to: Coeffs,
    ramp_t: f32,
    ramp_dt: f32,
    state: [BiquadState; 2],
    /// Band gain is exactly 0 dB (target).
    flat_target: bool,
}

impl Band {
    pub fn new(kind: BandKind, coeffs: Coeffs, flat: bool, ramp_frames: u32) -> Self {
        Self {
            kind,
            cur: coeffs,
            from: coeffs,
            to: coeffs,
            ramp_t: 1.0,
            ramp_dt: 1.0 / ramp_frames.max(1) as f32,
            state: [BiquadState::default(); 2],
            flat_target: flat,
        }
    }

    /// Set new target coefficients. If signal is in flight the band ramps
    /// there over its ramp span; a quiet band (state decayed) snaps, which
    /// is click-free by construction and keeps deterministic renders
    /// identical to a long-settled realtime engine.
    pub fn retarget(&mut self, to: Coeffs, flat: bool) {
        if to == self.to {
            return;
        }
        self.to = to;
        self.flat_target = flat;
        if self.state_quiet() {
            self.cur = to;
            self.from = to;
            self.ramp_t = 1.0;
        } else {
            self.from = self.cur;
            self.ramp_t = 0.0;
        }
    }

    #[inline(always)]
    fn advance_ramp(&mut self) {
        if self.ramp_t < 1.0 {
            self.ramp_t = (self.ramp_t + self.ramp_dt).min(1.0);
            if self.ramp_t >= 1.0 {
                self.cur = self.to;
            } else {
                let t = self.ramp_t;
                self.cur = Coeffs {
                    b0: self.from.b0 + (self.to.b0 - self.from.b0) * t,
                    b1: self.from.b1 + (self.to.b1 - self.from.b1) * t,
                    b2: self.from.b2 + (self.to.b2 - self.from.b2) * t,
                    a1: self.from.a1 + (self.to.a1 - self.from.a1) * t,
                    a2: self.from.a2 + (self.to.a2 - self.from.a2) * t,
                };
            }
        }
    }

    #[inline(always)]
    fn process_frame(&mut self, frame: &mut [f32; 2]) {
        self.advance_ramp();
        frame[0] = self.state[0].process(&self.cur, frame[0]);
        frame[1] = self.state[1].process(&self.cur, frame[1]);
    }

    fn settled_flat(&self) -> bool {
        self.flat_target && self.ramp_t >= 1.0
    }

    fn state_quiet(&self) -> bool {
        self.state[0].is_quiet() && self.state[1].is_quiet()
    }

    fn reset_state(&mut self) {
        self.state[0].reset();
        self.state[1].reset();
    }

    fn flush_state(&mut self) {
        self.state[0].flush();
        self.state[1].flush();
    }
}

/// The 4-band channel EQ for one strip.
#[derive(Debug, Clone)]
pub struct EqBank {
    pub bands: [Band; EQ_BANDS],
    /// Last-applied raw parameter values per band (dirty check: the block
    /// prep calls retarget_band_checked every block; only changes recompute
    /// coefficients or touch the bypass).
    last: [(f32, f32, f32); EQ_BANDS],
    /// True while the whole bank is flat and its state has decayed: the
    /// process path is skipped entirely (bit-exact bypass).
    bypassed: bool,
}

impl EqBank {
    pub fn new(sample_rate: u32, ramp_frames: u32) -> Self {
        let bands = std::array::from_fn(|i| {
            let kind = BAND_KINDS[i];
            let coeffs = compute(kind, sample_rate, BAND_DEFAULT_HZ[i], 0.0, BAND_DEFAULT_Q);
            Band::new(kind, coeffs, true, ramp_frames)
        });
        Self {
            bands,
            last: std::array::from_fn(|i| (BAND_DEFAULT_HZ[i], 0.0, BAND_DEFAULT_Q)),
            bypassed: true,
        }
    }

    /// Retarget one band (index 0-3). Called at block boundaries when the
    /// parameter atomics changed.
    pub fn retarget_band(
        &mut self,
        band: usize,
        sample_rate: u32,
        freq_hz: f32,
        gain_db: f32,
        q: f32,
    ) {
        if let Some(b) = self.bands.get_mut(band) {
            let coeffs = compute(b.kind, sample_rate, freq_hz, gain_db, q);
            b.retarget(coeffs, gain_db == 0.0);
            self.bypassed = false;
        }
    }

    /// Block-boundary entry point: no-op unless the raw values changed.
    #[inline]
    pub fn retarget_band_checked(
        &mut self,
        band: usize,
        sample_rate: u32,
        freq_hz: f32,
        gain_db: f32,
        q: f32,
    ) {
        if let Some(cached) = self.last.get_mut(band) {
            if cached.0 == freq_hz && cached.1 == gain_db && cached.2 == q {
                return;
            }
            *cached = (freq_hz, gain_db, q);
        }
        self.retarget_band(band, sample_rate, freq_hz, gain_db, q);
    }

    /// Block-boundary hygiene: re-evaluate the bypass and flush denormals.
    pub fn block_maintenance(&mut self) {
        if self.bypassed {
            return;
        }
        let mut all_flat = true;
        let mut all_quiet = true;
        for band in &mut self.bands {
            band.flush_state();
            all_flat &= band.settled_flat();
            all_quiet &= band.state_quiet();
        }
        if all_flat && all_quiet {
            for band in &mut self.bands {
                band.reset_state();
            }
            self.bypassed = true;
        }
    }

    #[inline(always)]
    pub fn process_frame(&mut self, frame: &mut [f32; 2]) {
        if self.bypassed {
            return;
        }
        for band in &mut self.bands {
            band.process_frame(frame);
        }
    }

    pub fn is_bypassed(&self) -> bool {
        self.bypassed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Magnitude response of coefficients at a frequency (steady-state).
    fn magnitude(c: &Coeffs, sample_rate: f32, freq: f32) -> f32 {
        let w = 2.0 * std::f64::consts::PI * f64::from(freq) / f64::from(sample_rate);
        let (b0, b1, b2) = (f64::from(c.b0), f64::from(c.b1), f64::from(c.b2));
        let (a1, a2) = (f64::from(c.a1), f64::from(c.a2));
        let num_re = b0 + b1 * w.cos() + b2 * (2.0 * w).cos();
        let num_im = -(b1 * w.sin() + b2 * (2.0 * w).sin());
        let den_re = 1.0 + a1 * w.cos() + a2 * (2.0 * w).cos();
        let den_im = -(a1 * w.sin() + a2 * (2.0 * w).sin());
        let num = (num_re * num_re + num_im * num_im).sqrt();
        let den = (den_re * den_re + den_im * den_im).sqrt();
        (num / den) as f32
    }

    #[test]
    fn flat_gain_is_exact_identity() {
        for kind in [BandKind::LowShelf, BandKind::Bell, BandKind::HighShelf] {
            let c = compute(kind, 48_000, 1_000.0, 0.0, 0.71);
            assert_eq!(c.b0, 1.0, "{kind:?} b0");
            assert_eq!(c.b1, c.a1, "{kind:?} b1==a1");
            assert_eq!(c.b2, c.a2, "{kind:?} b2==a2");
            // And the filter really passes samples through bit-exactly.
            let mut st = BiquadState::default();
            for i in 0..64 {
                let x = ((i * 37) as f32 * 0.01).sin() * 0.7;
                let y = st.process(&c, x);
                assert_eq!(y.to_bits(), x.to_bits(), "{kind:?} frame {i}");
            }
        }
    }

    #[test]
    fn bell_hits_its_center_gain() {
        for gain_db in [-12.0_f32, -4.0, 3.0, 9.0] {
            let c = compute(BandKind::Bell, 48_000, 1_000.0, gain_db, 1.0);
            let mag = magnitude(&c, 48_000.0, 1_000.0);
            let mag_db = 20.0 * mag.log10();
            assert!(
                (mag_db - gain_db).abs() < 0.05,
                "bell center gain {gain_db} dB, measured {mag_db} dB"
            );
        }
    }

    #[test]
    fn low_shelf_hits_dc_gain_high_shelf_hits_nyquist_gain() {
        let c = compute(BandKind::LowShelf, 48_000, 200.0, 6.0, 0.71);
        let dc = 20.0 * magnitude(&c, 48_000.0, 1.0).log10();
        assert!((dc - 6.0).abs() < 0.05, "low shelf DC gain measured {dc}");
        let high_end = 20.0 * magnitude(&c, 48_000.0, 20_000.0).log10();
        assert!(high_end.abs() < 0.1, "low shelf leaves the top alone: {high_end}");

        let c = compute(BandKind::HighShelf, 48_000, 5_000.0, -9.0, 0.71);
        let ny = 20.0 * magnitude(&c, 48_000.0, 23_900.0).log10();
        assert!((ny + 9.0).abs() < 0.1, "high shelf Nyquist gain measured {ny}");
        let low_end = 20.0 * magnitude(&c, 48_000.0, 30.0).log10();
        assert!(low_end.abs() < 0.05, "high shelf leaves the bottom alone: {low_end}");
    }

    #[test]
    fn eq_bank_bypass_engages_after_flat_and_quiet() {
        let mut bank = EqBank::new(48_000, 240);
        assert!(bank.is_bypassed());
        bank.retarget_band(1, 48_000, 400.0, 6.0, 1.0);
        assert!(!bank.is_bypassed());
        // Run some signal through, then set flat and feed silence.
        for _ in 0..1_000 {
            let mut frame = [0.5, -0.5];
            bank.process_frame(&mut frame);
        }
        bank.retarget_band(1, 48_000, 400.0, 0.0, 1.0);
        for _ in 0..200 {
            for _ in 0..128 {
                let mut f = [0.0, 0.0];
                bank.process_frame(&mut f);
            }
            bank.block_maintenance();
        }
        assert!(bank.is_bypassed(), "flat + decayed bank re-bypasses");
    }

    #[test]
    fn coefficient_ramp_prevents_steps_on_gain_toggle() {
        // A 12 dB bell toggle on a steady low tone must not step the output.
        let mut bank = EqBank::new(48_000, 240);
        let mut out = Vec::new();
        let tone = |i: usize| (2.0 * std::f32::consts::PI * 100.0 * i as f32 / 48_000.0).sin() * 0.5;
        for i in 0..2_000 {
            let mut f = [tone(i), tone(i)];
            if i == 500 {
                bank.retarget_band(1, 48_000, 300.0, 12.0, 1.0);
            }
            if i == 1_200 {
                bank.retarget_band(1, 48_000, 300.0, 0.0, 1.0);
            }
            bank.process_frame(&mut f);
            out.push(f[0]);
        }
        // Max legitimate per-frame delta for a 100 Hz half-scale tone with a
        // +12 dB bell is well under 0.02 without steps.
        let max_source_step = 2.0 * std::f32::consts::PI * 100.0 / 48_000.0 * 0.5 * 4.1;
        for (i, w) in out.windows(2).enumerate() {
            let step = (w[1] - w[0]).abs();
            assert!(
                step < max_source_step + 0.02,
                "zipper step {step} at frame {i}"
            );
        }
    }
}
