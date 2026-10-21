//! Atomic parameter block: the DJ AtomicParams/ParamFrame idiom, grown to
//! the full strip surface.
//!
//! Control threads store clamped values with Relaxed ordering; the render
//! callback loads what it needs once per block. Capacity (max tracks) is an
//! `EngineConfig` decision, never a hardcoded constant.
//!
//! Per track: gain, mute, solo, pan, 4-band EQ (freq/gain/Q per band, catalog
//! `mix.eq` shape), and two send amounts (bus A reverb, bus B delay).
//! Master: gain, limiter (enabled/ceiling/release), bus voicing (reverb
//! damping/decay, delay tap frames/feedback/tone) and return levels.

use std::sync::atomic::{AtomicU32, AtomicU64, AtomicU8, Ordering};

use crate::dsp::biquad::{BAND_DEFAULT_HZ, BAND_DEFAULT_Q, EQ_BANDS};

pub const MIN_GAIN_DB: f32 = -96.0;
pub const MAX_GAIN_DB: f32 = 24.0;
pub const MIN_EQ_GAIN_DB: f32 = -24.0;
pub const MAX_EQ_GAIN_DB: f32 = 24.0;

// ---------------------------------------------------------------------------
// E5 routing + effects capacity (DESIGN-E5-routing.md §4.1, §16.5).
//
// ⚠️ PLACEMENT NOTE FOR E5-graph. §4.1 says `MAX_ROUTE_NODES` /
// `MAX_ROUTE_EDGES` are `pub const` in `render/src/rt.rs` next to
// `MAX_TRACK_LANES`. `rt.rs` is E5-graph's file and E5-params must not touch
// it (§21.1) — but `EngineParams` has to size its atomic slot arrays from the
// SAME numbers, and two independent declarations of a capacity is precisely
// the "two implementations that disagree" hazard this document exists to
// prevent. They therefore live here, at the point of allocation.
// **`rt.rs` should `pub use crate::params::{MAX_ROUTE_NODES, MAX_ROUTE_EDGES};`
// rather than redeclare them.** The VALUES are exactly §4.1/§16.5's; only the
// module is different, and E5-graph's re-export keeps `rt::MAX_ROUTE_NODES`
// resolving as the document spells it.
// ---------------------------------------------------------------------------

/// §4.1. Explicitly-created routing nodes (buses + groups). Master and the two
/// render-side-only `LegacyFx` nodes are NOT counted here.
pub const MAX_ROUTE_NODES: usize = 32;
/// §4.1. 64 tracks x 8 sends is the real ceiling.
pub const MAX_ROUTE_EDGES: usize = 512;
/// §16.5. Effect instances across every chain in the session.
pub const MAX_FX_TOTAL: usize = 256;

/// Parameter slots reserved per effect instance. Not pinned by the document:
/// §16.6 specifies a FLAT fx-param slot space and §21.2's
/// `FxNode::load_block_targets(&mut self, p: &EngineParams, base_slot: usize)`
/// requires each effect's slots to be CONTIGUOUS from a base. Fixing a stride
/// makes `base_slot = fx_slot * MAX_FX_PARAMS_PER_FX` a pure function of the
/// fx slot, so the host, `compile` and the DSP cannot disagree about where a
/// parameter lives without disagreeing about the fx slot itself.
///
/// 32 is headroom over the widest kind in §17.1 (`Eq`: 4 bands x
/// {freq, gain, q} + `mix` + `bypass` = 14). **`compile` must reject an fx kind
/// that needs more, naming the cap** — the same control §16.5 puts on every
/// other capacity.
pub const MAX_FX_PARAMS_PER_FX: usize = 32;
/// The flat fx-param slot space addressed by `set_fx_param` / `fx_param_target`.
pub const MAX_FX_PARAM_SLOTS: usize = MAX_FX_TOTAL * MAX_FX_PARAMS_PER_FX;

/// §6.3 / `route.connect`'s `level` schema: linear, 1.0 is unity, 4.0 is +12 dB.
pub const MIN_EDGE_LEVEL: f32 = 0.0;
pub const MAX_EDGE_LEVEL: f32 = 4.0;

fn db_to_lin(db: f32) -> f32 {
    10.0_f32.powf(db / 20.0)
}

struct AtomicF32(AtomicU32);

impl AtomicF32 {
    fn new(v: f32) -> Self {
        Self(AtomicU32::new(v.to_bits()))
    }

    #[inline]
    fn store(&self, v: f32) {
        self.0.store(v.to_bits(), Ordering::Relaxed);
    }

    #[inline]
    fn load(&self) -> f32 {
        f32::from_bits(self.0.load(Ordering::Relaxed))
    }
}

struct EqBandAtomic {
    freq_hz: AtomicF32,
    gain_db: AtomicF32,
    q: AtomicF32,
}

