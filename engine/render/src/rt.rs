//! The render core: everything that runs on the audio thread.
//!
//! DJ engine idioms carried over verbatim where they earned it:
//! - bounded command channel (capacity from config, DJ used 2048) drained
//!   with `try_recv` at block start
//! - atomic params loaded once per block into plain arrays
//! - replaced heap payloads (session snapshots, capture buffers) leave via a
//!   bounded drop channel and are freed on a drop thread; if that channel is
//!   full the callback leaks deliberately and counts it (never frees inline,
//!   never prints)
//! - per-frame state machines on Copy data only
//!
//! Phase 1 graph (L2): per-track strip (clip sum -> gain/pan -> 4-band EQ ->
//! post-fader send taps) -> bus A (Freeverb) + bus B (tempo delay) -> master
//! (gain -> optional true-peak lookahead limiter -> meters). The full graph
//! runs every block whether or not the transport moves, so bus tails ring
//! out naturally and idle cost is the real cost.
//!
//! Determinism rule: ALL signal state advances per FRAME. Block boundaries
//! only read atomics into targets. With static params, rendering the same
//! command schedule at any chunk size is bit-identical: that is the offline
//! bounce null-test guarantee.
//!
//! Session swaps CROSSFADE at the clip-sum layer over the declick window
//! (5 ms): every edit lands click-free by construction. Identical content
//! crossfades to itself bit-exactly (linear blend), so swaps that do not
//! change what is audible do not perturb the output. A swap arriving while
//! one is in flight parks in a latest-wins pending slot.
//!
//! Zero allocation, zero locks, zero I/O in `render()`. Proven by the
//! counting allocator in `guard` plus the integration tests.

use std::collections::BTreeMap;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Instant;

use crossbeam_channel::{Receiver, Sender};
use timeline_core::FadeShape;

use crate::automation::AutoLane;
use crate::notes::{FrameEvents, NoteCursor, NoteLane};
use crate::dsp::click::{MetroConfig, Metronome};
use crate::dsp::delay::DelayBus;
use crate::dsp::fx::{base_slot_of, FxNode};
use crate::params::{MAX_EDGE_LEVEL, MIN_EDGE_LEVEL};
use crate::routing_rt::{
    RtGraph, ACC_FX_A, ACC_FX_B, ACC_MASTER, ACC_TRACK_BASE, IMPLICIT_UNITY, NO_LANE,
};
use crate::dsp::instrument::{InstrumentNode, InstrumentParams, INSTRUMENT_PARAM_COUNT};
use crate::dsp::limiter::Limiter;
use crate::dsp::reverb::ReverbBus;
use crate::dsp::slew::Slew;
use crate::dsp::truepeak::TruePeakDetector;
use crate::media::AudioBuf;
use crate::stats::{EngineStats, MeterBank};
use crate::strip::Strip;

/// Engine-internal rate, v1 (02-ARCHITECTURE.md section 3). SRC at IO.
pub const ENGINE_SAMPLE_RATE: u32 = 48_000;

/// 5 ms declick ramp in frames at the engine rate (DJ MICRO_FADE_FRAMES).
pub const MICRO_FADE_FRAMES: u64 = (ENGINE_SAMPLE_RATE as u64 * 5) / 1000;
const RAMP_FRAMES: u32 = MICRO_FADE_FRAMES as u32;

/// One clip as the render side sees it: resolved frames, linear gain,
/// Arc'd audio. Built by `compile`, immutable on this side. Fade shapes are
/// per edge so the compiler can inject implicit LINEAR declick ramps at
/// boundaries that are not sample-continuous, without touching authored
/// equal-power fades on the other edge.
pub struct RtClip {
    pub audio: Arc<AudioBuf>,
    pub start_frame: u64,
    pub offset_frames: u64,
    pub len_frames: u64,
    pub gain_lin: f32,
    pub fade_in_frames: u64,
    pub fade_out_frames: u64,
    pub fade_in_shape: FadeShape,
    pub fade_out_shape: FadeShape,
}

impl RtClip {
    #[inline]
    pub fn end_frame(&self) -> u64 {
        self.start_frame + self.len_frames
    }
}

/// Fixed lane slots. Volume and pan keep dedicated indices so their hot paths
/// are a constant-index array read plus the existing dB cache — no lookup, no
/// branch on a path string. They are the FAST PATH, not the only representable
/// lanes: slots >= `LANE_FIXED` are assigned at compile time from the session's
/// ParamRef set (design §5.2).
pub const LANE_VOLUME: usize = 0;
pub const LANE_PAN: usize = 1;
pub const LANE_FIXED: usize = 2;

/// Hard cap on lanes per track. Cursor state lives in a fixed-size array on the
/// `Strip` (preallocated at engine construction), so this is what keeps the
/// audio thread allocation-free. `compile` rejects a project that exceeds it
/// with a control-side error, exactly like `max_tracks`.
pub const MAX_TRACK_LANES: usize = 32;

/// §23.2: capacity constants have EXACTLY ONE declaration, at the point where
/// the atomic arrays are allocated (`params.rs`). §4.1 spelled them in this
/// module, so they are re-exported rather than redeclared — two declarations
/// of one capacity is a buffer sized by one number and indexed by another.
pub use crate::params::{MAX_ROUTE_EDGES, MAX_ROUTE_NODES};

/// The baked routing structures live in `routing_rt`; they are re-exported
/// here because §6.2 spells them `rt::NodeStep` / `rt::RtEdge` and `compile.rs`
/// imports them from this module.
pub use crate::routing_rt::{NodeStep, NodeStepKind, RtEdge};

/// The two legacy FX send levels, as slots on `RtSession::send_lane_slots`.
pub const SEND_A: usize = 0;
pub const SEND_B: usize = 1;

/// ⚠️ **THE ANTI-INERT-LANE GATE. Read this before adding an automatable path.**
///
/// `true` iff `RenderCore::render` (or something it calls) actually READS a lane
/// on `path` and lets it reach the audio. `compile::build_lane_index` refuses any
/// other path, LOUDLY, instead of handing it a dense slot nothing will ever look
/// at.
///
/// It exists because the opposite shipped: `track.send.a.level` compiled into a
/// real slot, got a real cursor, was journaled, moved the control — and rendered
/// bit-identically to no automation at all. That is the solo bug's exact shape:
/// a UI-state path that updates while nothing reaches the audio.
///
/// **Adding a path here without adding its reader re-opens the bug.** The
/// pairing is asserted, path by path, in `render/tests/inert_lanes.rs`.
///
/// The refusal is deliberately here (control-side, at compile) and NOT in
/// `Project::require_param_ref_on`: replay runs `apply_cmd`
/// (`timeline-core/src/session.rs:576`), so narrowing the command would make a
/// project that already journaled such a lane fail to OPEN. The points survive
/// in the model and on disk; only the render refuses.
///
/// ⚠️ **This is a PURE PATH function — it answers "does this path FAMILY have
/// a per-frame reader", never "does this lane resolve in this project".** A
/// `true` here is necessary but NOT sufficient: `bus.<id>.gain` is readable as
/// a family while `<id>` may name no node, and `track.device.<id>.<key>` while
/// the track carries no such device — dangling lanes are forward-legal since
/// the `require_param_ref_on` widening (stranded by `route.node.remove` /
/// `device.remove`, or a typo'd id). The resolution-aware half of the fence is
/// `compile::refuse_unreadable_lanes`' dangling sweep (fed a `LaneTargets`
/// built from the project by both feeds), and the kind-/instance-aware half
/// for fx and edge lanes lives in their bakes. Three halves, one fence; a
/// path that passes here and resolves nowhere is still refused, loudly.
pub fn lane_has_reader(path: &str) -> bool {
    use timeline_core::ParamRefKind as K;
    let Ok(r) = timeline_core::ParamRef::parse(path) else {
        return false;
    };
    match r.kind() {
        // rt.rs: `strip.vol_lane_lin` / `strip.pan_lane_value` in the strip loop.
        K::TrackVolume | K::TrackPan => true,
        // rt.rs: `strip.lane_value` on the send targets in the strip loop.
        K::TrackSendLevel { send_id } => send_id == "a" || send_id == "b",
        // rt.rs: `render_instrument_frame` -> `TrackInstrument::slots`.
        K::TrackDeviceParam { param, .. } => {
            crate::dsp::instrument::INSTRUMENT_PARAM_KEYS.contains(&param)
        }
        // rt.rs: the `Node` step of the graph walk, through
        // `RtGraph::node_gain_lanes` (design §6.5). E5-graph landed the reader.
        K::BusGain { .. } => true,
        // rt.rs: the `Track` step's out-edge loop, through
        // `RtGraph::edges[..].level_slot` (design §6.4/§6.5).
        //
        // ⚠️ TRACK-SOURCED EDGES ONLY. §6.5 defers bus->bus edge level
        // automation ("atomic-only, not automatable") because a bus has no
        // `RtTrack` to hang a lane on, and §13 keeps that deferral. The lane
        // STORE is per (track, path), so a lane on this path is by construction
        // attached to a track — `compile` additionally refuses one whose named
        // edge is not sourced by that track, rather than baking a slot the walk
        // will not read.
        K::RouteEdgeLevel { .. } => true,
        // No reader. Each of these is a real gap, not an oversight — see
        // `compile::build_lane_index`'s error text for why.
        K::TrackEq { .. } | K::MasterGain | K::MasterLimiter { .. } => false,
        // rt.rs: `run_fx_chain` drives `FxNode::set_frame_param` from
        // `RtFx::lanes` once per FRAME, before that frame's `process_frame` —
        // the per-frame parameter seam E5-graph's report-and-stop said the
        // §21.2 trait lacked, now added (fx-param-automation lane).
        //
        // ⚠️ READABLE BY KEY, not wholesale. `dsp::fx::fx_key_class` is the
        // one classification (derived from the same `FxParamSpec` tables
        // `load_block_targets` reads): a key every declaring kind applies with
        // arithmetic or a change-cached dB->lin conversion — the cost class
        // `Strip::vol_lane_lin` already pays per frame — has a reader; a key
        // whose application recomputes a filter or envelope COEFFICIENT
        // (`coeff_from_ms` is an `exp`; an EQ band retarget is RBJ trig) stays
        // refused, per key, for exactly the §6.1/§16.3 cost-cliff reason that
        // keeps `track.eq.*` out of this set. `bypass` stays refused because
        // it occupies no parameter slot at all (§23.5).
        //
        // This is a pure PATH function and cannot see which `FxKind` the fx id
        // resolves to; classifying by key is honest only while a shared key's
        // rate agrees across kinds (pinned by a test in `dsp::fx`). The
        // kind-aware half of the refusal — a lane naming a missing fx, a key
        // its kind does not declare, or (belt) a Block-rate spec — lives in
        // `compile::bake_fx_lanes`, where the project is in hand.
        K::TrackFxParam { param, .. }
        | K::BusFxParam { param, .. }
        | K::MasterFxParam { param, .. } => {
            crate::dsp::fx::fx_key_class(param) == crate::dsp::fx::FxKeyClass::Frame
        }
        K::Unrecognized => false,
    }
}

/// Why `path` has no render-side reader. One sentence per gap, so the refusal
/// tells the user what is actually missing instead of "unsupported".
pub fn lane_gap_reason(path: &str) -> &'static str {
    use timeline_core::ParamRefKind as K;
    let Ok(r) = timeline_core::ParamRef::parse(path) else {
        return "not a well-formed parameter path";
    };
    match r.kind() {
        K::TrackEq { .. } => {
            "the channel EQ retargets its RBJ coefficients at BLOCK boundaries \
             (`EqBank::retarget_band_checked`), and every piece of signal state in \
             this engine must advance per FRAME or the bounce stops being \
             bit-identical to the live callback. Automating a band means \
             recomputing its coefficients per frame — new DSP, with a cost cliff — \
             not wiring up an existing reader"
        }
        K::MasterGain | K::MasterLimiter { .. } => {
            "master parameters are GLOBAL, but an automation lane is stored per \
             (track, path), so two tracks can each carry a `master.*` lane and \
             nothing says which one wins. A master lane needs a session-scoped \
             lane table, which is a model decision, not a render one"
        }
        K::TrackFxParam { param, .. }
        | K::BusFxParam { param, .. }
        | K::MasterFxParam { param, .. } => match crate::dsp::fx::fx_key_class(param) {
            crate::dsp::fx::FxKeyClass::Frame => "has a reader",
            crate::dsp::fx::FxKeyClass::Coefficient => {
                "this key is a filter or envelope COEFFICIENT (an EQ band \
                 retarget is RBJ trig; attack/release exist only as one-pole \
                 coefficients, and `coeff_from_ms` is an `exp`). Every piece \
                 of signal state in this engine must advance per FRAME or the \
                 bounce stops being bit-identical to the live callback, and a \
                 per-frame coefficient recompute is the cost cliff that keeps \
                 the channel EQ out of this set — the same answer is given \
                 here for the same reason. Effect keys that apply with plain \
                 arithmetic (gains, thresholds, mix, pan and similar) DO \
                 automate, through the per-frame hook on the effect contract \
                 (`FxNode::set_frame_param`); this key is refused BY KEY, not \
                 because effects cannot automate. The effect and its \
                 parameters are stored and saved correctly. See \
                 DESIGN-E5-routing.md sections 6.1 and 16.3"
            }
            crate::dsp::fx::FxKeyClass::Bypass => {
                "`bypass` occupies NO parameter slot (DESIGN-E5-routing.md \
                 §23.5): it is a per-instance flag read once per block through \
                 `EngineParams::fx_bypassed` and declicked by the unit's own \
                 crossfade, and a lane on it would be a third spelling of one \
                 fact — the desync trap the design rejects. Toggle it with \
                 fx.param.set {\"key\": \"bypass\"}"
            }
            crate::dsp::fx::FxKeyClass::Unimplemented => {
                "no effect kind implements this parameter key (`division` is \
                 reserved vocabulary — tempo divisions resolve control-side), \
                 so there is nothing for a lane to drive"
            }
        },
        K::Unrecognized => "not a parameter this build knows",
        _ => "has a reader",
    }
}

