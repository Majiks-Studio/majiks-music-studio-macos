//! Compile a timeline-core `Project` (plus render-side warp overlay and
//! automation lanes) into an immutable `RtSession` snapshot. Control-side
//! only. Every clip is validated against the actually loaded audio so the
//! render callback can never read out of bounds.
//!
//! DECLICK INVARIANT (the L2 acceptance bar): under `DeclickPolicy::Auto`
//! every clip boundary renders through a ramp unless the material across the
//! boundary is sample-continuous. The compiler enforces it structurally:
//! - authored fades pass through with their authored shape
//! - a zero-fade clip edge gets an implicit LINEAR micro-fade (5 ms,
//!   clamped to half the clip) UNLESS the neighbor clip butts exactly
//!   against it with sample-continuous material (same source, contiguous
//!   offsets, same gain, both unwarped, no authored fades at the joint):
//!   gapless adjacency stays bit-exact butt-jointed
//! - a warped clip plays its pre-rendered stretched buffer; its timeline
//!   extent is the stretched length
//!
//! `DeclickPolicy::None` is the raw scheduler: authored fades only, no
//! implicit ramps. It exists so the sample-exact scheduler tests (P0-B) and
//! the offline null test measure the scheduler math itself, not the edge
//! policy. The live host plays `Auto`; correctness suites use `None`.

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use timeline_core::routing::NodeRef;
use timeline_core::{Clip, FadeShape, Project, TempoMap};

use crate::automation as auto;
use crate::automation::{AutoLane, AutomationStore};
use crate::dsp::instrument::{
    Instrument, InstrumentNode, InstrumentParams, INSTRUMENT_PARAM_COUNT, INSTRUMENT_PARAM_KEYS,
    NODE_VOICES,
};
use crate::dsp::drum::{DrumKit, DrumPad, DrumRack, RACK_PADS};
use crate::dsp::sampler::{SampleMap, SampleZone, Sampler};
use crate::dsp::synth::Synth;
use crate::media::AudioBuf;
use crate::notes::{bake_clip_notes, NoteEvent, NoteLane};
use crate::dsp::fx::{
    base_slot_of, seed_fx_defaults, set_fx_param_by_key, FxKindId, FxParamRate, FxUnit,
};
use crate::params::{EngineParams, MAX_FX_PARAMS_PER_FX, MAX_FX_TOTAL};
use crate::routing_rt::{
    check_cap, node_acc_len, CompDelay, RtEdge, RtFx, RtFxLane, RtGraph, ACC_FX_A, ACC_FX_B,
    ACC_MASTER, ACC_TRACK_BASE, IMPLICIT_UNITY, MAX_FX_PER_CHAIN, NO_LANE,
};
use crate::rt::{
    NodeStep, NodeStepKind, RtClip, RtSession, RtTrack, TrackInstrument,
    LANE_FIXED, LANE_PAN, LANE_VOLUME, MAX_ROUTE_EDGES, MAX_ROUTE_NODES, MAX_TRACK_LANES,
    MICRO_FADE_FRAMES,
};
use crate::warp::{is_identity, WarpOverlay};

/// Whether the compiler injects implicit declick micro-fades at clip edges.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeclickPolicy {
    /// Authored fades only (sample-exact scheduler; P0-B + null test).
    None,
    /// Implicit 5 ms linear ramp at every non-continuous zero-fade edge
    /// (clickless playback; the live host).
    Auto,
}

fn db_to_lin(db: f32) -> f32 {
    10.0_f32.powf(db / 20.0)
}

/// Resolved audio for one clip after the warp overlay is applied.
struct ResolvedClip<'a> {
    clip: &'a Clip,
    audio: Arc<AudioBuf>,
    offset_frames: u64,
    len_frames: u64,
    warped: bool,
}

/// True when `next` continues exactly where `prev` ends: butt joint, same
/// source, contiguous source material, same gain, neither warped, and no
/// authored fades at the joint itself.
fn sample_continuous(prev: &ResolvedClip<'_>, next: &ResolvedClip<'_>) -> bool {
    !prev.warped
        && !next.warped
        && prev.clip.source_id == next.clip.source_id
        && prev.clip.start_frame + prev.len_frames == next.clip.start_frame
        && prev.offset_frames + prev.len_frames == next.offset_frames
        // Compare effective linear gain so authored +0.0 vs -0.0 dB (equal
        // gain, different bits) stays a gapless joint rather than a dip.
        && db_to_lin(prev.clip.gain_db) == db_to_lin(next.clip.gain_db)
        && prev.clip.fade_out_frames == 0
        && next.clip.fade_in_frames == 0
}

/// Back-compat entry point (P0-B tests, simple callers): no warp, no
/// automation, raw scheduler (no implicit declick).
pub fn compile_session(
    project: &Project,
    sources: &HashMap<String, Arc<AudioBuf>>,
    max_tracks: usize,
) -> Result<Box<RtSession>, String> {
    compile_session_full(
        project,
        sources,
        &WarpOverlay::new(),
        &AutomationStore::new(),
        max_tracks,
        DeclickPolicy::None,
    )
}

