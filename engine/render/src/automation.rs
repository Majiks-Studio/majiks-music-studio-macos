//! Automation lanes as the RENDER side sees them: frame-positioned points
//! with a segment shape, evaluated per frame with a cheap cursor.
//!
//! Catalog v1 (`autopoint.add`) defines targets `track.volume` (dB) and
//! `track.pan` (-1..1) with tick positions and no shape field; the compile
//! step bakes ticks to frames through the tempo map, and this module
//! supports Linear plus a power-curve segment shape so L1 can add curved
//! segments to the catalog without a render change (flagged in the L2
//! report as a contract question, not silently added to the catalog).
//!
//! Evaluation rules:
//! - before the first point: the first point's value
//! - after the last point: the last point's value
//! - between points: the LEFT point's `curve` shapes the segment
//! - evaluation is per frame and stateless given (lane, frame): the cursor
//!   is a pure accelerator, so output is chunk-size independent and seeks
//!   (backward jumps) just re-search
//!
//! Sample-accuracy contract: a step (two points on adjacent frames, or
//! `Step`) changes the evaluated target exactly at its frame. Zipper
//! protection is NOT this module's job: the strip glides toward evaluated
//! targets through the declick slew (see `strip.rs`), which turns steps
//! into bounded-slope ramps (the 10 Hz square proof exercises this).

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CurveKind {
    /// Hold the left value until the next point.
    Step,
    Linear,
    /// value = left + (right-left) * t^k. k in (0, 8]; 1.0 equals Linear.
    Pow { k: f32 },
}

#[derive(Debug, Clone, Copy)]
pub struct AutoPoint {
    pub frame: u64,
    pub value: f32,
    pub curve: CurveKind,
}

/// Points sorted by frame, frames unique (compile guarantees both).
#[derive(Debug, Clone)]
pub struct AutoLane {
    points: Box<[AutoPoint]>,
}

impl AutoLane {
    /// Build from points; sorts and de-duplicates (last write wins per
    /// frame). Returns None for an empty set.
    pub fn new(mut points: Vec<AutoPoint>) -> Option<Self> {
        if points.is_empty() {
            return None;
        }
        points.sort_by_key(|p| p.frame);
        let mut dedup: Vec<AutoPoint> = Vec::with_capacity(points.len());
        for p in points {
            if let Some(last) = dedup.last_mut() {
                if last.frame == p.frame {
                    *last = p;
                    continue;
                }
            }
            dedup.push(p);
        }
        Some(Self {
            points: dedup.into_boxed_slice(),
        })
    }

    pub fn points(&self) -> &[AutoPoint] {
        &self.points
    }

