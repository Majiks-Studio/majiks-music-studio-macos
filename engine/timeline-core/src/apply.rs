//! The catalog executor: `Project::apply_cmd`.
//!
//! Contract per 02-ARCH section 4: validate first, mutate second; a failed
//! command NEVER partially applies. Every undoable command returns
//! (a) `inverse`: the FULL undo sequence (catalog commands that restore the
//! exact pre-state when applied in order; undo journals these forward), and
//! (b) `hint`: the single-command envelope inverse (catalog `inverseRule`
//! shape; exact when a single command can express the restoration, the
//! declared shape otherwise, e.g. `clip.split`). The distinction is P0-C's
//! own design: `autolane.clear` documents "undo restores the full prior point
//! set (runtime snapshot, not expressed field-by-field in this schema)".
//!
//! v1 semantic decisions that the contract leaves open are marked
//! `V1-DECISION` here, restated in INTERFACE.md and the evidence doc, and
//! carried as proposals in the lane report.

use crate::cmd::{Cmd, FadeEdge, NoteEdge, NoteSpec, NoteTiming, SendBus, TrimEdgeWire};
use crate::diff::ChangeScope;
use crate::error::CommandError;
use crate::model::{
    AutoPoint, Clip, Crossfade, Device, DeviceKind, DeviceZone, FadeCurve, FadeSpec, Marker,
    Project, Section, TakeRecord, TakeStatus, TimeSig, Track, Warp, WarpMode,
    DEFAULT_TRACK_COLOR, DEFAULT_TRACK_HEIGHT_PX, MAX_PITCH,
};
use serde_json::Map;
use crate::note::Note;
use crate::paramref::ParamRef;
use crate::num::Num;
use crate::tempo::Bpm;
use std::collections::BTreeSet;

/// Result of a successful apply.
#[derive(Debug, Clone, PartialEq)]
pub struct CmdEffect {
    /// True when the model changed (transport/view commands are false).
    pub mutated: bool,
    /// Full undo sequence (applied in order to restore the pre-state).
    /// Empty for non-undoable commands.
    pub inverse: Vec<Cmd>,
    /// Single-command envelope inverse. `Some` exactly when the catalog
    /// marks the command undoable (except `import.audio`, whose hint the
    /// host supplies; see session::submit_with_hint).
    pub hint: Option<Cmd>,
    /// Coarse change scopes for the diff-cursor.
    pub scopes: Vec<ChangeScope>,
}

impl CmdEffect {
    fn unjournaled_noop() -> Self {
        CmdEffect {
            mutated: false,
            inverse: Vec::new(),
            hint: None,
            scopes: Vec::new(),
        }
    }

    fn record_only(scopes: Vec<ChangeScope>) -> Self {
        CmdEffect {
            mutated: false,
            inverse: Vec::new(),
            hint: None,
            scopes,
        }
    }
}

/// Mixer gain bounds shared by mix.gain / mix.master.gain / clip.setGain
/// (the checkpoint schema constrains stored gains to [-60, 12] even where
/// the command schema leaves them open; enforced here so a checkpoint is
/// always schema-valid).
const GAIN_DB_MIN: f64 = -60.0;
const GAIN_DB_MAX: f64 = 12.0;

/// Velocity must be an INTEGER-SHAPED `Num` in 0..=127.
///
/// FINDING, not a design choice: the catalog types velocity `integer`, but
/// JSON Schema defines "integer" as *any number with a zero fractional part*,
/// so `100.0` validates. `Num` would then faithfully preserve the float shape
/// and re-emit `100.0` forever. The chain stays self-consistent either way, but
/// the shape is contract, so the check moves to apply time — the same
/// schema-time-to-apply-time move E0 §3 made for `ParamRef`, and for the same
/// reason: validation moved, it did not disappear.
fn check_velocity(v: &Num) -> Result<(), CommandError> {
    if !v.0.is_i64() && !v.0.is_u64() {
        return Err(CommandError::InvalidParams(format!(
            "velocity {} is float-shaped; velocities are integers on the wire (a JSON \
             Schema `integer` accepts 100.0, so this is enforced here)",
            v.0
        )));
    }
    if crate::note::velocity_in_range(v) {
        Ok(())
    } else {
        Err(CommandError::OutOfRange(format!(
            "velocity {} outside [0, {}]",
            v.as_f64(),
            crate::note::MIDI_MAX
        )))
    }
}

fn check_pitch(p: i64) -> Result<(), CommandError> {
    if (0..=crate::note::MIDI_MAX).contains(&p) {
        Ok(())
    } else {
        Err(CommandError::OutOfRange(format!(
            "pitch {p} outside [0, {}] — the engine refuses the whole batch rather than \
             clamping, because clamping is not invertible and would collapse a chord onto \
             the boundary",
            crate::note::MIDI_MAX
        )))
    }
}

/// `base + delta`, `None` on underflow past zero or on overflow.
fn offset_u64(base: u64, delta: i64) -> Option<u64> {
    if delta >= 0 {
        base.checked_add(delta as u64)
    } else {
        base.checked_sub(delta.unsigned_abs())
    }
}

/// The wire form of a note (the `note.add` batch element).
fn spec_of(n: &Note) -> crate::cmd::NoteSpec {
    crate::cmd::NoteSpec {
        note_id: n.id.clone(),
        start_ticks: n.start_ticks,
        length_ticks: n.length_ticks,
        pitch: n.pitch,
        velocity: n.velocity.clone(),
    }
}

/// Resolve a note-id batch against a clip. Every id must exist and the batch
/// must be non-empty and duplicate-free; a batch that names a missing note is
/// refused WHOLE, never applied partially.
fn require_note_batch<'a>(
    clip: &Clip,
    note_ids: &'a [String],
) -> Result<BTreeSet<&'a str>, CommandError> {
    if note_ids.is_empty() {
        return Err(CommandError::InvalidParams(
            "noteIds must not be empty".into(),
        ));
    }
    let mut set = BTreeSet::new();
    for id in note_ids {
        if !set.insert(id.as_str()) {
            return Err(CommandError::DuplicateId(id.clone()));
        }
        if clip.note_index(id).is_none() {
            return Err(CommandError::UnknownNote(id.clone()));
        }
    }
    Ok(set)
}

/// How far one absolute tick position travels toward its grid line, in ticks.
///
/// Three properties this has to have, and all three are why it is integer-only:
///
/// 1. **Anchored on the project's phase, not on tick 0.** `anchor` is
///    `Project::phase_anchor_ticks`. A landed generative song's bar 1 starts
///    partway into the timeline; grid lines measured from zero are not where
///    that song's beats are, so quantizing to them would move notes OFF the
///    beat with complete confidence.
/// 2. **Deterministic.** Replay re-runs this from the journal, so a float
///    multiply — whose rounding is not guaranteed identical across builds —
///    would be a chain divergence waiting to happen. Everything here is i64
///    with an explicit rounding rule: ties round to the LATER grid line, and
///    the strength scaling rounds half away from zero.
/// 3. **Strength-proportional, not thresholded.** At 0 the shift is exactly 0
///    (so a 0% quantize is a genuine no-op, not a small nudge); at 100 the
///    position lands exactly on the line.
fn quantize_shift(position: i64, anchor: i64, grid: i64, strength_percent: i64) -> i64 {
    debug_assert!(grid > 0);
    let rel = position - anchor;
    let below = rel.div_euclid(grid) * grid;
    let remainder = rel - below;
    let target = if remainder * 2 >= grid {
        below + grid
    } else {
        below
    };
    let full = target - rel;
    let scaled = full * strength_percent;
    if scaled >= 0 {
        (scaled + 50) / 100
    } else {
        -((-scaled + 50) / 100)
    }
}

fn check_note_length(length_ticks: u64) -> Result<(), CommandError> {
    if length_ticks == 0 {
        Err(CommandError::InvalidParams(
            "lengthTicks must be > 0; a zero-length note is never stored".into(),
        ))
    } else {
        Ok(())
    }
}

/// A zone boundary: an INTEGER-shaped `Num` in 0..=127.
///
/// Integer-shaped for the same reason `note.add`'s velocity is: a JSON Schema
/// `integer` accepts `60.0`, and `Num` hashes `60` and `60.0` differently, so
/// the shape has to be enforced here or two projects that mean the same thing
/// would carry different chains.
fn require_pitch(n: &Num, what: &str) -> Result<i64, CommandError> {
    if !n.is_integer_shaped() {
        return Err(CommandError::InvalidParams(format!(
            "device.zone.add: {what} {} is float-shaped; MIDI note numbers are integers on \
             the wire",
            n.0
        )));
    }
    let v = n.0.as_i64().ok_or_else(|| {
        CommandError::OutOfRange(format!("device.zone.add: {what} {} is out of range", n.0))
    })?;
    if !(0..=MAX_PITCH).contains(&v) {
        return Err(CommandError::OutOfRange(format!(
            "device.zone.add: {what} {v} outside [0, {MAX_PITCH}]"
        )));
    }
    Ok(v)
}

fn check_gain_bounds(what: &str, gain: &Num) -> Result<(), CommandError> {
    let v = gain.as_f64();
    if !(GAIN_DB_MIN..=GAIN_DB_MAX).contains(&v) {
        return Err(CommandError::OutOfRange(format!(
            "{what}: gainDb {v} outside [{GAIN_DB_MIN}, {GAIN_DB_MAX}]"
        )));
    }
    Ok(())
}

impl Project {
    fn require_track_index(&self, id: &str) -> Result<usize, CommandError> {
        self.track_index(id)
            .ok_or_else(|| CommandError::UnknownTrack(id.to_string()))
    }

    /// Validate a `ParamRef` without track context. Same checks as
    /// [`Project::require_param_ref_on`] — build-static only; see its doc for
    /// why live-state existence deliberately does NOT belong here (truthful
    /// inverses: a forward-legal removal's inverse must re-apply against
    /// mutated state).
    ///
    /// NOTE the deliberate asymmetry with persistence: an UNRECOGNIZED path or
    /// unknown key is rejected as a COMMAND (this build cannot mean anything
    /// by it) but is PRESERVED VERBATIM on load→save (a newer build may know
    /// it, and dropping it would be silent data loss). Those are two different
    /// questions and E0 answers them differently on purpose.
    pub fn require_param_ref(&self, r: &ParamRef) -> Result<(), CommandError> {
        self.require_param_ref_on(None, r)
    }

    /// `ParamRef` validation for the lane family (`autopoint.add/move`,
    /// `track.remove`'s lane guard).
    ///
    /// WHAT THIS CHECKS — and, deliberately, what it no longer does. Every
    /// check below is BUILD-STATIC: the path grammar recognizes the family and
    /// the key/band/send/field is one this build ships. None of it can change
    /// between two applies within one binary.
    ///
    /// It used to ALSO resolve the path against live model state (device on
    /// this track? fx in this chain? routing node? routing edge, and is its
    /// source a track?). Those existence checks were removed, and the reason
    /// is truthful inverses, not convenience:
    ///
    /// `autopoint.remove` and `autolane.clear` never check the path (deleting
    /// is always allowed — documented at their arms), and `device.remove` /
    /// `fx.remove` / `route.node.remove` / `route.disconnect` deliberately
    /// KEEP lanes that reference the removed object. So this five-command
    /// journal was fully forward-legal:
    ///
    ///   track.add → device.add dev0 → autopoint.add track.device.dev0.sustain
    ///   → device.remove dev0 → autopoint.remove <that point>
    ///
    /// …and then `undo()` FAILED: the recorded inverse `autopoint.add` re-ran
    /// this function against the post-removal state and was refused. A journal
    /// every binary accepts forward, whose recorded inverse cannot apply — a
    /// lie in the journal. Worse, for `route.edge.<id>.level` lanes the same
    /// refusal fired in the MIDDLE of `track.remove`'s restore sequence (the
    /// lane point is re-added before the edge is re-connected), and
    /// `Session::undo` pops the unit before applying with `?`, so the model
    /// was left HALF-restored and the unit destroyed.
    ///
    /// An existence check here can never be made undo-safe, because the
    /// forward commands that create the dangling state are (correctly) not
    /// refusable. So resolution against live state belongs to the one place
    /// that reads lanes: the render compile, which refuses an unreadable lane
    /// LOUDLY, BY NAME, with a remedy
    /// (`render/tests/inert_lanes.rs::a_lane_with_no_reader_is_refused_loudly`,
    /// `::an_fx_lane_naming_a_missing_fx_is_refused_loudly`) — a gate that
    /// already had to exist, because stranded lanes were always reachable.
    /// The §6.5 bus-sourced-edge deferral is enforced at that same gate now
    /// (only a track source has a dense lane table to read the lane).
    ///
    /// The consequence, chosen not accidental (pinned by
    /// `tests/undo_fidelity.rs::autopoint_add_on_a_never_existed_path_is_forward_legal_and_round_trips`):
    /// authoring a lane for a path that never resolved — a typo'd device id —
    /// now lands in the model and is refused at compile instead of at apply.
    ///
    /// Compatibility: this is a pure WIDENING of accepted journals. Every
    /// journal that replayed before replays byte-identically (a check that
    /// passed had no effect on state); new journals may hold entries an older
    /// binary refuses at open — loud, and the accepted direction (§9.2).
    ///
    /// `track_index` is kept for signature stability; no arm resolves against
    /// live state any more, so it is unused by construction.
    pub fn require_param_ref_on(
        &self,
        track_index: Option<usize>,
        r: &ParamRef,
    ) -> Result<(), CommandError> {
        use crate::paramref::ParamRefKind as K;
        let _ = track_index;
        let bad = |why: &str| Err(CommandError::UnknownParameter(format!("{r}: {why}")));
        match r.kind() {
            K::TrackVolume | K::TrackPan | K::MasterGain => Ok(()),
            K::TrackEq { band, .. } => {
                if (band as usize) < crate::model::EQ_DEFAULT_FREQS.len() {
                    Ok(())
                } else {
                    bad("v1 channel EQ has 4 bands, index 0-3")
                }
            }
            K::TrackSendLevel { send_id } => {
                if send_id == "a" || send_id == "b" {
                    Ok(())
                } else {
                    bad("v1 has exactly two sends, 'a' and 'b' (E5 generalizes this)")
                }
            }
            K::MasterLimiter { field } => {
                if field == "ceiling" || field == "release" {
                    Ok(())
                } else {
                    bad("master limiter parameters are 'ceiling' and 'release'")
                }
            }
            // Node existence is live state — compile-gated (see above).
            K::BusGain { .. } => Ok(()),
            K::TrackDeviceParam { param, .. } => {
                if !crate::model::DEVICE_PARAM_KEYS.contains(&param) {
                    return bad("not an instrument parameter this build knows");
                }
                Ok(())
            }
            // ---- E5 §16.3: effect parameters, on the three fx hosts ----
            //
            // Deliberately NOT validating the (kind, key) pairing, exactly as
            // `TrackDeviceParam` does not: `apply.rs` runs on REPLAY, so a
            // tightening here would break replay of any project that ever
            // automated a key its kind ignores. That is a narrowing, and §2.1
            // rejects narrowings. The hole it leaves — automation bound to a key
            // the kind ignores is silently inert — is closed render-side by
            // `CompileReport::inert_lanes`, not by narrowing the contract.
            // Host/fx EXISTENCE is live state — compile-gated (see above).
            K::TrackFxParam { param, .. }
            | K::BusFxParam { param, .. }
            | K::MasterFxParam { param, .. } => {
                if !crate::model::FX_PARAM_KEYS.contains(&param) {
                    return bad("not an effect parameter this build knows");
                }
                Ok(())
            }
            // ---- E5 §2.2/§6.5: routing edge level ----
            //
            // Edge existence AND the §6.5 "source must be a track" deferral
            // are both live state (an edge id can be freed by route.disconnect
            // and later reused by an edge with a different source), so both
            // now live at the compile gate. Keeping the source check here
            // conditional on existence would be incoherent — refuse a path
            // when its edge exists but accept it when the edge is gone.
            K::RouteEdgeLevel { .. } => Ok(()),
            K::Unrecognized => bad("not a parameter this build knows"),
        }
    }

    // ---- E5 §16: fx host resolution ----
    //
    // `NodeRef` is the fx host address (§16.2): `master` | `track.<id>` |
    // `bus.<id>`. One resolver, three collections, no second "where does this
    // effect live" type.