pub fn compile_session_full(
    project: &Project,
    sources: &HashMap<String, Arc<AudioBuf>>,
    warp: &WarpOverlay,
    automation: &AutomationStore,
    max_tracks: usize,
    declick: DeclickPolicy,
) -> Result<Box<RtSession>, String> {
    if project.tracks.len() > max_tracks {
        return Err(format!(
            "project has {} tracks, engine capacity is {max_tracks}",
            project.tracks.len()
        ));
    }
    let tempo: &TempoMap = &project.tempo;
    let rate = project.sample_rate;

    let lane_index = build_lane_index(automation, project)?;
    let lane_count = lane_index.values().copied().max().map(|m| m + 1).unwrap_or(0);

    let mut tracks = Vec::with_capacity(project.tracks.len());
    for track in &project.tracks {
        // Resolve audio (warp overlay first) and validate extents.
        let mut resolved: Vec<ResolvedClip<'_>> = Vec::with_capacity(track.clips.len());
        // E1: bake this track's note clips into one sorted, preallocated event
        // slice in ABSOLUTE frames. Control-side, once, exactly like the
        // automation lanes below — notes are never streamed per-event through
        // the command channel, which is what keeps bounce identical to live.
        let mut note_events: Vec<NoteEvent> = Vec::new();
        for clip in &track.clips {
            if clip.is_midi() {
                // A note clip references no audio asset; it must not go through
                // the source-resolution path at all.
                if !clip.muted {
                    bake_clip_notes(
                        &clip.notes,
                        clip.start_ticks,
                        clip.source_offset_ticks,
                        clip.content_end_ticks(),
                        tempo,
                        rate,
                        &mut note_events,
                    );
                }
                continue;
            }
            let source = sources.get(&clip.source_id).ok_or_else(|| {
                format!(
                    "clip {} references unloaded source {}",
                    clip.id, clip.source_id
                )
            })?;
            let entry = warp.get(&clip.id);
            let (audio, offset, len, warped) = match entry {
                Some(e) if e.stretched.is_some() && !is_identity(e.stretched_ratio) => {
                    let stretched = e.stretched.as_ref().expect("checked is_some");
                    (Arc::clone(stretched), 0, stretched.len_frames(), true)
                }
                _ => (Arc::clone(source), clip.offset_frames, clip.len_frames, false),
            };
            if len == 0 {
                return Err(format!("clip {} resolves to zero length", clip.id));
            }
            let end_in_source = offset
                .checked_add(len)
                .ok_or_else(|| format!("clip {} extent overflows", clip.id))?;
            if end_in_source > audio.len_frames() {
                return Err(format!(
                    "clip {} reads past loaded audio ({} > {})",
                    clip.id,
                    end_in_source,
                    audio.len_frames()
                ));
            }
            resolved.push(ResolvedClip {
                clip,
                audio,
                offset_frames: offset,
                len_frames: len,
                warped,
            });
        }
        // Stable render order (the early-break scan depends on it).
        resolved.sort_by_key(|r| r.clip.start_frame);

        // Implicit declick fades at non-continuous zero-fade boundaries
        // (Auto policy only).
        let mut clips = Vec::with_capacity(resolved.len());
        for i in 0..resolved.len() {
            let r = &resolved[i];
            let clamp = (r.len_frames / 2).max(1);
            let micro = MICRO_FADE_FRAMES.min(clamp);

            let mut fade_in = r.clip.fade_in_frames.min(r.len_frames);
            let mut fade_in_shape = r.clip.fade_shape;
            if fade_in == 0 && declick == DeclickPolicy::Auto {
                let continuous = i > 0 && sample_continuous(&resolved[i - 1], r);
                if !continuous {
                    fade_in = micro;
                    fade_in_shape = FadeShape::Linear;
                }
            }

            let mut fade_out = r.clip.fade_out_frames.min(r.len_frames);
            let mut fade_out_shape = r.clip.fade_shape;
            if fade_out == 0 && declick == DeclickPolicy::Auto {
                let continuous =
                    i + 1 < resolved.len() && sample_continuous(r, &resolved[i + 1]);
                if !continuous {
                    fade_out = micro;
                    fade_out_shape = FadeShape::Linear;
                }
            }

            clips.push(RtClip {
                audio: Arc::clone(&r.audio),
                start_frame: r.clip.start_frame,
                offset_frames: r.offset_frames,
                len_frames: r.len_frames,
                gain_lin: db_to_lin(r.clip.gain_db),
                fade_in_frames: fade_in,
                fade_out_frames: fade_out,
                fade_in_shape,
                fade_out_shape,
            });
        }

        // Lanes are baked into the session's DENSE SLOT TABLE. Slot 0/1 are
        // always volume/pan (present or absent); everything else got its slot
        // from `lane_index`, which is a pure function of the store's key set,
        // so the same project always compiles to the same table.
        let mut lanes: Vec<Option<AutoLane>> = vec![None; lane_count];
        for (path, slot) in &lane_index {
            lanes[*slot] = automation.bake_path(&track.id, path, tempo, rate);
        }

        let instrument = build_instrument(track, sources, &lane_index, rate)?;

        tracks.push(RtTrack {
            clips: clips.into_boxed_slice(),
            lanes: lanes.into_boxed_slice(),
            instrument,
            // `NoteLane::new` sorts into (frame, offs-before-ons, pitch,
            // voice_hint) and freezes the Vec into a Box<[..]>. The audio
            // thread walks it by index through a fixed-size `NoteCursor` and
            // never sorts, allocates, or looks anything up.
            notes: NoteLane::new(note_events),
        });
    }

    // Routing: the topological sort happens HERE, on the control thread, and
    // the result is baked flat. The audio thread walks it by index (E5) and
    // never sorts, allocates, or discovers a cycle.
    let track_ids: Vec<&str> = project.tracks.iter().map(|t| t.id.as_str()).collect();
    // E5 §18.2: sidechain LINKS are ordering-only constraints and the sort MUST
    // be told about them. If it is not, a keyed processor reads its source's
    // accumulator BEFORE it is written this frame — exactly 0.0, i.e. silence,
    // not a small error — and every model-level test still passes. Empty for
    // any project with no sidechained fx, so this is behaviour-identical today.
    let links = project.sidechain_links();
    let schedule = project
        .routing
        .schedule(&track_ids, &links)
        .map_err(|e| e.to_string())?;
    let (node_order, graph) =
        build_graph(project, &schedule, &lane_index, automation, tempo, rate, max_tracks)?;

    // Resolve the two legacy send lanes to dense slots ONCE, control-side, so
    // the audio thread indexes `RtTrack::lanes` and never looks up a string.
    // `build_lane_index` already refuses a session with more than
    // `MAX_TRACK_LANES` (32) lanes, so a slot always fits in a u8.
    let send_lane_slots = [
        lane_index.get(auto::TRACK_SEND_A_LEVEL).map(|s| *s as u8),
        lane_index.get(auto::TRACK_SEND_B_LEVEL).map(|s| *s as u8),
    ];

    Ok(Box::new(RtSession {
        tracks: tracks.into_boxed_slice(),
        lane_index,
        send_lane_slots,
        node_order: node_order.into_boxed_slice(),
        graph,
    }))
}

// ---------------------------------------------------------------------------
// E5-graph: baking the routing graph (DESIGN-E5-routing.md §2.1, §6.2, §16,
// §19). Everything below is CONTROL-SIDE. The audio thread receives flat,
// preallocated slices and walks them by index.
// ---------------------------------------------------------------------------

/// Accumulator slot for a `NodeRef` in `routing_rt`'s flat slot space.
fn acc_slot_of(project: &Project, r: &NodeRef) -> Option<usize> {
    match r {
        NodeRef::Master => Some(ACC_MASTER),
        NodeRef::Node(id) => project.routing.node_index(id),
        NodeRef::Track(id) => project
            .tracks
            .iter()
            .position(|t| t.id == *id)
            .map(|i| ACC_TRACK_BASE + i),
    }
}

fn acc_slot_name(project: &Project, slot: usize) -> String {
    match slot {
        ACC_FX_A => "the legacy reverb bus".into(),
        ACC_FX_B => "the legacy delay bus".into(),
        ACC_MASTER => "master".into(),
        s if s >= ACC_TRACK_BASE => project
            .tracks
            .get(s - ACC_TRACK_BASE)
            .map(|t| format!("track.{}", t.id))
            .unwrap_or_else(|| format!("track slot {}", s - ACC_TRACK_BASE)),
        s => project
            .routing
            .nodes
            .get(s)
            .map(|n| format!("bus.{}", n.id))
            .unwrap_or_else(|| format!("node slot {s}")),
    }
}

/// Every fx chain in the project, in the ONE canonical order: tracks in
/// project order, then routing nodes in declaration order, then master.
///
/// **This order is the fx slot assignment**, and it must be identical in
/// `build_graph` and in [`sync_graph_params`] or a compressor would read
/// another effect's threshold. It also matches `Project::sidechain_links`'s
/// order, deliberately: one traversal rule, spelled once.
fn fx_hosts(project: &Project) -> Vec<(NodeRef, &[timeline_core::model::Fx])> {
    let mut out: Vec<(NodeRef, &[timeline_core::model::Fx])> = Vec::new();
    for t in &project.tracks {
        out.push((NodeRef::Track(t.id.clone()), &t.fx));
    }
    for n in &project.routing.nodes {
        out.push((NodeRef::Node(n.id.clone()), &n.fx));
    }
    out.push((NodeRef::Master, &project.master.fx));
    out
}

fn fx_kind_id(kind: timeline_core::model::FxKind) -> FxKindId {
    use timeline_core::model::FxKind as K;
    match kind {
        K::Eq => FxKindId::Eq,
        K::Compressor => FxKindId::Compressor,
        K::Gate => FxKindId::Gate,
        K::Delay => FxKindId::Delay,
        K::Reverb => FxKindId::Reverb,
        K::Saturator => FxKindId::Saturator,
        K::Chorus => FxKindId::Chorus,
        K::Utility => FxKindId::Utility,
        K::Limiter => FxKindId::Limiter,
    }
}

/// Model edge indices in SCHEDULE order — **the one implementation of the
/// edge-slot ordering rule** (§6.2: "flat, sorted by source in SCHEDULE
/// order"). `build_graph` uses it to lay out `RtEdge`s and assign atomic
/// slots; [`sync_graph_params`] uses it to push levels into those same slots.
/// Two implementations of this rule would permute the mix.
fn edge_order(project: &Project, schedule: &[timeline_core::routing::ScheduleStep]) -> Vec<usize> {
    let mut out = Vec::with_capacity(project.routing.edges.len());
    for step in schedule {
        for (i, e) in project.routing.edges.iter().enumerate() {
            if e.from == step.node {
                out.push(i);
            }
        }
    }
    // An edge whose source the schedule never enumerated (a dangling
    // reference) still needs a slot, or the level a host pushes for it would
    // land on somebody else's edge. It gets one at the end, and no RtEdge.
    for i in 0..project.routing.edges.len() {
        if !out.contains(&i) {
            out.push(i);
        }
    }
    out
}

/// Is `path` an fx-parameter lane (`track.fx.*` / `bus.<id>.fx.*` /
/// `master.fx.*`)?
///
/// Fx lanes are EXCLUDED from the per-track dense slot table
/// (`build_lane_index`) and live on the fx instance instead (`RtFx::lanes`,
/// baked by [`bake_fx_lanes`]): an fx lane belongs to an fx INSTANCE — a bus
/// or master chain has no `RtTrack` to hang a slot on — and the dense table's
/// `MAX_TRACK_LANES` (32) budget is a session-wide resource that a couple of
/// automated chains would otherwise exhaust. One mechanism for all three host
/// spellings, one budget (`MAX_FX_TOTAL` x per-kind key count) for fx lanes.
fn is_fx_lane_path(path: &str) -> bool {
    use timeline_core::ParamRefKind as K;
    match timeline_core::ParamRef::parse(path) {
        Ok(r) => matches!(
            r.kind(),
            K::TrackFxParam { .. } | K::BusFxParam { .. } | K::MasterFxParam { .. }
        ),
        Err(_) => false,
    }
}

