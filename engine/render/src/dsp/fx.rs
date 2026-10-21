//! E5-fx: the effect-device DSP layer (`DESIGN-E5-routing.md` §16–§17, §21.2).
//!
//! This module owns the **`FxNode` trait** (§21.2 seam 2), the per-kind
//! **parameter slot layout**, and `FxUnit` — the render-side realisation of a
//! `timeline_core::FxKind` that `compile.rs` constructs and `rt.rs` calls.
//! E5-fx owns the implementations; E5-graph owns the call site. Nothing in
//! this module touches `rt.rs`, `compile.rs`, `strip.rs` or `params.rs`.
//!
//! ## The rules everything here obeys (§6.1, §16.7)
//!
//! - **Every signal state advances per FRAME.** There is no per-block process
//!   method anywhere in this module, deliberately: a per-block shortcut makes
//!   a node's output depend on the buffer size and destroys the bit-identity
//!   between the live callback (128) and the offline bounce (512) that
//!   `render/tests/graph.rs` proves. `render/tests/fx.rs` pins this by
//!   chunking the identical input at 1 / 128 / 417 / 480 / 512 and asserting
//!   the output is **bit-identical**.
//! - **No allocation, no locks, no IO, no logging in `process_frame` or
//!   `load_block_targets`.** Every ring and every table is allocated in a
//!   constructor, control-side. Proven with `guard::CountingAlloc` (plus a
//!   positive control) in `render/tests/fx.rs`.
//! - **Seven of nine kinds reuse DSP that already exists** (§17.1): `EqBank`,
//!   `DelayBus`, `ReverbBus`, `Limiter` and `pan::balance_gains` are wrapped,
//!   never reimplemented. Only the compressor, gate, saturator and chorus are
//!   new code.
//! - **`latency_frames()` is a constant for the life of the node** (§21.2) and
//!   is `0` for every kind except `Limiter`, which reports the 96 frames its
//!   lookahead genuinely costs (§17.1, §19.1). It does **not** change when the
//!   unit is bypassed — PDC compensates topology, not switch position.
//!
//! ## The E5-params seam — now the verbatim signature
//!
//! §21.2 states `fn load_block_targets(&mut self, p: &EngineParams, base_slot: usize)`
//! and that is exactly what this module implements. `EngineParams`'s §16.6 /
//! §23.4 fx surface (`fx_param_target`, `set_fx_param`, `clear_fx_params_from`,
//! `set_fx_bypass`, `fx_bypassed`, `MAX_FX_PARAMS_PER_FX`) has landed, so no
//! fixture stands in for it. E5-fx never writes `params.rs`; it only reads.
//!
//! `base_slot = fx_slot * MAX_FX_PARAMS_PER_FX` (§23.4), so the fx slot is
//! recoverable from the base slot — which is how `load_block_targets` reads
//! `fx_bypassed(fx_slot)` from a signature that carries only `base_slot`.
//!
//! **No kind may declare more than `MAX_FX_PARAMS_PER_FX` (32) keys** (§23.4).
//! The widest is `Eq` at 12. A `const` assertion below makes exceeding it a
//! compile error in this crate rather than a `compile.rs` runtime rejection.
//!
//! ## Bypass occupies NO parameter slot
//!
//! §16.6 keeps `bypass` a *param on the wire* (`fx.param.set {key: "bypass"}`)
//! so it automates for free, and §23.4 pins `EngineParams::fx_bypassed(fx_slot)`
//! as the render-side load. Those are one fact with two spellings, so this
//! module reads **only** `fx_bypassed` and gives `bypass` no slot in any kind's
//! parameter block. Two independent spellings of one fact is the desync trap §2
//! rejects, and a slot nothing reads is §0 row 7's bug class.
//!
//! ⚠️ **E5-model/E5-graph consequence:** the `bypass` key must map to
//! `EngineParams::set_fx_bypass(fx_slot, …)`, **not** to a `set_fx_param` slot.
//! `BYPASS_KEY` is still reported by [`all_fx_param_keys`] so it appears in
//! `FX_PARAM_KEYS`.
//!
use crate::dsp::biquad::{EqBank, BAND_DEFAULT_HZ, BAND_DEFAULT_Q, EQ_BANDS};
use crate::dsp::chorus::ChorusFx;
use crate::dsp::compressor::CompressorFx;
use crate::dsp::delay::DelayBus;
use crate::dsp::gate::GateFx;
use crate::dsp::limiter::{Limiter, LOOKAHEAD_FRAMES};
use crate::dsp::reverb::ReverbBus;
use crate::dsp::saturator::SaturatorFx;
use crate::dsp::slew::Slew;
use crate::dsp::utility::UtilityFx;
use crate::dsp::{db_to_lin, flush_denormal};
use crate::params::{EngineParams, MAX_FX_PARAMS_PER_FX};

/// The wire key for bypass. It occupies no parameter slot (see the module
/// header): `EngineParams::fx_bypassed(fx_slot)` is the only read path.
pub const BYPASS_KEY: &str = "bypass";

/// Largest parameter count of any kind (`Eq`: 4 bands x {freq, gain, q}).
/// Lets a caller size a fixed scratch array without a heap allocation.
pub const MAX_FX_PARAMS: usize = EQ_BANDS * 3;

/// §23.4: no effect may declare more than `MAX_FX_PARAMS_PER_FX` keys, or its
/// slots would alias into the next effect's block. Enforced at compile time
/// here so a lane adding a parameter cannot discover it at integration.
const _: () = assert!(MAX_FX_PARAMS <= MAX_FX_PARAMS_PER_FX);

/// The parameter base slot of an fx instance (§23.4).
#[inline]
pub fn base_slot_of(fx_slot: usize) -> usize {
    fx_slot * MAX_FX_PARAMS_PER_FX
}

/// The fx instance owning a parameter base slot — the inverse of
/// [`base_slot_of`], and how `load_block_targets` reaches `fx_bypassed` from a
/// signature that carries only `base_slot`.
#[inline]
pub fn fx_slot_of(base_slot: usize) -> usize {
    base_slot / MAX_FX_PARAMS_PER_FX
}

// ---------------------------------------------------------------------------
// Control-side helpers over the EngineParams fx surface
// ---------------------------------------------------------------------------

/// Seed one fx instance's whole parameter block with its DSP defaults.
///
/// §16.4: params stay SPARSE on the wire and *"an absent key means the DSP
/// default"*, the `InstrumentParams::default()`-then-override shape
/// `build_instrument` already uses (`compile.rs:349-363`). `compile.rs` must
/// call this before applying a project's stored `Fx::params`, or an effect
/// inherits `FX_PARAM_CLEARED` (0.0) for every key it does not set — which for
/// a compressor is `ratio = 0`.
///
/// Control-side only. `read_param` additionally clamps every read, so a slab
/// that was never seeded degrades to a legal, neutral setting instead of to a
/// NaN or a division by zero on the audio thread.
pub fn seed_fx_defaults(p: &EngineParams, kind: FxKindId, fx_slot: usize) {
    let base = base_slot_of(fx_slot);
    for (i, spec) in kind.params().iter().enumerate() {
        p.set_fx_param(base + i, spec.default);
    }
    p.set_fx_bypass(fx_slot, false);
}

/// Set one parameter by its wire key. Returns false when the kind has no such
/// key — which the contract layer must NOT treat as an error (§16.3 forbids
/// validating the (kind, key) pairing at apply time); it is what
/// `CompileReport::inert_lanes` reports.
///
/// `BYPASS_KEY` is routed to `set_fx_bypass`, not to a parameter slot.
pub fn set_fx_param_by_key(
    p: &EngineParams,
    kind: FxKindId,
    fx_slot: usize,
    key: &str,
    value: f32,
) -> bool {
    if key == BYPASS_KEY {
        p.set_fx_bypass(fx_slot, value >= 0.5);
        return true;
    }
    match kind.param_index(key) {
        Some(i) => {
            p.set_fx_param(base_slot_of(fx_slot) + i, value);
            true
        }
        None => false,
    }
}

// ---------------------------------------------------------------------------
// The node trait (§21.2 seam 2)
// ---------------------------------------------------------------------------

