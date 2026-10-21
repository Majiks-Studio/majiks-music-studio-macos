"""Waveform region splicing with equal-power crossfades.

numpy only. No torch, no librosa, no audio I/O.

Audio arrays are float, shaped (frames,) for mono or (frames, channels).
All region indices are half-open sample ranges [start, end).

Fade placement is always INSIDE the replaced region: the crossfades occupy
[start, start + fade) and [end - fade, end). Samples outside [start, end)
are copied from the original bit-exact, which is the null-preserve guarantee
the stem-scope product rule depends on (02-ARCHITECTURE.md section 5).
"""

from __future__ import annotations

from typing import Dict, Iterable, Tuple

import numpy as np

__all__ = [
    "equal_power_curves",
    "extract_region",
    "splice_region",
    "stem_recombine",
]


def equal_power_curves(n: int) -> Tuple[np.ndarray, np.ndarray]:
    """Return (fade_in, fade_out) equal-power curves of length n.

    Sampled at bin centers so neither endpoint is exactly 0 or 1, and
    fade_in**2 + fade_out**2 == 1 at every sample.
    """
    if not (isinstance(n, (int, np.integer)) and n >= 0):
        raise ValueError(f"n must be a non-negative int, got {n!r}")
    if n == 0:
        empty = np.zeros(0, dtype=np.float64)
        return empty, empty.copy()
    t = (np.arange(n, dtype=np.float64) + 0.5) / n
    fade_in = np.sin(0.5 * np.pi * t)
    fade_out = np.cos(0.5 * np.pi * t)
    return fade_in, fade_out


def _check_audio(x: np.ndarray, name: str) -> np.ndarray:
    if not isinstance(x, np.ndarray):
        raise TypeError(f"{name} must be a numpy array, got {type(x)!r}")
    if x.ndim not in (1, 2):
        raise ValueError(f"{name} must be 1-D or 2-D (frames[, channels]), got shape {x.shape}")
    if not np.issubdtype(x.dtype, np.floating):
        raise TypeError(f"{name} must be float audio, got dtype {x.dtype}")
    return x


def _expand_curve(curve: np.ndarray, like: np.ndarray) -> np.ndarray:
    """Shape a 1-D fade curve so it broadcasts over (frames[, channels])."""
    if like.ndim == 2:
        return curve[:, np.newaxis]
    return curve


def extract_region(audio: np.ndarray, start: int, end: int) -> np.ndarray:
    """Copy the half-open sample region [start, end) out of audio."""
    _check_audio(audio, "audio")
    n = audio.shape[0]
    if not (0 <= start < end <= n):
        raise ValueError(f"invalid region [{start}, {end}) for length {n}")
    return audio[start:end].copy()


def splice_region(
    original: np.ndarray,
    replacement: np.ndarray,
    start: int,
    end: int,
    fade_samples: int,
) -> np.ndarray:
    """Replace original[start:end] with replacement, equal-power crossfaded.

    replacement must be exactly (end - start) frames with the same channel
    layout as original. fade_samples == 0 is a hard cut. The two fades must
    fit inside the region (2 * fade_samples <= end - start).

    Returns a new float64 array; original is untouched outside the region.
    """
    _check_audio(original, "original")
    _check_audio(replacement, "replacement")
    n = original.shape[0]
    if not (0 <= start < end <= n):
        raise ValueError(f"invalid region [{start}, {end}) for length {n}")
    region_len = end - start
    if replacement.shape[0] != region_len:
        raise ValueError(
            f"replacement has {replacement.shape[0]} frames, region needs {region_len}"
        )
    if replacement.ndim != original.ndim or (
        original.ndim == 2 and replacement.shape[1] != original.shape[1]
    ):
        raise ValueError(
            f"channel layout mismatch: original {original.shape}, replacement {replacement.shape}"
        )
    if not (isinstance(fade_samples, (int, np.integer)) and fade_samples >= 0):
        raise ValueError(f"fade_samples must be a non-negative int, got {fade_samples!r}")
    if 2 * fade_samples > region_len:
        raise ValueError(
            f"fades do not fit: 2 * {fade_samples} > region length {region_len}"
        )

    out = original.astype(np.float64, copy=True)
    region = replacement.astype(np.float64, copy=True)

    if fade_samples > 0:
        fade_in, fade_out = equal_power_curves(fade_samples)
        head_in = _expand_curve(fade_in, region)
        head_out = _expand_curve(fade_out, region)
        # Entry: original fades out, replacement fades in.
        region[:fade_samples] = (
            original[start : start + fade_samples] * head_out
            + region[:fade_samples] * head_in
        )
        # Exit: replacement fades out, original fades in.
        region[region_len - fade_samples :] = (
            region[region_len - fade_samples :] * head_out[::-1]
            + original[end - fade_samples : end] * head_in[::-1]
        )

    out[start:end] = region
    return out


def stem_recombine(
    original_stems: Dict[str, np.ndarray],
    replacement_stems: Dict[str, np.ndarray],
    scoped: Iterable[str],
    start: int,
    end: int,
    fade_samples: int,
) -> Tuple[np.ndarray, Dict[str, np.ndarray]]:
    """Stem-scoped region replacement (the product rule from 02-ARCH section 5).

    For each stem name in scoped, splice replacement_stems[name] (which must be
    exactly the region, end - start frames) into original_stems[name]. Stems
    not in scoped are passed through untouched (null-preserve).

    Returns (mix, stems_out) where mix is the float64 sum of all output stems.
    """
    scoped_set = set(scoped)
    unknown = scoped_set - set(original_stems)
    if unknown:
        raise ValueError(f"scoped stems not in original_stems: {sorted(unknown)}")
    missing = scoped_set - set(replacement_stems)
    if missing:
        raise ValueError(f"scoped stems missing from replacement_stems: {sorted(missing)}")
    if not original_stems:
        raise ValueError("original_stems is empty")

    shapes = {s.shape for s in original_stems.values()}
    if len(shapes) != 1:
        raise ValueError(f"original stems disagree on shape: {sorted(shapes)}")

    stems_out: Dict[str, np.ndarray] = {}
    for name, stem in original_stems.items():
        if name in scoped_set:
            stems_out[name] = splice_region(
                stem, replacement_stems[name], start, end, fade_samples
            )
        else:
            stems_out[name] = stem.astype(np.float64, copy=True)

    mix = np.zeros_like(next(iter(stems_out.values())))
    for stem in stems_out.values():
        mix = mix + stem
    return mix, stems_out
