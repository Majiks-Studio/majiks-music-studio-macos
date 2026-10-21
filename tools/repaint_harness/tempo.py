"""Tempo and beat-grid metrics. Requires librosa (GPU box analysis venv).

Kept separate from metrics.py so the numpy-only modules stay importable
on machines without librosa.
"""

from __future__ import annotations

from typing import Dict, Optional, Tuple

import numpy as np


def _librosa():
    import librosa

    return librosa


def estimate_tempo_bpm(y: np.ndarray, sr: int) -> float:
    """Tempo estimate in BPM for a mono float signal."""
    librosa = _librosa()
    if hasattr(librosa.feature, "tempo"):
        t = librosa.feature.tempo(y=y, sr=sr)
    else:  # older librosa
        t = librosa.beat.tempo(y=y, sr=sr)
    return float(np.atleast_1d(t)[0])


def beat_grid_metrics(
    y: np.ndarray,
    sr: int,
    expected_bpm: float,
    region: Optional[Tuple[int, int]] = None,
    grid_offset_seconds: float = 0.0,
) -> Dict[str, float]:
    """Beat continuity of (a region of) a signal against a known grid.

    Returns:
        tempo_bpm: free tempo estimate of the segment
        beat_interval_drift_pct: (median beat interval - expected) / expected
        grid_phase_error_ms: median absolute distance from detected beats to
            the nearest expected grid line (grid: offset + k * 60/bpm)
        n_beats: number of beats the tracker found
    """
    librosa = _librosa()
    lo, hi = region if region is not None else (0, y.shape[0])
    seg = y[lo:hi]
    period = 60.0 / expected_bpm

    tempo_bpm = estimate_tempo_bpm(seg, sr)

    _, beat_frames = librosa.beat.beat_track(
        y=seg, sr=sr, start_bpm=expected_bpm, trim=False
    )
    beat_times = librosa.frames_to_time(beat_frames, sr=sr) + lo / sr

    out: Dict[str, float] = {
        "tempo_bpm": tempo_bpm,
        "n_beats": float(len(beat_times)),
        "beat_interval_drift_pct": float("nan"),
        "grid_phase_error_ms": float("nan"),
    }
    if len(beat_times) >= 3:
        intervals = np.diff(beat_times)
        med = float(np.median(intervals))
        out["beat_interval_drift_pct"] = (med - period) / period * 100.0

        rel = (beat_times - grid_offset_seconds) / period
        err = np.abs(rel - np.round(rel)) * period * 1000.0
        out["grid_phase_error_ms"] = float(np.median(err))
    return out


def estimate_grid_offset_seconds(
    y: np.ndarray, sr: int, expected_bpm: float, window: Tuple[float, float] = (5.0, 40.0)
) -> float:
    """Circular-mean phase of tracked beats against the expected period.

    Answers: how far after t=0 does the beat grid actually start.
    """
    librosa = _librosa()
    lo = int(window[0] * sr)
    hi = min(y.shape[0], int(window[1] * sr))
    seg = y[lo:hi]
    period = 60.0 / expected_bpm

    _, beat_frames = librosa.beat.beat_track(
        y=seg, sr=sr, start_bpm=expected_bpm, trim=False
    )
    beat_times = librosa.frames_to_time(beat_frames, sr=sr) + window[0]
    if len(beat_times) < 3:
        return 0.0
    phases = (beat_times % period) / period * 2.0 * np.pi
    mean_angle = float(np.arctan2(np.mean(np.sin(phases)), np.mean(np.cos(phases))))
    if mean_angle < 0:
        mean_angle += 2.0 * np.pi
    return mean_angle / (2.0 * np.pi) * period