/// One effect in an insert chain.
///
/// `process_frame` is called once per FRAME (§6.1) — never per block, no
/// exceptions. `key` is the sidechain input for this frame, or the fx's own
/// input when unkeyed (§17.3); an unkeyed call site passes `key == x`.
pub trait FxNode {
    /// Per FRAME (§6.1). Never per block.
    fn process_frame(&mut self, x: [f32; 2], key: [f32; 2]) -> [f32; 2];

    /// Read once per block from the parameter atomics into targets.
    /// No allocation, no locks.
    fn load_block_targets(&mut self, p: &EngineParams, base_slot: usize);

    /// **The per-frame parameter seam** — the hook `lane_gap_reason` said the
    /// contract lacked, added so fx-parameter automation can exist without
    /// violating §6.1.
    ///
    /// Drive ONE parameter from an automation lane for THIS frame. `index` is
    /// the slot offset within the kind's parameter block — the same index
    /// `load_block_targets` reads at `base_slot + index` — and `value` is in
    /// the key's wire units (dB, ms, 0..1), exactly what `set_fx_param` and the
    /// lane store carry.
    ///
    /// The rules that keep this from being the §6.1/§16.3 cost cliff:
    ///
    /// - **Called once per FRAME per automated key**, before that frame's
    ///   `process_frame`, so the value the frame renders is the lane's value at
    ///   that frame regardless of how frames are chunked into blocks. Bounce
    ///   parity at 128/417/480/512 depends on this — applying a lane at block
    ///   boundaries is exactly the bug this trait method exists to avoid.
    /// - **An implementation may spend arithmetic and comparisons only, plus a
    ///   dB→lin conversion CACHED on value change** (the class the volume lane
    ///   already pays — `Strip::vol_lane_lin`, `node_gain_last_db`). It must
    ///   NEVER recompute a filter or envelope coefficient (`coeff_from_ms`'s
    ///   `exp`, `retarget_band_checked`'s RBJ trig): every key whose
    ///   application needs one is declared `FxParamRate::Block` in its spec and
    ///   is REFUSED as a lane target by compile, per key, before it can reach
    ///   here.
    /// - Only `FxParamRate::Frame` indices are ever passed. A `Block` or
    ///   out-of-range index is a caller bug: implementations `debug_assert` and
    ///   no-op (never panic — this runs on the audio thread).
    /// - The caller (`FxUnit`) clamps to the spec range and maps NaN to the
    ///   spec default before dispatching, so implementations receive a finite,
    ///   in-range value. `bypass` has no index and never arrives here (§23.5).
    ///
    /// No default body, deliberately: a default no-op would let a new kind
    /// compile with silently inert automation — §0 row 7's bug shape, at the
    /// trait level.
    fn set_frame_param(&mut self, index: usize, value: f32);

    /// Frames of latency (§19). MUST be a constant for the life of the node,
    /// and must NOT vary with bypass.
    fn latency_frames(&self) -> u32 {
        0
    }

    /// Block-flushed telemetry: the smallest linear gain this node applied
    /// since the last call (1.0 = no reduction). §17.2 — gain reduction is the
    /// one number a user must see. Never a per-frame atomic write.
    fn take_block_meter(&mut self) -> f32 {
        1.0
    }

    fn reset(&mut self);
}

// ---------------------------------------------------------------------------
// Parameter specs
// ---------------------------------------------------------------------------

/// How a parameter's value is APPLIED, which decides whether an automation
/// lane may drive it per frame.
///
/// This is the render-side single source of truth for the fx-lane
/// readable/refused split: `rt::lane_has_reader` consults it (through
/// [`fx_key_class`]) and `compile` refuses `Block` keys by name. One table,
/// two feeds — a second copy of this classification would drift, and then the
/// gate would refuse a key the walk reads, or worse the reverse.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FxParamRate {
    /// Applying a new value costs arithmetic and comparisons, or a dB→lin
    /// conversion cached on value change — the exact cost class the volume
    /// lane already pays per frame (`Strip::vol_lane_lin`, measured there).
    /// A lane may drive it per FRAME through `FxNode::set_frame_param`.
    Frame,
    /// Applying a new value recomputes a filter or envelope COEFFICIENT
    /// (`coeff_from_ms` is an `exp`; an EQ band retarget is RBJ trig). Read
    /// once per block from the atomics; automation lanes are REFUSED per key
    /// — driving a coefficient recompute per frame is the §6.1/§16.3 cost
    /// cliff that keeps `track.eq.*` refused, and the same answer is given
    /// here for the same reason.
    Block,
}

/// One parameter of one kind. Position in `FxKindId::params()` IS the slot
/// offset from the fx's `base_slot`.
#[derive(Debug, Clone, Copy)]
pub struct FxParamSpec {
    /// Wire key. **Must be a member of `timeline_core::model::FX_PARAM_KEYS`**
    /// (E5-model owns that vocabulary; `fx_keys_are_all_in_the_model_vocabulary`
    /// in `render/tests/fx.rs` pins the containment). A single
    /// `^[A-Za-z0-9_-]+$` segment, so `track.fx.<fxId>.<key>` stays a
    /// 4-segment ParamRef (§16.3) — which is why the EQ keys are FLAT
    /// (`band0Gain`, never `band.0.gain`).
    pub key: &'static str,
    pub default: f32,
    pub min: f32,
    pub max: f32,
    /// Frame = lane-automatable; Block = coefficient, lanes refused (see
    /// [`FxParamRate`]). ⚠️ Keys shared across kinds must agree on the rate in
    /// every kind that declares them — `lane_has_reader` is a pure path
    /// function and classifies by KEY, so a key that were `Frame` on one kind
    /// and `Block` on another would make the path-level gate dishonest.
    /// [`fx_key_class`] resolves a mixed key conservatively (refused), and
    /// `fx_key_rate_is_consistent_across_kinds` pins that none exists, so a
    /// future kind that wants to diverge trips a test instead of shipping a
    /// silent narrowing.
    pub rate: FxParamRate,
}

/// A `Frame`-rate parameter (see [`FxParamRate::Frame`]).
const fn p(key: &'static str, default: f32, min: f32, max: f32) -> FxParamSpec {
    FxParamSpec {
        key,
        default,
        min,
        max,
        rate: FxParamRate::Frame,
    }
}

/// A `Block`-rate COEFFICIENT parameter (see [`FxParamRate::Block`]): applying
/// it runs `coeff_from_ms` (an `exp`) or an RBJ retarget (trig), so automation
/// lanes on it are refused per key.
const fn pb(key: &'static str, default: f32, min: f32, max: f32) -> FxParamSpec {
    FxParamSpec {
        key,
        default,
        min,
        max,
        rate: FxParamRate::Block,
    }
}

/// ALL 12 are `Block`: every one of them feeds `retarget_band_checked`, an
/// RBJ coefficient recompute (sin/cos + `powf`) — the cost cliff by
/// definition, and the same reason `track.eq.*` has no lane reader.
const EQ_PARAMS: [FxParamSpec; 12] = [
    pb("band0Freq", BAND_DEFAULT_HZ[0], 20.0, 20_000.0),
    pb("band0Gain", 0.0, -24.0, 24.0),
    pb("band0Q", BAND_DEFAULT_Q, 0.05, 10.0),
    pb("band1Freq", BAND_DEFAULT_HZ[1], 20.0, 20_000.0),
    pb("band1Gain", 0.0, -24.0, 24.0),
    pb("band1Q", BAND_DEFAULT_Q, 0.05, 10.0),
    pb("band2Freq", BAND_DEFAULT_HZ[2], 20.0, 20_000.0),
    pb("band2Gain", 0.0, -24.0, 24.0),
    pb("band2Q", BAND_DEFAULT_Q, 0.05, 10.0),
    pb("band3Freq", BAND_DEFAULT_HZ[3], 20.0, 20_000.0),
    pb("band3Gain", 0.0, -24.0, 24.0),
    pb("band3Q", BAND_DEFAULT_Q, 0.05, 10.0),
];