struct TrackParamAtomic {
    gain_db: AtomicF32,
    mute: AtomicU8,
    /// PRE-DAG SOLO (E5 replaces this). A flat per-track flag; the gate that
    /// consumes it lives in `track_gain_target`, so solo rides the same strip
    /// gain `Slew` (5 ms declick) as mute. No solo-safe, no group solo, no
    /// solo-in-place — those need the routing DAG.
    solo: AtomicU8,
    pan: AtomicF32,
    eq: [EqBandAtomic; EQ_BANDS],
    send_a: AtomicF32,
    send_b: AtomicF32,
}

impl TrackParamAtomic {
    fn new() -> Self {
        Self {
            gain_db: AtomicF32::new(0.0),
            mute: AtomicU8::new(0),
            solo: AtomicU8::new(0),
            pan: AtomicF32::new(0.0),
            eq: std::array::from_fn(|i| EqBandAtomic {
                freq_hz: AtomicF32::new(BAND_DEFAULT_HZ[i]),
                gain_db: AtomicF32::new(0.0),
                q: AtomicF32::new(BAND_DEFAULT_Q),
            }),
            send_a: AtomicF32::new(0.0),
            send_b: AtomicF32::new(0.0),
        }
    }
}

/// One EQ band's parameter view (render side reads bits for dirty checks).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EqBandValue {
    pub freq_hz: f32,
    pub gain_db: f32,
    pub q: f32,
}

/// Value a never-configured / retired edge slot reads (§6.3). Silence, not
/// unity: a slot the current session does not point at must contribute
/// NOTHING, and a recycled slot that the host somehow failed to push is then
/// inaudible rather than a full-level phantom send in the mix.
const EDGE_LEVEL_CLEARED: f32 = 0.0;
/// Value a never-configured / retired node-gain slot reads (§6.3). `RouteNode`
/// carries no gain field in the model, so a node with no fader movement IS at
/// unity; 0 dB is the honest default rather than a fail-safe choice.
const NODE_GAIN_DB_CLEARED: f32 = 0.0;
/// Value a never-configured / retired fx-param slot reads (§16.6).
///
/// ⚠️ **0.0 is not a universal DSP default** — §16.4 keeps `Fx::params` SPARSE
/// and says an absent key means "the DSP default", which only the effect kind
/// knows. The push contract is therefore: **whoever pushes an fx must push a
/// value for EVERY slot that fx reads, defaults included.** A cleared slot is
/// "nobody owns this", not "use the default".
const FX_PARAM_CLEARED: f32 = 0.0;

pub struct EngineParams {
    master_gain_db: AtomicF32,
    limiter_enabled: AtomicU8,
    limiter_ceiling_db: AtomicF32,
    limiter_release_ms: AtomicF32,
    reverb_damping: AtomicF32,
    reverb_feedback: AtomicF32,
    return_a_db: AtomicF32,
    return_b_db: AtomicF32,
    delay_tap_frames: AtomicU32,
    delay_feedback: AtomicF32,
    delay_tone: AtomicF32,
    tracks: Box<[TrackParamAtomic]>,
    // ---- E5 routing + effects (§6.3, §16.6) ----
    //
    // Levels are ATOMICS, not snapshot constants, because every mutation
    // recompiles the whole session (`sync_after_mutation` ->
    // `push_live_session` -> `compile_session_full`). Baking a send level onto
    // the snapshot would rebuild every clip, note and lane per mouse move.
    // The snapshot carries topology and slot indices; the VALUES live here.
    //
    // Fixed capacity, allocated once in `new`: the audio thread must never see
    // a resize, and `compile` rejects an over-cap session control-side.
    edge_levels: Box<[AtomicF32]>,
    node_gains_db: Box<[AtomicF32]>,
    fx_params: Box<[AtomicF32]>,
    fx_bypass: Box<[AtomicU8]>,
    // ---- metronome (MONITOR state, never project state) ----
    //
    // These are atomics for the same reason the mixer's are: the control side
    // pokes them without recompiling a session. They are NOT part of the
    // rendered mix — `CoreConfig::monitor` decides whether the click reaches
    // the output at all, and it is false on every offline path (see
    // `offline::ManualRenderer::new`). Nothing here is journaled: the
    // metronome is how you hear the grid, not part of the music.
    //
    // The grid is carried as the model's EXACT RATIONAL bpm plus the project
    // phase anchor in ticks, not as a pre-divided "frames per beat". Handing
    // the render side a rounded frame count would reintroduce exactly the
    // drift `timeline_core::tempo` was written in integer arithmetic to avoid.
    metronome_enabled: AtomicU8,
    metronome_level: AtomicF32,
    metronome_bpm_num: AtomicU32,
    metronome_bpm_den: AtomicU32,
    metronome_anchor_ticks: AtomicU64,
    metronome_beats_per_bar: AtomicU32,
}

