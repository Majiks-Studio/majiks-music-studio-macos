//! DSP primitives for the render graph. Everything here is fixed-size,
//! allocation-free in its process path, and advances per FRAME (never per
//! block), so output is chunk-size independent when parameters are static.
//! That per-frame rule is what keeps the offline bounce bit-identical to the
//! realtime callback at any block size (the null-test bar).

pub mod biquad;
/// The metronome click. Monitor-path DSP: audible live, structurally excluded
/// from every offline render (see `rt::CoreConfig::monitor`).
pub mod click;
pub mod delay;
pub mod limiter;
pub mod pan;
pub mod reverb;
pub mod slew;
pub mod truepeak;

// E2 software instruments. Same rules: fixed-size, allocation-free in the
// process path, per-FRAME advance. `note` carries the E1 note seam.
pub mod drum;
pub mod env;
pub mod instrument;
pub mod note;
pub mod osc;
pub mod sampler;
pub mod svf;
pub mod synth;
pub mod voice;

// E5 effect devices (DESIGN-E5-routing.md §16-§17). Same rules again, and the
// per-FRAME one is load-bearing twice over here: §16.7 forbids an fx with a
// per-block process method outright, because it would break bit-identity at
// 128/417/480/512. `fx` carries the FxNode trait, the parameter slot layout
// and the four REUSE wrappers (EqBank / DelayBus / ReverbBus / Limiter);
// `compressor`, `gate`, `saturator` and `chorus` are the only genuinely new
// DSP in the suite, and `gate` shares `compressor`'s detector.
pub mod chorus;
pub mod compressor;
pub mod fx;
pub mod gate;
pub mod saturator;
pub mod utility;

/// Flush tiny values to zero. Feedback structures (reverb combs, delay
/// lines, filter state) decay into denormals on silence; flushing keeps the
/// idle graph cheap and the state exactly zero for deterministic starts.
#[inline(always)]
pub fn flush_denormal(x: f32) -> f32 {
    if x.abs() < 1.0e-20 {
        0.0
    } else {
        x
    }
}

/// dB to linear gain.
#[inline]
pub fn db_to_lin(db: f32) -> f32 {
    10.0_f32.powf(db * 0.05)
}

/// Linear gain to dB (floor at -160 dB for zero).
#[inline]
pub fn lin_to_db(lin: f32) -> f32 {
    if lin > 0.0 {
        20.0 * lin.log10()
    } else {
        -160.0
    }
}