/// Resolve and bake every fx-parameter automation lane onto its fx instance.
///
/// `lane_has_reader` already gated these paths BY KEY (a pure path function
/// cannot see the fx kind); this is the KIND-AWARE half of the refusal, run
/// where the project is in hand. Everything refused here is refused LOUDLY,
/// naming the lane, the reason and the way out — never compiled into a
/// binding nothing reads, which is §0 row 7's defect:
///
/// - a lane naming an fx id its host does not carry (the fx existed when the
///   point was drawn and was later `fx.remove`d, or the store was built by
///   hand) — the `route.edge.<id>.level` dangling-edge precedent;
/// - a lane on a key its resolved KIND does not declare (`mix` on an `Eq`):
///   §16.3 forbids validating the (kind, key) pairing at apply time because
///   apply runs on replay, so the pairing is enforced here, render-side,
///   where refusing cannot break an open;
/// - a `bus.*`/`master.*` fx lane authored on more than one track: the lane
///   store is keyed `(track, path)` but the parameter is SESSION-scoped, so
///   nothing says which track's lane wins — the `bus.<id>.gain` precedent,
///   refused rather than resolved by iteration luck;
/// - (belt, unreachable while the key-rate consistency test holds) a lane
///   whose resolved spec is `FxParamRate::Block`: the per-key gate already
///   refused the path, but the kind-aware check re-asserts it so a drifted
///   classification cannot hand a lane to a coefficient slot.
///
/// Track-fx lanes (`track.fx.*`) are track-relative, like `track.volume`: the
/// lane on track T binds to T's OWN chain, so two tracks may each carry a
/// lane on the same path without ambiguity.
///
/// Returns bindings keyed by flat fx index (== fx slot: both walks are
/// `fx_hosts` order), each sorted by `param_index` for a deterministic
/// application order.
fn bake_fx_lanes(
    automation: &AutomationStore,
    fx_lookup: &BTreeMap<(NodeRef, String), (usize, FxKindId)>,
    tempo: &TempoMap,
    rate: u32,
) -> Result<BTreeMap<usize, Vec<RtFxLane>>, String> {
    use timeline_core::ParamRefKind as K;
    let mut out: BTreeMap<usize, Vec<RtFxLane>> = BTreeMap::new();
    for (track_id, path) in automation.iter_lane_keys() {
        let Ok(r) = timeline_core::ParamRef::parse(path) else {
            continue;
        };
        let (host, fx_id, key) = match r.kind() {
            K::TrackFxParam { fx_id, param } => {
                (NodeRef::Track(track_id.to_string()), fx_id, param)
            }
            K::BusFxParam {
                bus_id,
                fx_id,
                param,
            } => (NodeRef::Node(bus_id.to_string()), fx_id, param),
            K::MasterFxParam { fx_id, param } => (NodeRef::Master, fx_id, param),
            _ => continue,
        };
        if !matches!(host, NodeRef::Track(_)) {
            let mut owners = automation.tracks_for_path(path);
            owners.sort_unstable();
            owners.dedup();
            if owners.len() > 1 {
                return Err(format!(
                    "automation lane '{path}' has points on more than one track ({}); \
                     an fx parameter on {host} is SESSION-scoped, so nothing says \
                     which track's lane wins. Clear all but one with autolane.clear — \
                     this is refused rather than resolved by iteration luck",
                    owners.join(", ")
                ));
            }
        }
        let Some((flat_idx, kind)) = fx_lookup.get(&(host.clone(), fx_id.to_string())) else {
            return Err(format!(
                "automation lane '{path}' on track {track_id} names fx '{fx_id}' on \
                 {host}, which this project does not contain; refused rather than \
                 compiled into a binding nothing reads. NOTHING IS LOST — the points \
                 are still saved and still undoable (autolane.clear removes the lane)"
            ));
        };
        let Some(param_index) = kind.param_index(key) else {
            return Err(format!(
                "automation lane '{path}' on track {track_id} binds to fx '{fx_id}' on \
                 {host}, which is a '{}' — a kind with no '{key}' parameter — so the \
                 lane would render nothing. Clear it with autolane.clear, or automate \
                 a key this kind declares. NOTHING IS LOST — the points are still \
                 saved and still undoable",
                kind.wire_name()
            ));
        };
        // Belt for the per-key gate: unreachable while
        // `fx_key_rate_is_consistent_across_kinds` holds, load-bearing the day
        // it does not.
        if kind.params()[param_index].rate != FxParamRate::Frame {
            return Err(format!(
                "automation lane '{path}' on track {track_id}: '{key}' on a '{}' is a \
                 block-rate COEFFICIENT parameter and has no per-frame reader ({}); \
                 clear the lane with autolane.clear",
                kind.wire_name(),
                crate::rt::lane_gap_reason(path)
            ));
        }
        if let Some(lane) = automation.bake_path(track_id, path, tempo, rate) {
            out.entry(*flat_idx).or_default().push(RtFxLane {
                param_index: param_index as u8,
                lane,
                cursor: 0,
            });
        }
    }
    for lanes in out.values_mut() {
        lanes.sort_by_key(|l| l.param_index);
    }
    Ok(out)
}

/// Push every routing/effect atomic for `project` into `params`, in exactly
/// the slot order `compile` assigns, then clear every retired slot.
///
/// This is the PUSH half of §6.3's stale-slot discipline and the §23.1
/// edge-level push. It lives here, next to the slot assignment, because
/// "which slot is this edge" is a fact `compile` owns — a host cannot derive
/// it (declaration order is not schedule order) and guessing it permutes the
/// mix.
///
/// ⚠️ **`seed_fx_defaults` runs BEFORE the stored parameters** (§23.5). An
/// unseeded compressor reads `ratio = 0`; the clamp catches it, so it does not
/// blow up — it is simply *neutral*, and the user's effect silently does
/// nothing while every model-level test passes.
///
/// ⚠️ **`bypass` occupies NO parameter slot** (§23.5). `set_fx_param_by_key`
/// routes it to `set_fx_bypass`; it must never be given a slot, because a slot
/// nothing reads is the inert-lane defect this epic began with.
pub fn sync_graph_params(project: &Project, params: &EngineParams) {
    let track_ids: Vec<&str> = project.tracks.iter().map(|t| t.id.as_str()).collect();
    let links = project.sidechain_links();
    // A cyclic graph cannot be pushed (there is no schedule), but it also
    // cannot be compiled, so the session never changes and the previous slots
    // stay valid. Clearing everything would silence a mix that is still
    // playing correctly.
    if let Ok(schedule) = project.routing.schedule(&track_ids, &links) {
        for (slot, model_idx) in edge_order(project, &schedule).into_iter().enumerate() {
            if let Some(e) = project.routing.edges.get(model_idx) {
                params.set_edge_level(slot, e.level.as_f64() as f32);
            }
        }
    }
    params.clear_edge_levels_from(project.routing.edges.len());

    // The node-fader push. `route.node.set` writes `RouteNode::gain_db` (dB,
    // `Num`); the render side reads `node_gain_target(slot)` which converts
    // once per block via `db_to_lin` — the same dB-atomic/linear-read seam
    // every track fader uses (`set_track_gain_db` / `track_gain_target`).
    // Slot = DECLARATION index: `build_graph` maps `NodeStepKind::Node(i)`
    // through `routing.node_index(id)`, which is this same enumeration order.
    // Without this loop the fader is silently unity — §0 row 7's bug (a value
    // the model carries and nothing pushes), the exact class this epic was
    // started to fix. The automation lane (`bus.<id>.gain`), when present,
    // takes precedence in the reader; the atomic is the static half.
    for (slot, n) in project.routing.nodes.iter().enumerate() {
        params.set_node_gain_db(slot, n.gain_db.as_f64() as f32);
    }
    params.clear_node_gains_from(project.routing.nodes.len());

    let mut fx_slot = 0_usize;
    for (_, chain) in fx_hosts(project) {
        for f in chain {
            if fx_slot >= MAX_FX_TOTAL {
                break;
            }
            let kind = fx_kind_id(f.kind);
            seed_fx_defaults(params, kind, fx_slot);
            for (key, value) in &f.params {
                let v = value.as_f64();
                if v.is_finite() {
                    set_fx_param_by_key(params, kind, fx_slot, key, v as f32);
                }
            }
            fx_slot += 1;
        }
    }
    params.clear_fx_params_from(fx_slot * MAX_FX_PARAMS_PER_FX);
}