    /// The change scope an edit to `target`'s fx chain touches. E5 adds NO new
    /// `ChangeScope` (§8); `ChangeScope` is serialized and a finer scope is a
    /// report-and-stop, not a quiet addition.
    fn fx_scope(target: &crate::routing::NodeRef) -> ChangeScope {
        match target {
            crate::routing::NodeRef::Master => ChangeScope::Master,
            crate::routing::NodeRef::Track(id) => ChangeScope::Track(id.clone()),
            crate::routing::NodeRef::Node(_) => ChangeScope::Routing,
        }
    }

    fn fx_chain_mut(
        &mut self,
        target: &crate::routing::NodeRef,
    ) -> Result<&mut Vec<crate::model::Fx>, CommandError> {
        use crate::routing::NodeRef;
        match target {
            NodeRef::Master => Ok(&mut self.master.fx),
            NodeRef::Track(id) => {
                let ti = self.require_track_index(id)?;
                Ok(&mut self.tracks[ti].fx)
            }
            NodeRef::Node(id) => {
                let ni = self.routing.node_index(id).ok_or_else(|| {
                    CommandError::Routing(format!("no such routing node {id}"))
                })?;
                Ok(&mut self.routing.nodes[ni].fx)
            }
        }
    }

    /// `(chain index, chain)` for one fx, or a typed error naming what is
    /// missing. `UnknownDevice` is reused for a missing fx id: the code is
    /// stable and additive-stable, and an fx IS a device in the user's language
    /// even though it is a separate registry in the model.
    fn require_fx_index(
        &mut self,
        target: &crate::routing::NodeRef,
        fx_id: &str,
    ) -> Result<usize, CommandError> {
        let chain = self.fx_chain_mut(target)?;
        crate::model::fx_index(chain, fx_id)
            .ok_or_else(|| CommandError::UnknownDevice(format!("{fx_id} on {target}")))
    }

    fn require_clip_pos(&self, id: &str) -> Result<(usize, usize), CommandError> {
        self.find_clip(id)
            .ok_or_else(|| CommandError::UnknownClip(id.to_string()))
    }

    /// A clip that must be NOTE-BACKED. Every `note.*` command goes through
    /// here, so "add a note to an audio clip" is a typed error rather than a
    /// silently-ignored write.
    fn require_midi_clip(&self, id: &str, what: &str) -> Result<(usize, usize), CommandError> {
        let (ti, ci) = self.require_clip_pos(id)?;
        if !self.tracks[ti].clips[ci].is_midi() {
            return Err(CommandError::InvalidParams(format!(
                "{what}: clip {id} is audio-backed; notes live only on clips created by \
                 clip.placeMidi"
            )));
        }
        Ok((ti, ci))
    }

    /// The mirror guard: an AUDIO-only clip operation must refuse a note clip
    /// rather than write meaningless state (a fade or a stretch ratio on a MIDI
    /// clip would round-trip through the checkpoint and mean nothing).
    fn require_audio_clip(&self, id: &str, what: &str) -> Result<(usize, usize), CommandError> {
        let (ti, ci) = self.require_clip_pos(id)?;
        if self.tracks[ti].clips[ci].is_midi() {
            return Err(CommandError::InvalidParams(format!(
                "{what}: clip {id} is note-backed; this operation is audio-only"
            )));
        }
        Ok((ti, ci))
    }

    /// Overlap validation in the tick domain: same-track clips never overlap
    /// (crossfades are edge metadata, not overlaps).
    fn check_overlap(
        &self,
        track_index: usize,
        exclude_clip: Option<&str>,
        start_ticks: u64,
        length_ticks: u64,
    ) -> Result<(), CommandError> {
        let end = start_ticks
            .checked_add(length_ticks)
            .ok_or_else(|| CommandError::OutOfRange("clip extent overflows ticks".into()))?;
        for other in &self.tracks[track_index].clips {
            if Some(other.id.as_str()) == exclude_clip {
                continue;
            }
            if start_ticks < other.end_ticks() && other.start_ticks < end {
                return Err(CommandError::Overlap(format!(
                    "[{start_ticks}, {end}) overlaps clip {} [{}, {})",
                    other.id,
                    other.start_ticks,
                    other.end_ticks()
                )));
            }
        }
        Ok(())
    }

    /// Source-extent validation: applies only when the asset is registered
    /// and the clip is unwarped (content-addressing makes this deterministic
    /// across machines: the same hash always has the same length).
    fn check_source_extent(
        &self,
        asset_hash: &str,
        source_offset_ticks: u64,
        length_ticks: u64,
        warped: bool,
    ) -> Result<(), CommandError> {
        if warped {
            return Ok(());
        }
        let Some(source) = self.source(asset_hash) else {
            return Ok(()); // offline clip: length unknown, allowed by contract
        };
        let rate = self.sample_rate;
        let end = self
            .tempo
            .tick_to_frame(source_offset_ticks.saturating_add(length_ticks), rate);
        if end > source.len_frames {
            return Err(CommandError::OutOfRange(format!(
                "clip reads past source end ({} > {} frames of {asset_hash})",
                end, source.len_frames
            )));
        }
        Ok(())
    }

    fn rematerialize_clip(&mut self, ti: usize, ci: usize) {
        let tempo = self.tempo.clone();
        let rate = self.sample_rate;
        self.tracks[ti].clips[ci].rematerialize(&tempo, rate);
        self.tracks[ti].sort_clips();
    }

    /// The single-command envelope inverse of removing `clip`: the placement
    /// command that recreates it in the right KIND. `clip.remove`'s catalog
    /// `inverseRule.name` is v1.1 law (`clip.place`) and cannot change, but the
    /// entry is already annotated `inverseShape: multi` — "the runtime undo MAY
    /// be a sequence"; for a note-backed clip the head of that sequence is
    /// `clip.placeMidi`, because `clip.place` demands a 64-hex asset hash a
    /// MIDI clip does not have.
    fn clip_place_cmd(clip: &Clip, track_id: &str) -> Cmd {
        if clip.is_midi() {
            Cmd::ClipPlaceMidi {
                clip_id: clip.id.clone(),
                track_id: track_id.to_string(),
                start_ticks: clip.start_ticks,
                length_ticks: clip.length_ticks,
            }
        } else {
            Cmd::ClipPlace {
                clip_id: clip.id.clone(),
                track_id: track_id.to_string(),
                asset_hash: clip.source_id.clone(),
                start_ticks: clip.start_ticks,
                length_ticks: clip.length_ticks,
                source_offset_ticks: Some(clip.source_offset_ticks),
            }
        }
    }

    /// Restore commands for a full clip (everything clip.place cannot carry).
    fn clip_restore_sequence(clip: &Clip, track_id: &str) -> Vec<Cmd> {
        let mut seq = vec![Self::clip_place_cmd(clip, track_id)];
        debug_assert!(
            !clip.is_midi() || clip.source_offset_ticks == 0,
            "a note clip's content offset is pinned at 0 (start-edge trim is refused in E1)"
        );
        if !clip.notes.is_empty() {
            // One batched note.add restores every note in the clip's sorted
            // order, so the undo sequence is the same length whether the clip
            // holds one note or a thousand.
            seq.push(Cmd::NoteAdd {
                clip_id: clip.id.clone(),
                notes: clip.notes.iter().map(spec_of).collect(),
            });
        }
        if clip.name != clip.id {
            seq.push(Cmd::ClipRename {
                clip_id: clip.id.clone(),
                name: clip.name.clone(),
            });
        }
        if clip.gain != Num::int(0) {
            seq.push(Cmd::ClipSetGain {
                clip_id: clip.id.clone(),
                gain_db: clip.gain.clone(),
            });
        }
        if clip.muted {
            seq.push(Cmd::ClipMute {
                clip_id: clip.id.clone(),
                muted: true,
            });
        }
        if clip.fade_in != FadeSpec::default() {
            seq.push(Cmd::ClipFadeSet {
                clip_id: clip.id.clone(),
                edge: FadeEdge::In,
                length_ticks: clip.fade_in.length_ticks,
                shape: clip.fade_in.curve,
            });
        }
        if clip.fade_out != FadeSpec::default() {
            seq.push(Cmd::ClipFadeSet {
                clip_id: clip.id.clone(),
                edge: FadeEdge::Out,
                length_ticks: clip.fade_out.length_ticks,
                shape: clip.fade_out.curve,
            });
        }
        if clip.warp != Warp::default() {
            seq.push(Cmd::ClipWarpSet {
                clip_id: clip.id.clone(),
                mode: clip.warp.mode,
                stretch_ratio: match clip.warp.mode {
                    WarpMode::Ratio => Some(clip.warp.stretch_ratio.clone()),
                    WarpMode::Conform => None,
                },
            });
        }
        // The L8 phase anchor is per-clip authored state with its own command,
        // and `clip.place` cannot carry it. Omitting it made `clip.remove`
        // silently reset a warped clip's bar-grid alignment on undo — the same
        // defect class as the missing device restore below, found by the same
        // round-trip probe.
        if clip.phase_anchor_ticks != 0 {
            seq.push(Cmd::ClipPhaseAnchorSet {
                clip_id: clip.id.clone(),
                anchor_ticks: clip.phase_anchor_ticks,
            });
        }
        seq
    }

    /// Refuse rather than silently drop.
    ///
    /// `extra` holds checkpoint fields written by a NEWER build that no catalog
    /// command in THIS build can name, so an inverse cannot carry them. Dropping
    /// them on an undo is exactly the data loss the design exists to prevent —
    /// and it is invisible, because the model round-trips "successfully" minus
    /// the fields. `device.zone.remove` and `fx.remove` already refuse on this
    /// ground; every other destructive command now does too, in the same words.
    fn refuse_unrestorable_extra(
        cmd: &str,
        what: &str,
        id: &str,
        extra: &Map<String, serde_json::Value>,
    ) -> Result<(), CommandError> {
        if extra.is_empty() {
            return Ok(());
        }
        Err(CommandError::InvalidParams(format!(
            "{cmd}: {what} {id} carries {} unknown field(s) that no catalog command in this \
             build can restore, so removing it would not be undoable",
            extra.len()
        )))
    }

    /// The commands that rebuild `devices` on a track, in `Vec` order.
    ///
    /// `device.add` APPENDS, so adding in order restores registry order. Each
    /// device's zones follow its own `device.add`, so the sequence is valid at
    /// every prefix — the same shape `fx_restore_sequence` uses, and the same
    /// shape `device.remove`'s own inverse already uses for one device.
    ///
    /// `Device::params` IS emitted now, one `device.param.set` per stored key.
    /// It used to be skipped because no command could write one, which is why
    /// `track.remove` refused a track whose device carried params at all; that
    /// refusal is gone with the same commit that made the params writable.
    fn device_restore_sequence(track_id: &str, devices: &[Device]) -> Vec<Cmd> {
        let mut seq = Vec::new();
        for d in devices {
            seq.push(Cmd::DeviceAdd {
                track_id: track_id.to_string(),
                device_id: d.id.clone(),
                kind: d.kind,
            });
            seq.extend(d.params.iter().map(|(k, v)| Cmd::DeviceParamSet {
                track_id: track_id.to_string(),
                device_id: d.id.clone(),
                key: k.clone(),
                value: v.clone(),
            }));
            seq.extend(d.zones.iter().map(|z| Cmd::DeviceZoneAdd {
                track_id: track_id.to_string(),
                device_id: d.id.clone(),
                zone_id: z.id.clone(),
                source_id: z.source_id.clone(),
                root_pitch: z.root_pitch.clone(),
                lo_pitch: z.lo_pitch.clone(),
                hi_pitch: z.hi_pitch.clone(),
                gain_db: Some(z.gain.clone()),
                pan: Some(z.pan.clone()),
            }));
        }
        seq
    }

    /// Restore commands for a full (empty) track beyond track.add.
    /// The commands that rebuild `chain` on `target`, in chain order (E5 §16).
    ///
    /// `fx.add` APPENDS, so adding in `Vec` order restores chain order without
    /// a single `fx.move`. Each effect's stored params and sidechain link follow
    /// its own `fx.add`, so the sequence is valid at every prefix.
    fn fx_restore_sequence(
        target: &crate::routing::NodeRef,
        chain: &[crate::model::Fx],
    ) -> Vec<Cmd> {
        let mut seq = Vec::new();
        for f in chain {
            seq.push(Cmd::FxAdd {
                target: target.clone(),
                fx_id: f.id.clone(),
                kind: f.kind,
            });
            seq.extend(f.params.iter().map(|(k, v)| Cmd::FxParamSet {
                target: target.clone(),
                fx_id: f.id.clone(),
                key: k.clone(),
                value: v.clone(),
            }));
            if let Some(src) = &f.sidechain {
                seq.push(Cmd::FxSidechainSet {
                    target: target.clone(),
                    fx_id: f.id.clone(),
                    source: src.clone(),
                });
            }
        }
        seq
    }

    /// Drop every sidechain link that names `gone` as its KEY SOURCE, returning
    /// the commands that restore them.
    ///
    /// Removing a track or a routing node already removes its incident EDGES,
    /// "or the graph would keep an endpoint that resolves to nothing". A
    /// sidechain link is an ordering constraint over the same graph (E5 §18.1),
    /// so it needs exactly the same treatment: a link left pointing at a deleted
    /// node is a dangling ordering constraint that `resolves()` rejects and that
    /// the compile would have to invent a meaning for.
    fn clear_links_to(&mut self, gone: &crate::routing::NodeRef) -> Vec<Cmd> {
        use crate::routing::NodeRef;
        let mut restore = Vec::new();
        let mut sweep = |host: NodeRef, chain: &mut Vec<crate::model::Fx>| {
            for f in chain.iter_mut() {
                if f.sidechain.as_ref() == Some(gone) {
                    f.sidechain = None;
                    restore.push(Cmd::FxSidechainSet {
                        target: host.clone(),
                        fx_id: f.id.clone(),
                        source: gone.clone(),
                    });
                }
            }
        };
        for t in &mut self.tracks {
            let host = NodeRef::Track(t.id.clone());
            sweep(host, &mut t.fx);
        }
        for n in &mut self.routing.nodes {
            let host = NodeRef::Node(n.id.clone());
            sweep(host, &mut n.fx);
        }
        sweep(NodeRef::Master, &mut self.master.fx);
        restore
    }

    fn track_restore_sequence(track: &Track, index: usize) -> Vec<Cmd> {
        let mut seq = vec![Cmd::TrackAdd {
            track_id: track.id.clone(),
            name: track.name.clone(),
            index: Some(index as u32),
        }];
        if track.color != DEFAULT_TRACK_COLOR {
            seq.push(Cmd::TrackSetColor {
                track_id: track.id.clone(),
                color: track.color.clone(),
            });
        }
        if track.height_px != DEFAULT_TRACK_HEIGHT_PX {
            seq.push(Cmd::TrackSetHeight {
                track_id: track.id.clone(),
                height_px: track.height_px,
            });
        }
        if track.mute {
            seq.push(Cmd::TrackMute {
                track_id: track.id.clone(),
                muted: true,
            });
        }
        if track.solo {
            seq.push(Cmd::TrackSolo {
                track_id: track.id.clone(),
                soloed: true,
            });
        }
        if track.armed {
            seq.push(Cmd::TrackArm {
                track_id: track.id.clone(),
                armed: true,
            });
        }
        if track.input_channel != 0 {
            seq.push(Cmd::TrackSetInputChannel {
                track_id: track.id.clone(),
                channel: track.input_channel,
            });
        }
        if track.gain != Num::int(0) {
            seq.push(Cmd::MixGain {
                track_id: track.id.clone(),
                gain_db: track.gain.clone(),
            });
        }
        if track.pan != Num::int(0) {
            seq.push(Cmd::MixPan {
                track_id: track.id.clone(),
                pan: track.pan.clone(),
            });
        }
        let defaults = crate::model::default_eq();
        for (i, band) in track.eq.iter().enumerate() {
            if band != &defaults[i] {
                seq.push(Cmd::MixEq {
                    track_id: track.id.clone(),
                    band: i as u32,
                    freq_hz: band.freq_hz.clone(),
                    gain_db: band.gain_db.clone(),
                    q: Some(band.q.clone()),
                });
            }
        }
        if track.sends.a != Num::int(0) {
            seq.push(Cmd::MixSend {
                track_id: track.id.clone(),
                bus: SendBus::A,
                amount: track.sends.a.clone(),
            });
        }
        if track.sends.b != Num::int(0) {
            seq.push(Cmd::MixSend {
                track_id: track.id.clone(),
                bus: SendBus::B,
                amount: track.sends.b.clone(),
            });
        }
        // E2: the instrument registry. Restored BEFORE the automation loop for
        // exactly the reason the fx chain is: a `track.device.<id>.<key>` lane
        // does not resolve until the device exists (`require_param_ref_on`).
        //
        // Omitting this made `track.remove` lose every instrument on the track —
        // delete a track, undo, and your synth (and a sampler's whole set of
        // source bindings) was gone, with no error. When the track also carried
        // a device automation lane it was worse than silent: the inverse's
        // `autopoint.add` was REFUSED mid-sequence, and `Session::undo` applies
        // inverses with `?` after popping the unit, so the undo unit was
        // destroyed and the model left half-restored.
        seq.extend(Self::device_restore_sequence(&track.id, &track.devices));
        // E5: the INSERT chain, restored BEFORE the automation loop below,
        // because a `track.fx.<fxId>.<key>` lane does not resolve until the fx
        // exists (`require_param_ref_on`). Same reason the chain is rebuilt in
        // `Vec` order: `fx.add` appends, so in-order adds restore chain order
        // with no `fx.move`.
        seq.extend(Self::fx_restore_sequence(
            &crate::routing::NodeRef::Track(track.id.clone()),
            &track.fx,
        ));
        // EVERY lane, not just the two legacy ones: a restore sequence that
        // silently skipped a device/EQ lane would make track.remove's undo
        // lossy the moment E2 lands. `iter_lanes` is deterministic.
        for (target, points) in track.automation.iter_lanes() {
            for p in points {
                seq.push(Cmd::AutopointAdd {
                    track_id: track.id.clone(),
                    target: target.clone(),
                    point_id: p.id.clone(),
                    position_ticks: p.position_ticks,
                    value: p.value.clone(),
                });
            }
        }
        seq
    }