impl EngineParams {
    pub fn new(max_tracks: usize) -> Self {
        Self {
            master_gain_db: AtomicF32::new(0.0),
            limiter_enabled: AtomicU8::new(0),
            limiter_ceiling_db: AtomicF32::new(-1.0),
            limiter_release_ms: AtomicF32::new(50.0),
            reverb_damping: AtomicF32::new(crate::dsp::reverb::DEFAULT_DAMPING),
            reverb_feedback: AtomicF32::new(crate::dsp::reverb::DEFAULT_FEEDBACK),
            return_a_db: AtomicF32::new(0.0),
            return_b_db: AtomicF32::new(0.0),
            // 3/16 of a beat at 120 BPM as a safe boot value; the host
            // resolves real divisions through the tempo map.
            delay_tap_frames: AtomicU32::new(18_000),
            delay_feedback: AtomicF32::new(crate::dsp::delay::DEFAULT_FEEDBACK),
            delay_tone: AtomicF32::new(crate::dsp::delay::DEFAULT_TONE),
            tracks: (0..max_tracks).map(|_| TrackParamAtomic::new()).collect(),
            edge_levels: (0..MAX_ROUTE_EDGES)
                .map(|_| AtomicF32::new(EDGE_LEVEL_CLEARED))
                .collect(),
            node_gains_db: (0..MAX_ROUTE_NODES)
                .map(|_| AtomicF32::new(NODE_GAIN_DB_CLEARED))
                .collect(),
            fx_params: (0..MAX_FX_PARAM_SLOTS)
                .map(|_| AtomicF32::new(FX_PARAM_CLEARED))
                .collect(),
            fx_bypass: (0..MAX_FX_TOTAL).map(|_| AtomicU8::new(0)).collect(),
            metronome_enabled: AtomicU8::new(0),
            metronome_level: AtomicF32::new(crate::dsp::click::DEFAULT_LEVEL),
            // 120 BPM 4/4 at the origin: the same safe boot grid the rest of
            // the engine assumes before a project is loaded.
            metronome_bpm_num: AtomicU32::new(120),
            metronome_bpm_den: AtomicU32::new(1),
            metronome_anchor_ticks: AtomicU64::new(0),
            metronome_beats_per_bar: AtomicU32::new(
                crate::dsp::click::BEATS_PER_BAR_V1 as u32,
            ),
        }
    }

    pub fn max_tracks(&self) -> usize {
        self.tracks.len()
    }

    // ---- track params (out-of-range indices are ignored; surfaces
    // validate first, the DJ setter shape) ----

    pub fn set_track_gain_db(&self, track: usize, gain_db: f32) {
        if let Some(t) = self.tracks.get(track) {
            t.gain_db.store(gain_db.clamp(MIN_GAIN_DB, MAX_GAIN_DB));
        }
    }

    pub fn set_track_mute(&self, track: usize, mute: bool) {
        if let Some(t) = self.tracks.get(track) {
            t.mute.store(u8::from(mute), Ordering::Relaxed);
        }
    }

    /// PRE-DAG SOLO. Mirrors `Track::solo`; the render side turns the set of
    /// flags into "any solo active" once per block (see `any_solo`).
    pub fn set_track_solo(&self, track: usize, solo: bool) {
        if let Some(t) = self.tracks.get(track) {
            t.solo.store(u8::from(solo), Ordering::Relaxed);
        }
    }

    /// Clear solo on every slot from `from` upward. Solo is a GLOBAL gate, so
    /// unlike mute a stale flag on a slot the current session no longer uses
    /// would silence the whole mix. Surfaces call this after pushing the live
    /// track count.
    pub fn clear_track_solos_from(&self, from: usize) {
        for t in self.tracks.iter().skip(from) {
            t.solo.store(0, Ordering::Relaxed);
        }
    }

    pub fn set_track_pan(&self, track: usize, pan: f32) {
        if let Some(t) = self.tracks.get(track) {
            t.pan.store(pan.clamp(-1.0, 1.0));
        }
    }

    pub fn set_track_eq(&self, track: usize, band: usize, freq_hz: f32, gain_db: f32, q: f32) {
        if let Some(t) = self.tracks.get(track) {
            if let Some(b) = t.eq.get(band) {
                b.freq_hz.store(freq_hz.clamp(20.0, 20_000.0));
                b.gain_db.store(gain_db.clamp(MIN_EQ_GAIN_DB, MAX_EQ_GAIN_DB));
                b.q.store(q.clamp(0.05, 10.0));
            }
        }
    }

    pub fn set_track_send(&self, track: usize, bus_b: bool, amount: f32) {
        if let Some(t) = self.tracks.get(track) {
            let v = amount.clamp(0.0, 1.0);
            if bus_b {
                t.send_b.store(v);
            } else {
                t.send_a.store(v);
            }
        }
    }

    // -----------------------------------------------------------------------
    // E5 routing edges + node faders (DESIGN-E5-routing.md §6.3).
    //
    // Slots are assigned by `compile` and change on every session swap.
    //
    // ⚠️ STALE-SLOT HAZARD — the solo bug's twin. After a swap the mapping
    // changes, and a level left in a retired slot is either harmless (nothing
    // points at it) or WRONG (a recycled edge inherits a level the user never
    // set for it). This is structurally identical to why
    // `clear_track_solos_from` exists. **Every host that pushes edge levels or
    // node gains MUST call the matching `clear_*_from` immediately after,
    // exactly as `sync_params` already does for solo.**
    //
    // Out-of-range slots are ignored on write and read as the cleared value,
    // the same shape the track setters use: surfaces validate first.
    //
    // Non-finite writes are DROPPED rather than clamped. `f32::NAN.clamp(a, b)`
    // is NaN, and one NaN reaching a summing point poisons the whole mix from
    // that frame on with no way to recover and no cause in the model. A
    // rejected write leaves the previous good value, which is loud enough to
    // find and never destroys the bounce.
    // -----------------------------------------------------------------------

