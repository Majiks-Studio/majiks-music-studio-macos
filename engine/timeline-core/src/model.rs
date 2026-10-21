//! Project model: sources, tracks, clips, sections, markers, automation,
//! mixer state, takes.
//!
//! Position model (locked by the P0-C contract freeze): the catalog bus and
//! persistence speak integer ticks (960 PPQ). The model stores ticks as the
//! canonical position and MATERIALIZES sample-frame fields through the tempo
//! map on every mutation, so the render side keeps reading plain frame fields
//! (`start_frame`, `len_frames`, ...) exactly as in P0-B. `project.setTempo`
//! re-derives every frame field from ticks. The legacy P0-B command subset
//! (frame-canonical) still works as a compatibility shim for render's current
//! host and back-derives ticks by rounding; see INTERFACE.md section 1.
//!
//! Default discipline (undo exactness): every optional-in-command field is a
//! CONCRETE value with a canonical default in the model, never an `Option`
//! "unset" that a catalog command cannot restore. The checkpoint mapping
//! (io::checkpoint) omits a field when it equals its default, which is how a
//! never-customized track/clip round-trips to the same bytes as the P0-C
//! fixtures. Because undo applies catalog commands, "back to default" and
//! "never set" MUST be the same model state, and they are.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::CommandError;
use crate::note::{sort_notes, Note};
use crate::num::Num;
use crate::paramref::{self, ParamRef};
use crate::routing::Routing;
use crate::tempo::TempoMap;

pub const DEFAULT_TRACK_COLOR: &str = "#FFFFFF";
/// v1 default track height (V1-DECISION: no fixture pins this; UI-only, and
/// omitted from the checkpoint when unchanged). Documented in the evidence doc.
pub const DEFAULT_TRACK_HEIGHT_PX: u32 = 90;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FadeShape {
    Linear,
    EqualPower,
}

impl Default for FadeShape {
    fn default() -> Self {
        FadeShape::EqualPower
    }
}

/// Catalog fade/crossfade curve vocabulary (superset of the render-side
/// `FadeShape`, which stays frozen because render matches on it).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FadeCurve {
    #[serde(rename = "linear")]
    Linear,
    #[serde(rename = "equalPower")]
    EqualPower,
    #[serde(rename = "exponential")]
    Exponential,
    #[serde(rename = "logarithmic")]
    Logarithmic,
}

impl Default for FadeCurve {
    fn default() -> Self {
        FadeCurve::Linear
    }
}

impl FadeCurve {
    /// Lossy map onto the render-capable shapes until L2 consumes FadeCurve.
    pub fn to_fade_shape(self) -> FadeShape {
        match self {
            FadeCurve::Linear => FadeShape::Linear,
            FadeCurve::EqualPower | FadeCurve::Exponential | FadeCurve::Logarithmic => {
                FadeShape::EqualPower
            }
        }
    }

    pub fn wire_name(self) -> &'static str {
        match self {
            FadeCurve::Linear => "linear",
            FadeCurve::EqualPower => "equalPower",
            FadeCurve::Exponential => "exponential",
            FadeCurve::Logarithmic => "logarithmic",
        }
    }
}

/// A clip fade in the tick domain (canonical) with materialized frames.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct FadeSpec {
    pub length_ticks: u64,
    pub curve: FadeCurve,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WarpMode {
    Ratio,
    Conform,
}

/// A clip time-warp. The canonical "unwarped" state is `Ratio` at ratio 1.0
/// (the `Default`), so undo-to-unwarped is expressible as a catalog command
/// and compares equal to a never-warped clip.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Warp {
    pub mode: WarpMode,
    pub stretch_ratio: Num,
}

impl Default for Warp {
    fn default() -> Self {
        Warp {
            mode: WarpMode::Ratio,
            stretch_ratio: Num::int(1),
        }
    }
}

impl Warp {
    pub fn is_unwarped(&self) -> bool {
        self.mode == WarpMode::Ratio && self.stretch_ratio == Num::int(1)
    }
}

/// An audio source the project references. `path` is opaque data here; the
/// render/media side owns filesystem access and truthful rate stamping.
/// `len_frames` is the source length at the ENGINE rate (48 kHz v1).
/// For catalog-placed clips the source `id` IS the blake3 asset hash.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Source {
    pub id: String,
    pub path: String,
    pub len_frames: u64,
}

/// What backs a clip's content (E1 §1).
///
/// **This is an ADDITIVE optional field on `Clip`, deliberately NOT a re-tagged
/// enum.** `Clip` is existing v1.1 law: an audio clip must serialize
/// byte-identically before and after E1. `Audio` is the `Default`, the field is
/// omitted from both the checkpoint and the derived serialization when it is
/// `Audio`, and `tests/v1_1_replay_regression.rs` proves an untouched v1.1
/// project still opens with an unchanged blake3 chain.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ClipKind {
    #[default]
    Audio,
    Midi,
}

impl ClipKind {
    pub fn is_audio(&self) -> bool {
        matches!(self, ClipKind::Audio)
    }

