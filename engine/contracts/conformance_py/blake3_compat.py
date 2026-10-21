"""blake3_hex(data) -> 64-char lowercase hex digest.

Prefers the compiled `blake3` PyPI package when it is importable (fast); falls
back to blake3_pure.Hasher (this directory) otherwise. Both paths are required
to agree - see test_conformance.py's test_pure_blake3_matches_compiled_when_available.
"""
from . import blake3_pure

try:
    import blake3 as _compiled_blake3
    HAVE_COMPILED_BLAKE3 = True
except ImportError:
    _compiled_blake3 = None
    HAVE_COMPILED_BLAKE3 = False


def blake3_hex(data: bytes) -> str:
    if HAVE_COMPILED_BLAKE3:
        return _compiled_blake3.blake3(data).hexdigest()
    return blake3_pure.blake3_hex(data)
