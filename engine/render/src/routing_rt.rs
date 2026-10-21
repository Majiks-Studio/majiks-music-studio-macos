//! E5-graph: the RENDER-SIDE realisation of the routing graph
//! (`DESIGN-E5-routing.md` §6.2, §16.7, §19.4).
//!
//! `compile.rs` bakes these structures; `rt.rs` walks them by INDEX. Nothing
//! in here allocates, sorts, or looks anything up on the audio thread — every
//! `Box<[..]>` is built control-side and moved into the snapshot.
//!
//! ## The accumulator slot space
//!
//! One flat, fixed-layout `node_acc: Box<[[f32; 2]]>` on `RenderCore`, sized
//! once in `RenderCore::new` and never per session (§4.1):
//!
//! ```text
//! 0 .. MAX_ROUTE_NODES        explicitly-created routing nodes (bus/group)
//! ACC_FX_A                    the legacy Freeverb bus  (render-side only)
//! ACC_FX_B                    the legacy tempo delay   (render-side only)
//! ACC_MASTER                  master
//! ACC_TRACK_BASE + i          track strip i
//! ```
//!
//! **Why tracks get accumulator slots.** §4.1 sizes `node_acc` as
//! `MAX_ROUTE_NODES + 2 + 1` because §4.2's worked table only ever uses a
//! track as an edge SOURCE. But `route.connect`'s `to` is a `NodeRef` and
//! `validate_new_edge` accepts `track.<id>` there (it rejects only
//! `from == master`, self-loops and cycles), so `bus.grp -> track.t1` is a
//! legal, already-shipped edge. The two alternatives were both worse than a
//! slot: refusing it at compile makes `push_live_session` swallow the error
//! and freeze live audio silently (§0 row 16), and narrowing `route.connect`
//! breaks replay (§2.1). A track's accumulator is summed into its clip layer,
//! i.e. the edge lands PRE-FADER, which is the only position that makes a
//! strip's gain, pan, EQ and mute mean what they say. **An empty graph writes
//! nothing into these slots, so the legacy-null gate is untouched.**
//! This is a gap the document did not decide, not a decision it made
//! differently — flagged in the lane report.

use std::collections::BTreeMap;

use timeline_core::routing::Tap;

use crate::automation::AutoLane;
use crate::dsp::fx::FxUnit;
use crate::params::{MAX_ROUTE_EDGES, MAX_ROUTE_NODES};

/// §16.5. Effects in one insert chain.
pub const MAX_FX_PER_CHAIN: usize = 16;

/// §19.3. Compensation frames a single edge may carry (~85 ms at 48 k).
/// `compile` hard-errors above it, naming the node and the frame count.
pub const MAX_COMP_FRAMES: u32 = 4096;

/// `level_slot` sentinel for an edge that carries no atomic: the implicit
/// unity master feed (§4.2) and the two legacy return edges. Unity is applied
/// as a plain `+=`, never `* 1.0`, so the arithmetic is byte-identical to the
/// pre-E5 tail.
pub const IMPLICIT_UNITY: u16 = u16::MAX;

/// `level_lane` sentinel for an edge whose level is atomic-only.
pub const NO_LANE: u16 = u16::MAX;

/// Accumulator slot of the legacy Freeverb bus.
pub const ACC_FX_A: usize = MAX_ROUTE_NODES;
/// Accumulator slot of the legacy tempo-delay bus.
pub const ACC_FX_B: usize = MAX_ROUTE_NODES + 1;
/// Accumulator slot of master.
pub const ACC_MASTER: usize = MAX_ROUTE_NODES + 2;
/// First track accumulator slot; track `i` owns `ACC_TRACK_BASE + i`.
pub const ACC_TRACK_BASE: usize = MAX_ROUTE_NODES + 3;

/// Total accumulator slots for a core with `max_tracks` strips.
pub const fn node_acc_len(max_tracks: usize) -> usize {
    ACC_TRACK_BASE + max_tracks
}

/// One compiled edge. `Copy`, allocation-free, walked by index.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RtEdge {
    /// Destination accumulator slot.
    pub dest: u16,
    pub tap: Tap,
    /// Index into `EngineParams`' edge-level atomics, or [`IMPLICIT_UNITY`].
    pub level_slot: u16,
    /// Dense lane slot on the SOURCE TRACK for `route.edge.<id>.level`, or
    /// [`NO_LANE`] (§6.5). Only a track-sourced edge can carry one: a bus has
    /// no `RtTrack` to hang a lane on, and §6.5/§13 defer bus->bus edge level
    /// automation to a later epic rather than invent a second lane store.
    pub level_lane: u16,
    /// §19.4: compensation frames on THIS edge. `0` = bit-exact passthrough.
    pub comp: u32,
}