/// Clips sorted by start_frame (compile guarantees it), plus the track's baked
/// automation lanes (frames at the engine rate).
///
/// The lanes are an INDEXED, PREALLOCATED TABLE, not named fields. Before E0 a
/// new automatable parameter needed four coordinated changes (a new AutoTarget
/// variant, a new lane FIELD here, a new atomic, a catalog change); now E2/E4/E8
/// add parameters without touching this struct. The slice is dense and every
/// track in a session has the same length, so a slot index means the same thing
/// on every track.
pub struct RtTrack {
    pub clips: Box<[RtClip]>,
    pub lanes: Box<[Option<AutoLane>]>,
    /// E1: the track's baked MIDI note events, sorted and preallocated, in
    /// ABSOLUTE session frames. Empty for a track with no note clips.
    ///
    /// A track is the instrument-node position in this build: `ParamRef`
    /// addresses `track.device.<deviceId>.<param>`, the device registry now
    /// exists, and `compile` binds ONE instrument device per track — so "per
    /// instrument node" and "per track" are still the same slice.
    pub notes: NoteLane,
    /// E1/E2 WIRING: the instrument this track's notes drive, or `None` for a
    /// plain audio track. `None` is what every pre-E2 session compiles to, so
    /// old projects are bit-for-bit unaffected.
    pub instrument: Option<Box<TrackInstrument>>,
}

impl RtTrack {
    /// Constant-time, bounds-checked slot read. The audio thread only ever
    /// reaches lanes this way — by INDEX, never by name.
    #[inline]
    pub fn lane(&self, slot: usize) -> Option<&AutoLane> {
        self.lanes.get(slot).and_then(Option::as_ref)
    }
}

/// One track's instrument, plus everything needed to drive it from the baked
/// note lane. Built control-side by `compile`, owned by the session snapshot,
/// mutated only by the audio thread.
///
/// # Why the cursor lives HERE and not on `Strip`
///
/// `Strip` is engine-lifetime state (preallocated at construction, survives
/// session swaps). A note cursor cannot live there: during a session-swap
/// crossfade the OLD session's instrument is still sounding and must keep
/// rendering its own notes for the 5 ms fade, so old and new need one cursor
/// EACH. Putting the cursor on the snapshot makes that free, and makes a
/// stale-cursor-after-swap bug structurally impossible — a new session brings a
/// new cursor at index 0 with nothing sounding.
///
/// # ⚠️ Two cursors would double-trigger — only ONE drives
///
/// There are two note cursors in this crate:
///
/// * E1's [`NoteCursor`] over [`NoteLane`] (`notes.rs`) — **this is the one the
///   engine drives.** It is the one `compile` bakes into, and it carries a
///   128-bit "which pitches are sounding" set so that ANY frame discontinuity
///   (loop fold, seek) releases every held pitch BEFORE re-anchoring. The
///   anti-stuck-note guarantee is structural in it.
/// * E2's `NoteSchedule` inside `InstrumentNode` (`dsp/note.rs`) — a pure
///   accelerator with no sounding set, which deliberately does NOT force-release
///   on a backward jump. Kept as `InstrumentNode`'s standalone unit-test driver.
///
/// A node installed on a track therefore MUST carry an EMPTY schedule, so
/// `InstrumentNode::render_frame` (which drains it) cannot fire a second copy of
/// every event. `TrackInstrument::new` asserts that, control-side.
pub struct TrackInstrument {
    /// The voice pool + DSP. Driven through `instrument_mut()`, never through
    /// `InstrumentNode::render_frame`, which would run E2's cursor as well.
    pub node: InstrumentNode,
    /// E1's cursor over `RtTrack::notes`.
    pub cursor: NoteCursor,
    /// The device's authored (static) parameter values, `Num -> f32` converted
    /// ONCE at compile time.
    pub base: InstrumentParams,
    /// Instrument param slot -> dense automation lane slot, resolved at compile
    /// time from `track.device.<deviceId>.<paramKey>`. `None` = not automated,
    /// so `base` stands. A fixed-size array: no lookup, no allocation.
    pub slots: [Option<u8>; INSTRUMENT_PARAM_COUNT],
    /// True when any slot is `Some`, so the common (un-automated) case skips
    /// the param scan entirely.
    pub automated: bool,
}

impl TrackInstrument {
    /// Control-side constructor. Panics if `node` carries a non-empty
    /// `NoteSchedule` — see the two-cursor warning above. This is a compile-time
    /// (control-thread) assertion; the audio thread never runs it.
    pub fn new(
        node: InstrumentNode,
        base: InstrumentParams,
        slots: [Option<u8>; INSTRUMENT_PARAM_COUNT],
    ) -> Self {
        assert!(
            node.schedule().is_empty(),
            "a track-installed InstrumentNode must have an EMPTY NoteSchedule: \
             the engine drives it from E1's NoteCursor over RtTrack::notes, and \
             running both cursors would trigger every note twice"
        );
        let automated = slots.iter().any(Option::is_some);
        Self {
            node,
            cursor: NoteCursor::new(),
            base,
            slots,
            automated,
        }
    }

    /// Release every sounding voice AND forget the cursor's sounding set,
    /// without emitting a second round of note-offs through it.
    ///
    /// THE anti-stuck-note lever. Called on every transport discontinuity:
    /// loop fold, seek, play, stop. Allocation-free, lock-free, no I/O — safe
    /// on the audio thread.
    #[inline]
    pub fn panic_notes(&mut self) {
        self.node.all_notes_off();
        // `reset` clears the sounding set WITHOUT emitting offs, which is
        // exactly right here: `all_notes_off` above already released those
        // voices, so emitting them again would double-release.
        self.cursor.reset();
    }
}

pub struct RtSession {
    pub tracks: Box<[RtTrack]>,
    /// ParamRef (verbatim wire string) -> dense lane slot, resolved at compile
    /// time. CONTROL-SIDE ONLY: the audio thread never touches it. It is
    /// carried on the snapshot so the host can answer "which slot is
    /// track.eq.2.gain in this session" without recompiling.
    pub lane_index: BTreeMap<String, usize>,
    /// Dense lane slot for `track.send.{a,b}.level`, resolved at compile time
    /// from `lane_index` — the same trick `TrackInstrument::slots` uses for
    /// device params, so the audio thread indexes and never looks up a string.
    /// `None` = this session automates no send on that bus, and the send level
    /// comes from the atomic exactly as before.
    ///
    /// Session-scoped rather than per-track because the slot table IS
    /// session-scoped: a slot index means the same thing on every track.
    pub send_lane_slots: [Option<u8>; 2],
    /// The baked routing evaluation order (design §5/§6.2). E0 delivered the
    /// ordering; E5-graph implements the evaluation that walks it. For a v1
    /// project this is `[Track(0), .., Track(n-1), LegacyReturns, Master]` —
    /// the pre-E5 topology, desugared (§2.1) and never written to the model.
    pub node_order: Box<[NodeStep]>,
    /// The baked graph the walk indexes into: edges, compensation rings, fx
    /// chains and node-fader lanes. `RtGraph::empty()` for a v1 project.
    pub graph: RtGraph,
}

/// Preallocated capture buffer, moved into the core by command and returned
/// through the capture channel when full. Records the master output exactly
/// as rendered (pre silence gate).
pub struct CaptureBuf {
    pub data: Box<[[f32; 2]]>,
    pub written: usize,
}

impl CaptureBuf {
    pub fn new(frames: usize) -> Self {
        Self {
            data: vec![[0.0; 2]; frames].into_boxed_slice(),
            written: 0,
        }
    }
}

/// Commands the render core executes at block boundaries. Everything heap-
/// shaped is allocated control-side and moved in.
pub enum RenderCommand {
    SetSession(Box<RtSession>),
    Play,
    Stop,
    Seek { frame: u64 },
    LoopSet { start_frame: u64, end_frame: u64 },
    LoopClear,
    /// Arm a capture; optionally reset to frame 0 and start playing in the
    /// same drain so captured frame 0 is exactly play frame 0 (the null-test
    /// alignment guarantee).
    CaptureStart {
        capture: CaptureBuf,
        start_transport: bool,
    },
    /// AUDITION a note on one track's instrument RIGHT NOW, outside the
    /// timeline. This is the piano-roll gutter key, a drawn note, and a MIDI
    /// keyboard key — feedback, never an edit: nothing here touches the note
    /// lane, the journal, or the transport, and the offline bounce never
    /// receives one of these, so a bounce stays bit-identical.
    ///
    /// `hold_frames == 0` means "held until an explicit `PreviewNoteOff`"
    /// (a MIDI key held down). Any non-zero value is a one-shot that releases
    /// itself after that many frames (a UI click, which has no key-up).
    PreviewNoteOn {
        track: usize,
        pitch: u8,
        velocity: f32,
        hint: u32,
        hold_frames: u64,
    },
    PreviewNoteOff {
        track: usize,
        hint: u32,
    },
    /// Arm an audible count-in of `beats` clicks at `period_frames` apart,
    /// starting on the next frame.
    ///
    /// A count-in sounds BEFORE the transport rolls, so unlike the metronome
    /// proper it cannot hang off `position`. It gets its own frame counter.
    /// Like `PreviewNoteOn` this is monitor feedback, never an edit: the
    /// offline bounce never receives one, and even if it did,
    /// `CoreConfig::monitor` is false there so nothing would reach the buffer.
    CountIn {
        beats: u32,
        period_frames: u64,
    },
    /// Cancel an armed count-in (the user hit record again, or stop).
    CountInCancel,
}

/// One live audition voice, tracked control-of-the-audio-thread side so a
/// one-shot releases itself and a held note can be released by hint.
///
/// Fixed-size table, no allocation: [`PREVIEW_VOICES`] slots, oldest-stolen.
#[derive(Clone, Copy)]
struct PreviewVoice {
    active: bool,
    track: usize,
    hint: u32,
    /// Frames left before the self-release; `u64::MAX` = held until an
    /// explicit off.
    left: u64,
    /// Monotonic age stamp, for deterministic oldest-first stealing.
    age: u64,
}

impl PreviewVoice {
    const IDLE: Self = Self {
        active: false,
        track: 0,
        hint: 0,
        left: 0,
        age: 0,
    };
}

/// How many notes can be auditioning at once. Ten fingers plus headroom; a
/// fixed array so the audio thread never allocates to sound a key.
pub const PREVIEW_VOICES: usize = 16;

/// Voice hints for auditions live in their own high range so they can never
/// collide with a baked note's hint (`voice_hint_for(note.id)`), which would
/// make one note's release steal another's voice.
pub const PREVIEW_HINT_BASE: u32 = 0xF000_0000;

/// Heap payloads leaving the render thread for the drop thread.
pub enum DropPayload {
    Session(Box<RtSession>),
    Capture(CaptureBuf),
}

pub struct CoreConfig {
    pub sample_rate: u32,
    pub max_tracks: usize,
    /// THE EXPORT FIREWALL.
    ///
    /// True only for a core that is driving a real output device. The
    /// metronome click is summed into the output buffer ONLY when this is set,
    /// which is what makes "the metronome is never in an exported mix" a
    /// structural property instead of a promise someone has to keep.
    ///
    /// `offline::ManualRenderer::new` — the constructor behind
    /// `render_offline`, `bounce_master`, `bounce_region`, the stem export and
    /// every deterministic test — hardcodes this false. There is no parameter,
    /// no command and no atomic that can turn it on for a bounce; a test that
    /// wants to hear the click must construct a monitoring renderer explicitly
    /// (`ManualRenderer::new_monitoring`).
    pub monitor: bool,
}

