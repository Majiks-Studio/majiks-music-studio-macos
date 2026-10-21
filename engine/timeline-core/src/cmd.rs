//! The catalog command set: one typed variant per command in
//! `engine/contracts/command-catalog.v1.1.json` (87 commands, catalog v1.1).
//!
//! Wire form is `{"name": "<catalog name>", "params": {...}}` with camelCase
//! params, exactly as journaled. Unknown params are rejected by schema
//! validation against the embedded catalog BEFORE typed deserialization
//! (`crate::catalog::validate_params`), so this enum can stay lenient.
//!
//! Numeric params that the catalog types as "number" are `Num` (wire-exact:
//! an integer literal on the way in stays an integer literal in inverses and
//! checkpoints, which the hash chain requires). Tick positions are u64,
//! `deltaTicks` is i64.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

use crate::model::{DeviceKind, FadeCurve, FxKind, WarpMode};
use crate::paramref::ParamRef;
use crate::routing::{NodeKind, NodeRef, Tap};
use crate::num::Num;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TrimEdgeWire {
    Start,
    End,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FadeEdge {
    In,
    Out,
}

/// Which edge of a note `note.resize` moves.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NoteEdge {
    /// Move the start, shortening/lengthening from the front. The note's END
    /// stays put, which is what makes the operation self-inverse.
    Leading,
    /// Change the length only; the start stays put.
    Trailing,
}

/// One note in a `note.add` batch. Wire form is camelCase, matching the
/// catalog `paramsSchema`.
///
/// `velocity` is `Num` (E0 §1 invariant 6 — journaled values are `Num`, whose
/// integer/float SHAPE the hash chain depends on), and `100` round-trips as
/// `100`.
///
/// CORRECTED: this comment used to claim the catalog's `"type": "integer"`
/// means "`100.0` is rejected at the contract boundary". It is not. JSON Schema
/// (draft 2020-12, which `schema.rs` implements and `contracts-conformance`
/// cross-checks against the `jsonschema` crate) defines an integer as ANY
/// number with a zero fractional part, so `100.0` validates and is then
/// journaled with the float shape it arrived in — a different hash for the same
/// musical edit. Nothing rejects it; the catalog description is the only place
/// a caller is warned, which is why it now says so.
/// `tests/catalog_description_behaviour.rs` executes this rather than asserting
/// it, so the comment cannot drift back.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteSpec {
    pub note_id: String,
    pub start_ticks: u64,
    pub length_ticks: u64,
    pub pitch: u8,
    pub velocity: Num,
}

/// One entry in a `note.timing.set` batch: where a note IS, not how far it
/// moves.
///
/// The whole note command family is delta-shaped so its inverse is a negation.
/// `note.quantize` is the one operation that cannot be: each note travels its
/// own distance to its own grid line, so no single delta describes the batch.
/// Rather than invent an approximate "quantize back" (which would drift a
/// little further from the performance on every undo), the quantize inverse
/// carries the exact pre-state through this shape.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteTiming {
    pub note_id: String,
    pub start_ticks: u64,
    pub length_ticks: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "name", content = "params", rename_all_fields = "camelCase")]
pub enum Cmd {
    // ---- project ----
    #[serde(rename = "project.new")]
    ProjectNew { name: String },
    #[serde(rename = "project.open")]
    ProjectOpen { path: String },
    #[serde(rename = "project.save")]
    ProjectSave {},
    #[serde(rename = "project.setTempo")]
    ProjectSetTempo { bpm: Num },
    #[serde(rename = "project.setTimeSig")]
    ProjectSetTimeSig { numerator: u32, denominator: u32 },
    /// Deferred proposal L8 (accepted): the project-level bar-grid phase
    /// anchor. Bar-aligned lead-in is needed by E7 warp markers.
    #[serde(rename = "project.setPhaseAnchor")]
    ProjectSetPhaseAnchor { anchor_ticks: u64 },
    #[serde(rename = "project.setKey")]
    ProjectSetKey { key: String },
    #[serde(rename = "section.set")]
    SectionSet {
        section_id: String,
        name: String,
        start_ticks: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        color: Option<String>,
    },
    #[serde(rename = "section.remove")]
    SectionRemove { section_id: String },
    #[serde(rename = "marker.set")]
    MarkerSet {
        marker_id: String,
        position_ticks: u64,
        label: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        color: Option<String>,
    },
    #[serde(rename = "marker.remove")]
    MarkerRemove { marker_id: String },

