"""Thin htdemucs entry for the engine's "Open in Studio" bridge (lane L8).

The Rust engine's `HtdemucsSeparator` shells out to this so the whole app uses
ONE separation path: it reuses the shipped `ACEGenerator.export_stems`
(htdemucs 4-stem, the same code the Stem Sessions tab and the Gen Protocol
`separate` op call) and prints the four stem paths as a single JSON object on
stdout for the engine to place on the timeline.

Usage:
    python -m majik_backend.separate_cli --in MIX.wav --out OUTPUT_DIR

Output (last stdout line; any library chatter above it is ignored by the engine):
    {"vocals": "...", "drums": "...", "bass": "...", "other": "..."}

Exits nonzero with a message on stderr when separation fails (e.g. demucs not
installed), which the engine surfaces as a clean audio error.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

STEMS = ("vocals", "drums", "bass", "other")


def _via_backend(mix: str, out_dir: str):
    """Reuse the shipped ACEGenerator.export_stems when the full backend is
    importable (production). `export_stems` reads no instance state, so build the
    generator WITHOUT its heavy model-loading __init__."""
    from majik_backend.ace_generator import ACEGenerator  # may need librosa etc.

    generator = ACEGenerator.__new__(ACEGenerator)
    return generator.export_stems(mix, out_dir)["stems"]


def _via_demucs(mix: str, out_dir: str):
    """Lightweight fallback that mirrors ACEGenerator.export_stems exactly
    (`python -m demucs -n htdemucs -o OUT MIX`), so separation only needs
    demucs + torch, not the whole backend."""
    source = Path(mix)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, "-m", "demucs", "-n", "htdemucs", "-o", str(out), str(source)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"Demucs failed: {result.stderr.strip()}")
    track_dir = out / "htdemucs" / source.stem
    if not track_dir.exists():
        raise RuntimeError("Demucs output not found.")
    return {name: str(track_dir / f"{name}.wav") for name in STEMS}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="htdemucs 4-stem separation for Open in Studio")
    parser.add_argument("--in", dest="input", required=True, help="mix audio file")
    parser.add_argument("--out", dest="output", required=True, help="output directory")
    args = parser.parse_args(argv)

    try:
        try:
            stems = _via_backend(args.input, args.output)
        except ImportError:
            # Full backend deps absent; separate with demucs directly.
            stems = _via_demucs(args.input, args.output)
    except Exception as exc:  # noqa: BLE001 - report any failure to the engine
        print(f"separate_cli: htdemucs separation failed: {exc}", file=sys.stderr)
        return 1

    missing = [name for name in STEMS if name not in stems]
    if missing:
        print(f"separate_cli: separation produced no {', '.join(missing)} stem", file=sys.stderr)
        return 1

    # The engine reads the LAST JSON line on stdout.
    print(json.dumps({name: stems[name] for name in STEMS}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