/// §17.2. `detector`: 0 = peak, 1 = RMS. `mix`: parallel / NY compression.
///
/// `attack`/`release` are `Block`: they exist only as one-pole COEFFICIENTS
/// (`coeff_from_ms`, an `exp` per application) — the envelope-time-constant
/// class the design names as genuinely expensive. `threshold`/`ratio`/`knee`
/// are used directly in the dB-domain static curve, `mix` is a crossfade
/// weight, `detector` is a mode flag, and `makeup` is a dB gain behind the
/// same change-cached conversion the volume lane uses: all `Frame`.
const COMPRESSOR_PARAMS: [FxParamSpec; 8] = [
    p("threshold", -12.0, -60.0, 0.0),
    p("ratio", 4.0, 1.0, 20.0),
    p("knee", 0.0, 0.0, 24.0),
    pb("attack", 10.0, 0.0, 200.0),
    pb("release", 100.0, 1.0, 2_000.0),
    p("makeup", 0.0, -24.0, 24.0),
    p("mix", 1.0, 0.0, 1.0),
    p("detector", 0.0, 0.0, 1.0),
];

/// §17.2: the same detector, decision inverted, plus `hold` and `range`.
///
/// `attack`/`release` are `Block` — gain one-pole coefficients, same class as
/// the compressor's. `hold` stays `Frame` even though it is a time value: its
/// application is `ms -> frames`, one multiply and a cast, not a coefficient.
const GATE_PARAMS: [FxParamSpec; 6] = [
    p("threshold", -40.0, -96.0, 0.0),
    pb("attack", 1.0, 0.0, 200.0),
    p("hold", 10.0, 0.0, 2_000.0),
    pb("release", 100.0, 1.0, 2_000.0),
    // -96 dB or lower is treated as exactly zero so the release genuinely
    // reaches silence instead of parking on a residual (a truncated release
    // is a click).
    p("range", -96.0, -96.0, 0.0),
    p("detector", 0.0, 0.0, 1.0),
];

const DELAY_PARAMS: [FxParamSpec; 4] = [
    p("time", 375.0, 1.0, 2_000.0),
    p("feedback", 0.35, 0.0, 0.95),
    p("tone", 0.4, 0.0, 0.99),
    p("mix", 0.35, 0.0, 1.0),
];

const REVERB_PARAMS: [FxParamSpec; 3] = [
    p("damping", 0.35, 0.0, 0.99),
    p("size", 0.84, 0.0, 0.98),
    p("mix", 0.3, 0.0, 1.0),
];

/// `release` is `Block` — `coeff_from_ms`, same envelope-coefficient class as
/// the compressor's. `ceiling` is a dB level behind the change-cached
/// conversion: `Frame`.
const LIMITER_PARAMS: [FxParamSpec; 2] = [
    p("ceiling", -1.0, -24.0, 0.0),
    pb("release", 50.0, 1.0, 1_000.0),
];

const SATURATOR_PARAMS: [FxParamSpec; 3] = [
    p("drive", 0.0, -24.0, 36.0),
    p("mix", 1.0, 0.0, 1.0),
    p("gain", 0.0, -24.0, 24.0),
];

const CHORUS_PARAMS: [FxParamSpec; 4] = [
    p("rate", 0.8, 0.01, 20.0),
    p("depth", 3.0, 0.0, 9.0),
    p("mix", 0.5, 0.0, 1.0),
    // LFO phase offset of the right channel, in cycles. 0.25 = quadrature.
    p("spread", 0.25, 0.0, 1.0),
];

const UTILITY_PARAMS: [FxParamSpec; 4] = [
    p("gain", 0.0, -96.0, 24.0),
    p("pan", 0.0, -1.0, 1.0),
    p("width", 1.0, 0.0, 2.0),
    p("polarity", 0.0, 0.0, 1.0),
];

/// Render-side effect kinds. Mirrors `timeline_core::FxKind` (§16.1) one for
/// one, including the lowercase wire spelling; `compile.rs` maps the model
/// enum onto this one. Declared here rather than imported because
/// `timeline-core`'s `FxKind` is E5-model's to land and E5-fx must not touch
/// that crate — the mapping is a two-line `match` in `compile.rs`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FxKindId {
    Eq,
    Compressor,
    Gate,
    Delay,
    Reverb,
    Saturator,
    Chorus,
    Utility,
    Limiter,
}

/// Every kind, in `FxKind` declaration order. Test and registry convenience.
pub const ALL_FX_KINDS: [FxKindId; 9] = [
    FxKindId::Eq,
    FxKindId::Compressor,
    FxKindId::Gate,
    FxKindId::Delay,
    FxKindId::Reverb,
    FxKindId::Saturator,
    FxKindId::Chorus,
    FxKindId::Utility,
    FxKindId::Limiter,
];

impl FxKindId {
    /// The lowercase serde spelling of `timeline_core::FxKind` (§16.1).
    pub fn wire_name(self) -> &'static str {
        match self {
            FxKindId::Eq => "eq",
            FxKindId::Compressor => "compressor",
            FxKindId::Gate => "gate",
            FxKindId::Delay => "delay",
            FxKindId::Reverb => "reverb",
            FxKindId::Saturator => "saturator",
            FxKindId::Chorus => "chorus",
            FxKindId::Utility => "utility",
            FxKindId::Limiter => "limiter",
        }
    }

    /// Parameter block for this kind. Index in the slice IS the offset from
    /// the fx's `base_slot`. Slot 0 is always `bypass`.
    pub fn params(self) -> &'static [FxParamSpec] {
        match self {
            FxKindId::Eq => &EQ_PARAMS,
            FxKindId::Compressor => &COMPRESSOR_PARAMS,
            FxKindId::Gate => &GATE_PARAMS,
            FxKindId::Delay => &DELAY_PARAMS,
            FxKindId::Reverb => &REVERB_PARAMS,
            FxKindId::Saturator => &SATURATOR_PARAMS,
            FxKindId::Chorus => &CHORUS_PARAMS,
            FxKindId::Utility => &UTILITY_PARAMS,
            FxKindId::Limiter => &LIMITER_PARAMS,
        }
    }

    /// Number of parameter slots this kind occupies.
    pub fn param_count(self) -> usize {
        self.params().len()
    }

    pub fn param_index(self, key: &str) -> Option<usize> {
        self.params().iter().position(|s| s.key == key)
    }

    /// Latency this kind will report, known before construction so `compile.rs`
    /// can run the §19.2 PDC pass without instantiating anything.
    pub fn latency_frames(self) -> u32 {
        match self {
            FxKindId::Limiter => LOOKAHEAD_FRAMES as u32,
            _ => 0,
        }
    }
}

/// Every parameter key any kind honours, de-duplicated and sorted.
/// This is the render-side source for `timeline-core`'s `FX_PARAM_KEYS`
/// (§16.3) — E5-model should generate that const from this list rather than
/// hand-maintaining a second copy that can drift.
pub fn all_fx_param_keys() -> Vec<&'static str> {
    let mut keys: Vec<&'static str> = ALL_FX_KINDS
        .iter()
        .flat_map(|k| k.params().iter().map(|s| s.key))
        .collect();
    // `bypass` has no slot but IS a wire key (§16.6).
    keys.push(BYPASS_KEY);
    keys.sort_unstable();
    keys.dedup();
    keys
}

/// What an automation lane on an fx parameter KEY may do, resolved across
/// every kind that declares the key.
///
/// This exists because `rt::lane_has_reader` is a pure PATH function: it sees
/// `track.fx.<fxId>.<key>` and cannot see which `FxKind` the id resolves to.
/// So the path-level gate classifies by key, and it can do that honestly only
/// because the rate of a shared key is consistent across kinds — pinned by
/// `fx_key_rate_is_consistent_across_kinds`. Where the kind IS known
/// (`compile::bake_fx_lanes`), the per-(kind, index) spec is checked again, so
/// even a drifted table cannot hand a lane to a `Block` slot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FxKeyClass {
    /// Every kind declaring the key applies it per frame with arithmetic or a
    /// change-cached conversion: a lane on it HAS a reader.
    Frame,
    /// At least one kind declaring the key applies it by recomputing a filter
    /// or envelope coefficient: REFUSED per key. (A key that is `Frame` on one
    /// kind and `Block` on another lands here too — conservative, and the
    /// consistency test makes such a key a loud design decision, not a drift.)
    Coefficient,
    /// `bypass`: a wire key with NO parameter slot (§23.5), read once per
    /// block through `EngineParams::fx_bypassed` and declicked by the unit's
    /// own crossfade. A lane would be a third spelling of one fact.
    Bypass,
    /// No kind implements the key (`division` is reserved vocabulary — tempo
    /// division resolves control-side), or it is not fx vocabulary at all.
    /// Nothing exists for a lane to drive.
    Unimplemented,
}