    /// Set one edge's linear level. Clamped to `0.0..=4.0`, matching
    /// `route.connect`'s `level` schema (1.0 is unity).
    pub fn set_edge_level(&self, slot: usize, level: f32) {
        if !level.is_finite() {
            return;
        }
        if let Some(e) = self.edge_levels.get(slot) {
            e.store(level.clamp(MIN_EDGE_LEVEL, MAX_EDGE_LEVEL));
        }
    }

    /// Linear level target for one edge slot. Render side, once per block;
    /// the per-edge `Slew` does the ramping.
    pub fn edge_level_target(&self, slot: usize) -> f32 {
        self.edge_levels
            .get(slot)
            .map(AtomicF32::load)
            .unwrap_or(EDGE_LEVEL_CLEARED)
    }

    /// Reset every edge slot from `from` upward. Hosts call this with the LIVE
    /// edge count immediately after pushing levels for slots `0..from`.
    pub fn clear_edge_levels_from(&self, from: usize) {
        for e in self.edge_levels.iter().skip(from) {
            e.store(EDGE_LEVEL_CLEARED);
        }
    }

    /// Set one routing node's fader, in dB. Clamped to the same
    /// `MIN_GAIN_DB..=MAX_GAIN_DB` window as a track fader.
    pub fn set_node_gain_db(&self, slot: usize, gain_db: f32) {
        if !gain_db.is_finite() {
            return;
        }
        if let Some(n) = self.node_gains_db.get(slot) {
            n.store(gain_db.clamp(MIN_GAIN_DB, MAX_GAIN_DB));
        }
    }

    /// LINEAR gain target for one routing node. Render side, once per block.
    /// An out-of-range slot reads 0.0 (silence), the same fail-safe
    /// `track_gain_target` uses for an out-of-range track.
    pub fn node_gain_target(&self, slot: usize) -> f32 {
        match self.node_gains_db.get(slot) {
            Some(n) => db_to_lin(n.load()),
            None => 0.0,
        }
    }

    /// Reset every node-gain slot from `from` upward. Hosts call this with the
    /// LIVE node count immediately after pushing gains for slots `0..from`.
    pub fn clear_node_gains_from(&self, from: usize) {
        for n in self.node_gains_db.iter().skip(from) {
            n.store(NODE_GAIN_DB_CLEARED);
        }
    }

    // -----------------------------------------------------------------------
    // E5 effect-device parameters (DESIGN-E5-routing.md §16.6).
    //
    // Same argument as §6.3 with more force: turning a compressor's threshold
    // knob must not trigger a full rebuild of every clip, note and lane.
    //
    // ⚠️ The stale-slot hazard is now THREE-dimensional (edges, nodes, fx
    // params). A stale fx-param slot is worse than a stale edge level: it is
    // INAUDIBLE until the slot is recycled, and then it is a wrong sound with
    // no cause.
    //
    // Slot layout: fx instance `i` owns the contiguous block
    // `i * MAX_FX_PARAMS_PER_FX .. (i + 1) * MAX_FX_PARAMS_PER_FX`, which is
    // the `base_slot` §21.2's `FxNode::load_block_targets` receives.
    // -----------------------------------------------------------------------

    /// Set one fx parameter slot. NOT clamped: the range of a key is the
    /// effect kind's business (dB, ms, ratio, 0..1 mix all share this space)
    /// and `apply.rs` validates the wire value. Non-finite writes are dropped
    /// for the reason above.
    pub fn set_fx_param(&self, slot: usize, value: f32) {
        if !value.is_finite() {
            return;
        }
        if let Some(p) = self.fx_params.get(slot) {
            p.store(value);
        }
    }

    /// Target for one fx parameter slot. Render side, once per block.
    pub fn fx_param_target(&self, slot: usize) -> f32 {
        self.fx_params
            .get(slot)
            .map(AtomicF32::load)
            .unwrap_or(FX_PARAM_CLEARED)
    }

    /// Reset every fx parameter slot from `from` upward. ⚠️ `from` is a
    /// PARAM slot, not an fx slot: clear from
    /// `live_fx_count * MAX_FX_PARAMS_PER_FX`.
    pub fn clear_fx_params_from(&self, from: usize) {
        for p in self.fx_params.iter().skip(from) {
            p.store(FX_PARAM_CLEARED);
        }
        // A retired fx's bypass flag is stale for exactly the same reason its
        // params are, and leaving it set would silence a recycled slot.
        let from_fx = from / MAX_FX_PARAMS_PER_FX;
        for b in self.fx_bypass.iter().skip(from_fx) {
            b.store(0, Ordering::Relaxed);
        }
    }