/// Limiter enable/disable is a latency change, so the core declicks around
/// it: fade the output down over the window, flip, fade back up.
#[derive(Debug, Clone, Copy)]
enum LimiterToggle {
    FadeOut { to_enabled: bool, left: u32 },
    FadeIn { left: u32 },
}

pub struct RenderCore {
    cfg: CoreConfig,
    session: Option<Box<RtSession>>,
    /// Outgoing session during a swap crossfade + frames left in the fade.
    old_session: Option<Box<RtSession>>,
    xfade_left: u32,
    /// Latest-wins slot for a swap that arrived mid-crossfade.
    pending_session: Option<Box<RtSession>>,
    position: u64,
    playing: bool,
    /// Transport declick gain (0..=1) and its target; linear ramp over
    /// MICRO_FADE_FRAMES. Gain-continuous under any command storm.
    transport_gain: f32,
    transport_target: f32,
    /// A seek that is waiting for the transport declick to reach silence.
    ///
    /// A seek WHILE PLAYING is a content discontinuity: the sample after the
    /// jump has nothing to do with the sample before it, so moving `position`
    /// at full gain steps the output by whatever the waveform happened to be —
    /// a full-scale click, once per seek. This used to set `transport_gain`
    /// straight to `0.0` and call that "landing in silence", but a hard step
    /// TO silence is the same click, and a UI that seeks repeatedly (a scrub)
    /// turns one click into a stream of them, which is a buzz, not a click.
    ///
    /// So the jump is DEFERRED behind the ramp that already exists: the target
    /// goes to 0, `transport_gain` glides down over MICRO_FADE_FRAMES, and the
    /// position moves on the frame it reaches exactly zero — where a content
    /// change is inaudible because there is no content. Latest-wins: a second
    /// seek arriving mid-fade replaces the destination without restarting the
    /// fade, so a command storm costs one fade, not one per command.
    ///
    /// `Play` and `Stop` LAND it immediately (see `drain_commands`): both are
    /// transport decisions that must not be undone five milliseconds later by
    /// a jump that re-arms playback.
    pending_seek: Option<u64>,
    loop_region: Option<(u64, u64)>,
    strips: Box<[Strip]>,
    // Per-block parameter targets (index-aligned with strips).
    track_gain_target: Box<[f32]>,
    track_pan_target: Box<[f32]>,
    track_send_a_target: Box<[f32]>,
    track_send_b_target: Box<[f32]>,
    /// §3.3: the mute/solo gate WITHOUT the fader, for the pre tap.
    track_gate_target: Box<[f32]>,
    // ---- E5 routing graph state, ALL preallocated in `new` from CoreConfig
    // and never resized per session (§4.1). ----
    /// One summing point per node in `routing_rt`'s flat slot space.
    node_acc: Box<[[f32; 2]]>,
    /// Per-node fader glide, `MAX_ROUTE_NODES` long.
    node_gain: Box<[Slew]>,
    node_gain_target: Box<[f32]>,
    /// Node-fader automation fast path: cache the last evaluated dB so the
    /// `powf` only runs when the lane value actually moved — the same cache
    /// `Strip::vol_lane_lin` uses, for the same measured reason.
    node_gain_last_db: Box<[f32]>,
    node_gain_last_lin: Box<[f32]>,
    /// Per-edge level glide, `MAX_ROUTE_EDGES` long.
    edge_level: Box<[Slew]>,
    edge_level_target: Box<[f32]>,
    /// Per-node lane cursor for `bus.<id>.gain` (§6.5). One `usize` per node,
    /// fixed size: the audio thread never allocates to read a lane.
    node_lane_cursor: Box<[usize]>,
    // Block-local node meter accumulation, flushed in the block epilogue
    // exactly like `Strip::take_block_meters` (§8 — never a per-frame atomic).
    node_peak_l: Box<[f32]>,
    node_peak_r: Box<[f32]>,
    node_sumsq: Box<[f32]>,
    master_gain: Slew,
    return_a: Slew,
    return_b: Slew,
    reverb: ReverbBus,
    delay: DelayBus,
    limiter: Limiter,
    limiter_engaged: bool,
    limiter_toggle: Option<LimiterToggle>,
    toggle_mute: f32,
    master_tp: TruePeakDetector,
    // Master block meter accumulation.
    master_peak_l: f32,
    master_peak_r: f32,
    master_sumsq: f32,
    master_block_tp: f32,
    // Block-local stereo-correlation accumulators (sum L*R, L*L, R*R). A meter
    // only: it reads the master frame that is already computed and never alters
    // a sample. Published once per block as a normalized phase-correlation
    // coefficient in [-1, 1] (mono = +1, out-of-phase = -1).
    master_sum_lr: f32,
    master_sum_ll: f32,
    master_sum_rr: f32,
    params: Arc<crate::params::EngineParams>,
    meters: Arc<MeterBank>,
    commands: Receiver<RenderCommand>,
    drop_tx: Sender<DropPayload>,
    capture_tx: Sender<CaptureBuf>,
    meter_tx: Option<Sender<[f32; 2]>>,
    capture: Option<CaptureBuf>,
    stats: Arc<EngineStats>,
    /// Scratch for one frame's note boundaries, PREALLOCATED at construction
    /// and reused by every track on every frame. `FrameEvents` is fixed size
    /// (256 events: a full 128-pitch release plus the events authored at one
    /// frame), so the audio thread never allocates to dispatch notes.
    note_events: FrameEvents,
    /// Live audition voices (piano-roll key, drawn note, MIDI keyboard).
    /// Fixed size, preallocated; see [`PreviewVoice`].
    preview: [PreviewVoice; PREVIEW_VOICES],
    /// How many `preview` slots are active. Kept as a counter so the hot path
    /// tests one `usize` per frame instead of scanning the table, and so the
    /// instrument render gate below is a single comparison.
    preview_active: usize,
    /// Monotonic stamp for deterministic oldest-first voice stealing.
    preview_age: u64,
    // ---- metronome (monitor path only; see `CoreConfig::monitor`) ----
    /// Beat clock + click voice. Fixed size, `Copy`, allocated once here: the
    /// audio thread never allocates to click.
    metronome: Metronome,
    /// Grid the metronome is currently configured for, so the per-block
    /// `set_config` only runs when the project's tempo/anchor actually moved
    /// (a config change forces a grid resync, which we must not do every
    /// block).
    metronome_cfg: MetroConfig,
    /// Frames left in an armed count-in, and the free-running counter that
    /// clocks it. A count-in sounds BEFORE the transport rolls, so it cannot
    /// be driven by `position`; it gets its own counter, advanced per FRAME
    /// like everything else here.
    count_in_left: u32,
    count_in_frames: u64,
    /// Frames per count-in beat, resolved control-side from the same tempo map
    /// the click grid uses.
    count_in_period: u64,
}

/// Ramp step per frame for the 5 ms declick (linear domain).
const TRANSPORT_STEP: f32 = 1.0 / MICRO_FADE_FRAMES as f32;

/// Clip envelope gain at relative frame `rel` (0-based inside the clip).
#[inline]
fn clip_fade_gain(clip: &RtClip, rel: u64) -> f32 {
    let mut gain = 1.0_f32;
    let fade_in = clip.fade_in_frames.min(clip.len_frames);
    if fade_in > 0 && rel < fade_in {
        let x = rel as f32 / fade_in as f32;
        gain *= match clip.fade_in_shape {
            FadeShape::Linear => x,
            FadeShape::EqualPower => (x * std::f32::consts::FRAC_PI_2).sin(),
        };
    }
    let fade_out = clip.fade_out_frames.min(clip.len_frames);
    if fade_out > 0 {
        let from_end = clip.len_frames - rel;
        if from_end <= fade_out {
            let x = from_end as f32 / fade_out as f32;
            gain *= match clip.fade_out_shape {
                FadeShape::Linear => x,
                FadeShape::EqualPower => (x * std::f32::consts::FRAC_PI_2).sin(),
            };
        }
    }
    gain
}

/// Sum every clip overlapping `position` on one track (sorted clips, early
/// break past the position). Returns true in .1 when a clip referenced
/// audio that was not resident (fault -> underrun counter).
#[inline]
fn sum_clips(track: &RtTrack, position: u64) -> ([f32; 2], bool) {
    let mut sum = [0.0_f32; 2];
    let mut fault = false;
    for clip in track.clips.iter() {
        if clip.start_frame > position {
            break;
        }
        if position < clip.end_frame() {
            let rel = position - clip.start_frame;
            let src_idx = (clip.offset_frames + rel) as usize;
            match clip.audio.samples.get(src_idx) {
                Some(sample) => {
                    let g = clip.gain_lin * clip_fade_gain(clip, rel);
                    sum[0] += sample[0] * g;
                    sum[1] += sample[1] * g;
                }
                None => fault = true,
            }
        }
    }
    (sum, fault)
}

/// Advance ONE track's instrument by exactly one frame at absolute session
/// frame `position`, and return its stereo contribution. `[0.0, 0.0]` when the
/// track has no instrument.
///
/// Everything here advances per FRAME — the note cursor, the parameter reads,
/// every voice and every ramp. There is no block-rate path, which is what keeps
/// a bounce with an instrument playing bit-identical at any block size.
///
/// `panic_first` is set on a transport discontinuity (loop fold). The cursor
/// would catch it too — it releases every sounding pitch on any non-contiguous
/// frame — but the belt AND the braces are deliberate: a stuck note is the
/// worst failure mode in this epic, and `all_notes_off` sweeps the voice pool
/// itself rather than trusting that every held voice is still reachable by the
/// `voice_hint` the cursor remembers (voice stealing can retire a hint).
///
/// Zero allocation, zero locks, zero I/O: `events` is a caller-owned fixed
/// buffer, the lane reads are constant-index cursor reads, and the voice pool
/// is preallocated.
#[inline]
fn render_instrument_frame(
    track: &mut RtTrack,
    strip: &mut Strip,
    position: u64,
    events: &mut FrameEvents,
    panic_first: bool,
) -> [f32; 2] {
    let RtTrack {
        notes,
        instrument,
        lanes,
        ..
    } = track;
    let Some(ti) = instrument.as_mut() else {
        return [0.0, 0.0];
    };
    if panic_first {
        ti.panic_notes();
    }

    // Parameter targets for THIS frame: authored value, overridden by the
    // automation lane where one exists. Same dense-slot path as volume/pan
    // (`Strip::lane_value`), so instrument params automate for free.
    let mut p = ti.base;
    if ti.automated {
        for slot_idx in 0..INSTRUMENT_PARAM_COUNT {
            if let Some(slot) = ti.slots[slot_idx] {
                let slot = slot as usize;
                let lane = lanes.get(slot).and_then(Option::as_ref);
                let v = strip.lane_value(lane, slot, position, p.get(slot_idx));
                p.set(slot_idx, v);
            }
        }
    }

    // Note boundaries FIRST, then render: a note-on at frame F is audible at
    // frame F, and a note-off at F stops contributing from F.
    ti.cursor.advance(notes, position, events);
    let inst = ti.node.instrument_mut();
    for e in events.as_slice() {
        if e.on {
            inst.note_on(e.pitch, e.velocity, e.voice_hint, &p);
        } else {
            inst.note_off(e.voice_hint);
        }
    }
    inst.render_frame(&p)
}

/// Render ONE frame of a track's instrument for an AUDITION while the
/// transport is stopped.
///
/// Deliberately NOT `render_instrument_frame`: it must not advance the note
/// cursor. While stopped, `position` never changes, so advancing the cursor to
/// the same frame on every callback is a frame discontinuity every time — the
/// cursor would dutifully release every sounding pitch, and the auditioned note
/// would be cut dead within a block. It reads the AUTHORED params (`base`), not
/// the automation lanes: with the transport stopped there is no meaningful
/// playhead to read a lane at.
#[inline]
fn render_preview_frame(track: &mut RtTrack) -> [f32; 2] {
    let Some(ti) = track.instrument.as_mut() else {
        return [0.0, 0.0];
    };
    let p = ti.base;
    ti.node.instrument_mut().render_frame(&p)
}

