//! Shared test support: a representative valid call per catalog command (used
//! to prove full catalog coverage and to seed generators), a small deterministic
//! RNG, and a stateful random-command generator for the fuzz test.
//!
//! Included into each integration test binary via `#[path = "support.rs"] mod
//! support;`.

#![allow(dead_code)]

use serde_json::{json, Value};
use timeline_core::cmd::Cmd;
use timeline_core::envelope::{Actor, EntryMeta};
use timeline_core::session::Session;
use timeline_core::tempo::Bpm;
use timeline_core::{Num, TempoMap};

const ULID_A: &str = "01J8Z4G9K2X4Q6R8T0V2W4Y6A8";
const ULID_B: &str = "01J8Z4G9K2X4Q6R8T0V2W4Y6A9";
const HASH_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const HASH_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

/// One representative, schema-valid params object per catalog command name.
/// This is the coverage table: it must contain every one of the catalog's
/// commands (100 in catalog v2 after E1).
pub fn representative_commands() -> Vec<(&'static str, Value)> {
    vec![
        ("project.new", json!({"name": "Song"})),
        ("project.open", json!({"path": "/tmp/x.mstudio"})),
        ("project.save", json!({})),
        ("project.setTempo", json!({"bpm": 92})),
        (
            "project.setTimeSig",
            json!({"numerator": 4, "denominator": 4}),
        ),
        ("project.setKey", json!({"key": "A minor"})),
        (
            "section.set",
            json!({"sectionId": "sec1", "name": "Verse", "startTicks": 0}),
        ),
        ("section.remove", json!({"sectionId": "sec1"})),
        (
            "marker.set",
            json!({"markerId": "mk1", "positionTicks": 960, "label": "drop"}),
        ),
        ("marker.remove", json!({"markerId": "mk1"})),
        ("transport.play", json!({})),
        ("transport.stop", json!({})),
        ("transport.seek", json!({"positionTicks": 480})),
        (
            "transport.loop.set",
            json!({"startTicks": 0, "endTicks": 3840}),
        ),
        ("transport.loop.clear", json!({})),
        ("transport.metronome", json!({"enabled": true})),
        ("record.start", json!({"trackId": "trk1"})),
        ("record.rotate", json!({})),
        ("record.stop", json!({})),
        ("record.cancel", json!({})),
        ("record.inputListen", json!({"enabled": true})),
        (
            "midi.device.select",
            json!({"device": "USB MIDI Interface", "map": "auto"}),
        ),
        (
            "midi.port.role.set",
            json!({"port": "USB MIDI Interface", "role": "instrument"}),
        ),
        ("midi.learn.start", json!({"device": "USB MIDI Interface"})),
        ("midi.learn.stop", json!({})),
        (
            "midi.binding.set",
            json!({
                "device": "USB MIDI Interface",
                "control": {"type": "controlChange", "channel": 0, "number": 74},
                "target": {"kind": "command", "name": "mix.gain", "params": {"trackId": "trk1", "gainDb": "$value"}},
                "valueMap": {"inputMin": 0, "inputMax": 127, "outputMin": -12, "outputMax": 6, "curve": "linear"},
                "label": "Filter knob",
                "enabled": true
            }),
        ),
        (
            "midi.binding.clear",
            json!({"device": "USB MIDI Interface", "control": {"type": "controlChange", "channel": 0, "number": 74}}),
        ),
        (
            "midi.map.import",
            json!({"sourcePath": "/tmp/controller-map.json"}),
        ),
        (
            "midi.map.export",
            json!({"map": "generic-controller", "outputPath": "/tmp/generic-controller.json"}),
        ),
        ("midi.reload", json!({})),
        (
            "track.add",
            json!({"trackId": "trk1", "name": "Drums", "index": 0}),
        ),
        ("track.remove", json!({"trackId": "trk1"})),
        ("track.rename", json!({"trackId": "trk1", "name": "Kit"})),
        ("track.reorder", json!({"trackId": "trk1", "newIndex": 0})),
        (
            "track.setColor",
            json!({"trackId": "trk1", "color": "#E05252"}),
        ),
        (
            "track.setHeight",
            json!({"trackId": "trk1", "heightPx": 120}),
        ),
        ("track.mute", json!({"trackId": "trk1", "muted": true})),
        ("track.solo", json!({"trackId": "trk1", "soloed": true})),
        ("track.arm", json!({"trackId": "trk1", "armed": true})),
        (
            "track.setInputChannel",
            json!({"trackId": "trk1", "channel": 0}),
        ),
        (
            "device.add",
            json!({"trackId": "trk1", "deviceId": "dev1", "kind": "synth"}),
        ),
        ("device.remove", json!({"trackId": "trk1", "deviceId": "dev1"})),
        (
            "device.zone.add",
            json!({"trackId": "trk1", "deviceId": "dev1", "zoneId": "z1",
                   "sourceId": HASH_A, "rootPitch": 60, "loPitch": 0, "hiPitch": 127}),
        ),
        (
            "device.zone.remove",
            json!({"trackId": "trk1", "deviceId": "dev1", "zoneId": "z1"}),
        ),
        (
            "device.param.set",
            json!({"trackId": "trk1", "deviceId": "dev1", "key": "waveform", "value": 3}),
        ),
        (
            "device.param.clear",
            json!({"trackId": "trk1", "deviceId": "dev1", "key": "waveform"}),
        ),
        (
            "clip.place",
            json!({"clipId": "c1", "trackId": "trk1", "assetHash": HASH_A, "startTicks": 0, "lengthTicks": 3840}),
        ),
        (
            "clip.move",
            json!({"clipId": "c1", "trackId": "trk1", "startTicks": 960}),
        ),
        (
            "clip.trim",
            json!({"clipId": "c1", "edge": "end", "deltaTicks": -480}),
        ),
        (
            "clip.split",
            json!({"clipId": "c1", "atTicks": 1920, "newClipId": "c1r"}),
        ),
        (
            "clip.duplicate",
            json!({"clipId": "c1", "newClipId": "c2", "startTicks": 3840}),
        ),
        ("clip.remove", json!({"clipId": "c1"})),
        ("clip.setGain", json!({"clipId": "c1", "gainDb": -3})),
        ("clip.mute", json!({"clipId": "c1", "muted": true})),
        (
            "clip.fade.set",
            json!({"clipId": "c1", "edge": "in", "lengthTicks": 240, "shape": "linear"}),
        ),
        (
            "clip.crossfade.set",
            json!({"clipIdA": "c1", "clipIdB": "c2", "lengthTicks": 240, "shape": "equalPower"}),
        ),
        (
            "clip.warp.set",
            json!({"clipId": "c1", "mode": "ratio", "stretchRatio": 1.5}),
        ),
        (
            "clip.phaseAnchor.set",
            json!({"clipId": "c1", "anchorTicks": 0}),
        ),
        ("clip.rename", json!({"clipId": "c1", "name": "Loop"})),
        // ---- E1: note-backed clips + MIDI notes (batch + delta) ----
        (
            "clip.placeMidi",
            json!({"clipId": "cm1", "trackId": "trk1", "startTicks": 0, "lengthTicks": 3840}),
        ),
        (
            "note.add",
            json!({"clipId": "cm1", "notes": [
                {"noteId": "nt1", "startTicks": 0, "lengthTicks": 480, "pitch": 60, "velocity": 100},
                {"noteId": "nt2", "startTicks": 0, "lengthTicks": 480, "pitch": 64, "velocity": 100}
            ]}),
        ),
        ("note.remove", json!({"clipId": "cm1", "noteIds": ["nt1", "nt2"]})),
        (
            "note.move",
            json!({"clipId": "cm1", "noteIds": ["nt1"], "deltaTicks": 480, "deltaPitch": 2}),
        ),
        (
            "note.resize",
            json!({"clipId": "cm1", "noteIds": ["nt1"], "edge": "trailing", "deltaTicks": 240}),
        ),
        (
            "note.velocity.set",
            json!({"clipId": "cm1", "noteIds": ["nt1"], "deltaVelocity": -10}),
        ),
        (
            "note.duplicate",
            json!({"clipId": "cm1", "noteIds": ["nt1"], "newNoteIds": ["nt3"],
                   "deltaTicks": 960, "deltaPitch": 0}),
        ),
        // The two ABSOLUTE note commands. `note.timing.set` is the only one in
        // the family that names positions instead of deltas, and it exists so
        // `note.quantize` has an inverse that restores exactly where the
        // performance was.
        (
            "note.timing.set",
            json!({"clipId": "cm1", "notes": [
                {"noteId": "nt1", "startTicks": 237, "lengthTicks": 461}
            ]}),
        ),
        (
            "note.quantize",
            json!({"clipId": "cm1", "noteIds": ["nt1", "nt2"], "gridTicks": 240,
                   "strengthPercent": 65, "quantizeEnds": false}),
        ),
        (
            "autolane.show",
            json!({"trackId": "trk1", "target": "track.volume", "visible": true}),
        ),
        (
            "autopoint.add",
            json!({"trackId": "trk1", "target": "track.volume", "pointId": "ap1", "positionTicks": 0, "value": 0}),
        ),
        (
            "autopoint.move",
            json!({"trackId": "trk1", "target": "track.volume", "pointId": "ap1", "positionTicks": 960, "value": -6}),
        ),
        (
            "autopoint.remove",
            json!({"trackId": "trk1", "target": "track.volume", "pointId": "ap1"}),
        ),
        (
            "autolane.clear",
            json!({"trackId": "trk1", "target": "track.volume"}),
        ),
        ("mix.gain", json!({"trackId": "trk1", "gainDb": -2})),
        ("mix.pan", json!({"trackId": "trk1", "pan": 0})),
        (
            "mix.eq",
            json!({"trackId": "trk1", "band": 0, "freqHz": 80, "gainDb": 3}),
        ),
        (
            "mix.send",
            json!({"trackId": "trk1", "bus": "a", "amount": 1}),
        ),
        ("mix.master.gain", json!({"gainDb": 0})),
        ("mix.limiter.set", json!({"enabled": true})),
        (
            "gen.song",
            json!({"requestId": ULID_A, "trackId": "trk1", "insertAtTicks": 0, "request": {"caption": "lofi"}}),
        ),
        (
            "gen.revise",
            json!({"requestId": ULID_A, "clipId": "c1", "regionStartTicks": 0, "regionEndTicks": 960, "scope": "all-stems", "request": {"instruction": "warmer"}}),
        ),
        (
            "gen.extend",
            json!({"requestId": ULID_A, "clipId": "c1", "addedDurationSeconds": 8, "request": {}}),
        ),
        (
            "gen.layer",
            json!({"requestId": ULID_A, "targetTrackId": "trk1", "instruction": "bass", "request": {}}),
        ),
        (
            "gen.retake",
            json!({"requestId": ULID_A, "sourceTakeId": "tk1", "request": {}}),
        ),
        (
            "gen.autocomplete",
            json!({"requestId": ULID_A, "clipId": "c1", "request": {}}),
        ),
        (
            "gen.cover",
            json!({"requestId": ULID_A, "referenceClipId": "c1", "request": {}}),
        ),
        (
            "gen.separate",
            json!({"requestId": ULID_A, "clipId": "c1", "engine": "demucs"}),
        ),
        ("gen.cancel", json!({"requestId": ULID_A})),
        (
            "gen.finalize",
            json!({"requestId": ULID_A, "draftTakeId": "tk1", "targetQualityRung": "full", "request": {}}),
        ),
        (
            "gen.landed",
            json!({"requestId": ULID_A, "sourceCommand": "gen.song", "takeId": "tk1", "assetHashes": {"mix": HASH_B}, "engineIdentity": {"model": "acestep-v15", "device": "mlx"}}),
        ),
        (
            "take.promote",
            json!({"takeId": "tk1", "targetClipId": "c1"}),
        ),
        ("take.discard", json!({"takeId": "tk1"})),
        ("take.purge", json!({"takeId": "tk1"})),
        ("take.restore", json!({"takeId": "tk1"})),
        (
            "take.auditionMix",
            json!({"takeId": "tk1", "stems": ["mix"]}),
        ),
        (
            "import.audio",
            json!({"sourcePath": "/tmp/a.wav", "targetTrackId": "trk1"}),
        ),
        (
            "import.stems",
            json!({"sourceDir": "/tmp/stems", "targetTrackId": "trk1"}),
        ),
        (
            "export.master",
            json!({"outputPath": "/tmp/out.wav", "format": "wav"}),
        ),
        (
            "export.stems",
            json!({"outputDir": "/tmp/stems", "format": "wav"}),
        ),
        (
            "export.region",
            json!({"outputPath": "/tmp/r.wav", "startTicks": 0, "endTicks": 3840, "format": "wav"}),
        ),
        (
            "export.manifest",
            json!({"outputPath": "/tmp/manifest.json"}),
        ),
        (
            "publish.track",
            json!({"assetHash": HASH_A, "title": "Song"}),
        ),
        ("txn.begin", json!({"txnId": "txn1", "reason": "drag"})),
        ("txn.commit", json!({"txnId": "txn1"})),
        ("studio.importStemSession", json!({"stemSessionId": "ss1"})),
        // ---- catalog v2 ----
        ("project.setPhaseAnchor", json!({"anchorTicks": 1915})),
        (
            "route.node.add",
            json!({"nodeId": "grp1", "kind": "group", "name": "Drums Bus"}),
        ),
        ("route.node.remove", json!({"nodeId": "grp1"})),
        (
            "route.connect",
            json!({"edgeId": "e1", "from": "track.trk1", "to": "bus.grp1",
                   "level": 1, "tap": "post"}),
        ),
        ("route.disconnect", json!({"edgeId": "e1"})),
        (
            "route.edge.set",
            json!({"edgeId": "e1", "level": 1, "tap": "pre"}),
        ),
        ("route.node.set", json!({"nodeId": "grp1", "gainDb": -6})),
        // ---- E5 §16: the effect registry ----
        (
            "fx.add",
            json!({"target": "track.trk1", "fxId": "fx1", "kind": "compressor"}),
        ),
        ("fx.remove", json!({"target": "track.trk1", "fxId": "fx1"})),
        (
            "fx.move",
            json!({"target": "bus.grp1", "fxId": "fx1", "index": 0}),
        ),
        (
            "fx.param.set",
            json!({"target": "master", "fxId": "fx1", "key": "threshold", "value": -18}),
        ),
        (
            "fx.param.clear",
            json!({"target": "master", "fxId": "fx1", "key": "threshold"}),
        ),
        (
            "fx.sidechain.set",
            json!({"target": "bus.grp1", "fxId": "fx1", "source": "track.trk1"}),
        ),
        (
            "fx.sidechain.clear",
            json!({"target": "bus.grp1", "fxId": "fx1"}),
        ),
    ]
}