    pub fn wire_name(self) -> &'static str {
        match self {
            ClipKind::Audio => "audio",
            ClipKind::Midi => "midi",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Clip {
    pub id: String,
    pub source_id: String,
    /// Materialized timeline position, sample frames at the project rate.
    pub start_frame: u64,
    /// Materialized read offset into the source, sample frames.
    pub offset_frames: u64,
    /// Materialized clip length, sample frames. Always > 0.
    pub len_frames: u64,
    /// Clip gain in dB (render view; `gain` below is the wire-exact value).
    pub gain_db: f32,
    pub fade_in_frames: u64,
    pub fade_out_frames: u64,
    /// Legacy single-shape view (render reads this); most recently set edge's
    /// curve. Per-edge truth lives in `fade_in`/`fade_out`.
    pub fade_shape: FadeShape,

    // Catalog-canonical state (additive since 0.2).
    #[serde(default)]
    pub start_ticks: u64,
    #[serde(default)]
    pub length_ticks: u64,
    #[serde(default)]
    pub source_offset_ticks: u64,
    /// Display name; defaults to the clip id ("unnamed").
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub muted: bool,
    #[serde(default = "Clip::default_gain")]
    pub gain: Num,
    #[serde(default)]
    pub fade_in: FadeSpec,
    #[serde(default)]
    pub fade_out: FadeSpec,
    #[serde(default)]
    pub warp: Warp,
    /// Timeline bar-grid phase anchor for warped source playback.
    #[serde(default)]
    pub phase_anchor_ticks: u64,
    /// True when the asset hash had no resolvable audio at open time.
    #[serde(default)]
    pub offline: bool,

    // ---- E1 (catalog v2): note-backed clips. ADDITIVE, defaulting to audio.
    /// Audio-backed (v1.1 law) or note-backed. Omitted when `Audio` so an
    /// existing audio clip's bytes are unchanged.
    #[serde(default, skip_serializing_if = "ClipKind::is_audio")]
    pub kind: ClipKind,
    /// The clip's notes, sorted by `(start_ticks, pitch, id)`. Always empty on
    /// an audio clip.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<Note>,

    /// Unknown checkpoint fields, preserved round-trip (contract section 6).
    #[serde(default)]
    pub extra: Map<String, Value>,
}

impl Clip {
    /// Catalog constructor (tick-canonical). Frame fields are materialized by
    /// the caller via `rematerialize`.
    pub fn new_catalog(
        id: String,
        asset_hash: String,
        start_ticks: u64,
        length_ticks: u64,
        source_offset_ticks: u64,
    ) -> Self {
        Clip {
            name: id.clone(),
            id,
            source_id: asset_hash,
            start_frame: 0,
            offset_frames: 0,
            len_frames: 1,
            gain_db: 0.0,
            fade_in_frames: 0,
            fade_out_frames: 0,
            fade_shape: FadeShape::default(),
            start_ticks,
            length_ticks,
            source_offset_ticks,
            muted: false,
            gain: Num::int(0),
            fade_in: FadeSpec::default(),
            fade_out: FadeSpec::default(),
            warp: Warp::default(),
            phase_anchor_ticks: 0,
            offline: false,
            kind: ClipKind::Audio,
            notes: Vec::new(),
            extra: Map::new(),
        }
    }

    /// Catalog constructor for a NOTE-BACKED clip (`clip.placeMidi`).
    ///
    /// There is no asset, so `source_id` is empty and `offline` is meaningless
    /// (`package::mark_offline` skips note clips explicitly — otherwise an
    /// empty `audio/` directory would mark every MIDI clip offline).
    pub fn new_midi(id: String, start_ticks: u64, length_ticks: u64) -> Self {
        let mut c = Clip::new_catalog(id, String::new(), start_ticks, length_ticks, 0);
        c.kind = ClipKind::Midi;
        c
    }

    pub fn is_midi(&self) -> bool {
        self.kind == ClipKind::Midi
    }

    /// One tick past the last visible tick, in the CONTENT coordinate (the
    /// coordinate `source_offset_ticks` and `Note::start_ticks` share).
    pub fn content_end_ticks(&self) -> u64 {
        self.source_offset_ticks.saturating_add(self.length_ticks)
    }

    pub fn note(&self, note_id: &str) -> Option<&Note> {
        self.notes.iter().find(|n| n.id == note_id)
    }

    pub fn note_index(&self, note_id: &str) -> Option<usize> {
        self.notes.iter().position(|n| n.id == note_id)
    }

    /// Re-establish the one total ordering `(start_ticks, pitch, id)`.
    pub(crate) fn sort_notes(&mut self) {
        sort_notes(&mut self.notes);
    }

    pub fn end_frame(&self) -> u64 {
        self.start_frame.saturating_add(self.len_frames)
    }

    pub fn end_ticks(&self) -> u64 {
        self.start_ticks.saturating_add(self.length_ticks)
    }

    /// The content-addressed asset reference (same value as `source_id`).
    pub fn asset_hash(&self) -> &str {
        &self.source_id
    }

    /// Display name: explicit name or the clip id.
    pub fn display_name(&self) -> &str {
        if self.name.is_empty() {
            &self.id
        } else {
            &self.name
        }
    }

    fn default_gain() -> Num {
        Num::int(0)
    }

    /// Re-derive every materialized frame field from canonical ticks.
    pub(crate) fn rematerialize(&mut self, tempo: &TempoMap, sample_rate: u32) {
        let start = tempo.tick_to_frame(self.start_ticks, sample_rate);
        let end = tempo.tick_to_frame(self.end_ticks(), sample_rate);
        self.start_frame = start;
        self.len_frames = end.saturating_sub(start).max(1);
        self.offset_frames = tempo.tick_to_frame(self.source_offset_ticks, sample_rate);
        self.fade_in_frames = tempo.tick_to_frame(self.fade_in.length_ticks, sample_rate);
        self.fade_out_frames = tempo.tick_to_frame(self.fade_out.length_ticks, sample_rate);
        self.fade_shape = self.fade_out.curve.to_fade_shape();
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AutoPoint {
    pub id: String,
    pub position_ticks: u64,
    pub value: Num,
    #[serde(default)]
    pub extra: Map<String, Value>,
}

/// v1 automation targets (catalog enum: track.volume, track.pan).
///
/// Kept as a typed convenience for the two legacy lanes that have dedicated
/// storage and a dedicated render fast path. It is NOT the addressing type any
/// more — that is [`crate::paramref::ParamRef`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AutoTarget {
    #[serde(rename = "track.volume")]
    Volume,
    #[serde(rename = "track.pan")]
    Pan,
}

impl AutoTarget {
    pub fn wire_name(self) -> &'static str {
        match self {
            AutoTarget::Volume => paramref::TRACK_VOLUME,
            AutoTarget::Pan => paramref::TRACK_PAN,
        }
    }

    pub fn param_ref(self) -> ParamRef {
        match self {
            AutoTarget::Volume => ParamRef::track_volume(),
            AutoTarget::Pan => ParamRef::track_pan(),
        }
    }

    /// `Some` exactly for the two paths that have legacy storage.
    pub fn from_param_ref(r: &ParamRef) -> Option<AutoTarget> {
        match r.as_str() {
            paramref::TRACK_VOLUME => Some(AutoTarget::Volume),
            paramref::TRACK_PAN => Some(AutoTarget::Pan),
            _ => None,
        }
    }
}

/// Per-track automation storage (design §4).
///
/// `volume`/`pan` keep their v1 fields so a v2 file that only automates those
/// two is still *readable* by a v1 binary. (Per design §9.3 that buys v1
/// readability, not v1 safety: a v2 project using new command names is
/// v1-unopenable anyway, which is the safe outcome.) Everything else lives in
/// `lanes`.
///
/// **`BTreeMap`, never `HashMap`** — for `project.json` byte-stability and
/// `Ord`-keyed determinism.
///
/// **Exactly one storage location per `ParamRef`.** A legacy path is ALWAYS in
/// its legacy field and NEVER in `lanes`; a lane that could live in both would
/// desync. [`Automation::single_storage_violations`] proves it and
/// [`Automation::normalize`] repairs a file that violated it.
///
/// `extra` is E0's addition (design §9.3 flagged its absence): `Clip`, `Track`,
/// `AutoPoint` and `Project` all have one, and without it this build would
/// DESTROY automation-level metadata written by a future build. It is the one
/// place forward-compat was missing.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct Automation {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub volume: Vec<AutoPoint>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pan: Vec<AutoPoint>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub lanes: BTreeMap<ParamRef, Vec<AutoPoint>>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub extra: Map<String, Value>,
}

impl Automation {
    /// Points on `target`. Empty slice when the lane does not exist — reading a
    /// lane never creates one.
    pub fn lane(&self, target: &ParamRef) -> &[AutoPoint] {
        match AutoTarget::from_param_ref(target) {
            Some(AutoTarget::Volume) => &self.volume,
            Some(AutoTarget::Pan) => &self.pan,
            None => self.lanes.get(target).map(Vec::as_slice).unwrap_or(&[]),
        }
    }