    // ---- transport (unjournaled, non-undoable, no model mutation) ----
    #[serde(rename = "transport.play")]
    TransportPlay {},
    #[serde(rename = "transport.stop")]
    TransportStop {},
    #[serde(rename = "transport.seek")]
    TransportSeek { position_ticks: u64 },
    #[serde(rename = "transport.loop.set")]
    TransportLoopSet { start_ticks: u64, end_ticks: u64 },
    #[serde(rename = "transport.loop.clear")]
    TransportLoopClear {},
    #[serde(rename = "transport.metronome")]
    TransportMetronome { enabled: bool },

    // ---- record (unjournaled transport-class; the landed take/clip is the
    // undoable unit, so start/stop/cancel carry no inverse of their own) ----
    #[serde(rename = "record.start")]
    RecordStart {
        track_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        device_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        start_ticks: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        punch_out_ticks: Option<u64>,
    },
    #[serde(rename = "record.rotate")]
    RecordRotate {},
    #[serde(rename = "record.stop")]
    RecordStop {},
    #[serde(rename = "record.cancel")]
    RecordCancel {},
    /// Opt-in input open for metering without landing. Never opened by arm.
    #[serde(rename = "record.inputListen")]
    RecordInputListen {
        enabled: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        device_id: Option<String>,
    },
    #[serde(rename = "midi.device.select")]
    MidiDeviceSelect {
        device: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        map: Option<String>,
    },
    /// What a MIDI input port's KEYS do. See the catalog entry: `instrument`
    /// (the default) plays the selected instrument track, `control` fires the
    /// port's bindings. A NEW command name, per E0 §9.2 — this is new
    /// semantics, so it does NOT ride on `midi.device.select`.
    #[serde(rename = "midi.port.role.set")]
    MidiPortRoleSet { port: String, role: String },
    #[serde(rename = "midi.learn.start")]
    MidiLearnStart {
        #[serde(skip_serializing_if = "Option::is_none")]
        device: Option<String>,
    },
    #[serde(rename = "midi.learn.stop")]
    MidiLearnStop {},
    #[serde(rename = "midi.binding.set")]
    MidiBindingSet {
        #[serde(skip_serializing_if = "Option::is_none")]
        device: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        control: Option<Map<String, Value>>,
        target: Map<String, Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        value_map: Option<Map<String, Value>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        label: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        enabled: Option<bool>,
    },
    #[serde(rename = "midi.binding.clear")]
    MidiBindingClear {
        device: String,
        control: Map<String, Value>,
    },
    #[serde(rename = "midi.map.import")]
    MidiMapImport {
        source_path: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        overwrite: Option<bool>,
    },
    #[serde(rename = "midi.map.export")]
    MidiMapExport { map: String, output_path: String },
    #[serde(rename = "midi.reload")]
    MidiReload {},

    // ---- track ----
    #[serde(rename = "track.add")]
    TrackAdd {
        track_id: String,
        name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        index: Option<u32>,
    },
    #[serde(rename = "track.remove")]
    TrackRemove { track_id: String },
    #[serde(rename = "track.rename")]
    TrackRename { track_id: String, name: String },
    #[serde(rename = "track.reorder")]
    TrackReorder { track_id: String, new_index: u32 },
    #[serde(rename = "track.setColor")]
    TrackSetColor { track_id: String, color: String },
    #[serde(rename = "track.setHeight")]
    TrackSetHeight { track_id: String, height_px: u32 },
    #[serde(rename = "track.mute")]
    TrackMute { track_id: String, muted: bool },
    #[serde(rename = "track.solo")]
    TrackSolo { track_id: String, soloed: bool },
    #[serde(rename = "track.arm")]
    TrackArm { track_id: String, armed: bool },
    /// Which hardware input channel (0-based) this track records from.
    /// NEW NAME — never widen `track.arm` with a channel field.
    #[serde(rename = "track.setInputChannel")]
    TrackSetInputChannel { track_id: String, channel: u32 },

