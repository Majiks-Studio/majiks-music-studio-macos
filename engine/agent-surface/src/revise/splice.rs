//! `splice`: the client-side region splicer (pure PCM math, no io, unit-tested).
//!
//! P0-A locked this in (docs/evidence/p0a-repaint.md sections 5-6): raw repaint
//! output does NOT preserve audio outside the revised region (median residual
//! about -21 dBFS, never silence, plus a full-track loudness renormalization).
//! So the DAW must NEVER present raw repaint output outside the region. Commit =
//! splice the regenerated region into the ORIGINAL waveform with equal-power
//! crossfades placed INSIDE the region, which keeps the outside audio bit-exact
//! by construction and the seam at the unedited song's own boundary floor.
//!
//! Two shapes live here:
//!   - `splice_region`: one buffer, one region replacement (the "all-stems" /
//!     single-clip revise, and the per-stem clip splice for stem-scope).
//!   - the stem-scope null identity is proved by composition in the tests and
//!     the orchestrator: unscoped stems pass through UNCHANGED (null-preserve),
//!     only scoped stems are spliced, and the summed mix is bit-exact outside
//!     the region because every part is.
//!
//! The crossfade is equal-power (`g_out^2 + g_in^2 == 1`), default 20 ms, which
//! P0-A measured as the right default (fades barely move the click metric,
//! which content transients dominate, but spectral abruptness falls
//! monotonically with fade length; 50 ms is the escalation). 5 ms is the hard
//! declick floor (the DJ engine constant, restated in 01-DESIGN section 8).

/// Engine rate (48 kHz v1), for ms<->frame conversions in the splice defaults.
pub const RATE: u32 = 48_000;

/// The design default crossfade (01-DESIGN 3.2 step 5, P0-A section 9).
pub const DEFAULT_CROSSFADE_MS: f64 = 20.0;

/// The hard declick floor: no ramp shorter than this (01-DESIGN section 8, the
/// DJ 5 ms constant). A commit that would splice with a shorter ramp is clamped
/// up to this, never below.
pub const MIN_DECLICK_MS: f64 = 5.0;

/// Milliseconds -> whole frames at the engine rate (rounded, never below 1).
pub fn ms_to_frames(ms: f64) -> usize {
    ((ms / 1000.0) * RATE as f64).round().max(1.0) as usize
}

/// Frames -> milliseconds at the engine rate.
pub fn frames_to_ms(frames: usize) -> f64 {
    frames as f64 / RATE as f64 * 1000.0
}

/// Equal-power crossfade gains at phase `t` in [0, 1]. `t = 0` is all A
/// (outgoing), `t = 1` is all B (incoming); `g_a^2 + g_b^2 == 1` for every t.
#[inline]
pub fn equal_power_gains(t: f32) -> (f32, f32) {
    let t = t.clamp(0.0, 1.0);
    let angle = t * std::f32::consts::FRAC_PI_2;
    (angle.cos(), angle.sin())
}

/// Choose the actual crossfade length in frames for a region of `region_frames`
/// frames given a requested millisecond length. Clamped to the declick floor
/// below, and to `region_frames / 2` above (a crossfade can never exceed half
/// the region, or the two ramps would overlap).
pub fn crossfade_frames(requested_ms: f64, region_frames: usize) -> usize {
    let floor = ms_to_frames(MIN_DECLICK_MS);
    let want = ms_to_frames(requested_ms.max(MIN_DECLICK_MS)).max(floor);
    want.min(region_frames / 2).max(1.min(region_frames))
}

/// Splice `replacement` into `original` at `region_start`, with an equal-power
/// crossfade of `xfade` frames at BOTH boundaries, placed INSIDE the region.
///
/// Invariants (all asserted by the tests, and by construction here):
///   - `out.len() == original.len()` (repaint preserves region length; the
///     spliced asset is a same-length substitution, so timeline geometry is
///     untouched and the take.promote asset swap is sample-aligned).
///   - `out[i] == original[i]` bit-exactly for every `i` OUTSIDE
///     `[region_start, region_start + replacement.len())`. This is the P0-A
///     null-preserve rule.
///   - The two boundaries carry an equal-power ramp of `xfade` frames, so there
///     is no cut step: at the exact seams `out` equals the original sample, and
///     the middle of the region is the pure replacement.
///
/// `region_start + replacement.len()` must be `<= original.len()`; a replacement
/// that would read past the original is clamped to fit (never panics).
pub fn splice_region(
    original: &[[f32; 2]],
    replacement: &[[f32; 2]],
    region_start: usize,
    xfade: usize,
) -> Vec<[f32; 2]> {
    let mut out = original.to_vec();
    if replacement.is_empty() || region_start >= original.len() {
        return out;
    }
    let region_len = replacement.len().min(original.len() - region_start);
    // A crossfade can never exceed half the region (the ramps must not overlap).
    let xf = xfade.min(region_len / 2);
    let region_end = region_start + region_len;

    for k in 0..region_len {
        let i = region_start + k;
        let repl = replacement[k];
        let orig = original[i];
        let blended = if xf > 0 && k < xf {
            // Leading ramp: original -> replacement (t goes 0..1 across xf).
            let t = k as f32 / xf as f32;
            let (g_a, g_b) = equal_power_gains(t);
            [orig[0] * g_a + repl[0] * g_b, orig[1] * g_a + repl[1] * g_b]
        } else if xf > 0 && k >= region_len - xf {
            // Trailing ramp: replacement -> original (t goes 0..1 across xf).
            let t = (k - (region_len - xf)) as f32 / xf as f32;
            let (g_b, g_a) = equal_power_gains(t); // g_b fades replacement out, g_a fades original in
            [repl[0] * g_b + orig[0] * g_a, repl[1] * g_b + orig[1] * g_a]
        } else {
            repl
        };
        out[i] = blended;
        let _ = region_end;
    }
    out
}