/// Classify one wire key across [`ALL_FX_KINDS`] — the ONE implementation of
/// the fx-lane readable/refused split. `rt::lane_has_reader` and
/// `rt::lane_gap_reason` call it for the path-level gate; `compile` re-checks
/// the resolved (kind, index) spec where the kind is known. Derived from the
/// same `FxParamSpec` tables `load_block_targets` reads, so the reader set and
/// the refusal set cannot drift apart without a test noticing.
pub fn fx_key_class(key: &str) -> FxKeyClass {
    if key == BYPASS_KEY {
        return FxKeyClass::Bypass;
    }
    let mut declared = false;
    for k in ALL_FX_KINDS {
        if let Some(i) = k.param_index(key) {
            declared = true;
            if k.params()[i].rate == FxParamRate::Block {
                return FxKeyClass::Coefficient;
            }
        }
    }
    if declared {
        FxKeyClass::Frame
    } else {
        FxKeyClass::Unimplemented
    }
}

/// Read one parameter slot, clamped to its declared range. Every kind reads
/// through this, so an unseeded or hostile slab can never produce a NaN, a
/// division by zero or an out-of-range coefficient on the audio thread.
///
/// The clamp is load-bearing: `EngineParams::set_fx_param` is deliberately
/// UNCLAMPED (`params.rs`: *"the range of a key is the effect kind's
/// business"*) and an unseeded slot reads `FX_PARAM_CLEARED` = 0.0, which for a
/// compressor is `ratio = 0`.
///
/// The **NaN branch, by contrast, is unreachable through `set_fx_param`**,
/// which drops non-finite writes (§23.4). It is defence in depth for any future
/// writer, and it is therefore **not covered by a mutation test** — removing it
/// alone leaves the suite green. Stated here rather than implied, because an
/// uncovered branch that looks covered is worse than an uncovered one that says
/// so. `fx_param_bank_contract` below pins the upstream behaviour this relies
/// on, so a regression there is visible.
#[inline]
pub fn read_param(p: &EngineParams, base_slot: usize, kind: FxKindId, index: usize) -> f32 {
    let spec = &kind.params()[index];
    let v = p.fx_param_target(base_slot + index);
    if v.is_nan() {
        spec.default
    } else {
        v.clamp(spec.min, spec.max)
    }
}

/// One-pole convergence toward `target` that ARRIVES EXACTLY.
///
/// `coeff` is `exp(-1 / (tau_seconds * sample_rate))`.
///
/// Two things stop a textbook one-pole from ever arriving, and both are real
/// defects rather than pedantry:
///
/// 1. **It decays asymptotically**, so an idle compressor's envelope sits a
///    hair off its target forever and its state fills with denormals — the CPU
///    trap `dsp/mod.rs:26-37` documents. Flushing the *residual* fixes that:
///    the state reaches exactly zero on silence.
///
/// 2. **f32 rounding produces a FIXED POINT well short of the target.**
///    `fl(target + r)` quantises `r` to ULPs of `target`, so once
///    `|r| < 0.5 / (1 - coeff)` ULPs the next iterate rounds back to the
///    current one and the envelope stalls. This is not theoretical: measured
///    here, a `target = 1.0` with a 1 ms coefficient stalls **24 ULPs short**
///    (`0.99999857`), and a 2 s release stalls **0.29 % short** — a −51 dB
///    residual that never decays. A gate would then never actually close and
///    a compressor would never actually report unity gain. When the one-pole
///    can no longer make progress, this steps one ULP toward the target
///    instead, which is monotone, click-free and guaranteed to terminate.
///
/// Together these are §17.2's two requirements — *"gain reduction must reach
/// and hold exactly 1.0"* and *"the smoothed envelope must flush denormals"* —
/// plus the reason a gate release genuinely reaches silence rather than
/// truncating (a truncated release is a click).
#[inline(always)]
pub fn converge_exact(now: f32, target: f32, coeff: f32) -> f32 {
    let d = now - target;
    if d == 0.0 {
        return target;
    }
    let next = target + flush_denormal(d * coeff);
    if next != now {
        return next;
    }
    // Rounding fixed point: force one ULP of progress toward `target`.
    // Same sign by construction here (the stall only happens when |d| is tiny
    // relative to `target`), so a magnitude step is a value step.
    let bits = now.to_bits();
    let stepped = if (now > target) == (now > 0.0) {
        f32::from_bits(bits.wrapping_sub(1))
    } else {
        f32::from_bits(bits.wrapping_add(1))
    };
    // Never overshoot: if the ULP step crosses the target, land on it.
    if (stepped - target) * d > 0.0 {
        stepped
    } else {
        target
    }
}

/// Per-frame one-pole coefficient for a time constant in milliseconds.
/// The exact form `EngineParams::limiter_release_coeff` already uses
/// (`params.rs:306-309`). `ms <= 0` gives 0.0 — an instant follower.
#[inline]
pub fn coeff_from_ms(ms: f32, sample_rate: u32) -> f32 {
    let t = ms * 0.001 * sample_rate.max(1) as f32;
    if t <= 0.0 {
        0.0
    } else {
        (-1.0 / t).exp()
    }
}

/// dB to linear, with anything at or below -96 dB collapsing to EXACTLY zero
/// so "full attenuation" really is silence.
#[inline]
pub fn db_to_lin_floor(db: f32) -> f32 {
    if db <= -96.0 {
        0.0
    } else {
        db_to_lin(db)
    }
}

/// Dry/wet crossfade with EXACT endpoints.
///
/// The endpoints are branched rather than interpolated because
/// `dry + (wet - dry) * 1.0` is not bit-identically `wet` in f32. Exactness at
/// the endpoints is what lets `mix = 1` be a true measurement of the wet path
/// and `mix = 0` a true bypass.
#[inline(always)]
pub fn mix_frames(dry: [f32; 2], wet: [f32; 2], m: f32) -> [f32; 2] {
    if m == 1.0 {
        wet
    } else if m == 0.0 {
        dry
    } else {
        [
            dry[0] + (wet[0] - dry[0]) * m,
            dry[1] + (wet[1] - dry[1]) * m,
        ]
    }
}

// ---------------------------------------------------------------------------
// FxUnit — bypass wrapper + static dispatch over the nine kinds
// ---------------------------------------------------------------------------

enum Inner {
    Eq(EqFx),
    Compressor(CompressorFx),
    Gate(GateFx),
    Delay(DelayFx),
    Reverb(ReverbFx),
    Saturator(SaturatorFx),
    Chorus(ChorusFx),
    Utility(UtilityFx),
    // Boxed: `Limiter` carries ~3 KB of inline lookahead ring, and an fx slab
    // sized to MAX_FX_TOTAL would otherwise pay that for every slot.
    Limiter(Box<LimiterFx>),
}

/// One effect slot: a kind plus the universal bypass crossfade.
///
/// **Bypass semantics.** The wet path is processed on every frame *even while
/// bypassed*, so filter/ring state stays warm and un-bypassing is click-free
/// rather than starting from cold. Only the output mix branches. A fully
/// settled bypass returns the input **bit-identically** (§20.2 proof 3) —
/// `Slew` arrives exactly on target, so the branch is exact, not
/// "within epsilon". The transition ramps over the unit's declick window
/// (`MICRO_FADE_FRAMES` when `rt.rs` constructs it) instead of stepping.
pub struct FxUnit {
    kind: FxKindId,
    inner: Inner,
    /// 1.0 = fully bypassed. Ramped, never stepped.
    bypass: Slew,
    bypass_target: f32,
}