    // ---- E1/E2 seam: the device registry that makes ParamRef resolve ----
    //
    // E0 §3 promised "instrument params are already addressable and
    // automatable... E2 needs NO contract work for automation". That promise
    // needed a REGISTRY to resolve against: before these commands,
    // `require_param_ref` rejected every `track.device.*` path outright.
    #[serde(rename = "device.add")]
    DeviceAdd {
        track_id: String,
        device_id: String,
        kind: DeviceKind,
    },
    #[serde(rename = "device.remove")]
    DeviceRemove {
        track_id: String,
        device_id: String,
    },

    // ---- the SOURCE BINDING: what a sampler zone / drum pad actually plays ----
    //
    // NEW NAMES ONLY (§9.2). `device.add` is NOT widened with an optional
    // `sourceId`: replay does not validate params and nothing uses
    // `deny_unknown_fields`, so an older binary would verify the chain and then
    // silently build a sampler with no audio.
    //
    // There is no `device.zone.set`. An edit is remove+add, which keeps every
    // inverse EXACT without inventing per-field defaults the model would then
    // have to guarantee forever.
    #[serde(rename = "device.zone.add")]
    DeviceZoneAdd {
        track_id: String,
        device_id: String,
        zone_id: String,
        /// The content-addressed asset id, exactly as `clip.place` names it.
        source_id: String,
        root_pitch: Num,
        lo_pitch: Num,
        hi_pitch: Num,
        #[serde(skip_serializing_if = "Option::is_none")]
        gain_db: Option<Num>,
        #[serde(skip_serializing_if = "Option::is_none")]
        pan: Option<Num>,
    },
    #[serde(rename = "device.zone.remove")]
    DeviceZoneRemove {
        track_id: String,
        device_id: String,
        zone_id: String,
    },

    // ---- what the instrument SOUNDS like ----
    //
    // E1/E2 shipped the registry and the source binding and deliberately left
    // this out: "its inverse cannot be exact without per-parameter defaults
    // that the DSP lane owns, and inventing them would ship a booby trap"
    // (`apply.rs`, `device.remove`). E5 answered exactly that objection for
    // `fx.param.set`, and the answer transfers verbatim: parameters stay
    // SPARSE, an absent key means the DSP default — which is what
    // `build_instrument` already implements — so setting a key that was absent
    // inverts to `device.param.clear` and NO default is ever written into the
    // project. Nothing has to be invented, so nothing is a booby trap.
    //
    // Until this landed, `Waveform::Saw` was the app's ONLY instrument sound:
    // the synth had four waveforms and a full ADSR, every one of them already
    // automatable through `track.device.<id>.<key>`, and no command anywhere in
    // the catalog could write one. Built, and unreachable.
    #[serde(rename = "device.param.set")]
    DeviceParamSet {
        track_id: String,
        device_id: String,
        key: String,
        value: Num,
    },
    #[serde(rename = "device.param.clear")]
    DeviceParamClear {
        track_id: String,
        device_id: String,
        key: String,
    },


    // ---- clip ----
    #[serde(rename = "clip.place")]
    ClipPlace {
        clip_id: String,
        track_id: String,
        asset_hash: String,
        start_ticks: u64,
        length_ticks: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        source_offset_ticks: Option<u64>,
    },
    // ---- E1 (catalog v2): note-backed clips + MIDI notes ----
    //
    // NEW NAMES ONLY, per design §9.2 — the same rule the routing block below
    // obeys. `clip.placeMidi` is NOT `clip.place` with an optional `assetHash`:
    // replay does not validate params and nothing uses `deny_unknown_fields`,
    // so an older binary would verify the chain and silently build an audio
    // clip where a MIDI clip belongs. An unknown command NAME hard-fails the
    // open, which is the safe outcome.
    #[serde(rename = "clip.placeMidi")]
    ClipPlaceMidi {
        clip_id: String,
        track_id: String,
        start_ticks: u64,
        length_ticks: u64,
    },
    // The note commands are BATCH-first and DELTA-based: one chord drag is ONE
    // journal entry whose inverse is the negated delta, so relative voicing
    // inside a selection is a property of the command rather than of the
    // caller. Ids are minted UI-side (the `autopoint.add`/`pointId` precedent);
    // the engine never mints one, because a minted id would make replay diverge
    // from the live model.
    #[serde(rename = "note.add")]
    NoteAdd {
        clip_id: String,
        notes: Vec<NoteSpec>,
    },
    #[serde(rename = "note.remove")]
    NoteRemove {
        clip_id: String,
        note_ids: Vec<String>,
    },
    #[serde(rename = "note.move")]
    NoteMove {
        clip_id: String,
        note_ids: Vec<String>,
        delta_ticks: i64,
        delta_pitch: i32,
    },
    #[serde(rename = "note.resize")]
    NoteResize {
        clip_id: String,
        note_ids: Vec<String>,
        edge: NoteEdge,
        delta_ticks: i64,
    },
    #[serde(rename = "note.velocity.set")]
    NoteVelocitySet {
        clip_id: String,
        note_ids: Vec<String>,
        delta_velocity: i64,
    },
    #[serde(rename = "note.duplicate")]
    NoteDuplicate {
        clip_id: String,
        note_ids: Vec<String>,
        new_note_ids: Vec<String>,
        delta_ticks: i64,
        delta_pitch: i32,
    },
    // The two ABSOLUTE members of the family. They are new NAMES rather than
    // extra params on `note.move`, for the §9.2 reason: replay does not
    // validate parameters, so an older binary handed a widened `note.move`
    // would verify the hash chain and silently build a project where the notes
    // are somewhere else. An unknown command name hard-fails the open instead.
    #[serde(rename = "note.timing.set")]
    NoteTimingSet {
        clip_id: String,
        notes: Vec<NoteTiming>,
    },
    #[serde(rename = "note.quantize")]
    NoteQuantize {
        clip_id: String,
        note_ids: Vec<String>,
        grid_ticks: u64,
        strength_percent: u32,
        quantize_ends: bool,
    },