/// Deterministic SplitMix64 for reproducible fuzzing without a rand dep.
pub struct Rng(pub u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng(seed)
    }
    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
    pub fn below(&mut self, n: u64) -> u64 {
        if n == 0 {
            0
        } else {
            self.next_u64() % n
        }
    }
    pub fn pick<'a, T>(&mut self, xs: &'a [T]) -> &'a T {
        &xs[self.below(xs.len() as u64) as usize]
    }
}

pub fn meta(n: u64, actor: Actor) -> EntryMeta {
    EntryMeta {
        id: format!("{n:026}"),
        ts: "2026-07-11T20:00:00Z".to_string(),
        actor,
    }
}

pub fn user_meta(n: u64) -> EntryMeta {
    meta(n, Actor::user("aaron"))
}

/// Parse a (name, params) pair into a typed Cmd (panics on failure, for tests).
pub fn cmd(name: &str, params: Value) -> Cmd {
    Cmd::from_wire(name, params).expect("representative command parses")
}

// ---------------------------------------------------------------------------
// Conductor: generates ONE legal-by-construction catalog command for the
// current project state (fresh ids for creates, free slots for placement, safe
// deltas for trims), spread across command families for coverage. Used by both
// the property tests and the 10k fuzz. Occasionally a candidate may still be
// rejected (e.g. a positive trim that would overlap); callers skip rejects.
// ---------------------------------------------------------------------------

