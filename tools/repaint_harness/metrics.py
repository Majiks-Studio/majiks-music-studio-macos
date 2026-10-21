"""Boundary and null-test metrics for repaint evaluation.

numpy only. No torch, no librosa, no audio I/O.

All metrics take float audio shaped (frames,) or (frames, channels) and a
sample rate. Multichannel input is averaged to mono first; a splice click
or level step survives the mixdown.

Metric definitions (reported in docs/evidence/p0a-repaint.md):
- rms_step_db: |RMS(window before boundary) - RMS(window after)| in dB.
  Measures level continuity. Musical content may legitimately step.
- click_ratio: max |first difference| in a small probe window centered on
  the boundary, divided by the median |first difference| over a wider
  context. A hard cut at a non-zero-crossing spikes this ratio; clean
  program material stays near the values measured at arbitrary positions.
- spectral_flux_zscore: L2 distance between unit-normalized magnitude
  spectra of the frames touching the boundary, z-scored against the same
  measure at random reference positions in the same signal. Answers "is
  this boundary any more spectrally abrupt than the song's own transitions".
- null_residual: level of (result - original) outside the edited region,
  raw and after a single optimal scalar gain, in dBFS.
"""

from __future__ import annotations

from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

__all__ = [
    "to_mono",
    "rms_db",
    "peak_db",
    "rms_step_db",
    "click_ratio",
    "spectral_flux_zscore",
    "null_residual",
    "boundary_metrics",
]

_EPS = 1e-12
_SILENCE_DB = -200.0


def to_mono(x: np.ndarray) -> np.ndarray:
    """Average channels to mono, float64."""
    if x.ndim == 1:
        return x.astype(np.float64, copy=False)
    if x.ndim == 2:
        return x.astype(np.float64, copy=False).mean(axis=1)
    raise ValueError(f"audio must be 1-D or 2-D, got shape {x.shape}")


def rms_db(x: np.ndarray) -> float:
    """RMS level in dBFS. Empty or silent input reports -200 dB."""
    x = to_mono(x)
    if x.size == 0:
        return _SILENCE_DB
    rms = float(np.sqrt(np.mean(np.square(x))))
    if rms <= 0.0:
        return _SILENCE_DB
    return max(_SILENCE_DB, 20.0 * np.log10(rms))


def peak_db(x: np.ndarray) -> float:
    """Absolute peak in dBFS. Empty or silent input reports -200 dB."""
    x = to_mono(x)
    if x.size == 0:
        return _SILENCE_DB
    peak = float(np.max(np.abs(x)))
    if peak <= 0.0:
        return _SILENCE_DB
    return max(_SILENCE_DB, 20.0 * np.log10(peak))


def _window(
    x: np.ndarray, center: int, half_width: int
) -> np.ndarray:
    lo = max(0, center - half_width)
    hi = min(x.shape[0], center + half_width)
    return x[lo:hi]


def rms_step_db(y: np.ndarray, boundary: int, sample_rate: int, win_ms: float = 50.0) -> float:
    """Absolute RMS level step across the boundary, in dB."""
    y = to_mono(y)
    win = max(1, int(round(win_ms * 1e-3 * sample_rate)))
    if boundary - win < 0 or boundary + win > y.shape[0]:
        raise ValueError(
            f"boundary {boundary} with {win}-sample windows leaves the signal"
        )
    before = rms_db(y[boundary - win : boundary])
    after = rms_db(y[boundary : boundary + win])
    return abs(after - before)


def click_ratio(
    y: np.ndarray,
    boundary: int,
    sample_rate: int,
    probe_ms: float = 2.0,
    context_ms: float = 500.0,
) -> float:
    """Discontinuity spike ratio at the boundary (see module docstring)."""
    y = to_mono(y)
    if not (0 < boundary < y.shape[0]):
        raise ValueError(f"boundary {boundary} outside signal of {y.shape[0]} frames")
    d = np.abs(np.diff(y))
    probe_half = max(1, int(round(probe_ms * 1e-3 * sample_rate / 2)))
    context_half = max(probe_half * 4, int(round(context_ms * 1e-3 * sample_rate / 2)))
    # diff index i spans samples i..i+1; the boundary seam is index boundary-1.
    seam = boundary - 1
    probe = _window(d, seam, probe_half)
    context = _window(d, seam, context_half)
    if probe.size == 0 or context.size == 0:
        raise ValueError("probe or context window is empty")
    denom = float(np.median(context)) + _EPS
    return float(np.max(probe)) / denom


def _norm_mag_spectrum(frame: np.ndarray) -> np.ndarray:
    windowed = frame * np.hanning(frame.shape[0])
    mag = np.abs(np.fft.rfft(windowed))
    norm = float(np.linalg.norm(mag))
    if norm <= 0.0:
        return mag
    return mag / norm