/// Bake the schedule, the edges, the insert chains, the node lanes and the
/// delay compensation into the flat structures the audio thread walks.
#[allow(clippy::too_many_arguments)]
fn build_graph(
    project: &Project,
    schedule: &[timeline_core::routing::ScheduleStep],
    lane_index: &BTreeMap<String, usize>,
    automation: &AutomationStore,
    tempo: &TempoMap,
    rate: u32,
    max_tracks: usize,
) -> Result<(Vec<NodeStep>, RtGraph), String> {
    let routing = &project.routing;
    check_cap("routing nodes", routing.nodes.len(), MAX_ROUTE_NODES)?;
    check_cap("routing edges", routing.edges.len(), MAX_ROUTE_EDGES)?;

    // ---- effect chains -------------------------------------------------
    // Slot assignment first, because PDC needs each host's own latency and
    // `FxKindId::latency_frames()` is available BEFORE construction (§23.5).
    let hosts = fx_hosts(project);
    let mut total_fx = 0_usize;
    let n_slots = node_acc_len(max_tracks);
    let mut own_latency = vec![0_u32; n_slots];
    // (host, fx id) -> (flat fx index, kind), for fx-lane resolution. Filled
    // by the SAME walk that assigns slots, so the mapping cannot disagree with
    // the instantiation below.
    let mut fx_lookup: BTreeMap<(NodeRef, String), (usize, FxKindId)> = BTreeMap::new();
    for (host, chain) in &hosts {
        check_cap(
            &format!("effects in the chain on {host}"),
            chain.len(),
            MAX_FX_PER_CHAIN,
        )?;
        for f in *chain {
            let kind = fx_kind_id(f.kind);
            // §23.4: reject an fx kind needing more than the per-fx stride
            // rather than aliasing into the next effect's parameter block.
            if kind.param_count() > MAX_FX_PARAMS_PER_FX {
                return Err(format!(
                    "effect {} on {host} is a '{}', which declares {} parameter keys; \
                     the engine reserves {MAX_FX_PARAMS_PER_FX} parameter slots per \
                     effect and refuses rather than aliasing into the next effect's \
                     block",
                    f.id,
                    kind.wire_name(),
                    kind.param_count()
                ));
            }
            fx_lookup.insert((host.clone(), f.id.clone()), (total_fx, kind));
            total_fx += 1;
        }
        if let Some(slot) = acc_slot_of(project, host) {
            own_latency[slot] = chain
                .iter()
                .map(|f| fx_kind_id(f.kind).latency_frames())
                .sum();
        }
    }
    check_cap("effect instances", total_fx, MAX_FX_TOTAL)?;

    // ---- fx parameter lanes (per-frame readers on the fx instances) -----
    let mut fx_lane_map = bake_fx_lanes(automation, &fx_lookup, tempo, rate)?;

    // ---- node fader lanes (§6.5) ---------------------------------------
    let mut node_gain_lanes: Vec<Option<crate::automation::AutoLane>> =
        (0..routing.nodes.len()).map(|_| None).collect();
    for (idx, node) in routing.nodes.iter().enumerate() {
        let path = format!("bus.{}.gain", node.id);
        let owners = automation.tracks_for_path(&path);
        if owners.len() > 1 {
            return Err(format!(
                "automation lane '{path}' has points on more than one track ({}); a \
                 routing node's fader is SESSION-scoped, so nothing says which \
                 track's lane wins. Clear all but one with autolane.clear — this is \
                 refused rather than resolved by iteration luck",
                owners.join(", ")
            ));
        }
        if let Some(owner) = owners.first() {
            node_gain_lanes[idx] = automation.bake_path(owner, &path, tempo, rate);
        }
    }

    // ---- edge level lanes (§6.5) ---------------------------------------
    // A `route.edge.<id>.level` lane lives on a TRACK, and the walk reads it
    // from the SOURCE track's dense table. A lane authored on any other track
    // would be handed a slot nothing looks at — the inert-lane defect — so it
    // is refused by name.
    let mut edge_lane_slot: Vec<u16> = vec![NO_LANE; routing.edges.len()];
    for (track_id, path) in automation.iter_lane_keys() {
        let Ok(r) = timeline_core::ParamRef::parse(path) else {
            continue;
        };
        let timeline_core::ParamRefKind::RouteEdgeLevel { edge_id } = r.kind() else {
            continue;
        };
        let Some(edge_idx) = routing.edge_index(edge_id) else {
            return Err(format!(
                "automation lane '{path}' on track {track_id} names edge '{edge_id}', \
                 which this project does not contain; refused rather than compiled \
                 into a slot nothing reads. NOTHING IS LOST — the points are still \
                 saved and still undoable (autolane.clear removes the lane)"
            ));
        };
        let edge = &routing.edges[edge_idx];
        if edge.from != NodeRef::Track(track_id.to_string()) {
            return Err(format!(
                "automation lane '{path}' is on track {track_id}, but edge '{edge_id}' \
                 is sourced by {}. An edge level is read from its SOURCE track's lane \
                 table, so this lane would render nothing. Move it to the source, or \
                 clear it with autolane.clear. (A bus-sourced edge cannot be \
                 automated at all in this build — DESIGN-E5-routing.md §6.5.)",
                edge.from
            ));
        }
        if let Some(slot) = lane_index.get(path) {
            edge_lane_slot[edge_idx] = *slot as u16;
        }
    }

    // ---- edges, in SCHEDULE order (§6.2) --------------------------------
    let order = edge_order(project, schedule);
    let mut level_slot_of: Vec<u16> = vec![0; routing.edges.len()];
    let mut edge_index: BTreeMap<String, usize> = BTreeMap::new();
    for (slot, model_idx) in order.iter().copied().enumerate() {
        level_slot_of[model_idx] = slot as u16;
        edge_index.insert(routing.edges[model_idx].id.clone(), slot);
    }

    // ---- the walk order + per-step edge ranges --------------------------
    let mut steps: Vec<(NodeStepKind, Option<NodeRef>)> = Vec::with_capacity(schedule.len() + 1);
    for step in schedule {
        let kind = match &step.node {
            NodeRef::Master => NodeStepKind::Master,
            NodeRef::Track(id) => match project.tracks.iter().position(|t| t.id == *id) {
                Some(i) => NodeStepKind::Track(i),
                None => NodeStepKind::Skip,
            },
            NodeRef::Node(id) => match routing.node_index(id) {
                Some(i) => NodeStepKind::Node(i),
                None => NodeStepKind::Skip,
            },
        };
        // §2.1: the two legacy FX buses are DESUGARED — render-side-only
        // compiled nodes with no wire form, never written to the model. They
        // sit immediately before master, exactly where the pre-E5 tail had
        // them, and as ONE step so `master += rev * ra + del * rb` stays a
        // single (non-associative) expression.
        if matches!(kind, NodeStepKind::Master) {
            steps.push((NodeStepKind::LegacyReturns, None));
        }
        steps.push((kind, Some(step.node.clone())));
    }

    let mut edges: Vec<RtEdge> = Vec::new();
    let mut pdc_edges: Vec<(usize, usize)> = Vec::new();
    let mut node_order: Vec<NodeStep> = Vec::with_capacity(steps.len());
    let mut fx_ranges: BTreeMap<NodeRef, (u32, u32)> = BTreeMap::new();
    {
        let mut next = 0_u32;
        for (host, chain) in &hosts {
            let lo = next;
            next += chain.len() as u32;
            fx_ranges.insert(host.clone(), (lo, next));
        }
    }

    for (kind, node_ref) in &steps {
        let lo = edges.len() as u32;
        if let Some(nr) = node_ref {
            let src_slot = acc_slot_of(project, nr);
            for (model_idx, e) in routing.edges.iter().enumerate() {
                if e.from != *nr {
                    continue;
                }
                let Some(dest) = acc_slot_of(project, &e.to) else {
                    return Err(format!(
                        "edge {} points at {}, which this project does not contain",
                        e.id, e.to
                    ));
                };
                edges.push(RtEdge {
                    dest: dest as u16,
                    tap: e.tap,
                    level_slot: level_slot_of[model_idx],
                    level_lane: edge_lane_slot[model_idx],
                    comp: 0,
                });
                pdc_edges.push((src_slot.unwrap_or(usize::MAX), dest));
            }
            // §4.2: N keeps its implicit unity post-tap edge to master IFF the
            // routing declares no `post`-tap edge with `from == N`. Pre-tap
            // edges are sends and never suppress it.
            //
            // **E5-graph CALLS the model's predicate and does not reimplement
            // it** (§11.1) — two implementations that disagree is a mix that
            // changes depending on which code path ran.
            if !matches!(kind, NodeStepKind::Skip | NodeStepKind::Master)
                && routing.has_implicit_master_feed(nr)
            {
                edges.push(RtEdge {
                    dest: ACC_MASTER as u16,
                    tap: timeline_core::routing::Tap::Post,
                    level_slot: IMPLICIT_UNITY,
                    level_lane: NO_LANE,
                    comp: 0,
                });
                pdc_edges.push((src_slot.unwrap_or(usize::MAX), ACC_MASTER));
            }
        }
        let hi = edges.len() as u32;
        let fx = node_ref
            .as_ref()
            .and_then(|nr| fx_ranges.get(nr).copied())
            .unwrap_or((0, 0));
        node_order.push(NodeStep {
            kind: *kind,
            out_edges: (lo, hi),
            fx,
        });
    }

    // ---- delay compensation (§19.2) -------------------------------------
    // The legacy sends and returns are built into the walk rather than being
    // `RtEdge`s (§2.1 keeps them bit-exact), so they enter the PDC graph as
    // pseudo-edges: every track can feed either bus, and both feed master.
    // They carry no compensation of their own — see the honest limitation
    // recorded on `RtGraph::legacy_comp`.
    let mut pdc_pseudo: Vec<(usize, usize)> = Vec::new();
    for i in 0..project.tracks.len() {
        pdc_pseudo.push((ACC_TRACK_BASE + i, ACC_FX_A));
        pdc_pseudo.push((ACC_TRACK_BASE + i, ACC_FX_B));
    }
    let legacy_return_base = pdc_edges.len() + pdc_pseudo.len();
    pdc_pseudo.push((ACC_FX_A, ACC_MASTER));
    pdc_pseudo.push((ACC_FX_B, ACC_MASTER));
    let mut all_pdc = pdc_edges.clone();
    all_pdc.extend_from_slice(&pdc_pseudo);

    let mut pdc_order: Vec<usize> = Vec::with_capacity(node_order.len() + 2);
    for step in &node_order {
        match step.kind {
            NodeStepKind::Track(i) => pdc_order.push(ACC_TRACK_BASE + i),
            NodeStepKind::Node(i) => pdc_order.push(i),
            NodeStepKind::LegacyReturns => {
                pdc_order.push(ACC_FX_A);
                pdc_order.push(ACC_FX_B);
            }
            NodeStepKind::Master => pdc_order.push(ACC_MASTER),
            NodeStepKind::Skip => {}
        }
    }
    let pdc_links: Vec<(usize, usize)> = project
        .sidechain_links()
        .iter()
        .filter_map(|(src, host)| {
            Some((acc_slot_of(project, src)?, acc_slot_of(project, host)?))
        })
        .collect();
    let pdc = crate::pdc::compute(
        &pdc_order,
        &all_pdc,
        &pdc_links,
        &own_latency,
        n_slots,
        &|s| acc_slot_name(project, s),
    )?;
    for (i, e) in edges.iter_mut().enumerate() {
        e.comp = pdc.comp[i];
    }
    let legacy_comp = [pdc.comp[legacy_return_base], pdc.comp[legacy_return_base + 1]];

    let comp_rings: Vec<CompDelay> = edges.iter().map(|e| CompDelay::new(e.comp)).collect();

    // ---- instantiate the effects ----------------------------------------
    // Every allocation an effect will ever need — rings, filter tables —
    // happens HERE, once, control-side, exactly like `build_instrument`.
    let mut fx: Vec<RtFx> = Vec::with_capacity(total_fx);
    let mut fx_slot = 0_u32;
    for (host, chain) in &hosts {
        for f in *chain {
            let key_src = f
                .sidechain
                .as_ref()
                .and_then(|s| acc_slot_of(project, s))
                .map(|s| s as u16);
            if let Some(src) = &f.sidechain {
                if acc_slot_of(project, src).is_none() {
                    return Err(format!(
                        "effect {} on {host} is keyed by {src}, which this project does \
                         not contain",
                        f.id
                    ));
                }
            }
            fx.push(RtFx {
                unit: FxUnit::new(fx_kind_id(f.kind), rate, MICRO_FADE_FRAMES as u32),
                fx_slot,
                key_src,
                // `fx_slot` and `bake_fx_lanes`'s flat index are the same
                // `fx_hosts` walk, so this attach cannot land on the wrong
                // instance without the debug_assert below firing first.
                lanes: fx_lane_map
                    .remove(&(fx_slot as usize))
                    .map(Vec::into_boxed_slice)
                    .unwrap_or_default(),
            });
            fx_slot += 1;
        }
    }
    debug_assert_eq!(
        fx.len(),
        total_fx,
        "the fx slot walk and the fx instantiation walk must be the same walk"
    );
    debug_assert!(
        fx_lane_map.is_empty(),
        "every baked fx lane must land on an instantiated fx (leftover keys: {:?})",
        fx_lane_map.keys().collect::<Vec<_>>()
    );
    let _ = base_slot_of(0);

    Ok((
        node_order,
        RtGraph {
            edges: edges.into_boxed_slice(),
            comp_rings: comp_rings.into_boxed_slice(),
            fx: fx.into_boxed_slice(),
            node_gain_lanes: node_gain_lanes.into_boxed_slice(),
            edge_index,
            edge_level_count: routing.edges.len(),
            node_count: routing.nodes.len(),
            legacy_comp,
            legacy_rings: [
                CompDelay::new(legacy_comp[0]),
                CompDelay::new(legacy_comp[1]),
            ],
        },
    ))
}

