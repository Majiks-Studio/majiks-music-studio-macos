//! The LEGACY command bus seed (P0-B subset, frame-canonical). Kept as a
//! compatibility shim for render's current host and tests; new work goes
//! through the catalog bus (`crate::cmd` + `crate::session`), which is
//! tick-canonical per the P0-C contract freeze. This shim back-derives the
//! tick fields by rounding after every mutation so the model never goes
//! internally inconsistent. See INTERFACE.md section 1.
//!
//! Every mutation of a project is a serializable command. Applying a command
//! either fully succeeds and returns its inverse command list, or returns a
//! typed error with the project untouched (validate first, mutate second).
//!
//! Inverses: most commands invert with a single command. `clip.split`
//! inverts with a short sequence (remove right, trim left back, restore the
//! left fade-out); the full catalog will either add `clip.join` or wrap this
//! in `txn.begin/commit`. That question is flagged for P0-C in the evidence
//! doc rather than silently decided here.
//!
//! Transport commands are commands too (same bus, same serialization) but are
//! non-undoable and touch no model state; the engine host routes them to the
//! render side.

use serde::{Deserialize, Serialize};

use crate::error::CommandError;
use crate::model::{Clip, FadeCurve, FadeShape, Project, Warp};
use crate::num::Num;
use crate::tempo::TempoMap;

pub const MIN_GAIN_DB: f32 = -96.0;
pub const MAX_GAIN_DB: f32 = 24.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrimEdge {
    Start,
    End,
}

/// The P0-B command subset. Serde names are the locked catalog names.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "name", content = "params")]
pub enum Command {
    /// Place a clip. Position is `start_tick` (musical placement, converted
    /// through the tempo map exactly once) or `start_frame` (sample-exact,
    /// used by inverses); exactly one must be present.
    #[serde(rename = "clip.place")]
    ClipPlace {
        track_id: String,
        clip_id: String,
        source_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        start_tick: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        start_frame: Option<u64>,
        offset_frames: u64,
        len_frames: u64,
        #[serde(default)]
        gain_db: f32,
        #[serde(default)]
        fade_in_frames: u64,
        #[serde(default)]
        fade_out_frames: u64,
        #[serde(default)]
        fade_shape: FadeShape,
    },
    #[serde(rename = "clip.remove")]
    ClipRemove { clip_id: String },
    /// Move a clip, optionally to another track. Exactly one of
    /// `to_start_tick` / `to_start_frame`.
    #[serde(rename = "clip.move")]
    ClipMove {
        clip_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        to_track_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        to_start_tick: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        to_start_frame: Option<u64>,
    },
    /// Trim one edge to an absolute timeline frame. Start trims re-anchor
    /// the source offset so content under the kept region never shifts.
    #[serde(rename = "clip.trim")]
    ClipTrim {
        clip_id: String,
        edge: TrimEdge,
        to_frame: u64,
    },
    /// Split at an absolute timeline frame strictly inside the clip. The
    /// right half becomes `right_clip_id` (caller-supplied, must be new).
    #[serde(rename = "clip.split")]
    ClipSplit {
        clip_id: String,
        at_frame: u64,
        right_clip_id: String,
    },
    #[serde(rename = "clip.setGain")]
    ClipSetGain { clip_id: String, gain_db: f32 },
    /// Set fades. Only the provided fields change; the inverse restores
    /// exactly those fields.
    #[serde(rename = "clip.fade.set")]
    ClipFadeSet {
        clip_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        fade_in_frames: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        fade_out_frames: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        fade_shape: Option<FadeShape>,
    },
    #[serde(rename = "track.add")]
    TrackAdd {
        track_id: String,
        name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        index: Option<usize>,
    },
    /// P0-B scope: removing a track requires it to be empty (typed error
    /// otherwise). Full catalog semantics are P0-C's call.
    #[serde(rename = "track.remove")]
    TrackRemove { track_id: String },
    #[serde(rename = "track.mute")]
    TrackMute { track_id: String, mute: bool },

    // Transport: commands, serialized like everything else, but unjournaled
    // and non-undoable (catalog rule). They do not mutate the model.
    #[serde(rename = "transport.play")]
    TransportPlay {},
    #[serde(rename = "transport.stop")]
    TransportStop {},
    /// Seek to a musical tick or an exact frame; exactly one.
    #[serde(rename = "transport.seek")]
    TransportSeek {
        #[serde(skip_serializing_if = "Option::is_none")]
        to_tick: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        to_frame: Option<u64>,
    },
    #[serde(rename = "transport.loop.set")]
    TransportLoopSet { start_tick: u64, end_tick: u64 },
    #[serde(rename = "transport.loop.clear")]
    TransportLoopClear {},
}