    /// Mutable access, creating the lane in its ONE correct home.
    pub fn lane_mut(&mut self, target: &ParamRef) -> &mut Vec<AutoPoint> {
        match AutoTarget::from_param_ref(target) {
            Some(AutoTarget::Volume) => &mut self.volume,
            Some(AutoTarget::Pan) => &mut self.pan,
            None => {
                debug_assert!(
                    !target.is_legacy(),
                    "legacy path must never reach the lanes map"
                );
                self.lanes.entry(target.clone()).or_default()
            }
        }
    }

    /// Drop a lane entirely (as opposed to emptying it). Legacy lanes are
    /// emptied, never removed, so their field keeps existing.
    pub fn clear_lane(&mut self, target: &ParamRef) -> Vec<AutoPoint> {
        match AutoTarget::from_param_ref(target) {
            Some(AutoTarget::Volume) => std::mem::take(&mut self.volume),
            Some(AutoTarget::Pan) => std::mem::take(&mut self.pan),
            None => self.lanes.remove(target).unwrap_or_default(),
        }
    }

    /// Every non-empty lane, legacy first then map order. Deterministic.
    pub fn iter_lanes(&self) -> Vec<(ParamRef, &Vec<AutoPoint>)> {
        let mut out: Vec<(ParamRef, &Vec<AutoPoint>)> = Vec::new();
        if !self.volume.is_empty() {
            out.push((ParamRef::track_volume(), &self.volume));
        }
        if !self.pan.is_empty() {
            out.push((ParamRef::track_pan(), &self.pan));
        }
        for (k, v) in &self.lanes {
            if !v.is_empty() {
                out.push((k.clone(), v));
            }
        }
        out
    }

    pub fn is_empty(&self) -> bool {
        self.volume.is_empty()
            && self.pan.is_empty()
            && self.lanes.values().all(Vec::is_empty)
            && self.extra.is_empty()
    }

    /// Legacy paths found in the map — must always be empty.
    pub fn single_storage_violations(&self) -> Vec<ParamRef> {
        self.lanes
            .keys()
            .filter(|k| k.is_legacy())
            .cloned()
            .collect()
    }

    /// Repair a file that put a legacy path in the map (a foreign writer, or a
    /// hand-edited project). The legacy field wins; map points are appended and
    /// the lane is re-sorted so the result is deterministic either way.
    pub fn normalize(&mut self) {
        for target in [AutoTarget::Volume, AutoTarget::Pan] {
            let key = target.param_ref();
            if let Some(points) = self.lanes.remove(&key) {
                let field = match target {
                    AutoTarget::Volume => &mut self.volume,
                    AutoTarget::Pan => &mut self.pan,
                };
                for p in points {
                    if !field.iter().any(|q| q.id == p.id) {
                        field.push(p);
                    }
                }
                self.sort_lane(&key);
            }
        }
        debug_assert!(self.single_storage_violations().is_empty());
    }