    /// Apply a catalog command. Full success returns the effect; any failure
    /// returns a typed error with the project untouched.
    pub fn apply_cmd(&mut self, cmd: &Cmd) -> Result<CmdEffect, CommandError> {
        match cmd {
            // ---- lifecycle: no model mutation here (host/session owns io) ----
            Cmd::ProjectNew { .. } | Cmd::ProjectOpen { .. } | Cmd::ProjectSave {} => {
                Ok(CmdEffect::unjournaled_noop())
            }

            // ---- transport / view / record: validated, no model mutation
            // (the host owns the capture side; a record.stop lands its take
            // through the normal txn/gen.landed/clip.place path, which journals
            // there, not here) ----
            Cmd::TransportPlay {}
            | Cmd::TransportStop {}
            | Cmd::TransportLoopClear {}
            | Cmd::TransportMetronome { .. }
            | Cmd::TransportSeek { .. }
            | Cmd::RecordStart { .. }
            | Cmd::RecordRotate {}
            | Cmd::RecordStop {}
            | Cmd::RecordCancel {}
            | Cmd::RecordInputListen { .. }
            | Cmd::MidiDeviceSelect { .. }
            | Cmd::MidiPortRoleSet { .. }
            | Cmd::MidiLearnStart { .. }
            | Cmd::MidiLearnStop {}
            | Cmd::MidiBindingSet { .. }
            | Cmd::MidiBindingClear { .. }
            | Cmd::MidiMapImport { .. }
            | Cmd::MidiMapExport { .. }
            | Cmd::MidiReload {} => Ok(CmdEffect::unjournaled_noop()),
            Cmd::TransportLoopSet {
                start_ticks,
                end_ticks,
            } => {
                if start_ticks >= end_ticks {
                    return Err(CommandError::InvalidParams(
                        "loop startTicks must be before endTicks".into(),
                    ));
                }
                Ok(CmdEffect::unjournaled_noop())
            }
            Cmd::AutolaneShow {
                track_id, target, ..
            } => {
                self.require_track_index(track_id)?;
                let _ = target;
                Ok(CmdEffect::unjournaled_noop())
            }
            Cmd::TakeAuditionMix { take_id, .. } => {
                self.take(take_id)
                    .ok_or_else(|| CommandError::UnknownTake(take_id.clone()))?;
                Ok(CmdEffect::unjournaled_noop())
            }

            // ---- project ----
            Cmd::ProjectSetTempo { bpm } => {
                let parsed = Bpm::from_json_number(&bpm.0)?;
                let prior = self.bpm_wire.clone();
                self.tempo.set_single(parsed);
                self.bpm_wire = bpm.clone();
                self.rematerialize_all();
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![Cmd::ProjectSetTempo { bpm: prior.clone() }],
                    hint: Some(Cmd::ProjectSetTempo { bpm: prior }),
                    scopes: vec![ChangeScope::Tempo],
                })
            }
            Cmd::ProjectSetTimeSig {
                numerator,
                denominator,
            } => {
                let prior = self.time_sig.clone();
                self.time_sig = TimeSig {
                    numerator: *numerator,
                    denominator: *denominator,
                };
                let inv = Cmd::ProjectSetTimeSig {
                    numerator: prior.numerator,
                    denominator: prior.denominator,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Project],
                })
            }
            Cmd::ProjectSetKey { key } => {
                let prior = self.key.clone();
                self.key = key.clone();
                let inv = Cmd::ProjectSetKey { key: prior };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Project],
                })
            }

            // ---- sections / markers ----
            Cmd::SectionSet {
                section_id,
                name,
                start_ticks,
                color,
            } => {
                let prior = self.section(section_id).cloned();
                let inv = match &prior {
                    None => Cmd::SectionRemove {
                        section_id: section_id.clone(),
                    },
                    Some(s) => Cmd::SectionSet {
                        section_id: s.id.clone(),
                        name: s.name.clone(),
                        start_ticks: s.start_ticks,
                        color: s.color.clone(),
                    },
                };
                match self.sections.iter_mut().find(|s| s.id == *section_id) {
                    Some(s) => {
                        s.name = name.clone();
                        s.start_ticks = *start_ticks;
                        s.color = color.clone();
                    }
                    None => self.sections.push(Section {
                        id: section_id.clone(),
                        name: name.clone(),
                        start_ticks: *start_ticks,
                        color: color.clone(),
                        extra: Default::default(),
                    }),
                }
                self.sort_sections_markers();
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Sections],
                })
            }
            Cmd::SectionRemove { section_id } => {
                let pos = self
                    .sections
                    .iter()
                    .position(|s| s.id == *section_id)
                    .ok_or_else(|| CommandError::UnknownSection(section_id.clone()))?;
                Self::refuse_unrestorable_extra(
                    "section.remove",
                    "section",
                    section_id,
                    &self.sections[pos].extra,
                )?;
                let s = self.sections.remove(pos);
                let inv = Cmd::SectionSet {
                    section_id: s.id,
                    name: s.name,
                    start_ticks: s.start_ticks,
                    color: s.color,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Sections],
                })
            }
            Cmd::MarkerSet {
                marker_id,
                position_ticks,
                label,
                color,
            } => {
                let prior = self.marker(marker_id).cloned();
                let inv = match &prior {
                    None => Cmd::MarkerRemove {
                        marker_id: marker_id.clone(),
                    },
                    Some(m) => Cmd::MarkerSet {
                        marker_id: m.id.clone(),
                        position_ticks: m.position_ticks,
                        label: m.label.clone(),
                        color: m.color.clone(),
                    },
                };
                match self.markers.iter_mut().find(|m| m.id == *marker_id) {
                    Some(m) => {
                        m.position_ticks = *position_ticks;
                        m.label = label.clone();
                        m.color = color.clone();
                    }
                    None => self.markers.push(Marker {
                        id: marker_id.clone(),
                        position_ticks: *position_ticks,
                        label: label.clone(),
                        color: color.clone(),
                        extra: Default::default(),
                    }),
                }
                self.sort_sections_markers();
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Markers],
                })
            }
            Cmd::MarkerRemove { marker_id } => {
                let pos = self
                    .markers
                    .iter()
                    .position(|m| m.id == *marker_id)
                    .ok_or_else(|| CommandError::UnknownMarker(marker_id.clone()))?;
                Self::refuse_unrestorable_extra(
                    "marker.remove",
                    "marker",
                    marker_id,
                    &self.markers[pos].extra,
                )?;
                let m = self.markers.remove(pos);
                let inv = Cmd::MarkerSet {
                    marker_id: m.id,
                    position_ticks: m.position_ticks,
                    label: m.label,
                    color: m.color,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Markers],
                })
            }

            // ---- track ----
            Cmd::TrackAdd {
                track_id,
                name,
                index,
            } => {
                if self.track(track_id).is_some() {
                    return Err(CommandError::DuplicateId(track_id.clone()));
                }
                let at = index.map(|i| i as usize).unwrap_or(self.tracks.len());
                if at > self.tracks.len() {
                    return Err(CommandError::OutOfRange(format!(
                        "track index {at} out of range 0..={}",
                        self.tracks.len()
                    )));
                }
                self.tracks
                    .insert(at, Track::new(track_id.clone(), name.clone()));
                let inv = Cmd::TrackRemove {
                    track_id: track_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Tracks],
                })
            }
            Cmd::TrackRemove { track_id } => {
                let index = self.require_track_index(track_id)?;
                if !self.tracks[index].clips.is_empty() {
                    return Err(CommandError::TrackNotEmpty(track_id.clone()));
                }
                // VALIDATE FIRST, MUTATE SECOND. Everything the restore sequence
                // cannot express is refused here, before a single field moves,
                // so `track.remove` either round-trips exactly or does nothing.
                {
                    let t = &self.tracks[index];
                    Self::refuse_unrestorable_extra("track.remove", "track", &t.id, &t.extra)?;
                    for d in &t.devices {
                        Self::refuse_unrestorable_extra("track.remove", "device", &d.id, &d.extra)?;
                        // Mirrors `device.remove`: the "carries stored params, so
                        // it cannot be restored" refusal is gone, because
                        // `device.param.set` restores a key exactly and
                        // `device_restore_sequence` now emits one per key. A
                        // track whose synth has been given a sound is a deletable
                        // track again.
                        for z in &d.zones {
                            Self::refuse_unrestorable_extra(
                                "track.remove",
                                "zone",
                                &z.id,
                                &z.extra,
                            )?;
                        }
                    }
                    for f in &t.fx {
                        Self::refuse_unrestorable_extra("track.remove", "fx", &f.id, &f.extra)?;
                    }
                }
                // A lane this build cannot RE-AUTHOR would make the restore
                // sequence fail halfway — the corrupting failure mode described
                // above. Since the existence widening, `require_param_ref_on`
                // fails only for build-static reasons (unknown key, unknown
                // path family, band/send/field out of this build's range), so
                // this guard now fires only for lanes loaded from a NEWER
                // build's checkpoint — `autopoint.add` refuses them live, and a
                // lane on merely-removed objects restores fine. Refuse up front
                // and name the remedy: `autolane.clear` works on any lane.
                for (target, _points) in self.tracks[index].automation.iter_lanes() {
                    if self.require_param_ref_on(Some(index), &target).is_err() {
                        return Err(CommandError::InvalidParams(format!(
                            "track.remove: track {track_id} carries an automation lane for \
                             '{target}', which no catalog command in this build can re-author \
                             (unknown key or path family, likely written by a newer build) — so \
                             removing the track would not be undoable. Clear the lane first \
                             (autolane.clear)."
                        )));
                    }
                }
                {
                    let me = crate::routing::NodeRef::Track(track_id.clone());
                    for e in &self.routing.edges {
                        if e.from == me || e.to == me {
                            Self::refuse_unrestorable_extra(
                                "track.remove",
                                "routing edge",
                                &e.id,
                                &e.extra,
                            )?;
                        }
                    }
                }
                let track = self.tracks.remove(index);
                let mut inverse = Self::track_restore_sequence(&track, index);
                // A track is an implicit routing node, so removing it must also
                // remove its incident edges or the graph would keep an endpoint
                // that resolves to nothing and `schedule` would emit a phantom
                // step. The undo restores them, so the round trip is exact.
                let me = crate::routing::NodeRef::Track(track.id.clone());
                let (removed, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut self.routing.edges)
                    .into_iter()
                    .partition(|e| e.from == me || e.to == me);
                self.routing.edges = kept;
                let mut touched_routing = !removed.is_empty();
                inverse.extend(removed.iter().map(|e| Cmd::RouteConnect {
                    edge_id: e.id.clone(),
                    from: e.from.clone(),
                    to: e.to.clone(),
                    level: e.level.clone(),
                    tap: e.tap,
                }));
                // E5 §18.1: a sidechain link is an ordering constraint over the
                // same graph, so it dangles for exactly the same reason an edge
                // would. Cleared here, restored by the inverse.
                let relinks = self.clear_links_to(&me);
                touched_routing |= !relinks.is_empty();
                inverse.extend(relinks);
                let mut scopes = vec![ChangeScope::Tracks];
                if touched_routing {
                    scopes.push(ChangeScope::Routing);
                }
                Ok(CmdEffect {
                    mutated: true,
                    inverse,
                    hint: Some(Cmd::TrackAdd {
                        track_id: track.id,
                        name: track.name,
                        index: Some(index as u32),
                    }),
                    scopes,
                })
            }
            Cmd::TrackRename { track_id, name } => {
                let index = self.require_track_index(track_id)?;
                let prior = std::mem::replace(&mut self.tracks[index].name, name.clone());
                let inv = Cmd::TrackRename {
                    track_id: track_id.clone(),
                    name: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Track(track_id.clone())],
                })
            }
            Cmd::TrackReorder {
                track_id,
                new_index,
            } => {
                let from = self.require_track_index(track_id)?;
                let to = *new_index as usize;
                if to >= self.tracks.len() {
                    return Err(CommandError::OutOfRange(format!(
                        "newIndex {to} out of range 0..{}",
                        self.tracks.len()
                    )));
                }
                let track = self.tracks.remove(from);
                self.tracks.insert(to, track);
                let inv = Cmd::TrackReorder {
                    track_id: track_id.clone(),
                    new_index: from as u32,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Tracks],
                })
            }
            Cmd::TrackSetColor { track_id, color } => {
                let index = self.require_track_index(track_id)?;
                let prior = std::mem::replace(&mut self.tracks[index].color, color.clone());
                let inv = Cmd::TrackSetColor {
                    track_id: track_id.clone(),
                    color: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Track(track_id.clone())],
                })
            }
            Cmd::TrackSetHeight {
                track_id,
                height_px,
            } => {
                let index = self.require_track_index(track_id)?;
                let prior = std::mem::replace(&mut self.tracks[index].height_px, *height_px);
                let inv = Cmd::TrackSetHeight {
                    track_id: track_id.clone(),
                    height_px: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Track(track_id.clone())],
                })
            }
            Cmd::TrackMute { track_id, muted } => {
                let index = self.require_track_index(track_id)?;
                let prior = std::mem::replace(&mut self.tracks[index].mute, *muted);
                let inv = Cmd::TrackMute {
                    track_id: track_id.clone(),
                    muted: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Track(track_id.clone())],
                })
            }
            Cmd::TrackSolo { track_id, soloed } => {
                let index = self.require_track_index(track_id)?;
                let prior = std::mem::replace(&mut self.tracks[index].solo, *soloed);
                let inv = Cmd::TrackSolo {
                    track_id: track_id.clone(),
                    soloed: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Track(track_id.clone())],
                })
            }
            Cmd::TrackArm { track_id, armed } => {
                let index = self.require_track_index(track_id)?;
                let prior = std::mem::replace(&mut self.tracks[index].armed, *armed);
                let inv = Cmd::TrackArm {
                    track_id: track_id.clone(),
                    armed: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Track(track_id.clone())],
                })
            }
            Cmd::TrackSetInputChannel { track_id, channel } => {
                let index = self.require_track_index(track_id)?;
                let prior =
                    std::mem::replace(&mut self.tracks[index].input_channel, *channel);
                let inv = Cmd::TrackSetInputChannel {
                    track_id: track_id.clone(),
                    channel: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Track(track_id.clone())],
                })
            }

            // ---- devices (the E1/E2 seam) ----
            Cmd::DeviceAdd {
                track_id,
                device_id,
                kind,
            } => {
                let ti = self.require_track_index(track_id)?;
                if self.tracks[ti].device_index(device_id).is_some() {
                    return Err(CommandError::DuplicateId(device_id.clone()));
                }
                self.tracks[ti]
                    .devices
                    .push(Device::new(device_id.clone(), *kind));
                let inv = Cmd::DeviceRemove {
                    track_id: track_id.clone(),
                    device_id: device_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Track(track_id.clone())],
                })
            }
            Cmd::DeviceRemove {
                track_id,
                device_id,
            } => {
                let ti = self.require_track_index(track_id)?;
                let di = self.tracks[ti]
                    .device_index(device_id)
                    .ok_or_else(|| CommandError::UnknownDevice(device_id.clone()))?;
                // THE "stored params make this device unremovable" GUARD IS GONE,
                // and its removal is the point of `device.param.set`.
                //
                // E1 refused a device carrying params because this build shipped
                // no command that could write one back, so `device.add` alone was
                // not an exact inverse and removing such a device would have lost
                // data silently. That reasoning was right and is now spent:
                // `device.param.set` restores a key exactly, so the inverse is a
                // SEQUENCE (add, then one set per stored param, then the zones)
                // rather than a refusal — the identical trade `fx.remove` already
                // makes, and `inverse_shape.rs` calls out by name ("`fx.param.set`
                // CAN restore them, so copying it would make every configured
                // effect unremovable").
                //
                // Keeping the guard would have been worse than useless here: the
                // moment a person picks a sound for their synth, the instrument
                // stops being removable — the tone control would have quietly
                // broken "Remove Instrument".
                //
                // The guard below covered a ZONE's unknown fields but not the
                // DEVICE's own — `device.add` reconstructs a `Device` with an
                // empty `extra`, so an unknown field on the device itself was
                // dropped by the undo just as silently.
                Self::refuse_unrestorable_extra(
                    "device.remove",
                    "device",
                    device_id,
                    &self.tracks[ti].devices[di].extra,
                )?;
                // A zone CAN be restored — `device.zone.add` carries every
                // field — so unlike `params` the sampler's source bindings do
                // not have to block the remove. They do make the inverse a
                // SEQUENCE, which is why `device.remove` is annotated
                // `inverseShape: "multi"` (the same shape `track.remove` and
                // `clip.remove` already use). A zone carrying unknown `extra`
                // is the one thing no command can restore; refuse that, exactly
                // as `device.zone.remove` does.
                if let Some(z) = self.tracks[ti].devices[di]
                    .zones
                    .iter()
                    .find(|z| !z.extra.is_empty())
                {
                    return Err(CommandError::InvalidParams(format!(
                        "device.remove: zone {} carries {} unknown field(s) that no catalog \
                         command in this build can restore, so removing it would not be undoable",
                        z.id,
                        z.extra.len()
                    )));
                }
                let device = self.tracks[ti].devices.remove(di);
                // Automation lanes addressing this device are NOT deleted:
                // `require_param_ref` refuses NEW points on a dead path, but an
                // authored lane is preserved verbatim so undo restores a
                // working project.
                let hint = Cmd::DeviceAdd {
                    track_id: track_id.clone(),
                    device_id: device.id.clone(),
                    kind: device.kind,
                };
                let mut inverse = vec![hint.clone()];
                // The authored sound, one command per stored key, BEFORE the
                // zones so the sequence reads the way `device_restore_sequence`
                // writes it. `params` is a BTreeMap, so this order is stable and
                // the journal is byte-reproducible across runs.
                inverse.extend(device.params.iter().map(|(k, v)| Cmd::DeviceParamSet {
                    track_id: track_id.clone(),
                    device_id: device.id.clone(),
                    key: k.clone(),
                    value: v.clone(),
                }));
                inverse.extend(device.zones.iter().map(|z| Cmd::DeviceZoneAdd {
                    track_id: track_id.clone(),
                    device_id: device.id.clone(),
                    zone_id: z.id.clone(),
                    source_id: z.source_id.clone(),
                    root_pitch: z.root_pitch.clone(),
                    lo_pitch: z.lo_pitch.clone(),
                    hi_pitch: z.hi_pitch.clone(),
                    gain_db: Some(z.gain.clone()),
                    pan: Some(z.pan.clone()),
                }));
                Ok(CmdEffect {
                    mutated: true,
                    inverse,
                    hint: Some(hint),
                    scopes: vec![ChangeScope::Track(track_id.clone())],
                })
            }

            // ---- the source binding (sampler zones / drum pads) ----
            Cmd::DeviceZoneAdd {
                track_id,
                device_id,
                zone_id,
                source_id,
                root_pitch,
                lo_pitch,
                hi_pitch,
                gain_db,
                pan,
            } => {
                let ti = self.require_track_index(track_id)?;
                let di = self.tracks[ti]
                    .device_index(device_id)
                    .ok_or_else(|| CommandError::UnknownDevice(device_id.clone()))?;
                // A synth synthesizes; it has nothing to read a sample from.
                // Accepting a zone on one would store state that renders
                // nothing — silent degradation, which is the failure class this
                // whole binding exists to close.
                if self.tracks[ti].devices[di].kind == DeviceKind::Synth {
                    return Err(CommandError::InvalidParams(format!(
                        "device.zone.add: device {device_id} has kind 'synth', which reads no \
                         audio; zones belong to 'sampler' or 'drum'"
                    )));
                }
                if self.tracks[ti].devices[di].zone_index(zone_id).is_some() {
                    return Err(CommandError::DuplicateId(zone_id.clone()));
                }
                if source_id.is_empty() {
                    return Err(CommandError::InvalidParams(
                        "device.zone.add: sourceId must not be empty".into(),
                    ));
                }
                let lo = require_pitch(lo_pitch, "loPitch")?;
                let hi = require_pitch(hi_pitch, "hiPitch")?;
                require_pitch(root_pitch, "rootPitch")?;
                if hi < lo {
                    return Err(CommandError::OutOfRange(format!(
                        "device.zone.add: hiPitch {hi} is below loPitch {lo}"
                    )));
                }
                // A pad is ONE key: a rack does not pitch-track, so a range
                // would silently collapse to its first key.
                if self.tracks[ti].devices[di].kind == DeviceKind::Drum && hi != lo {
                    return Err(CommandError::InvalidParams(format!(
                        "device.zone.add: a drum pad covers exactly one key, but zone {zone_id} \
                         spans {lo}..={hi}"
                    )));
                }
                // The source is deliberately NOT required to be registered
                // here: `check_source_extent` already lets a clip reference an
                // offline asset, and a zone follows the same rule. The LOUD
                // failure is render-side, where `compile.rs` resolves the very
                // same `sources` map and errors with "references unloaded
                // source" — one lookup path, one failure.
                let zone = DeviceZone {
                    id: zone_id.clone(),
                    source_id: source_id.clone(),
                    root_pitch: root_pitch.clone(),
                    lo_pitch: lo_pitch.clone(),
                    hi_pitch: hi_pitch.clone(),
                    gain: gain_db.clone().unwrap_or_else(DeviceZone::default_gain),
                    pan: pan.clone().unwrap_or_else(DeviceZone::default_pan),
                    extra: Map::new(),
                };
                self.tracks[ti].devices[di].zones.push(zone);
                self.tracks[ti].devices[di].sort_zones();
                let inv = Cmd::DeviceZoneRemove {
                    track_id: track_id.clone(),
                    device_id: device_id.clone(),
                    zone_id: zone_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Track(track_id.clone())],
                })
            }
            Cmd::DeviceZoneRemove {
                track_id,
                device_id,
                zone_id,
            } => {
                let ti = self.require_track_index(track_id)?;
                let di = self.tracks[ti]
                    .device_index(device_id)
                    .ok_or_else(|| CommandError::UnknownDevice(device_id.clone()))?;
                let zi = self.tracks[ti].devices[di]
                    .zone_index(zone_id)
                    .ok_or_else(|| CommandError::UnknownDevice(zone_id.clone()))?;
                // Same guard, same reason, as `device.remove`'s params check: a
                // zone written by a newer build can carry fields `zone.add`
                // cannot name, and dropping them on an undo is exactly the data
                // loss this design exists to prevent.
                if !self.tracks[ti].devices[di].zones[zi].extra.is_empty() {
                    return Err(CommandError::InvalidParams(format!(
                        "device.zone.remove: zone {zone_id} carries {} unknown field(s) that no \
                         catalog command in this build can restore, so removing it would not \
                         be undoable",
                        self.tracks[ti].devices[di].zones[zi].extra.len()
                    )));
                }
                let zone = self.tracks[ti].devices[di].zones.remove(zi);
                // The inverse carries EVERY field, gain and pan included, so
                // remove+add is exact whether or not they were defaulted.
                let inv = Cmd::DeviceZoneAdd {
                    track_id: track_id.clone(),
                    device_id: device_id.clone(),
                    zone_id: zone.id,
                    source_id: zone.source_id,
                    root_pitch: zone.root_pitch,
                    lo_pitch: zone.lo_pitch,
                    hi_pitch: zone.hi_pitch,
                    gain_db: Some(zone.gain),
                    pan: Some(zone.pan),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Track(track_id.clone())],
                })
            }

            // ---- what the instrument SOUNDS like ----
            //
            // Params stay SPARSE: an absent key means "the DSP default", which
            // is exactly what `build_instrument` implements (it starts from
            // `InstrumentParams::default()` and overwrites only the keys the
            // device stores). So the inverse of setting a key that was ABSENT is
            // `device.param.clear` — undoing to absent, NOT to a written
            // default. That is the property E1/E2 said it could not have without
            // "per-parameter defaults that the DSP lane owns", and it is the
            // same property `fx.param.set` shipped on. `inverseShape` is "multi"
            // because the declared inverse NAME cannot cover both directions.
            Cmd::DeviceParamSet {
                track_id,
                device_id,
                key,
                value,
            } => {
                if !crate::model::DEVICE_PARAM_KEYS.contains(&key.as_str()) {
                    return Err(CommandError::UnknownParameter(format!(
                        "{key}: not an instrument parameter this build knows"
                    )));
                }
                if !value.as_f64().is_finite() {
                    return Err(CommandError::InvalidParams(format!(
                        "device.param.set: {key} must be finite"
                    )));
                }
                let ti = self.require_track_index(track_id)?;
                let di = self.tracks[ti]
                    .device_index(device_id)
                    .ok_or_else(|| CommandError::UnknownDevice(device_id.clone()))?;
                let prior = self.tracks[ti].devices[di]
                    .params
                    .insert(key.clone(), value.clone());
                let inv = match prior {
                    Some(prev) => Cmd::DeviceParamSet {
                        track_id: track_id.clone(),
                        device_id: device_id.clone(),
                        key: key.clone(),
                        value: prev,
                    },
                    None => Cmd::DeviceParamClear {
                        track_id: track_id.clone(),
                        device_id: device_id.clone(),
                        key: key.clone(),
                    },
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Track(track_id.clone())],
                })
            }

            Cmd::DeviceParamClear {
                track_id,
                device_id,
                key,
            } => {
                let ti = self.require_track_index(track_id)?;
                let di = self.tracks[ti]
                    .device_index(device_id)
                    .ok_or_else(|| CommandError::UnknownDevice(device_id.clone()))?;
                // Clearing an absent key is a typed error, not a silent no-op:
                // a no-op would have no exact inverse to journal.
                let prior = self.tracks[ti].devices[di]
                    .params
                    .remove(key)
                    .ok_or_else(|| {
                        CommandError::UnknownParameter(format!(
                            "{key}: device {device_id} stores no value for this key (it is \
                             already at the DSP default)"
                        ))
                    })?;
                let inv = Cmd::DeviceParamSet {
                    track_id: track_id.clone(),
                    device_id: device_id.clone(),
                    key: key.clone(),
                    value: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Track(track_id.clone())],
                })
            }

            // ---- clip ----
            Cmd::ClipPlace {
                clip_id,
                track_id,
                asset_hash,
                start_ticks,
                length_ticks,
                source_offset_ticks,
            } => {
                if self.clip_id_exists(clip_id) {
                    return Err(CommandError::DuplicateId(clip_id.clone()));
                }
                let ti = self.require_track_index(track_id)?;
                if *length_ticks == 0 {
                    return Err(CommandError::InvalidParams(
                        "lengthTicks must be > 0".into(),
                    ));
                }
                let offset = source_offset_ticks.unwrap_or(0);
                self.check_overlap(ti, None, *start_ticks, *length_ticks)?;
                self.check_source_extent(asset_hash, offset, *length_ticks, false)?;
                // `offline` is a package load-time concern (does the asset file
                // exist under audio/), set by package::open, not here: the pure
                // executor never touches the filesystem.
                let mut clip = Clip::new_catalog(
                    clip_id.clone(),
                    asset_hash.clone(),
                    *start_ticks,
                    *length_ticks,
                    offset,
                );
                clip.rematerialize(&self.tempo.clone(), self.sample_rate);
                self.tracks[ti].clips.push(clip);
                self.tracks[ti].sort_clips();
                let inv = Cmd::ClipRemove {
                    clip_id: clip_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id.clone())],
                })
            }
            // ---- E1: note-backed clips ----
            Cmd::ClipPlaceMidi {
                clip_id,
                track_id,
                start_ticks,
                length_ticks,
            } => {
                if self.clip_id_exists(clip_id) {
                    return Err(CommandError::DuplicateId(clip_id.clone()));
                }
                let ti = self.require_track_index(track_id)?;
                if *length_ticks == 0 {
                    return Err(CommandError::InvalidParams(
                        "lengthTicks must be > 0".into(),
                    ));
                }
                self.check_overlap(ti, None, *start_ticks, *length_ticks)?;
                let mut clip = Clip::new_midi(clip_id.clone(), *start_ticks, *length_ticks);
                clip.rematerialize(&self.tempo.clone(), self.sample_rate);
                self.tracks[ti].clips.push(clip);
                self.tracks[ti].sort_clips();
                let inv = Cmd::ClipRemove {
                    clip_id: clip_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id.clone())],
                })
            }
            // ---- E1: MIDI notes. Batch-first and DELTA-based. ----
            //
            // Two properties every arm below preserves, and both are load-
            // bearing:
            //
            // 1. VALIDATE THE WHOLE BATCH FIRST, mutate second. A partial apply
            //    would leave a state no inverse describes.
            // 2. NEVER CLAMP. If a delta would move any note out of range the
            //    command is REFUSED. Clamping would silently break
            //    self-inversion (clamp, then negate the delta, and you do not
            //    get the original back) and would collapse a chord onto the
            //    boundary note by note. Group clamping that preserves voicing
            //    belongs to the caller, which is where the selection lives.
            Cmd::NoteAdd { clip_id, notes } => {
                let (ti, ci) = self.require_midi_clip(clip_id, "note.add")?;
                if notes.is_empty() {
                    return Err(CommandError::InvalidParams(
                        "note.add: notes must not be empty".into(),
                    ));
                }
                let mut seen: BTreeSet<&str> = BTreeSet::new();
                for spec in notes {
                    check_note_length(spec.length_ticks)?;
                    check_pitch(i64::from(spec.pitch))?;
                    check_velocity(&spec.velocity)?;
                    if !seen.insert(spec.note_id.as_str()) {
                        return Err(CommandError::DuplicateId(spec.note_id.clone()));
                    }
                    if self.tracks[ti].clips[ci].note_index(&spec.note_id).is_some() {
                        return Err(CommandError::DuplicateId(spec.note_id.clone()));
                    }
                }
                let track_id = self.tracks[ti].id.clone();
                let clip = &mut self.tracks[ti].clips[ci];
                for spec in notes {
                    clip.notes.push(Note::new(
                        spec.note_id.clone(),
                        spec.start_ticks,
                        spec.length_ticks,
                        spec.pitch,
                        spec.velocity.clone(),
                    ));
                }
                clip.sort_notes();
                // NOT self-inverse: undoing an add is a removal. Declared
                // `explicit -> note.remove` in the catalog for that reason.
                let inv = Cmd::NoteRemove {
                    clip_id: clip_id.clone(),
                    note_ids: notes.iter().map(|s| s.note_id.clone()).collect(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::NoteRemove { clip_id, note_ids } => {
                let (ti, ci) = self.require_midi_clip(clip_id, "note.remove")?;
                let wanted = require_note_batch(&self.tracks[ti].clips[ci], note_ids)?;
                // `NoteSpec` carries five fields; `Note` has a sixth. Whole
                // batch validated before anything is removed.
                for n in self.tracks[ti].clips[ci]
                    .notes
                    .iter()
                    .filter(|n| wanted.contains(n.id.as_str()))
                {
                    Self::refuse_unrestorable_extra("note.remove", "note", &n.id, &n.extra)?;
                }
                let track_id = self.tracks[ti].id.clone();
                // Snapshot in the MODEL's sorted order, not the caller's array
                // order, so the same removal always journals the same inverse.
                let restored: Vec<NoteSpec> = self.tracks[ti].clips[ci]
                    .notes
                    .iter()
                    .filter(|n| wanted.contains(n.id.as_str()))
                    .map(spec_of)
                    .collect();
                self.tracks[ti].clips[ci]
                    .notes
                    .retain(|n| !wanted.contains(n.id.as_str()));
                let inv = Cmd::NoteAdd {
                    clip_id: clip_id.clone(),
                    notes: restored,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::NoteMove {
                clip_id,
                note_ids,
                delta_ticks,
                delta_pitch,
            } => {
                let (ti, ci) = self.require_midi_clip(clip_id, "note.move")?;
                let wanted = require_note_batch(&self.tracks[ti].clips[ci], note_ids)?;
                // Pass 1: every note must land in range, or nothing moves.
                let mut moved: Vec<(usize, u64, u8)> = Vec::with_capacity(wanted.len());
                for (i, n) in self.tracks[ti].clips[ci].notes.iter().enumerate() {
                    if !wanted.contains(n.id.as_str()) {
                        continue;
                    }
                    let start = offset_u64(n.start_ticks, *delta_ticks).ok_or_else(|| {
                        CommandError::OutOfRange(format!(
                            "note.move: note {} would start before tick 0",
                            n.id
                        ))
                    })?;
                    let pitch = i64::from(n.pitch) + i64::from(*delta_pitch);
                    check_pitch(pitch)?;
                    moved.push((i, start, pitch as u8));
                }
                let track_id = self.tracks[ti].id.clone();
                let clip = &mut self.tracks[ti].clips[ci];
                for (i, start, pitch) in moved {
                    clip.notes[i].start_ticks = start;
                    clip.notes[i].pitch = pitch;
                }
                clip.sort_notes();
                let inv = Cmd::NoteMove {
                    clip_id: clip_id.clone(),
                    note_ids: note_ids.clone(),
                    delta_ticks: -*delta_ticks,
                    delta_pitch: -*delta_pitch,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::NoteResize {
                clip_id,
                note_ids,
                edge,
                delta_ticks,
            } => {
                let (ti, ci) = self.require_midi_clip(clip_id, "note.resize")?;
                let wanted = require_note_batch(&self.tracks[ti].clips[ci], note_ids)?;
                let mut sized: Vec<(usize, u64, u64)> = Vec::with_capacity(wanted.len());
                for (i, n) in self.tracks[ti].clips[ci].notes.iter().enumerate() {
                    if !wanted.contains(n.id.as_str()) {
                        continue;
                    }
                    let (start, length) = match edge {
                        // Leading: the note's END stays put. That is what makes
                        // the negated delta an exact inverse.
                        NoteEdge::Leading => {
                            let start =
                                offset_u64(n.start_ticks, *delta_ticks).ok_or_else(|| {
                                    CommandError::OutOfRange(format!(
                                        "note.resize: note {} would start before tick 0",
                                        n.id
                                    ))
                                })?;
                            let length =
                                offset_u64(n.length_ticks, -*delta_ticks).ok_or_else(|| {
                                    CommandError::OutOfRange(format!(
                                        "note.resize: note {} would have negative length",
                                        n.id
                                    ))
                                })?;
                            (start, length)
                        }
                        NoteEdge::Trailing => {
                            let length =
                                offset_u64(n.length_ticks, *delta_ticks).ok_or_else(|| {
                                    CommandError::OutOfRange(format!(
                                        "note.resize: note {} would have negative length",
                                        n.id
                                    ))
                                })?;
                            (n.start_ticks, length)
                        }
                    };
                    check_note_length(length)?;
                    sized.push((i, start, length));
                }
                let track_id = self.tracks[ti].id.clone();
                let clip = &mut self.tracks[ti].clips[ci];
                for (i, start, length) in sized {
                    clip.notes[i].start_ticks = start;
                    clip.notes[i].length_ticks = length;
                }
                clip.sort_notes();
                let inv = Cmd::NoteResize {
                    clip_id: clip_id.clone(),
                    note_ids: note_ids.clone(),
                    edge: *edge,
                    delta_ticks: -*delta_ticks,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::NoteVelocitySet {
                clip_id,
                note_ids,
                delta_velocity,
            } => {
                let (ti, ci) = self.require_midi_clip(clip_id, "note.velocity.set")?;
                let wanted = require_note_batch(&self.tracks[ti].clips[ci], note_ids)?;
                let mut vels: Vec<(usize, i64)> = Vec::with_capacity(wanted.len());
                for (i, n) in self.tracks[ti].clips[ci].notes.iter().enumerate() {
                    if !wanted.contains(n.id.as_str()) {
                        continue;
                    }
                    // The stored velocity is a `Num`; its integer view is the
                    // only sane base for an integer delta. A float-shaped
                    // velocity can only arrive from a hand-edited file, and it
                    // is rejected here rather than silently truncated.
                    let base = n.velocity.0.as_i64().ok_or_else(|| {
                        CommandError::InvalidParams(format!(
                            "note.velocity.set: note {} has a non-integer velocity; \
                             velocities are integers on the wire",
                            n.id
                        ))
                    })?;
                    let next = base + *delta_velocity;
                    if !(0..=crate::note::MIDI_MAX).contains(&next) {
                        return Err(CommandError::OutOfRange(format!(
                            "note.velocity.set: note {} would reach velocity {next}, outside \
                             [0, {}]",
                            n.id,
                            crate::note::MIDI_MAX
                        )));
                    }
                    vels.push((i, next));
                }
                let track_id = self.tracks[ti].id.clone();
                let clip = &mut self.tracks[ti].clips[ci];
                for (i, v) in vels {
                    // Integer-shaped in, integer-shaped out: `Num::int` never
                    // renders `100.0`.
                    clip.notes[i].velocity = Num::int(v);
                }
                let inv = Cmd::NoteVelocitySet {
                    clip_id: clip_id.clone(),
                    note_ids: note_ids.clone(),
                    delta_velocity: -*delta_velocity,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::NoteDuplicate {
                clip_id,
                note_ids,
                new_note_ids,
                delta_ticks,
                delta_pitch,
            } => {
                let (ti, ci) = self.require_midi_clip(clip_id, "note.duplicate")?;
                if note_ids.len() != new_note_ids.len() {
                    return Err(CommandError::InvalidParams(format!(
                        "note.duplicate: {} source ids but {} new ids; they are positionally \
                         paired",
                        note_ids.len(),
                        new_note_ids.len()
                    )));
                }
                let _ = require_note_batch(&self.tracks[ti].clips[ci], note_ids)?;
                let mut seen: BTreeSet<&str> = BTreeSet::new();
                for id in new_note_ids {
                    if !seen.insert(id.as_str()) {
                        return Err(CommandError::DuplicateId(id.clone()));
                    }
                    if self.tracks[ti].clips[ci].note_index(id).is_some() {
                        return Err(CommandError::DuplicateId(id.clone()));
                    }
                }
                // Build every copy before touching the model.
                let mut copies: Vec<Note> = Vec::with_capacity(note_ids.len());
                for (src, dst) in note_ids.iter().zip(new_note_ids.iter()) {
                    let n = self.tracks[ti].clips[ci]
                        .note(src)
                        .expect("checked by require_note_batch");
                    let start = offset_u64(n.start_ticks, *delta_ticks).ok_or_else(|| {
                        CommandError::OutOfRange(format!(
                            "note.duplicate: copy of {src} would start before tick 0"
                        ))
                    })?;
                    let pitch = i64::from(n.pitch) + i64::from(*delta_pitch);
                    check_pitch(pitch)?;
                    let mut copy = n.clone();
                    copy.id = dst.clone();
                    copy.start_ticks = start;
                    copy.pitch = pitch as u8;
                    // Same rule as `clip.duplicate`: a new id inherits no
                    // unknown fields, which also keeps this command's inverse
                    // (`note.remove` of the copies) applicable.
                    copy.extra = Map::new();
                    copies.push(copy);
                }
                let track_id = self.tracks[ti].id.clone();
                let clip = &mut self.tracks[ti].clips[ci];
                clip.notes.extend(copies);
                clip.sort_notes();
                let inv = Cmd::NoteRemove {
                    clip_id: clip_id.clone(),
                    note_ids: new_note_ids.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            // The two ABSOLUTE arms. Same two rules as the delta arms above —
            // validate the whole batch first, never clamp — but the inverse is
            // built from the pre-state rather than from a negated delta,
            // because no single delta describes what quantize does.
            Cmd::NoteTimingSet { clip_id, notes } => {
                let (ti, ci) = self.require_midi_clip(clip_id, "note.timing.set")?;
                if notes.is_empty() {
                    return Err(CommandError::InvalidParams(
                        "note.timing.set: notes must not be empty".into(),
                    ));
                }
                // Pass 1: every id distinct, every id present, every length
                // legal. Nothing is written until all of that holds.
                let mut seen: BTreeSet<&str> = BTreeSet::new();
                let mut targets: Vec<(usize, u64, u64)> = Vec::with_capacity(notes.len());
                for t in notes {
                    if !seen.insert(t.note_id.as_str()) {
                        return Err(CommandError::DuplicateId(t.note_id.clone()));
                    }
                    let index = self.tracks[ti].clips[ci]
                        .note_index(&t.note_id)
                        .ok_or_else(|| CommandError::UnknownNote(t.note_id.clone()))?;
                    check_note_length(t.length_ticks)?;
                    targets.push((index, t.start_ticks, t.length_ticks));
                }
                let track_id = self.tracks[ti].id.clone();
                // The inverse is taken in the CALLER's array order so that
                // `set(x) -> inverse -> set(x)` is a fixed point; the model's
                // sort order is restored by `sort_notes` either way.
                let prior: Vec<NoteTiming> = targets
                    .iter()
                    .map(|(index, _, _)| {
                        let n = &self.tracks[ti].clips[ci].notes[*index];
                        NoteTiming {
                            note_id: n.id.clone(),
                            start_ticks: n.start_ticks,
                            length_ticks: n.length_ticks,
                        }
                    })
                    .collect();
                let clip = &mut self.tracks[ti].clips[ci];
                for (index, start, length) in targets {
                    clip.notes[index].start_ticks = start;
                    clip.notes[index].length_ticks = length;
                }
                clip.sort_notes();
                let inv = Cmd::NoteTimingSet {
                    clip_id: clip_id.clone(),
                    notes: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::NoteQuantize {
                clip_id,
                note_ids,
                grid_ticks,
                strength_percent,
                quantize_ends,
            } => {
                let (ti, ci) = self.require_midi_clip(clip_id, "note.quantize")?;
                if *grid_ticks == 0 {
                    return Err(CommandError::InvalidParams(
                        "note.quantize: gridTicks must be > 0".into(),
                    ));
                }
                if *strength_percent > 100 {
                    return Err(CommandError::InvalidParams(format!(
                        "note.quantize: strengthPercent {strength_percent} is outside [0, 100]"
                    )));
                }
                let wanted = require_note_batch(&self.tracks[ti].clips[ci], note_ids)?;
                // Grid lines are measured from the PROJECT phase anchor, not
                // from tick 0. A song with a lead-in has its bar 1 partway into
                // the timeline; anchoring at zero would quantize every note to
                // a line that is not where the music's beats are.
                let anchor = self.phase_anchor_ticks as i64;
                let clip_start = self.tracks[ti].clips[ci].start_ticks as i64;
                let grid = *grid_ticks as i64;
                let strength = i64::from(*strength_percent);

                let mut moved: Vec<(usize, u64, u64)> = Vec::with_capacity(wanted.len());
                let mut prior: Vec<NoteTiming> = Vec::with_capacity(wanted.len());
                for (i, n) in self.tracks[ti].clips[ci].notes.iter().enumerate() {
                    if !wanted.contains(n.id.as_str()) {
                        continue;
                    }
                    let start_abs = clip_start + n.start_ticks as i64;
                    let start_shift =
                        quantize_shift(start_abs, anchor, grid, strength);
                    let new_start = n.start_ticks as i64 + start_shift;
                    if new_start < 0 {
                        return Err(CommandError::OutOfRange(format!(
                            "note.quantize: note {} would start before tick 0",
                            n.id
                        )));
                    }
                    let new_length = if *quantize_ends {
                        let end_abs = start_abs + n.length_ticks as i64;
                        let end_shift = quantize_shift(end_abs, anchor, grid, strength);
                        n.length_ticks as i64 + end_shift - start_shift
                    } else {
                        n.length_ticks as i64
                    };
                    if new_length < 1 {
                        return Err(CommandError::OutOfRange(format!(
                            "note.quantize: note {} would be squeezed to {new_length} ticks; \
                             the whole batch is refused rather than clamped, because a clamped \
                             note has no exact way back",
                            n.id
                        )));
                    }
                    prior.push(NoteTiming {
                        note_id: n.id.clone(),
                        start_ticks: n.start_ticks,
                        length_ticks: n.length_ticks,
                    });
                    moved.push((i, new_start as u64, new_length as u64));
                }
                let track_id = self.tracks[ti].id.clone();
                let clip = &mut self.tracks[ti].clips[ci];
                for (i, start, length) in moved {
                    clip.notes[i].start_ticks = start;
                    clip.notes[i].length_ticks = length;
                }
                clip.sort_notes();
                // EXACT prior positions, not a reverse quantize. Quantizing
                // back would land on the grid, not on the performance, and the
                // owner's own take is deliberately off it.
                let inv = Cmd::NoteTimingSet {
                    clip_id: clip_id.clone(),
                    notes: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::ClipRemove { clip_id } => {
                let (ti, ci) = self.require_clip_pos(clip_id)?;
                let track_id = self.tracks[ti].id.clone();
                // V1-DECISION: a promoted take pinned to this clip blocks
                // removal (discard the take first); keeps take un-splice exact.
                if let Some(t) = self
                    .takes
                    .iter()
                    .find(|t| t.promoted_into.as_deref() == Some(clip_id.as_str()))
                {
                    return Err(CommandError::TakeState(format!(
                        "clip {clip_id} carries promoted take {}; take.discard it first",
                        t.take_id
                    )));
                }
                {
                    let c = &self.tracks[ti].clips[ci];
                    Self::refuse_unrestorable_extra("clip.remove", "clip", &c.id, &c.extra)?;
                    for n in &c.notes {
                        Self::refuse_unrestorable_extra("clip.remove", "note", &n.id, &n.extra)?;
                    }
                }
                let clip = self.tracks[ti].clips.remove(ci);
                let inverse = Self::clip_restore_sequence(&clip, &track_id);
                let hint = Some(Cmd::ClipPlace {
                    clip_id: clip.id.clone(),
                    track_id,
                    asset_hash: clip.source_id.clone(),
                    start_ticks: clip.start_ticks,
                    length_ticks: clip.length_ticks,
                    source_offset_ticks: Some(clip.source_offset_ticks),
                });
                Ok(CmdEffect {
                    mutated: true,
                    inverse,
                    hint,
                    scopes: vec![ChangeScope::Clips(self.tracks[ti].id.clone())],
                })
            }
            Cmd::ClipMove {
                clip_id,
                track_id,
                start_ticks,
            } => {
                let (ti, ci) = self.require_clip_pos(clip_id)?;
                let dest = self.require_track_index(track_id)?;
                let from_track_id = self.tracks[ti].id.clone();
                let prior_start = self.tracks[ti].clips[ci].start_ticks;
                let length = self.tracks[ti].clips[ci].length_ticks;
                let exclude = if dest == ti {
                    Some(clip_id.as_str())
                } else {
                    None
                };
                self.check_overlap(dest, exclude, *start_ticks, length)?;
                let mut clip = self.tracks[ti].clips.remove(ci);
                clip.start_ticks = *start_ticks;
                clip.rematerialize(&self.tempo.clone(), self.sample_rate);
                self.tracks[dest].clips.push(clip);
                self.tracks[dest].sort_clips();
                let inv = Cmd::ClipMove {
                    clip_id: clip_id.clone(),
                    track_id: from_track_id.clone(),
                    start_ticks: prior_start,
                };
                let mut scopes = vec![ChangeScope::Clips(from_track_id)];
                if dest != ti {
                    scopes.push(ChangeScope::Clips(track_id.clone()));
                }
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes,
                })
            }
            Cmd::ClipTrim {
                clip_id,
                edge,
                delta_ticks,
            } => {
                let (ti, ci) = self.require_clip_pos(clip_id)?;
                let track_id = self.tracks[ti].id.clone();
                let clip = &self.tracks[ti].clips[ci];
                if *delta_ticks == 0 {
                    return Err(CommandError::InvalidParams(
                        "deltaTicks must be nonzero".into(),
                    ));
                }
                // E1 LIMITATION, deliberate and reported rather than faked: a
                // note clip's content offset is pinned at 0 so `Note.start_ticks`
                // is literally clip-relative (§1). Sliding the start edge would
                // either desync that or force every start trim to rewrite/crop
                // notes with a multi-command inverse. Refused, not silently
                // mis-applied. The end edge works and is the common crop.
                if *edge == TrimEdgeWire::Start && clip.is_midi() {
                    return Err(CommandError::InvalidParams(format!(
                        "clip.trim: clip {clip_id} is note-backed; E1 supports the end edge only \
                         (a start-edge trim would move note positions relative to the clip)"
                    )));
                }
                let (new_start, new_offset, new_length) = match edge {
                    TrimEdgeWire::Start => {
                        // positive shortens from the start edge
                        let new_start = checked_add_signed(clip.start_ticks, *delta_ticks)
                            .ok_or_else(|| neg_err("start"))?;
                        let new_offset = checked_add_signed(clip.source_offset_ticks, *delta_ticks)
                            .ok_or_else(|| {
                                CommandError::OutOfRange(
                                    "start trim extends before source content".into(),
                                )
                            })?;
                        let new_length = checked_add_signed(clip.length_ticks, -*delta_ticks)
                            .filter(|l| *l > 0)
                            .ok_or_else(|| {
                                CommandError::OutOfRange("trim leaves no clip length".into())
                            })?;
                        (new_start, new_offset, new_length)
                    }
                    TrimEdgeWire::End => {
                        // positive lengthens from the end edge
                        let new_length = checked_add_signed(clip.length_ticks, *delta_ticks)
                            .filter(|l| *l > 0)
                            .ok_or_else(|| {
                                CommandError::OutOfRange("trim leaves no clip length".into())
                            })?;
                        (clip.start_ticks, clip.source_offset_ticks, new_length)
                    }
                };
                if clip.fade_in.length_ticks > new_length || clip.fade_out.length_ticks > new_length
                {
                    return Err(CommandError::OutOfRange(
                        "trim would leave a fade longer than the clip; shrink fades first".into(),
                    ));
                }
                let warped = clip.warp != Warp::default();
                let asset = clip.source_id.clone();
                self.check_overlap(ti, Some(clip_id), new_start, new_length)?;
                self.check_source_extent(&asset, new_offset, new_length, warped)?;
                {
                    let clip = &mut self.tracks[ti].clips[ci];
                    clip.start_ticks = new_start;
                    clip.source_offset_ticks = new_offset;
                    clip.length_ticks = new_length;
                }
                self.rematerialize_clip(ti, ci);
                let inv = Cmd::ClipTrim {
                    clip_id: clip_id.clone(),
                    edge: *edge,
                    delta_ticks: -*delta_ticks,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::ClipSplit {
                clip_id,
                at_ticks,
                new_clip_id,
            } => {
                if self.clip_id_exists(new_clip_id) {
                    return Err(CommandError::DuplicateId(new_clip_id.clone()));
                }
                let (ti, ci) = self.require_clip_pos(clip_id)?;
                let track_id = self.tracks[ti].id.clone();
                let clip = &self.tracks[ti].clips[ci];
                let (start, end) = (clip.start_ticks, clip.end_ticks());
                if !(*at_ticks > start && *at_ticks < end) {
                    return Err(CommandError::OutOfRange(format!(
                        "split point {at_ticks} must be strictly inside ({start}, {end})"
                    )));
                }
                let left_len = *at_ticks - start;
                let right_len = end - *at_ticks;
                if clip.fade_in.length_ticks > left_len {
                    return Err(CommandError::OutOfRange(
                        "fade-in longer than the left piece; shrink it first".into(),
                    ));
                }
                if clip.fade_out.length_ticks > right_len {
                    return Err(CommandError::OutOfRange(
                        "fade-out longer than the right piece; shrink it first".into(),
                    ));
                }
                let prior_len = clip.length_ticks;
                let prior_fade_out = clip.fade_out.clone();
                let is_midi = clip.is_midi();
                let mut right = clip.clone();
                right.id = new_clip_id.clone();
                right.name = new_clip_id.clone();
                // A NEW object gets no inherited unknown fields. `extra` holds
                // fields a newer build wrote FOR A SPECIFIC clip id; copying
                // them onto an id that build never saw is a fabrication, and it
                // would make this command's own inverse (`clip.remove` of the
                // right piece) refuse. The left piece keeps them, and undo
                // restores the left piece whole.
                right.extra = Map::new();
                right.start_ticks = *at_ticks;
                right.length_ticks = right_len;
                // V1-DECISION: source offset maps linearly across the split
                // for warped clips too (documented; warp-exact split math is
                // an L2 refinement). A note clip has no source, and its offset
                // stays pinned at 0 (see clip.trim).
                right.source_offset_ticks = if is_midi {
                    0
                } else {
                    clip.source_offset_ticks + left_len
                };
                right.fade_in = FadeSpec::default();

                // E1: split notes by WHOLE NOTE, at the side that contains the
                // note's START. Cutting a straddling note in two would have to
                // mint an id at apply time, and a minted id is nondeterministic
                // — it would make replay diverge from the live model. A note
                // that now overhangs its clip's end is simply cut short at bake
                // time (render::compile emits its note-off at the clip end),
                // which is also what makes "no stuck notes" structural.
                let mut moved: Vec<crate::note::Note> = Vec::new();
                if is_midi {
                    let mut kept = Vec::with_capacity(right.notes.len());
                    for n in std::mem::take(&mut right.notes) {
                        if n.start_ticks >= left_len {
                            let mut n = n;
                            n.start_ticks -= left_len;
                            kept.push(n);
                        }
                    }
                    right.notes = kept;
                }
                {
                    let left = &mut self.tracks[ti].clips[ci];
                    left.length_ticks = left_len;
                    left.fade_out = FadeSpec::default();
                    if is_midi {
                        let mut kept = Vec::with_capacity(left.notes.len());
                        for n in std::mem::take(&mut left.notes) {
                            if n.start_ticks < left_len {
                                kept.push(n);
                            } else {
                                moved.push(n);
                            }
                        }
                        left.notes = kept;
                    }
                }
                right.rematerialize(&self.tempo.clone(), self.sample_rate);
                self.tracks[ti].clips.push(right);
                self.rematerialize_clip(ti, ci);
                let mut inverse = vec![
                    Cmd::ClipRemove {
                        clip_id: new_clip_id.clone(),
                    },
                    Cmd::ClipTrim {
                        clip_id: clip_id.clone(),
                        edge: TrimEdgeWire::End,
                        delta_ticks: (prior_len - left_len) as i64,
                    },
                ];
                if prior_fade_out != FadeSpec::default() {
                    inverse.push(Cmd::ClipFadeSet {
                        clip_id: clip_id.clone(),
                        edge: FadeEdge::Out,
                        length_ticks: prior_fade_out.length_ticks,
                        shape: prior_fade_out.curve,
                    });
                }
                // Removing the right piece deletes the notes that went with it;
                // the undo sequence puts them back on the left clip at their
                // ORIGINAL positions (unchanged values, so this is exact).
                if !moved.is_empty() {
                    inverse.push(Cmd::NoteAdd {
                        clip_id: clip_id.clone(),
                        notes: moved.iter().map(spec_of).collect(),
                    });
                }
                // Envelope hint: the catalog declares clip.split self-inverse;
                // a single command cannot rejoin, so the hint carries the
                // declared shape and real undo uses the sequence above
                // (proposal on record).
                let hint = Some(Cmd::ClipSplit {
                    clip_id: clip_id.clone(),
                    at_ticks: *at_ticks,
                    new_clip_id: new_clip_id.clone(),
                });
                Ok(CmdEffect {
                    mutated: true,
                    inverse,
                    hint,
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::ClipDuplicate {
                clip_id,
                new_clip_id,
                start_ticks,
            } => {
                if self.clip_id_exists(new_clip_id) {
                    return Err(CommandError::DuplicateId(new_clip_id.clone()));
                }
                let (ti, ci) = self.require_clip_pos(clip_id)?;
                let track_id = self.tracks[ti].id.clone();
                let src = self.tracks[ti].clips[ci].clone();
                self.check_overlap(ti, None, *start_ticks, src.length_ticks)?;
                let mut copy = src.clone();
                copy.id = new_clip_id.clone();
                copy.name = if src.name == src.id {
                    new_clip_id.clone()
                } else {
                    src.name.clone()
                };
                copy.start_ticks = *start_ticks;
                // Same rule as `clip.split`: a new id inherits no unknown fields.
                copy.extra = Map::new();
                copy.rematerialize(&self.tempo.clone(), self.sample_rate);
                self.tracks[ti].clips.push(copy);
                self.tracks[ti].sort_clips();
                let inv = Cmd::ClipRemove {
                    clip_id: new_clip_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::ClipSetGain { clip_id, gain_db } => {
                check_gain_bounds("clip.setGain", gain_db)?;
                let (ti, ci) = self.require_clip_pos(clip_id)?;
                let track_id = self.tracks[ti].id.clone();
                let clip = &mut self.tracks[ti].clips[ci];
                let prior = std::mem::replace(&mut clip.gain, gain_db.clone());
                clip.gain_db = gain_db.as_f64() as f32;
                let inv = Cmd::ClipSetGain {
                    clip_id: clip_id.clone(),
                    gain_db: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::ClipMute { clip_id, muted } => {
                let (ti, ci) = self.require_clip_pos(clip_id)?;
                let track_id = self.tracks[ti].id.clone();
                let prior = std::mem::replace(&mut self.tracks[ti].clips[ci].muted, *muted);
                let inv = Cmd::ClipMute {
                    clip_id: clip_id.clone(),
                    muted: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::ClipFadeSet {
                clip_id,
                edge,
                length_ticks,
                shape,
            } => {
                let (ti, ci) = self.require_audio_clip(clip_id, "clip.fade.set")?;
                let track_id = self.tracks[ti].id.clone();
                let clip = &self.tracks[ti].clips[ci];
                if *length_ticks > clip.length_ticks {
                    return Err(CommandError::OutOfRange(format!(
                        "fade of {length_ticks} ticks exceeds clip length {}",
                        clip.length_ticks
                    )));
                }
                let prior = match edge {
                    FadeEdge::In => clip.fade_in.clone(),
                    FadeEdge::Out => clip.fade_out.clone(),
                };
                let clip = &mut self.tracks[ti].clips[ci];
                let spec = FadeSpec {
                    length_ticks: *length_ticks,
                    curve: *shape,
                };
                match edge {
                    FadeEdge::In => clip.fade_in = spec,
                    FadeEdge::Out => clip.fade_out = spec,
                }
                clip.fade_shape = shape.to_fade_shape();
                self.rematerialize_clip(ti, ci);
                let inv = Cmd::ClipFadeSet {
                    clip_id: clip_id.clone(),
                    edge: *edge,
                    length_ticks: prior.length_ticks,
                    shape: prior.curve,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::ClipCrossfadeSet {
                clip_id_a,
                clip_id_b,
                length_ticks,
                shape,
            } => {
                let (ta, ca) = self.require_audio_clip(clip_id_a, "clip.crossfade.set")?;
                let (tb, cb) = self.require_audio_clip(clip_id_b, "clip.crossfade.set")?;
                if ta != tb {
                    return Err(CommandError::NotAdjacent(format!(
                        "{clip_id_a} and {clip_id_b} are on different tracks"
                    )));
                }
                let a = &self.tracks[ta].clips[ca];
                let b = &self.tracks[tb].clips[cb];
                if a.end_ticks() != b.start_ticks {
                    return Err(CommandError::NotAdjacent(format!(
                        "{clip_id_a} must end exactly where {clip_id_b} starts"
                    )));
                }
                if *length_ticks > a.length_ticks || *length_ticks > b.length_ticks {
                    return Err(CommandError::OutOfRange(
                        "crossfade longer than one of the clips".into(),
                    ));
                }
                let track_id = self.tracks[ta].id.clone();
                let prior = self.crossfade(clip_id_a, clip_id_b).cloned();
                let inv = match &prior {
                    Some(x) => Cmd::ClipCrossfadeSet {
                        clip_id_a: clip_id_a.clone(),
                        clip_id_b: clip_id_b.clone(),
                        length_ticks: x.length_ticks,
                        shape: Some(x.curve),
                    },
                    // V1-DECISION (documented deviation, proposal on record):
                    // lengthTicks 0 = no crossfade; the frozen schema's
                    // exclusiveMinimum forbids it but the self-inverse rule
                    // requires expressing "the pre-state was none".
                    None => Cmd::ClipCrossfadeSet {
                        clip_id_a: clip_id_a.clone(),
                        clip_id_b: clip_id_b.clone(),
                        length_ticks: 0,
                        shape: None,
                    },
                };
                let curve = shape.unwrap_or(FadeCurve::EqualPower);
                self.crossfades
                    .retain(|x| !(x.clip_id_a == *clip_id_a && x.clip_id_b == *clip_id_b));
                if *length_ticks > 0 {
                    self.crossfades.push(Crossfade {
                        clip_id_a: clip_id_a.clone(),
                        clip_id_b: clip_id_b.clone(),
                        length_ticks: *length_ticks,
                        curve,
                    });
                    self.crossfades.sort_by(|x, y| {
                        (&x.clip_id_a, &x.clip_id_b).cmp(&(&y.clip_id_a, &y.clip_id_b))
                    });
                }
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Crossfades, ChangeScope::Clips(track_id)],
                })
            }
            Cmd::ClipWarpSet {
                clip_id,
                mode,
                stretch_ratio,
            } => {
                let (ti, ci) = self.require_audio_clip(clip_id, "clip.warp.set")?;
                let track_id = self.tracks[ti].id.clone();
                if *mode == WarpMode::Ratio {
                    let r = stretch_ratio
                        .as_ref()
                        .ok_or_else(|| {
                            CommandError::InvalidParams("mode 'ratio' requires stretchRatio".into())
                        })?
                        .as_f64();
                    if !(r > 0.0) {
                        return Err(CommandError::OutOfRange(format!(
                            "stretchRatio must be > 0, got {r}"
                        )));
                    }
                }
                let clip = &mut self.tracks[ti].clips[ci];
                let prior = clip.warp.clone();
                clip.warp = Warp {
                    mode: *mode,
                    stretch_ratio: match mode {
                        WarpMode::Ratio => stretch_ratio.clone().unwrap_or_else(|| Num::int(1)),
                        WarpMode::Conform => prior.stretch_ratio.clone(),
                    },
                };
                let inv = Cmd::ClipWarpSet {
                    clip_id: clip_id.clone(),
                    mode: prior.mode,
                    stretch_ratio: match prior.mode {
                        WarpMode::Ratio => Some(prior.stretch_ratio.clone()),
                        WarpMode::Conform => None,
                    },
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::ClipPhaseAnchorSet {
                clip_id,
                anchor_ticks,
            } => {
                let (ti, ci) = self.require_clip_pos(clip_id)?;
                let track_id = self.tracks[ti].id.clone();
                let prior = self.tracks[ti].clips[ci].phase_anchor_ticks;
                self.tracks[ti].clips[ci].phase_anchor_ticks = *anchor_ticks;
                let inv = Cmd::ClipPhaseAnchorSet {
                    clip_id: clip_id.clone(),
                    anchor_ticks: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }
            Cmd::ClipRename { clip_id, name } => {
                let (ti, ci) = self.require_clip_pos(clip_id)?;
                let track_id = self.tracks[ti].id.clone();
                let prior = std::mem::replace(&mut self.tracks[ti].clips[ci].name, name.clone());
                let inv = Cmd::ClipRename {
                    clip_id: clip_id.clone(),
                    name: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Clips(track_id)],
                })
            }

            // ---- automation ----
            //
            // `target` is a ParamRef, not the v1 two-value enum. Apply-time
            // validation is BUILD-STATIC only (family recognized, key/band/
            // send/field known to this build) — `require_param_ref_on`'s doc
            // explains why live-state existence checks were removed (a
            // forward-legal `autopoint.remove`'s inverse must re-apply after
            // the referenced device/fx/node/edge is gone). Live resolution is
            // the render compile's job, which refuses an unreadable lane by
            // name with a remedy.
            Cmd::AutopointAdd {
                track_id,
                target,
                point_id,
                position_ticks,
                value,
            } => {
                let ti = self.require_track_index(track_id)?;
                self.require_param_ref_on(Some(ti), target)?;
                if self.tracks[ti]
                    .automation
                    .lane(target)
                    .iter()
                    .any(|p| p.id == *point_id)
                {
                    return Err(CommandError::DuplicateId(point_id.clone()));
                }
                self.tracks[ti]
                    .automation
                    .lane_mut(target)
                    .push(AutoPoint {
                        id: point_id.clone(),
                        position_ticks: *position_ticks,
                        value: value.clone(),
                        extra: Default::default(),
                    });
                self.tracks[ti].automation.sort_lane(target);
                let inv = Cmd::AutopointRemove {
                    track_id: track_id.clone(),
                    target: target.clone(),
                    point_id: point_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Automation(
                        track_id.clone(),
                        target.as_str().to_string(),
                    )],
                })
            }
            Cmd::AutopointMove {
                track_id,
                target,
                point_id,
                position_ticks,
                value,
            } => {
                let ti = self.require_track_index(track_id)?;
                self.require_param_ref_on(Some(ti), target)?;
                let lane = self.tracks[ti].automation.lane_mut(target);
                let point = lane
                    .iter_mut()
                    .find(|p| p.id == *point_id)
                    .ok_or_else(|| CommandError::UnknownAutoPoint(point_id.clone()))?;
                let prior_pos = std::mem::replace(&mut point.position_ticks, *position_ticks);
                let prior_val = std::mem::replace(&mut point.value, value.clone());
                self.tracks[ti].automation.sort_lane(target);
                let inv = Cmd::AutopointMove {
                    track_id: track_id.clone(),
                    target: target.clone(),
                    point_id: point_id.clone(),
                    position_ticks: prior_pos,
                    value: prior_val,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Automation(
                        track_id.clone(),
                        target.as_str().to_string(),
                    )],
                })
            }
            Cmd::AutopointRemove {
                track_id,
                target,
                point_id,
            } => {
                let ti = self.require_track_index(track_id)?;
                // DELIBERATELY NOT `require_param_ref`. Authoring automation
                // for a parameter that does not exist is refused; DELETING it
                // never is. Otherwise `device.remove` would strand its lane —
                // the points could neither be authored nor cleaned up, and the
                // undo of the `autopoint.add` that created them would fail.
                let lane = self.tracks[ti].automation.lane_mut(target);
                let pos = lane
                    .iter()
                    .position(|p| p.id == *point_id)
                    .ok_or_else(|| CommandError::UnknownAutoPoint(point_id.clone()))?;
                let p = lane.remove(pos);
                // Drop the lane entry entirely when its last point goes.
                //
                // PRE-EXISTING EXACTNESS GAP, found by the E1 fuzz: `lane_mut`
                // creates the map entry with `or_default()`, so add-then-remove
                // left `{path: []}` where there had been no key at all — the
                // inverse of `autopoint.add` did not restore the exact
                // pre-state for ANY v2 lane path. It went unnoticed because the
                // conductor only ever generated the two LEGACY targets, which
                // live in fields and leave no key behind. `autolane.show` is a
                // no-op, so an empty lane carries no meaning and dropping it
                // loses nothing.
                if !target.is_legacy() && lane.is_empty() {
                    self.tracks[ti].automation.lanes.remove(target);
                }
                let inv = Cmd::AutopointAdd {
                    track_id: track_id.clone(),
                    target: target.clone(),
                    point_id: p.id,
                    position_ticks: p.position_ticks,
                    value: p.value,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Automation(
                        track_id.clone(),
                        target.as_str().to_string(),
                    )],
                })
            }
            Cmd::AutolaneClear { track_id, target } => {
                let ti = self.require_track_index(track_id)?;
                // Same rule as autopoint.remove: clearing is always allowed.
                let removed: Vec<AutoPoint> = self.tracks[ti].automation.clear_lane(target);
                // Full undo restores every point; the hint is the catalog's
                // declared self shape (P0-C documents exactly this split).
                let inverse = removed
                    .iter()
                    .map(|p| Cmd::AutopointAdd {
                        track_id: track_id.clone(),
                        target: target.clone(),
                        point_id: p.id.clone(),
                        position_ticks: p.position_ticks,
                        value: p.value.clone(),
                    })
                    .collect();
                Ok(CmdEffect {
                    mutated: true,
                    inverse,
                    hint: Some(Cmd::AutolaneClear {
                        track_id: track_id.clone(),
                        target: target.clone(),
                    }),
                    scopes: vec![ChangeScope::Automation(
                        track_id.clone(),
                        target.as_str().to_string(),
                    )],
                })
            }

            // ---- mixer ----
            Cmd::MixGain { track_id, gain_db } => {
                check_gain_bounds("mix.gain", gain_db)?;
                let ti = self.require_track_index(track_id)?;
                let prior = std::mem::replace(&mut self.tracks[ti].gain, gain_db.clone());
                let inv = Cmd::MixGain {
                    track_id: track_id.clone(),
                    gain_db: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Mixer(track_id.clone())],
                })
            }
            Cmd::MixPan { track_id, pan } => {
                let ti = self.require_track_index(track_id)?;
                let prior = std::mem::replace(&mut self.tracks[ti].pan, pan.clone());
                let inv = Cmd::MixPan {
                    track_id: track_id.clone(),
                    pan: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Mixer(track_id.clone())],
                })
            }
            Cmd::MixEq {
                track_id,
                band,
                freq_hz,
                gain_db,
                q,
            } => {
                let ti = self.require_track_index(track_id)?;
                let bi = *band as usize;
                if bi >= 4 {
                    return Err(CommandError::OutOfRange(format!(
                        "eq band {bi} not in 0..=3"
                    )));
                }
                let prior = self.tracks[ti].eq[bi].clone();
                let slot = &mut self.tracks[ti].eq[bi];
                slot.freq_hz = freq_hz.clone();
                slot.gain_db = gain_db.clone();
                if let Some(qv) = q {
                    slot.q = qv.clone();
                }
                // Inverse mirrors the fields the command carried: q is echoed
                // back to its prior value only when the command set q. Fixture
                // entry 15's forward has no q, so its inverse omits q too, and
                // q never moves; a q-carrying command inverts to the prior q.
                let inv = Cmd::MixEq {
                    track_id: track_id.clone(),
                    band: *band,
                    freq_hz: prior.freq_hz.clone(),
                    gain_db: prior.gain_db.clone(),
                    q: q.as_ref().map(|_| prior.q.clone()),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Mixer(track_id.clone())],
                })
            }
            Cmd::MixSend {
                track_id,
                bus,
                amount,
            } => {
                let ti = self.require_track_index(track_id)?;
                let slot = match bus {
                    SendBus::A => &mut self.tracks[ti].sends.a,
                    SendBus::B => &mut self.tracks[ti].sends.b,
                };
                let prior = std::mem::replace(slot, amount.clone());
                let inv = Cmd::MixSend {
                    track_id: track_id.clone(),
                    bus: *bus,
                    amount: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Mixer(track_id.clone())],
                })
            }
            Cmd::MixMasterGain { gain_db } => {
                check_gain_bounds("mix.master.gain", gain_db)?;
                let prior = std::mem::replace(&mut self.master.gain_db, gain_db.clone());
                let inv = Cmd::MixMasterGain { gain_db: prior };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Master],
                })
            }
            Cmd::MixLimiterSet {
                enabled,
                ceiling_db,
                release_ms,
            } => {
                let prior = self.master.limiter.clone();
                self.master.limiter.enabled = *enabled;
                if let Some(c) = ceiling_db {
                    self.master.limiter.ceiling_db = c.clone();
                }
                if let Some(r) = release_ms {
                    self.master.limiter.release_ms = r.clone();
                }
                let inv = Cmd::MixLimiterSet {
                    enabled: prior.enabled,
                    ceiling_db: ceiling_db.as_ref().map(|_| prior.ceiling_db.clone()),
                    release_ms: release_ms.as_ref().map(|_| prior.release_ms.clone()),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Master],
                })
            }

            // ---- gen: journaled request records, no model mutation ----
            Cmd::GenSong { track_id, .. } => {
                self.require_track_index(track_id)?;
                Ok(CmdEffect::record_only(vec![]))
            }
            Cmd::GenRevise {
                clip_id,
                region_start_ticks,
                region_end_ticks,
                ..
            } => {
                self.require_clip_pos(clip_id)?;
                if region_start_ticks >= region_end_ticks {
                    return Err(CommandError::InvalidParams(
                        "regionStartTicks must be before regionEndTicks".into(),
                    ));
                }
                Ok(CmdEffect::record_only(vec![]))
            }
            Cmd::GenExtend { clip_id, .. }
            | Cmd::GenAutocomplete { clip_id, .. }
            | Cmd::GenSeparate { clip_id, .. } => {
                self.require_clip_pos(clip_id)?;
                Ok(CmdEffect::record_only(vec![]))
            }
            Cmd::GenCover {
                reference_clip_id, ..
            } => {
                self.require_clip_pos(reference_clip_id)?;
                Ok(CmdEffect::record_only(vec![]))
            }
            Cmd::GenLayer {
                target_track_id,
                context_clip_id,
                ..
            } => {
                self.require_track_index(target_track_id)?;
                if let Some(c) = context_clip_id {
                    self.require_clip_pos(c)?;
                }
                Ok(CmdEffect::record_only(vec![]))
            }
            Cmd::GenRetake { source_take_id, .. } => {
                self.take(source_take_id)
                    .ok_or_else(|| CommandError::UnknownTake(source_take_id.clone()))?;
                Ok(CmdEffect::record_only(vec![]))
            }
            Cmd::GenFinalize { draft_take_id, .. } => {
                self.take(draft_take_id)
                    .ok_or_else(|| CommandError::UnknownTake(draft_take_id.clone()))?;
                Ok(CmdEffect::record_only(vec![]))
            }
            Cmd::GenCancel { .. } => Ok(CmdEffect::record_only(vec![])),
            Cmd::GenLanded {
                request_id,
                source_command,
                take_id,
                asset_hashes,
                engine_identity,
                ..
            } => {
                if self.take(take_id).is_some() {
                    return Err(CommandError::DuplicateId(take_id.clone()));
                }
                self.takes.push(TakeRecord {
                    take_id: take_id.clone(),
                    request_id: request_id.clone(),
                    source_command: source_command.clone(),
                    asset_hashes: asset_hashes.clone(),
                    engine_identity: engine_identity.clone(),
                    status: TakeStatus::Candidate,
                    promoted_into: None,
                    prior_asset: None,
                });
                Ok(CmdEffect {
                    mutated: true,
                    inverse: Vec::new(),
                    hint: None,
                    scopes: vec![ChangeScope::Takes],
                })
            }

            // ---- takes ----
            Cmd::TakePromote {
                take_id,
                target_clip_id,
            } => {
                let (ti, ci) = self.require_clip_pos(target_clip_id)?;
                let track_id = self.tracks[ti].id.clone();
                let take = self
                    .take(take_id)
                    .ok_or_else(|| CommandError::UnknownTake(take_id.clone()))?;
                if take.status == TakeStatus::Promoted {
                    return Err(CommandError::TakeState(format!(
                        "take {take_id} is already promoted"
                    )));
                }
                // V1-DECISION: single-file takes splice their "mix" asset; a
                // per-stem take needs per-stem promotion, composed by the
                // host as a txn over stem clips (proposal on record).
                let new_asset = take
                    .asset_hashes
                    .get("mix")
                    .cloned()
                    .or_else(|| {
                        if take.asset_hashes.len() == 1 {
                            take.asset_hashes.values().next().cloned()
                        } else {
                            None
                        }
                    })
                    .ok_or_else(|| {
                        CommandError::TakeState(format!(
                            "take {take_id} is per-stem; promote stems via a txn"
                        ))
                    })?;
                let prior_asset = self.tracks[ti].clips[ci].source_id.clone();
                {
                    let clip = &mut self.tracks[ti].clips[ci];
                    clip.source_id = new_asset;
                }
                let take = self.take_mut(take_id).expect("take exists");
                take.status = TakeStatus::Promoted;
                take.promoted_into = Some(target_clip_id.clone());
                take.prior_asset = Some(prior_asset);
                let inv = Cmd::TakeDiscard {
                    take_id: take_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Takes, ChangeScope::Clips(track_id)],
                })
            }
            Cmd::TakeDiscard { take_id } => {
                let take = self
                    .take(take_id)
                    .ok_or_else(|| CommandError::UnknownTake(take_id.clone()))?
                    .clone();
                // V1-DECISION (proposal on record): v1 journals take.discard
                // only for PROMOTED takes (un-splice + return to candidate),
                // which makes the catalog's promote/discard inverse pair
                // exact. Discarding a never-promoted candidate has no
                // journal-expressible undo in catalog v1 (no take.restore),
                // so it is a typed error instead of invented behavior.
                if take.status != TakeStatus::Promoted {
                    return Err(CommandError::TakeState(format!(
                        "take {take_id} is not promoted; v1 journals discard only as \
                         un-promote (candidate cleanup is a host/io concern, see proposal P5)"
                    )));
                }
                let clip_id = take.promoted_into.clone().ok_or_else(|| {
                    CommandError::TakeState(format!("take {take_id} has no promoted clip"))
                })?;
                let (ti, ci) = self.require_clip_pos(&clip_id)?;
                let track_id = self.tracks[ti].id.clone();
                let prior_asset = take.prior_asset.clone().ok_or_else(|| {
                    CommandError::TakeState(format!("take {take_id} has no prior asset"))
                })?;
                {
                    let clip = &mut self.tracks[ti].clips[ci];
                    clip.source_id = prior_asset;
                }
                let take = self.take_mut(take_id).expect("take exists");
                take.status = TakeStatus::Candidate;
                take.promoted_into = None;
                take.prior_asset = None;
                let inv = Cmd::TakePromote {
                    take_id: take_id.clone(),
                    target_clip_id: clip_id,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Takes, ChangeScope::Clips(track_id)],
                })
            }
            Cmd::TakePurge { take_id } => {
                let take = self
                    .take(take_id)
                    .ok_or_else(|| CommandError::UnknownTake(take_id.clone()))?
                    .clone();
                if take.status != TakeStatus::Candidate {
                    return Err(CommandError::TakeState(format!(
                        "take {take_id} is not an un-promoted candidate"
                    )));
                }
                let take = self.take_mut(take_id).expect("take exists");
                take.status = TakeStatus::Offline;
                let inv = Cmd::TakeRestore {
                    take_id: take_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Takes],
                })
            }

            // ---- io / publish: journaled request records ----
            Cmd::ImportAudio {
                target_track_id, ..
            } => {
                self.require_track_index(target_track_id)?;
                // V1-DECISION (proposal on record): the journaled
                // import.audio entry is an io record; the executing host
                // journals the resulting clip.place (with real assetHash and
                // length) in the same txn, so replay is deterministic without
                // re-reading the imported file. The envelope inverse hint
                // (clip.remove of the placed clip) is supplied by the host
                // via Session::submit_with_hint.
                Ok(CmdEffect::record_only(vec![]))
            }
            Cmd::ImportStems {
                target_track_id, ..
            } => {
                self.require_track_index(target_track_id)?;
                // The host expands the directory into ordinary track.add and
                // clip.place commands in the same transaction. Keeping this
                // request record in the journal preserves the source
                // provenance while replay remains deterministic.
                Ok(CmdEffect::record_only(vec![]))
            }
            Cmd::ExportMaster { .. }
            | Cmd::ExportStems { .. }
            | Cmd::ExportManifest { .. }
            | Cmd::PublishTrack { .. } => Ok(CmdEffect::record_only(vec![])),
            Cmd::ExportRegion {
                start_ticks,
                end_ticks,
                ..
            } => {
                if start_ticks >= end_ticks {
                    return Err(CommandError::InvalidParams(
                        "export region startTicks must be before endTicks".into(),
                    ));
                }
                Ok(CmdEffect::record_only(vec![]))
            }

            // ---- txn markers: session-level semantics, journaled records ----
            Cmd::TxnBegin { .. } | Cmd::TxnCommit { .. } => Ok(CmdEffect::record_only(vec![])),

            // ---- session ----
            Cmd::StudioImportStemSession { stem_session_id } => {
                let track_id = format!("trk_stems_{stem_session_id}");
                if self.track(&track_id).is_some() {
                    return Err(CommandError::DuplicateId(track_id));
                }
                let name = format!("Stem Session {stem_session_id}");
                self.tracks.push(Track::new(track_id.clone(), name));
                let inv = Cmd::TrackRemove {
                    track_id: track_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Tracks],
                })
            }
            Cmd::TakeRestore { take_id } => {
                let take = self
                    .take(take_id)
                    .ok_or_else(|| CommandError::UnknownTake(take_id.clone()))?
                    .clone();
                if take.status != TakeStatus::Offline {
                    return Err(CommandError::TakeState(format!(
                        "take {take_id} is not offline"
                    )));
                }
                let take = self.take_mut(take_id).expect("take exists");
                take.status = TakeStatus::Candidate;
                let inv = Cmd::TakePurge {
                    take_id: take_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Takes],
                })
            }

            // ---- project phase anchor (deferred proposal L8, accepted) ----
            Cmd::ProjectSetPhaseAnchor { anchor_ticks } => {
                let prior = std::mem::replace(&mut self.phase_anchor_ticks, *anchor_ticks);
                let inv = Cmd::ProjectSetPhaseAnchor {
                    anchor_ticks: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Project],
                })
            }

            // ---- routing DAG (design §5) ----
            //
            // MODEL ONLY. Validation, cycle rejection and the topological sort
            // live here; the render-side EVALUATION is E5's. `compile.rs`
            // already bakes the sorted order into the snapshot, so E5 inherits
            // an ordering with no contract work left.
            Cmd::RouteNodeAdd {
                node_id,
                kind,
                name,
            } => {
                if self.routing.node(node_id).is_some() {
                    return Err(CommandError::DuplicateId(node_id.clone()));
                }
                if node_id == crate::routing::MASTER {
                    return Err(CommandError::Routing(
                        "'master' is a reserved implicit node".into(),
                    ));
                }
                self.routing.nodes.push(crate::routing::RouteNode {
                    id: node_id.clone(),
                    kind: *kind,
                    name: name.clone(),
                    gain_db: crate::routing::gain_db_default(),
                    fx: Vec::new(),
                    extra: Default::default(),
                });
                let inv = Cmd::RouteNodeRemove {
                    node_id: node_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Routing],
                })
            }
            Cmd::RouteNodeRemove { node_id } => {
                let idx = self.routing.node_index(node_id).ok_or_else(|| {
                    CommandError::Routing(format!("no such routing node {node_id}"))
                })?;
                // Validate first: `route.node.add` and `route.connect` both
                // reconstruct with an empty `extra`, so anything unknown on the
                // node, its inserts, or its incident edges would vanish silently.
                Self::refuse_unrestorable_extra(
                    "route.node.remove",
                    "node",
                    node_id,
                    &self.routing.nodes[idx].extra,
                )?;
                for f in &self.routing.nodes[idx].fx {
                    Self::refuse_unrestorable_extra("route.node.remove", "fx", &f.id, &f.extra)?;
                }
                {
                    let me = crate::routing::NodeRef::Node(node_id.clone());
                    for e in &self.routing.edges {
                        if e.from == me || e.to == me {
                            Self::refuse_unrestorable_extra(
                                "route.node.remove",
                                "routing edge",
                                &e.id,
                                &e.extra,
                            )?;
                        }
                    }
                }
                let node = self.routing.nodes.remove(idx);
                // Removing a node removes every edge incident to it. The undo
                // therefore has to restore the node AND every removed edge —
                // a multi-command inverse, declared as inverseShape "multi" in
                // the catalog and enforced by tests/inverse_shape.rs.
                let me = crate::routing::NodeRef::Node(node_id.clone());
                let (removed, kept): (Vec<_>, Vec<_>) = std::mem::take(&mut self.routing.edges)
                    .into_iter()
                    .partition(|e| e.from == me || e.to == me);
                self.routing.edges = kept;
                let mut inverse = vec![Cmd::RouteNodeAdd {
                    node_id: node.id.clone(),
                    kind: node.kind,
                    name: node.name.clone(),
                }];
                // The node FADER goes with it too, and `route.node.add` cannot
                // carry it (E0 §9.2: no new params on a shipped command), so a
                // non-default gain is restored by its own `route.node.set`.
                // Without this, removing a trimmed bus and undoing would
                // silently reopen it at unity — `track.remove` dropping
                // `Track::devices` all over again.
                if !crate::routing::gain_db_is_default(&node.gain_db) {
                    inverse.push(Cmd::RouteNodeSet {
                        node_id: node.id.clone(),
                        gain_db: node.gain_db.clone(),
                    });
                }
                // E5: the node's own INSERT chain goes with it, and
                // `route.node.add` cannot carry it, so the inverse rebuilds it.
                // Without this, removing a bus with a compressor on it and
                // undoing would silently return a bare summing point.
                inverse.extend(Self::fx_restore_sequence(&me, &node.fx));
                inverse.extend(removed.iter().map(|e| Cmd::RouteConnect {
                    edge_id: e.id.clone(),
                    from: e.from.clone(),
                    to: e.to.clone(),
                    level: e.level.clone(),
                    tap: e.tap,
                }));
                // ... and links KEYED OFF this node dangle exactly as its edges
                // would (§18.1).
                inverse.extend(self.clear_links_to(&me));
                Ok(CmdEffect {
                    mutated: true,
                    inverse,
                    hint: Some(Cmd::RouteNodeAdd {
                        node_id: node.id,
                        kind: node.kind,
                        name: node.name,
                    }),
                    scopes: vec![ChangeScope::Routing],
                })
            }
            Cmd::RouteConnect {
                edge_id,
                from,
                to,
                level,
                tap,
            } => {
                let edge = crate::routing::RouteEdge {
                    id: edge_id.clone(),
                    from: from.clone(),
                    to: to.clone(),
                    level: level.clone(),
                    tap: *tap,
                    extra: Default::default(),
                };
                let ids: std::collections::BTreeSet<&str> =
                    self.tracks.iter().map(|t| t.id.as_str()).collect();
                // CYCLE REJECTION AT COMMAND TIME. The audio thread must never
                // discover a cycle, so the graph is never allowed to contain one.
                //
                // E5 §18.1: sidechain LINKS constrain the order exactly as edges
                // do, so an audio edge can close a cycle *through* a link.
                // Without the links here, `route.connect` would accept such an
                // edge, `schedule` would fail at compile, and `push_live_session`
                // swallows compile errors — live audio would silently freeze.
                let links = self.sidechain_links();
                self.routing
                    .validate_new_edge_with_links(&edge, &ids, &links)?;
                self.routing.edges.push(edge);
                let inv = Cmd::RouteDisconnect {
                    edge_id: edge_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Routing],
                })
            }
            Cmd::RouteDisconnect { edge_id } => {
                let idx = self.routing.edge_index(edge_id).ok_or_else(|| {
                    CommandError::Routing(format!("no such routing edge {edge_id}"))
                })?;
                Self::refuse_unrestorable_extra(
                    "route.disconnect",
                    "routing edge",
                    edge_id,
                    &self.routing.edges[idx].extra,
                )?;
                let e = self.routing.edges.remove(idx);
                let inv = Cmd::RouteConnect {
                    edge_id: e.id,
                    from: e.from,
                    to: e.to,
                    level: e.level,
                    tap: e.tap,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Routing],
                })
            }
            Cmd::RouteEdgeSet {
                edge_id,
                level,
                tap,
            } => {
                let idx = self.routing.edge_index(edge_id).ok_or_else(|| {
                    CommandError::Routing(format!("no such routing edge {edge_id}"))
                })?;
                let e = &mut self.routing.edges[idx];
                let prior_level = std::mem::replace(&mut e.level, level.clone());
                let prior_tap = std::mem::replace(&mut e.tap, *tap);
                let inv = Cmd::RouteEdgeSet {
                    edge_id: edge_id.clone(),
                    level: prior_level,
                    tap: prior_tap,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Routing],
                })
            }
            // The node FADER (§4.3). Same bounds as `mix.gain` — one dB window
            // for every fader a user can grab — and the same truthful
            // self-inverse carrying the PRIOR value (`Num`, shape-exact, so
            // the hashed hint replays byte-identically).
            Cmd::RouteNodeSet { node_id, gain_db } => {
                check_gain_bounds("route.node.set", gain_db)?;
                let idx = self.routing.node_index(node_id).ok_or_else(|| {
                    CommandError::Routing(format!("no such routing node {node_id}"))
                })?;
                let prior =
                    std::mem::replace(&mut self.routing.nodes[idx].gain_db, gain_db.clone());
                let inv = Cmd::RouteNodeSet {
                    node_id: node_id.clone(),
                    gain_db: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![ChangeScope::Routing],
                })
            }

            // ---- E5 §16: the effect registry ----
            //
            // SEVEN NEW NAMES (E0 §9.2). `Device`/`DeviceKind`/`device.add` are
            // untouched, and there is ZERO enum widening: an effect lives in a
            // separate `fx` collection because `build_instrument` hard-errors on
            // a track with more than one device (§16.1).
            Cmd::FxAdd {
                target,
                fx_id,
                kind,
            } => {
                let scope = Project::fx_scope(target);
                let chain = self.fx_chain_mut(target)?;
                if crate::model::fx_index(chain, fx_id).is_some() {
                    return Err(CommandError::DuplicateId(fx_id.clone()));
                }
                chain.push(crate::model::Fx::new(fx_id.clone(), *kind));
                let inv = Cmd::FxRemove {
                    target: target.clone(),
                    fx_id: fx_id.clone(),
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![scope],
                })
            }

            // The inverse is a SEQUENCE (`inverseShape: "multi"`), never
            // `inverseRule: self`: it restores the fx, its CHAIN INDEX, every
            // stored parameter, and its sidechain link.
            //
            // `device.remove`'s non-empty-params guard is deliberately NOT
            // copied. That guard exists because E1/E2 shipped no way to restore
            // a device's params; `fx.param.set` IS that way, so `fx.remove`
            // restores them instead of refusing. Copying the guard would make
            // every configured effect unremovable (§16.4).
            Cmd::FxRemove { target, fx_id } => {
                let scope = Project::fx_scope(target);
                let idx = self.require_fx_index(target, fx_id)?;
                let chain = self.fx_chain_mut(target)?;
                // `extra` is the one thing no catalog command can restore.
                // Refuse rather than silently drop it, exactly as
                // `device.zone.remove` does.
                if !chain[idx].extra.is_empty() {
                    return Err(CommandError::InvalidParams(format!(
                        "fx.remove: fx {fx_id} carries {} unknown field(s) that no catalog \
                         command in this build can restore, so removing it would not be undoable",
                        chain[idx].extra.len()
                    )));
                }
                let last = chain.len() - 1;
                let fx = chain.remove(idx);
                let hint = Cmd::FxAdd {
                    target: target.clone(),
                    fx_id: fx.id.clone(),
                    kind: fx.kind,
                };
                let mut inverse = vec![hint.clone()];
                // `fx.add` appends, so a non-terminal fx needs its index back.
                if idx != last {
                    inverse.push(Cmd::FxMove {
                        target: target.clone(),
                        fx_id: fx.id.clone(),
                        index: idx as u32,
                    });
                }
                inverse.extend(fx.params.iter().map(|(k, v)| Cmd::FxParamSet {
                    target: target.clone(),
                    fx_id: fx.id.clone(),
                    key: k.clone(),
                    value: v.clone(),
                }));
                if let Some(src) = &fx.sidechain {
                    inverse.push(Cmd::FxSidechainSet {
                        target: target.clone(),
                        fx_id: fx.id.clone(),
                        source: src.clone(),
                    });
                }
                Ok(CmdEffect {
                    mutated: true,
                    inverse,
                    hint: Some(hint),
                    scopes: vec![scope],
                })
            }

            Cmd::FxMove {
                target,
                fx_id,
                index,
            } => {
                let scope = Project::fx_scope(target);
                let cur = self.require_fx_index(target, fx_id)?;
                let chain = self.fx_chain_mut(target)?;
                let to = *index as usize;
                if to >= chain.len() {
                    return Err(CommandError::OutOfRange(format!(
                        "fx.move: index {to} is past the end of a {}-effect chain",
                        chain.len()
                    )));
                }
                let fx = chain.remove(cur);
                chain.insert(to, fx);
                // Self-inverse carrying the PRIOR index. remove+insert is a
                // rotation, and the reverse rotation restores exactly.
                let inv = Cmd::FxMove {
                    target: target.clone(),
                    fx_id: fx_id.clone(),
                    index: cur as u32,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![scope],
                })
            }

            // Params stay SPARSE: an absent key means "the DSP default", the
            // same rule `build_instrument` already implements. So the inverse of
            // setting a key that was ABSENT is `fx.param.clear` — undoing to
            // absent, NOT to a written default. That is what makes this setter
            // safe where E1/E2's `device.param.set` would have been a booby
            // trap, and it is why `inverseShape` is "multi" (§16.4): the
            // declared inverse name cannot cover both directions.
            Cmd::FxParamSet {
                target,
                fx_id,
                key,
                value,
            } => {
                if !crate::model::FX_PARAM_KEYS.contains(&key.as_str()) {
                    return Err(CommandError::UnknownParameter(format!(
                        "{key}: not an effect parameter this build knows"
                    )));
                }
                let scope = Project::fx_scope(target);
                let idx = self.require_fx_index(target, fx_id)?;
                let chain = self.fx_chain_mut(target)?;
                let prior = chain[idx].params.insert(key.clone(), value.clone());
                let inv = match prior {
                    Some(prev) => Cmd::FxParamSet {
                        target: target.clone(),
                        fx_id: fx_id.clone(),
                        key: key.clone(),
                        value: prev,
                    },
                    None => Cmd::FxParamClear {
                        target: target.clone(),
                        fx_id: fx_id.clone(),
                        key: key.clone(),
                    },
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![scope],
                })
            }

            Cmd::FxParamClear {
                target,
                fx_id,
                key,
            } => {
                let scope = Project::fx_scope(target);
                let idx = self.require_fx_index(target, fx_id)?;
                let chain = self.fx_chain_mut(target)?;
                // Clearing an absent key is a typed error, not a silent no-op:
                // a no-op would have no exact inverse to journal.
                let prior = chain[idx].params.remove(key).ok_or_else(|| {
                    CommandError::UnknownParameter(format!(
                        "{key}: fx {fx_id} stores no value for this key (it is already at \
                         the DSP default)"
                    ))
                })?;
                let inv = Cmd::FxParamSet {
                    target: target.clone(),
                    fx_id: fx_id.clone(),
                    key: key.clone(),
                    value: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![scope],
                })
            }

            // A sidechain is an ORDERING CONSTRAINT, not an audio edge (§18.1).
            // §5.2's legality table is this command's acceptance criteria, and
            // the cycle check runs BEFORE the mutation, exactly as
            // `validate_new_edge` does for `route.connect`.
            Cmd::FxSidechainSet {
                target,
                fx_id,
                source,
            } => {
                let scope = Project::fx_scope(target);
                let idx = self.require_fx_index(target, fx_id)?;
                let prior = self.fx_chain_mut(target)?[idx].sidechain.clone();
                let ids: BTreeSet<&str> = self.tracks.iter().map(|t| t.id.as_str()).collect();
                // Every OTHER link: the one being replaced must not be validated
                // against itself, or re-pointing a link would be rejected.
                let mut existing = self.sidechain_links();
                if let Some(prev) = &prior {
                    if let Some(pos) = existing
                        .iter()
                        .position(|l| l.0 == *prev && l.1 == *target)
                    {
                        existing.remove(pos);
                    }
                }
                self.routing
                    .validate_new_link(source, target, &existing, &ids)?;
                self.fx_chain_mut(target)?[idx].sidechain = Some(source.clone());
                let inv = match prior {
                    Some(prev) => Cmd::FxSidechainSet {
                        target: target.clone(),
                        fx_id: fx_id.clone(),
                        source: prev,
                    },
                    None => Cmd::FxSidechainClear {
                        target: target.clone(),
                        fx_id: fx_id.clone(),
                    },
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![scope],
                })
            }

            Cmd::FxSidechainClear { target, fx_id } => {
                let scope = Project::fx_scope(target);
                let idx = self.require_fx_index(target, fx_id)?;
                let chain = self.fx_chain_mut(target)?;
                let prior = chain[idx].sidechain.take().ok_or_else(|| {
                    CommandError::Routing(format!(
                        "fx {fx_id} has no sidechain link to clear (it already uses the \
                         internal detector)"
                    ))
                })?;
                let inv = Cmd::FxSidechainSet {
                    target: target.clone(),
                    fx_id: fx_id.clone(),
                    source: prior,
                };
                Ok(CmdEffect {
                    mutated: true,
                    inverse: vec![inv.clone()],
                    hint: Some(inv),
                    scopes: vec![scope],
                })
            }
        }
    }
}

fn checked_add_signed(base: u64, delta: i64) -> Option<u64> {
    if delta >= 0 {
        base.checked_add(delta as u64)
    } else {
        base.checked_sub(delta.unsigned_abs())
    }
}

fn neg_err(what: &str) -> CommandError {
    CommandError::OutOfRange(format!("trim pushes clip {what} before tick 0"))
}
