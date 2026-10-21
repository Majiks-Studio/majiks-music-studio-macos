//! The render-side half of the automation generalization (design §5.2).
//!
//! Before E0, a new automatable parameter needed FOUR coordinated changes: a
//! new `AutoTarget` variant, a new lane FIELD on `RtTrack`, a new atomic, and a
//! catalog change. These tests pin the property that replaced it: `RtTrack`
//! carries an indexed, preallocated lane table resolved at compile time, so an
//! arbitrary ParamRef is representable with no render-struct change at all.
//!
//! RT rules being defended here (all four are absolute):
//!   - no alloc / lock / sort / lookup on the audio thread → the table is dense
//!     and indexed, cursors live in a fixed-size array on the `Strip`, and the
//!     topological sort happens in `compile`
//!   - state advances per FRAME → unchanged; this only changes where lanes live
//!
//! ⚠️ **Why the stand-in paths here are all renderable ones.** These tests used
//! `track.eq.2.gain`, `bus.reverb.gain` and `master.gain` as throwaway "some
//! arbitrary ParamRef" values. `build_lane_index` now REFUSES a path no reader
//! exists for (`rt::lane_has_reader`), because handing a dense slot and a live
//! cursor to a path nothing reads is exactly how `track.send.a.level`
//! automation shipped silently inert. The property under test is unchanged —
//! an arbitrary ParamRef becomes a lane with no render-struct change — so the
//! stand-ins are now paths this build can actually render. **Do not swap them
//! back to unrenderable ones to "broaden coverage"; that coverage was the bug.**

use std::collections::HashMap;
use std::sync::Arc;

use render::automation::{AutomationStore, CurveKind, RawPoint, TRACK_PAN, TRACK_VOLUME};
use render::compile::{compile_session_full, DeclickPolicy};
use render::media::AudioBuf;
use render::rt::{LANE_PAN, LANE_VOLUME, MAX_TRACK_LANES};
use render::warp::WarpOverlay;
use timeline_core::cmd::Cmd;
use timeline_core::model::DeviceKind;
use timeline_core::{Bpm, Project, TempoMap, Track};

/// Give a track a synth so its `track.device.<id>.<key>` lanes RESOLVE.
///
/// ⚠️ Since the dangling-lane sweep, a device lane whose id resolves to
/// nothing on the authoring track is REFUSED at compile (it used to get a
/// dense slot nothing reads — the inert-lane defect). These tests pin slot
/// TABLE properties, not the refusal, so their stand-in paths must name a
/// device that exists. The refusal itself is pinned in
/// `render/tests/inert_lanes.rs`.
fn add_synth_device(p: &mut Project, track: &str, device: &str) {
    p.apply_cmd(&Cmd::DeviceAdd {
        track_id: track.into(),
        device_id: device.into(),
        kind: DeviceKind::Synth,
    })
    .expect("device.add");
}

fn project(tracks: &[&str]) -> Project {
    let mut p = Project::new(48_000, TempoMap::single(Bpm::from_int(120).unwrap()));
    for t in tracks {
        p.tracks.push(Track::new(*t, *t));
    }
    p
}

fn sources() -> HashMap<String, Arc<AudioBuf>> {
    HashMap::new()
}

fn point(tick: u64, value: f32) -> RawPoint {
    RawPoint {
        tick,
        value,
        curve: CurveKind::Linear,
    }
}

fn compile(p: &Project, a: &AutomationStore) -> Box<render::rt::RtSession> {
    compile_session_full(
        p,
        &sources(),
        &WarpOverlay::new(),
        a,
        64,
        DeclickPolicy::None,
    )
    .expect("compiles")
}

#[test]
fn volume_and_pan_keep_fixed_slots_even_when_unused() {
    let p = project(&["t1"]);
    let s = compile(&p, &AutomationStore::new());
    assert_eq!(s.lane_index.get(TRACK_VOLUME), Some(&LANE_VOLUME));
    assert_eq!(s.lane_index.get(TRACK_PAN), Some(&LANE_PAN));
    assert_eq!(s.tracks[0].lanes.len(), 2, "the two fixed slots always exist");
    assert!(s.tracks[0].lane(LANE_VOLUME).is_none());
    assert!(s.tracks[0].lane(LANE_PAN).is_none());
}

#[test]
fn an_arbitrary_paramref_becomes_a_lane_with_no_render_struct_change() {
    // This is the whole point of §5.2: E2 automates a device parameter that did
    // not exist when this test was written, and nothing in `render` changes.
    let mut p = project(&["t1"]);
    add_synth_device(&mut p, "t1", "01J8XZ");
    let mut a = AutomationStore::new();
    a.add_point_path("t1", "track.device.01J8XZ.cutoff", point(0, 200.0));
    a.add_point_path("t1", "track.device.01J8XZ.cutoff", point(480, 8000.0));
    a.add_point_path("t1", "track.send.a.level", point(0, 0.4));
    a.add_point_path("t1", TRACK_VOLUME, point(0, -3.0));

    let s = compile(&p, &a);
    let cutoff = s.lane_index["track.device.01J8XZ.cutoff"];
    let send = s.lane_index["track.send.a.level"];
    assert!(cutoff >= 2 && send >= 2, "new lanes get slots past the fixed two");
    assert_ne!(cutoff, send);
    assert_eq!(s.tracks[0].lanes.len(), 4);

    // The lane is baked and evaluable exactly like volume/pan.
    let lane = s.tracks[0].lane(cutoff).expect("device lane baked");
    let mut cursor = 0usize;
    assert_eq!(lane.value_at(0, &mut cursor), 200.0);
    let mid = lane.value_at(240 * 2, &mut cursor); // 480 ticks at 120bpm/48k
    assert!(mid > 200.0 && mid < 8000.0, "interpolating: {mid}");

    // And volume still resolves through its fixed slot.
    assert!(s.tracks[0].lane(LANE_VOLUME).is_some());
}