impl FxUnit {
    /// `ramp_frames` is the declick window; `rt.rs` passes `MICRO_FADE_FRAMES`
    /// (5 ms / 240 frames at 48 k). Allocates (rings, tables) — control-side
    /// only, exactly like `EqBank::new` / `DelayBus::new`.
    pub fn new(kind: FxKindId, sample_rate: u32, ramp_frames: u32) -> Self {
        let inner = match kind {
            FxKindId::Eq => Inner::Eq(EqFx::new(sample_rate, ramp_frames)),
            FxKindId::Compressor => {
                Inner::Compressor(CompressorFx::new(sample_rate, ramp_frames))
            }
            FxKindId::Gate => Inner::Gate(GateFx::new(sample_rate, ramp_frames)),
            FxKindId::Delay => Inner::Delay(DelayFx::new(sample_rate, ramp_frames)),
            FxKindId::Reverb => Inner::Reverb(ReverbFx::new(sample_rate, ramp_frames)),
            FxKindId::Saturator => Inner::Saturator(SaturatorFx::new(sample_rate, ramp_frames)),
            FxKindId::Chorus => Inner::Chorus(ChorusFx::new(sample_rate, ramp_frames)),
            FxKindId::Utility => Inner::Utility(UtilityFx::new(sample_rate, ramp_frames)),
            FxKindId::Limiter => Inner::Limiter(Box::new(LimiterFx::new(sample_rate))),
        };
        Self {
            kind,
            inner,
            bypass: Slew::new(0.0, 1.0 / ramp_frames.max(1) as f32),
            bypass_target: 0.0,
        }
    }

    pub fn kind(&self) -> FxKindId {
        self.kind
    }

    /// Number of parameter slots this unit occupies from its `base_slot`.
    pub fn param_count(&self) -> usize {
        self.kind.param_count()
    }

    /// Snap the bypass crossfade to its target (session install, not
    /// mid-signal) — the `Slew::snap` convention.
    pub fn snap_bypass(&mut self) {
        self.bypass.snap(self.bypass_target);
    }

    #[inline]
    fn node(&mut self) -> &mut dyn FxNode {
        match &mut self.inner {
            Inner::Eq(v) => v,
            Inner::Compressor(v) => v,
            Inner::Gate(v) => v,
            Inner::Delay(v) => v,
            Inner::Reverb(v) => v,
            Inner::Saturator(v) => v,
            Inner::Chorus(v) => v,
            Inner::Utility(v) => v,
            Inner::Limiter(v) => v.as_mut(),
        }
    }
}

impl FxNode for FxUnit {
    #[inline]
    fn process_frame(&mut self, x: [f32; 2], key: [f32; 2]) -> [f32; 2] {
        let target = self.bypass_target;
        let b = self.bypass.advance(target);
        // Always advance the wet path so state stays warm; only the mix
        // branches. `Slew` arrives exactly, so b == 0.0 / 1.0 are exact.
        let wet = self.node().process_frame(x, key);
        if b == 0.0 {
            wet
        } else if b == 1.0 {
            x
        } else {
            let w = 1.0 - b;
            [x[0] * b + wet[0] * w, x[1] * b + wet[1] * w]
        }
    }

    fn load_block_targets(&mut self, p: &EngineParams, base_slot: usize) {
        debug_assert_eq!(
            base_slot % MAX_FX_PARAMS_PER_FX,
            0,
            "base_slot must be fx_slot * MAX_FX_PARAMS_PER_FX (§23.4)"
        );
        // §23.4: bypass is a per-instance flag, not a parameter slot.
        self.bypass_target = if p.fx_bypassed(fx_slot_of(base_slot)) {
            1.0
        } else {
            0.0
        };
        self.node().load_block_targets(p, base_slot);
    }

    /// The ONE clamp point for lane values: spec range + NaN→default, exactly
    /// the guarantee `read_param` gives the block path, applied here because
    /// this is where the kind is known. Inner nodes receive a finite, in-range
    /// value (documented on the trait). Upstream already drops non-finite
    /// atomic writes (§23.4); this is the defensive re-assertion the lane path
    /// owes, since lane points come from the model, not from `set_fx_param`.
    #[inline]
    fn set_frame_param(&mut self, index: usize, value: f32) {
        let Some(spec) = self.kind.params().get(index) else {
            debug_assert!(false, "{:?} has no param index {index}", self.kind);
            return;
        };
        debug_assert_eq!(
            spec.rate,
            FxParamRate::Frame,
            "{:?} '{}' is Block-rate; compile must refuse its lane, never route it here",
            self.kind,
            spec.key
        );
        let v = if value.is_nan() {
            spec.default
        } else {
            value.clamp(spec.min, spec.max)
        };
        self.node().set_frame_param(index, v);
    }

    fn latency_frames(&self) -> u32 {
        // Constant for the life of the node, and independent of bypass.
        self.kind.latency_frames()
    }

    fn take_block_meter(&mut self) -> f32 {
        self.node().take_block_meter()
    }

    fn reset(&mut self) {
        self.node().reset();
        self.bypass.snap(self.bypass_target);
    }
}

// ---------------------------------------------------------------------------
// The four REUSE wrappers (§17.1). None of these reimplements its primitive.
// ---------------------------------------------------------------------------

/// `FxKind::Eq` — a straight wrap of the existing 4-band `EqBank`
/// (`dsp/biquad.rs`), which is already per-frame, already declicked, and
/// already has a bit-exact flat bypass.
pub struct EqFx {
    bank: EqBank,
    sample_rate: u32,
    bands: [(f32, f32, f32); EQ_BANDS],
}

impl EqFx {
    pub fn new(sample_rate: u32, ramp_frames: u32) -> Self {
        Self {
            bank: EqBank::new(sample_rate, ramp_frames),
            sample_rate,
            bands: std::array::from_fn(|i| (BAND_DEFAULT_HZ[i], 0.0, BAND_DEFAULT_Q)),
        }
    }
}

impl FxNode for EqFx {
    #[inline]
    fn process_frame(&mut self, x: [f32; 2], _key: [f32; 2]) -> [f32; 2] {
        let mut frame = x;
        self.bank.process_frame(&mut frame);
        frame
    }

    fn load_block_targets(&mut self, p: &EngineParams, base_slot: usize) {
        for b in 0..EQ_BANDS {
            let i = b * 3;
            let freq = read_param(p, base_slot, FxKindId::Eq, i);
            let gain = read_param(p, base_slot, FxKindId::Eq, i + 1);
            let q = read_param(p, base_slot, FxKindId::Eq, i + 2);
            self.bands[b] = (freq, gain, q);
            self.bank
                .retarget_band_checked(b, self.sample_rate, freq, gain, q);
        }
        self.bank.block_maintenance();
    }

    fn set_frame_param(&mut self, index: usize, _value: f32) {
        // Every Eq key is an RBJ COEFFICIENT (`Block`), refused as a lane
        // target by compile — the same cliff that keeps `track.eq.*` refused —
        // so this is unreachable. No-op rather than panic: audio thread.
        debug_assert!(false, "Eq has no Frame-rate params (index {index})");
    }

    fn reset(&mut self) {
        self.bank = EqBank::new(self.sample_rate, 1);
    }
}

/// `FxKind::Delay` — wraps `DelayBus` (`dsp/delay.rs`), which is 100 % wet by
/// send-bus discipline, and adds the dry/wet an insert needs.
pub struct DelayFx {
    bus: DelayBus,
    sample_rate: u32,
    tap_frames: u32,
    feedback: f32,
    tone: f32,
    mix: Slew,
    mix_target: f32,
    ramp_frames: u32,
}

impl DelayFx {
    pub fn new(sample_rate: u32, ramp_frames: u32) -> Self {
        let default_ms = DELAY_PARAMS[0].default;
        let tap = (default_ms * 0.001 * sample_rate as f32) as u32;
        Self {
            bus: DelayBus::new(sample_rate, tap.max(1), ramp_frames),
            sample_rate,
            tap_frames: tap.max(1),
            feedback: DELAY_PARAMS[1].default,
            tone: DELAY_PARAMS[2].default,
            mix: Slew::new(DELAY_PARAMS[3].default, 1.0 / ramp_frames.max(1) as f32),
            mix_target: DELAY_PARAMS[3].default,
            ramp_frames,
        }
    }
}

