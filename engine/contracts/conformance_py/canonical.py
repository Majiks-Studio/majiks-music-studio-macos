"""Canonical JSON + journal hash chain, per engine/contracts/README.md
'Canonicalization and the hash chain'. This module is the single
implementation the fixture generator and the pytest conformance module both
import, so there is exactly one place this logic can drift.
"""
import json

from .blake3_compat import blake3_hex

GENESIS_HASH = "0" * 64

ENVELOPE_HASHED_FIELDS = ("id", "ts", "actor", "name", "params", "inverse", "result")


def canonical_json_bytes(obj) -> bytes:
    """Sorted keys (recursive), compact separators, ASCII-only (non-ASCII
    escaped), no trailing newline. See README.md rules 1-6.

    Numbers follow rule 4: an integer-shaped literal emits as plain digits, a
    float-shaped literal emits as the shortest round-trip decimal. Catalog v2
    PINNED the float half of that rule (deferred proposal 1). Before it, this
    function rejected every float, which meant a real project with a fractional
    gain produced a journal the conformance suite could not hash at all.

    Python's json.dumps uses repr(float) == shortest round-trip, which is
    byte-identical to Rust's serde_json (ryu) Display for every finite f64.
    NaN and +/-inf are NOT valid JSON and are rejected here, matching Rust,
    where serde_json::Number cannot hold them in the first place.
    """
    _reject_non_finite(obj)
    text = json.dumps(
        obj,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
    )
    return text.encode("ascii")


def _reject_non_finite(obj):
    if isinstance(obj, float) and (obj != obj or obj in (float("inf"), float("-inf"))):
        raise ValueError(
            f"canonical_json_bytes: {obj!r} is not representable in JSON and can "
            "never appear in a hashed envelope field."
        )
    if isinstance(obj, dict):
        for v in obj.values():
            _reject_non_finite(v)
    elif isinstance(obj, list):
        for v in obj:
            _reject_non_finite(v)


def envelope_hashed_payload(entry: dict) -> dict:
    """The 7-field object that gets canonicalized+hashed for a journal entry:
    every field except 'hash' itself."""
    return {k: entry[k] for k in ENVELOPE_HASHED_FIELDS}


def compute_entry_hash(prev_hash_hex: str, entry: dict) -> str:
    """hash(n) = blake3_hex(ascii(prev_hash_hex) ++ utf8(canonical_json(entry_without_hash)))"""
    payload = envelope_hashed_payload(entry)
    canonical = canonical_json_bytes(payload)
    return blake3_hex(prev_hash_hex.encode("ascii") + canonical)


def verify_chain(entries: list[dict]) -> tuple[bool, str, int]:
    """Recompute the hash chain over a list of parsed journal entries (dicts
    that include 'hash'). Returns (ok, tip_hash, entry_count). ok is False on
    the first mismatch; tip_hash is the hash the chain actually reaches
    (either matching every stored hash, or the recomputed hash at the point of
    first mismatch, for error messages).
    """
    prev = GENESIS_HASH
    for i, entry in enumerate(entries):
        expected = compute_entry_hash(prev, entry)
        stored = entry.get("hash")
        if expected != stored:
            return False, expected, i
        prev = expected
    return True, prev, len(entries)