/// A successfully applied command plus the commands that undo it (applied in
/// order). Empty for non-undoable commands.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Applied {
    pub command: Command,
    pub inverse: Vec<Command>,
}

impl Command {
    /// Catalog name (mirrors the serde tag; useful for envelopes and logs).
    pub fn name(&self) -> &'static str {
        match self {
            Command::ClipPlace { .. } => "clip.place",
            Command::ClipRemove { .. } => "clip.remove",
            Command::ClipMove { .. } => "clip.move",
            Command::ClipTrim { .. } => "clip.trim",
            Command::ClipSplit { .. } => "clip.split",
            Command::ClipSetGain { .. } => "clip.setGain",
            Command::ClipFadeSet { .. } => "clip.fade.set",
            Command::TrackAdd { .. } => "track.add",
            Command::TrackRemove { .. } => "track.remove",
            Command::TrackMute { .. } => "track.mute",
            Command::TransportPlay {} => "transport.play",
            Command::TransportStop {} => "transport.stop",
            Command::TransportSeek { .. } => "transport.seek",
            Command::TransportLoopSet { .. } => "transport.loop.set",
            Command::TransportLoopClear {} => "transport.loop.clear",
        }
    }

    pub fn is_transport(&self) -> bool {
        matches!(
            self,
            Command::TransportPlay {}
                | Command::TransportStop {}
                | Command::TransportSeek { .. }
                | Command::TransportLoopSet { .. }
                | Command::TransportLoopClear {}
        )
    }

    pub fn is_undoable(&self) -> bool {
        !self.is_transport()
    }
}

/// Wire-shaped gain for the legacy f32 path (float-shaped Num; the catalog
/// bus preserves the exact wire number instead).
fn legacy_gain_num(gain_db: f32) -> Num {
    serde_json::Number::from_f64(f64::from(gain_db))
        .map(Num::from)
        .unwrap_or_else(|| Num::int(0))
}

fn validate_gain(gain_db: f32) -> Result<(), CommandError> {
    if !gain_db.is_finite() || !(MIN_GAIN_DB..=MAX_GAIN_DB).contains(&gain_db) {
        return Err(CommandError::InvalidParams(format!(
            "gain_db must be finite in [{MIN_GAIN_DB}, {MAX_GAIN_DB}], got {gain_db}"
        )));
    }
    Ok(())
}

/// Back-derive the tick-canonical fields of a clip from its frame fields
/// (legacy shim path only: ticks round to the nearest tick; the catalog bus
/// is tick-first and never calls this).
fn sync_ticks_from_frames(clip: &mut Clip, tempo: &TempoMap, rate: u32) {
    clip.start_ticks = tempo.frame_to_tick(clip.start_frame, rate);
    let end_ticks = tempo.frame_to_tick(clip.end_frame(), rate);
    clip.length_ticks = end_ticks.saturating_sub(clip.start_ticks).max(1);
    clip.source_offset_ticks = tempo.frame_to_tick(clip.offset_frames, rate);
    clip.fade_in.length_ticks = tempo.frame_to_tick(clip.fade_in_frames, rate);
    clip.fade_out.length_ticks = tempo.frame_to_tick(clip.fade_out_frames, rate);
    let curve = match clip.fade_shape {
        FadeShape::Linear => FadeCurve::Linear,
        FadeShape::EqualPower => FadeCurve::EqualPower,
    };
    clip.fade_in.curve = curve;
    clip.fade_out.curve = curve;
}

/// Resolve a tick-or-frame position pair (exactly one side present).
fn resolve_position(
    what: &str,
    tick: Option<u64>,
    frame: Option<u64>,
    project: &Project,
) -> Result<u64, CommandError> {
    match (tick, frame) {
        (Some(t), None) => Ok(project.tempo.tick_to_frame(t, project.sample_rate)),
        (None, Some(f)) => Ok(f),
        _ => Err(CommandError::InvalidParams(format!(
            "{what}: exactly one of the tick/frame position fields is required"
        ))),
    }
}