    /// Bypass one fx instance. §16.6: bypass is a PARAM on the wire
    /// (`fx.param.set {key: "bypass"}`), so it automates for free; this is the
    /// resolved per-instance flag the render side reads. The transition must
    /// ramp over `MICRO_FADE_FRAMES` on the render side or it clicks.
    pub fn set_fx_bypass(&self, fx_slot: usize, bypassed: bool) {
        if let Some(b) = self.fx_bypass.get(fx_slot) {
            b.store(u8::from(bypassed), Ordering::Relaxed);
        }
    }

    /// Companion reader for `set_fx_bypass` (additive to §16.6's list, which
    /// specifies the setter only — the render side needs a load).
    pub fn fx_bypassed(&self, fx_slot: usize) -> bool {
        self.fx_bypass
            .get(fx_slot)
            .map(|b| b.load(Ordering::Relaxed) != 0)
            .unwrap_or(false)
    }

    // ---- master + bus params ----

    pub fn set_master_gain_db(&self, gain_db: f32) {
        self.master_gain_db.store(gain_db.clamp(MIN_GAIN_DB, MAX_GAIN_DB));
    }

    pub fn set_limiter(&self, enabled: bool, ceiling_db: f32, release_ms: f32) {
        self.limiter_ceiling_db.store(ceiling_db.clamp(-6.0, 0.0));
        self.limiter_release_ms.store(release_ms.clamp(1.0, 1_000.0));
        self.limiter_enabled.store(u8::from(enabled), Ordering::Relaxed);
    }

    pub fn set_reverb(&self, damping: f32, feedback: f32) {
        self.reverb_damping.store(damping.clamp(0.0, 0.99));
        self.reverb_feedback.store(feedback.clamp(0.0, 0.98));
    }

    pub fn set_return_db(&self, bus_b: bool, gain_db: f32) {
        let v = gain_db.clamp(MIN_GAIN_DB, MAX_GAIN_DB);
        if bus_b {
            self.return_b_db.store(v);
        } else {
            self.return_a_db.store(v);
        }
    }

    pub fn set_delay(&self, tap_frames: u32, feedback: f32, tone: f32) {
        self.delay_tap_frames.store(tap_frames.max(1), Ordering::Relaxed);
        self.delay_feedback.store(feedback.clamp(0.0, 0.95));
        self.delay_tone.store(tone.clamp(0.0, 0.99));
    }

    // ---- metronome ----

    pub fn set_metronome_enabled(&self, enabled: bool) {
        self.metronome_enabled
            .store(u8::from(enabled), Ordering::Relaxed);
    }

    pub fn metronome_enabled(&self) -> bool {
        self.metronome_enabled.load(Ordering::Relaxed) != 0
    }

    /// Click level, linear peak gain. Clamped to a range that cannot be
    /// weaponised: 0 is off, 2.0 is +6 dB over the default reference.
    pub fn set_metronome_level(&self, level: f32) {
        self.metronome_level.store(level.clamp(0.0, 2.0));
    }

    pub fn metronome_level(&self) -> f32 {
        self.metronome_level.load()
    }

    /// Push the musical grid. `bpm_num`/`bpm_den` are the model's EXACT
    /// rational BPM (`timeline_core::tempo::Bpm`), not a float: the render
    /// side recomputes each beat's frame with the same integer arithmetic the
    /// timeline uses, so the click lands on the frame the model says the beat
    /// is on.
    pub fn set_metronome_grid(
        &self,
        bpm_num: u32,
        bpm_den: u32,
        phase_anchor_ticks: u64,
        beats_per_bar: u32,
    ) {
        self.metronome_bpm_num
            .store(bpm_num.max(1), Ordering::Relaxed);
        self.metronome_bpm_den
            .store(bpm_den.max(1), Ordering::Relaxed);
        self.metronome_anchor_ticks
            .store(phase_anchor_ticks, Ordering::Relaxed);
        self.metronome_beats_per_bar
            .store(beats_per_bar.max(1), Ordering::Relaxed);
    }

    /// Read the whole metronome grid as the render side's config. One call per
    /// block, never per frame.
    pub fn metronome_config(&self, sample_rate: u32) -> crate::dsp::click::MetroConfig {
        crate::dsp::click::MetroConfig {
            sample_rate,
            bpm_num: self.metronome_bpm_num.load(Ordering::Relaxed),
            bpm_den: self.metronome_bpm_den.load(Ordering::Relaxed),
            phase_anchor_ticks: self.metronome_anchor_ticks.load(Ordering::Relaxed),
            beats_per_bar: u64::from(self.metronome_beats_per_bar.load(Ordering::Relaxed)),
            level: self.metronome_level.load(),
        }
    }

    // ---- render-side loads ----

    /// PRE-DAG SOLO. True when ANY strip in `0..count` is soloed. Render side
    /// calls this once per block, before the per-track target loop, so every
    /// strip in a block sees one consistent gate. Bounded by the live track
    /// count (not `max_tracks`) so a stale flag on a retired slot can never
    /// silence the mix.
    pub fn any_solo(&self, count: usize) -> bool {
        self.tracks
            .iter()
            .take(count)
            .any(|t| t.solo.load(Ordering::Relaxed) != 0)
    }

