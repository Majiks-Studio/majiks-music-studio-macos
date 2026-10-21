"""Bar, beat, and sample math for region-based editing.

Standard library only. No numpy, no torch, no audio I/O.

Conventions (these are the contract the Revise UI math must share):
- Bars are 1-based and the bar range is musically inclusive:
  "bars 17-24" covers eight full bars.
- A time region [start_seconds, end_seconds) is half-open: start is the
  first instant inside the region, end is the first instant after it.
  The same holds for sample regions [start_sample, end_sample).
- beats_per_bar is the time-signature numerator over a quarter-note pulse
  (4 for 4/4, 3 for 3/4, 6 for 6/8). This matches ACE-Step's integer
  "timesignature" field.
- grid_offset_seconds shifts the whole bar grid later in time. Use it when
  beat 1 of bar 1 does not fall exactly at t=0 in the audio file.
"""

from __future__ import annotations

import math

__all__ = [
    "seconds_per_beat",
    "seconds_per_bar",
    "bar_start_seconds",
    "region_seconds",
    "region_duration_seconds",
    "bars_in_region",
    "seconds_to_sample",
    "region_samples",
    "bar_at_seconds",
    "snap_seconds_to_bar",
]


def _validate_bpm(bpm: float) -> None:
    if not (isinstance(bpm, (int, float)) and math.isfinite(bpm) and bpm > 0):
        raise ValueError(f"bpm must be a positive finite number, got {bpm!r}")


def _validate_beats_per_bar(beats_per_bar: int) -> None:
    if not (isinstance(beats_per_bar, int) and beats_per_bar >= 1):
        raise ValueError(f"beats_per_bar must be an int >= 1, got {beats_per_bar!r}")


def seconds_per_beat(bpm: float) -> float:
    """Duration of one beat in seconds."""
    _validate_bpm(bpm)
    return 60.0 / bpm


def seconds_per_bar(bpm: float, beats_per_bar: int = 4) -> float:
    """Duration of one bar in seconds."""
    _validate_beats_per_bar(beats_per_bar)
    return seconds_per_beat(bpm) * beats_per_bar


def bar_start_seconds(
    bar: int,
    bpm: float,
    beats_per_bar: int = 4,
    grid_offset_seconds: float = 0.0,
) -> float:
    """Start time of a 1-based bar on the grid."""
    if not (isinstance(bar, int) and bar >= 1):
        raise ValueError(f"bar must be an int >= 1, got {bar!r}")
    return grid_offset_seconds + (bar - 1) * seconds_per_bar(bpm, beats_per_bar)


def region_seconds(
    start_bar: int,
    end_bar: int,
    bpm: float,
    beats_per_bar: int = 4,
    grid_offset_seconds: float = 0.0,
) -> tuple[float, float]:
    """Half-open [start, end) seconds for the inclusive bar range start_bar..end_bar.

    The region ends where bar end_bar ends, i.e. where bar end_bar + 1 starts.
    """
    if not (isinstance(end_bar, int) and end_bar >= start_bar):
        raise ValueError(
            f"end_bar must be an int >= start_bar, got start={start_bar!r} end={end_bar!r}"
        )
    start = bar_start_seconds(start_bar, bpm, beats_per_bar, grid_offset_seconds)
    end = bar_start_seconds(end_bar + 1, bpm, beats_per_bar, grid_offset_seconds)
    return (start, end)


def bars_in_region(start_bar: int, end_bar: int) -> int:
    """Number of bars in the inclusive range start_bar..end_bar."""
    if not (isinstance(start_bar, int) and start_bar >= 1):
        raise ValueError(f"start_bar must be an int >= 1, got {start_bar!r}")
    if not (isinstance(end_bar, int) and end_bar >= start_bar):
        raise ValueError(f"end_bar must be >= start_bar, got {end_bar!r}")
    return end_bar - start_bar + 1


def region_duration_seconds(
    start_bar: int, end_bar: int, bpm: float, beats_per_bar: int = 4
) -> float:
    """Duration in seconds of the inclusive bar range."""
    return bars_in_region(start_bar, end_bar) * seconds_per_bar(bpm, beats_per_bar)


def seconds_to_sample(t: float, sample_rate: int) -> int:
    """Convert a time to a sample index (round half up). t must be >= 0."""
    if not (isinstance(sample_rate, int) and sample_rate > 0):
        raise ValueError(f"sample_rate must be a positive int, got {sample_rate!r}")
    if not (isinstance(t, (int, float)) and math.isfinite(t) and t >= 0):
        raise ValueError(f"t must be a non-negative finite number, got {t!r}")
    return int(math.floor(t * sample_rate + 0.5))


def region_samples(
    start_bar: int,
    end_bar: int,
    bpm: float,
    sample_rate: int,
    beats_per_bar: int = 4,
    grid_offset_seconds: float = 0.0,
) -> tuple[int, int]:
    """Half-open [start_sample, end_sample) for the inclusive bar range."""
    start_s, end_s = region_seconds(
        start_bar, end_bar, bpm, beats_per_bar, grid_offset_seconds
    )
    return (seconds_to_sample(start_s, sample_rate), seconds_to_sample(end_s, sample_rate))


def bar_at_seconds(
    t: float,
    bpm: float,
    beats_per_bar: int = 4,
    grid_offset_seconds: float = 0.0,
) -> int:
    """1-based bar containing time t. Times before the grid start are bar 1."""
    if not (isinstance(t, (int, float)) and math.isfinite(t)):
        raise ValueError(f"t must be a finite number, got {t!r}")
    rel = t - grid_offset_seconds
    if rel < 0:
        return 1
    return int(rel // seconds_per_bar(bpm, beats_per_bar)) + 1


def snap_seconds_to_bar(
    t: float,
    bpm: float,
    beats_per_bar: int = 4,
    grid_offset_seconds: float = 0.0,
    mode: str = "nearest",
) -> float:
    """Snap a time to the bar grid. mode is one of nearest, floor, ceil.

    Result can be the grid origin (start of bar 1) at the earliest.
    """
    if mode not in ("nearest", "floor", "ceil"):
        raise ValueError(f"mode must be nearest, floor, or ceil, got {mode!r}")
    bar_len = seconds_per_bar(bpm, beats_per_bar)
    rel = (t - grid_offset_seconds) / bar_len
    if mode == "nearest":
        snapped = math.floor(rel + 0.5)
    elif mode == "floor":
        snapped = math.floor(rel)
    else:
        snapped = math.ceil(rel)
    snapped = max(0, snapped)
    return grid_offset_seconds + snapped * bar_len