    /// Evaluate at `frame`. `cursor` accelerates sequential playback; any
    /// discontinuity (seek, loop fold, session swap) self-heals via
    /// re-search. Allocation-free.
    #[inline]
    pub fn value_at(&self, frame: u64, cursor: &mut usize) -> f32 {
        let pts = &self.points;
        let n = pts.len();
        debug_assert!(n > 0);
        if *cursor >= n {
            *cursor = n - 1;
        }
        // Re-anchor if the cursor is ahead of the frame (backward jump).
        if pts[*cursor].frame > frame {
            *cursor = match pts.binary_search_by_key(&frame, |p| p.frame) {
                Ok(i) => i,
                Err(0) => 0,
                Err(i) => i - 1,
            };
        }
        // Advance while the next point starts at or before the frame.
        while *cursor + 1 < n && pts[*cursor + 1].frame <= frame {
            *cursor += 1;
        }
        let left = pts[*cursor];
        if frame <= left.frame {
            // Before the first point (cursor 0, frame < first) or exactly on
            // a point.
            if frame < left.frame {
                return pts[0].value;
            }
            return left.value;
        }
        if *cursor + 1 >= n {
            return left.value;
        }
        let right = pts[*cursor + 1];
        match left.curve {
            CurveKind::Step => left.value,
            CurveKind::Linear => {
                let span = (right.frame - left.frame) as f32;
                let t = (frame - left.frame) as f32 / span;
                left.value + (right.value - left.value) * t
            }
            CurveKind::Pow { k } => {
                let span = (right.frame - left.frame) as f32;
                let t = (frame - left.frame) as f32 / span;
                let shaped = t.powf(k.clamp(0.05, 8.0));
                left.value + (right.value - left.value) * shaped
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Control-side store
// ---------------------------------------------------------------------------

use std::collections::{BTreeMap, BTreeSet};
use timeline_core::TempoMap;

/// The two legacy lane paths. These strings are contract, not convenience:
/// they must match `timeline_core::paramref` byte for byte.
pub const TRACK_VOLUME: &str = "track.volume";
pub const TRACK_PAN: &str = "track.pan";

/// The two legacy FX send levels. Same contract rule as above: byte-identical
/// to what `ParamRefKind::TrackSendLevel` classifies and to what
/// `apply.rs::require_param_ref_on` accepts ("v1 has exactly two sends").
pub const TRACK_SEND_A_LEVEL: &str = "track.send.a.level";
pub const TRACK_SEND_B_LEVEL: &str = "track.send.b.level";

/// Which parameter a lane drives. Retained as a typed convenience for the two
/// lanes with a render fast path; it is NOT the addressing type any more — a
/// lane is addressed by its ParamRef path string, so E2/E4/E8 add parameters
/// without adding a variant here.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum AutoTarget {
    Volume,
    Pan,
}

impl AutoTarget {
    pub fn path(self) -> &'static str {
        match self {
            AutoTarget::Volume => TRACK_VOLUME,
            AutoTarget::Pan => TRACK_PAN,
        }
    }
}

/// A raw automation point as authored: tick position + value + segment
/// shape. Catalog v1 has no shape field, so commands default to Linear; the
/// store also accepts Step/Pow so L1 can extend the catalog without a render
/// change (flagged as a contract question in the L2 report).
#[derive(Debug, Clone, Copy)]
pub struct RawPoint {
    pub tick: u64,
    pub value: f32,
    pub curve: CurveKind,
}

/// Control-side automation: raw points keyed by (track_id, ParamRef path). The
/// compile step bakes each lane to frames through the tempo map and assigns it
/// a dense slot index. Owned by the host; never touched by the render thread.
///
/// `BTreeMap`, not `HashMap`: the compiled slot assignment is derived from key
/// order, and a bounce must not depend on hash seed.
#[derive(Debug, Clone, Default)]
pub struct AutomationStore {
    lanes: BTreeMap<(String, String), Vec<RawPoint>>,
}

impl AutomationStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_empty(&self) -> bool {
        self.lanes.values().all(|v| v.is_empty())
    }

    /// Add a point on any lane, addressed by its ParamRef path.
    pub fn add_point_path(&mut self, track_id: &str, path: &str, point: RawPoint) {
        self.lanes
            .entry((track_id.to_string(), path.to_string()))
            .or_default()
            .push(point);
    }

    pub fn remove_at_path(&mut self, track_id: &str, path: &str, tick: u64) {
        if let Some(v) = self
            .lanes
            .get_mut(&(track_id.to_string(), path.to_string()))
        {
            v.retain(|p| p.tick != tick);
        }
    }

    pub fn clear_lane_path(&mut self, track_id: &str, path: &str) {
        self.lanes.remove(&(track_id.to_string(), path.to_string()));
    }

    /// Add or replace a point by tick on a lane (last write per tick wins at
    /// bake time). Validation lives at the command layer.
    pub fn add_point(&mut self, track_id: &str, target: AutoTarget, point: RawPoint) {
        self.add_point_path(track_id, target.path(), point);
    }

    /// Remove all points at a tick on a lane (autopoint.remove support).
    pub fn remove_at(&mut self, track_id: &str, target: AutoTarget, tick: u64) {
        self.remove_at_path(track_id, target.path(), tick);
    }

    /// Clear a whole lane (autolane.clear support).
    pub fn clear_lane(&mut self, track_id: &str, target: AutoTarget) {
        self.clear_lane_path(track_id, target.path());
    }

    /// Every non-empty lane path in the store, deterministically ordered.
    /// `compile` uses this to build the session's slot assignment.
    pub fn lane_paths(&self) -> BTreeSet<&str> {
        self.lanes
            .iter()
            .filter(|(_, v)| !v.is_empty())
            .map(|((_, path), _)| path.as_str())
            .collect()
    }

    /// Every (track_id, path) pair with at least one point, in deterministic
    /// `BTreeMap` order. Feeds `compile::refuse_unreadable_lanes`.
    pub fn iter_lane_keys(&self) -> impl Iterator<Item = (&str, &str)> {
        self.lanes
            .iter()
            .filter(|(_, v)| !v.is_empty())
            .map(|((t, p), _)| (t.as_str(), p.as_str()))
    }

    /// Which tracks author a non-empty lane on `path`, in deterministic order.
    ///
    /// `compile` needs this so a refusal can name the tracks to clear, not just
    /// the parameter: `autolane.clear` is keyed by `{trackId, target}`, and a
    /// refusal that names only the target leaves the user hunting for which
    /// track carries it. An accurate error the user cannot act on is still a
    /// dead end.
    pub fn tracks_for_path(&self, path: &str) -> Vec<&str> {
        self.lanes
            .iter()
            .filter(|((_, p), v)| p == path && !v.is_empty())
            .map(|((t, _), _)| t.as_str())
            .collect()
    }

    pub fn bake_path(
        &self,
        track_id: &str,
        path: &str,
        tempo: &TempoMap,
        sample_rate: u32,
    ) -> Option<AutoLane> {
        let raw = self.lanes.get(&(track_id.to_string(), path.to_string()))?;
        if raw.is_empty() {
            return None;
        }
        let points = raw
            .iter()
            .map(|p| AutoPoint {
                frame: tempo.tick_to_frame(p.tick, sample_rate),
                value: p.value,
                curve: p.curve,
            })
            .collect();
        AutoLane::new(points)
    }

    fn bake(
        &self,
        track_id: &str,
        target: AutoTarget,
        tempo: &TempoMap,
        sample_rate: u32,
    ) -> Option<AutoLane> {
        self.bake_path(track_id, target.path(), tempo, sample_rate)
    }

    pub fn bake_volume(
        &self,
        track_id: &str,
        tempo: &TempoMap,
        sample_rate: u32,
    ) -> Option<AutoLane> {
        self.bake(track_id, AutoTarget::Volume, tempo, sample_rate)
    }

    pub fn bake_pan(
        &self,
        track_id: &str,
        tempo: &TempoMap,
        sample_rate: u32,
    ) -> Option<AutoLane> {
        self.bake(track_id, AutoTarget::Pan, tempo, sample_rate)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lane(points: &[(u64, f32)]) -> AutoLane {
        AutoLane::new(
            points
                .iter()
                .map(|(f, v)| AutoPoint {
                    frame: *f,
                    value: *v,
                    curve: CurveKind::Linear,
                })
                .collect(),
        )
        .unwrap()
    }

    #[test]
    fn holds_ends_and_lerps_between() {
        let l = lane(&[(100, 0.0), (200, 1.0)]);
        let mut c = 0;
        assert_eq!(l.value_at(0, &mut c), 0.0);
        assert_eq!(l.value_at(100, &mut c), 0.0);
        assert_eq!(l.value_at(150, &mut c), 0.5);
        assert_eq!(l.value_at(200, &mut c), 1.0);
        assert_eq!(l.value_at(9_999, &mut c), 1.0);
    }

    #[test]
    fn cursor_survives_backward_jumps() {
        let l = lane(&[(0, 0.0), (1_000, 1.0), (2_000, 0.0), (3_000, 1.0)]);
        let mut c = 0;
        // Play forward.
        for f in 0..3_500 {
            let _ = l.value_at(f, &mut c);
        }
        // Jump back (loop fold) and verify correctness immediately.
        assert_eq!(l.value_at(1_500, &mut c), 0.5);
        assert_eq!(l.value_at(500, &mut c), 0.5);
    }

    #[test]
    fn step_and_pow_shapes() {
        let l = AutoLane::new(vec![
            AutoPoint { frame: 0, value: 1.0, curve: CurveKind::Step },
            AutoPoint { frame: 100, value: 0.0, curve: CurveKind::Pow { k: 2.0 } },
            AutoPoint { frame: 200, value: 1.0, curve: CurveKind::Linear },
        ])
        .unwrap();
        let mut c = 0;
        assert_eq!(l.value_at(50, &mut c), 1.0, "step holds");
        assert_eq!(l.value_at(99, &mut c), 1.0, "step holds to the edge");
        assert_eq!(l.value_at(100, &mut c), 0.0, "lands exactly at the point");
        let mid = l.value_at(150, &mut c);
        assert!((mid - 0.25).abs() < 1e-6, "t^2 at t=0.5 is 0.25, got {mid}");
    }

    #[test]
    fn cursor_matches_fresh_search_everywhere() {
        let l = lane(&[(10, 0.1), (57, 0.9), (58, 0.2), (400, 0.7), (401, 0.7)]);
        let mut walk = 0;
        for f in 0..500 {
            let mut fresh = 0;
            assert_eq!(
                l.value_at(f, &mut walk),
                l.value_at(f, &mut fresh),
                "divergence at frame {f}"
            );
        }
    }
}