    /// Linear gain target for one track (0.0 when muted, or when solo is
    /// active elsewhere and this track is not soloed). Render side, once per
    /// block per track.
    ///
    /// PRE-DAG SOLO semantics — Ableton Live convention: mute and solo are
    /// independent switches and MUTE WINS. Live's mute is the track activator
    /// (the channel is off); solo only implicitly mutes the tracks that are
    /// not soloed. So a track that is both muted and soloed stays silent.
    /// Returning a plain target keeps this on the existing strip gain `Slew`,
    /// which is what gives solo the same 5 ms declick ramp as mute — a hard
    /// gain step here would click.
    pub fn track_gain_target(&self, track: usize, any_solo: bool) -> f32 {
        match self.tracks.get(track) {
            Some(t) => {
                if Self::gated(t, any_solo) {
                    0.0
                } else {
                    db_to_lin(t.gain_db.load())
                }
            }
            None => 0.0,
        }
    }

    /// The one mute/solo gate predicate. `track_gain_target` and
    /// `track_gate_target` MUST agree frame for frame — a pre-fader send that
    /// disagreed with the fader about whether a track is soloed would leave
    /// every other track's reverb up while the user thinks they pressed solo.
    /// One expression, two callers, so they cannot drift.
    #[inline]
    fn gated(t: &TrackParamAtomic, any_solo: bool) -> bool {
        let muted = t.mute.load(Ordering::Relaxed) != 0;
        let solo_gated = any_solo && t.solo.load(Ordering::Relaxed) == 0;
        muted || solo_gated
    }

    /// §3.3. The mute/solo gate WITHOUT the fader: 0.0 when muted or
    /// solo-gated, else 1.0. Read once per block alongside
    /// `track_gain_target`, using the SAME `any_solo` so a block is internally
    /// consistent.
    ///
    /// This exists for the PRE-fader tap. A pre-fader send is deliberately not
    /// gated by the fader (pull the fader to zero and the reverb tail
    /// continues) but IS gated by mute and by solo:
    ///
    /// - mute is the channel activator (the Live convention documented on
    ///   `track_gain_target`), and a mute that leaves a reverb tail ringing is
    ///   indistinguishable from a broken mute;
    /// - solo must mean "nothing else is audible ANYWHERE" — if a pre-fader
    ///   send bypassed the solo gate, soloing a kick would leave every other
    ///   track's reverb in the mix, and that gets filed as "solo is broken"
    ///   for the second time in this product's life.
    ///
    /// ⚠️ **Render side: this must ride its OWN 5 ms `Slew` (`Strip::gate`).**
    /// Do NOT fold it into `strip.gain` by refactoring
    /// `gain_target = track_gain_target(..) * vol_auto` into a product of two
    /// slews: floating-point multiplication is not associative and that
    /// refactor breaks the legacy-null gate (§3.3, §12.2). The post path's
    /// arithmetic stays untouched, byte for byte.
    pub fn track_gate_target(&self, track: usize, any_solo: bool) -> f32 {
        match self.tracks.get(track) {
            Some(t) => {
                if Self::gated(t, any_solo) {
                    0.0
                } else {
                    1.0
                }
            }
            None => 0.0,
        }
    }

    pub fn track_pan_target(&self, track: usize) -> f32 {
        self.tracks.get(track).map(|t| t.pan.load()).unwrap_or(0.0)
    }

    pub fn track_eq_value(&self, track: usize, band: usize) -> EqBandValue {
        match self.tracks.get(track).and_then(|t| t.eq.get(band)) {
            Some(b) => EqBandValue {
                freq_hz: b.freq_hz.load(),
                gain_db: b.gain_db.load(),
                q: b.q.load(),
            },
            None => EqBandValue {
                freq_hz: 1_000.0,
                gain_db: 0.0,
                q: BAND_DEFAULT_Q,
            },
        }
    }

    pub fn track_send_target(&self, track: usize, bus_b: bool) -> f32 {
        match self.tracks.get(track) {
            Some(t) => {
                if bus_b {
                    t.send_b.load()
                } else {
                    t.send_a.load()
                }
            }
            None => 0.0,
        }
    }

    pub fn master_gain_target(&self) -> f32 {
        db_to_lin(self.master_gain_db.load())
    }

    pub fn limiter_enabled(&self) -> bool {
        self.limiter_enabled.load(Ordering::Relaxed) != 0
    }

    pub fn limiter_ceiling_lin(&self) -> f32 {
        db_to_lin(self.limiter_ceiling_db.load())
    }

    /// Per-frame release coefficient for the limiter at `sample_rate`.
    pub fn limiter_release_coeff(&self, sample_rate: u32) -> f32 {
        let ms = self.limiter_release_ms.load();
        (-1.0 / (ms * 0.001 * sample_rate.max(1) as f32)).exp()
    }

    pub fn reverb_damping(&self) -> f32 {
        self.reverb_damping.load()
    }

    pub fn reverb_feedback(&self) -> f32 {
        self.reverb_feedback.load()
    }