/// Instantiate the track's instrument (E1/E2 wiring), or `None` for a plain
/// audio track. CONTROL-SIDE: every allocation an instrument will ever need —
/// the voice pool, the oscillators, the filters — happens here, once.
///
/// Bindings resolved here, so the audio thread never looks anything up:
/// - `Device.params` (`Num`) -> `InstrumentParams` (`f32`). THE one conversion.
/// - `track.device.<deviceId>.<paramKey>` -> dense automation lane slot, from
///   the same `lane_index` volume and pan come from.
///
/// The node is built with an EMPTY `NoteSchedule` on purpose: the engine drives
/// it from E1's `NoteCursor` over `RtTrack::notes`. See `rt::TrackInstrument`.
fn build_instrument(
    track: &timeline_core::Track,
    sources: &HashMap<String, Arc<AudioBuf>>,
    lane_index: &BTreeMap<String, usize>,
    sample_rate: u32,
) -> Result<Option<Box<TrackInstrument>>, String> {
    use timeline_core::model::DeviceKind;

    // One instrument node per track in this build (see `RtTrack::notes`): the
    // note lane is per track, so a second instrument device would have no
    // separate note source to play. Refuse rather than silently ignore it.
    let instruments: Vec<_> = track.devices.iter().collect();
    let device = match instruments.split_first() {
        None => return Ok(None),
        Some((first, rest)) => {
            if !rest.is_empty() {
                return Err(format!(
                    "track {} has {} devices; this build binds ONE instrument per track \
                     (the baked note lane is per track, so a second instrument would have \
                     no notes to play)",
                    track.id,
                    instruments.len()
                ));
            }
            *first
        }
    };

    let instrument = match device.kind {
        DeviceKind::Synth => Instrument::Synth(Synth::new(
            sample_rate,
            NODE_VOICES,
            MICRO_FADE_FRAMES as u32,
        )),
        // `Device.zones` is the source binding. Every zone resolves through the
        // SAME `sources` map, with the SAME loud failure, that a clip's
        // `source_id` resolves through above — one lookup path, one error.
        DeviceKind::Sampler => Instrument::Sampler(Sampler::new(
            Arc::new(build_sample_map(track, device, sources)?),
            sample_rate,
            NODE_VOICES,
            MICRO_FADE_FRAMES as u32,
        )),
        DeviceKind::Drum => Instrument::Drum(DrumRack::new(
            Arc::new(build_drum_kit(track, device, sources)?),
            sample_rate,
            NODE_VOICES,
            MICRO_FADE_FRAMES as u32,
        )),
    };

    // Authored parameters, Num -> f32, ONCE, here.
    let mut base = InstrumentParams::default();
    for (slot, key) in INSTRUMENT_PARAM_KEYS.iter().enumerate() {
        if let Some(v) = device.params.get(*key) {
            let f = v.as_f64();
            if !f.is_finite() {
                return Err(format!(
                    "track {}: device {} param '{}' is not finite",
                    track.id, device.id, key
                ));
            }
            base.set(slot, f as f32);
        }
    }

    // ParamRef -> dense lane slot. `MAX_TRACK_LANES` is 32 and `build_lane_index`
    // already refuses more, so a slot always fits in a u8.
    let mut slots: [Option<u8>; INSTRUMENT_PARAM_COUNT] = [None; INSTRUMENT_PARAM_COUNT];
    for (idx, key) in INSTRUMENT_PARAM_KEYS.iter().enumerate() {
        let path = format!("track.device.{}.{}", device.id, key);
        if let Some(slot) = lane_index.get(&path) {
            slots[idx] = Some(*slot as u8);
        }
    }

    let node = InstrumentNode::new(device.id.clone(), instrument, Vec::new());
    let mut ti = TrackInstrument::new(node, base, slots);
    // Settle the ramps here too, so a node is already on-target the moment it is
    // installed even if the install path ever stops snapping.
    ti.node.snap_to(&base);
    Ok(Some(Box::new(ti)))
}