/// One step of the baked routing schedule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NodeStep {
    pub kind: NodeStepKind,
    /// Half-open range into `RtSession::edges`. The audio thread slices by
    /// index and never searches.
    pub out_edges: (u32, u32),
    /// Half-open range into `RtSession::fx`: this node's insert chain, in
    /// chain order.
    pub fx: (u32, u32),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeStepKind {
    /// Index into `RtSession::tracks`.
    Track(usize),
    /// Index into the project's routing node list -> `node_acc` slot.
    Node(usize),
    /// §2.1: the two legacy FX buses, render-side only, with no wire form.
    ///
    /// They are ONE step, not two, and that is load-bearing: the pre-E5 tail
    /// computes `master += rev * ra + del * rb` as a single expression, and
    /// float addition is not associative, so splitting it into two accumulator
    /// writes would change the low bit of every frame of every existing
    /// project and take the §12.2 legacy-null gate red.
    LegacyReturns,
    Master,
    /// A node the schedule mentioned but the project does not contain (a
    /// dangling edge endpoint). Skipped: it has no accumulator and no audio.
    Skip,
}

/// One automated parameter of one fx instance: the baked lane, the slot
/// offset within the kind's parameter block, and this binding's own
/// evaluation cursor.
///
/// The cursor lives ON THE SNAPSHOT, exactly like `TrackInstrument::cursor`
/// and for the same reason: during a session-swap crossfade the outgoing
/// session's fx keep rendering (and reading their lanes) for the 5 ms fade,
/// so old and new need one cursor EACH — and a fresh snapshot brings fresh
/// cursors, making a stale-cursor-after-swap bug structurally impossible.
/// `AutoLane::value_at` is stateless given (lane, frame); the cursor is a
/// pure accelerator that self-heals on any seek.
pub struct RtFxLane {
    /// Offset within the kind's parameter block — the same index
    /// `load_block_targets` reads at `base_slot + index`, handed per frame to
    /// `FxNode::set_frame_param`. Compile guarantees it names a
    /// `FxParamRate::Frame` spec of this instance's kind.
    pub param_index: u8,
    pub lane: AutoLane,
    pub cursor: usize,
}

/// One compiled effect instance.
///
/// The DSP unit lives on the SNAPSHOT (like `TrackInstrument`), so a session
/// swap brings a fresh, cold unit and the crossfade covers the discontinuity.
/// Parameter VALUES do not live here — they are atomics (§16.6), read once per
/// block through `FxNode::load_block_targets(base_slot)` — EXCEPT automated
/// ones: a lane in `lanes` overrides its parameter per FRAME through
/// `FxNode::set_frame_param`, the same lane-overrides-atomic convention the
/// send and node-fader readers use.
pub struct RtFx {
    pub unit: FxUnit,
    /// Flat fx instance index; `base_slot = fx_slot * MAX_FX_PARAMS_PER_FX`.
    pub fx_slot: u32,
    /// Sidechain key source accumulator slot (§17.3), or `None` for the
    /// internal (self) detector.
    ///
    /// The scheduler is told about the link (`Project::sidechain_links` ->
    /// `Routing::schedule`), so the source is guaranteed to have been written
    /// THIS frame before this node runs. Without that guarantee the detector
    /// would read exactly `0.0` — silence, not a small error.
    pub key_src: Option<u16>,
    /// This instance's automated parameters, sorted by `param_index`, baked by
    /// `compile::bake_fx_lanes`. Empty (the overwhelmingly common case) costs
    /// one slice-length test per frame. Session-scoped storage rather than the
    /// per-track dense table because an fx lane belongs to an fx INSTANCE —
    /// a bus or master chain has no `RtTrack` to hang a slot on, and the
    /// per-track table's 32-slot budget is a session-wide resource fx lanes
    /// must not consume.
    pub lanes: Box<[RtFxLane]>,
}

/// A fixed-size integer-tap delay used only for plugin delay compensation
/// (§19.2). Modelled on `DelayBus`'s ring; allocated control-side, sized to
/// its computed need, never resized on the audio thread.
///
/// **A zero-frame ring is a bit-exact passthrough**, not a ring read at
/// offset 0 (§19.3) — the caller checks `comp == 0` and never touches this.
pub struct CompDelay {
    buf: Box<[[f32; 2]]>,
    pos: usize,
}

impl CompDelay {
    pub fn new(frames: u32) -> Self {
        Self {
            buf: vec![[0.0; 2]; frames as usize].into_boxed_slice(),
            pos: 0,
        }
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.buf.len()
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }

