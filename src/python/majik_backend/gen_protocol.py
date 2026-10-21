"""Gen Protocol v1 service (lane L4).

Adapts the existing ACE-Step generators (ace_generator.py) behind the frozen
Gen Protocol contract (engine/contracts/gen-protocol.v1.yaml +
gen-protocol-mapping.md). This module owns NO model code: it is a thin,
async-job-shaped translation layer over methods that already exist.

Four RPC entry points are registered additively in rpc_server.py:
    gen.submit        -> submit(op, request, notify=...)
    gen.status        -> status(job_id)
    gen.cancel        -> cancel(job_id)
    gen.capabilities  -> capabilities()

Design decisions made in this lane (see docs/evidence/l4-gen-protocol.md for
the full record; summarized here so the code is self-explaining):

1. Job identity. jobId == the caller's requestId, always (mapping.md, "Job
   identity and the async model"). This module never mints a second id.

2. local-mlx route. The current backend has no submit/poll store for local
   generation (mapping.md). This module ADDS one: gen.submit spawns a
   background thread that calls the existing (unmodified) generator method,
   re-emits its progress_callback as gen.submit progress via `notify`, and
   records a terminal JobRecord. All local-mlx jobs are serialized through
   one lock (_LOCAL_EXEC_LOCK): the singleton ACEStepGenerator is not meant
   for concurrent use (one model, one GPU/MPS device, self._model_lock /
   self._active_generations bookkeeping already assumes sequential calls).
   This lock only serializes jobs submitted THROUGH gen.submit; it does not
   (cannot, without editing rpc_server.py's existing dispatch blocks, which
   is out of this lane's file ownership) cover old-style direct generate_*
   RPC calls made concurrently with a gen.submit job. In practice this is a
   latent risk, not an active one: nothing in this lane wires gen.submit into
   the shipping UI (Create tab is untouched, per scope), and GenerationQueue
   .swift already serializes local jobs client-side (a single
   `localProcessingTask`, not a pool). Flagged as an open question in the
   evidence doc for whoever wires gen.submit into the Studio tab.

3. remote-ace route == the EXISTING Swift ServerPool / RemoteGenerationService
   bridge protocol (POST /api/v1/studio/generate, poll .../jobs/{id}), which
   Python already mirrors as ace_generator.RemoteACEStepGenerator. Read
   directly: that class implements generate_music/generate_variants ONLY,
   no generate_repaint/_continuation/_lego/_extract/_cover method exists on
   it. So remote-ace supports op="generate" only. This is a structural fact
   of already-shipped code this lane must not modify, not a probe result;
   verified by reading ace_generator.py and RemoteGenerationService.swift
   (session brief scope item 3: "VERIFY... if not, capabilities marks
   revise-class ops local-only").

4. gen-node route == a NEW adapter (_StockAceServerClient in this file)
   speaking the RAW upstream ACE-Step api_server wire protocol that P0-A
   proved out (docs/evidence/p0a-repaint.md section 1: POST /release_task as
   JSON -> {task_id}, POST /query_result -> {status: 0 queued/running,
   1 succeeded, 2 failed, ...}, GET /v1/audio?path=... to download). Per
   02-ARCHITECTURE.md section 5 and this lane's brief ("Gen Node gateway
   (P-00120) gets a capability probe with graceful unknown... do not build
   gateway endpoints in this lane"): P-00120 (Majiks Gen Node) is exactly a
   "self-hostable ACE-Step server", i.e. a deployment of this same upstream
   wire protocol, so this adapter is offered as the gen-node route's client,
   reached at MAJIKS_GEN_NODE_URL (unset = capabilities reports it empty,
   "graceful unknown", per session adaptation). No gateway is deployed by
   this lane; this is a client only, matching the Swift GenProtocolClient's
   own local/remote client role.

   On this route only (new code, nothing existing to preserve), two P0-A
   findings are applied directly since they cost nothing and are proven:
   chunk_mask_mode="explicit" for revise-class ops (P0-A section 2 finding
   #3: ~8 dB better outside-region fidelity, no seam-quality cost) and NOT
   overriding the wire "instruction" field so the server's own
   _resolve_instruction() fills the correct TASK_INSTRUCTIONS[task_type]
   text (P0-A section 2 finding #1: the app's local route leaves this at
   the text2music default; this route does not inherit that gap because it
   is not ace_generator.py). This does not change local-mlx behavior at all.

5. uc-cloud route is not implemented in this lane (no deployment, no
   credentials). capabilities() reports it with an empty op list.

6. Client-side splice is mandatory for revise, retake-with-region, extend,
   and finalize (P0-A section 1 + section 9: raw model output never
   preserves untouched audio, median ~-21 dBFS residual outside the region,
   normalization alone can swing gain 0.19x-1.47x). generate, layer, retake
   -without-region, autocomplete, cover do not rewrite pre-existing audio the
   product needs to preserve, so no splice applies (autocomplete is flagged
   as an explicit open question: P0-A did not test it, so this is a
   documented assumption, not a measured one). Splice math (equal-power
   crossfade, faded inside the region) mirrors the validated approach in
   tools/repaint_harness/splice.py; it is reimplemented here rather than
   imported because tools/ is a research harness, not a runtime dependency
   this shipped module should carry.

7. Quality rungs (mapping.md "finalize" section + session brief section 7):
   draft = acestep-v15-turbo / 8 steps. full = acestep-v15-base / 50 steps.
   standard = acestep-v15-quality with a step count "not observed in any
   shipped call site" per the mapping doc's own open question. This module
   does NOT invent one; targetQualityRung="standard" raises a clear
   QUALITY_RUNG_NOT_CONFIGURED error instead.

8. retake requires resolving sourceTakeId -> the take's originating request
   (source audio, region, caption). That lineage store is the Rust engine's
   journal / takes.list / lineage.get(clipId) (02-ARCH section 4), which does
   not exist yet and is out of this lane's scope (engine/ is L1/L2's). This
   module fully implements retake's validation/routing (region-pair
   completeness -> repaint-shaped vs generate-shaped) but its execution
   accepts an injectable `lineage_resolver` callable; with none configured
   (the real state today) it raises a clear LINEAGE_STORE_NOT_AVAILABLE
   error rather than inventing a lookup. Flagged in the evidence doc.

9. Hashing. Terminal artifacts carry blake3 hex digests (assetHash pattern
   in gen-protocol.schemas.json, and the whole provenance chain elsewhere in
   this program is blake3). The compiled `blake3` PyPI package is NOT a
   pyproject.toml dependency (adding one is out of this lane's file
   ownership) and the shipped app bundle only carries majik_backend/, not
   engine/contracts/ (a dev/contracts-only tree) - so this module carries its
   own dependency-free pure-Python BLAKE3 fallback rather than importing
   engine/contracts/conformance_py/blake3_pure.py across that boundary. Both
   implementations exist because P0-C already proved the algorithm correct
   (docs/evidence/p0c-contracts.md: cross-checked byte-for-byte against the
   compiled package across 39 inputs); this is the same algorithm, ported
   for this module's own production independence, not a second attempt at
   the math. Real compiled blake3 is preferred when importable (faster).
"""

from __future__ import annotations

import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Local (unmodified) generator imports. Mirrors rpc_server.py's own defensive
# import pattern so this module can still be imported (capabilities/status/
# cancel/pure mapping helpers all still work) even if ace_generator's own
# heavier deps (numpy/soundfile/librosa) are missing.
# ---------------------------------------------------------------------------
ACE_GENERATOR_IMPORT_ERROR: Optional[str] = None
try:
    from .ace_generator import (
        GenerationStepError,
        RemoteACEStepGenerator,
        _extract_metadata,
        get_generator,
    )
    _HAVE_ACE_GENERATOR = True
except Exception as _ace_import_exc:  # noqa: BLE001
    ACE_GENERATOR_IMPORT_ERROR = str(_ace_import_exc)
    _HAVE_ACE_GENERATOR = False
    GenerationStepError = Exception  # type: ignore[assignment,misc]
    RemoteACEStepGenerator = None  # type: ignore[assignment,misc]

    def _extract_metadata(file_path: str):  # type: ignore[misc]
        return None, None

    def get_generator() -> Any:  # type: ignore[misc]
        raise GenProtocolError(
            code="ACE_STEP_NOT_FOUND",
            message="ACE-Step dependencies are missing from the selected Python environment.",
            fix="Use the ACE-Step virtual environment Python and restart the app.",
            detail=ACE_GENERATOR_IMPORT_ERROR,
            step="ACE-Step init",
        )

try:
    import numpy as np
    _HAVE_NUMPY = True
except Exception:  # noqa: BLE001
    np = None  # type: ignore[assignment]
    _HAVE_NUMPY = False

try:
    import soundfile as sf
    _HAVE_SOUNDFILE = True
except Exception:  # noqa: BLE001
    sf = None  # type: ignore[assignment]
    _HAVE_SOUNDFILE = False


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