use timeline_core::model::{AutoTarget, DeviceKind, FxKind, Project};
use timeline_core::paramref::ParamRef;
use timeline_core::routing::NodeRef;

/// True when `target` on track `ti` names a live-resolvable object that the
/// model no longer contains — a DEAD lane. `require_param_ref_on` deliberately
/// stopped checking this (existence is the compile gate's job; checking it at
/// apply time broke truthful inverses), so the generator and the coverage test
/// inspect the model directly.
pub fn lane_is_dead(project: &Project, ti: usize, target: &ParamRef) -> bool {
    use timeline_core::paramref::ParamRefKind as K;
    match target.kind() {
        K::TrackDeviceParam { device_id, .. } => project.tracks[ti].device(device_id).is_none(),
        K::TrackFxParam { fx_id, .. } => {
            timeline_core::model::fx_index(&project.tracks[ti].fx, fx_id).is_none()
        }
        K::BusGain { bus_id } => project.routing.node(bus_id).is_none(),
        K::BusFxParam { bus_id, fx_id, .. } => match project.routing.node(bus_id) {
            None => true,
            Some(n) => timeline_core::model::fx_index(&n.fx, fx_id).is_none(),
        },
        K::MasterFxParam { fx_id, .. } => {
            timeline_core::model::fx_index(&project.master.fx, fx_id).is_none()
        }
        K::RouteEdgeLevel { edge_id } => project.routing.edge(edge_id).is_none(),
        _ => false,
    }
}