    /// Push one frame in, take the frame `len` frames old out. Per FRAME
    /// (§6.1); there is deliberately no block form.
    #[inline]
    pub fn process_frame(&mut self, x: [f32; 2]) -> [f32; 2] {
        if self.buf.is_empty() {
            return x;
        }
        let out = self.buf[self.pos];
        self.buf[self.pos] = x;
        self.pos += 1;
        if self.pos >= self.buf.len() {
            self.pos = 0;
        }
        out
    }
}

/// Everything the graph walk needs, baked. Carried on `RtSession`.
pub struct RtGraph {
    /// Flat, in SCHEDULE order, sliced by `NodeStep::out_edges`.
    pub edges: Box<[RtEdge]>,
    /// Per-edge compensation rings, index-aligned with `edges`. An edge with
    /// `comp == 0` still has an entry, and it is empty.
    pub comp_rings: Box<[CompDelay]>,
    /// Every fx instance, in host order (tracks, then routing nodes, then
    /// master), sliced by `NodeStep::fx`.
    pub fx: Box<[RtFx]>,
    /// §6.5: the one-dimensional node lane table — `bus.<id>.gain`, indexed by
    /// node slot. `None` = not automated, so the atomic stands.
    ///
    /// Session-scoped rather than per-track because a node fader is not a
    /// track parameter. `AutomationStore` is keyed by `(track_id, path)`, so
    /// `compile` resolves the owning track deterministically and REFUSES a
    /// project where two tracks carry points for the same node's fader —
    /// silently picking one would be the ambiguity that keeps `master.gain`
    /// out of the reader set.
    pub node_gain_lanes: Box<[Option<AutoLane>]>,
    /// Model edge id -> edge-level atomic slot. **CONTROL-SIDE ONLY** — the
    /// same role `lane_index` plays, and the audio thread never touches it.
    pub edge_index: BTreeMap<String, usize>,
    /// Highest edge-level atomic slot in use + 1 (== the model edge count).
    pub edge_level_count: usize,
    /// Routing node count in this session (<= `MAX_ROUTE_NODES`).
    pub node_count: usize,
    /// Compensation frames on the two legacy return paths (§19.2).
    ///
    /// ⚠️ **`[0, 0]` is the load-bearing case and it must stay a bit-exact
    /// passthrough**: when both are zero the walk keeps `master += rev * ra +
    /// del * rb` as ONE expression, because float addition is not associative
    /// and splitting it would take the legacy-null gate red.
    ///
    /// **Honest limitation, stated rather than discovered.** The legacy SENDS
    /// (`Track::sends.a/b`) are built into the track step, not `RtEdge`s, so
    /// they are not individually compensated. If one track carries a
    /// latency-bearing insert and another does not, and both send to the same
    /// legacy bus, their contributions to that bus are misaligned by the
    /// difference. The RETURN is compensated, so the wet path still lands in
    /// time with the compensated dry paths at master. Fixing the send half
    /// means making the legacy sends real `RtEdge`s, which §2.1 forbids for
    /// exactly the bit-identity reason above.
    pub legacy_comp: [u32; 2],
    /// Rings for `legacy_comp`. Empty (and untouched) in the `[0, 0]` case.
    pub legacy_rings: [CompDelay; 2],
}

impl Default for RtGraph {
    fn default() -> Self {
        Self::empty()
    }
}

impl RtGraph {
    /// The v1 topology: no explicit nodes, no explicit edges. Every field is
    /// empty, so every walk over it is a no-op and the render is
    /// bit-identical to the pre-E5 engine.
    pub fn empty() -> Self {
        Self {
            edges: Box::new([]),
            comp_rings: Box::new([]),
            fx: Box::new([]),
            node_gain_lanes: Box::new([]),
            edge_index: BTreeMap::new(),
            edge_level_count: 0,
            node_count: 0,
            legacy_comp: [0, 0],
            legacy_rings: [CompDelay::new(0), CompDelay::new(0)],
        }
    }

    /// Node-fader lane for a node slot, bounds-checked.
    #[inline]
    pub fn node_gain_lane(&self, slot: usize) -> Option<&AutoLane> {
        self.node_gain_lanes.get(slot).and_then(Option::as_ref)
    }
}

/// Capacity guard shared by `compile` and its tests, so the message is written
/// once and names the cap AND the count exactly as `build_lane_index` does.
pub fn check_cap(what: &str, count: usize, cap: usize) -> Result<(), String> {
    if count > cap {
        return Err(format!(
            "project uses {count} {what}, engine capacity is {cap} \
             (the audio thread's tables are preallocated, so this is refused \
             control-side and the render never sees it)"
        ));
    }
    Ok(())
}

/// `MAX_ROUTE_EDGES` is re-exported here purely so the cap checks in
/// `compile.rs` read against one name.
pub const EDGE_CAP: usize = MAX_ROUTE_EDGES;