class GenProtocolError(Exception):
    """Structured error matching the existing _structured_error() vocabulary
    (rpc_server.py) and the contract's errorBody shape (code, message, fix,
    detail, step)."""

    def __init__(
        self,
        code: str,
        message: str,
        fix: str = "",
        detail: Optional[str] = None,
        step: Optional[str] = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.fix = fix
        self.detail = detail
        self.step = step

    def to_dict(self) -> Dict[str, Any]:
        out: Dict[str, Any] = {"code": self.code, "message": self.message}
        if self.fix:
            out["fix"] = self.fix
        if self.detail:
            out["detail"] = self.detail
        if self.step:
            out["step"] = self.step
        return out


class _CancelSignal(Exception):
    """Internal-only: raised from a progress callback to unwind a blocking
    generator call once a job's own cancel_event has been set. Never crosses
    this module's public boundary."""


# ---------------------------------------------------------------------------
# blake3 hashing: compiled package preferred, dependency-free pure-Python
# fallback otherwise. See module docstring point 9.
# ---------------------------------------------------------------------------

def _blake3_hex_pure(data: bytes) -> str:
    """Pure-Python BLAKE3 (unkeyed, 32-byte output), stdlib only.

    Ported from engine/contracts/conformance_py/blake3_pure.py (P0-C),
    verified there byte-for-byte against the compiled `blake3` package across
    39 inputs (0..65537 bytes). Duplicated here (not imported) so this
    shipped backend module has no runtime dependency on the engine/contracts
    tree. See module docstring point 9.
    """
    block_len = 64
    chunk_len = 1024
    chunk_start, chunk_end, parent, root = 1, 2, 4, 8
    iv = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
          0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]
    msg_perm = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]
    mask32 = 0xFFFFFFFF

    def rotr32(x: int, n: int) -> int:
        return ((x >> n) | (x << (32 - n))) & mask32

    def g(state: List[int], a: int, b: int, c: int, d: int, mx: int, my: int) -> None:
        state[a] = (state[a] + state[b] + mx) & mask32
        state[d] = rotr32(state[d] ^ state[a], 16)
        state[c] = (state[c] + state[d]) & mask32
        state[b] = rotr32(state[b] ^ state[c], 12)
        state[a] = (state[a] + state[b] + my) & mask32
        state[d] = rotr32(state[d] ^ state[a], 8)
        state[c] = (state[c] + state[d]) & mask32
        state[b] = rotr32(state[b] ^ state[c], 7)

    def round_(state: List[int], m: List[int]) -> None:
        g(state, 0, 4, 8, 12, m[0], m[1])
        g(state, 1, 5, 9, 13, m[2], m[3])
        g(state, 2, 6, 10, 14, m[4], m[5])
        g(state, 3, 7, 11, 15, m[6], m[7])
        g(state, 0, 5, 10, 15, m[8], m[9])
        g(state, 1, 6, 11, 12, m[10], m[11])
        g(state, 2, 7, 8, 13, m[12], m[13])
        g(state, 3, 4, 9, 14, m[14], m[15])

    def permute(m: List[int]) -> List[int]:
        return [m[i] for i in msg_perm]

    def compress(cv: List[int], block_words: List[int], counter: int, blen: int, flags: int) -> List[int]:
        state = list(cv) + list(iv[0:4]) + [counter & mask32, (counter >> 32) & mask32, blen, flags]
        block = list(block_words)
        for r in range(7):
            round_(state, block)
            if r < 6:
                block = permute(block)
        for i in range(8):
            state[i] = (state[i] ^ state[i + 8]) & mask32
            state[i + 8] = (state[i + 8] ^ cv[i]) & mask32
        return state

    def words_from_le_bytes(b: bytes) -> List[int]:
        padded = bytes(b) + b"\x00" * (block_len - len(b))
        return [int.from_bytes(padded[i:i + 4], "little") for i in range(0, block_len, 4)]

    class Output:
        __slots__ = ("icv", "block_words", "counter", "block_len", "flags")

        def __init__(self, icv: List[int], block_words: List[int], counter: int, blen: int, flags: int) -> None:
            self.icv = icv
            self.block_words = block_words
            self.counter = counter
            self.block_len = blen
            self.flags = flags

        def chaining_value(self) -> List[int]:
            return compress(self.icv, self.block_words, self.counter, self.block_len, self.flags)[0:8]

        def root_bytes(self, out_len: int) -> bytes:
            out = bytearray()
            counter = 0
            while len(out) < out_len:
                words = compress(self.icv, self.block_words, counter, self.block_len, self.flags | root)
                for w in words:
                    out.extend(w.to_bytes(4, "little"))
                    if len(out) >= out_len:
                        break
                counter += 1
            return bytes(out[:out_len])

    class ChunkState:
        def __init__(self, cv: List[int], counter: int, flags: int) -> None:
            self.cv = cv
            self.counter = counter
            self.block = bytearray()
            self.block_len = 0
            self.blocks_compressed = 0
            self.flags = flags

        def length(self) -> int:
            return block_len * self.blocks_compressed + self.block_len

        def start_flag(self) -> int:
            return chunk_start if self.blocks_compressed == 0 else 0

        def update(self, data: bytes) -> None:
            idx, n = 0, len(data)
            while idx < n:
                if self.block_len == block_len:
                    bw = words_from_le_bytes(bytes(self.block))
                    self.cv = compress(self.cv, bw, self.counter, block_len, self.flags | self.start_flag())[0:8]
                    self.blocks_compressed += 1
                    self.block = bytearray()
                    self.block_len = 0
                want = block_len - self.block_len
                take = min(want, n - idx)
                self.block.extend(data[idx:idx + take])
                self.block_len += take
                idx += take

        def output(self) -> "Output":
            bw = words_from_le_bytes(bytes(self.block))
            return Output(self.cv, bw, self.counter, self.block_len, self.flags | self.start_flag() | chunk_end)

    def parent_output(left_cv: List[int], right_cv: List[int], key_words: List[int], flags: int) -> "Output":
        return Output(key_words, list(left_cv) + list(right_cv), 0, block_len, parent | flags)

    def parent_cv(left_cv: List[int], right_cv: List[int], key_words: List[int], flags: int) -> List[int]:
        return parent_output(left_cv, right_cv, key_words, flags).chaining_value()

    key_words = list(iv)
    flags = 0
    state = ChunkState(list(key_words), 0, flags)
    cv_stack: List[List[int]] = []

    idx, n = 0, len(data)
    while idx < n:
        if state.length() == chunk_len:
            chunk_cv = state.output().chaining_value()
            total_chunks = state.counter + 1
            tc = total_chunks
            new_cv = chunk_cv
            while tc & 1 == 0:
                new_cv = parent_cv(cv_stack.pop(), new_cv, key_words, flags)
                tc >>= 1
            cv_stack.append(new_cv)
            state = ChunkState(list(key_words), total_chunks, flags)
        want = chunk_len - state.length()
        take = min(want, n - idx)
        state.update(data[idx:idx + take])
        idx += take

    output = state.output()
    remaining = len(cv_stack)
    while remaining > 0:
        remaining -= 1
        output = parent_output(cv_stack[remaining], output.chaining_value(), key_words, flags)
    return output.root_bytes(32).hex()


def blake3_hex(data: bytes) -> str:
    """64-char lowercase hex BLAKE3 digest. Prefers the compiled package."""
    try:
        import blake3 as _compiled  # noqa: PLC0415
        return _compiled.blake3(data).hexdigest()
    except ImportError:
        return _blake3_hex_pure(data)


def blake3_hex_of_file(path: str) -> str:
    with open(path, "rb") as fh:
        return blake3_hex(fh.read())


# ---------------------------------------------------------------------------
# Splice: equal-power crossfade region replacement. numpy only. Mirrors the
# validated approach in tools/repaint_harness/splice.py (P0-A); see module
# docstring point 6.
# ---------------------------------------------------------------------------

def equal_power_curves(n: int) -> Tuple["np.ndarray", "np.ndarray"]:
    """(fade_in, fade_out) equal-power curves of length n, bin-centered so
    neither endpoint is exactly 0 or 1; fade_in**2 + fade_out**2 == 1."""
    if n == 0:
        empty = np.zeros(0, dtype=np.float64)
        return empty, empty.copy()
    t = (np.arange(n, dtype=np.float64) + 0.5) / n
    return np.sin(0.5 * np.pi * t), np.cos(0.5 * np.pi * t)


def _expand_curve(curve: "np.ndarray", like: "np.ndarray") -> "np.ndarray":
    return curve[:, np.newaxis] if like.ndim == 2 else curve