    pub(crate) fn sort_lane(&mut self, target: &ParamRef) {
        self.lane_mut(target)
            .sort_by(|a, b| (a.position_ticks, &a.id).cmp(&(b.position_ticks, &b.id)));
    }
}

/// One channel EQ band. v1 defaults: bands 0-3 at 80 / 250 / 2500 / 8000 Hz,
/// gain 0 dB, q 1 (all integer-shaped so inverse params stay hashable).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EqBand {
    pub freq_hz: Num,
    pub gain_db: Num,
    pub q: Num,
}

pub const EQ_DEFAULT_FREQS: [i64; 4] = [80, 250, 2500, 8000];

pub fn default_eq() -> [EqBand; 4] {
    EQ_DEFAULT_FREQS.map(|f| EqBand {
        freq_hz: Num::int(f),
        gain_db: Num::int(0),
        q: Num::int(1),
    })
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Sends {
    pub a: Num,
    pub b: Num,
}

impl Default for Sends {
    fn default() -> Self {
        Sends {
            a: Num::int(0),
            b: Num::int(0),
        }
    }
}

/// What a device on a track IS. §3 fixes the E2 vocabulary; the enum is
/// closed so an unknown kind fails loudly at the contract boundary instead of
/// producing a silent no-op node.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DeviceKind {
    Synth,
    Sampler,
    Drum,
}

impl DeviceKind {
    pub fn wire_name(self) -> &'static str {
        match self {
            DeviceKind::Synth => "synth",
            DeviceKind::Sampler => "sampler",
            DeviceKind::Drum => "drum",
        }
    }
}

/// The parameter keys a device exposes, as the `param` segment of
/// `ParamRef::TrackDeviceParam` (`track.device.<deviceId>.<paramKey>`).
///
/// This list is the ENGINE-side half of the seam; the DSP lane owns what each
/// one does. It is closed for the same reason `DeviceKind` is: a typo'd key
/// that the contract accepts becomes automation that silently drives nothing.
/// Which keys a given KIND actually honours is deliberately NOT validated here
/// — that pairing is the DSP lane's contract, not the model's, and guessing it
/// would be inventing a contract rather than implementing one.
pub const DEVICE_PARAM_KEYS: [&str; 10] = [
    "waveform",
    "cutoff",
    "resonance",
    "attack",
    "decay",
    "sustain",
    "release",
    "gain",
    "transpose",
    "fine",
];

// ---------------------------------------------------------------------------
// E5 §16.1 — the EFFECT registry. Deliberately NOT an extension of `Device`.
// ---------------------------------------------------------------------------

/// What an effect in an insert chain IS.
///
/// CLOSED, for the same reason `DeviceKind` is closed: an unknown kind must
/// fail loudly at the contract boundary (`Cmd::from_wire` → `Package::open`)
/// rather than build a silent no-op node. `tests/fx_commands.rs` pins that.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FxKind {
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

impl FxKind {
    pub fn wire_name(self) -> &'static str {
        match self {
            FxKind::Eq => "eq",
            FxKind::Compressor => "compressor",
            FxKind::Gate => "gate",
            FxKind::Delay => "delay",
            FxKind::Reverb => "reverb",
            FxKind::Saturator => "saturator",
            FxKind::Chorus => "chorus",
            FxKind::Utility => "utility",
            FxKind::Limiter => "limiter",
        }
    }

    pub fn parse(s: &str) -> Option<FxKind> {
        Some(match s {
            "eq" => FxKind::Eq,
            "compressor" => FxKind::Compressor,
            "gate" => FxKind::Gate,
            "delay" => FxKind::Delay,
            "reverb" => FxKind::Reverb,
            "saturator" => FxKind::Saturator,
            "chorus" => FxKind::Chorus,
            "utility" => FxKind::Utility,
            "limiter" => FxKind::Limiter,
            _ => return None,
        })
    }
}

/// Every parameter key any `FxKind` honours — the direct analogue of
/// `DEVICE_PARAM_KEYS`, and the `<paramKey>` segment of the three E5 ParamRef
/// families (`track.fx.<fxId>.<paramKey>`, `bus.<nodeId>.fx.<fxId>.<paramKey>`,
/// `master.fx.<fxId>.<paramKey>`).
///
/// ONE flat shared set across all nine kinds, exactly as `DEVICE_PARAM_KEYS` is
/// one flat set across three instrument kinds. Which keys a given KIND actually
/// honours is deliberately **NOT** validated here (E5 §16.3): `apply.rs` runs on
/// REPLAY, so tightening the (kind, key) pairing later would break replay of any
/// project that ever automated a key its kind ignores — a narrowing, which §2.1
/// rejects. The hole that leaves (automation bound to a key the kind ignores is
/// silently inert) is closed by `CompileReport::inert_lanes` render-side, not by
/// narrowing the contract.
///
/// **Growing this list is a WIDENING** of what `apply.rs` accepts, which is the
/// safe direction: nothing previously valid becomes invalid.
///
/// The EQ keys are FLAT (`band0Gain`, not `band.0.gain`) because the ParamRef
/// grammar gives an fx exactly ONE param segment; a nested spelling would not
/// parse as `track.fx.<fxId>.<paramKey>` at all.
pub const FX_PARAM_KEYS: [&str; 38] = [
    // universal
    "bypass", // 0/1, ramped over MICRO_FADE_FRAMES render-side (§16.6)
    "mix",    // dry/wet, 0..1
    "gain",
    // dynamics — compressor and gate share one detector (§17.2)
    "threshold",
    "ratio",
    "knee",
    "attack",
    "release",
    "makeup",
    "detector", // 0 = peak, 1 = RMS
    "hold",     // gate
    "range",    // gate
    // eq — four bands, flattened (see above)
    "band0Freq",
    "band0Gain",
    "band0Q",
    "band1Freq",
    "band1Gain",
    "band1Q",
    "band2Freq",
    "band2Gain",
    "band2Q",
    "band3Freq",
    "band3Gain",
    "band3Q",
    // delay / chorus
    "time",
    "division",
    "feedback",
    "rate",
    "depth",
    "spread",
    // reverb
    "size",
    "damping",
    "width",
    // saturator
    "drive",
    "tone",
    // utility
    "pan",
    "polarity",
    // limiter
    "ceiling",
];