    pub fn return_target(&self, bus_b: bool) -> f32 {
        db_to_lin(if bus_b {
            self.return_b_db.load()
        } else {
            self.return_a_db.load()
        })
    }

    pub fn delay_tap_frames(&self) -> u32 {
        self.delay_tap_frames.load(Ordering::Relaxed)
    }

    pub fn delay_feedback(&self) -> f32 {
        self.delay_feedback.load()
    }

    pub fn delay_tone(&self) -> f32 {
        self.delay_tone.load()
    }

    pub fn track_mute(&self, track: usize) -> bool {
        self.tracks
            .get(track)
            .map(|t| t.mute.load(Ordering::Relaxed) != 0)
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    //! Unit proofs for the §6.3 / §16.6 / §3.3 surface: clamping, slot
    //! bounds, non-finite rejection and the `clear_*_from` stale-slot
    //! discipline.
    //!
    //! **Seam honesty (§12.5): these tests set params DIRECTLY and therefore
    //! prove NOTHING about whether a host push reaches them.** That is exactly
    //! how the solo bug survived for months. The host hop is proven separately
    //! by `render/tests/params_slots.rs` (through `ProjectHost::apply`) and the
    //! bounce hop by `agent-surface/tests/e5_params_seam.rs`.

    use super::*;

    fn p() -> EngineParams {
        EngineParams::new(4)
    }

    #[test]
    fn edge_level_clamps_to_the_route_connect_schema() {
        let p = p();
        p.set_edge_level(0, 1.0);
        assert_eq!(p.edge_level_target(0), 1.0);
        p.set_edge_level(0, 9.0);
        assert_eq!(p.edge_level_target(0), MAX_EDGE_LEVEL, "level > 4 must clamp");
        p.set_edge_level(0, -3.0);
        assert_eq!(p.edge_level_target(0), MIN_EDGE_LEVEL, "level < 0 must clamp");
    }

    #[test]
    fn edge_level_rejects_non_finite_instead_of_clamping_to_nan() {
        let p = p();
        p.set_edge_level(0, 0.75);
        for bad in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
            p.set_edge_level(0, bad);
            let got = p.edge_level_target(0);
            assert!(got.is_finite(), "{bad} reached the audio thread as {got}");
            assert_eq!(got, 0.75, "a rejected write must leave the prior good value");
        }
    }

    #[test]
    fn out_of_range_edge_slot_is_ignored_and_reads_cleared() {
        let p = p();
        p.set_edge_level(MAX_ROUTE_EDGES, 4.0);
        p.set_edge_level(usize::MAX, 4.0);
        assert_eq!(p.edge_level_target(MAX_ROUTE_EDGES), EDGE_LEVEL_CLEARED);
        assert_eq!(p.edge_level_target(usize::MAX), EDGE_LEVEL_CLEARED);
    }

    /// §6.3's mandated shape: a value left in a RETIRED slot is cleared, and a
    /// value in a LIVE slot is not. Over-clearing is as wrong as under-
    /// clearing — it would wipe the level the host just pushed.
    #[test]
    fn clear_edge_levels_from_clears_retired_slots_only() {
        let p = p();
        for slot in 0..6 {
            p.set_edge_level(slot, 2.0);
        }
        p.set_edge_level(MAX_ROUTE_EDGES - 1, 3.0);
        p.clear_edge_levels_from(3);
        for slot in 0..3 {
            assert_eq!(p.edge_level_target(slot), 2.0, "live slot {slot} was wiped");
        }
        for slot in 3..6 {
            assert_eq!(p.edge_level_target(slot), 0.0, "retired slot {slot} survived");
        }
        assert_eq!(
            p.edge_level_target(MAX_ROUTE_EDGES - 1),
            0.0,
            "the clear must reach the top of the slot space, not stop at the dirty prefix"
        );
    }

    #[test]
    fn node_gain_is_db_in_linear_out_and_clamps_to_the_fader_window() {
        let p = p();
        assert_eq!(p.node_gain_target(0), 1.0, "an unset node fader is unity");
        p.set_node_gain_db(0, -6.0);
        let g = p.node_gain_target(0);
        assert!((g - 0.501_187_2).abs() < 1e-6, "-6 dB should be ~0.5012, got {g}");
        p.set_node_gain_db(1, 999.0);
        assert_eq!(p.node_gain_target(1), db_to_lin(MAX_GAIN_DB));
        p.set_node_gain_db(2, -999.0);
        assert_eq!(p.node_gain_target(2), db_to_lin(MIN_GAIN_DB));
        p.set_node_gain_db(3, f32::NAN);
        assert!(p.node_gain_target(3).is_finite());
    }

    #[test]
    fn out_of_range_node_slot_reads_silence_not_unity() {
        let p = p();
        assert_eq!(
            p.node_gain_target(MAX_ROUTE_NODES),
            0.0,
            "an out-of-range node must fail safe to silence, like track_gain_target"
        );
    }