/// One track strip's contribution for ONE frame.
///
/// `x` is `Tap::Post` and `pre` is `Tap::Pre` (§3.1/§3.2). They are returned
/// separately rather than mixed here because an edge chooses between them and
/// the choice is per edge, not per strip.
pub struct StripFrame {
    /// `Tap::Post` — post-fader, post-pan, **post-EQ**. Byte-identical to the
    /// pre-E5 `x`, which is what makes §12.2's null gate provable.
    pub x: [f32; 2],
    /// `Tap::Pre` — post-pan, **PRE-EQ**, pre-fader, gated by mute and solo.
    ///
    /// ⚠️ **A pre-fader send does not carry the channel EQ, deliberately**
    /// (§3.2). The three candidates that would have carried it were all
    /// rejected with a reason: dividing by the fader explodes the instant the
    /// track is mutes; reordering the strip so the EQ runs before the fader
    /// changes the legacy signal path (a biquad commutes with a constant gain
    /// but not with a ramping one, and `g` is a `Slew`); and a second
    /// `EqBank` per strip doubles the filter state and cost of all 64 strips.
    /// The third is the documented upgrade path. **This divergence is pinned
    /// by a test on purpose — do not "fix" it.**
    pub pre: [f32; 2],
    pub send_a: f32,
    pub send_b: f32,
    pub fault: bool,
}

/// Arguments to [`render_track_frame`]. A struct rather than eighteen
/// positional parameters, so a caller cannot transpose two `f32`s silently.
pub struct TrackFrameArgs<'a> {
    pub strip: &'a mut Strip,
    pub new_track: Option<&'a mut RtTrack>,
    pub old_track: Option<&'a mut RtTrack>,
    /// This track's insert chain, already sliced.
    pub fx: &'a mut [crate::routing_rt::RtFx],
    pub node_acc: &'a [[f32; 2]],
    pub events: &'a mut FrameEvents,
    pub position: u64,
    pub folded: bool,
    pub playing: bool,
    pub transport_gain: f32,
    pub preview_active: usize,
    pub xfade_t: f32,
    /// Audio routed INTO this strip by an edge, summed at the clip layer.
    pub inject: [f32; 2],
    pub gain_target: f32,
    pub gate_target: f32,
    pub pan_target: f32,
    pub send_a_atomic: f32,
    pub send_b_atomic: f32,
    pub send_slots: [Option<u8>; 2],
}

/// ONE track strip, ONE frame: clip sum + instrument -> insert chain -> fader,
/// pan, EQ -> the two taps.
///
/// This is the pre-E5 strip body, moved out of the loop verbatim so the graph
/// walk can call it from two places (a scheduled track, and a retiring track
/// the new schedule does not mention) without duplicating the arithmetic. The
/// only additions are `inject` (which is `[0.0, 0.0]` unless an edge targets
/// this strip), the insert chain (empty unless the track has fx), and `pre`
/// (computed but not mixed anywhere unless a `Tap::Pre` edge reads it) — so
/// for a v1 project every added term is an exact identity.
#[inline]
fn render_track_frame(a: TrackFrameArgs<'_>) -> StripFrame {
    let TrackFrameArgs {
        strip,
        new_track,
        old_track,
        fx,
        node_acc,
        events,
        position,
        folded,
        playing,
        transport_gain,
        preview_active,
        xfade_t,
        inject,
        gain_target,
        gate_target,
        pan_target,
        send_a_atomic,
        send_b_atomic,
        send_slots,
    } = a;
    let mut fault = false;

    // Clip layer: new and (during a crossfade) old session sums.
    //
    // The INSTRUMENT sums in HERE, at the clip layer, and not after the strip:
    // that is what makes an instrument inherit the 5 ms transport declick, the
    // session-swap crossfade and the strip's gain/pan/EQ automation for free.
    // Summing after the strip would bypass all three.
    let mut clip_sum = [0.0_f32; 2];
    let mut new_track = new_track;
    if playing && transport_gain > 0.0 {
        if let Some(track) = new_track.as_deref_mut() {
            let (sum, f) = sum_clips(track, position);
            let inst = render_instrument_frame(track, strip, position, events, folded);
            let sum = [sum[0] + inst[0], sum[1] + inst[1]];
            if xfade_t >= 1.0 {
                clip_sum = sum;
            } else {
                clip_sum[0] = sum[0] * xfade_t;
                clip_sum[1] = sum[1] * xfade_t;
            }
            fault |= f;
        }
        if xfade_t < 1.0 {
            if let Some(track) = old_track {
                let (sum, f) = sum_clips(track, position);
                // The outgoing session's instrument keeps sounding through the
                // crossfade — its voices are real audio and cutting them dead
                // would be a click on every edit. It has its OWN cursor (on the
                // snapshot), so this costs nothing but the render.
                let inst = render_instrument_frame(track, strip, position, events, folded);
                clip_sum[0] += (sum[0] + inst[0]) * (1.0 - xfade_t);
                clip_sum[1] += (sum[1] + inst[1]) * (1.0 - xfade_t);
                fault |= f;
            }
        }
        clip_sum[0] *= transport_gain;
        clip_sum[1] *= transport_gain;
    } else if preview_active > 0 {
        // STOPPED, but a note is auditioning. Render the instrument ALONE: no
        // `sum_clips` (the timeline is not playing), no cursor advance (the
        // position is stationary, and a cursor re-anchored on the same frame
        // every frame would release every voice), no `transport_gain` (which is
        // 0 while stopped, and would silence the very thing we came to hear).
        // It still feeds the strip below, so an audition obeys the track's
        // gain, pan, mute and EQ exactly as playback does.
        if let Some(track) = new_track.as_deref_mut() {
            clip_sum = render_preview_frame(track);
        }
    }
    // Audio arriving over an edge lands PRE-FADER, at the clip layer, for the
    // same reason the instrument does. Exactly `[0.0, 0.0]` for every project
    // with no bus->track edge, so this is an identity on the legacy path.
    if inject != [0.0, 0.0] {
        clip_sum[0] += inject[0];
        clip_sum[1] += inject[1];
    }

    // §16.7: the insert chain runs BEFORE the fader, which is where an insert
    // belongs and which keeps `Tap::Post`'s definition (post-fader, post-pan,
    // post-EQ) exactly as §3.1 froze it. An empty chain is a no-op.
    let clip_sum = run_fx_chain(fx, node_acc, position, clip_sum);

    // Automation targets come from the CURRENT session's lanes, read BY SLOT
    // INDEX. Volume and pan are fixed slots so this stays a constant-index
    // array read on the hot path.
    //
    // The two send levels ride the SAME table through the general
    // `Strip::lane_value` reader, with the atomic as the default — exactly how
    // an instrument device param overrides its authored `base`. A track with no
    // send lane therefore reads the atomic and renders bit-identically to
    // before this reader existed.
    let t = new_track.as_deref();
    let vol_lane = t.and_then(|t| t.lane(LANE_VOLUME));
    let pan_lane = t.and_then(|t| t.lane(LANE_PAN));
    let send_a_lane = t.and_then(|t| send_slots[SEND_A].and_then(|s| t.lane(s as usize)));
    let send_b_lane = t.and_then(|t| send_slots[SEND_B].and_then(|s| t.lane(s as usize)));

    let vol_auto = strip.vol_lane_lin(vol_lane, position);
    let gain_target = gain_target * vol_auto;
    let g = strip.gain.advance(gain_target);

    let pan_auto = strip.pan_lane_value(pan_lane, position);
    let pan_target = (pan_target + pan_auto).clamp(-1.0, 1.0);
    let (gl, gr) = strip.pan_gains(pan_target);

    // §3.2/§3.3: the pre tap is post-pan, PRE-EQ, pre-fader, and gated by mute
    // and solo through its OWN 5 ms `Slew`.
    //
    // ⚠️ `strip.gate` is deliberately NOT folded into `strip.gain`. Floating
    // point multiplication is not associative, so rewriting the post path as a
    // product of two slews would change its low bit and take the legacy-null
    // gate red. Two independent slews; the post path's arithmetic below is
    // untouched, byte for byte.
    let gate = strip.gate.advance(gate_target);
    let pre = [clip_sum[0] * gl * gate, clip_sum[1] * gr * gate];

    let mut x = [clip_sum[0] * g * gl, clip_sum[1] * g * gr];
    strip.eq.process_frame(&mut x);

    // Send level: the lane OVERRIDES the fader's atomic when one exists, and
    // the atomic is the default when it does not — the absolute-value
    // convention `render_instrument_frame` already uses for device params, not
    // volume's dB-offset one. An absolute level is the only convention that
    // makes the reported gesture work: a 0->1 ramp drawn on a send whose fader
    // sits at 0 must sweep the send, and an offset convention would multiply
    // (or add to) zero and stay silent -- the same bug, respelled.
    //
    // Clamped to the range `mix.send` and `set_track_send` clamp to, so a drawn
    // point cannot push a send somewhere the fader cannot go (a negative level
    // would flip polarity into the bus).
    let sa_target = strip
        .lane_value(
            send_a_lane,
            send_slots[SEND_A].unwrap_or(0) as usize,
            position,
            send_a_atomic,
        )
        .clamp(0.0, 1.0);
    let send_a = strip.send_a.advance(sa_target);
    let sb_target = strip
        .lane_value(
            send_b_lane,
            send_slots[SEND_B].unwrap_or(0) as usize,
            position,
            send_b_atomic,
        )
        .clamp(0.0, 1.0);
    let send_b = strip.send_b.advance(sb_target);

    StripFrame {
        x,
        pre,
        send_a,
        send_b,
        fault,
    }
}

/// Run one insert chain over ONE frame, in `Vec` order (§16.7).
///
/// `key` is the sidechain input (§17.3): the source node's accumulator AT THIS
/// FRAME, which the schedule guarantees was written earlier in this same frame
/// because `Project::sidechain_links` fed `Routing::schedule`. An unkeyed
/// effect is passed its own input, which is what `FxNode` specifies.
///
/// **The fx-lane reader lives here and is PER FRAME.** Every automated
/// parameter binding on the unit (`RtFx::lanes`, baked by
/// `compile::bake_fx_lanes`) is evaluated at `position` and applied through
/// `FxNode::set_frame_param` BEFORE this frame's `process_frame`, so the value
/// a frame renders is the lane's value at that frame no matter how frames are
/// chunked into blocks — the §6.1 rule, and the reason the bounce stays
/// bit-identical at 128/417/480/512 with fx automation live. Applying these at
/// block boundaries instead is precisely the defect `lane_has_reader` exists
/// to refuse. The lane OVERRIDES the parameter atomic while it exists (the
/// block loader's value is re-written before any frame renders), the same
/// convention the send and node-fader readers use.
///
/// Allocation-free: `value_at` is a cursor walk over a baked slice, and
/// `set_frame_param` is arithmetic (plus a change-gated dB conversion) by
/// trait contract.
#[inline]
fn run_fx_chain(
    fx: &mut [crate::routing_rt::RtFx],
    node_acc: &[[f32; 2]],
    position: u64,
    mut x: [f32; 2],
) -> [f32; 2] {
    for f in fx.iter_mut() {
        let crate::routing_rt::RtFx {
            unit, key_src, lanes, ..
        } = f;
        for al in lanes.iter_mut() {
            let v = al.lane.value_at(position, &mut al.cursor);
            unit.set_frame_param(al.param_index as usize, v);
        }
        let key = match key_src {
            Some(slot) => node_acc.get(*slot as usize).copied().unwrap_or([0.0, 0.0]),
            None => x,
        };
        x = unit.process_frame(x, key);
    }
    x
}

/// Push one node's output down its out-edges (§6.4).
///
/// `lane_value(slot, default)` resolves an edge-level automation lane; callers
/// with no lane table (a bus source — §6.5 defers bus->bus edge automation)
/// pass `|_, d| d`.
#[allow(clippy::too_many_arguments)]
#[inline]
fn push_edges(
    edges: &[RtEdge],
    comp_rings: &mut [crate::routing_rt::CompDelay],
    range: (usize, usize),
    post: [f32; 2],
    pre: [f32; 2],
    edge_level: &mut [Slew],
    edge_level_target: &[f32],
    node_acc: &mut [[f32; 2]],
    mut lane_value: impl FnMut(usize, f32) -> f32,
) {
    for i in range.0..range.1 {
        let Some(e) = edges.get(i).copied() else {
            continue;
        };
        let src = if e.tap == timeline_core::routing::Tap::Post {
            post
        } else {
            pre
        };
        // The implicit unity master feed and the two legacy returns carry no
        // atomic. Unity is a plain `+=`, never `* 1.0`: identical bits, one
        // fewer multiply, and no dependence on a slot that does not exist.
        let mut v = if e.level_slot == IMPLICIT_UNITY {
            src
        } else {
            let slot = e.level_slot as usize;
            let target = match e.level_lane {
                NO_LANE => edge_level_target.get(slot).copied().unwrap_or(0.0),
                lane => lane_value(
                    lane as usize,
                    edge_level_target.get(slot).copied().unwrap_or(0.0),
                )
                .clamp(MIN_EDGE_LEVEL, MAX_EDGE_LEVEL),
            };
            let lv = match edge_level.get_mut(slot) {
                Some(s) => s.advance(target),
                None => 0.0,
            };
            [src[0] * lv, src[1] * lv]
        };
        // §19.3: a zero-frame compensation is a bit-exact PASSTHROUGH, not a
        // ring read at offset 0. This is what lets the legacy-null gate run
        // *through* the PDC code path and still produce identical bytes.
        if e.comp != 0 {
            if let Some(ring) = comp_rings.get_mut(i) {
                v = ring.process_frame(v);
            }
        }
        let dest = e.dest as usize;
        if let Some(acc) = node_acc.get_mut(dest) {
            acc[0] += v[0];
            acc[1] += v[1];
        }
    }
}