/// An audio effect in an insert chain. **Chain order IS `Vec` order.**
///
/// This is a SEPARATE registry from `Device`, not a widening of it (E5 §16.1).
/// The blocking reason is concrete: `build_instrument` (`compile.rs:307-322`)
/// hard-errors on a track with more than one device, so an effect living in
/// `Track::devices` would break the compile of every instrument track that also
/// carries an effect. A separate collection makes that rewrite unnecessary —
/// `Track::devices` stays instruments-only and `build_instrument` is untouched.
/// Two further reasons: `Device::zones` is meaningless to every effect and
/// `Fx::sidechain` is meaningless to every instrument, and a separate name means
/// **zero enum widening sites** rather than one.
///
/// Instruments precede effects by construction and there is no interleaving rule
/// to invent: an instrument is a SOURCE (summed at the clip layer), an fx is an
/// INSERT (applied in the strip).
///
/// `params` is a `BTreeMap` for `project.json` byte stability and `Ord`-keyed
/// determinism, exactly like `Device::params`; values are `Num` (E0 §1 invariant
/// 6 — the integer/float SHAPE is hashed). Params stay **SPARSE**: an absent key
/// means "the DSP default", the same rule `build_instrument` already implements.
///
/// `extra` exists because every sibling struct has one and E0 §9.3 showed that
/// omitting it means a future field is DESTROYED, not ignored.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Fx {
    pub id: String,
    pub kind: FxKind,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub params: BTreeMap<String, Num>,
    /// Sidechain KEY source, or `None` for the internal (self) detector.
    ///
    /// Serialized as the `NodeRef` wire grammar — `track.<id>` | `bus.<id>` |
    /// `master` — because `NodeRef` already parses exactly the set of things
    /// that can be a key source and inventing a second "where does this live"
    /// type is how a model rots.
    ///
    /// A link is an **ORDERING CONSTRAINT, not an audio edge** (E5 §18.1): it
    /// creates no `RouteEdge` and contributes no audio. It does participate in
    /// cycle detection and topological ordering.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sidechain: Option<crate::routing::NodeRef>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub extra: Map<String, Value>,
}

impl Fx {
    pub fn new(id: impl Into<String>, kind: FxKind) -> Self {
        Fx {
            id: id.into(),
            kind,
            params: BTreeMap::new(),
            sidechain: None,
            extra: Map::new(),
        }
    }
}

/// Find an fx by id in a chain.
pub fn fx_index(chain: &[Fx], id: &str) -> Option<usize> {
    chain.iter().position(|f| f.id == id)
}

/// Highest MIDI note number a zone boundary may name.
pub const MAX_PITCH: i64 = 127;

/// THE SOURCE BINDING for a sampler zone or a drum pad.
///
/// A `Device`'s `params` map is `Num`-only, so before this there was no way to
/// say WHICH asset a zone or a pad plays and only `kind: synth` was reachable
/// end to end. A zone names its audio by `source_id` — the **same
/// content-addressed asset id a `Clip` uses** (`Clip::source_id`, registered in
/// `Project::sources`), resolved render-side through the **same**
/// `HashMap<String, Arc<AudioBuf>>` that `compile.rs` resolves clips through,
/// with the same loud "references unloaded source" failure. There is
/// deliberately no second lookup path and no filesystem path in the model.
///
/// ONE collection covers both instrument kinds, for exactly the reason
/// `INSTRUMENT_PARAM_KEYS` is one flat shared set: a per-kind split costs a
/// second command pair and a second checkpoint shape while buying nothing. An
/// instrument ignores the fields it has no use for —
///
/// | field | `sampler` | `drum` |
/// |---|---|---|
/// | `root_pitch` | the note the recording sounds at; playback rate is `2^((pitch-root)/12)` | ignored (a rack does not pitch-track) |
/// | `lo_pitch`/`hi_pitch` | the key range the zone covers | must be EQUAL: a pad is one key |
/// | `gain` | dB, applied to the zone | dB, applied to the pad |
/// | `pan` | ignored (the sampler is a pitched instrument on the track's pan) | pad pan, -1..=1 |
///
/// Every field that reaches the journal is `Num`, never `f32`/`f64` (E0 §1
/// invariant 6): `Num` preserves integer/float SHAPE and the blake3 chain
/// depends on it. `extra` exists because every sibling struct has one and E0
/// §9.3 showed that omitting it means a future field is DESTROYED, not ignored.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeviceZone {
    /// Stable identity for edit/undo, ULID-shaped like every other model id.
    pub id: String,
    /// Content-addressed asset id — the same registry `Clip::source_id` names.
    pub source_id: String,
    pub root_pitch: Num,
    pub lo_pitch: Num,
    pub hi_pitch: Num,
    /// Zone/pad gain in dB. Integer-shaped `0` is the canonical default, so a
    /// never-customized zone round-trips to the same bytes.
    #[serde(default = "DeviceZone::default_gain")]
    pub gain: Num,
    /// Pad pan, -1 (left) .. +1 (right). Honoured by `drum`, ignored by
    /// `sampler`.
    #[serde(default = "DeviceZone::default_pan")]
    pub pan: Num,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub extra: Map<String, Value>,
}