impl FxNode for DelayFx {
    #[inline]
    fn process_frame(&mut self, x: [f32; 2], _key: [f32; 2]) -> [f32; 2] {
        let wet = self
            .bus
            .process_frame(x, self.tap_frames, self.feedback, self.tone);
        mix_frames(x, wet, self.mix.advance(self.mix_target))
    }

    fn load_block_targets(&mut self, p: &EngineParams, base_slot: usize) {
        let k = FxKindId::Delay;
        let ms = read_param(p, base_slot, k, 0);
        self.tap_frames = ((ms * 0.001 * self.sample_rate as f32) as u32).max(1);
        self.feedback = read_param(p, base_slot, k, 1);
        self.tone = read_param(p, base_slot, k, 2);
        self.mix_target = read_param(p, base_slot, k, 3);
    }

    fn set_frame_param(&mut self, index: usize, value: f32) {
        match index {
            // `time` is an integer tap: ms -> frames is one multiply + cast,
            // and `DelayBus` itself crossfades any tap change over the declick
            // window (its documented contract), so a lane ramp declicks inside
            // the primitive rather than pitch-chirping.
            0 => self.tap_frames = ((value * 0.001 * self.sample_rate as f32) as u32).max(1),
            1 => self.feedback = value,
            2 => self.tone = value,
            3 => self.mix_target = value,
            _ => debug_assert!(false, "Delay has no Frame param index {index}"),
        }
    }

    fn reset(&mut self) {
        self.bus = DelayBus::new(self.sample_rate, self.tap_frames, self.ramp_frames);
        self.mix.snap(self.mix_target);
    }
}

/// `FxKind::Reverb` — wraps the existing Freeverb `ReverbBus`
/// (`dsp/reverb.rs`). NOTE (§16.7): this is a *new* insert effect; it does not
/// replace `NodeStepKind::LegacyFx(A)`, whose hardcoded instance must stay
/// exactly as it is or every existing project's render changes.
pub struct ReverbFx {
    bus: ReverbBus,
    sample_rate: u32,
    damping: f32,
    decay: f32,
    mix: Slew,
    mix_target: f32,
    ramp_frames: u32,
}

impl ReverbFx {
    pub fn new(sample_rate: u32, ramp_frames: u32) -> Self {
        Self {
            bus: ReverbBus::new(sample_rate, ramp_frames),
            sample_rate,
            damping: REVERB_PARAMS[0].default,
            decay: REVERB_PARAMS[1].default,
            mix: Slew::new(REVERB_PARAMS[2].default, 1.0 / ramp_frames.max(1) as f32),
            mix_target: REVERB_PARAMS[2].default,
            ramp_frames,
        }
    }
}

impl FxNode for ReverbFx {
    #[inline]
    fn process_frame(&mut self, x: [f32; 2], _key: [f32; 2]) -> [f32; 2] {
        let wet = self.bus.process_frame(x, self.damping, self.decay);
        mix_frames(x, wet, self.mix.advance(self.mix_target))
    }

    fn load_block_targets(&mut self, p: &EngineParams, base_slot: usize) {
        let k = FxKindId::Reverb;
        self.damping = read_param(p, base_slot, k, 0);
        self.decay = read_param(p, base_slot, k, 1);
        self.mix_target = read_param(p, base_slot, k, 2);
    }

    fn set_frame_param(&mut self, index: usize, value: f32) {
        match index {
            // `damping`/`size` are comb-filter WEIGHTS the bus already takes
            // as per-frame arguments — plain multiplies, no coefficient
            // derivation. A lane just supplies them per frame instead of once
            // per block.
            0 => self.damping = value,
            1 => self.decay = value,
            2 => self.mix_target = value,
            _ => debug_assert!(false, "Reverb has no Frame param index {index}"),
        }
    }

    fn reset(&mut self) {
        self.bus = ReverbBus::new(self.sample_rate, self.ramp_frames);
        self.mix.snap(self.mix_target);
    }
}

/// `FxKind::Limiter` — wraps the existing true-peak `Limiter`
/// (`dsp/limiter.rs`). **This is the one kind with latency** (96 frames), and
/// §19.1 says so explicitly: it is the reason E5 implements PDC rather than
/// keeping §9.2's fail-closed hook. `latency_frames()` must never be shaded to
/// zero to dodge the compensation pass.
pub struct LimiterFx {
    limiter: Limiter,
    sample_rate: u32,
    ceiling_lin: f32,
    /// Lane fast path for `ceiling`: (last dB seen, its linear value), so the
    /// `powf` runs only when the lane value actually moves — the
    /// `Strip::vol_lane_lin` cache, verbatim.
    ceiling_db_cache: f32,
    ceiling_lin_cache: f32,
    release_coeff: f32,
    meter: f32,
}

impl LimiterFx {
    pub fn new(sample_rate: u32) -> Self {
        let ceiling_db = LIMITER_PARAMS[0].default;
        let ceiling_lin = db_to_lin(ceiling_db);
        Self {
            limiter: Limiter::new(),
            sample_rate,
            ceiling_lin,
            ceiling_db_cache: ceiling_db,
            ceiling_lin_cache: ceiling_lin,
            release_coeff: coeff_from_ms(LIMITER_PARAMS[1].default, sample_rate),
            meter: 1.0,
        }
    }
}

impl FxNode for LimiterFx {
    #[inline]
    fn process_frame(&mut self, x: [f32; 2], _key: [f32; 2]) -> [f32; 2] {
        self.limiter
            .process_frame(x, self.ceiling_lin, self.release_coeff)
    }

    fn load_block_targets(&mut self, p: &EngineParams, base_slot: usize) {
        let k = FxKindId::Limiter;
        self.ceiling_lin = db_to_lin(read_param(p, base_slot, k, 0));
        self.release_coeff = coeff_from_ms(read_param(p, base_slot, k, 1), self.sample_rate);
        // Block-flushed telemetry, never a per-frame atomic write (§8).
        let (min_gain, _, _) = self.limiter.take_telemetry();
        self.meter = min_gain;
    }

    fn set_frame_param(&mut self, index: usize, value: f32) {
        match index {
            // Cache pair + UNCONDITIONAL write: the compare decides whether to
            // reconvert, never whether to apply — skipping the apply would
            // leave the block loader's atomic-derived value standing, i.e. the
            // stale-atomic leak the lane-overrides-atomic convention forbids.
            0 => {
                if value != self.ceiling_db_cache {
                    self.ceiling_db_cache = value;
                    self.ceiling_lin_cache = db_to_lin(value);
                }
                self.ceiling_lin = self.ceiling_lin_cache;
            }
            // Index 1 (`release`) is a Block-rate envelope coefficient;
            // compile refuses its lane, so it can never arrive here.
            _ => debug_assert!(false, "Limiter has no Frame param index {index}"),
        }
    }

    fn latency_frames(&self) -> u32 {
        LOOKAHEAD_FRAMES as u32
    }

    fn take_block_meter(&mut self) -> f32 {
        let m = self.meter;
        self.meter = 1.0;
        m
    }