    #[serde(rename = "clip.move")]
    ClipMove {
        clip_id: String,
        track_id: String,
        start_ticks: u64,
    },
    #[serde(rename = "clip.trim")]
    ClipTrim {
        clip_id: String,
        edge: TrimEdgeWire,
        delta_ticks: i64,
    },
    #[serde(rename = "clip.split")]
    ClipSplit {
        clip_id: String,
        at_ticks: u64,
        new_clip_id: String,
    },
    #[serde(rename = "clip.duplicate")]
    ClipDuplicate {
        clip_id: String,
        new_clip_id: String,
        start_ticks: u64,
    },
    #[serde(rename = "clip.remove")]
    ClipRemove { clip_id: String },
    #[serde(rename = "clip.setGain")]
    ClipSetGain { clip_id: String, gain_db: Num },
    #[serde(rename = "clip.mute")]
    ClipMute { clip_id: String, muted: bool },
    #[serde(rename = "clip.fade.set")]
    ClipFadeSet {
        clip_id: String,
        edge: FadeEdge,
        length_ticks: u64,
        shape: FadeCurve,
    },
    #[serde(rename = "clip.crossfade.set")]
    ClipCrossfadeSet {
        clip_id_a: String,
        clip_id_b: String,
        length_ticks: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        shape: Option<FadeCurve>,
    },
    #[serde(rename = "clip.warp.set")]
    ClipWarpSet {
        clip_id: String,
        mode: WarpMode,
        #[serde(skip_serializing_if = "Option::is_none")]
        stretch_ratio: Option<Num>,
    },
    #[serde(rename = "clip.phaseAnchor.set")]
    ClipPhaseAnchorSet { clip_id: String, anchor_ticks: u64 },
    #[serde(rename = "clip.rename")]
    ClipRename { clip_id: String, name: String },

    // ---- automation ----
    #[serde(rename = "autolane.show")]
    AutolaneShow {
        track_id: String,
        target: ParamRef,
        visible: bool,
    },
    #[serde(rename = "autopoint.add")]
    AutopointAdd {
        track_id: String,
        target: ParamRef,
        point_id: String,
        position_ticks: u64,
        value: Num,
    },
    #[serde(rename = "autopoint.move")]
    AutopointMove {
        track_id: String,
        target: ParamRef,
        point_id: String,
        position_ticks: u64,
        value: Num,
    },
    #[serde(rename = "autopoint.remove")]
    AutopointRemove {
        track_id: String,
        target: ParamRef,
        point_id: String,
    },
    #[serde(rename = "autolane.clear")]
    AutolaneClear {
        track_id: String,
        target: ParamRef,
    },