impl DeviceZone {
    pub fn default_gain() -> Num {
        Num::int(0)
    }

    pub fn default_pan() -> Num {
        Num::int(0)
    }

    /// Ordering key. Deliberately NOT `Num`'s shape-aware `PartialEq`: sorting
    /// needs a TOTAL order, and a zone boundary is validated to be an integer
    /// 0..=127 at apply time, so the integer view is exact for every zone this
    /// build can create. A float that slipped in from a foreign writer still
    /// sorts deterministically rather than panicking.
    fn pitch_key(n: &Num) -> i64 {
        n.0.as_i64().unwrap_or_else(|| n.as_f64().floor() as i64)
    }
}

/// An instrument (later: an effect) on a track.
///
/// Parameters are a `BTreeMap`, never a `HashMap`: `project.json` byte
/// stability and `Ord`-keyed determinism, exactly as `Automation::lanes`
/// requires. Values are `Num` (E0 §1 invariant 6).
///
/// Devices exist so `ParamRef::TrackDeviceParam` RESOLVES. Before this,
/// `require_param_ref` rejected every `track.device.*` path with "this build
/// has no device registry", which meant an instrument parameter could not be
/// automated at all — §3's "instrument params automate for free" was a promise
/// the model could not keep.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub kind: DeviceKind,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub params: BTreeMap<String, Num>,
    /// Source bindings for a `sampler` or `drum` device, sorted by
    /// `(lo_pitch, id)`. ADDITIVE and omitted when empty, so an existing
    /// device's bytes are unchanged — `tests/v1_1_replay_regression.rs` and
    /// `device_bytes_unchanged_without_zones` both pin that.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub zones: Vec<DeviceZone>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub extra: Map<String, Value>,
}

impl Device {
    pub fn new(id: impl Into<String>, kind: DeviceKind) -> Self {
        Device {
            id: id.into(),
            kind,
            params: BTreeMap::new(),
            zones: Vec::new(),
            extra: Map::new(),
        }
    }

    pub fn zone(&self, id: &str) -> Option<&DeviceZone> {
        self.zones.iter().find(|z| z.id == id)
    }

    pub fn zone_index(&self, id: &str) -> Option<usize> {
        self.zones.iter().position(|z| z.id == id)
    }