/// Resolve one zone's `source_id` to loaded audio.
///
/// THE point of this function is that it is the same lookup, against the same
/// map, with the same shape of error, as the clip path above. A sampler that
/// silently rendered nothing because its asset was not loaded is precisely the
/// silent-degradation class this program keeps catching, so an unloaded source
/// is a hard, control-side compile error — never an empty zone.
fn resolve_zone_audio<'a>(
    track: &timeline_core::Track,
    device: &timeline_core::model::Device,
    zone: &timeline_core::model::DeviceZone,
    sources: &'a HashMap<String, Arc<AudioBuf>>,
) -> Result<&'a Arc<AudioBuf>, String> {
    let audio = sources.get(&zone.source_id).ok_or_else(|| {
        format!(
            "track {}: device {} zone {} references unloaded source {}",
            track.id, device.id, zone.id, zone.source_id
        )
    })?;
    if audio.len_frames() == 0 {
        return Err(format!(
            "track {}: device {} zone {} resolves to zero-length audio ({})",
            track.id, device.id, zone.id, zone.source_id
        ));
    }
    Ok(audio)
}

/// A zone boundary as a MIDI note number. Control-side and loud: an
/// out-of-range or non-finite value would otherwise silently clamp a zone onto
/// the edge of the keyboard.
fn zone_pitch(
    track: &timeline_core::Track,
    device: &timeline_core::model::Device,
    zone_id: &str,
    what: &str,
    n: &timeline_core::Num,
) -> Result<u8, String> {
    let v = n.as_f64();
    if !v.is_finite() || v < 0.0 || v > 127.0 || v.fract() != 0.0 {
        return Err(format!(
            "track {}: device {} zone {} {what} {v} is not an integer MIDI note in [0, 127]",
            track.id, device.id, zone_id
        ));
    }
    Ok(v as u8)
}

/// Build the sampler's zone map from `Device.zones`.
///
/// The zones arrive in the model's `(lo_pitch, id)` order and are handed over
/// in that order, so `SampleMap::zone_for`'s "first zone covering the pitch in
/// declaration order" is a deterministic function of the project — never of
/// insertion order — which is what keeps a bounce reproducible.
fn build_sample_map(
    track: &timeline_core::Track,
    device: &timeline_core::model::Device,
    sources: &HashMap<String, Arc<AudioBuf>>,
) -> Result<SampleMap, String> {
    if device.zones.is_empty() {
        return Err(format!(
            "track {}: sampler device {} has no zones, so it could only render silence — \
             bind a source with device.zone.add",
            track.id, device.id
        ));
    }
    let mut zones = Vec::with_capacity(device.zones.len());
    for z in &device.zones {
        let audio = resolve_zone_audio(track, device, z, sources)?;
        let lo = zone_pitch(track, device, &z.id, "loPitch", &z.lo_pitch)?;
        let hi = zone_pitch(track, device, &z.id, "hiPitch", &z.hi_pitch)?;
        let root = zone_pitch(track, device, &z.id, "rootPitch", &z.root_pitch)?;
        if hi < lo {
            return Err(format!(
                "track {}: device {} zone {} has hiPitch {hi} below loPitch {lo}",
                track.id, device.id, z.id
            ));
        }
        let gain_db = z.gain.as_f64();
        if !gain_db.is_finite() {
            return Err(format!(
                "track {}: device {} zone {} gain is not finite",
                track.id, device.id, z.id
            ));
        }
        zones.push(SampleZone {
            audio: Arc::clone(audio),
            root_pitch: root,
            lo_pitch: lo,
            hi_pitch: hi,
            // Num -> f32, ONCE, here. Same conversion point as the device
            // params above and the clip gains further up.
            gain_lin: db_to_lin(gain_db as f32),
        });
    }
    Ok(SampleMap::new(zones))
}

/// Build the drum rack's kit from `Device.zones`.
///
/// A pad is ONE key (`apply.rs` refuses `hi != lo` on a drum device), so each
/// zone lands on exactly one pad. The rack is a fixed 16-slot grid, so the base
/// pitch is the lowest bound pad and the span has to fit; a kit that does not
/// fit is refused rather than silently truncated to the pads that do.
fn build_drum_kit(
    track: &timeline_core::Track,
    device: &timeline_core::model::Device,
    sources: &HashMap<String, Arc<AudioBuf>>,
) -> Result<DrumKit, String> {
    if device.zones.is_empty() {
        return Err(format!(
            "track {}: drum device {} has no pads, so it could only render silence — \
             bind a source with device.zone.add",
            track.id, device.id
        ));
    }
    let mut bound: Vec<(u8, DrumPad)> = Vec::with_capacity(device.zones.len());
    for z in &device.zones {
        let audio = resolve_zone_audio(track, device, z, sources)?;
        let lo = zone_pitch(track, device, &z.id, "loPitch", &z.lo_pitch)?;
        let hi = zone_pitch(track, device, &z.id, "hiPitch", &z.hi_pitch)?;
        if hi != lo {
            return Err(format!(
                "track {}: device {} is a drum rack, where a pad covers exactly one key, \
                 but zone {} spans {lo}..={hi}",
                track.id, device.id, z.id
            ));
        }
        let gain_db = z.gain.as_f64();
        let pan = z.pan.as_f64();
        if !gain_db.is_finite() || !pan.is_finite() {
            return Err(format!(
                "track {}: device {} zone {} gain or pan is not finite",
                track.id, device.id, z.id
            ));
        }
        bound.push((
            lo,
            DrumPad {
                audio: Arc::clone(audio),
                gain_lin: db_to_lin(gain_db as f32),
                pan: (pan as f32).clamp(-1.0, 1.0),
            },
        ));
    }
    // `bound` is already in the model's (lo_pitch, id) order.
    let base = bound[0].0;
    let top = bound[bound.len() - 1].0;
    if (top - base) as usize >= RACK_PADS {
        return Err(format!(
            "track {}: drum device {} spans pitches {base}..={top}, wider than the \
             {RACK_PADS}-pad rack; refusing rather than dropping the pads that do not fit",
            track.id, device.id
        ));
    }
    let mut pads: Vec<Option<DrumPad>> = (0..RACK_PADS).map(|_| None).collect();
    for (pitch, pad) in bound {
        let idx = (pitch - base) as usize;
        if pads[idx].is_some() {
            return Err(format!(
                "track {}: drum device {} binds two pads to pitch {pitch}",
                track.id, device.id
            ));
        }
        pads[idx] = Some(pad);
    }
    Ok(DrumKit::new(pads, base))
}