impl Project {
    /// Apply a command. Full success returns the inverse command list;
    /// any failure returns a typed error and leaves the project untouched.
    pub fn apply(&mut self, command: &Command) -> Result<Applied, CommandError> {
        let inverse = match command {
            Command::ClipPlace {
                track_id,
                clip_id,
                source_id,
                start_tick,
                start_frame,
                offset_frames,
                len_frames,
                gain_db,
                fade_in_frames,
                fade_out_frames,
                fade_shape,
            } => {
                let start = resolve_position("clip.place", *start_tick, *start_frame, self)?;
                if self.clip_id_exists(clip_id) {
                    return Err(CommandError::DuplicateId(clip_id.clone()));
                }
                let source = self
                    .source(source_id)
                    .ok_or_else(|| CommandError::UnknownSource(source_id.clone()))?;
                if *len_frames == 0 {
                    return Err(CommandError::InvalidParams(
                        "len_frames must be > 0".to_string(),
                    ));
                }
                let end_in_source = offset_frames
                    .checked_add(*len_frames)
                    .ok_or_else(|| CommandError::OutOfRange("clip extent overflows".into()))?;
                if end_in_source > source.len_frames {
                    return Err(CommandError::OutOfRange(format!(
                        "clip reads past source end ({} > {})",
                        end_in_source, source.len_frames
                    )));
                }
                validate_gain(*gain_db)?;
                let tempo = self.tempo.clone();
                let rate = self.sample_rate;
                let track = self
                    .track_mut(track_id)
                    .ok_or_else(|| CommandError::UnknownTrack(track_id.clone()))?;
                let mut clip = Clip {
                    id: clip_id.clone(),
                    source_id: source_id.clone(),
                    start_frame: start,
                    offset_frames: *offset_frames,
                    len_frames: *len_frames,
                    gain_db: *gain_db,
                    fade_in_frames: *fade_in_frames,
                    fade_out_frames: *fade_out_frames,
                    fade_shape: *fade_shape,
                    start_ticks: 0,
                    length_ticks: 0,
                    source_offset_ticks: 0,
                    name: clip_id.clone(),
                    muted: false,
                    gain: legacy_gain_num(*gain_db),
                    fade_in: Default::default(),
                    fade_out: Default::default(),
                    warp: Warp::default(),
                    phase_anchor_ticks: 0,
                    offline: false,
                    // The legacy P0-B frame-canonical shim only ever places
                    // audio clips; note clips arrive through `clip.placeMidi`.
                    kind: crate::model::ClipKind::Audio,
                    notes: Vec::new(),
                    extra: serde_json::Map::new(),
                };
                sync_ticks_from_frames(&mut clip, &tempo, rate);
                track.clips.push(clip);
                track.sort_clips();
                vec![Command::ClipRemove {
                    clip_id: clip_id.clone(),
                }]
            }

            Command::ClipRemove { clip_id } => {
                let (ti, ci) = self
                    .find_clip(clip_id)
                    .ok_or_else(|| CommandError::UnknownClip(clip_id.clone()))?;
                let track_id = self.tracks[ti].id.clone();
                let clip = self.tracks[ti].clips.remove(ci);
                vec![Command::ClipPlace {
                    track_id,
                    clip_id: clip.id,
                    source_id: clip.source_id,
                    start_tick: None,
                    start_frame: Some(clip.start_frame),
                    offset_frames: clip.offset_frames,
                    len_frames: clip.len_frames,
                    gain_db: clip.gain_db,
                    fade_in_frames: clip.fade_in_frames,
                    fade_out_frames: clip.fade_out_frames,
                    fade_shape: clip.fade_shape,
                }]
            }

            Command::ClipMove {
                clip_id,
                to_track_id,
                to_start_tick,
                to_start_frame,
            } => {
                let new_start =
                    resolve_position("clip.move", *to_start_tick, *to_start_frame, self)?;
                let (ti, ci) = self
                    .find_clip(clip_id)
                    .ok_or_else(|| CommandError::UnknownClip(clip_id.clone()))?;
                let old_track_id = self.tracks[ti].id.clone();
                let dest_index = match to_track_id {
                    Some(id) => self
                        .track_index(id)
                        .ok_or_else(|| CommandError::UnknownTrack(id.clone()))?,
                    None => ti,
                };
                let old_start = self.tracks[ti].clips[ci].start_frame;
                let tempo = self.tempo.clone();
                let rate = self.sample_rate;
                let mut clip = self.tracks[ti].clips.remove(ci);
                clip.start_frame = new_start;
                sync_ticks_from_frames(&mut clip, &tempo, rate);
                self.tracks[dest_index].clips.push(clip);
                self.tracks[dest_index].sort_clips();
                vec![Command::ClipMove {
                    clip_id: clip_id.clone(),
                    to_track_id: Some(old_track_id),
                    to_start_tick: None,
                    to_start_frame: Some(old_start),
                }]
            }

            Command::ClipTrim {
                clip_id,
                edge,
                to_frame,
            } => {
                let (ti, ci) = self
                    .find_clip(clip_id)
                    .ok_or_else(|| CommandError::UnknownClip(clip_id.clone()))?;
                let clip = &self.tracks[ti].clips[ci];
                let source_len = self
                    .source(&clip.source_id)
                    .ok_or_else(|| CommandError::UnknownSource(clip.source_id.clone()))?
                    .len_frames;
                let old_start = clip.start_frame;
                let old_end = clip.end_frame();
                match edge {
                    TrimEdge::Start => {
                        if *to_frame >= old_end {
                            return Err(CommandError::OutOfRange(
                                "start trim must stay before clip end".to_string(),
                            ));
                        }
                        let delta = i128::from(*to_frame) - i128::from(old_start);
                        let new_offset = i128::from(clip.offset_frames) + delta;
                        if new_offset < 0 {
                            return Err(CommandError::OutOfRange(
                                "start trim extends before source content".to_string(),
                            ));
                        }
                        let new_len = i128::from(old_end) - i128::from(*to_frame);
                        let tempo = self.tempo.clone();
                        let rate = self.sample_rate;
                        let clip = &mut self.tracks[ti].clips[ci];
                        clip.start_frame = *to_frame;
                        clip.offset_frames = new_offset as u64;
                        clip.len_frames = new_len as u64;
                        sync_ticks_from_frames(clip, &tempo, rate);
                        self.tracks[ti].sort_clips();
                        vec![Command::ClipTrim {
                            clip_id: clip_id.clone(),
                            edge: TrimEdge::Start,
                            to_frame: old_start,
                        }]
                    }
                    TrimEdge::End => {
                        if *to_frame <= old_start {
                            return Err(CommandError::OutOfRange(
                                "end trim must stay after clip start".to_string(),
                            ));
                        }
                        let new_len = *to_frame - old_start;
                        if clip.offset_frames.saturating_add(new_len) > source_len {
                            return Err(CommandError::OutOfRange(
                                "end trim extends past source content".to_string(),
                            ));
                        }
                        {
                            let tempo = self.tempo.clone();
                            let rate = self.sample_rate;
                            let clip = &mut self.tracks[ti].clips[ci];
                            clip.len_frames = new_len;
                            sync_ticks_from_frames(clip, &tempo, rate);
                        }
                        vec![Command::ClipTrim {
                            clip_id: clip_id.clone(),
                            edge: TrimEdge::End,
                            to_frame: old_end,
                        }]
                    }
                }
            }

            Command::ClipSplit {
                clip_id,
                at_frame,
                right_clip_id,
            } => {
                if self.clip_id_exists(right_clip_id) {
                    return Err(CommandError::DuplicateId(right_clip_id.clone()));
                }
                let (ti, ci) = self
                    .find_clip(clip_id)
                    .ok_or_else(|| CommandError::UnknownClip(clip_id.clone()))?;
                let clip = &self.tracks[ti].clips[ci];
                let (old_start, old_end) = (clip.start_frame, clip.end_frame());
                if !(*at_frame > old_start && *at_frame < old_end) {
                    return Err(CommandError::OutOfRange(format!(
                        "split point {at_frame} must be strictly inside ({old_start}, {old_end})"
                    )));
                }
                let old_fade_out = clip.fade_out_frames;
                let left_len = *at_frame - old_start;
                let tempo = self.tempo.clone();
                let rate = self.sample_rate;
                let mut right = clip.clone();
                right.id = right_clip_id.clone();
                right.start_frame = *at_frame;
                right.offset_frames = clip.offset_frames + left_len;
                right.len_frames = clip.len_frames - left_len;
                right.fade_in_frames = 0;
                right.name = right_clip_id.clone();
                sync_ticks_from_frames(&mut right, &tempo, rate);
                {
                    let left = &mut self.tracks[ti].clips[ci];
                    left.len_frames = left_len;
                    left.fade_out_frames = 0;
                    sync_ticks_from_frames(left, &tempo, rate);
                }
                self.tracks[ti].clips.push(right);
                self.tracks[ti].sort_clips();
                vec![
                    Command::ClipRemove {
                        clip_id: right_clip_id.clone(),
                    },
                    Command::ClipTrim {
                        clip_id: clip_id.clone(),
                        edge: TrimEdge::End,
                        to_frame: old_end,
                    },
                    Command::ClipFadeSet {
                        clip_id: clip_id.clone(),
                        fade_in_frames: None,
                        fade_out_frames: Some(old_fade_out),
                        fade_shape: None,
                    },
                ]
            }

            Command::ClipSetGain { clip_id, gain_db } => {
                validate_gain(*gain_db)?;
                let (ti, ci) = self
                    .find_clip(clip_id)
                    .ok_or_else(|| CommandError::UnknownClip(clip_id.clone()))?;
                let old = self.tracks[ti].clips[ci].gain_db;
                self.tracks[ti].clips[ci].gain_db = *gain_db;
                self.tracks[ti].clips[ci].gain = legacy_gain_num(*gain_db);
                vec![Command::ClipSetGain {
                    clip_id: clip_id.clone(),
                    gain_db: old,
                }]
            }

            Command::ClipFadeSet {
                clip_id,
                fade_in_frames,
                fade_out_frames,
                fade_shape,
            } => {
                if fade_in_frames.is_none() && fade_out_frames.is_none() && fade_shape.is_none() {
                    return Err(CommandError::InvalidParams(
                        "clip.fade.set requires at least one field".to_string(),
                    ));
                }
                let (ti, ci) = self
                    .find_clip(clip_id)
                    .ok_or_else(|| CommandError::UnknownClip(clip_id.clone()))?;
                let len = self.tracks[ti].clips[ci].len_frames;
                for (label, value) in [("fade_in", fade_in_frames), ("fade_out", fade_out_frames)] {
                    if let Some(frames) = value {
                        if *frames > len {
                            return Err(CommandError::OutOfRange(format!(
                                "{label} of {frames} frames exceeds clip length {len}"
                            )));
                        }
                    }
                }
                let clip = &mut self.tracks[ti].clips[ci];
                let inverse = Command::ClipFadeSet {
                    clip_id: clip_id.clone(),
                    fade_in_frames: fade_in_frames.map(|_| clip.fade_in_frames),
                    fade_out_frames: fade_out_frames.map(|_| clip.fade_out_frames),
                    fade_shape: fade_shape.map(|_| clip.fade_shape),
                };
                if let Some(frames) = fade_in_frames {
                    clip.fade_in_frames = *frames;
                }
                if let Some(frames) = fade_out_frames {
                    clip.fade_out_frames = *frames;
                }
                if let Some(shape) = fade_shape {
                    clip.fade_shape = *shape;
                }
                let tempo = self.tempo.clone();
                let rate = self.sample_rate;
                let (ti, ci) = self.find_clip(clip_id).expect("clip just mutated");
                sync_ticks_from_frames(&mut self.tracks[ti].clips[ci], &tempo, rate);
                vec![inverse]
            }

            Command::TrackAdd {
                track_id,
                name,
                index,
            } => {
                if self.track(track_id).is_some() {
                    return Err(CommandError::DuplicateId(track_id.clone()));
                }
                let at = index.unwrap_or(self.tracks.len());
                if at > self.tracks.len() {
                    return Err(CommandError::OutOfRange(format!(
                        "track index {at} out of range 0..={}",
                        self.tracks.len()
                    )));
                }
                self.tracks
                    .insert(at, crate::model::Track::new(track_id.clone(), name.clone()));
                vec![Command::TrackRemove {
                    track_id: track_id.clone(),
                }]
            }

            Command::TrackRemove { track_id } => {
                let index = self
                    .track_index(track_id)
                    .ok_or_else(|| CommandError::UnknownTrack(track_id.clone()))?;
                if !self.tracks[index].clips.is_empty() {
                    return Err(CommandError::TrackNotEmpty(track_id.clone()));
                }
                let track = self.tracks.remove(index);
                vec![Command::TrackAdd {
                    track_id: track.id,
                    name: track.name,
                    index: Some(index),
                }]
            }

            Command::TrackMute { track_id, mute } => {
                let track = self
                    .track_mut(track_id)
                    .ok_or_else(|| CommandError::UnknownTrack(track_id.clone()))?;
                let old = track.mute;
                track.mute = *mute;
                vec![Command::TrackMute {
                    track_id: track_id.clone(),
                    mute: old,
                }]
            }

            // Transport: validated, but no model mutation and no inverse.
            Command::TransportPlay {} | Command::TransportStop {} => Vec::new(),
            Command::TransportSeek { to_tick, to_frame } => {
                resolve_position("transport.seek", *to_tick, *to_frame, self)?;
                Vec::new()
            }
            Command::TransportLoopSet {
                start_tick,
                end_tick,
            } => {
                if start_tick >= end_tick {
                    return Err(CommandError::InvalidParams(
                        "loop start_tick must be before end_tick".to_string(),
                    ));
                }
                Vec::new()
            }
            Command::TransportLoopClear {} => Vec::new(),
        };

        Ok(Applied {
            command: command.clone(),
            inverse,
        })
    }
}