    // ---- mixer ----
    #[serde(rename = "mix.gain")]
    MixGain { track_id: String, gain_db: Num },
    #[serde(rename = "mix.pan")]
    MixPan { track_id: String, pan: Num },
    #[serde(rename = "mix.eq")]
    MixEq {
        track_id: String,
        band: u32,
        freq_hz: Num,
        gain_db: Num,
        #[serde(skip_serializing_if = "Option::is_none")]
        q: Option<Num>,
    },
    #[serde(rename = "mix.send")]
    MixSend {
        track_id: String,
        bus: SendBus,
        amount: Num,
    },
    #[serde(rename = "mix.master.gain")]
    MixMasterGain { gain_db: Num },
    #[serde(rename = "mix.limiter.set")]
    MixLimiterSet {
        enabled: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        ceiling_db: Option<Num>,
        #[serde(skip_serializing_if = "Option::is_none")]
        release_ms: Option<Num>,
    },

    // ---- gen (async request records; journaled, non-undoable) ----
    #[serde(rename = "gen.song")]
    GenSong {
        request_id: String,
        track_id: String,
        insert_at_ticks: u64,
        request: Map<String, Value>,
    },
    #[serde(rename = "gen.revise")]
    GenRevise {
        request_id: String,
        clip_id: String,
        region_start_ticks: u64,
        region_end_ticks: u64,
        scope: Value,
        request: Map<String, Value>,
    },
    #[serde(rename = "gen.extend")]
    GenExtend {
        request_id: String,
        clip_id: String,
        added_duration_seconds: Num,
        request: Map<String, Value>,
    },
    #[serde(rename = "gen.layer")]
    GenLayer {
        request_id: String,
        target_track_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        context_clip_id: Option<String>,
        instruction: String,
        request: Map<String, Value>,
    },
    #[serde(rename = "gen.retake")]
    GenRetake {
        request_id: String,
        source_take_id: String,
        request: Map<String, Value>,
    },
    #[serde(rename = "gen.autocomplete")]
    GenAutocomplete {
        request_id: String,
        clip_id: String,
        request: Map<String, Value>,
    },
    #[serde(rename = "gen.cover")]
    GenCover {
        request_id: String,
        reference_clip_id: String,
        request: Map<String, Value>,
    },
    #[serde(rename = "gen.separate")]
    GenSeparate {
        request_id: String,
        clip_id: String,
        engine: String,
    },
    #[serde(rename = "gen.cancel")]
    GenCancel { request_id: String },
    #[serde(rename = "gen.finalize")]
    GenFinalize {
        request_id: String,
        draft_take_id: String,
        target_quality_rung: String,
        request: Map<String, Value>,
    },
    #[serde(rename = "gen.landed")]
    GenLanded {
        request_id: String,
        source_command: String,
        take_id: String,
        asset_hashes: BTreeMap<String, String>,
        engine_identity: Value,
        #[serde(skip_serializing_if = "Option::is_none")]
        latency_seconds: Option<Num>,
    },
    #[serde(rename = "take.promote")]
    TakePromote {
        take_id: String,
        target_clip_id: String,
    },
    #[serde(rename = "take.discard")]
    TakeDiscard { take_id: String },
    #[serde(rename = "take.purge")]
    TakePurge { take_id: String },
    #[serde(rename = "take.restore")]
    TakeRestore { take_id: String },
    #[serde(rename = "take.auditionMix")]
    TakeAuditionMix { take_id: String, stems: Vec<String> },

    // ---- io ----
    #[serde(rename = "import.audio")]
    ImportAudio {
        source_path: String,
        target_track_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        separate: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        conform: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        start_ticks: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        clip_id: Option<String>,
    },
    #[serde(rename = "import.stems")]
    ImportStems {
        source_dir: String,
        target_track_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        start_ticks: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        group_name: Option<String>,
    },
    #[serde(rename = "export.master")]
    ExportMaster {
        output_path: String,
        format: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        sample_rate_hz: Option<u32>,
    },
    #[serde(rename = "export.stems")]
    ExportStems {
        output_dir: String,
        format: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        stems: Option<Vec<String>>,
    },
    #[serde(rename = "export.region")]
    ExportRegion {
        output_path: String,
        start_ticks: u64,
        end_ticks: u64,
        format: String,
    },
    #[serde(rename = "export.manifest")]
    ExportManifest { output_path: String },
    #[serde(rename = "publish.track")]
    PublishTrack {
        asset_hash: String,
        title: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        metadata: Option<Map<String, Value>>,
    },