/// The project-side facts the lane sweep resolves DANGLING lanes against:
/// which routing nodes exist, and which devices each track carries.
///
/// Why this exists: `require_param_ref_on` was deliberately widened to
/// build-static checks only — apply-time existence checks made recorded
/// inverses refusable, a lie in the journal (see the widening's doc in
/// `timeline-core/src/apply.rs`). So a lane may legally name a node or device
/// that does not exist (a `route.node.remove` / `device.remove` strands its
/// lanes; a typo'd id lands). The render compile is the one honest fence left,
/// and both of its bake paths had a HOLE: the node-fader bake iterates the
/// nodes that EXIST (a `bus.<missing>.gain` lane was never visited — silently
/// ignored), and `build_instrument` binds slots from live device ids (a lane
/// naming a missing device got a dense slot nothing reads). Both are the
/// inert-lane defect, re-entered through the back door.
///
/// Built from `&Project` by BOTH feeds — `build_lane_index` compile-side and
/// the host's per-mutation model feed — so the pairing stays single-sourced.
/// O(nodes + devices), bounded by `MAX_ROUTE_NODES` and one instrument per
/// track.
pub struct LaneTargets<'a> {
    nodes: std::collections::BTreeSet<&'a str>,
    /// track id -> the device ids that track carries. A device lane is
    /// per-track (`bake_path` bakes against the AUTHORING track, and
    /// `build_instrument` binds only that track's own device), so a lane on
    /// t1 naming t2's device is dangling ON T1 even though the id exists
    /// elsewhere.
    devices: BTreeMap<&'a str, std::collections::BTreeSet<&'a str>>,
    /// track id -> the fx ids on that track's insert chain, plus the two
    /// non-track chains. An fx lane bakes against the chain its path NAMES
    /// (`track.fx.*` against the authoring track, `bus.<id>.fx.*` against that
    /// bus, `master.fx.*` against master), so each needs its own set.
    track_fx: BTreeMap<&'a str, std::collections::BTreeSet<&'a str>>,
    bus_fx: BTreeMap<&'a str, std::collections::BTreeSet<&'a str>>,
    master_fx: std::collections::BTreeSet<&'a str>,
    /// Every routing edge id. A `route.edge.<id>.level` lane whose edge was
    /// disconnected is bound to nothing.
    edges: std::collections::BTreeSet<&'a str>,
}

impl<'a> LaneTargets<'a> {
    pub fn of(project: &'a Project) -> Self {
        Self {
            nodes: project
                .routing
                .nodes
                .iter()
                .map(|n| n.id.as_str())
                .collect(),
            devices: project
                .tracks
                .iter()
                .map(|t| {
                    (
                        t.id.as_str(),
                        t.devices.iter().map(|d| d.id.as_str()).collect(),
                    )
                })
                .collect(),
            track_fx: project
                .tracks
                .iter()
                .map(|t| (t.id.as_str(), t.fx.iter().map(|f| f.id.as_str()).collect()))
                .collect(),
            bus_fx: project
                .routing
                .nodes
                .iter()
                .map(|n| (n.id.as_str(), n.fx.iter().map(|f| f.id.as_str()).collect()))
                .collect(),
            master_fx: project.master.fx.iter().map(|f| f.id.as_str()).collect(),
            edges: project
                .routing
                .edges
                .iter()
                .map(|e| e.id.as_str())
                .collect(),
        }
    }
}

/// How a lane fails to reach the audio. One enum so the sweep stays a single
/// deterministic pass with one report shape, not a family of ad-hoc checks
/// that fire in whatever order the code happens to run.
enum LaneOffense {
    /// The path FAMILY has no per-frame reader (`rt::lane_has_reader`).
    NoReader,
    /// `bus.<id>.gain` naming a routing node this project does not contain.
    /// The node-fader bake iterates the nodes that exist, so without this
    /// check the lane is simply never visited.
    ///
    /// The id is owned: it is borrowed from a `ParamRef` parsed inside the
    /// sweep loop, which does not outlive the iteration. Control-side, cold
    /// path — the allocation is fine.
    MissingNode { node_id: String },
    /// `track.device.<id>.<key>` naming a device the AUTHORING track does not
    /// carry. `build_instrument` binds slots from live device ids only, so
    /// without this check the lane gets a dense slot nothing reads.
    MissingDevice { device_id: String },
    /// An fx param lane naming an fx instance the addressed chain no longer
    /// carries. `bake_fx_lanes` iterates the fx that EXIST, so without this it
    /// sails past the stranded lane in silence — the same shape as
    /// `MissingNode`, which is why this belongs beside it and not in the bake.
    MissingFx { fx_id: String, chain: String },
    /// `route.edge.<id>.level` naming an edge this project no longer routes.
    MissingEdge { edge_id: String },
}