/// Block-local node meter accumulation (§8). Never a per-frame atomic write —
/// the flush happens once per block in the epilogue, the same pattern
/// `Strip::take_block_meters` uses.
#[inline]
fn accumulate_node_meter(
    peak_l: &mut [f32],
    peak_r: &mut [f32],
    sumsq: &mut [f32],
    slot: usize,
    v: [f32; 2],
) {
    if slot >= peak_l.len() {
        return;
    }
    let al = v[0].abs();
    let ar = v[1].abs();
    if al > peak_l[slot] {
        peak_l[slot] = al;
    }
    if ar > peak_r[slot] {
        peak_r[slot] = ar;
    }
    sumsq[slot] += v[0] * v[0] + v[1] * v[1];
}

impl RenderCore {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        cfg: CoreConfig,
        params: Arc<crate::params::EngineParams>,
        meters: Arc<MeterBank>,
        commands: Receiver<RenderCommand>,
        drop_tx: Sender<DropPayload>,
        capture_tx: Sender<CaptureBuf>,
        meter_tx: Option<Sender<[f32; 2]>>,
        stats: Arc<EngineStats>,
    ) -> Self {
        let max_tracks = cfg.max_tracks;
        let sample_rate = cfg.sample_rate;
        let step = 1.0 / RAMP_FRAMES as f32;
        // The click's fixed-size state is built HERE, once, like every other
        // piece of RT state — the audio thread never allocates to click.
        let boot_metro = params.metronome_config(sample_rate);
        Self {
            cfg,
            session: None,
            old_session: None,
            xfade_left: 0,
            pending_session: None,
            position: 0,
            playing: false,
            transport_gain: 0.0,
            transport_target: 0.0,
            pending_seek: None,
            loop_region: None,
            strips: (0..max_tracks)
                .map(|_| Strip::new(sample_rate, RAMP_FRAMES))
                .collect(),
            track_gain_target: vec![1.0; max_tracks].into_boxed_slice(),
            track_pan_target: vec![0.0; max_tracks].into_boxed_slice(),
            track_send_a_target: vec![0.0; max_tracks].into_boxed_slice(),
            track_send_b_target: vec![0.0; max_tracks].into_boxed_slice(),
            track_gate_target: vec![1.0; max_tracks].into_boxed_slice(),
            node_acc: vec![[0.0; 2]; crate::routing_rt::node_acc_len(max_tracks)]
                .into_boxed_slice(),
            node_gain: vec![Slew::new(1.0, step); MAX_ROUTE_NODES].into_boxed_slice(),
            node_gain_target: vec![1.0; MAX_ROUTE_NODES].into_boxed_slice(),
            node_gain_last_db: vec![0.0; MAX_ROUTE_NODES].into_boxed_slice(),
            node_gain_last_lin: vec![1.0; MAX_ROUTE_NODES].into_boxed_slice(),
            edge_level: vec![Slew::new(0.0, step); MAX_ROUTE_EDGES].into_boxed_slice(),
            edge_level_target: vec![0.0; MAX_ROUTE_EDGES].into_boxed_slice(),
            node_lane_cursor: vec![0_usize; MAX_ROUTE_NODES].into_boxed_slice(),
            node_peak_l: vec![0.0; crate::stats::NODE_METER_SLOTS].into_boxed_slice(),
            node_peak_r: vec![0.0; crate::stats::NODE_METER_SLOTS].into_boxed_slice(),
            node_sumsq: vec![0.0; crate::stats::NODE_METER_SLOTS].into_boxed_slice(),
            master_gain: Slew::new(1.0, step),
            return_a: Slew::new(1.0, step),
            return_b: Slew::new(1.0, step),
            reverb: ReverbBus::new(sample_rate, RAMP_FRAMES),
            delay: DelayBus::new(sample_rate, params.delay_tap_frames(), RAMP_FRAMES),
            limiter: Limiter::new(),
            limiter_engaged: false,
            limiter_toggle: None,
            toggle_mute: 1.0,
            master_tp: TruePeakDetector::new(),
            master_peak_l: 0.0,
            master_peak_r: 0.0,
            master_sumsq: 0.0,
            master_block_tp: 0.0,
            master_sum_lr: 0.0,
            master_sum_ll: 0.0,
            master_sum_rr: 0.0,
            params,
            meters,
            commands,
            drop_tx,
            capture_tx,
            meter_tx,
            capture: None,
            stats,
            note_events: FrameEvents::new(),
            preview: [PreviewVoice::IDLE; PREVIEW_VOICES],
            preview_active: 0,
            preview_age: 0,
            metronome: Metronome::new(boot_metro),
            metronome_cfg: boot_metro,
            count_in_left: 0,
            count_in_frames: 0,
            count_in_period: 0,
        }
    }

    /// Hand a payload to the drop thread without freeing here. Full queue =
    /// deliberate leak, counted (DJ defer_drop with the print hazard fixed).
    #[inline]
    fn defer_drop(&self, payload: DropPayload) {
        if let Err(err) = self.drop_tx.try_send(payload) {
            let leaked = err.into_inner();
            self.stats.leaked_buffers.fetch_add(1, Ordering::Relaxed);
            std::mem::forget(leaked);
        }
    }

    /// Install a new session snapshot. First session snaps strip glides to
    /// their targets (nothing was audible before); later swaps crossfade at
    /// the clip-sum layer; a swap during a crossfade parks in the pending
    /// slot (latest wins).
    fn install_session(&mut self, mut new_session: Box<RtSession>) {
        // Settle every instrument ramp on install so a fresh node does not
        // glide in from its constructor default — the exact mirror of
        // `strip.gain.snap(...)` below. Cheap (a handful of `Slew::snap`s per
        // track), allocation-free, and it happens at a block boundary.
        //
        // It snaps to the AUTHORED (`base`) values, not to frame-0 automation,
        // for the same reason the strip snaps to the atomic target and not to
        // the volume lane: automation then ramps in over the 5 ms declick
        // window like every other parameter move.
        for track in new_session.tracks.iter_mut() {
            if let Some(ti) = track.instrument.as_mut() {
                let base = ti.base;
                ti.node.snap_to(&base);
            }
        }
        // Same act for the effect chain: an fx installed already bypassed must
        // start bypassed rather than crossfade in from "active" over the first
        // 5 ms. `snap_bypass` uses the target `load_block_targets` will read,
        // so the first block reads the same atomic this settles to.
        for f in new_session.graph.fx.iter_mut() {
            f.unit
                .load_block_targets(&self.params, base_slot_of(f.fx_slot as usize));
            f.unit.snap_bypass();
        }
        match self.session.take() {
            None => {
                let count = new_session.tracks.len().min(self.cfg.max_tracks);
                let node_count = new_session.graph.node_count;
                let edge_count = new_session.graph.edge_level_count;
                self.session = Some(new_session);
                self.load_block_targets(count);
                for idx in 0..count {
                    let strip = &mut self.strips[idx];
                    strip.gain.snap(self.track_gain_target[idx]);
                    strip.gate.snap(self.track_gate_target[idx]);
                    strip.pan.snap(self.track_pan_target[idx]);
                    strip.send_a.snap(self.track_send_a_target[idx]);
                    strip.send_b.snap(self.track_send_b_target[idx]);
                }
                // Nothing was audible before the first session, so the graph
                // glides settle too — a bus fader must not ramp up from
                // silence on the first block of a project that has one.
                for slot in 0..node_count.min(MAX_ROUTE_NODES) {
                    let t = self.params.node_gain_target(slot);
                    self.node_gain_target[slot] = t;
                    self.node_gain[slot].snap(t);
                }
                for slot in 0..edge_count.min(MAX_ROUTE_EDGES) {
                    let t = self.params.edge_level_target(slot);
                    self.edge_level_target[slot] = t;
                    self.edge_level[slot].snap(t);
                }
                self.master_gain.snap(self.params.master_gain_target());
                self.return_a.snap(self.params.return_target(false));
                self.return_b.snap(self.params.return_target(true));
            }
            Some(current) => {
                if self.xfade_left > 0 {
                    // Mid-crossfade: keep fading to `current`, park the
                    // newest (replacing any parked one).
                    self.session = Some(current);
                    if let Some(displaced) = self.pending_session.replace(new_session) {
                        self.defer_drop(DropPayload::Session(displaced));
                    }
                } else {
                    let old_count = current.tracks.len().min(self.cfg.max_tracks);
                    let new_count = new_session.tracks.len().min(self.cfg.max_tracks);
                    self.old_session = Some(current);
                    self.session = Some(new_session);
                    self.xfade_left = RAMP_FRAMES;
                    // Snap smoothers ONLY for newly visible track indices so
                    // they do not glide in from stale values.
                    let any_solo = self.params.any_solo(new_count);
                    for idx in old_count..new_count {
                        let strip = &mut self.strips[idx];
                        strip.gain.snap(self.params.track_gain_target(idx, any_solo));
                        strip.gate.snap(self.params.track_gate_target(idx, any_solo));
                        strip.pan.snap(self.params.track_pan_target(idx));
                        strip.send_a.snap(self.params.track_send_target(idx, false));
                        strip.send_b.snap(self.params.track_send_target(idx, true));
                    }
                }
            }
        }
    }

    /// Release every sounding voice on EVERY live instrument (current session
    /// and, during a swap crossfade, the outgoing one) and reset their note
    /// cursors.
    ///
    /// This is the transport half of the no-stuck-note guarantee. The loop-fold
    /// half is per frame, inside `render`, because a fold is transport state
    /// (`RenderCommand::LoopSet`) that is unknown at compile time and can change
    /// without recompiling — so a wrap note-off CANNOT be baked.
    ///
    /// Allocation-free: an iteration over preallocated slices.
    fn panic_all_notes(&mut self) {
        for session in [self.session.as_mut(), self.old_session.as_mut()]
            .into_iter()
            .flatten()
        {
            for track in session.tracks.iter_mut() {
                if let Some(ti) = track.instrument.as_mut() {
                    ti.panic_notes();
                }
            }
        }
        // `panic_notes` swept the voice POOL, so every auditioning voice is
        // already released. Forgetting the bookkeeping here would leave
        // `preview_active` non-zero forever, which holds the instrument render
        // gate open for the rest of the session — a silent CPU leak and a
        // stuck-note report waiting to happen.
        self.preview = [PreviewVoice::IDLE; PREVIEW_VOICES];
        self.preview_active = 0;
    }

    /// Start an audition voice on `track`'s instrument. Allocation-free: a
    /// scan of a fixed 16-slot array, stealing the oldest when full.
    fn preview_note_on(
        &mut self,
        track: usize,
        pitch: u8,
        velocity: f32,
        hint: u32,
        hold_frames: u64,
    ) {
        // No instrument on that track = nothing to sound. Bail BEFORE taking a
        // slot, so the render gate is never held open by a voice that can make
        // no sound.
        let Some(ti) = self
            .session
            .as_mut()
            .and_then(|s| s.tracks.get_mut(track))
            .and_then(|t| t.instrument.as_mut())
        else {
            return;
        };
        let base = ti.base;
        ti.node.instrument_mut().note_on(pitch, velocity, hint, &base);

        self.preview_age = self.preview_age.wrapping_add(1);
        let slot = match self.preview.iter().position(|v| !v.active) {
            Some(free) => free,
            None => {
                // Full: steal the oldest and release its voice first, so the
                // stolen note cannot hang.
                let (oldest, _) = self
                    .preview
                    .iter()
                    .enumerate()
                    .min_by_key(|(_, v)| v.age)
                    .map(|(i, v)| (i, v.age))
                    .unwrap_or((0, 0));
                let stolen = self.preview[oldest];
                self.release_preview(stolen.track, stolen.hint);
                self.preview[oldest] = PreviewVoice::IDLE;
                self.preview_active -= 1;
                oldest
            }
        };
        self.preview[slot] = PreviewVoice {
            active: true,
            track,
            hint,
            left: if hold_frames == 0 {
                u64::MAX
            } else {
                hold_frames
            },
            age: self.preview_age,
        };
        self.preview_active += 1;
    }

    /// Release the audition voice matching `(track, hint)`, if one is live.
    fn preview_note_off(&mut self, track: usize, hint: u32) {
        for idx in 0..PREVIEW_VOICES {
            let v = self.preview[idx];
            if v.active && v.track == track && v.hint == hint {
                self.release_preview(track, hint);
                self.preview[idx] = PreviewVoice::IDLE;
                self.preview_active -= 1;
            }
        }
    }

    /// Tell the instrument to release `hint`. No bookkeeping — callers own that.
    #[inline]
    fn release_preview(&mut self, track: usize, hint: u32) {
        if let Some(ti) = self
            .session
            .as_mut()
            .and_then(|s| s.tracks.get_mut(track))
            .and_then(|t| t.instrument.as_mut())
        {
            ti.node.instrument_mut().note_off(hint);
        }
    }

    /// Advance the one-shot audition voices by exactly ONE frame and release
    /// the ones whose hold expired. Held voices (`u64::MAX`) never expire.
    /// Only called when `preview_active > 0`.
    #[inline]
    fn tick_preview_voices(&mut self) {
        for idx in 0..PREVIEW_VOICES {
            let v = self.preview[idx];
            if !v.active || v.left == u64::MAX {
                continue;
            }
            if v.left > 1 {
                self.preview[idx].left = v.left - 1;
                continue;
            }
            self.release_preview(v.track, v.hint);
            self.preview[idx] = PreviewVoice::IDLE;
            self.preview_active -= 1;
        }
    }

    fn drain_commands(&mut self) {
        while let Ok(command) = self.commands.try_recv() {
            match command {
                RenderCommand::SetSession(new_session) => self.install_session(new_session),
                RenderCommand::Play => {
                    // Starting playback is a discontinuity: nothing may be
                    // sounding from before the transport stopped, and the
                    // cursor must re-anchor at the current position rather
                    // than resume a note whose attack was never delivered.
                    self.panic_all_notes();
                    // A seek still waiting behind its fade LANDS NOW. Play
                    // means "roll from where the user put the play head", so
                    // the destination has to be in `position` before the
                    // transport arms — and the fade it was waiting for is
                    // redundant here, because Play ramps up from wherever the
                    // gain currently is anyway.
                    if let Some(frame) = self.pending_seek.take() {
                        self.position = frame;
                    }
                    self.playing = true;
                    self.transport_target = 1.0;
                    // The beat clock caches the next beat's frame. Starting
                    // playback is exactly when that cache is stale.
                    self.metronome.desync();
                }
                RenderCommand::Stop => {
                    // Ramp to silence; `playing` flips false when the ramp
                    // lands (position keeps advancing during the tail).
                    // Release the voices NOW so nothing is left held when the
                    // instrument stops being rendered at the end of the ramp.
                    self.panic_all_notes();
                    // A pending seek still has to LAND — the user asked for
                    // that position and Stop does not take it back — but it
                    // must land WITHOUT re-arming the transport. The app's
                    // Stop is literally `seek(0)` then `stop`, so absorbing
                    // the seek here is what makes Stop halt at zero instead
                    // of resuming from it five milliseconds later.
                    if let Some(frame) = self.pending_seek.take() {
                        self.position = frame;
                        self.metronome.desync();
                    }
                    self.transport_target = 0.0;
                }
                RenderCommand::Seek { frame } => {
                    if self.playing && self.transport_gain > 0.0 {
                        // DEFERRED: fade out first, jump at exactly zero gain,
                        // fade back in. See `RenderCore::pending_seek` for why
                        // the old "set transport_gain = 0.0" was itself the
                        // click it claimed to avoid. Latest-wins, so a scrub
                        // that sends a seek per mouse-move costs ONE fade.
                        self.pending_seek = Some(frame);
                        self.transport_target = 0.0;
                    } else {
                        // Stopped (or already silent): nothing is sounding, so
                        // the jump is inaudible and immediate. This is also
                        // the path `prime_live_transport` takes when it
                        // restores a position into a fresh engine.
                        self.panic_all_notes();
                        self.pending_seek = None;
                        self.position = frame;
                        self.metronome.desync();
                    }
                }
                RenderCommand::LoopSet {
                    start_frame,
                    end_frame,
                } => {
                    if start_frame < end_frame {
                        self.loop_region = Some((start_frame, end_frame));
                    }
                }
                RenderCommand::LoopClear => {
                    self.loop_region = None;
                }
                RenderCommand::PreviewNoteOn {
                    track,
                    pitch,
                    velocity,
                    hint,
                    hold_frames,
                } => self.preview_note_on(track, pitch, velocity, hint, hold_frames),
                RenderCommand::PreviewNoteOff { track, hint } => {
                    self.preview_note_off(track, hint)
                }
                RenderCommand::CountIn {
                    beats,
                    period_frames,
                } => {
                    self.count_in_left = beats;
                    self.count_in_period = period_frames.max(1);
                    // Fire the FIRST click on the very next frame rather than
                    // one period later: "1" is now, not in a beat's time.
                    self.count_in_frames = 0;
                }
                RenderCommand::CountInCancel => {
                    self.count_in_left = 0;
                    self.count_in_frames = 0;
                }
                RenderCommand::CaptureStart {
                    capture,
                    start_transport,
                } => {
                    if let Some(old) = self.capture.replace(capture) {
                        self.defer_drop(DropPayload::Capture(old));
                    }
                    if start_transport {
                        // Same discontinuity as a Seek-to-0 plus a Play.
                        self.panic_all_notes();
                        self.position = 0;
                        self.playing = true;
                        self.transport_gain = 0.0;
                        self.transport_target = 1.0;
                    }
                }
            }
        }
    }

    /// Read atomics into per-block targets for strip indices < count.
    fn load_block_targets(&mut self, count: usize) {
        // PRE-DAG SOLO: resolve the global gate ONCE for the whole block, so
        // every strip agrees. This adds no per-block DSP state — it is a plain
        // read of the same atomics, exactly like the other targets, and the
        // gated value lands in track_gain_target[] where the per-frame strip
        // gain Slew ramps it (5 ms declick, same path as mute).
        let any_solo = self.params.any_solo(count);
        for idx in 0..count {
            self.track_gain_target[idx] = self.params.track_gain_target(idx, any_solo);
            // §3.3: the SAME `any_solo`, so a block is internally consistent —
            // a gate resolved from a second read could disagree with the fader
            // in the same block.
            self.track_gate_target[idx] = self.params.track_gate_target(idx, any_solo);
            self.track_pan_target[idx] = self.params.track_pan_target(idx);
            self.track_send_a_target[idx] = self.params.track_send_target(idx, false);
            self.track_send_b_target[idx] = self.params.track_send_target(idx, true);
            for band in 0..crate::dsp::biquad::EQ_BANDS {
                let v = self.params.track_eq_value(idx, band);
                self.strips[idx].eq.retarget_band_checked(
                    band,
                    self.cfg.sample_rate,
                    v.freq_hz,
                    v.gain_db,
                    v.q,
                );
            }
        }
    }

    /// Render one block. THE graph function: the cpal callback, the offline
    /// bounce, and the null test all run exactly this code.
    pub fn render(&mut self, out: &mut [[f32; 2]]) {
        let start = Instant::now();
        crate::guard::enter_render_scope();

        self.drain_commands();

        // Session lifecycle transitions happen ONLY at block boundaries, so
        // new_count / old_count / strip_count stay consistent for the whole
        // block (no mid-block index hazard). A crossfade that reached 0 on
        // the previous block retires its old session here; a parked (pending,
        // latest-wins) session then starts a fresh crossfade.
        if self.xfade_left == 0 {
            if let Some(old) = self.old_session.take() {
                self.defer_drop(DropPayload::Session(old));
            }
            if let Some(pending) = self.pending_session.take() {
                self.install_session(pending);
            }
        }

        // ---- block prep: read atomics into plain targets ----
        let new_count = self
            .session
            .as_ref()
            .map(|s| s.tracks.len().min(self.cfg.max_tracks))
            .unwrap_or(0);
        let old_count = self
            .old_session
            .as_ref()
            .map(|s| s.tracks.len().min(self.cfg.max_tracks))
            .unwrap_or(0);
        let strip_count = new_count.max(old_count);
        self.load_block_targets(strip_count);
        let master_target = self.params.master_gain_target();
        let return_a_target = self.params.return_target(false);
        let return_b_target = self.params.return_target(true);
        let reverb_damping = self.params.reverb_damping();
        let reverb_feedback = self.params.reverb_feedback();
        let delay_tap = self.params.delay_tap_frames();
        let delay_feedback = self.params.delay_feedback();
        let delay_tone = self.params.delay_tone();
        // Metronome grid + level, read ONCE per block like every other atomic
        // here. `set_config` forces the beat clock to resync, so it must only
        // run when the project's tempo or anchor genuinely moved — not every
        // block.
        let metro_enabled = self.params.metronome_enabled();
        let metro_cfg = self.params.metronome_config(self.cfg.sample_rate);
        if metro_cfg != self.metronome_cfg {
            self.metronome.set_config(metro_cfg);
            self.metronome_cfg = metro_cfg;
        }
        let limiter_ceiling = self.params.limiter_ceiling_lin();
        let limiter_release = self.params.limiter_release_coeff(self.cfg.sample_rate);
        let limiter_wanted = self.params.limiter_enabled();
        if limiter_wanted != self.limiter_engaged
            && !matches!(self.limiter_toggle, Some(LimiterToggle::FadeOut { .. }))
        {
            self.limiter_toggle = Some(LimiterToggle::FadeOut {
                to_enabled: limiter_wanted,
                left: RAMP_FRAMES,
            });
        }

        // ---- E5 graph block prep ----
        // Edge levels, node faders and every fx parameter are ATOMICS (§6.3,
        // §16.6), read ONCE here into plain targets; the per-frame `Slew`s and
        // the fx units' own smoothers do the ramping. Reading them per frame
        // would be an atomic load per edge per frame for no benefit, and
        // reading them per BLOCK is what the rest of this file already does.
        let (node_count, edge_count, fx_count) = match self.session.as_ref() {
            Some(s) => (
                s.graph.node_count.min(MAX_ROUTE_NODES),
                s.graph.edge_level_count.min(MAX_ROUTE_EDGES),
                s.graph.fx.len(),
            ),
            None => (0, 0, 0),
        };
        for slot in 0..node_count {
            self.node_gain_target[slot] = self.params.node_gain_target(slot);
        }
        for slot in 0..edge_count {
            self.edge_level_target[slot] = self.params.edge_level_target(slot);
        }
        let send_lane_slots = self
            .session
            .as_ref()
            .map(|s| s.send_lane_slots)
            .unwrap_or([None, None]);
        for i in 0..fx_count {
            // Split borrow: `self.params` is disjoint from `self.session`.
            let params = &self.params;
            if let Some(s) = self.session.as_mut() {
                let f = &mut s.graph.fx[i];
                f.unit
                    .load_block_targets(params, base_slot_of(f.fx_slot as usize));
            }
        }

        let mut fault = false;
        for frame_out in out.iter_mut() {
            // ---- transport ----
            // THE LOOP FOLD. E1 proved a loop-wrap note-off cannot be baked:
            // the loop region is TRANSPORT state (`RenderCommand::LoopSet`),
            // unknown at compile time and changeable without recompiling, so
            // the authored note-off for a note sounding across the fold lies
            // past the fold and is never reached. `folded` carries that fact
            // into the strip loop below, where every instrument gets
            // `all_notes_off()` on exactly this frame.
            // Audition voices age by exactly one FRAME, like every other piece
            // of signal state here, so a one-shot's length does not depend on
            // the block size. Skipped entirely when nothing is auditioning.
            if self.preview_active > 0 {
                self.tick_preview_voices();
            }

            let mut folded = false;
            if self.playing {
                if let Some((loop_start, loop_end)) = self.loop_region {
                    if self.position >= loop_end && loop_end > loop_start {
                        let len = loop_end - loop_start;
                        self.position = loop_start + (self.position - loop_end) % len;
                        folded = true;
                    }
                }
            }
            let tg = self.transport_gain;
            self.transport_gain = if (self.transport_target - tg).abs() <= TRANSPORT_STEP {
                self.transport_target
            } else if self.transport_target > tg {
                tg + TRANSPORT_STEP
            } else {
                tg - TRANSPORT_STEP
            };

            // THE DEFERRED SEEK LANDS HERE, and only here: on the frame the
            // declick reaches EXACTLY zero. `Slew`-style arrival is exact
            // (`transport_gain` is assigned `transport_target` once it is
            // within one step), so this is a bit-exact test, not an epsilon.
            //
            // It runs BEFORE the graph walk below, so `position` is already
            // the destination for this frame's clip, note and automation
            // reads — the jump and the silence are the SAME frame, which is
            // the whole point. `pending_seek` is `None` on every frame of
            // every project that never seeks, so this is one `Option` test
            // per frame and the arithmetic below is untouched.
            if self.pending_seek.is_some() && self.transport_gain == 0.0 {
                let frame = self.pending_seek.take().unwrap_or(self.position);
                self.panic_all_notes();
                self.position = frame;
                // The beat clock caches the next beat's frame; a jump is
                // exactly when that cache is dead (same reasoning as Play).
                self.metronome.desync();
                self.transport_target = 1.0;
            }

            // Crossfade weight for this frame (0 = all old, 1 = all new).
            let xfade_t = if self.old_session.is_some() && self.xfade_left > 0 {
                self.xfade_left -= 1;
                (RAMP_FRAMES - self.xfade_left) as f32 / RAMP_FRAMES as f32
            } else {
                1.0
            };

            // ---- THE ROUTING GRAPH WALK (design §6.4 + §16.7) ----
            //
            // ⚠️ Everything below advances per FRAME. There is deliberately no
            // "render this node's block, then mix the blocks" anywhere in it:
            // that shortcut makes a node's output depend on the buffer size and
            // destroys the bit-identity between the live callback (128) and the
            // offline bounce (512) that `render/tests/graph.rs` proves at
            // 128/417/480/512.
            //
            // For a v1 project (`Routing::is_empty()`) the baked order is
            // exactly `[Track(0) .. Track(n-1), LegacyReturns, Master]` with an
            // implicit unity edge from every track to master and no explicit
            // edges at all, so the arithmetic below reduces, term for term and
            // in the same association, to the pre-E5 tail. That is what makes
            // §12.2's legacy-null gate provable rather than hopeful.
            let position = self.position;

            // 1. Zero this frame's accumulators. ONE pass, at exactly one point
            //    per frame — the generalisation of the pre-E5 `bus_a`/`bus_b`
            //    re-zero, over the slots this session can actually touch.
            for slot in 0..node_count {
                self.node_acc[slot] = [0.0, 0.0];
            }
            self.node_acc[ACC_FX_A] = [0.0, 0.0];
            self.node_acc[ACC_FX_B] = [0.0, 0.0];
            self.node_acc[ACC_MASTER] = [0.0, 0.0];
            for idx in 0..strip_count {
                self.node_acc[ACC_TRACK_BASE + idx] = [0.0, 0.0];
            }

            // 2. Walk `node_order` BY INDEX. `NodeStepKind` is `Copy`, so the
            //    step is read out of the snapshot and the borrow released
            //    before the step runs: no allocation, no lookup, no sort, and
            //    no branch on a `String`.
            let steps = self
                .session
                .as_ref()
                .map(|s| s.node_order.len())
                .unwrap_or(0);
            for si in 0..steps {
                let (kind, out_range, fx_range) = {
                    let s = self
                        .session
                        .as_ref()
                        .expect("steps > 0 implies a live session");
                    let st = &s.node_order[si];
                    (
                        st.kind,
                        (st.out_edges.0 as usize, st.out_edges.1 as usize),
                        (st.fx.0 as usize, st.fx.1 as usize),
                    )
                };
                match kind {
                    // A schedule step naming something this session does not
                    // contain (a dangling edge endpoint). No accumulator, no
                    // audio, no work.
                    NodeStepKind::Skip => {}

                    NodeStepKind::Track(idx) => {
                        if idx >= strip_count {
                            continue;
                        }
                        // Anything routed INTO this strip arrives PRE-FADER, so
                        // the strip's gain, pan, EQ and mute mean what they say.
                        // Always `[0.0, 0.0]` for a project with no bus->track
                        // edge, which is every project that existed before E5.
                        let inject = self.node_acc[ACC_TRACK_BASE + idx];
                        let sf = {
                            let strip = &mut self.strips[idx];
                            let events = &mut self.note_events;
                            let node_acc = &self.node_acc;
                            let (new_track, fx) = match self.session.as_mut() {
                                Some(s) => {
                                    let RtSession { tracks, graph, .. } = &mut **s;
                                    (
                                        if idx < new_count {
                                            tracks.get_mut(idx)
                                        } else {
                                            None
                                        },
                                        &mut graph.fx[fx_range.0..fx_range.1],
                                    )
                                }
                                None => (None, &mut [][..]),
                            };
                            let old_track = self.old_session.as_mut().and_then(|o| {
                                if idx < old_count {
                                    o.tracks.get_mut(idx)
                                } else {
                                    None
                                }
                            });
                            render_track_frame(TrackFrameArgs {
                                strip,
                                new_track,
                                old_track,
                                fx,
                                node_acc,
                                events,
                                position,
                                folded,
                                playing: self.playing,
                                transport_gain: self.transport_gain,
                                preview_active: self.preview_active,
                                xfade_t,
                                inject,
                                gain_target: self.track_gain_target[idx],
                                gate_target: self.track_gate_target[idx],
                                pan_target: self.track_pan_target[idx],
                                send_a_atomic: self.track_send_a_target[idx],
                                send_b_atomic: self.track_send_b_target[idx],
                                send_slots: send_lane_slots,
                            })
                        };
                        fault |= sf.fault;
                        // The two legacy FX buses, desugared (§2.1). The
                        // arithmetic is the pre-E5 arithmetic verbatim — the
                        // `> 0.0` guard included — because `Tap::Post` is
                        // defined as "today's tap point, bit-exactly" (§3.1).
                        if sf.send_a > 0.0 {
                            self.node_acc[ACC_FX_A][0] += sf.x[0] * sf.send_a;
                            self.node_acc[ACC_FX_A][1] += sf.x[1] * sf.send_a;
                        }
                        if sf.send_b > 0.0 {
                            self.node_acc[ACC_FX_B][0] += sf.x[0] * sf.send_b;
                            self.node_acc[ACC_FX_B][1] += sf.x[1] * sf.send_b;
                        }
                        self.strips[idx].meter_frame(sf.x[0], sf.x[1]);
                        // Publish this strip's OUTPUT into its own accumulator
                        // so a keyed processor downstream can read it (§17.3).
                        // The slot was read as `inject` above and is not a
                        // destination for this track's own edges (self-loops
                        // are rejected at command time), so the overwrite is
                        // safe and the value is complete.
                        self.node_acc[ACC_TRACK_BASE + idx] = sf.x;
                        {
                            let strip = &mut self.strips[idx];
                            let (edges, comp_rings, lanes) = match self.session.as_mut() {
                                Some(s) => {
                                    let RtSession { tracks, graph, .. } = &mut **s;
                                    (
                                        &graph.edges[..],
                                        &mut graph.comp_rings[..],
                                        tracks.get(idx).map(|t| &t.lanes[..]),
                                    )
                                }
                                None => (&[][..], &mut [][..], None),
                            };
                            push_edges(
                                edges,
                                comp_rings,
                                out_range,
                                sf.x,
                                sf.pre,
                                &mut self.edge_level,
                                &self.edge_level_target,
                                &mut self.node_acc,
                                |slot, default| match lanes
                                    .and_then(|l| l.get(slot))
                                    .and_then(Option::as_ref)
                                {
                                    None => default,
                                    lane => strip
                                        .lane_value(lane, slot, position, default)
                                        .clamp(MIN_EDGE_LEVEL, MAX_EDGE_LEVEL),
                                },
                            );
                        }
                    }

                    NodeStepKind::Node(slot) => {
                        if slot >= node_count {
                            continue;
                        }
                        // A bus node's input is COMPLETE when it is reached:
                        // the topological sort guarantees every feeder was
                        // scheduled earlier this frame. That is the entire
                        // point of baking the schedule.
                        let mut x = self.node_acc[slot];
                        {
                            let node_acc = &self.node_acc;
                            if let Some(s) = self.session.as_mut() {
                                x = run_fx_chain(
                                    &mut s.graph.fx[fx_range.0..fx_range.1],
                                    node_acc,
                                    position,
                                    x,
                                );
                            }
                        }
                        // The node fader: the atomic is the default and the
                        // lane OVERRIDES it, the absolute-value convention the
                        // send readers already use. An offset convention would
                        // multiply a fader sitting at silence and stay silent —
                        // the same bug, respelled.
                        let lane_lin = {
                            let lane = self
                                .session
                                .as_ref()
                                .and_then(|s| s.graph.node_gain_lane(slot));
                            match lane {
                                None => None,
                                Some(lane) => {
                                    let cursor = &mut self.node_lane_cursor[slot];
                                    let db = lane.value_at(position, cursor);
                                    if db != self.node_gain_last_db[slot] {
                                        self.node_gain_last_db[slot] = db;
                                        self.node_gain_last_lin[slot] =
                                            crate::dsp::db_to_lin(db);
                                    }
                                    Some(self.node_gain_last_lin[slot])
                                }
                            }
                        };
                        let g = self
                            .node_gain[slot]
                            .advance(lane_lin.unwrap_or(self.node_gain_target[slot]));
                        x[0] *= g;
                        x[1] *= g;
                        accumulate_node_meter(
                            &mut self.node_peak_l,
                            &mut self.node_peak_r,
                            &mut self.node_sumsq,
                            slot,
                            x,
                        );
                        // The node's OUTPUT replaces its input in the
                        // accumulator, so a keyed processor downstream reads
                        // the node's fully-processed output at this frame
                        // (§17.3), not its raw sum.
                        self.node_acc[slot] = x;
                        {
                            let (edges, comp_rings) = match self.session.as_mut() {
                                Some(s) => {
                                    let RtGraph {
                                        edges, comp_rings, ..
                                    } = &mut s.graph;
                                    (&edges[..], &mut comp_rings[..])
                                }
                                None => (&[][..], &mut [][..]),
                            };
                            push_edges(
                                edges,
                                comp_rings,
                                out_range,
                                x,
                                x,
                                &mut self.edge_level,
                                &self.edge_level_target,
                                &mut self.node_acc,
                                |_, default| default,
                            );
                        }
                    }

                    // ⚠️ ONE step, not two, and that is load-bearing. The
                    // pre-E5 tail computes `master += rev * ra + del * rb` as a
                    // SINGLE expression; float addition is not associative, so
                    // splitting it into two accumulator writes would change the
                    // low bit of every frame of every existing project and take
                    // the legacy-null gate red.
                    NodeStepKind::LegacyReturns => {
                        // Retiring strips the NEW session's schedule does not
                        // mention still have to be heard for the length of the
                        // swap crossfade, or every edit that removes a track
                        // cuts its audio dead. They carry no graph (they belong
                        // to the outgoing session), so they take the implicit
                        // unity feed to master, in index order, exactly where
                        // the pre-E5 loop had them.
                        for idx in new_count..strip_count {
                            let inject = self.node_acc[ACC_TRACK_BASE + idx];
                            let sf = {
                                let strip = &mut self.strips[idx];
                                let events = &mut self.note_events;
                                let node_acc = &self.node_acc;
                                let old_track = self.old_session.as_mut().and_then(|o| {
                                    if idx < old_count {
                                        o.tracks.get_mut(idx)
                                    } else {
                                        None
                                    }
                                });
                                render_track_frame(TrackFrameArgs {
                                    strip,
                                    new_track: None,
                                    old_track,
                                    fx: &mut [],
                                    node_acc,
                                    events,
                                    position,
                                    folded,
                                    playing: self.playing,
                                    transport_gain: self.transport_gain,
                                    preview_active: 0,
                                    xfade_t,
                                    inject,
                                    gain_target: self.track_gain_target[idx],
                                    gate_target: self.track_gate_target[idx],
                                    pan_target: self.track_pan_target[idx],
                                    send_a_atomic: self.track_send_a_target[idx],
                                    send_b_atomic: self.track_send_b_target[idx],
                                    send_slots: [None, None],
                                })
                            };
                            fault |= sf.fault;
                            if sf.send_a > 0.0 {
                                self.node_acc[ACC_FX_A][0] += sf.x[0] * sf.send_a;
                                self.node_acc[ACC_FX_A][1] += sf.x[1] * sf.send_a;
                            }
                            if sf.send_b > 0.0 {
                                self.node_acc[ACC_FX_B][0] += sf.x[0] * sf.send_b;
                                self.node_acc[ACC_FX_B][1] += sf.x[1] * sf.send_b;
                            }
                            self.strips[idx].meter_frame(sf.x[0], sf.x[1]);
                            self.node_acc[ACC_MASTER][0] += sf.x[0];
                            self.node_acc[ACC_MASTER][1] += sf.x[1];
                        }

                        let bus_a = self.node_acc[ACC_FX_A];
                        let bus_b = self.node_acc[ACC_FX_B];
                        let rev = self
                            .reverb
                            .process_frame(bus_a, reverb_damping, reverb_feedback);
                        let ra = self.return_a.advance(return_a_target);
                        let del = self
                            .delay
                            .process_frame(bus_b, delay_tap, delay_feedback, delay_tone);
                        let rb = self.return_b.advance(return_b_target);
                        let legacy_comp = self
                            .session
                            .as_ref()
                            .map(|s| s.graph.legacy_comp)
                            .unwrap_or([0, 0]);
                        if legacy_comp == [0, 0] {
                            // THE bit-exact legacy tail: one expression, one
                            // association, byte for byte as before E5.
                            self.node_acc[ACC_MASTER][0] += rev[0] * ra + del[0] * rb;
                            self.node_acc[ACC_MASTER][1] += rev[1] * ra + del[1] * rb;
                        } else if let Some(s) = self.session.as_mut() {
                            let a = s.graph.legacy_rings[0]
                                .process_frame([rev[0] * ra, rev[1] * ra]);
                            let b = s.graph.legacy_rings[1]
                                .process_frame([del[0] * rb, del[1] * rb]);
                            self.node_acc[ACC_MASTER][0] += a[0] + b[0];
                            self.node_acc[ACC_MASTER][1] += a[1] + b[1];
                        }
                        accumulate_node_meter(
                            &mut self.node_peak_l,
                            &mut self.node_peak_r,
                            &mut self.node_sumsq,
                            crate::stats::LEGACY_FX_A_METER,
                            [rev[0] * ra, rev[1] * ra],
                        );
                        accumulate_node_meter(
                            &mut self.node_peak_l,
                            &mut self.node_peak_r,
                            &mut self.node_sumsq,
                            crate::stats::LEGACY_FX_B_METER,
                            [del[0] * rb, del[1] * rb],
                        );
                    }

                    NodeStepKind::Master => {
                        // §16.7: the master insert chain runs BEFORE the master
                        // gain and therefore before the existing master limiter.
                        let node_acc = &self.node_acc;
                        let x = node_acc[ACC_MASTER];
                        let out = match self.session.as_mut() {
                            Some(s) => run_fx_chain(
                                &mut s.graph.fx[fx_range.0..fx_range.1],
                                node_acc,
                                position,
                                x,
                            ),
                            None => x,
                        };
                        self.node_acc[ACC_MASTER] = out;
                    }
                }
            }

            // (Crossfade completion is handled at the next block boundary so
            // session track counts never change mid-block.)

            let mut master = self.node_acc[ACC_MASTER];

            // ---- master ----
            let mg = self.master_gain.advance(master_target);
            master[0] *= mg;
            master[1] *= mg;

            if self.limiter_engaged {
                master = self
                    .limiter
                    .process_frame(master, limiter_ceiling, limiter_release);
            }

            // Limiter toggle declick: output mute ramp around the flip.
            if let Some(toggle) = self.limiter_toggle {
                match toggle {
                    LimiterToggle::FadeOut { to_enabled, left } => {
                        let left = left - 1;
                        self.toggle_mute = left as f32 / RAMP_FRAMES as f32;
                        if left == 0 {
                            self.limiter_engaged = to_enabled;
                            self.limiter.reset();
                            self.limiter_toggle =
                                Some(LimiterToggle::FadeIn { left: RAMP_FRAMES });
                        } else {
                            self.limiter_toggle =
                                Some(LimiterToggle::FadeOut { to_enabled, left });
                        }
                    }
                    LimiterToggle::FadeIn { left } => {
                        let left = left - 1;
                        self.toggle_mute = (RAMP_FRAMES - left) as f32 / RAMP_FRAMES as f32;
                        self.limiter_toggle = if left == 0 {
                            None
                        } else {
                            Some(LimiterToggle::FadeIn { left })
                        };
                    }
                }
                master[0] *= self.toggle_mute;
                master[1] *= self.toggle_mute;
            }

            // ---- master meters, capture, output ----
            let tp = self.master_tp.process_frame(master);
            if tp > self.master_block_tp {
                self.master_block_tp = tp;
            }
            let al = master[0].abs();
            let ar = master[1].abs();
            if al > self.master_peak_l {
                self.master_peak_l = al;
            }
            if ar > self.master_peak_r {
                self.master_peak_r = ar;
            }
            self.master_sumsq += master[0] * master[0] + master[1] * master[1];
            self.master_sum_lr += master[0] * master[1];
            self.master_sum_ll += master[0] * master[0];
            self.master_sum_rr += master[1] * master[1];

            if self.playing {
                self.position += 1;
                // A transport that has ramped to silence AND is targeting
                // silence has stopped. A seek waiting behind its fade is
                // targeting silence too, and it is emphatically NOT a stop.
                //
                // ⚠️ THE `pending_seek` TERM IS UNREACHABLE TODAY, ON PURPOSE,
                // and it is written down rather than deleted. The deferred jump
                // above fires at the TOP of the very frame `transport_gain`
                // reaches zero and immediately retargets 1.0, so by the time
                // control gets here `pending_seek` is already `None` on exactly
                // the frames this test could otherwise fire on — a mutation
                // that deletes the term leaves every test in
                // `seek_declick.rs` green, which is reported as a surviving
                // mutant rather than papered over.
                //
                // It stays because it is not a redundancy, it is the INVARIANT:
                // "a fade the transport intends to come back from is not a
                // stop". The two are only equivalent while the jump is
                // evaluated before this check inside the same frame. Move
                // either one and the app's Stop (`seek(0)` then `stop`) starts
                // halting on the seek instead of the stop, silently, in a
                // 2 000-line render loop. One `Option` test per frame is a
                // cheap place to keep that from being a discovery.
                debug_assert!(
                    !(self.pending_seek.is_some() && self.transport_gain == 0.0),
                    "a pending seek must have landed on the frame the declick \
                     reached zero"
                );
                if self.transport_gain == 0.0
                    && self.transport_target == 0.0
                    && self.pending_seek.is_none()
                {
                    self.playing = false;
                }
            }

            *frame_out = master;

            // ---- THE METRONOME (monitor path only) ----
            //
            // Deliberately placed HERE, between the output write above and the
            // capture tap below, and it is the only thing in this function
            // that touches `frame_out` after `master` was written. Three
            // consequences, all of them wanted:
            //
            //   * It is NOT in `master`, so it never reaches the capture tap
            //     four lines down. A take you record while playing to the
            //     click has no click in it.
            //   * It is NOT in the master meters, the true-peak detector or
            //     the correlation accumulators (all computed above from
            //     `master`). The click cannot make the master meter lie.
            //   * It is post-fader and post-limiter, so pulling the master
            //     fader down does not take the click with it — which is the
            //     behaviour you want from something you are playing ALONG to.
            //
            // And the whole thing is behind `self.cfg.monitor`, which is false
            // on every offline path by construction. See `CoreConfig::monitor`.
            if self.cfg.monitor {
                // `position` is the post-fold, pre-increment snapshot taken at
                // the top of this frame — the same value the clip, note and
                // automation reads used, so the click is phase-locked to the
                // content rather than one frame off it.
                //
                // THE ONE OBSERVABLE SIGNAL FOR THE CLICK. Everything the
                // comment above is proud of — not in `master`, not in the
                // meters, not in the true-peak detector, not in the capture
                // tap — also means no instrument in this engine can see the
                // click. A human ear was the only oracle, which is why "one
                // chirp and then silence" could not be told apart from "the
                // enable never arrived". So: one relaxed atomic add, on the
                // frames that actually fire the voice (~2 a second at 120
                // BPM, not per frame), allocation-free and lock-free like
                // every other stats write on this thread. It is INSIDE
                // `if self.cfg.monitor`, so a bounce cannot move it — the
                // counter is as inert offline as the click is.
                if self
                    .metronome
                    .tick_clock(position, self.playing, metro_enabled)
                {
                    self.stats.metronome_clicks.fetch_add(1, Ordering::Relaxed);
                }
                // The count-in runs on its own counter because it sounds
                // BEFORE the transport rolls. It advances per FRAME, like
                // everything else in this loop.
                if self.count_in_left > 0 {
                    if self.count_in_frames % self.count_in_period == 0 {
                        // Beat 1 of the count-in is the accent, so "1" is
                        // unmistakable.
                        self.metronome.trigger(self.count_in_frames == 0);
                        // A count-in beat is a click the user is meant to
                        // hear, so it counts. One counter, not two: the
                        // question this answers is "did the engine sound a
                        // click", and the count-in is the one click path a
                        // user can fire with the transport stopped.
                        self.stats.metronome_clicks.fetch_add(1, Ordering::Relaxed);
                    }
                    self.count_in_frames += 1;
                    if self.count_in_frames >= self.count_in_period * u64::from(self.count_in_left)
                    {
                        self.count_in_left = 0;
                        self.count_in_frames = 0;
                    }
                }
                // EXACTLY ONE voice advance per frame, whatever combination of
                // grid beat and count-in beat landed on it.
                let click = self.metronome.voice_frame();
                frame_out[0] += click;
                frame_out[1] += click;
            }

            // Capture tap (pre silence gate; the gate lives in the stream
            // closure, never here).
            if let Some(capture) = self.capture.as_mut() {
                if capture.written < capture.data.len() {
                    capture.data[capture.written] = master;
                    capture.written += 1;
                }
                if capture.written >= capture.data.len() {
                    if let Some(done) = self.capture.take() {
                        if let Err(err) = self.capture_tx.try_send(done) {
                            let leaked = err.into_inner();
                            self.stats.leaked_buffers.fetch_add(1, Ordering::Relaxed);
                            std::mem::forget(leaked);
                        }
                    }
                }
            }

            // Loudness tap for the meter thread (live engine only).
            if let Some(tx) = self.meter_tx.as_ref() {
                if tx.try_send(master).is_err() {
                    self.stats.meter_drops.fetch_add(1, Ordering::Relaxed);
                }
            }
        }

        // ---- block epilogue: meters, hygiene, stats ----
        let frames = out.len();
        for idx in 0..strip_count {
            let strip = &mut self.strips[idx];
            let (pl, pr, rms) = strip.take_block_meters(frames);
            self.meters.track_frame(idx, pl, pr);
            self.meters.track_block_rms(idx, rms);
            strip.eq.block_maintenance();
        }
        // §8: routing-node meters, flushed once per block through the same
        // epilogue every other meter uses. The two legacy returns occupy the
        // last two slots, so the reverb and the tempo delay finally meter.
        for slot in 0..crate::stats::NODE_METER_SLOTS {
            let rms = if frames > 0 {
                (self.node_sumsq[slot] / (frames as f32 * 2.0)).sqrt()
            } else {
                0.0
            };
            self.meters
                .node_block(slot, self.node_peak_l[slot], self.node_peak_r[slot], rms);
            self.node_peak_l[slot] = 0.0;
            self.node_peak_r[slot] = 0.0;
            self.node_sumsq[slot] = 0.0;
        }
        let master_rms = if frames > 0 {
            (self.master_sumsq / (frames as f32 * 2.0)).sqrt()
        } else {
            0.0
        };
        self.meters
            .master_frame(self.master_peak_l, self.master_peak_r);
        let (min_gain, in_tp, _out_tp) = self.limiter.take_telemetry();
        let gr_db = if self.limiter_engaged && min_gain < 1.0 {
            -20.0 * min_gain.max(1.0e-6).log10()
        } else {
            0.0
        };
        // Normalized stereo correlation over this block. Undefined (NaN) when
        // either channel is silent, which the control side reads as "no signal".
        let denom = (self.master_sum_ll * self.master_sum_rr).sqrt();
        let corr = if denom > 0.0 {
            (self.master_sum_lr / denom).clamp(-1.0, 1.0)
        } else {
            f32::NAN
        };
        self.meters.master_block(
            master_rms,
            self.master_block_tp,
            if self.limiter_engaged { in_tp } else { 0.0 },
            gr_db,
            corr,
        );
        self.master_peak_l = 0.0;
        self.master_peak_r = 0.0;
        self.master_sumsq = 0.0;
        self.master_block_tp = 0.0;
        self.master_sum_lr = 0.0;
        self.master_sum_ll = 0.0;
        self.master_sum_rr = 0.0;

        if fault {
            self.stats.underruns.fetch_add(1, Ordering::Relaxed);
        }
        self.stats
            .position_frame
            .store(self.position, Ordering::Relaxed);
        self.stats
            .playing
            .store(u8::from(self.playing), Ordering::Relaxed);

        crate::guard::leave_render_scope();
        let elapsed_ns = start.elapsed().as_nanos() as u64;
        let budget_ns = (out.len() as u64).saturating_mul(1_000_000_000)
            / u64::from(self.cfg.sample_rate.max(1));
        self.stats.record_block(out.len(), elapsed_ns, budget_ns);
    }
}