def splice_region(
    original: "np.ndarray",
    replacement: "np.ndarray",
    start: int,
    end: int,
    fade_samples: int,
) -> "np.ndarray":
    """Replace original[start:end] with replacement, equal-power crossfaded
    INSIDE the region. Samples outside [start, end) are bit-exact copies of
    original. Returns a new float64 array."""
    n = original.shape[0]
    if not (0 <= start < end <= n):
        raise ValueError(f"invalid region [{start}, {end}) for length {n}")
    region_len = end - start
    if replacement.shape[0] != region_len:
        raise ValueError(f"replacement has {replacement.shape[0]} frames, region needs {region_len}")
    fade_samples = max(0, min(fade_samples, region_len // 2))

    out = original.astype(np.float64, copy=True)
    region = replacement.astype(np.float64, copy=True)

    if fade_samples > 0:
        fade_in, fade_out = equal_power_curves(fade_samples)
        head_in = _expand_curve(fade_in, region)
        head_out = _expand_curve(fade_out, region)
        region[:fade_samples] = (
            original[start:start + fade_samples] * head_out + region[:fade_samples] * head_in
        )
        region[region_len - fade_samples:] = (
            region[region_len - fade_samples:] * head_out[::-1]
            + original[end - fade_samples:end] * head_in[::-1]
        )

    out[start:end] = region
    return out


def splice_open_tail(
    original: "np.ndarray",
    extended: "np.ndarray",
    join_at: int,
    fade_samples: int,
) -> "np.ndarray":
    """Extend op splice: keep `original` bit-exact for its full length, then
    append extended[join_at:] (the new tail beyond the original), with an
    equal-power crossfade at the join so there is no click. `extended` must
    share the same content as `original` up to join_at (it is the model's
    full rewritten output) and `join_at` is normally len(original)."""
    if not (0 < join_at <= original.shape[0]):
        raise ValueError(f"invalid join_at {join_at} for original length {original.shape[0]}")
    if extended.shape[0] < join_at:
        raise ValueError("extended output is shorter than the join point")
    fade_samples = max(0, min(fade_samples, join_at, extended.shape[0] - join_at if extended.shape[0] > join_at else 0))

    head = original.astype(np.float64, copy=True)
    tail = extended[join_at:].astype(np.float64, copy=True)

    if fade_samples > 0:
        fade_in, fade_out = equal_power_curves(fade_samples)
        head_out = _expand_curve(fade_out, head)
        head_in = _expand_curve(fade_in, head)
        blended = (
            head[join_at - fade_samples:join_at] * head_out
            + extended[join_at - fade_samples:join_at].astype(np.float64) * head_in
        )
        head = head.copy()
        head[join_at - fade_samples:join_at] = blended

    return np.concatenate([head, tail], axis=0)


def stem_recombine(
    original_stems: Dict[str, "np.ndarray"],
    replacement_stems: Dict[str, "np.ndarray"],
    scoped: List[str],
    start: int,
    end: int,
    fade_samples: int,
) -> Tuple["np.ndarray", Dict[str, "np.ndarray"]]:
    """Stem-scoped region replacement (02-ARCH section 5 product rule).
    Stems in `scoped` get replacement spliced in over [start,end); the rest
    pass through untouched. Returns (mix, stems_out)."""
    scoped_set = set(scoped)
    unknown = scoped_set - set(original_stems)
    if unknown:
        raise ValueError(f"scoped stems not in original_stems: {sorted(unknown)}")
    missing = scoped_set - set(replacement_stems)
    if missing:
        raise ValueError(f"scoped stems missing from replacement_stems: {sorted(missing)}")

    stems_out: Dict[str, "np.ndarray"] = {}
    for name, stem in original_stems.items():
        if name in scoped_set:
            stems_out[name] = splice_region(stem, replacement_stems[name], start, end, fade_samples)
        else:
            stems_out[name] = stem.astype(np.float64, copy=True)

    mix = np.zeros_like(next(iter(stems_out.values())))
    for stem in stems_out.values():
        mix = mix + stem
    return mix, stems_out


# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------

LOCAL_MLX = "local-mlx"
REMOTE_ACE = "remote-ace"
GEN_NODE = "gen-node"
UC_CLOUD = "uc-cloud"
VALID_ROUTES = {LOCAL_MLX, REMOTE_ACE, GEN_NODE, UC_CLOUD}

OPS = (
    "generate", "revise", "extend", "layer", "retake",
    "autocomplete", "cover", "separate", "analyze", "finalize",
)

STEM_KINDS = ("vocals", "drums", "bass", "other")
ARTIFACT_KINDS = ("mix",) + STEM_KINDS

# draft/full grounded by docs/evidence/p0a-repaint.md section 7 + session
# adaptation. "standard" deliberately absent: see module docstring point 7.
QUALITY_RUNGS: Dict[str, Tuple[str, int]] = {
    "draft": ("acestep-v15-turbo", 8),
    "full": ("acestep-v15-base", 50),
}

# Matches gen-protocol.schemas.json #/$defs/ulid exactly: ^[0-7][0-9A-HJKMNP-TV-Z]{25}$
_ULID_RE = re.compile(r"^[0-7][0-9A-HJKMNP-TV-Z]{25}$")

# Required fields per op, straight from gen-protocol.schemas.json's $defs.
# Cross-checked against the real schema file in
# src/python/tests/test_gen_protocol_contract.py using jsonschema, so any
# drift between this hand-rolled list and the frozen contract is caught by
# tests rather than trusted blindly.
_REQUIRED_FIELDS: Dict[str, Tuple[str, ...]] = {
    "generate": ("requestId", "caption"),
    "revise": ("requestId", "sourceAudioRef", "regionStartSeconds", "regionEndSeconds", "instruction"),
    "extend": ("requestId", "sourceAudioRef", "addedDurationSeconds"),
    "layer": ("requestId", "instruction"),
    "retake": ("requestId", "sourceTakeId"),
    "autocomplete": ("requestId", "sourceAudioRef", "caption"),
    "cover": ("requestId", "referenceAudioRef", "caption"),
    "separate": ("requestId", "sourceAudioRef"),
    "analyze": ("requestId", "sourceAudioRef"),
    "finalize": ("requestId", "draftTakeId", "targetQualityRung", "request"),
}

_ALLOWED_FIELDS: Dict[str, set] = {
    "generate": {"requestId", "route", "caption", "lyrics", "durationSeconds", "bpm", "key",
                 "timeSig", "vocalLanguage", "seed", "model", "steps", "nVariants"},
    "revise": {"requestId", "route", "sourceAudioRef", "regionStartSeconds", "regionEndSeconds",
               "instruction", "scope", "seed", "variants"},
    "extend": {"requestId", "route", "sourceAudioRef", "addedDurationSeconds", "instruction", "seed"},
    "layer": {"requestId", "route", "contextAudioRef", "instruction", "caption", "seed"},
    "retake": {"requestId", "route", "sourceTakeId", "regionStartSeconds", "regionEndSeconds", "seed"},
    "autocomplete": {"requestId", "route", "sourceAudioRef", "caption", "seed"},
    "cover": {"requestId", "route", "referenceAudioRef", "caption", "coverStrength", "seed"},
    "separate": {"requestId", "sourceAudioRef", "engine", "instruction"},
    "analyze": {"requestId", "sourceAudioRef", "mode", "existingCaption", "existingTitle"},
    "finalize": {"requestId", "draftTakeId", "targetQualityRung", "request"},
}

# Ops where the model output rewrites pre-existing audio the product must
# preserve outside an edited region: mandatory client-side splice. See module
# docstring point 6.
_SPLICE_REQUIRED_OPS = {"revise", "finalize"}  # retake-with-region and extend are handled specially


def _validate_ulid(value: Any, field_name: str) -> str:
    if not isinstance(value, str) or not _ULID_RE.match(value):
        raise GenProtocolError(
            code="INVALID_REQUEST",
            message=f"{field_name} must be a 26-character Crockford-base32 ULID, got {value!r}",
            fix="Generate a valid ULID for the request id.",
        )
    return value


def validate_request(op: str, request: Dict[str, Any]) -> None:
    """Lightweight, dependency-free structural validation: required fields
    present, no unknown fields, requestId is ULID-shaped. Full JSON Schema
    conformance (types, ranges, enums) is exercised in tests against the
    authoritative gen-protocol.schemas.json; this runtime check exists to
    fail fast with a clear error without a jsonschema dependency."""
    if op not in OPS:
        raise GenProtocolError(
            code="UNKNOWN_OP",
            message=f"Unknown Gen Protocol op: {op!r}. Known ops: {', '.join(OPS)}",
            fix="Use one of the ten Gen Protocol ops.",
        )
    required = _REQUIRED_FIELDS[op]
    missing = [f for f in required if request.get(f) in (None, "")]
    # regionStartSeconds may legitimately be 0.0 (falsy); check presence, not truthiness.
    missing = [f for f in missing if f not in request]
    missing = list(dict.fromkeys(missing + [f for f in required if f not in request]))
    if missing:
        raise GenProtocolError(
            code="INVALID_REQUEST",
            message=f"{op} request missing required field(s): {', '.join(missing)}",
            fix=f"Include {', '.join(missing)} in the request body.",
        )
    allowed = _ALLOWED_FIELDS[op]
    unknown = set(request.keys()) - allowed
    if unknown:
        raise GenProtocolError(
            code="INVALID_REQUEST",
            message=f"{op} request has unexpected field(s): {', '.join(sorted(unknown))}",
            fix=f"Only {', '.join(sorted(allowed))} are valid for {op}.",
        )
    _validate_ulid(request.get("requestId"), "requestId")
    route = request.get("route")
    if route is not None and route not in VALID_ROUTES:
        raise GenProtocolError(
            code="INVALID_REQUEST",
            message=f"Unknown route: {route!r}. Known routes: {', '.join(sorted(VALID_ROUTES))}",
            fix="Omit route to let the caller choose, or use a known route name.",
        )
    if op == "retake":
        has_start = "regionStartSeconds" in request
        has_end = "regionEndSeconds" in request
        if has_start != has_end:
            raise GenProtocolError(
                code="INVALID_REQUEST",
                message="retake requires regionStartSeconds and regionEndSeconds together, or neither.",
                fix="Provide both region bounds for a region retake, or omit both for a whole-song retake.",
            )
    if op == "finalize":
        rung = request.get("targetQualityRung")
        if rung not in ("draft", "standard", "full"):
            raise GenProtocolError(
                code="INVALID_REQUEST",
                message=f"targetQualityRung must be draft, standard, or full; got {rung!r}",
                fix="Use draft, standard, or full.",
            )
        inner = request.get("request")
        if not isinstance(inner, dict):
            raise GenProtocolError(
                code="INVALID_REQUEST",
                message="finalize.request must be a reviseRequest object.",
                fix="Include the same request shape that produced draftTakeId.",
            )
        validate_request("revise", inner)


# ---------------------------------------------------------------------------
# Job registry
# ---------------------------------------------------------------------------

@dataclass
class JobRecord:
    job_id: str
    op: str
    route: str
    state: str = "queued"  # queued | running | done | failed | cancelled
    stage: str = "queued"
    percent: int = 0
    message: str = ""
    variant: Optional[int] = None
    artifacts: List[Dict[str, Any]] = field(default_factory=list)
    engine_identity: Optional[Dict[str, Any]] = None
    latency_seconds: Optional[float] = None
    error: Optional[Dict[str, Any]] = None
    created_at: float = field(default_factory=time.time)
    started_at: Optional[float] = None
    cancel_event: threading.Event = field(default_factory=threading.Event)
    thread: Optional[threading.Thread] = None

    def to_status_dict(self) -> Dict[str, Any]:
        if self.state in ("queued", "running"):
            return {"state": self.state, "jobId": self.job_id}
        if self.state == "done":
            out: Dict[str, Any] = {
                "state": "done",
                "jobId": self.job_id,
                "artifacts": self.artifacts,
                "engineIdentity": self.engine_identity,
            }
            if self.latency_seconds is not None:
                out["latencySeconds"] = self.latency_seconds
            return out
        if self.state == "failed":
            return {"state": "failed", "jobId": self.job_id, "error": self.error}
        if self.state == "cancelled":
            return {"state": "cancelled", "jobId": self.job_id}
        raise AssertionError(f"unreachable job state {self.state!r}")


class JobRegistry:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._jobs: Dict[str, JobRecord] = {}

    def create(self, job_id: str, op: str, route: str) -> JobRecord:
        with self._lock:
            job = JobRecord(job_id=job_id, op=op, route=route)
            self._jobs[job_id] = job
            return job

    def get(self, job_id: str) -> Optional[JobRecord]:
        with self._lock:
            return self._jobs.get(job_id)

    def set_running(self, job_id: str, stage: str = "starting", percent: int = 1, message: str = "") -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job and job.state == "queued":
                job.state = "running"
                job.started_at = time.time()
                job.stage, job.percent, job.message = stage, percent, message

    def update_progress(self, job_id: str, stage: str, percent: int, message: str, variant: Optional[int] = None) -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job and job.state in ("queued", "running"):
                job.state = "running"
                job.stage, job.percent, job.message, job.variant = stage, percent, message, variant

    def mark_done(self, job_id: str, artifacts: List[Dict[str, Any]], engine_identity: Dict[str, Any],
                  latency_seconds: Optional[float] = None) -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if not job:
                return
            job.state = "done"
            job.artifacts = artifacts
            job.engine_identity = engine_identity
            job.latency_seconds = latency_seconds
            job.stage, job.percent = "done", 100

    def mark_failed(self, job_id: str, error: Dict[str, Any]) -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job:
                job.state = "failed"
                job.error = error

    def mark_cancelled(self, job_id: str) -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job:
                job.state = "cancelled"

    def request_cancel(self, job_id: str) -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job:
                job.cancel_event.set()


_REGISTRY = JobRegistry()
_LOCAL_EXEC_LOCK = threading.Lock()

NotifyFn = Callable[..., None]  # (job_id, stage, percent, message, variant=None) -> None


def _noop_notify(job_id: str, stage: str, percent: int, message: str, variant: Optional[int] = None) -> None:
    return None


def _output_root() -> Path:
    override = os.environ.get("MAJIKS_GEN_PROTOCOL_OUTPUT_DIR")
    if override:
        return Path(override)
    base = os.environ.get("MAJIK_LIBRARY_PATH") or str(
        Path.home() / "Library/Application Support/MajiksMusicStudio/Audio"
    )
    return Path(base) / "gen_protocol"


def _job_output_dir(job_id: str) -> Path:
    out = _output_root() / job_id
    out.mkdir(parents=True, exist_ok=True)
    return out


# ---------------------------------------------------------------------------
# Audio I/O helpers (numpy + soundfile; both are hard deps of ace_generator.py
# already, so requiring them here adds nothing new to the app's dependency
# footprint).
# ---------------------------------------------------------------------------

def _read_audio(path: str) -> Tuple["np.ndarray", int]:
    if not _HAVE_SOUNDFILE:
        raise GenProtocolError("MISSING_DEPENDENCY", "soundfile is not installed.",
                                fix="pip install soundfile (already a project dependency).")
    data, sr = sf.read(path, dtype="float32", always_2d=True)
    return data, sr


def _write_audio(path: str, data: "np.ndarray", samplerate: int) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    sf.write(path, data, samplerate, subtype="FLOAT")


def _seconds_to_samples(seconds: float, samplerate: int) -> int:
    return int(round(seconds * samplerate))


DEFAULT_SPLICE_FADE_SECONDS = 0.020  # 20 ms equal-power, P0-A section 7/9 default
DEFAULT_STEM_CONTEXT_SECONDS = 2.0  # fixed padding: no tempo map is available to this
# service (reviseRequest carries no bpm/bar info), so P0-A's "1 bar" context
# is approximated with a fixed-seconds guard. Documented in the evidence doc
# as a simplification pending tempo-map access (engine/L1 territory).


# ---------------------------------------------------------------------------
# Local-mlx op -> ace_generator call mapping. Pure functions where possible
# so they are unit-testable without touching a generator at all.
# ---------------------------------------------------------------------------

def _progress_adapter(job_id: str, notify: NotifyFn) -> Callable[..., None]:
    job = _REGISTRY.get(job_id)

    def _cb(stage: str, percent: int, message: str, variant: Optional[int] = None) -> None:
        if job and job.cancel_event.is_set():
            raise _CancelSignal()
        notify(job_id, stage, percent, message, variant=variant)
        _REGISTRY.update_progress(job_id, stage, percent, message, variant=variant)

    return _cb


def _engine_identity(model: str, steps: Optional[int], seed: Optional[int], device: str) -> Dict[str, Any]:
    out: Dict[str, Any] = {"model": model, "device": device}
    if steps is not None:
        out["steps"] = steps
    if seed is not None:
        out["seed"] = seed
    return out


def _artifact(kind: str, path: str) -> Dict[str, Any]:
    if kind not in ARTIFACT_KINDS:
        raise ValueError(f"unknown artifact kind {kind!r}")
    return {"kind": kind, "path": path, "contentHash": blake3_hex_of_file(path)}


def _local_device(generator: Any) -> str:
    device = getattr(generator, "device", "cpu")
    if device not in ("mlx", "mps", "cuda", "cpu"):
        device = "cpu"
    return device


def _run_generate_local(job: JobRecord, request: Dict[str, Any], generator: Any, notify: NotifyFn) -> None:
    n_variants = int(request.get("nVariants", 1) or 1)
    model = request.get("model") or "acestep-v15-turbo"
    steps = request.get("steps")
    seed = request.get("seed")
    out_dir = _job_output_dir(job.job_id)
    cb = _progress_adapter(job.job_id, notify)

    kwargs = dict(
        caption=request["caption"],
        lyrics=request.get("lyrics"),
        bpm=request.get("bpm"),
        key=request.get("key"),
        duration=int(request.get("durationSeconds", 150) or 150),
        time_signature=request.get("timeSig", "4"),
        vocal_language=request.get("vocalLanguage", ""),
        seed=seed,
        model_name=model,
        progress_callback=cb,
    )
    if steps is not None:
        kwargs["num_inference_steps"] = int(steps)

    if n_variants <= 1:
        output_path = str(out_dir / "mix.wav")
        metadata = generator.generate_music(output_path=output_path, **kwargs)
        artifacts = [_artifact("mix", metadata.get("file_path", output_path))]
        identity = _engine_identity(metadata.get("model", model), metadata.get("num_inference_steps", steps),
                                     metadata.get("seed", seed), _local_device(generator))
    else:
        variants = generator.generate_variants(output_dir=str(out_dir), count=n_variants, **kwargs)
        artifacts = [_artifact("mix", v.get("file_path", str(out_dir / f"variant-{i + 1}.wav")))
                     for i, v in enumerate(variants)]
        first = variants[0] if variants else {}
        identity = _engine_identity(first.get("model", model), first.get("num_inference_steps", steps),
                                     first.get("seed", seed), _local_device(generator))
    _REGISTRY.mark_done(job.job_id, artifacts, identity)


def _load_region_context(
    source_path: str, region_start: float, region_end_raw: float, context_seconds: float = 0.0,
) -> Tuple["np.ndarray", int, int, int, float]:
    """Read source_path; resolve regionEndSeconds' -1 sentinel to file end;
    return (audio, samplerate, region_start_sample, region_end_sample,
    resolved_region_end_seconds)."""
    audio, sr = _read_audio(source_path)
    total = audio.shape[0]
    region_end = (total / sr) if region_end_raw is None or region_end_raw < 0 else region_end_raw
    start_s = _seconds_to_samples(region_start, sr)
    end_s = _seconds_to_samples(region_end, sr)
    start_s = max(0, min(start_s, total - 1))
    end_s = max(start_s + 1, min(end_s, total))
    return audio, sr, start_s, end_s, region_end


def _run_revise_local(job: JobRecord, request: Dict[str, Any], generator: Any, notify: NotifyFn,
                       *, reuse_seed: Optional[int] = None, model_override: Optional[str] = None,
                       steps_override: Optional[int] = None) -> None:
    source_audio = request["sourceAudioRef"]
    if not os.path.exists(source_audio):
        raise GenProtocolError("FILE_NOT_FOUND", f"Source audio not found: {source_audio}",
                                fix="Select a valid audio file and try again.")
    scope = request.get("scope", "all-stems")
    region_start = float(request["regionStartSeconds"])
    region_end_raw = float(request["regionEndSeconds"])
    seed = reuse_seed if reuse_seed is not None else request.get("seed")
    model = model_override or "acestep-v15-base"
    steps = steps_override if steps_override is not None else None
    n_variants = 1 if reuse_seed is not None else int(request.get("variants", 1) or 1)

    out_dir = _job_output_dir(job.job_id)
    cb = _progress_adapter(job.job_id, notify)

    orig_audio, sr, start_s, end_s, resolved_end = _load_region_context(source_audio, region_start, region_end_raw)

    artifacts: List[Dict[str, Any]] = []
    identity: Dict[str, Any] = {}

    for variant_index in range(n_variants):
        take_seed = seed if seed is not None else None
        if n_variants > 1 and seed is not None:
            take_seed = int(seed) + variant_index
        raw_path = str(out_dir / f"raw_repaint_{variant_index + 1}.wav")
        kwargs: Dict[str, Any] = dict(
            source_audio=source_audio,
            repainting_start=region_start,
            repainting_end=region_end_raw,
            caption=request["instruction"],
            output_path=raw_path,
            seed=take_seed,
            model_name=model,
            progress_callback=cb,
        )
        if steps is not None:
            kwargs["num_inference_steps"] = steps
        metadata = generator.generate_repaint(**kwargs)
        raw_out = metadata.get("file_path", raw_path)

        repainted_audio, repainted_sr = _read_audio(raw_out)
        if repainted_sr != sr or repainted_audio.shape[0] != orig_audio.shape[0]:
            # Defensive: repaint is expected to preserve length/samplerate
            # (P0-A section 3/5). If it does not, clip/pad to the original
            # length rather than crash the splice, and surface this loudly.
            n = min(repainted_audio.shape[0], orig_audio.shape[0])
            repainted_audio = repainted_audio[:n]
            local_orig = orig_audio[:n]
            local_end_s = min(end_s, n)
        else:
            local_orig = orig_audio
            local_end_s = end_s

        fade_samples = _seconds_to_samples(DEFAULT_SPLICE_FADE_SECONDS, sr)

        if scope == "all-stems":
            replacement_region = repainted_audio[start_s:local_end_s]
            spliced_mix = splice_region(local_orig, replacement_region, start_s, local_end_s, fade_samples)
            mix_path = str(out_dir / f"mix_{variant_index + 1}.wav")
            _write_audio(mix_path, spliced_mix, sr)
            artifacts.append(_artifact("mix", mix_path))
        else:
            mix_path, stem_artifacts = _stem_scope_splice(
                generator, out_dir, variant_index, local_orig, repainted_audio, sr,
                start_s, local_end_s, fade_samples, [scope],
            )
            artifacts.append(_artifact("mix", mix_path))
            artifacts.extend(stem_artifacts)

        identity = _engine_identity(metadata.get("model", model), metadata.get("num_inference_steps", steps),
                                     metadata.get("seed", take_seed), _local_device(generator))

    _REGISTRY.mark_done(job.job_id, artifacts, identity)


def _stem_scope_splice(
    generator: Any, out_dir: Path, variant_index: int,
    original_full: "np.ndarray", repainted_full: "np.ndarray", sr: int,
    start_s: int, end_s: int, fade_samples: int, scoped_stems: List[str],
) -> Tuple[str, List[Dict[str, Any]]]:
    """P0-A section 6 pipeline: separate the region+context window of BOTH
    the original and the repainted audio, splice only the scoped stem(s)
    inside the true region, keep the rest of the window's stems original,
    sum for the mix. Stem artifacts cover the region+context WINDOW, not the
    full song (see module docstring / evidence doc: full-track stem
    regeneration on every revise is deliberately not paid for here)."""
    ctx = _seconds_to_samples(DEFAULT_STEM_CONTEXT_SECONDS, sr)
    win_start = max(0, start_s - ctx)
    win_end = min(original_full.shape[0], end_s + ctx)

    orig_window = original_full[win_start:win_end]
    repainted_window = repainted_full[win_start:win_end]

    orig_clip_path = str(out_dir / f"stemsrc_orig_{variant_index + 1}.wav")
    repainted_clip_path = str(out_dir / f"stemsrc_repainted_{variant_index + 1}.wav")
    _write_audio(orig_clip_path, orig_window, sr)
    _write_audio(repainted_clip_path, repainted_window, sr)

    orig_stems_dir = str(out_dir / f"stems_orig_{variant_index + 1}")
    repainted_stems_dir = str(out_dir / f"stems_repainted_{variant_index + 1}")
    orig_result = generator.export_stems(orig_clip_path, orig_stems_dir)
    repainted_result = generator.export_stems(repainted_clip_path, repainted_stems_dir)

    orig_stems = {name: _read_audio(path)[0] for name, path in orig_result["stems"].items()}
    repainted_stems = {name: _read_audio(path)[0] for name, path in repainted_result["stems"].items()}

    # Region bounds relative to the window (where the actual splice happens).
    win_region_start = start_s - win_start
    win_region_end = end_s - win_start

    # stem_recombine (like splice_region underneath it) takes the REPLACEMENT
    # as exactly the region span, not the whole window: slice the repainted
    # window's stems down to [win_region_start, win_region_end) here.
    repainted_region_stems = {name: arr[win_region_start:win_region_end] for name, arr in repainted_stems.items()}

    mix_window, stems_out = stem_recombine(
        orig_stems, repainted_region_stems, scoped_stems, win_region_start, win_region_end, fade_samples,
    )

    # Full-length mix: splice the recombined window's REGION back into the
    # original full mix (bit-exact outside the region either way, since
    # stem_recombine already preserves outside-region content within the
    # window, and the window itself sits inside splice_region's fade-free
    # copy for anything outside [start_s, end_s)).
    mix_region = mix_window[win_region_start:win_region_end]
    full_mix = splice_region(original_full, mix_region, start_s, end_s, fade_samples)
    mix_path = str(out_dir / f"mix_{variant_index + 1}.wav")
    _write_audio(mix_path, full_mix, sr)

    stem_artifacts: List[Dict[str, Any]] = []
    window_start_s = win_start / sr
    window_end_s = win_end / sr
    for name in scoped_stems:
        stem_path = str(
            out_dir / f"stem_{name}_{variant_index + 1}_window_{window_start_s:.2f}-{window_end_s:.2f}.wav"
        )
        _write_audio(stem_path, stems_out[name], sr)
        kind = name if name in STEM_KINDS else "other"
        stem_artifacts.append(_artifact(kind, stem_path))

    return mix_path, stem_artifacts


def _run_extend_local(job: JobRecord, request: Dict[str, Any], generator: Any, notify: NotifyFn) -> None:
    source_audio = request["sourceAudioRef"]
    if not os.path.exists(source_audio):
        raise GenProtocolError("FILE_NOT_FOUND", f"Source audio not found: {source_audio}",
                                fix="Select a valid audio file and try again.")
    added = float(request["addedDurationSeconds"])
    seed = request.get("seed")
    model = request.get("model") or "acestep-v15-turbo"
    out_dir = _job_output_dir(job.job_id)
    cb = _progress_adapter(job.job_id, notify)

    orig_audio, sr = _read_audio(source_audio)
    source_duration = orig_audio.shape[0] / sr
    total_duration = int(round(source_duration + added))

    raw_path = str(out_dir / "raw_extend.wav")
    metadata = generator.generate_continuation(
        source_audio=source_audio,
        caption=request.get("instruction", "") or "",
        output_path=raw_path,
        duration=total_duration,
        seed=seed,
        model_name=model,
        progress_callback=cb,
    )
    raw_out = metadata.get("file_path", raw_path)
    extended_audio, ext_sr = _read_audio(raw_out)
    if ext_sr != sr:
        raise GenProtocolError("PYTHON_CRASH", f"extend output samplerate {ext_sr} != source samplerate {sr}",
                                fix="Retry; if persistent, file a bug against generate_continuation.")

    join_at = orig_audio.shape[0]
    fade_samples = _seconds_to_samples(DEFAULT_SPLICE_FADE_SECONDS, sr)
    spliced = splice_open_tail(orig_audio, extended_audio, join_at, fade_samples)
    out_path = str(out_dir / "mix.wav")
    _write_audio(out_path, spliced, sr)

    identity = _engine_identity(metadata.get("model", model), metadata.get("num_inference_steps"),
                                 metadata.get("seed", seed), _local_device(generator))
    _REGISTRY.mark_done(job.job_id, [_artifact("mix", out_path)], identity)


def _run_layer_local(job: JobRecord, request: Dict[str, Any], generator: Any, notify: NotifyFn) -> None:
    out_dir = _job_output_dir(job.job_id)
    cb = _progress_adapter(job.job_id, notify)
    context_audio = request.get("contextAudioRef") or ""
    out_path = str(out_dir / "layer.wav")
    metadata = generator.generate_lego(
        source_audio=context_audio,
        instruction=request["instruction"],
        caption=request.get("caption", "") or "",
        output_path=out_path,
        seed=request.get("seed"),
        progress_callback=cb,
    )
    kind = _lego_kind(request["instruction"])
    identity = _engine_identity(metadata.get("model", "acestep-v15-base"), metadata.get("num_inference_steps"),
                                 metadata.get("seed", request.get("seed")), _local_device(generator))
    _REGISTRY.mark_done(job.job_id, [_artifact(kind, metadata.get("file_path", out_path))], identity)


def _lego_kind(instruction: str) -> str:
    """lego can generate ANY named instrument layer, but the artifact kind
    enum is fixed to {mix, vocals, drums, bass, other} (frozen schema). Best
    -effort match against the three named stems, else "other" (proposed as
    an evidence-doc open item: the contract may want a free-text kind for
    lego layers at the next revision)."""
    text = instruction.lower()
    for kind in ("vocals", "drums", "bass"):
        if kind in text or (kind == "vocals" and "vocal" in text):
            return kind
    return "other"


def _run_autocomplete_local(job: JobRecord, request: Dict[str, Any], generator: Any, notify: NotifyFn) -> None:
    source_audio = request["sourceAudioRef"]
    if not os.path.exists(source_audio):
        raise GenProtocolError("FILE_NOT_FOUND", f"Source audio not found: {source_audio}",
                                fix="Select a valid audio file and try again.")
    out_dir = _job_output_dir(job.job_id)
    cb = _progress_adapter(job.job_id, notify)
    out_path = str(out_dir / "mix.wav")
    metadata = generator.generate_auto_complete(
        source_audio=source_audio,
        caption=request["caption"],
        output_path=out_path,
        seed=request.get("seed"),
        progress_callback=cb,
    )
    identity = _engine_identity(metadata.get("model", "acestep-v15-base"), metadata.get("num_inference_steps"),
                                 metadata.get("seed", request.get("seed")), _local_device(generator))
    _REGISTRY.mark_done(job.job_id, [_artifact("mix", metadata.get("file_path", out_path))], identity)


def _run_cover_local(job: JobRecord, request: Dict[str, Any], generator: Any, notify: NotifyFn) -> None:
    reference_audio = request["referenceAudioRef"]
    if not os.path.exists(reference_audio):
        raise GenProtocolError("FILE_NOT_FOUND", f"Reference audio not found: {reference_audio}",
                                fix="Select a valid audio file and try again.")
    out_dir = _job_output_dir(job.job_id)
    cb = _progress_adapter(job.job_id, notify)
    out_path = str(out_dir / "mix.wav")
    metadata = generator.generate_cover(
        reference_audio=reference_audio,
        caption=request["caption"],
        output_path=out_path,
        cover_strength=float(request.get("coverStrength", 0.5)),
        seed=request.get("seed"),
        progress_callback=cb,
    )
    identity = _engine_identity(metadata.get("model", "acestep-v15-turbo"), metadata.get("num_inference_steps"),
                                 metadata.get("seed", request.get("seed")), _local_device(generator))
    _REGISTRY.mark_done(job.job_id, [_artifact("mix", metadata.get("file_path", out_path))], identity)


def _run_separate_local(job: JobRecord, request: Dict[str, Any], generator: Any, notify: NotifyFn) -> None:
    source_audio = request["sourceAudioRef"]
    if not os.path.exists(source_audio):
        raise GenProtocolError("FILE_NOT_FOUND", f"Source audio not found: {source_audio}",
                                fix="Select a valid audio file and try again.")
    engine = request.get("engine", "demucs")
    out_dir = _job_output_dir(job.job_id)
    notify(job.job_id, "separating", 10, f"Running {engine} separation")
    _REGISTRY.update_progress(job.job_id, "separating", 10, f"Running {engine} separation")

    if engine == "demucs":
        result = generator.export_stems(source_audio, str(out_dir))
        artifacts = [_artifact(name, path) for name, path in result["stems"].items()]
        identity = _engine_identity("htdemucs", None, None, "cpu")
    else:
        instruction = request.get("instruction", "") or ""
        out_path = str(out_dir / "extract.wav")
        metadata = generator.generate_extract(
            source_audio=source_audio,
            instruction=instruction,
            caption="",
            output_path=out_path,
        )
        requested = [s.strip().lower() for s in instruction.split(",") if s.strip()] or ["other"]
        artifacts = []
        for name in requested:
            kind = name if name in STEM_KINDS else "other"
            artifacts.append(_artifact(kind, metadata.get("file_path", out_path)))
        identity = _engine_identity(metadata.get("model", "acestep-v15-base"), metadata.get("num_inference_steps"),
                                     metadata.get("seed"), _local_device(generator))
    _REGISTRY.mark_done(job.job_id, artifacts, identity)


def analyze_sync(request: Dict[str, Any], generator: Any) -> Dict[str, Any]:
    """Synchronous per the contract's own /gen/analyze 200 response shape
    (not job-shaped, unlike the other nine ops). See module docstring."""
    source_audio = request["sourceAudioRef"]
    if not os.path.exists(source_audio):
        raise GenProtocolError("FILE_NOT_FOUND", f"Source audio not found: {source_audio}",
                                fix="Select a valid audio file and try again.")
    mode = request.get("mode", "full")
    if mode == "fast":
        import librosa  # noqa: PLC0415
        bpm, key = _extract_metadata(source_audio)
        duration = librosa.get_duration(path=source_audio)
        out: Dict[str, Any] = {
            "bpm": round(bpm) if bpm is not None else None,
            "key": key,
            "duration": round(duration, 1) if duration is not None else None,
            "downbeats": None,
            "loudnessLufs": None,
        }
        return out
    result = generator.understand_music(source_audio)
    return {
        "bpm": result.get("bpm"),
        "key": result.get("key") or None,
        "duration": result.get("duration"),
        "downbeats": None,  # not produced anywhere in the Python backend today
        "loudnessLufs": None,  # planned for the Rust engine's media crate, not Python
        "caption": result.get("caption", ""),
        "lyrics": result.get("lyrics", ""),
        "language": result.get("language", ""),
        "timeSig": result.get("time_signature", ""),
    }


def _run_finalize_local(job: JobRecord, request: Dict[str, Any], generator: Any, notify: NotifyFn) -> None:
    rung = request["targetQualityRung"]
    if rung not in QUALITY_RUNGS:
        raise GenProtocolError(
            code="QUALITY_RUNG_NOT_CONFIGURED",
            message=(
                "targetQualityRung=standard (acestep-v15-quality) has no confirmed step count in any "
                "shipped call site (gen-protocol-mapping.md, finalize section, open question)."
            ),
            fix="Use draft or full until acestep-v15-quality's step count is confirmed in the contract.",
        )
    model, steps = QUALITY_RUNGS[rung]
    inner = request["request"]
    # Finalize reuses the draft's OWN seed for lineage fidelity (mapping.md);
    # the caller supplies it via inner["seed"] (the same seed the draft used).
    seed = inner.get("seed")
    _run_revise_local(job, inner, generator, notify, reuse_seed=seed, model_override=model, steps_override=steps)


_LOCAL_RUNNERS: Dict[str, Callable[..., None]] = {
    "generate": _run_generate_local,
    "revise": _run_revise_local,
    "extend": _run_extend_local,
    "layer": _run_layer_local,
    "autocomplete": _run_autocomplete_local,
    "cover": _run_cover_local,
    "separate": _run_separate_local,
    "finalize": _run_finalize_local,
}


def _run_retake_local(job: JobRecord, request: Dict[str, Any], generator: Any, notify: NotifyFn,
                       lineage_resolver: Optional[Callable[[str], Dict[str, Any]]]) -> None:
    if lineage_resolver is None:
        raise GenProtocolError(
            code="LINEAGE_STORE_NOT_AVAILABLE",
            message=(
                "retake requires resolving sourceTakeId to its originating request (source audio, region, "
                "caption). No lineage store is wired to gen_protocol yet: that is the Rust engine's journal / "
                "takes.list / lineage.get(clipId) (02-ARCHITECTURE.md section 4), out of this lane's scope."
            ),
            fix="Wire a lineage_resolver callable once the engine's takes.list/lineage.get(clipId) read surface exists.",
            step="retake lineage lookup",
        )
    origin = lineage_resolver(request["sourceTakeId"])
    has_region = "regionStartSeconds" in request and "regionEndSeconds" in request
    fresh_seed = request.get("seed")
    if has_region:
        revise_req = {
            "requestId": request["requestId"],
            "sourceAudioRef": origin["sourceAudioRef"],
            "regionStartSeconds": request["regionStartSeconds"],
            "regionEndSeconds": request["regionEndSeconds"],
            "instruction": origin["caption"],
            "scope": "all-stems",
            "seed": fresh_seed,
            "variants": 1,
        }
        _run_revise_local(job, revise_req, generator, notify)
    else:
        generate_req = {
            "requestId": request["requestId"],
            "caption": origin["caption"],
            "seed": fresh_seed,
            "nVariants": 1,
        }
        for k in ("lyrics", "bpm", "key", "timeSig", "vocalLanguage", "model", "steps", "durationSeconds"):
            if k in origin:
                generate_req[k] = origin[k]
        _run_generate_local(job, generate_req, generator, notify)


# ---------------------------------------------------------------------------
# remote-ace route: the EXISTING Swift ServerPool bridge protocol, mirrored
# in Python as ace_generator.RemoteACEStepGenerator. generate only (see
# module docstring point 3). Reuses that class unmodified.
# ---------------------------------------------------------------------------

def _run_generate_remote_ace(job: JobRecord, request: Dict[str, Any], notify: NotifyFn,
                              server_url: str, api_key: Optional[str]) -> None:
    if RemoteACEStepGenerator is None:
        raise GenProtocolError("ACE_STEP_NOT_FOUND", "RemoteACEStepGenerator is unavailable.",
                                fix=str(ACE_GENERATOR_IMPORT_ERROR or ""))
    generator = RemoteACEStepGenerator(server_url, api_key)
    out_dir = _job_output_dir(job.job_id)
    cb = _progress_adapter(job.job_id, notify)
    out_path = str(out_dir / "mix.wav")
    metadata = generator.generate_music(
        caption=request["caption"],
        output_path=out_path,
        lyrics=request.get("lyrics"),
        bpm=request.get("bpm"),
        key=request.get("key"),
        duration=int(request.get("durationSeconds", 150) or 150),
        num_inference_steps=int(request["steps"]) if request.get("steps") is not None else 8,
        seed=request.get("seed"),
        model_name=request.get("model") or "acestep-v15-turbo",
        progress_callback=cb,
        time_signature=request.get("timeSig", "4"),
        vocal_language=request.get("vocalLanguage", ""),
    )
    identity = _engine_identity(metadata.get("model", "acestep-v15-turbo"), request.get("steps"),
                                 metadata.get("seed", request.get("seed")), "remote")
    _REGISTRY.mark_done(job.job_id, [_artifact("mix", metadata.get("file_path", out_path))], identity)


def _run_remote_ace(job: JobRecord, op: str, request: Dict[str, Any], notify: NotifyFn) -> None:
    if op != "generate":
        raise GenProtocolError(
            code="ROUTE_OP_NOT_SUPPORTED",
            message=(
                f"remote-ace does not support op={op!r}. The existing ServerPool bridge protocol "
                "(POST /api/v1/studio/generate) only implements text2music: read directly from "
                "ace_generator.RemoteACEStepGenerator and RemoteGenerationService.swift, neither exposes "
                "task_type, src_audio_path, repainting_start/end, or an instruction/instruction-template field."
            ),
            fix="Use route=local-mlx (or route=gen-node, if a Gen Node / raw ACE-Step api_server is configured) for revise-class ops.",
        )
    server_url = os.environ.get("ACE_STEP_SERVER_URL")
    api_key = os.environ.get("ACE_STEP_SERVER_API_KEY")
    if not server_url:
        raise GenProtocolError("REMOTE_CONNECTION_FAILED", "No ACE_STEP_SERVER_URL configured for route=remote-ace.",
                                fix="Set ACE_STEP_SERVER_URL (and optionally ACE_STEP_SERVER_API_KEY).")
    _run_generate_remote_ace(job, request, notify, server_url, api_key)


# ---------------------------------------------------------------------------
# gen-node route: NEW client for the raw upstream ACE-Step api_server wire
# protocol (P0-A section 1). See module docstring point 4.
# ---------------------------------------------------------------------------

# Status ints straight from the live server's acestep/api/server_utils.py:
# STATUS_MAP = {"queued": 0, "running": 0, "succeeded": 1, "failed": 2}
_STOCK_STATUS_DONE = 1
_STOCK_STATUS_FAILED = 2

# task_type per op, from acestep/constants.py TASK_TYPES (verified live on
# bigboy 2026-07-11; see docs/evidence/l4-gen-protocol.md).
_STOCK_TASK_TYPE = {
    "generate": "text2music",
    "revise": "repaint",
    "extend": "complete",
    "layer": "lego",
    "autocomplete": "complete",
    "cover": "cover",
    "finalize": "repaint",
}


class _StockAceServerClient:
    """Talks to a raw ACE-Step 1.5 api_server instance (P0-A section 1):
    POST /release_task (JSON body only - the form-alias table lacks the
    repaint fields, gen-protocol-mapping.md / session brief), POST
    /query_result to poll, GET /v1/audio?path=... to download. stdlib
    urllib only, matching RemoteACEStepGenerator's own existing style."""

    def __init__(self, base_url: str, api_key: Optional[str] = None, timeout: float = 30.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.timeout = timeout

    def _post(self, path: str, body: Dict[str, Any]) -> Dict[str, Any]:
        if self.api_key:
            body = dict(body, ai_token=self.api_key)
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            f"{self.base_url}{path}", data=data,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                envelope = json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode()[:300] if exc.fp else ""
            raise GenProtocolError("REMOTE_SERVER_ERROR", f"gen-node HTTP {exc.code} on {path}: {detail}",
                                    fix="Check the gen-node / ACE-Step server logs.", detail=detail) from exc
        except urllib.error.URLError as exc:
            raise GenProtocolError("REMOTE_CONNECTION_FAILED", f"Cannot reach gen-node at {self.base_url}: {exc.reason}",
                                    fix="Check MAJIKS_GEN_NODE_URL and that the server is running.") from exc
        if envelope.get("code") not in (200, None) or envelope.get("error"):
            raise GenProtocolError("REMOTE_SERVER_ERROR", f"gen-node returned an error: {envelope.get('error')}",
                                    fix="Check the gen-node / ACE-Step server logs.")
        return envelope.get("data", envelope)

    def get_bytes(self, file_ref: str) -> bytes:
        # The stock ACE-Step api_server's /query_result returns `file` as a
        # READY server-relative download URL, already percent-encoded, e.g.
        # "/v1/audio?path=%2Fhome%2F...%2Fclip.wav" (verified live on bigboy
        # 2026-07-12). Wrapping that in a second /v1/audio?path= layer
        # double-encodes it and the server 403s (the path check resolves the
        # nested string, which is not under temp_audio_dir). So: if file_ref
        # is already a URL or a server-relative URL fragment, use it as-is;
        # only wrap a BARE filesystem path.
        if file_ref.startswith(("http://", "https://")):
            url = file_ref
        elif file_ref.startswith("/") and ("?" in file_ref or file_ref.startswith("/v1/")):
            url = f"{self.base_url}{file_ref}"
        else:
            url = f"{self.base_url}/v1/audio?path={urllib.parse.quote(file_ref, safe='')}"
        req = urllib.request.Request(url, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=max(self.timeout, 60.0)) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            raise GenProtocolError("REMOTE_SERVER_ERROR", f"gen-node audio download HTTP {exc.code}",
                                    fix="Check the gen-node / ACE-Step server logs.") from exc
        except urllib.error.URLError as exc:
            raise GenProtocolError("REMOTE_CONNECTION_FAILED", f"Cannot download audio from gen-node: {exc.reason}",
                                    fix="Check MAJIKS_GEN_NODE_URL and that the server is running.") from exc

    def health(self) -> bool:
        req = urllib.request.Request(f"{self.base_url}/health", method="GET")
        try:
            with urllib.request.urlopen(req, timeout=min(self.timeout, 5.0)):
                return True
        except Exception:  # noqa: BLE001
            return False

    def submit(self, payload: Dict[str, Any]) -> str:
        data = self._post("/release_task", payload)
        task_id = data.get("task_id")
        if not task_id:
            raise GenProtocolError("REMOTE_SERVER_ERROR", "gen-node /release_task did not return a task_id.",
                                    fix="Check the gen-node / ACE-Step server version.")
        return task_id

    def poll_once(self, task_id: str) -> Dict[str, Any]:
        data = self._post("/query_result", {"task_id_list": [task_id]})
        items = data if isinstance(data, list) else []
        if not items:
            return {"status": 0}
        item = items[0]
        result_raw = item.get("result", "[]")
        try:
            result_list = json.loads(result_raw) if isinstance(result_raw, str) else result_raw
        except (TypeError, ValueError):
            result_list = []
        first = result_list[0] if result_list else {}
        return {"status": item.get("status", 0), "first": first}


def _build_stock_payload(op: str, request: Dict[str, Any], model: str, steps: Optional[int],
                          audio_format: str = "wav32") -> Dict[str, Any]:
    task_type = _STOCK_TASK_TYPE[op]
    payload: Dict[str, Any] = {
        "task_type": task_type,
        "model": model,
        "audio_format": audio_format,
        "batch_size": 1,  # Gen Protocol handles variants itself (mapping.md); the
        # server's own default batch_size=2 would silently double every call.
        "thinking": False,  # matches ACESTEP_INIT_LLM=false boot: no LM needed for a
        # plain caption -> DiT call; keeps this route's latency honest and independent
        # of whether an LM backend happens to be loaded on the target server.
        "time_signature": request.get("timeSig", "4"),
        "vocal_language": request.get("vocalLanguage", "") or "en",
    }
    if steps is not None:
        payload["inference_steps"] = int(steps)
    seed = request.get("seed")
    if seed is not None:
        payload["use_random_seed"] = False
        payload["seed"] = int(seed)
    else:
        payload["use_random_seed"] = True

    if op == "generate":
        payload["prompt"] = request["caption"]
        payload["lyrics"] = request.get("lyrics", "") or ""
        payload["audio_duration"] = float(request.get("durationSeconds", 150) or 150)
        if request.get("bpm") is not None:
            payload["bpm"] = int(request["bpm"])
        if request.get("key"):
            payload["key_scale"] = request["key"]
    elif op in ("revise", "finalize"):
        inner = request["request"] if op == "finalize" else request
        payload["prompt"] = inner["instruction"]
        payload["src_audio_path"] = inner["sourceAudioRef"]
        payload["repainting_start"] = float(inner["regionStartSeconds"])
        region_end = float(inner["regionEndSeconds"])
        if region_end >= 0:
            payload["repainting_end"] = region_end
        # P0-A section 2 finding #3: explicit chunk masking measured ~8 dB
        # better outside-region fidelity at no seam-quality cost. Applied
        # only on this new route; local-mlx (ace_generator.py) is untouched.
        payload["chunk_mask_mode"] = "explicit"
        # Deliberately NOT setting "instruction" here: leaving it at the
        # server default lets _resolve_instruction() fill in
        # TASK_INSTRUCTIONS["repaint"] correctly (P0-A section 2 finding #1).
    elif op == "extend":
        payload["prompt"] = request.get("instruction", "") or ""
        payload["src_audio_path"] = request["sourceAudioRef"]
        # audio_duration is set by the caller (run_stock_op) once source
        # duration is known via analyze; placeholder here.
    elif op == "layer":
        payload["prompt"] = request.get("caption", "") or ""
        if request.get("contextAudioRef"):
            payload["src_audio_path"] = request["contextAudioRef"]
        # track_name drives the server's own TASK_INSTRUCTIONS["lego"]
        # template ("Generate the {TRACK_NAME} track based on the audio
        # context:"), which reads better than passing the bare instruction
        # word into the instruction field the way the local route's
        # generate_lego does (P0-A section 2 finding #4). Leaving
        # "instruction" unset lets the server auto-resolve it.
        payload["track_name"] = request["instruction"]
    elif op == "autocomplete":
        payload["prompt"] = request["caption"]
        payload["src_audio_path"] = request["sourceAudioRef"]
    elif op == "cover":
        payload["prompt"] = request["caption"]
        payload["reference_audio_path"] = request["referenceAudioRef"]
        payload["audio_cover_strength"] = float(request.get("coverStrength", 0.5))
    return payload


def _run_stock_op(job: JobRecord, op: str, request: Dict[str, Any], notify: NotifyFn,
                   client: "_StockAceServerClient", *, reuse_seed: Optional[int] = None,
                   model_override: Optional[str] = None, steps_override: Optional[int] = None) -> None:
    if op not in _STOCK_TASK_TYPE:
        raise GenProtocolError("ROUTE_OP_NOT_SUPPORTED",
                                f"gen-node adapter does not implement op={op!r} (separate/analyze have no "
                                "REST equivalent on the stock ACE-Step api_server).",
                                fix="Use route=local-mlx for separate/analyze.")
    default_model, default_steps = QUALITY_RUNGS["full"] if op in ("revise", "layer", "autocomplete", "finalize") \
        else QUALITY_RUNGS["draft"]
    model = model_override or request.get("model") or default_model
    steps = steps_override if steps_override is not None else request.get("steps", default_steps)

    inner_for_source = request["request"] if op == "finalize" else request
    source_ref = inner_for_source.get("sourceAudioRef") or inner_for_source.get("referenceAudioRef") \
        or inner_for_source.get("contextAudioRef")
    need_splice = op in _SPLICE_REQUIRED_OPS or (op == "extend")
    orig_audio = orig_sr = None
    if need_splice and source_ref:
        orig_audio, orig_sr = _read_audio(source_ref)

    payload = _build_stock_payload(op, request, model, steps)
    if op == "extend" and orig_audio is not None:
        added = float(request["addedDurationSeconds"])
        payload["audio_duration"] = round(orig_audio.shape[0] / orig_sr + added)
    if reuse_seed is not None:
        payload["use_random_seed"] = False
        payload["seed"] = int(reuse_seed)

    notify(job.job_id, "submitting", 5, "Submitting to gen-node")
    _REGISTRY.update_progress(job.job_id, "submitting", 5, "Submitting to gen-node")
    task_id = client.submit(payload)

    deadline = time.time() + 600
    result: Dict[str, Any] = {}
    while time.time() < deadline:
        if job.cancel_event.is_set():
            raise _CancelSignal()
        result = client.poll_once(task_id)
        status = result.get("status", 0)
        if status == _STOCK_STATUS_DONE:
            break
        if status == _STOCK_STATUS_FAILED:
            err = result.get("first", {}).get("error") or "gen-node reported task failure"
            raise GenProtocolError("REMOTE_GENERATION_FAILED", str(err),
                                    fix="Check the gen-node / ACE-Step server logs.")
        first = result.get("first", {})
        percent = 10 + int(70 * float(first.get("progress", 0.0) or 0.0))
        stage = first.get("stage") or "generating"
        notify(job.job_id, stage, percent, f"gen-node: {stage}")
        _REGISTRY.update_progress(job.job_id, stage, percent, f"gen-node: {stage}")
        time.sleep(2)
    else:
        raise GenProtocolError("REMOTE_TIMEOUT", "gen-node task timed out after 600s.",
                                fix="Try a shorter duration or check the gen-node server.")

    remote_path = result.get("first", {}).get("file")
    if not remote_path:
        raise GenProtocolError("REMOTE_SERVER_ERROR", "gen-node task succeeded but returned no file path.",
                                fix="Check the gen-node / ACE-Step server version.")
    notify(job.job_id, "downloading", 85, "Downloading from gen-node")
    _REGISTRY.update_progress(job.job_id, "downloading", 85, "Downloading from gen-node")
    audio_bytes = client.get_bytes(remote_path)

    out_dir = _job_output_dir(job.job_id)
    raw_path = out_dir / f"raw_{op}.wav"
    raw_path.write_bytes(audio_bytes)

    artifacts: List[Dict[str, Any]] = []
    if need_splice and orig_audio is not None:
        model_audio, model_sr = _read_audio(str(raw_path))
        if model_sr != orig_sr:
            raise GenProtocolError("PYTHON_CRASH", f"gen-node output samplerate {model_sr} != source {orig_sr}")
        fade_samples = _seconds_to_samples(DEFAULT_SPLICE_FADE_SECONDS, orig_sr)
        if op == "extend":
            join_at = orig_audio.shape[0]
            spliced = splice_open_tail(orig_audio, model_audio, join_at, fade_samples)
        else:
            inner = request["request"] if op == "finalize" else request
            _, _, start_s, end_s, _ = _load_region_context(source_ref, float(inner["regionStartSeconds"]),
                                                             float(inner["regionEndSeconds"]))
            n = min(model_audio.shape[0], orig_audio.shape[0])
            end_s = min(end_s, n)
            spliced = splice_region(orig_audio[:n], model_audio[start_s:end_s], start_s, end_s, fade_samples)
        mix_path = str(out_dir / "mix.wav")
        _write_audio(mix_path, spliced, orig_sr)
        artifacts.append(_artifact("mix", mix_path))
    else:
        artifacts.append(_artifact("mix", str(raw_path)))

    identity = _engine_identity(model, steps, payload.get("seed"), "remote")
    _REGISTRY.mark_done(job.job_id, artifacts, identity)


def _gen_node_client() -> "_StockAceServerClient":
    base_url = os.environ.get("MAJIKS_GEN_NODE_URL")
    if not base_url:
        raise GenProtocolError("REMOTE_CONNECTION_FAILED", "No MAJIKS_GEN_NODE_URL configured for route=gen-node.",
                                fix="Set MAJIKS_GEN_NODE_URL to a reachable ACE-Step api_server (or Gen Node gateway).")
    return _StockAceServerClient(base_url, os.environ.get("MAJIKS_GEN_NODE_API_KEY"))


def _run_gen_node(job: JobRecord, op: str, request: Dict[str, Any], notify: NotifyFn) -> None:
    client = _gen_node_client()
    if op == "finalize":
        rung = request["targetQualityRung"]
        if rung not in QUALITY_RUNGS:
            raise GenProtocolError(
                code="QUALITY_RUNG_NOT_CONFIGURED",
                message="targetQualityRung=standard has no confirmed step count (see gen-protocol-mapping.md).",
                fix="Use draft or full until acestep-v15-quality's step count is confirmed.",
            )
        model, steps = QUALITY_RUNGS[rung]
        seed = request["request"].get("seed")
        _run_stock_op(job, "revise", request["request"], notify, client,
                      reuse_seed=seed, model_override=model, steps_override=steps)
    else:
        _run_stock_op(job, op, request, notify, client)


# ---------------------------------------------------------------------------
# Public API: submit / status / cancel / capabilities
# ---------------------------------------------------------------------------

def submit(op: str, request: Dict[str, Any], *, notify: Optional[NotifyFn] = None,
           lineage_resolver: Optional[Callable[[str], Dict[str, Any]]] = None) -> Dict[str, Any]:
    """gen.submit. Validates, then either:
    - op == "analyze": executes synchronously and returns the analyzeResponse
      shape directly (per the contract's own /gen/analyze 200 response,
      distinct from the other nine ops' 202 submitResponse).
    - otherwise: spawns a background thread and returns {"jobId": requestId}
      immediately; progress/terminal state are reachable via gen.status and
      `notify`.
    """
    request = dict(request or {})
    validate_request(op, request)
    notify = notify or _noop_notify
    job_id = request["requestId"]
    route = request.get("route") or LOCAL_MLX

    if op == "analyze":
        # analyzeRequest has no "route" field in the frozen schema (unlike
        # the other nine ops) - validate_request already rejects one, so
        # this is unconditionally local-mlx; see analyze_sync's docstring.
        generator = get_generator()
        return analyze_sync(request, generator)

    job = _REGISTRY.create(job_id, op=op, route=route)

    def _runner() -> None:
        try:
            if route == LOCAL_MLX:
                with _LOCAL_EXEC_LOCK:
                    if job.cancel_event.is_set():
                        raise _CancelSignal()
                    _REGISTRY.set_running(job_id)
                    generator = get_generator()
                    if op == "retake":
                        _run_retake_local(job, request, generator, notify, lineage_resolver)
                    else:
                        _LOCAL_RUNNERS[op](job, request, generator, notify)
            elif route == REMOTE_ACE:
                _REGISTRY.set_running(job_id)
                _run_remote_ace(job, op, request, notify)
            elif route == GEN_NODE:
                _REGISTRY.set_running(job_id)
                _run_gen_node(job, op, request, notify)
            elif route == UC_CLOUD:
                raise GenProtocolError("NOT_IMPLEMENTED", "uc-cloud route is not implemented in this lane.",
                                        fix="Use local-mlx, remote-ace, or gen-node.")
        except _CancelSignal:
            _REGISTRY.mark_cancelled(job_id)
        except GenProtocolError as exc:
            if job.cancel_event.is_set():
                _REGISTRY.mark_cancelled(job_id)
            else:
                _REGISTRY.mark_failed(job_id, exc.to_dict())
        except GenerationStepError as exc:  # noqa: F821 - real class or shim, both Exception subclasses
            if job.cancel_event.is_set():
                _REGISTRY.mark_cancelled(job_id)
            else:
                _REGISTRY.mark_failed(job_id, {
                    "code": getattr(exc, "code", "PYTHON_CRASH"),
                    "message": getattr(exc, "message", str(exc)),
                    "fix": getattr(exc, "fix", "Restart backend in Settings and try again."),
                    "detail": getattr(exc, "detail", None),
                    "step": getattr(exc, "step", None),
                })
        except Exception as exc:  # noqa: BLE001
            if job.cancel_event.is_set():
                _REGISTRY.mark_cancelled(job_id)
            else:
                _REGISTRY.mark_failed(job_id, {"code": "PYTHON_CRASH", "message": str(exc)})

    t = threading.Thread(target=_runner, daemon=True, name=f"gen-protocol-{job_id}")
    job.thread = t
    t.start()
    return {"jobId": job_id}


def status(job_id: str) -> Dict[str, Any]:
    job = _REGISTRY.get(job_id)
    if job is None:
        raise GenProtocolError("JOB_NOT_FOUND", f"No job with id {job_id!r}.",
                                fix="Check the jobId; jobs are not persisted across backend restarts.")
    return job.to_status_dict()


def cancel(job_id: str) -> Dict[str, Any]:
    _REGISTRY.request_cancel(job_id)
    return {"jobId": job_id}


def capabilities() -> Dict[str, Any]:
    """capabilitiesResponse: per-endpoint op/model/slot support. See module
    docstring points 3-5 for how each route's entry is derived."""
    endpoints: List[Dict[str, Any]] = []

    # local-mlx: everything this lane's mapping implements, gated on whether
    # ace_generator import + list_models() actually work in this environment.
    local_ops = list(OPS)
    local_models: List[str] = []
    if _HAVE_ACE_GENERATOR:
        try:
            local_models = list(get_generator().list_models())
        except Exception:  # noqa: BLE001
            local_models = ["acestep-v15-turbo", "acestep-v15-quality", "acestep-v15-base"]
    else:
        local_ops = []  # nothing runs locally if ace_generator itself failed to import
    endpoints.append({
        "route": LOCAL_MLX,
        "ops": local_ops,
        "models": local_models,
        "concurrentSlots": 1 if local_ops else 0,  # _LOCAL_EXEC_LOCK: one in-flight local job
    })

    # remote-ace: structural fact from reading RemoteACEStepGenerator /
    # RemoteGenerationService.swift (module docstring point 3), not a probe.
    endpoints.append({
        "route": REMOTE_ACE,
        "ops": ["generate"],
        "models": ["acestep-v15-turbo"],
        "concurrentSlots": 2 if os.environ.get("ACE_STEP_SERVER_URL") else 0,
    })

    # gen-node: graceful-unknown probe (session adaptation). Empty unless
    # MAJIKS_GEN_NODE_URL is configured AND reachable.
    gen_node_url = os.environ.get("MAJIKS_GEN_NODE_URL")
    gen_node_ops: List[str] = []
    gen_node_models: List[str] = []
    gen_node_slots = 0
    if gen_node_url:
        try:
            client = _StockAceServerClient(gen_node_url, os.environ.get("MAJIKS_GEN_NODE_API_KEY"))
            if client.health():
                # What P0-A proved the wire protocol supports (section 1);
                # separate/analyze have no REST equivalent on this server.
                gen_node_ops = ["generate", "revise", "extend", "layer", "autocomplete", "cover", "finalize"]
                gen_node_models = ["acestep-v15-turbo", "acestep-v15-base"]
                gen_node_slots = 1
        except Exception:  # noqa: BLE001
            pass
    endpoints.append({
        "route": GEN_NODE,
        "ops": gen_node_ops,
        "models": gen_node_models,
        "concurrentSlots": gen_node_slots,
    })

    # uc-cloud: not implemented in this lane.
    endpoints.append({"route": UC_CLOUD, "ops": [], "models": [], "concurrentSlots": 0})

    return {"endpoints": endpoints}