def _flux_at(y: np.ndarray, pos: int, n_fft: int) -> float:
    before = _norm_mag_spectrum(y[pos - n_fft : pos])
    after = _norm_mag_spectrum(y[pos : pos + n_fft])
    return float(np.linalg.norm(after - before))


def spectral_flux_zscore(
    y: np.ndarray,
    boundary: int,
    sample_rate: int,
    n_fft: int = 2048,
    n_ref: int = 200,
    seed: int = 0,
    exclude: Optional[Sequence[Tuple[int, int]]] = None,
) -> Dict[str, float]:
    """Spectral flux at the boundary, z-scored against random positions.

    exclude lists half-open sample ranges (e.g. the other boundary or the
    whole edited region) that reference positions must not touch.
    Returns {"flux", "ref_mean", "ref_std", "zscore", "percentile"}.
    """
    y = to_mono(y)
    n = y.shape[0]
    if not (n_fft <= boundary <= n - n_fft):
        raise ValueError(f"boundary {boundary} too close to edges for n_fft {n_fft}")

    flux_b = _flux_at(y, boundary, n_fft)

    blocked: List[Tuple[int, int]] = [(boundary - n_fft, boundary + n_fft)]
    for lo, hi in exclude or []:
        blocked.append((lo - n_fft, hi + n_fft))

    rng = np.random.default_rng(seed)
    refs: List[float] = []
    attempts = 0
    while len(refs) < n_ref and attempts < n_ref * 50:
        attempts += 1
        pos = int(rng.integers(n_fft, n - n_fft + 1))
        if any(lo <= pos < hi for lo, hi in blocked):
            continue
        refs.append(_flux_at(y, pos, n_fft))
    if len(refs) < 8:
        raise ValueError("not enough unblocked reference positions for flux z-score")

    ref = np.asarray(refs)
    mean = float(ref.mean())
    std = float(ref.std())
    z = (flux_b - mean) / (std + _EPS)
    pct = float(np.mean(ref < flux_b))
    return {
        "flux": flux_b,
        "ref_mean": mean,
        "ref_std": std,
        "zscore": z,
        "percentile": pct,
    }


def null_residual(
    original: np.ndarray,
    result: np.ndarray,
    exclude: Sequence[Tuple[int, int]],
    guard_samples: int = 0,
) -> Dict[str, float]:
    """Residual level of result vs original outside the excluded ranges.

    Compares over min(len) frames; the frame-count mismatch is reported as
    length_delta. guard_samples widens every excluded range on both sides.
    Returns raw and gain-compensated residual levels in dBFS, the reference
    level over the same samples, and the optimal scalar gain.
    """
    a = to_mono(original)
    b = to_mono(result)
    n = min(a.shape[0], b.shape[0])
    length_delta = int(b.shape[0] - a.shape[0])
    a = a[:n]
    b = b[:n]

    keep = np.ones(n, dtype=bool)
    for lo, hi in exclude:
        lo = max(0, lo - guard_samples)
        hi = min(n, hi + guard_samples)
        if lo < hi:
            keep[lo:hi] = False
    if not np.any(keep):
        raise ValueError("exclusions cover the whole signal")

    a_k = a[keep]
    b_k = b[keep]
    resid = b_k - a_k

    denom = float(np.dot(b_k, b_k))
    gain = float(np.dot(a_k, b_k) / denom) if denom > 0.0 else 1.0
    resid_gain = a_k - gain * b_k

    def _db(x: np.ndarray, kind: str) -> float:
        if x.size == 0:
            return _SILENCE_DB
        v = float(np.max(np.abs(x))) if kind == "peak" else float(np.sqrt(np.mean(np.square(x))))
        if v <= 0.0:
            return _SILENCE_DB
        return max(_SILENCE_DB, 20.0 * np.log10(v))

    return {
        "kept_samples": int(a_k.size),
        "length_delta": length_delta,
        "reference_rms_db": _db(a_k, "rms"),
        "residual_rms_db": _db(resid, "rms"),
        "residual_peak_db": _db(resid, "peak"),
        "gain": gain,
        "residual_rms_db_gain_compensated": _db(resid_gain, "rms"),
    }


def boundary_metrics(
    y: np.ndarray,
    boundary: int,
    sample_rate: int,
    exclude: Optional[Sequence[Tuple[int, int]]] = None,
    seed: int = 0,
) -> Dict[str, float]:
    """Convenience bundle: rms step, click ratio, spectral flux z-score."""
    flux = spectral_flux_zscore(
        y, boundary, sample_rate, exclude=exclude, seed=seed
    )
    return {
        "rms_step_db": rms_step_db(y, boundary, sample_rate),
        "click_ratio": click_ratio(y, boundary, sample_rate),
        "flux": flux["flux"],
        "flux_zscore": flux["zscore"],
        "flux_percentile": flux["percentile"],
    }