pub struct Conductor {
    pub rng: Rng,
    next_track: u64,
    next_clip: u64,
    next_point: u64,
    next_note: u64,
    next_section: u64,
    next_marker: u64,
    next_device: u64,
    next_zone: u64,
    next_fx: u64,
    next_node: u64,
    next_edge: u64,
}

impl Conductor {
    pub fn new(seed: u64) -> Self {
        Conductor {
            rng: Rng::new(seed),
            next_track: 0,
            next_clip: 0,
            next_point: 0,
            next_note: 0,
            next_section: 0,
            next_marker: 0,
            next_device: 0,
            next_zone: 0,
            next_fx: 0,
            next_node: 0,
            next_edge: 0,
        }
    }

    fn fresh(prefix: &str, n: &mut u64) -> String {
        let id = format!("{prefix}{n}");
        *n += 1;
        id
    }

    fn tick(&mut self) -> u64 {
        self.rng.below(16) * 240 // multiples of a 16th note, 0..3840
    }

    fn gain(&mut self) -> Num {
        Num::int(0 - self.rng.below(13) as i64) // 0..-12 dB, integer-shaped
    }

    fn free_start_on(project: &Project, track_idx: usize, exclude: Option<&str>) -> u64 {
        project.tracks[track_idx]
            .clips
            .iter()
            .filter(|c| Some(c.id.as_str()) != exclude)
            .map(|c| c.end_ticks())
            .max()
            .unwrap_or(0)
    }