    fn reset(&mut self) {
        self.limiter.reset();
        self.meter = 1.0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// §23.4 + the module header: `bypass` is a wire key with NO slot. A kind
    /// that declared it as a parameter would have two spellings of one fact,
    /// and the slot would be inert because `load_block_targets` reads
    /// `fx_bypassed` instead.
    #[test]
    fn bypass_occupies_no_parameter_slot() {
        for k in ALL_FX_KINDS {
            assert_eq!(k.param_index(BYPASS_KEY), None, "{k:?} declares a bypass slot");
        }
        assert!(all_fx_param_keys().contains(&BYPASS_KEY), "bypass must stay a wire key");
    }

    /// §23.4's hard cap, per kind rather than only on the widest.
    #[test]
    fn no_kind_exceeds_the_param_stride() {
        for k in ALL_FX_KINDS {
            assert!(
                k.param_count() <= MAX_FX_PARAMS_PER_FX,
                "{k:?} declares {} params, cap is {MAX_FX_PARAMS_PER_FX}",
                k.param_count()
            );
        }
        assert_eq!(FxKindId::Eq.param_count(), 12, "Eq is the widest kind");
    }

    #[test]
    fn slot_arithmetic_round_trips() {
        for fx_slot in [0_usize, 1, 7, 255] {
            assert_eq!(fx_slot_of(base_slot_of(fx_slot)), fx_slot);
        }
        assert_eq!(base_slot_of(1), MAX_FX_PARAMS_PER_FX);
    }

    #[test]
    fn param_keys_are_single_wire_segments() {
        for k in ALL_FX_KINDS {
            for s in k.params() {
                assert!(
                    !s.key.is_empty()
                        && s.key
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-'),
                    "{k:?} key {:?} is not a single ParamRef segment",
                    s.key
                );
                assert!(s.min <= s.default && s.default <= s.max, "{k:?} {}", s.key);
            }
        }
    }

    #[test]
    fn param_keys_are_unique_within_a_kind() {
        for k in ALL_FX_KINDS {
            let mut seen: Vec<&str> = k.params().iter().map(|s| s.key).collect();
            let n = seen.len();
            seen.sort_unstable();
            seen.dedup();
            assert_eq!(seen.len(), n, "{k:?} has duplicate param keys");
        }
    }

    #[test]
    fn only_the_limiter_reports_latency() {
        for k in ALL_FX_KINDS {
            let want = if k == FxKindId::Limiter { 96 } else { 0 };
            assert_eq!(k.latency_frames(), want, "{k:?}");
            let unit = FxUnit::new(k, 48_000, 240);
            assert_eq!(unit.latency_frames(), want, "{k:?} constructed");
        }
    }

    #[test]
    fn max_fx_params_bounds_every_kind() {
        for k in ALL_FX_KINDS {
            assert!(k.param_count() <= MAX_FX_PARAMS, "{k:?}");
        }
    }

    #[test]
    fn converge_arrives_exactly_and_flushes_to_zero() {
        // Toward zero: must reach EXACTLY 0.0, not a denormal residue.
        let mut v = 1.0_f32;
        let c = coeff_from_ms(1.0, 48_000);
        for _ in 0..48_000 {
            v = converge_exact(v, 0.0, c);
        }
        assert_eq!(v, 0.0, "release must reach exactly zero");

        // Toward one: must reach EXACTLY 1.0 so an idle compressor's gain
        // reduction is exactly "no reduction". A plain one-pole stalls 24 ULPs
        // short here (0.99999857) — measured before the ULP-progress fix.
        let mut v = 0.0_f32;
        for _ in 0..48_000 {
            v = converge_exact(v, 1.0, c);
        }
        assert_eq!(v, 1.0);
    }

    /// The rounding fixed point across the whole range of time constants the
    /// suite exposes, from the fastest coefficient to the slowest. The slow
    /// end is the one that matters: a 2 s release stalls 0.29 % short.
    ///
    /// Honest bound on the `-> 0.0` direction: there is no rounding fixed
    /// point toward zero (relative precision is scale-free), so arrival there
    /// is governed by the 1e-20 `flush_denormal` floor and takes ~94 s of
    /// signal at a 2 s release — hence the large frame budget. That floor sits
    /// eighteen orders of magnitude above f32's denormal range, so the CPU
    /// trap this is really about is closed long before the value is exact.
    #[test]
    fn converge_arrives_at_every_time_constant_and_from_both_sides() {
        for ms in [0.0_f32, 1.0, 10.0, 100.0, 500.0, 2_000.0] {
            let c = coeff_from_ms(ms, 48_000);
            for &(start, target) in &[
                (0.0_f32, 1.0_f32),
                (1.0, 0.25118864),
                (0.25118864, 1.0),
                (-1.0, -0.5),
                (0.5, 0.0),
            ] {
                let mut v = start;
                let mut settled = None;
                for i in 0..6_000_000 {
                    v = converge_exact(v, target, c);
                    if v == target {
                        settled = Some(i);
                        break;
                    }
                }
                assert!(
                    settled.is_some(),
                    "ms={ms} {start} -> {target} stalled at {v} (delta {})",
                    v - target
                );
            }
        }
    }

    #[test]
    fn converge_never_overshoots() {
        for c in [0.0_f32, 0.5, 0.9999] {
            let mut v = 0.0_f32;
            for _ in 0..10_000 {
                v = converge_exact(v, 1.0, c);
                assert!((0.0..=1.0).contains(&v), "overshot to {v}");
            }
            let mut v = 1.0_f32;
            for _ in 0..10_000 {
                v = converge_exact(v, -1.0, c);
                assert!((-1.0..=1.0).contains(&v), "overshot to {v}");
            }
        }
    }

    /// `mix_frames`'s endpoints are EXACT, and the branch that makes them so
    /// is load-bearing rather than decorative.
    ///
    /// `dry + (wet - dry) * 1.0` is not bit-identically `wet` whenever `wet`
    /// is far below `dry` in magnitude: the subtraction rounds `wet` away
    /// entirely and the sum lands on 0.0. For a 100 %-wet reverb or delay that
    /// silently truncates the quiet end of a tail. (Discovered because the
    /// rendered tests could not tell the two forms apart — the difference is
    /// real but sits below -150 dBFS in every musical case, so it is proven
    /// here, at the contract, rather than through a contrived render.)
    #[test]
    fn mix_frames_endpoints_are_exact() {
        let dry = [1.0_f32, 1.0];
        let wet = [1.0e-8_f32, 1.0e-8];
        assert_eq!(mix_frames(dry, wet, 1.0), wet, "mix=1 must be exactly wet");
        assert_eq!(mix_frames(dry, wet, 0.0), dry, "mix=0 must be exactly dry");

        // The naive form really does destroy it — pinned so the comment above
        // cannot rot into a claim nobody checks.
        let naive = dry[0] + (wet[0] - dry[0]) * 1.0;
        assert_eq!(naive, 0.0, "the naive lerp is expected to collapse to zero");
        assert_ne!(naive, wet[0]);

        // Signed zero survives the dry endpoint.
        let neg_zero = [-0.0_f32, -0.0];
        assert!(mix_frames(neg_zero, [1.0, 1.0], 0.0)[0].is_sign_negative());
    }

    #[test]
    fn db_to_lin_floor_collapses_to_exact_silence() {
        assert_eq!(db_to_lin_floor(-96.0), 0.0);
        assert_eq!(db_to_lin_floor(-120.0), 0.0);
        assert_eq!(db_to_lin_floor(0.0), 1.0);
    }

    /// `set_fx_param` is deliberately UNCLAMPED (`params.rs`: "the range of a
    /// key is the effect kind's business"), and a slot that was never seeded
    /// reads `FX_PARAM_CLEARED` = 0.0. So the DSP-side clamp in `read_param` is
    /// the only thing standing between an unseeded slab and `ratio = 0`.
    #[test]
    fn read_param_clamps_an_unseeded_slab() {
        let p = EngineParams::new(1);
        assert_eq!(read_param(&p, 0, FxKindId::Compressor, 1), 1.0, "ratio floors at 1:1");
        // And an out-of-range write is clamped on the way out, not on the way in.
        p.set_fx_param(1, 1.0e9);
        assert_eq!(read_param(&p, 0, FxKindId::Compressor, 1), 20.0);
        p.set_fx_param(1, -5.0);
        assert_eq!(read_param(&p, 0, FxKindId::Compressor, 1), 1.0);
    }

    /// The contract E5-fx depends on and does not own: `set_fx_param` DROPS a
    /// non-finite write rather than clamping it (§23.4 — `f32::NAN.clamp()` is
    /// NaN). If E5-params ever changed this to a clamp, `read_param`'s NaN
    /// branch is what would keep the audio thread safe; this test is how we
    /// would find out that the branch had become load-bearing.
    #[test]
    fn fx_param_bank_contract() {
        let p = EngineParams::new(1);
        p.set_fx_param(0, 4.0);
        for bad in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
            p.set_fx_param(0, bad);
            assert_eq!(
                p.fx_param_target(0),
                4.0,
                "a {bad} write must be DROPPED, leaving the previous value"
            );
        }
    }