/// The peak absolute per-sample step (max over channels of `|s[i+1] - s[i]|`)
/// within a window around `at` (+/- `half` frames). A hard cut shows up as a
/// near-full-scale step here; a declicked seam sits near the material's own
/// local slope. Used by the commit declick check.
pub fn max_adjacent_step(buf: &[[f32; 2]], at: usize, half: usize) -> f32 {
    if buf.len() < 2 {
        return 0.0;
    }
    let lo = at.saturating_sub(half).min(buf.len() - 1);
    let hi = (at + half).min(buf.len() - 1);
    let mut max = 0.0f32;
    for i in lo..hi {
        for ch in 0..2 {
            max = max.max((buf[i + 1][ch] - buf[i][ch]).abs());
        }
    }
    max
}

/// Peak and RMS of `a - b` over their overlap, in dBFS (the "null" residual).
/// `-inf` floors at -200. Mirrors `landing::residual_dbfs` so the whole engine
/// speaks one null metric; kept here so the splice math has no landing dep.
pub fn residual_dbfs(a: &[[f32; 2]], b: &[[f32; 2]]) -> (f64, f64) {
    let n = a.len().min(b.len());
    if n == 0 {
        return (-200.0, -200.0);
    }
    let mut peak = 0.0f64;
    let mut sum_sq = 0.0f64;
    for i in 0..n {
        for ch in 0..2 {
            let d = (a[i][ch] - b[i][ch]) as f64;
            peak = peak.max(d.abs());
            sum_sq += d * d;
        }
    }
    let rms = (sum_sq / (2 * n) as f64).sqrt();
    (lin_to_dbfs(peak), lin_to_dbfs(rms))
}

fn lin_to_dbfs(lin: f64) -> f64 {
    if lin > 0.0 {
        (20.0 * lin.log10()).max(-200.0)
    } else {
        -200.0
    }
}