    /// Produce one candidate command legal for `project`'s current state.
    pub fn gen(&mut self, project: &Project) -> Cmd {
        let have_tracks = !project.tracks.is_empty();
        let clips: Vec<(String, String)> = project
            .tracks
            .iter()
            .flat_map(|t| t.clips.iter().map(move |c| (t.id.clone(), c.id.clone())))
            .collect();
        let have_clips = !clips.is_empty();

        // Weighted menu: bias toward building structure early, then editing.
        let roll = self.rng.below(100);
        // Ensure we can always make progress: if no tracks, add one.
        if !have_tracks || roll < 12 {
            let id = Self::fresh("trk", &mut self.next_track);
            let idx = if project.tracks.is_empty() {
                0
            } else {
                self.rng.below(project.tracks.len() as u64 + 1) as u32
            };
            return Cmd::TrackAdd {
                track_id: id.clone(),
                name: format!("Track {id}"),
                index: Some(idx),
            };
        }
        if roll < 30 {
            // place a clip in a free slot
            let ti = self.rng.below(project.tracks.len() as u64) as usize;
            let start = Self::free_start_on(project, ti, None) + self.rng.below(4) * 240;
            let len = (self.rng.below(8) + 1) * 480;
            return Cmd::ClipPlace {
                clip_id: Self::fresh("cl", &mut self.next_clip),
                track_id: project.tracks[ti].id.clone(),
                asset_hash: format!("{:064x}", self.rng.next_u64()),
                start_ticks: start,
                length_ticks: len,
                source_offset_ticks: None,
            };
        }
        // E1: note-backed clips get the SAME fuzz treatment as audio clips.
        // A command family the conductor never emits is a family whose inverse
        // exactness is never actually property-tested.
        if roll < 34 {
            let ti = self.rng.below(project.tracks.len() as u64) as usize;
            let start = Self::free_start_on(project, ti, None) + self.rng.below(4) * 240;
            let len = (self.rng.below(8) + 1) * 480;
            return Cmd::ClipPlaceMidi {
                clip_id: Self::fresh("cm", &mut self.next_clip),
                track_id: project.tracks[ti].id.clone(),
                start_ticks: start,
                length_ticks: len,
            };
        }
        // Collect the note clips once; several branches below need them.
        let midi_clips: Vec<String> = project
            .tracks
            .iter()
            .flat_map(|t| t.clips.iter())
            .filter(|c| c.is_midi())
            .map(|c| c.id.clone())
            .collect();
        if roll < 46 && !midi_clips.is_empty() {
            let cid = midi_clips[self.rng.below(midi_clips.len() as u64) as usize].clone();
            let clip = project.clip(&cid).expect("just listed").clone();
            let ids: Vec<String> = clip.notes.iter().map(|n| n.id.clone()).collect();
            // Bias toward adding while a clip is empty so later branches have
            // something to edit.
            if ids.is_empty() || self.rng.below(3) == 0 {
                let n = 1 + self.rng.below(3);
                let notes = (0..n)
                    .map(|_| timeline_core::cmd::NoteSpec {
                        note_id: Self::fresh("nt", &mut self.next_note),
                        start_ticks: self.rng.below(8) * 240,
                        length_ticks: (self.rng.below(4) + 1) * 120,
                        pitch: (24 + self.rng.below(72)) as u8,
                        velocity: Num::int(1 + self.rng.below(120) as i64),
                    })
                    .collect();
                return Cmd::NoteAdd { clip_id: cid, notes };
            }
            // A random non-empty subset, so batches of every size are covered.
            let take = 1 + self.rng.below(ids.len() as u64);
            let batch: Vec<String> = ids.into_iter().take(take as usize).collect();
            return match self.rng.below(5) {
                0 => Cmd::NoteRemove {
                    clip_id: cid,
                    note_ids: batch,
                },
                1 => Cmd::NoteMove {
                    clip_id: cid,
                    note_ids: batch,
                    // Deltas that can legally fail (negative past 0, pitch out
                    // of range) are GOOD here: the conductor's rejects prove
                    // the no-partial-apply rule as much as its accepts do.
                    delta_ticks: self.rng.below(9) as i64 * 120 - 480,
                    delta_pitch: self.rng.below(25) as i32 - 12,
                },
                2 => Cmd::NoteResize {
                    clip_id: cid,
                    note_ids: batch,
                    edge: if self.rng.below(2) == 1 {
                        timeline_core::cmd::NoteEdge::Leading
                    } else {
                        timeline_core::cmd::NoteEdge::Trailing
                    },
                    delta_ticks: self.rng.below(5) as i64 * 120 - 240,
                },
                3 => Cmd::NoteVelocitySet {
                    clip_id: cid,
                    note_ids: batch,
                    delta_velocity: self.rng.below(41) as i64 - 20,
                },
                _ => {
                    let new_ids = batch
                        .iter()
                        .map(|_| Self::fresh("nt", &mut self.next_note))
                        .collect();
                    Cmd::NoteDuplicate {
                        clip_id: cid,
                        note_ids: batch,
                        new_note_ids: new_ids,
                        delta_ticks: self.rng.below(5) as i64 * 240,
                        delta_pitch: self.rng.below(13) as i32 - 6,
                    }
                }
            };
        }
        if roll < 36 {
            let bpm = 60 + self.rng.below(120) as i64;
            return Cmd::ProjectSetTempo { bpm: Num::int(bpm) };
        }
        if roll < 40 {
            return Cmd::MarkerSet {
                marker_id: Self::fresh("mk", &mut self.next_marker),
                position_ticks: self.tick(),
                label: "m".into(),
                color: None,
            };
        }
        if roll < 44 {
            return Cmd::SectionSet {
                section_id: Self::fresh("sec", &mut self.next_section),
                name: "S".into(),
                start_ticks: self.tick(),
                color: None,
            };
        }
        // track-scoped edits
        let ti = self.rng.below(project.tracks.len() as u64) as usize;
        let track_id = project.tracks[ti].id.clone();
        if roll < 50 {
            return Cmd::TrackMute {
                track_id,
                muted: self.rng.below(2) == 1,
            };
        }
        if roll < 54 {
            return Cmd::MixGain {
                track_id,
                gain_db: self.gain(),
            };
        }
        if roll < 58 {
            return Cmd::MixEq {
                track_id,
                band: self.rng.below(4) as u32,
                freq_hz: Num::int(80 + 200 * self.rng.below(20) as i64),
                gain_db: Num::int(self.rng.below(13) as i64 - 6),
                q: None,
            };
        }
        if roll < 62 {
            return Cmd::AutopointAdd {
                track_id,
                target: if self.rng.below(2) == 1 {
                    AutoTarget::Volume.param_ref()
                } else {
                    AutoTarget::Pan.param_ref()
                },
                point_id: Self::fresh("ap", &mut self.next_point),
                position_ticks: self.tick(),
                value: Num::int(self.rng.below(7) as i64 - 6),
            };
        }
        if roll < 66 {
            return Cmd::TrackSetColor {
                track_id,
                color: format!("#{:06X}", self.rng.below(0xFFFFFF)),
            };
        }

        // ---- devices, inserts, routing, and the DESTRUCTIVE family ----
        //
        // THE HOLE THIS CLOSES. Before this branch the conductor emitted 26 of
        // the catalog's 112 commands, and among them exactly ONE remove
        // (`note.remove`). No generated sequence ever put an instrument on a
        // track and then removed the track, so `single_command_inverse_restores_prestate`
        // ran for months over a `track.remove` whose inverse silently dropped
        // `Track::devices` — real user data loss (delete a track, undo, your
        // synth is gone) that a property suite named "every applied command's
        // inverse restores the exact pre-state" could not see, because it never
        // generated the command.
        //
        // A command family the conductor never emits is a family whose inverse
        // exactness is never actually property-tested. The rule this branch
        // encodes: every DESTRUCTIVE command must be reachable, and it must be
        // reachable on state that is RICH (devices, zones, inserts, effect
        // params, sends, per-lane automation, phase anchors), because an
        // inverse that drops sub-state round-trips perfectly on an empty one.
        if roll < 86 {
            if let Some(cmd) = self.gen_structural(project) {
                return cmd;
            }
        }

        // clip-scoped edits (fall back to a track edit if no clips)
        if !have_clips {
            return Cmd::TrackRename {
                track_id,
                name: format!("R{}", self.rng.below(1000)),
            };
        }
        let (ctrack, cid) = clips[self.rng.below(clips.len() as u64) as usize].clone();
        let cti = project.track_index(&ctrack).unwrap();
        let clip = project.clip(&cid).unwrap().clone();
        match self.rng.below(8) {
            0 => {
                // move to a free slot on some track
                let dti = self.rng.below(project.tracks.len() as u64) as usize;
                let start = Self::free_start_on(project, dti, Some(&cid)) + self.rng.below(4) * 240;
                Cmd::ClipMove {
                    clip_id: cid,
                    track_id: project.tracks[dti].id.clone(),
                    start_ticks: start,
                }
            }
            1 => Cmd::ClipSetGain {
                clip_id: cid,
                gain_db: self.gain(),
            },
            2 => Cmd::ClipMute {
                clip_id: cid,
                muted: self.rng.below(2) == 1,
            },
            3 => {
                // shrink from the end (always safe: reduces length)
                let max_shrink = clip.length_ticks.saturating_sub(240).max(1);
                let delta = -((self.rng.below(max_shrink / 240 + 1) * 240) as i64);
                Cmd::ClipTrim {
                    clip_id: cid,
                    edge: timeline_core::cmd::TrimEdgeWire::End,
                    delta_ticks: if delta == 0 { -240 } else { delta },
                }
            }
            4 => {
                let flen =
                    (self.rng.below(clip.length_ticks / 240 + 1) * 240).min(clip.length_ticks);
                Cmd::ClipFadeSet {
                    clip_id: cid,
                    edge: if self.rng.below(2) == 1 {
                        timeline_core::cmd::FadeEdge::In
                    } else {
                        timeline_core::cmd::FadeEdge::Out
                    },
                    length_ticks: flen,
                    shape: timeline_core::model::FadeCurve::Linear,
                }
            }
            5 if clip.length_ticks > 480 => {
                let at = clip.start_ticks + 240 * (1 + self.rng.below(clip.length_ticks / 240 - 1));
                Cmd::ClipSplit {
                    clip_id: cid,
                    at_ticks: at,
                    new_clip_id: Self::fresh("cl", &mut self.next_clip),
                }
            }
            6 => {
                let start = Self::free_start_on(project, cti, None) + self.rng.below(4) * 240;
                Cmd::ClipDuplicate {
                    clip_id: cid,
                    new_clip_id: Self::fresh("cl", &mut self.next_clip),
                    start_ticks: start,
                }
            }
            _ => Cmd::ClipRename {
                clip_id: cid,
                name: format!("clip{}", self.rng.below(1000)),
            },
        }
    }