    /// `set_fx_param` drops non-finite writes (§23.4), and `read_param` is the
    /// second line of defence: whatever it returns is finite and in range, so a
    /// NaN can never reach a coefficient.
    #[test]
    fn read_param_never_returns_a_non_finite_value() {
        let p = EngineParams::new(1);
        for k in ALL_FX_KINDS {
            let base = base_slot_of(0);
            for bad in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY, 1.0e30, -1.0e30] {
                for i in 0..k.param_count() {
                    p.set_fx_param(base + i, bad);
                    let v = read_param(&p, base, k, i);
                    let spec = &k.params()[i];
                    assert!(v.is_finite(), "{k:?} {} -> {v} from {bad}", spec.key);
                    assert!(
                        (spec.min..=spec.max).contains(&v),
                        "{k:?} {} -> {v} outside [{}, {}]",
                        spec.key,
                        spec.min,
                        spec.max
                    );
                }
            }
        }
    }

    /// ⚠️ THE assumption `rt::lane_has_reader`'s per-key gate stands on: a
    /// wire key shared by several kinds carries ONE rate. The path-level gate
    /// classifies by key (it cannot see the kind), so a key that were `Frame`
    /// on one kind and `Block` on another would be refused wholesale by
    /// `fx_key_class`'s conservative fold — silently narrowing the readable
    /// set for the kind whose application IS cheap. A future kind that wants
    /// to diverge must trip THIS test and force the design conversation, not
    /// ship the narrowing.
    #[test]
    fn fx_key_rate_is_consistent_across_kinds() {
        use std::collections::BTreeMap;
        let mut rates: BTreeMap<&str, FxParamRate> = BTreeMap::new();
        for k in ALL_FX_KINDS {
            for s in k.params() {
                if let Some(prev) = rates.insert(s.key, s.rate) {
                    assert_eq!(
                        prev, s.rate,
                        "key '{}' declares different rates across kinds ({k:?} says \
                         {:?}); the path-level lane gate classifies by KEY and cannot \
                         be honest about a mixed key",
                        s.key, s.rate
                    );
                }
            }
        }
    }

    /// The readable/refused split, pinned key by key so a table edit is a
    /// visible diff here, not a silent flip of `lane_has_reader`.
    ///
    /// The split's criterion (spelled in `FxParamRate`): a key is `Frame` iff
    /// applying a new value is arithmetic/comparison or a change-cached
    /// dB->lin conversion — the class the volume lane already pays per frame —
    /// and `Coefficient` iff applying it recomputes a filter or envelope
    /// coefficient (`coeff_from_ms`'s `exp`, RBJ trig).
    #[test]
    fn the_frame_block_split_is_exactly_the_pinned_table() {
        let frame = [
            "threshold", "ratio", "knee", "makeup", "mix", "detector", // dynamics curve
            "hold", "range", // gate (ms->frames multiply; dB floor cached)
            "time", "feedback", "tone", // delay (integer tap + weights)
            "damping", "size",     // reverb comb weights
            "ceiling",  // limiter dB level (cached conversion)
            "drive", "gain",     // saturator/utility dB gains (cached conversion)
            "rate", "depth", "spread", // chorus arithmetic
            "pan", "width", "polarity", // utility arithmetic
        ];
        let coefficient = [
            "attack", "release", // envelope one-pole coefficients (exp)
            "band0Freq", "band0Gain", "band0Q", "band1Freq", "band1Gain", "band1Q",
            "band2Freq", "band2Gain", "band2Q", "band3Freq", "band3Gain", "band3Q",
        ];
        for k in frame {
            assert_eq!(fx_key_class(k), FxKeyClass::Frame, "{k}");
        }
        for k in coefficient {
            assert_eq!(fx_key_class(k), FxKeyClass::Coefficient, "{k}");
        }
        assert_eq!(fx_key_class(BYPASS_KEY), FxKeyClass::Bypass);
        assert_eq!(fx_key_class("division"), FxKeyClass::Unimplemented);
        assert_eq!(fx_key_class("zorp"), FxKeyClass::Unimplemented);

        // Exhaustive: the two lists above plus bypass cover every declared key,
        // so a NEW key cannot be added without extending this table.
        let mut covered: Vec<&str> = frame.iter().chain(coefficient.iter()).copied().collect();
        covered.push(BYPASS_KEY);
        for key in all_fx_param_keys() {
            assert!(covered.contains(&key), "key '{key}' is not in the pinned split");
        }
    }

    /// `FxUnit::set_frame_param` is the ONE clamp point for lane values:
    /// NaN -> the spec default, out-of-range -> the spec range — the same
    /// guarantee `read_param` gives the block path. Proven on the OUTPUT, not
    /// on a field: a Utility driven to +1000 dB by a hostile lane value must
    /// come out at the +24 dB ceiling, and a NaN must leave it at unity.
    #[test]
    fn set_frame_param_clamps_and_defuses_nan_at_the_dispatch_boundary() {
        let settle = |u: &mut FxUnit| {
            for _ in 0..4_000 {
                u.process_frame([0.5, 0.5], [0.5, 0.5]);
            }
        };
        let gain_index = FxKindId::Utility
            .param_index("gain")
            .expect("utility has gain");

        // Out-of-range: clamps to max (+24 dB = ~15.85x), not 1000 dB.
        let p = EngineParams::new(1);
        seed_fx_defaults(&p, FxKindId::Utility, 0);
        let mut u = FxUnit::new(FxKindId::Utility, 48_000, 240);
        u.load_block_targets(&p, 0);
        u.set_frame_param(gain_index, 1_000.0);
        settle(&mut u);
        let out = u.process_frame([0.5, 0.5], [0.0, 0.0]);
        let want = 0.5 * db_to_lin(24.0);
        assert!(
            (out[0] - want).abs() < 1e-3,
            "gain lane at +1000 dB must clamp to the +24 dB spec max: {out:?} vs {want}"
        );

        // NaN: maps to the spec DEFAULT (0 dB = unity), never propagates.
        let mut u = FxUnit::new(FxKindId::Utility, 48_000, 240);
        u.load_block_targets(&p, 0);
        u.set_frame_param(gain_index, f32::NAN);
        settle(&mut u);
        let out = u.process_frame([0.5, 0.5], [0.0, 0.0]);
        assert_eq!(out, [0.5, 0.5], "a NaN lane value must read as the default");
    }

    /// The dB->lin caches must never GATE the apply — only the reconversion.
    /// A cache that skips the apply when the lane value is unchanged leaves
    /// the block loader's atomic-derived value standing on every frame after
    /// the first block boundary, i.e. the lane silently loses to the atomic.
    /// This drives exactly that interleaving and asserts the lane wins.
    #[test]
    fn a_steady_lane_value_survives_a_block_boundary_reload() {
        let p = EngineParams::new(1);
        seed_fx_defaults(&p, FxKindId::Utility, 0);
        // The ATOMIC says -96 dB (silence); the LANE says 0 dB (unity).
        assert!(set_fx_param_by_key(&p, FxKindId::Utility, 0, "gain", -96.0));
        let gain_index = FxKindId::Utility.param_index("gain").unwrap();

        let mut u = FxUnit::new(FxKindId::Utility, 48_000, 240);
        // Several blocks, lane value STEADY at 0 dB the whole time.
        let mut last = [0.0_f32; 2];
        for _block in 0..20 {
            u.load_block_targets(&p, 0);
            for _ in 0..256 {
                u.set_frame_param(gain_index, 0.0);
                last = u.process_frame([0.5, 0.5], [0.0, 0.0]);
            }
        }
        assert!(
            (last[0] - 0.5).abs() < 1e-4,
            "the steady lane value lost to the block-boundary atomic reload: {last:?}"
        );
    }

    #[test]
    fn all_param_keys_are_collected() {
        let keys = all_fx_param_keys();
        for k in ALL_FX_KINDS {
            for s in k.params() {
                assert!(keys.contains(&s.key), "{k:?} {} missing", s.key);
            }
        }
        // Sorted + deduped.
        let mut sorted = keys.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(keys, sorted);
    }
}