#[test]
fn the_slot_table_is_dense_and_identical_on_every_track() {
    let p = project(&["t1", "t2", "t3"]);
    let mut a = AutomationStore::new();
    a.add_point_path("t2", "track.send.a.level", point(0, 1.0));
    a.add_point_path("t3", "track.send.b.level", point(0, 0.5));
    let s = compile(&p, &a);

    let n = s.tracks[0].lanes.len();
    assert_eq!(n, 4, "2 fixed + 2 discovered");
    for t in s.tracks.iter() {
        assert_eq!(t.lanes.len(), n, "a slot index must mean the same on every track");
    }
    let slots: Vec<usize> = s.lane_index.values().copied().collect();
    let mut sorted = slots.clone();
    sorted.sort_unstable();
    assert_eq!(sorted, (0..n).collect::<Vec<_>>(), "slots must be dense");

    // Only the track that authored a lane has it baked.
    let rev = s.lane_index["track.send.a.level"];
    assert!(s.tracks[1].lane(rev).is_some());
    assert!(s.tracks[0].lane(rev).is_none());
}

#[test]
fn slot_assignment_is_deterministic_regardless_of_insertion_order() {
    // A bounce must not depend on the order the host happened to add points.
    let paths = [
        "track.device.zzz.cutoff",
        "track.device.zzz.release",
        "track.send.b.level",
        "track.send.a.level",
    ];
    let build = |order: &[usize]| {
        let mut a = AutomationStore::new();
        for i in order {
            a.add_point_path("t1", paths[*i], point(0, 1.0));
        }
        let mut p = project(&["t1"]);
        add_synth_device(&mut p, "t1", "zzz");
        let s = compile(&p, &a);
        s.lane_index
            .iter()
            .map(|(k, v)| (k.clone(), *v))
            .collect::<Vec<_>>()
    };
    let a = build(&[0, 1, 2, 3]);
    let b = build(&[3, 2, 1, 0]);
    let c = build(&[2, 0, 3, 1]);
    assert_eq!(a, b);
    assert_eq!(a, c);
}

#[test]
fn exceeding_the_lane_capacity_is_a_control_side_error_not_an_rt_surprise() {
    // The cursor table on the Strip is fixed-size so the audio thread never
    // allocates. Overflow must therefore fail at COMPILE time, loudly.
    //
    // Every path RESOLVES (one synth per track, all ten keys per device):
    // 4 tracks x 10 keys = 40 dense paths + the 2 fixed slots > 32, so the
    // capacity error fires — not the dangling-lane refusal, which would let
    // this test go green without ever reaching the capacity check.
    let mut p = project(&["t1", "t2", "t3", "t4"]);
    let mut a = AutomationStore::new();
    for (i, t) in ["t1", "t2", "t3", "t4"].iter().enumerate() {
        add_synth_device(&mut p, t, &format!("d{i}"));
        for key in render::dsp::instrument::INSTRUMENT_PARAM_KEYS {
            a.add_point_path(t, &format!("track.device.d{i}.{key}"), point(0, 1.0));
        }
    }
    let err = match compile_session_full(
        &p,
        &sources(),
        &WarpOverlay::new(),
        &a,
        64,
        DeclickPolicy::None,
    ) {
        Err(e) => e,
        Ok(_) => panic!("must refuse to compile past the lane capacity"),
    };
    assert!(err.contains("automation lanes"), "{err}");
}

#[test]
fn a_volume_and_pan_only_project_compiles_to_exactly_the_v1_table() {
    // Regression guard for bounce parity: adding the general table must not
    // change what a v1-shaped project compiles to.
    let p = project(&["t1"]);
    let mut a = AutomationStore::new();
    a.add_point_path("t1", TRACK_VOLUME, point(0, 0.0));
    a.add_point_path("t1", TRACK_VOLUME, point(48_000, -12.0));
    a.add_point_path("t1", TRACK_PAN, point(0, -1.0));
    let s = compile(&p, &a);
    assert_eq!(s.tracks[0].lanes.len(), 2);
    assert_eq!(s.lane_index.len(), 2);
    let vol = s.tracks[0].lane(LANE_VOLUME).expect("volume");
    let mut c = 0;
    assert_eq!(vol.value_at(0, &mut c), 0.0);
    // tick 48000 bakes to a frame through the tempo map; the end value holds
    // past the last point either way.
    assert_eq!(vol.value_at(10_000_000, &mut c), -12.0);
    let pan = s.tracks[0].lane(LANE_PAN).expect("pan");
    let mut c = 0;
    assert_eq!(pan.value_at(0, &mut c), -1.0);
}