    #[test]
    fn clear_node_gains_from_clears_retired_slots_only() {
        let p = p();
        for slot in 0..5 {
            p.set_node_gain_db(slot, -12.0);
        }
        p.clear_node_gains_from(2);
        for slot in 0..2 {
            assert_eq!(p.node_gain_target(slot), db_to_lin(-12.0), "live slot {slot} wiped");
        }
        for slot in 2..5 {
            assert_eq!(p.node_gain_target(slot), 1.0, "retired slot {slot} survived");
        }
    }

    #[test]
    fn fx_params_are_unclamped_but_finite_and_slot_bounded() {
        let p = p();
        p.set_fx_param(0, -48.0);
        assert_eq!(p.fx_param_target(0), -48.0, "a threshold in dB must not be clamped");
        p.set_fx_param(1, 20.0);
        assert_eq!(p.fx_param_target(1), 20.0, "a ratio must not be clamped");
        p.set_fx_param(2, f32::NAN);
        assert!(p.fx_param_target(2).is_finite());
        p.set_fx_param(MAX_FX_PARAM_SLOTS, 1.0);
        assert_eq!(p.fx_param_target(MAX_FX_PARAM_SLOTS), FX_PARAM_CLEARED);
    }

    #[test]
    fn clear_fx_params_from_also_clears_the_retired_bypass_flags() {
        let p = p();
        let live_fx = 2usize;
        let from = live_fx * MAX_FX_PARAMS_PER_FX;
        for fx in 0..4 {
            p.set_fx_bypass(fx, true);
            p.set_fx_param(fx * MAX_FX_PARAMS_PER_FX, 1.5);
        }
        p.clear_fx_params_from(from);
        for fx in 0..live_fx {
            assert!(p.fx_bypassed(fx), "live fx {fx} lost its bypass");
            assert_eq!(p.fx_param_target(fx * MAX_FX_PARAMS_PER_FX), 1.5);
        }
        for fx in live_fx..4 {
            assert!(
                !p.fx_bypassed(fx),
                "retired fx {fx} kept a bypass flag: a recycled slot would boot silenced"
            );
            assert_eq!(p.fx_param_target(fx * MAX_FX_PARAMS_PER_FX), FX_PARAM_CLEARED);
        }
    }

    #[test]
    fn fx_param_slot_space_is_contiguous_per_instance() {
        let p = p();
        // The last param of fx 0 and the first param of fx 1 must not alias.
        p.set_fx_param(MAX_FX_PARAMS_PER_FX - 1, 7.0);
        p.set_fx_param(MAX_FX_PARAMS_PER_FX, 9.0);
        assert_eq!(p.fx_param_target(MAX_FX_PARAMS_PER_FX - 1), 7.0);
        assert_eq!(p.fx_param_target(MAX_FX_PARAMS_PER_FX), 9.0);
        assert_eq!(MAX_FX_PARAM_SLOTS, MAX_FX_TOTAL * MAX_FX_PARAMS_PER_FX);
    }

    // ---- §3.3 track_gate_target ----

    #[test]
    fn gate_is_unity_when_open_and_zero_when_muted() {
        let p = p();
        assert_eq!(p.track_gate_target(0, false), 1.0);
        p.set_track_mute(0, true);
        assert_eq!(p.track_gate_target(0, false), 0.0, "mute must kill the pre tap");
    }

    #[test]
    fn gate_is_zero_for_a_non_soloed_track_when_solo_is_active() {
        let p = p();
        p.set_track_solo(1, true);
        let any = p.any_solo(4);
        assert!(any);
        assert_eq!(
            p.track_gate_target(0, any),
            0.0,
            "solo must mean nothing else is audible ANYWHERE, including pre-fader sends"
        );
        assert_eq!(p.track_gate_target(1, any), 1.0);
    }

    /// The gate carries NO fader: a track at -60 dB still has an open pre tap.
    /// This is the whole point of §3.2 (pull the fader down, the tail rings on).
    #[test]
    fn gate_ignores_the_fader() {
        let p = p();
        p.set_track_gain_db(0, -60.0);
        assert_eq!(p.track_gate_target(0, false), 1.0);
        assert!(p.track_gain_target(0, false) < 0.01);
    }

    /// The two readers must agree about WHETHER a track is gated for every
    /// combination of mute / solo / any_solo. If they ever disagree, a
    /// pre-fader send outlives a mute or survives a solo.
    #[test]
    fn gate_and_gain_agree_on_every_mute_solo_combination() {
        for muted in [false, true] {
            for soloed in [false, true] {
                for other_soloed in [false, true] {
                    let p = p();
                    p.set_track_gain_db(0, 0.0);
                    p.set_track_mute(0, muted);
                    p.set_track_solo(0, soloed);
                    p.set_track_solo(1, other_soloed);
                    let any = p.any_solo(4);
                    let gain_silent = p.track_gain_target(0, any) == 0.0;
                    let gate_shut = p.track_gate_target(0, any) == 0.0;
                    assert_eq!(
                        gain_silent, gate_shut,
                        "disagreement at muted={muted} soloed={soloed} other={other_soloed}"
                    );
                }
            }
        }
    }

    #[test]
    fn out_of_range_track_gate_is_shut() {
        let p = p();
        assert_eq!(p.track_gate_target(99, false), 0.0);
    }
}