    /// One command from the device / insert / routing / remove families.
    ///
    /// `None` when the current state offers no legal candidate in the drawn
    /// sub-family (e.g. `fx.remove` with no effects anywhere); the caller falls
    /// through to the clip-edit menu, so the generator never stalls.
    fn gen_structural(&mut self, project: &Project) -> Option<Cmd> {
        let ti = self.rng.below(project.tracks.len() as u64) as usize;
        let track_id = project.tracks[ti].id.clone();

        // DEAD-LANE SWEEP, before the family draw: when the chosen track holds
        // a lane whose object is gone, one roll in four edits it right away.
        // Case 11's in-family bias alone left the ordering reachable but so
        // rare that a 120-case property run could sail past a reverted fix;
        // this hoist makes "remove object → edit its dead lane → undo" land
        // inside ordinary property-test case counts, not just the 24k-step
        // coverage drive.
        if self.rng.below(4) == 0 {
            let lanes = project.tracks[ti].automation.iter_lanes();
            let dead: Vec<_> = lanes
                .iter()
                .filter(|(t, _)| lane_is_dead(project, ti, t))
                .collect();
            if !dead.is_empty() {
                let (target, points) = dead[self.rng.below(dead.len() as u64) as usize];
                if self.rng.below(2) == 0 {
                    return Some(Cmd::AutolaneClear {
                        track_id,
                        target: target.clone(),
                    });
                }
                let p = &points[self.rng.below(points.len() as u64) as usize];
                return Some(Cmd::AutopointRemove {
                    track_id,
                    target: target.clone(),
                    point_id: p.id.clone(),
                });
            }
        }

        // Flat views of the state the destructive commands need.
        let devices: Vec<(String, String, DeviceKind)> = project
            .tracks
            .iter()
            .flat_map(|t| {
                t.devices
                    .iter()
                    .map(move |d| (t.id.clone(), d.id.clone(), d.kind))
            })
            .collect();
        let zones: Vec<(String, String, String)> = project
            .tracks
            .iter()
            .flat_map(|t| {
                t.devices.iter().flat_map(move |d| {
                    d.zones
                        .iter()
                        .map(move |z| (t.id.clone(), d.id.clone(), z.id.clone()))
                })
            })
            .collect();
        let track_fx: Vec<(String, String)> = project
            .tracks
            .iter()
            .flat_map(|t| t.fx.iter().map(move |f| (t.id.clone(), f.id.clone())))
            .collect();

        match self.rng.below(18) {
            // ---- E1/E2 device registry ----
            0 => Some(Cmd::DeviceAdd {
                track_id,
                device_id: Self::fresh("dev", &mut self.next_device),
                kind: match self.rng.below(3) {
                    0 => DeviceKind::Synth,
                    1 => DeviceKind::Sampler,
                    _ => DeviceKind::Drum,
                },
            }),
            1 => {
                // A zone only belongs on a sampler or a drum pad, and a pad
                // covers exactly one key.
                let candidates: Vec<_> = devices
                    .iter()
                    .filter(|(_, _, k)| *k != DeviceKind::Synth)
                    .collect();
                if candidates.is_empty() {
                    return None;
                }
                let (t, d, k) = candidates[self.rng.below(candidates.len() as u64) as usize];
                let lo = self.rng.below(96) as i64;
                let hi = if *k == DeviceKind::Drum {
                    lo
                } else {
                    lo + self.rng.below(24) as i64
                };
                Some(Cmd::DeviceZoneAdd {
                    track_id: t.clone(),
                    device_id: d.clone(),
                    zone_id: Self::fresh("zn", &mut self.next_zone),
                    source_id: format!("{:064x}", self.rng.next_u64()),
                    root_pitch: Num::int(lo),
                    lo_pitch: Num::int(lo),
                    hi_pitch: Num::int(hi),
                    // Sometimes defaulted, sometimes explicit, so the inverse
                    // is exercised in both shapes.
                    gain_db: (self.rng.below(2) == 1)
                        .then(|| Num::int(0 - self.rng.below(7) as i64)),
                    pan: (self.rng.below(2) == 1).then(|| Num::int(0)),
                })
            }
            2 => {
                if zones.is_empty() {
                    return None;
                }
                let (t, d, z) = zones[self.rng.below(zones.len() as u64) as usize].clone();
                Some(Cmd::DeviceZoneRemove {
                    track_id: t,
                    device_id: d,
                    zone_id: z,
                })
            }
            3 => {
                if devices.is_empty() {
                    return None;
                }
                let (t, d, _) = devices[self.rng.below(devices.len() as u64) as usize].clone();
                Some(Cmd::DeviceRemove {
                    track_id: t,
                    device_id: d,
                })
            }
            // A `track.device.<id>.<key>` lane — the lane class whose restore
            // ordering `track.remove` gets wrong if devices are not rebuilt
            // BEFORE the automation loop. One roll in eight authors on a
            // NEVER-existed device id: forward-legal since the existence
            // widening (the loud gate is the render compile), and generating
            // it keeps that chosen behavior inside the property net — undo,
            // redo, replay, and checkpoint round-trips all see such lanes.
            4 => {
                let key = timeline_core::model::DEVICE_PARAM_KEYS
                    [self.rng.below(timeline_core::model::DEVICE_PARAM_KEYS.len() as u64) as usize];
                if self.rng.below(8) == 0 {
                    let ghost = Self::fresh("ghost", &mut self.next_device);
                    return Some(Cmd::AutopointAdd {
                        track_id,
                        target: ParamRef::parse(&format!("track.device.{ghost}.{key}")).ok()?,
                        point_id: Self::fresh("ap", &mut self.next_point),
                        position_ticks: self.tick(),
                        value: Num::int(self.rng.below(9) as i64 - 4),
                    });
                }
                let mine: Vec<_> = devices.iter().filter(|(t, _, _)| *t == track_id).collect();
                if mine.is_empty() {
                    return None;
                }
                let (_, d, _) = mine[self.rng.below(mine.len() as u64) as usize];
                Some(Cmd::AutopointAdd {
                    track_id,
                    target: ParamRef::parse(&format!("track.device.{d}.{key}")).ok()?,
                    point_id: Self::fresh("ap", &mut self.next_point),
                    position_ticks: self.tick(),
                    value: Num::int(self.rng.below(9) as i64 - 4),
                })
            }
            // ---- E5 insert chain ----
            5 => Some(Cmd::FxAdd {
                target: NodeRef::Track(track_id),
                fx_id: Self::fresh("fx", &mut self.next_fx),
                kind: match self.rng.below(9) {
                    0 => FxKind::Eq,
                    1 => FxKind::Compressor,
                    2 => FxKind::Gate,
                    3 => FxKind::Delay,
                    4 => FxKind::Reverb,
                    5 => FxKind::Saturator,
                    6 => FxKind::Chorus,
                    7 => FxKind::Utility,
                    _ => FxKind::Limiter,
                },
            }),
            6 => {
                if track_fx.is_empty() {
                    return None;
                }
                let (t, f) = track_fx[self.rng.below(track_fx.len() as u64) as usize].clone();
                let key = timeline_core::model::FX_PARAM_KEYS
                    [self.rng.below(timeline_core::model::FX_PARAM_KEYS.len() as u64) as usize];
                Some(Cmd::FxParamSet {
                    target: NodeRef::Track(t),
                    fx_id: f,
                    key: key.to_string(),
                    value: Num::int(self.rng.below(5) as i64),
                })
            }
            7 => {
                if track_fx.is_empty() {
                    return None;
                }
                let (t, f) = track_fx[self.rng.below(track_fx.len() as u64) as usize].clone();
                Some(Cmd::FxRemove {
                    target: NodeRef::Track(t),
                    fx_id: f,
                })
            }
            8 => {
                let mine: Vec<_> = track_fx.iter().filter(|(t, _)| *t == track_id).collect();
                if mine.is_empty() {
                    return None;
                }
                let (_, f) = mine[self.rng.below(mine.len() as u64) as usize];
                let key = timeline_core::model::FX_PARAM_KEYS
                    [self.rng.below(timeline_core::model::FX_PARAM_KEYS.len() as u64) as usize];
                Some(Cmd::AutopointAdd {
                    track_id,
                    target: ParamRef::parse(&format!("track.fx.{f}.{key}")).ok()?,
                    point_id: Self::fresh("ap", &mut self.next_point),
                    position_ticks: self.tick(),
                    value: Num::int(self.rng.below(5) as i64),
                })
            }
            // ---- the removes ----
            //
            // `track.remove` refuses a track that still holds clips, so aim at
            // an empty one; otherwise the branch would be a permanent reject
            // and the family would stay unreachable in practice.
            9 => {
                let empty: Vec<&String> = project
                    .tracks
                    .iter()
                    .filter(|t| t.clips.is_empty())
                    .map(|t| &t.id)
                    .collect();
                if empty.is_empty() {
                    return None;
                }
                Some(Cmd::TrackRemove {
                    track_id: empty[self.rng.below(empty.len() as u64) as usize].clone(),
                })
            }
            10 => {
                let clips: Vec<String> = project
                    .tracks
                    .iter()
                    .flat_map(|t| t.clips.iter().map(|c| c.id.clone()))
                    .collect();
                if clips.is_empty() {
                    return None;
                }
                Some(Cmd::ClipRemove {
                    clip_id: clips[self.rng.below(clips.len() as u64) as usize].clone(),
                })
            }
            11 => {
                // autopoint.remove / autolane.clear over EVERY lane class, not
                // just the two legacy ones — and PREFER a DEAD lane when the
                // track has one. `device.remove`/`fx.remove`/`route.node.remove`/
                // `route.disconnect` all keep lanes referencing the removed
                // object, and the inverse of removing such a stray point is an
                // `autopoint.add` on the dead path. That inverse was refused
                // for months (the orphaned-autopoint bug): the generator could
                // technically reach the ordering but rarely did, so the
                // property suite never saw it. The bias makes the ordering
                // COMMON, and `the_conductor_reaches_every_destructive_command_family`
                // asserts it is actually exercised.
                let lanes = project.tracks[ti].automation.iter_lanes();
                if lanes.is_empty() {
                    return None;
                }
                let dead: Vec<usize> = (0..lanes.len())
                    .filter(|&i| lane_is_dead(project, ti, &lanes[i].0))
                    .collect();
                let li = if !dead.is_empty() && self.rng.below(2) == 0 {
                    dead[self.rng.below(dead.len() as u64) as usize]
                } else {
                    self.rng.below(lanes.len() as u64) as usize
                };
                let (target, points) = &lanes[li];
                if self.rng.below(2) == 0 {
                    Some(Cmd::AutolaneClear {
                        track_id,
                        target: target.clone(),
                    })
                } else {
                    let p = &points[self.rng.below(points.len() as u64) as usize];
                    Some(Cmd::AutopointRemove {
                        track_id,
                        target: target.clone(),
                        point_id: p.id.clone(),
                    })
                }
            }
            // ---- the strip state `track_restore_sequence` has to carry ----
            12 => Some(Cmd::MixPan {
                track_id,
                pan: Num::int(self.rng.below(3) as i64 - 1),
            }),
            13 => Some(Cmd::MixSend {
                track_id,
                bus: if self.rng.below(2) == 1 {
                    timeline_core::cmd::SendBus::A
                } else {
                    timeline_core::cmd::SendBus::B
                },
                amount: Num::int(self.rng.below(2) as i64),
            }),
            14 => Some(match self.rng.below(3) {
                0 => Cmd::TrackSolo {
                    track_id,
                    soloed: self.rng.below(2) == 1,
                },
                1 => Cmd::TrackArm {
                    track_id,
                    armed: self.rng.below(2) == 1,
                },
                _ => Cmd::TrackSetHeight {
                    track_id,
                    height_px: 24 + self.rng.below(377) as u32,
                },
            }),
            15 => Some(Cmd::TrackReorder {
                track_id,
                new_index: self.rng.below(project.tracks.len() as u64) as u32,
            }),
            // The L8 phase anchor: the OTHER sub-state `clip.remove` dropped.
            16 => {
                let clips: Vec<String> = project
                    .tracks
                    .iter()
                    .flat_map(|t| t.clips.iter().map(|c| c.id.clone()))
                    .collect();
                if clips.is_empty() {
                    return None;
                }
                Some(Cmd::ClipPhaseAnchorSet {
                    clip_id: clips[self.rng.below(clips.len() as u64) as usize].clone(),
                    anchor_ticks: self.tick(),
                })
            }
            // ---- routing graph. Edges are only ever drawn track -> bus,
            // track -> master or bus -> master, so a generated graph is
            // acyclic BY CONSTRUCTION and `route.connect`'s cycle rejection is
            // never the reason a candidate is skipped.
            _ => {
                let nodes: Vec<String> =
                    project.routing.nodes.iter().map(|n| n.id.clone()).collect();
                let edges: Vec<String> =
                    project.routing.edges.iter().map(|e| e.id.clone()).collect();
                match self.rng.below(5) {
                    0 => Some(Cmd::RouteNodeAdd {
                        node_id: Self::fresh("bus", &mut self.next_node),
                        kind: if self.rng.below(2) == 1 {
                            timeline_core::routing::NodeKind::Bus
                        } else {
                            timeline_core::routing::NodeKind::Group
                        },
                        name: "Bus".into(),
                    }),
                    // The node fader. Joins the generative set the day it
                    // ships, so `single_command_inverse_restores_prestate`
                    // covers its self-inverse and `route.node.remove`'s
                    // multi-inverse is exercised on nodes with a NON-DEFAULT
                    // fader (the sub-state its undo would otherwise drop).
                    4 => {
                        if nodes.is_empty() {
                            return None;
                        }
                        Some(Cmd::RouteNodeSet {
                            node_id: nodes[self.rng.below(nodes.len() as u64) as usize].clone(),
                            gain_db: self.gain(),
                        })
                    }
                    1 => {
                        let to = if nodes.is_empty() || self.rng.below(2) == 0 {
                            NodeRef::Master
                        } else {
                            NodeRef::Node(nodes[self.rng.below(nodes.len() as u64) as usize].clone())
                        };
                        Some(Cmd::RouteConnect {
                            edge_id: Self::fresh("edg", &mut self.next_edge),
                            from: NodeRef::Track(track_id),
                            to,
                            level: Num::int(self.rng.below(3) as i64),
                            tap: if self.rng.below(2) == 1 {
                                timeline_core::routing::Tap::Pre
                            } else {
                                timeline_core::routing::Tap::Post
                            },
                        })
                    }
                    2 => {
                        if edges.is_empty() {
                            return None;
                        }
                        Some(Cmd::RouteDisconnect {
                            edge_id: edges[self.rng.below(edges.len() as u64) as usize].clone(),
                        })
                    }
                    _ => {
                        if nodes.is_empty() {
                            return None;
                        }
                        Some(Cmd::RouteNodeRemove {
                            node_id: nodes[self.rng.below(nodes.len() as u64) as usize].clone(),
                        })
                    }
                }
            }
        }
    }
}

/// Build a Session by applying up to `steps` legal commands (rejects skipped).
/// Returns (session, applied_commands, meta_counter).
pub fn build_random(seed: u64, steps: usize) -> (Session, Vec<Cmd>, u64) {
    let mut c = Conductor::new(seed);
    let project = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    let mut session = Session::new(project);
    let mut applied = Vec::new();
    let mut n = 1u64;
    let mut i = 0;
    while applied.len() < steps && i < steps * 3 {
        i += 1;
        let cmd = c.gen(session.project());
        let m = user_meta(n);
        match session.submit(m, cmd.clone()) {
            Ok(sub) if !sub.duplicate => {
                n += 1;
                applied.push(cmd);
            }
            _ => {}
        }
    }
    (session, applied, n)
}