    /// Total, deterministic ordering — `(lo_pitch, id)`, mirroring
    /// `Automation::sort_lane`'s `(position_ticks, id)`. Nondeterministic
    /// ordering changes serialized bytes AND changes which of two overlapping
    /// zones wins at note-on, so this is a correctness property, not tidiness.
    pub(crate) fn sort_zones(&mut self) {
        self.zones
            .sort_by(|a, b| {
                (DeviceZone::pitch_key(&a.lo_pitch), &a.id)
                    .cmp(&(DeviceZone::pitch_key(&b.lo_pitch), &b.id))
            });
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Track {
    pub id: String,
    pub name: String,
    pub mute: bool,
    /// Clips sorted by (start_frame, id) for deterministic iteration.
    pub clips: Vec<Clip>,

    // Catalog-canonical state (additive since 0.2).
    #[serde(default = "Track::default_color")]
    pub color: String,
    #[serde(default = "Track::default_height")]
    pub height_px: u32,
    #[serde(default)]
    pub solo: bool,
    #[serde(default)]
    pub armed: bool,
    /// 0-based hardware input channel this track records from when armed.
    /// Defaults to 0 (first channel). Independent of arming: arming selects
    /// the destination track, this selects which mic feeds it.
    #[serde(default, rename = "inputChannel")]
    pub input_channel: u32,
    #[serde(default = "Track::default_gain")]
    pub gain: Num,
    #[serde(default = "Track::default_pan")]
    pub pan: Num,
    #[serde(default)]
    pub sends: Sends,
    #[serde(default = "default_eq")]
    pub eq: [EqBand; 4],
    #[serde(default)]
    pub automation: Automation,
    /// E1/E2: instruments on this track. Empty on every pre-E1 track, and
    /// omitted from both the checkpoint and the derived serialization when
    /// empty, so an existing track's bytes are unchanged.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub devices: Vec<Device>,
    /// E5: the INSERT chain on this track's strip. Chain order is `Vec` order.
    /// Additive and omitted when empty, so a pre-E5 track's bytes are unchanged
    /// (`tests/fx_bytes.rs` pins it).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fx: Vec<Fx>,
    #[serde(default)]
    pub extra: Map<String, Value>,
}

impl Track {
    pub fn device(&self, id: &str) -> Option<&Device> {
        self.devices.iter().find(|d| d.id == id)
    }

    pub fn device_index(&self, id: &str) -> Option<usize> {
        self.devices.iter().position(|d| d.id == id)
    }

    pub fn new(id: impl Into<String>, name: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            mute: false,
            clips: Vec::new(),
            color: Self::default_color(),
            height_px: Self::default_height(),
            solo: false,
            armed: false,
            input_channel: 0,
            gain: Num::int(0),
            pan: Num::int(0),
            sends: Sends::default(),
            eq: default_eq(),
            automation: Automation::default(),
            devices: Vec::new(),
            fx: Vec::new(),
            extra: Map::new(),
        }
    }

    fn default_color() -> String {
        DEFAULT_TRACK_COLOR.to_string()
    }

    fn default_height() -> u32 {
        DEFAULT_TRACK_HEIGHT_PX
    }

    fn default_gain() -> Num {
        Num::int(0)
    }

    fn default_pan() -> Num {
        Num::int(0)
    }

    pub(crate) fn sort_clips(&mut self) {
        self.clips
            .sort_by(|a, b| (a.start_frame, &a.id).cmp(&(b.start_frame, &b.id)));
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimeSig {
    pub numerator: u32,
    pub denominator: u32,
}

impl Default for TimeSig {
    fn default() -> Self {
        TimeSig {
            numerator: 4,
            denominator: 4,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Section {
    pub id: String,
    pub name: String,
    pub start_ticks: u64,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Marker {
    pub id: String,
    pub position_ticks: u64,
    pub label: String,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub extra: Map<String, Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Limiter {
    pub enabled: bool,
    pub ceiling_db: Num,
    pub release_ms: Num,
}

impl Default for Limiter {
    fn default() -> Self {
        Limiter {
            enabled: false,
            ceiling_db: Num::int(-1),
            release_ms: Num::int(50),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MasterBus {
    pub gain_db: Num,
    pub limiter: Limiter,
    /// E5 §16.2: the MASTER insert chain. `NodeRef::Master` addresses it, which
    /// is what makes a master-bus effect chain fall out of the `NodeRef` grammar
    /// for free — a `trackId`-keyed command family could never have expressed
    /// it. Runs BEFORE the existing master limiter (§16.7).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fx: Vec<Fx>,
    #[serde(default)]
    pub extra: Map<String, Value>,
}

impl Default for MasterBus {
    fn default() -> Self {
        MasterBus {
            gain_db: Num::int(0),
            limiter: Limiter::default(),
            fx: Vec::new(),
            extra: Map::new(),
        }
    }
}

/// A crossfade across the shared edge of two butt-joined clips on one track.
/// Same-track clips never overlap in v1; the crossfade is edge metadata and is
/// ACTIVE only while the two clips stay butt-joined (a pure predicate over
/// clip state, so replay stays exact).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Crossfade {
    pub clip_id_a: String,
    pub clip_id_b: String,
    pub length_ticks: u64,
    pub curve: FadeCurve,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TakeStatus {
    Candidate,
    Promoted,
    Discarded,
    Offline,
}

/// A generative take, recorded by `gen.landed` and driven through
/// `take.promote` / `take.discard`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TakeRecord {
    pub take_id: String,
    pub request_id: String,
    pub source_command: String,
    /// "mix" or stem names -> blake3 asset hash (sorted map: deterministic).
    pub asset_hashes: BTreeMap<String, String>,
    pub engine_identity: Value,
    pub status: TakeStatus,
    /// While Promoted: the clip it is spliced into and the asset the clip had
    /// before promotion (exact un-splice on discard/undo).
    #[serde(default)]
    pub promoted_into: Option<String>,
    #[serde(default)]
    pub prior_asset: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Project {
    /// Engine rate, 48 kHz in v1. SRC happens at IO (render/media side).
    pub sample_rate: u32,
    pub tempo: TempoMap,
    pub sources: Vec<Source>,
    pub tracks: Vec<Track>,

    // Catalog-canonical state (additive since 0.2).
    /// Wire-exact bpm (the number as `project.setTempo` received it) so the
    /// checkpoint and inverses preserve "92" vs "92.0" exactly.
    #[serde(default = "Project::default_bpm_wire")]
    pub bpm_wire: Num,
    #[serde(default = "Project::default_project_id")]
    pub project_id: String,
    #[serde(default = "Project::default_name")]
    pub name: String,
    #[serde(default)]
    pub key: String,
    #[serde(default)]
    pub time_sig: TimeSig,
    #[serde(default)]
    pub sections: Vec<Section>,
    #[serde(default)]
    pub markers: Vec<Marker>,
    #[serde(default)]
    pub master: MasterBus,
    #[serde(default)]
    pub crossfades: Vec<Crossfade>,
    #[serde(default)]
    pub takes: Vec<TakeRecord>,
    /// The routing DAG (design §5). Empty means the v1 implicit topology:
    /// every track straight to master plus the two hard-coded aux buses. E0
    /// owns the model + validation + topological sort; E5 owns evaluation.
    #[serde(default, skip_serializing_if = "Routing::is_empty")]
    pub routing: Routing,
    /// Project-level bar-grid phase anchor, in ticks (deferred proposal L8,
    /// accepted). 0 is the v1 behaviour.
    #[serde(default)]
    pub phase_anchor_ticks: u64,
    #[serde(default)]
    pub extra: Map<String, Value>,
}

impl Project {
    /// Every sidechain ORDERING link in the project, as `(source, host)` pairs
    /// (E5 §18.1/§18.2), collected by walking every fx chain on every track,
    /// every routing node and master.
    ///
    /// **This is the one implementation.** `compile.rs` calls it to feed
    /// `Routing::schedule`/`find_cycle`; `apply.rs` calls it to feed
    /// `validate_new_link`. Two implementations of a scheduling constraint that
    /// disagree is a mix that changes depending on which code path ran (§21.2).
    ///
    /// Deterministic order: tracks in project order, then routing nodes in
    /// declaration order, then master; within a host, chain order.
    pub fn sidechain_links(&self) -> Vec<(crate::routing::NodeRef, crate::routing::NodeRef)> {
        use crate::routing::NodeRef;
        let mut out = Vec::new();
        let mut push = |host: NodeRef, chain: &[Fx]| {
            for f in chain {
                if let Some(src) = &f.sidechain {
                    out.push((src.clone(), host.clone()));
                }
            }
        };
        for t in &self.tracks {
            push(NodeRef::Track(t.id.clone()), &t.fx);
        }
        for n in &self.routing.nodes {
            push(NodeRef::Node(n.id.clone()), &n.fx);
        }
        push(NodeRef::Master, &self.master.fx);
        out
    }

    /// The fx chain hosted by `target`, or `None` if the target does not
    /// resolve. `master` | `track.<id>` | `bus.<id>` (E5 §16.2).
    pub fn fx_chain(&self, target: &crate::routing::NodeRef) -> Option<&Vec<Fx>> {
        use crate::routing::NodeRef;
        match target {
            NodeRef::Master => Some(&self.master.fx),
            NodeRef::Track(id) => self.tracks.iter().find(|t| t.id == *id).map(|t| &t.fx),
            NodeRef::Node(id) => self
                .routing
                .nodes
                .iter()
                .find(|n| n.id == *id)
                .map(|n| &n.fx),
        }
    }

    pub fn new(sample_rate: u32, tempo: TempoMap) -> Self {
        let bpm_wire =
            Num::int(i64::from(tempo.first_bpm().num) / i64::from(tempo.first_bpm().den));
        Self {
            sample_rate,
            tempo,
            sources: Vec::new(),
            tracks: Vec::new(),
            bpm_wire,
            project_id: Self::default_project_id(),
            name: Self::default_name(),
            key: String::new(),
            time_sig: TimeSig::default(),
            sections: Vec::new(),
            markers: Vec::new(),
            master: MasterBus::default(),
            crossfades: Vec::new(),
            takes: Vec::new(),
            routing: Routing::default(),
            phase_anchor_ticks: 0,
            extra: Map::new(),
        }
    }

    fn default_bpm_wire() -> Num {
        Num::int(120)
    }

    fn default_project_id() -> String {
        "00000000000000000000000000".to_string()
    }

    fn default_name() -> String {
        "Untitled".to_string()
    }

    /// Register a source. The io layer owns asset resolution; this is the
    /// model-level registry (id = blake3 asset hash for catalog assets).
    pub fn add_source(&mut self, source: Source) -> Result<(), CommandError> {
        if self.sources.iter().any(|s| s.id == source.id) {
            return Err(CommandError::DuplicateId(source.id));
        }
        if source.len_frames == 0 {
            return Err(CommandError::InvalidParams(format!(
                "source {} has zero length",
                source.id
            )));
        }
        self.sources.push(source);
        Ok(())
    }

    pub fn source(&self, id: &str) -> Option<&Source> {
        self.sources.iter().find(|s| s.id == id)
    }

    pub fn track(&self, id: &str) -> Option<&Track> {
        self.tracks.iter().find(|t| t.id == id)
    }

    pub fn track_mut(&mut self, id: &str) -> Option<&mut Track> {
        self.tracks.iter_mut().find(|t| t.id == id)
    }

    pub fn track_index(&self, id: &str) -> Option<usize> {
        self.tracks.iter().position(|t| t.id == id)
    }

    /// (track index, clip index) for a clip id.
    pub fn find_clip(&self, clip_id: &str) -> Option<(usize, usize)> {
        for (ti, track) in self.tracks.iter().enumerate() {
            if let Some(ci) = track.clips.iter().position(|c| c.id == clip_id) {
                return Some((ti, ci));
            }
        }
        None
    }

    pub fn clip(&self, clip_id: &str) -> Option<&Clip> {
        self.find_clip(clip_id)
            .map(|(ti, ci)| &self.tracks[ti].clips[ci])
    }

    pub fn clip_id_exists(&self, clip_id: &str) -> bool {
        self.find_clip(clip_id).is_some()
    }

    /// End of the last clip on any track (bounce length helper).
    pub fn content_end_frame(&self) -> u64 {
        self.tracks
            .iter()
            .flat_map(|t| t.clips.iter())
            .map(|c| c.end_frame())
            .max()
            .unwrap_or(0)
    }

    pub fn section(&self, id: &str) -> Option<&Section> {
        self.sections.iter().find(|s| s.id == id)
    }

    pub fn marker(&self, id: &str) -> Option<&Marker> {
        self.markers.iter().find(|m| m.id == id)
    }

    pub fn take(&self, id: &str) -> Option<&TakeRecord> {
        self.takes.iter().find(|t| t.take_id == id)
    }

    pub fn take_mut(&mut self, id: &str) -> Option<&mut TakeRecord> {
        self.takes.iter_mut().find(|t| t.take_id == id)
    }

    /// The crossfade registered for an ordered clip pair, if any.
    pub fn crossfade(&self, a: &str, b: &str) -> Option<&Crossfade> {
        self.crossfades
            .iter()
            .find(|x| x.clip_id_a == a && x.clip_id_b == b)
    }

    /// A crossfade is active only while its two clips are butt-joined on the
    /// same track.
    pub fn crossfade_is_active(&self, x: &Crossfade) -> bool {
        let (Some((ta, ca)), Some((tb, cb))) =
            (self.find_clip(&x.clip_id_a), self.find_clip(&x.clip_id_b))
        else {
            return false;
        };
        if ta != tb {
            return false;
        }
        let a = &self.tracks[ta].clips[ca];
        let b = &self.tracks[tb].clips[cb];
        a.end_ticks() == b.start_ticks && x.length_ticks > 0
    }

    /// Re-derive every materialized frame field from canonical ticks
    /// (called after tempo changes).
    pub(crate) fn rematerialize_all(&mut self) {
        let tempo = self.tempo.clone();
        let rate = self.sample_rate;
        for track in &mut self.tracks {
            for clip in &mut track.clips {
                clip.rematerialize(&tempo, rate);
            }
            track.sort_clips();
        }
    }

    pub(crate) fn sort_sections_markers(&mut self) {
        self.sections
            .sort_by(|a, b| (a.start_ticks, &a.id).cmp(&(b.start_ticks, &b.id)));
        self.markers
            .sort_by(|a, b| (a.position_ticks, &a.id).cmp(&(b.position_ticks, &b.id)));
    }
}