/// Sum a set of stems frame by frame into one mix (the null-test reference for
/// stem-scope: the mix must be bit-exact outside the region because every stem
/// is). Length is the max stem length; short stems contribute zeros past their
/// end.
pub fn sum_stems(stems: &[Vec<[f32; 2]>]) -> Vec<[f32; 2]> {
    let n = stems.iter().map(Vec::len).max().unwrap_or(0);
    let mut out = vec![[0.0f32; 2]; n];
    for stem in stems {
        for (i, f) in stem.iter().enumerate() {
            out[i][0] += f[0];
            out[i][1] += f[1];
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dc(v: f32, n: usize) -> Vec<[f32; 2]> {
        vec![[v, v]; n]
    }

    #[test]
    fn equal_power_holds_the_power_law() {
        for k in 0..=100 {
            let t = k as f32 / 100.0;
            let (a, b) = equal_power_gains(t);
            assert!((a * a + b * b - 1.0).abs() < 1e-5, "t={t}: {a}^2+{b}^2 != 1");
        }
        // Endpoints are exact all-A / all-B.
        let (a0, b0) = equal_power_gains(0.0);
        assert!((a0 - 1.0).abs() < 1e-6 && b0.abs() < 1e-6);
        let (a1, b1) = equal_power_gains(1.0);
        assert!(a1.abs() < 1e-6 && (b1 - 1.0).abs() < 1e-6);
    }

    #[test]
    fn splice_preserves_everything_outside_the_region_bit_exactly() {
        let original = dc(0.3, 2000);
        let replacement = dc(-0.4, 400);
        let region_start = 800;
        let xf = ms_to_frames(DEFAULT_CROSSFADE_MS); // 960 frames -> clamped to region/2
        let out = splice_region(&original, &replacement, region_start, xf);
        assert_eq!(out.len(), original.len(), "length is preserved");
        // Outside [800, 1200): bit-exact original (the P0-A null-preserve rule).
        for i in 0..original.len() {
            if i < region_start || i >= region_start + replacement.len() {
                assert_eq!(out[i], original[i], "sample {i} outside region changed");
            }
        }
    }

    #[test]
    fn splice_middle_is_the_pure_replacement() {
        let original = dc(0.3, 2000);
        let replacement = dc(-0.4, 400);
        let region_start = 800;
        let xf = 100; // < region/2 (200), so a pure middle exists
        let out = splice_region(&original, &replacement, region_start, xf);
        // Middle of the region (past the leading ramp, before the trailing one).
        for k in xf..(replacement.len() - xf) {
            assert_eq!(out[region_start + k], replacement[k], "middle sample {k} not pure replacement");
        }
    }

    #[test]
    fn equal_power_splice_kills_the_cut_step() {
        // original +0.1, replacement -0.1: a HARD cut is a 0.2 step at each seam.
        let original = dc(0.1, 4000);
        let replacement = dc(-0.1, 1000);
        let region_start = 1500;
        let xf = ms_to_frames(DEFAULT_CROSSFADE_MS); // 960 frames

        // Hard cut (xf = 0) for the contrast baseline.
        let hard = splice_region(&original, &replacement, region_start, 0);
        let hard_step = max_adjacent_step(&hard, region_start, 4);
        assert!(hard_step > 0.15, "hard cut should step ~0.2, got {hard_step}");

        // Declicked splice: no seam step anywhere near the cut size.
        let soft = splice_region(&original, &replacement, region_start, xf);
        let start_step = max_adjacent_step(&soft, region_start, xf + 4);
        let end_step = max_adjacent_step(&soft, region_start + replacement.len(), xf + 4);
        assert!(start_step < 0.01, "declicked start seam still steps {start_step}");
        assert!(end_step < 0.01, "declicked end seam still steps {end_step}");
        // And the ramp clears the 5 ms declick floor.
        assert!(frames_to_ms(xf) >= MIN_DECLICK_MS, "ramp under the declick floor");
    }

    #[test]
    fn crossfade_frames_respects_the_declick_floor_and_region_cap() {
        // A tiny requested fade is lifted to the 5 ms floor.
        let f = crossfade_frames(1.0, 100_000);
        assert!(frames_to_ms(f) >= MIN_DECLICK_MS - 1e-9, "floor not enforced: {}", frames_to_ms(f));
        // A fade longer than half the region is capped to half the region.
        let f2 = crossfade_frames(1000.0, 400);
        assert!(f2 <= 200, "not capped to region/2: {f2}");
    }

    #[test]
    fn stem_scope_null_preserves_unscoped_stems_and_the_outside_mix() {
        // Four stems that sum to a mix. Scope = {drums(1), other(3)}.
        let n = 3000;
        let vocals = dc(0.05, n);
        let drums = dc(0.10, n);
        let bass = dc(0.07, n);
        let other = dc(0.03, n);
        let orig_mix = sum_stems(&[vocals.clone(), drums.clone(), bass.clone(), other.clone()]);

        let region_start = 1000;
        let region_len = 600;
        let xf = 120;
        // Regenerated scoped-stem region content (different from the originals).
        let new_drums_region = dc(-0.20, region_len);
        let new_other_region = dc(0.12, region_len);

        // Splice ONLY the scoped stems; vocals + bass pass through UNCHANGED.
        let new_drums = splice_region(&drums, &new_drums_region, region_start, xf);
        let new_other = splice_region(&other, &new_other_region, region_start, xf);
        let new_mix = sum_stems(&[vocals.clone(), new_drums.clone(), bass.clone(), new_other.clone()]);

        // Unscoped stems are byte-identical everywhere (null-preserve).
        assert_eq!(new_mix.len(), orig_mix.len());
        // Outside [1000, 1600): the mix is bit-exact (every part is).
        for i in 0..n {
            if i < region_start || i >= region_start + region_len {
                assert_eq!(new_mix[i], orig_mix[i], "mix sample {i} outside region changed");
            }
        }
        // Inside the pure middle, the mix reflects the scoped swap:
        // vocals+bass unchanged (0.05+0.07=0.12), drums+other swapped (-0.20+0.12=-0.08).
        let mid = region_start + region_len / 2;
        assert!((new_mix[mid][0] - (0.12 + -0.08)).abs() < 1e-5, "middle mix wrong: {}", new_mix[mid][0]);
    }

    #[test]
    fn residual_of_identical_buffers_floors() {
        let a = dc(0.3, 1000);
        let (p, r) = residual_dbfs(&a, &a);
        assert_eq!(p, -200.0);
        assert_eq!(r, -200.0);
    }
}