    // ---- txn ----
    #[serde(rename = "txn.begin")]
    TxnBegin {
        txn_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    #[serde(rename = "txn.commit")]
    TxnCommit { txn_id: String },

    // ---- routing (catalog v2) ----
    //
    // NEW NAMES ONLY. Design §9.2: replay does not validate params and nothing
    // uses `deny_unknown_fields`, so adding an optional field to a v1 command
    // would let an OLDER binary verify the chain and silently build a WRONG
    // model. An unknown command NAME hard-fails the open, which is safe.
    #[serde(rename = "route.node.add")]
    RouteNodeAdd {
        node_id: String,
        kind: NodeKind,
        name: String,
    },
    #[serde(rename = "route.node.remove")]
    RouteNodeRemove { node_id: String },
    #[serde(rename = "route.connect")]
    RouteConnect {
        edge_id: String,
        from: NodeRef,
        to: NodeRef,
        level: Num,
        tap: Tap,
    },
    #[serde(rename = "route.disconnect")]
    RouteDisconnect { edge_id: String },
    #[serde(rename = "route.edge.set")]
    RouteEdgeSet {
        edge_id: String,
        level: Num,
        tap: Tap,
    },
    /// The node FADER (§4.3's "buses with their own fader"). A NEW NAME, not a
    /// param on `route.node.add`, for the §9.2 reason above; the object-grain
    /// setter mirrors `route.edge.set` (the node's one mutable property is its
    /// gain — `name`/`kind` are identity, the insert chain has its own `fx.*`
    /// family). NOT `route.node.gain.set`: §2.2 forbids a
    /// `route.node.<id>.gain` ParamRef (the automation spelling is
    /// `bus.<id>.gain`), and a command spelled `route.node.gain.*` invites
    /// exactly that confusion.
    #[serde(rename = "route.node.set")]
    RouteNodeSet { node_id: String, gain_db: Num },

    // ---- E5 §16: the EFFECT registry ----
    //
    // SEVEN NEW NAMES. `device.add`'s `kind` enum is NOT widened and
    // `Device`/`DeviceKind` are NOT touched: `build_instrument`
    // (`compile.rs:307-322`) hard-errors on a track with more than one device,
    // so an effect in `Track::devices` would break the compile of every
    // instrument track carrying an effect. A separate collection avoids that
    // rewrite entirely (§16.1) and costs ZERO enum widening sites.
    //
    // `target` is a `NodeRef` — `master` | `track.<id>` | `bus.<id>` — which is
    // what makes a master-bus effect chain fall out for free (§16.2).
    #[serde(rename = "fx.add")]
    FxAdd {
        target: NodeRef,
        fx_id: String,
        kind: FxKind,
    },
    #[serde(rename = "fx.remove")]
    FxRemove { target: NodeRef, fx_id: String },
    #[serde(rename = "fx.move")]
    FxMove {
        target: NodeRef,
        fx_id: String,
        index: u32,
    },
    /// The parameter setter E1/E2 deliberately omitted for `Device` ("its
    /// inverse cannot be exact without per-parameter defaults that the DSP lane
    /// owns"). E5 IS the DSP lane, and the inverse is exact without inventing
    /// any default: a key that was absent undoes to ABSENT via `fx.param.clear`.
    #[serde(rename = "fx.param.set")]
    FxParamSet {
        target: NodeRef,
        fx_id: String,
        key: String,
        value: Num,
    },
    #[serde(rename = "fx.param.clear")]
    FxParamClear {
        target: NodeRef,
        fx_id: String,
        key: String,
    },
    /// A sidechain is an ORDERING CONSTRAINT, not an audio edge (§18.1): it
    /// creates no `RouteEdge` and contributes no audio, but it constrains the
    /// topological order exactly as an edge does.
    #[serde(rename = "fx.sidechain.set")]
    FxSidechainSet {
        target: NodeRef,
        fx_id: String,
        source: NodeRef,
    },
    #[serde(rename = "fx.sidechain.clear")]
    FxSidechainClear { target: NodeRef, fx_id: String },

    // ---- session ----
    #[serde(rename = "studio.importStemSession")]
    StudioImportStemSession { stem_session_id: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SendBus {
    A,
    B,
}

impl SendBus {
    pub fn wire_name(self) -> &'static str {
        match self {
            SendBus::A => "a",
            SendBus::B => "b",
        }
    }
}

impl Cmd {
    /// Catalog name (the serde tag).
    pub fn name(&self) -> &'static str {
        match self {
            Cmd::ProjectNew { .. } => "project.new",
            Cmd::ProjectOpen { .. } => "project.open",
            Cmd::ProjectSave {} => "project.save",
            Cmd::ProjectSetTempo { .. } => "project.setTempo",
            Cmd::ProjectSetTimeSig { .. } => "project.setTimeSig",
            Cmd::ProjectSetKey { .. } => "project.setKey",
            Cmd::SectionSet { .. } => "section.set",
            Cmd::SectionRemove { .. } => "section.remove",
            Cmd::MarkerSet { .. } => "marker.set",
            Cmd::MarkerRemove { .. } => "marker.remove",
            Cmd::TransportPlay {} => "transport.play",
            Cmd::TransportStop {} => "transport.stop",
            Cmd::TransportSeek { .. } => "transport.seek",
            Cmd::TransportLoopSet { .. } => "transport.loop.set",
            Cmd::TransportLoopClear {} => "transport.loop.clear",
            Cmd::TransportMetronome { .. } => "transport.metronome",
            Cmd::RecordStart { .. } => "record.start",
            Cmd::RecordRotate {} => "record.rotate",
            Cmd::RecordStop {} => "record.stop",
            Cmd::RecordCancel {} => "record.cancel",
            Cmd::RecordInputListen { .. } => "record.inputListen",
            Cmd::MidiDeviceSelect { .. } => "midi.device.select",
            Cmd::MidiPortRoleSet { .. } => "midi.port.role.set",
            Cmd::MidiLearnStart { .. } => "midi.learn.start",
            Cmd::MidiLearnStop {} => "midi.learn.stop",
            Cmd::MidiBindingSet { .. } => "midi.binding.set",
            Cmd::MidiBindingClear { .. } => "midi.binding.clear",
            Cmd::MidiMapImport { .. } => "midi.map.import",
            Cmd::MidiMapExport { .. } => "midi.map.export",
            Cmd::MidiReload {} => "midi.reload",
            Cmd::TrackAdd { .. } => "track.add",
            Cmd::TrackRemove { .. } => "track.remove",
            Cmd::TrackRename { .. } => "track.rename",
            Cmd::TrackReorder { .. } => "track.reorder",
            Cmd::TrackSetColor { .. } => "track.setColor",
            Cmd::TrackSetHeight { .. } => "track.setHeight",
            Cmd::TrackMute { .. } => "track.mute",
            Cmd::TrackSolo { .. } => "track.solo",
            Cmd::TrackArm { .. } => "track.arm",
            Cmd::TrackSetInputChannel { .. } => "track.setInputChannel",
            Cmd::DeviceAdd { .. } => "device.add",
            Cmd::DeviceRemove { .. } => "device.remove",
            Cmd::DeviceZoneAdd { .. } => "device.zone.add",
            Cmd::DeviceZoneRemove { .. } => "device.zone.remove",
            Cmd::DeviceParamSet { .. } => "device.param.set",
            Cmd::DeviceParamClear { .. } => "device.param.clear",
            Cmd::ClipPlace { .. } => "clip.place",
            Cmd::ClipPlaceMidi { .. } => "clip.placeMidi",
            Cmd::NoteAdd { .. } => "note.add",
            Cmd::NoteRemove { .. } => "note.remove",
            Cmd::NoteMove { .. } => "note.move",
            Cmd::NoteResize { .. } => "note.resize",
            Cmd::NoteVelocitySet { .. } => "note.velocity.set",
            Cmd::NoteDuplicate { .. } => "note.duplicate",
            Cmd::NoteTimingSet { .. } => "note.timing.set",
            Cmd::NoteQuantize { .. } => "note.quantize",
            Cmd::ClipMove { .. } => "clip.move",
            Cmd::ClipTrim { .. } => "clip.trim",
            Cmd::ClipSplit { .. } => "clip.split",
            Cmd::ClipDuplicate { .. } => "clip.duplicate",
            Cmd::ClipRemove { .. } => "clip.remove",
            Cmd::ClipSetGain { .. } => "clip.setGain",
            Cmd::ClipMute { .. } => "clip.mute",
            Cmd::ClipFadeSet { .. } => "clip.fade.set",
            Cmd::ClipCrossfadeSet { .. } => "clip.crossfade.set",
            Cmd::ClipWarpSet { .. } => "clip.warp.set",
            Cmd::ClipPhaseAnchorSet { .. } => "clip.phaseAnchor.set",
            Cmd::ClipRename { .. } => "clip.rename",
            Cmd::AutolaneShow { .. } => "autolane.show",
            Cmd::AutopointAdd { .. } => "autopoint.add",
            Cmd::AutopointMove { .. } => "autopoint.move",
            Cmd::AutopointRemove { .. } => "autopoint.remove",
            Cmd::AutolaneClear { .. } => "autolane.clear",
            Cmd::MixGain { .. } => "mix.gain",
            Cmd::MixPan { .. } => "mix.pan",
            Cmd::MixEq { .. } => "mix.eq",
            Cmd::MixSend { .. } => "mix.send",
            Cmd::MixMasterGain { .. } => "mix.master.gain",
            Cmd::MixLimiterSet { .. } => "mix.limiter.set",
            Cmd::GenSong { .. } => "gen.song",
            Cmd::GenRevise { .. } => "gen.revise",
            Cmd::GenExtend { .. } => "gen.extend",
            Cmd::GenLayer { .. } => "gen.layer",
            Cmd::GenRetake { .. } => "gen.retake",
            Cmd::GenAutocomplete { .. } => "gen.autocomplete",
            Cmd::GenCover { .. } => "gen.cover",
            Cmd::GenSeparate { .. } => "gen.separate",
            Cmd::GenCancel { .. } => "gen.cancel",
            Cmd::GenFinalize { .. } => "gen.finalize",
            Cmd::GenLanded { .. } => "gen.landed",
            Cmd::TakePromote { .. } => "take.promote",
            Cmd::TakeDiscard { .. } => "take.discard",
            Cmd::TakePurge { .. } => "take.purge",
            Cmd::TakeRestore { .. } => "take.restore",
            Cmd::TakeAuditionMix { .. } => "take.auditionMix",
            Cmd::ImportAudio { .. } => "import.audio",
            Cmd::ImportStems { .. } => "import.stems",
            Cmd::ExportMaster { .. } => "export.master",
            Cmd::ExportStems { .. } => "export.stems",
            Cmd::ExportRegion { .. } => "export.region",
            Cmd::ExportManifest { .. } => "export.manifest",
            Cmd::PublishTrack { .. } => "publish.track",
            Cmd::TxnBegin { .. } => "txn.begin",
            Cmd::TxnCommit { .. } => "txn.commit",
            Cmd::RouteNodeAdd { .. } => "route.node.add",
            Cmd::RouteNodeRemove { .. } => "route.node.remove",
            Cmd::RouteConnect { .. } => "route.connect",
            Cmd::RouteDisconnect { .. } => "route.disconnect",
            Cmd::RouteEdgeSet { .. } => "route.edge.set",
            Cmd::RouteNodeSet { .. } => "route.node.set",
            Cmd::FxAdd { .. } => "fx.add",
            Cmd::FxRemove { .. } => "fx.remove",
            Cmd::FxMove { .. } => "fx.move",
            Cmd::FxParamSet { .. } => "fx.param.set",
            Cmd::FxParamClear { .. } => "fx.param.clear",
            Cmd::FxSidechainSet { .. } => "fx.sidechain.set",
            Cmd::FxSidechainClear { .. } => "fx.sidechain.clear",
            Cmd::ProjectSetPhaseAnchor { .. } => "project.setPhaseAnchor",
            Cmd::StudioImportStemSession { .. } => "studio.importStemSession",
        }
    }

    /// The wire `params` object for this command.
    pub fn params_value(&self) -> Value {
        match serde_json::to_value(self) {
            Ok(Value::Object(map)) => map
                .get("params")
                .cloned()
                .unwrap_or(Value::Object(Map::new())),
            _ => Value::Object(Map::new()),
        }
    }

    /// Parse from catalog name + params object (no schema validation here;
    /// callers go through `catalog::validate_params` first).
    pub fn from_wire(name: &str, params: Value) -> Result<Cmd, serde_json::Error> {
        let mut obj = Map::new();
        obj.insert("name".to_string(), Value::String(name.to_string()));
        obj.insert("params".to_string(), params);
        serde_json::from_value(Value::Object(obj))
    }
}