/// Refuse any automation lane that cannot reach the audio: a path family with
/// no reader, OR a readable family whose named node/device does not resolve in
/// THIS project (a dangling lane — stranded by `route.node.remove` /
/// `device.remove`, or born of a typo'd id).
///
/// Takes `(track_id, path)` pairs plus [`LaneTargets`] rather than an
/// `AutomationStore` so the HOST can feed it straight from the model on every
/// mutation — cheap enough to run per command (one pass over the lane keys;
/// it never touches a clip, a note or an instrument) — while `build_lane_index`
/// feeds it from the compiled store. **One implementation, two feeds.** A
/// second copy of this rule would drift, and then the host would report a lane
/// the compiler accepts, or the reverse.
///
/// Division of labour, so nobody "fixes" it into drift later:
///   * `rt::lane_has_reader` stays a PURE PATH function: does this path FAMILY
///     have a per-frame reader in the render loop. It cannot see the project.
///   * THIS sweep is the resolution-aware half for the two families whose ids
///     bind at compile (`bus.<id>.gain`, `track.device.<id>.<key>`).
///   * `bake_fx_lanes` / the edge bake stay the kind- and instance-aware half
///     for fx and edge lanes (they need `FxKind` / `edge.from`, which live
///     beyond these two id sets).
///
/// The message is the user's whole way forward, so it carries all three things
/// they need: which parameter, which track, and that the data is recoverable.
pub fn refuse_unreadable_lanes<'a>(
    lanes: impl Iterator<Item = (&'a str, &'a str)>,
    targets: &LaneTargets<'_>,
) -> Result<(), String> {
    use timeline_core::ParamRefKind as K;
    // Deterministic: report the first offending path in sorted order, and name
    // every track carrying it, so the message does not depend on iteration luck.
    let mut offenders: BTreeMap<&'a str, (Vec<&'a str>, LaneOffense)> = BTreeMap::new();
    for (track_id, path) in lanes {
        if !crate::rt::lane_has_reader(path) {
            offenders
                .entry(path)
                .or_insert_with(|| (Vec::new(), LaneOffense::NoReader))
                .0
                .push(track_id);
            continue;
        }
        // Readable family — now resolve the id, where the family binds one.
        let Ok(r) = timeline_core::ParamRef::parse(path) else {
            continue; // unparseable is already NoReader above
        };
        match r.kind() {
            K::BusGain { bus_id } => {
                if !targets.nodes.contains(bus_id) {
                    offenders
                        .entry(path)
                        .or_insert_with(|| {
                            (Vec::new(), LaneOffense::MissingNode { node_id: bus_id.to_string() })
                        })
                        .0
                        .push(track_id);
                }
            }
            K::TrackDeviceParam { device_id, .. } => {
                // Per-TRACK: the lane bakes against its authoring track, so
                // only that track's own devices count.
                let carried = targets
                    .devices
                    .get(track_id)
                    .is_some_and(|d| d.contains(device_id));
                if !carried {
                    offenders
                        .entry(path)
                        .or_insert_with(|| {
                            (
                                Vec::new(),
                                LaneOffense::MissingDevice { device_id: device_id.to_string() },
                            )
                        })
                        .0
                        .push(track_id);
                }
            }
            // Fx lanes: resolve the INSTANCE against the chain the path names.
            // The bakes remain the kind-aware half (which FxKind declares this
            // key); this is the existence half, and a bake cannot supply it
            // because it walks what is there.
            K::TrackFxParam { fx_id, .. } => {
                let carried = targets
                    .track_fx
                    .get(track_id)
                    .is_some_and(|f| f.contains(fx_id));
                if !carried {
                    offenders
                        .entry(path)
                        .or_insert_with(|| {
                            (
                                Vec::new(),
                                LaneOffense::MissingFx {
                                    fx_id: fx_id.to_string(),
                                    chain: format!("track {track_id}"),
                                },
                            )
                        })
                        .0
                        .push(track_id);
                }
            }
            K::BusFxParam { bus_id, fx_id, .. } => {
                let carried = targets.bus_fx.get(bus_id).is_some_and(|f| f.contains(fx_id));
                if !carried {
                    offenders
                        .entry(path)
                        .or_insert_with(|| {
                            (
                                Vec::new(),
                                LaneOffense::MissingFx {
                                    fx_id: fx_id.to_string(),
                                    chain: format!("bus '{bus_id}'"),
                                },
                            )
                        })
                        .0
                        .push(track_id);
                }
            }
            K::MasterFxParam { fx_id, .. } => {
                if !targets.master_fx.contains(fx_id) {
                    offenders
                        .entry(path)
                        .or_insert_with(|| {
                            (
                                Vec::new(),
                                LaneOffense::MissingFx {
                                    fx_id: fx_id.to_string(),
                                    chain: "the master chain".to_string(),
                                },
                            )
                        })
                        .0
                        .push(track_id);
                }
            }
            K::RouteEdgeLevel { edge_id } => {
                if !targets.edges.contains(edge_id) {
                    offenders
                        .entry(path)
                        .or_insert_with(|| {
                            (
                                Vec::new(),
                                LaneOffense::MissingEdge { edge_id: edge_id.to_string() },
                            )
                        })
                        .0
                        .push(track_id);
                }
            }
            // Everything else has no id to resolve.
            _ => {}
        }
    }
    let Some((path, (tracks, offense))) = offenders.iter().next() else {
        return Ok(());
    };
    let mut tracks = tracks.clone();
    tracks.sort_unstable();
    tracks.dedup();
    let also = if offenders.len() > 1 {
        format!(
            " ({} other unrenderable lane(s) in this project: {})",
            offenders.len() - 1,
            offenders
                .keys()
                .skip(1)
                .copied()
                .collect::<Vec<_>>()
                .join(", ")
        )
    } else {
        String::new()
    };
    let owner = tracks.first().copied().unwrap_or("<trackId>");
    let owners = tracks.join(", ");
    Err(match offense {
        LaneOffense::NoReader => format!(
            "automation lane '{path}' on track {owners} cannot be rendered by this \
             build, so it is REFUSED rather than silently ignored: {}{also}. \
             NOTHING IS LOST — the points are still in the project, still saved to \
             disk, and still undoable. To render, either clear the lane with \
             autolane.clear {{\"trackId\": \"{owner}\", \"target\": \"{path}\"}} (undo \
             restores every point), or move the automation to a parameter this build \
             reads: track.volume, track.pan, track.send.a|b.level, \
             track.device.<deviceId>.<param>, bus.<nodeId>.gain, \
             route.edge.<edgeId>.level, or a frame-rate effect parameter \
             (track.fx.<fxId>.<key> / bus.<nodeId>.fx.<fxId>.<key> / \
             master.fx.<fxId>.<key> — gains, thresholds, mix, pan and similar; \
             attack/release and EQ band coefficients stay block-rate)",
            crate::rt::lane_gap_reason(path),
        ),
        LaneOffense::MissingNode { node_id } => format!(
            "automation lane '{path}' on track {owners} names routing node \
             '{node_id}', which this project does not contain, so it is REFUSED \
             rather than silently ignored: the node-fader bake resolves lanes \
             against the nodes that exist, and without this refusal the lane would \
             simply never be visited — automation that moves nothing{also}. \
             NOTHING IS LOST — the points are still in the project, still saved to \
             disk, and still undoable. Either re-create the node \
             (route.node.add {{\"nodeId\": \"{node_id}\", ...}}, or undo the \
             route.node.remove that stranded this lane), or clear the lane with \
             autolane.clear {{\"trackId\": \"{owner}\", \"target\": \"{path}\"}} \
             (undo restores every point)",
        ),
        LaneOffense::MissingDevice { device_id } => format!(
            "automation lane '{path}' on track {owners} names device '{device_id}', \
             which that track does not carry, so it is REFUSED rather than silently \
             ignored: instrument lanes bind to the track's own device at compile, \
             and without this refusal the lane would get a dense slot nothing \
             reads — automation that moves nothing{also}. \
             NOTHING IS LOST — the points are still in the project, still saved to \
             disk, and still undoable. Either re-add the device \
             (device.add {{\"trackId\": \"{owner}\", \"deviceId\": \"{device_id}\", \
             ...}}, or undo the device.remove that stranded this lane), or clear \
             the lane with autolane.clear {{\"trackId\": \"{owner}\", \
             \"target\": \"{path}\"}} (undo restores every point)",
        ),
        LaneOffense::MissingFx { fx_id, chain } => format!(
            "automation lane '{path}' on track {owners} names effect '{fx_id}', which \
             {chain} no longer carries, so it is REFUSED rather than silently \
             ignored: an fx lane binds to a live fx INSTANCE at compile, and the fx \
             bake walks the effects that exist — so a stranded lane would simply \
             never be visited, and the automation would move nothing{also}. \
             NOTHING IS LOST — the points are still in the project, still saved to \
             disk, and still undoable. Either re-add the effect (fx.add, or undo the \
             fx.remove that stranded this lane), or clear the lane with \
             autolane.clear {{\"trackId\": \"{owner}\", \"target\": \"{path}\"}} \
             (undo restores every point)",
        ),
        LaneOffense::MissingEdge { edge_id } => format!(
            "automation lane '{path}' on track {owners} names routing edge \
             '{edge_id}', which this project no longer routes, so it is REFUSED \
             rather than silently ignored: an edge level lane binds to a live edge \
             at compile, and the graph walk visits the edges that exist — so a \
             stranded lane would move nothing{also}. \
             NOTHING IS LOST — the points are still in the project, still saved to \
             disk, and still undoable. Either reconnect the edge \
             (route.connect {{\"edgeId\": \"{edge_id}\", ...}}, or undo the \
             route.disconnect that stranded this lane), or clear the lane with \
             autolane.clear {{\"trackId\": \"{owner}\", \"target\": \"{path}\"}} \
             (undo restores every point)",
        ),
    })
}

/// ParamRef path -> dense lane slot for one session.
///
/// Slots 0 and 1 are ALWAYS `track.volume` and `track.pan`, whether or not the
/// project automates them, so the render fast paths can index a constant.
/// Everything else is assigned in `BTreeSet` order — a pure function of the
/// project, never of insertion or hash order, so two compiles of the same
/// project produce the same table and therefore the same bounce.
///
/// ⚠️ **A slot is only handed out to a path something actually READS**
/// (`rt::lane_has_reader`). This function used to give a dense slot and a live
/// cursor to *every* path in the store, including paths the render loop never
/// looked at — so `track.send.a.level` automation was journaled, moved the
/// control, updated the model, and rendered bit-identically to no automation.
/// Silent. Refusing here converts that into a control-side error the user can
/// see, which is the whole lesson of that bug class.
fn build_lane_index(
    automation: &AutomationStore,
    project: &Project,
) -> Result<BTreeMap<String, usize>, String> {
    // THE gate, and the ONLY implementation of it. The host calls the same
    // function on every mutation (it is cheap — one pass over the lane keys,
    // no clips, no notes, no instruments) so a refused lane is reported the
    // moment it is drawn, rather than discovered at bounce. Two copies of this
    // rule would eventually disagree, and then the host would report a lane the
    // compiler accepts, or worse the reverse.
    //
    // `LaneTargets` makes the sweep resolution-aware: a `bus.<id>.gain` or
    // `track.device.<id>.<key>` lane whose id resolves to nothing in THIS
    // project is refused here, because the bakes downstream iterate what
    // EXISTS and would sail past the dangling lane without a sound.
    refuse_unreadable_lanes(automation.iter_lane_keys(), &LaneTargets::of(project))?;
    let mut index = BTreeMap::new();
    index.insert(auto::TRACK_VOLUME.to_string(), LANE_VOLUME);
    index.insert(auto::TRACK_PAN.to_string(), LANE_PAN);
    let mut next = LANE_FIXED;
    for path in automation.lane_paths() {
        if index.contains_key(path) {
            continue;
        }
        // Fx lanes are readable but do NOT ride the per-track dense table:
        // they bind to an fx INSTANCE (`RtFx::lanes`, baked by
        // `bake_fx_lanes`), which is what lets bus/master chains automate at
        // all and keeps them from consuming the session-wide 32-slot budget.
        // Handing them a dense slot here would be a slot nothing reads — §0
        // row 7's shape, one layer down.
        if is_fx_lane_path(path) {
            continue;
        }
        if next >= MAX_TRACK_LANES {
            return Err(format!(
                "project uses more than {MAX_TRACK_LANES} automation lanes per track \
                 (engine capacity); the audio thread's cursor table is preallocated"
            ));
        }
        index.insert(path.to_string(), next);
        next += 1;
    }
    Ok(index)
}

/// Last audible frame of a compiled session (warp-aware bounce length).
///
/// E1: a track whose only content is a note clip has no `RtClip` at all, so
/// the note lane's last event has to count or a MIDI-only bounce would come
/// out zero-length. (It is the note-OFF that bounds the region; an instrument's
/// release tail past it is E2's concern, not the scheduler's.)
pub fn session_end_frame(session: &RtSession) -> u64 {
    let audio = session
        .tracks
        .iter()
        .flat_map(|t| t.clips.iter())
        .map(|c| c.end_frame())
        .max()
        .unwrap_or(0);
    let notes = session
        .tracks
        .iter()
        .map(|t| t.notes.end_frame())
        .max()
        .unwrap_or(0);
    audio.max(notes)
}
