#!/usr/bin/env python3
"""
Deterministic test audio fixture generator for Majik's Music Studio DAW engine.

Generates a small set of reproducible WAV files for testing:
- Sine sweeps (48 kHz stereo, 44.1 kHz stereo for SRC path)
- Click tracks at 92, 120, 174 BPM (for timing/grid tests)
- Mono tone (440 Hz, for mono upmix tests)

Relationship to engine/fixtures: the Rust gen-fixtures bin
(cargo run -p render --bin gen-fixtures) is the CANONICAL fixture set for
engine tests; it emits 32-bit float WAVs pinned by blake3 in
engine/fixtures/MANIFEST.json. This script covers the same six specs as an
independent Python implementation (16-bit PCM, its own click/tone shapes) so
Python-side tooling can get deterministic audio without a Rust toolchain.
The two sets are NOT bit-identical and are pinned by separate manifests.

Files are gitignored and generated on demand. Hashes are verified against
TESTDATA_MANIFEST.json (committed) to detect changes. Hash algorithm is
recorded in the manifest (blake3 when the python blake3 module is installed,
sha256 fallback otherwise; the committed manifest says which).

Usage:
    python3 generate_testdata.py                  # generate missing files, verify hashes
    python3 generate_testdata.py --write-manifest # regenerate all, update manifest
    python3 generate_testdata.py --check          # verify hashes only
"""

import struct
import math
import json
import hashlib
import sys
from pathlib import Path

# Test fixture specifications matching engine/render/src/fixtures.rs
FIXTURES = [
    {
        "name": "sweep_48k_stereo.wav",
        "sample_rate": 48000,
        "channels": 2,
        "seconds": 8.0,
        "kind": "sweep",
        "f0": 30.0,
        "f1": 8000.0,
    },
    {
        "name": "sweep_44k1_stereo.wav",
        "sample_rate": 44100,
        "channels": 2,
        "seconds": 6.0,
        "kind": "sweep",
        "f0": 40.0,
        "f1": 6000.0,
    },
    {
        "name": "click_92bpm_48k_stereo.wav",
        "sample_rate": 48000,
        "channels": 2,
        "seconds": 8.0,
        "kind": "click",
        "bpm": 92.0,
    },
    {
        "name": "click_120bpm_48k_stereo.wav",
        "sample_rate": 48000,
        "channels": 2,
        "seconds": 8.0,
        "kind": "click",
        "bpm": 120.0,
    },
    {
        "name": "click_174bpm_48k_stereo.wav",
        "sample_rate": 48000,
        "channels": 2,
        "seconds": 8.0,
        "kind": "click",
        "bpm": 174.0,
    },
    {
        "name": "tone_440_48k_mono.wav",
        "sample_rate": 48000,
        "channels": 1,
        "seconds": 4.0,
        "kind": "tone",
        "hz": 440.0,
    },
]

def sample_value(spec, i):
    """Generate a single sample value (mono) at frame i.

    Pure f64 math, deterministic, matches engine/render/src/fixtures.rs.
    """
    rate = float(spec["sample_rate"])
    t = i / rate
    kind = spec["kind"]

    if kind == "sweep":
        # Exponential sine sweep: phase = 2π*f0*(e^(kt)-1)/k where k = ln(f1/f0)/duration
        f0 = spec["f0"]
        f1 = spec["f1"]
        duration = spec["seconds"]
        k = math.log(f1 / f0) / duration
        phase = 2 * math.pi * f0 * (math.exp(k * t) - 1.0) / k
        return 0.5 * math.sin(phase)

    elif kind == "click":
        # Click track: short decaying tone bursts on beat grid, accented downbeat every 4 beats.
        bpm = spec["bpm"]
        beat_duration = 60.0 / bpm

        # Position within the current beat
        pos = t % beat_duration

        # Click duration and envelope
        click_duration = 0.05  # 50 ms click
        if pos < click_duration:
            # Decaying sine at 800 Hz
            freq = 800.0
            envelope = 1.0 - (pos / click_duration)  # linear decay
            return 0.3 * envelope * math.sin(2 * math.pi * freq * pos)
        else:
            return 0.0

    elif kind == "tone":
        # Steady tone with 10 ms edge ramps
        hz = spec["hz"]
        ramp_time = 0.01
        duration = spec["seconds"]

        # Ramp in at start
        if t < ramp_time:
            envelope = t / ramp_time
        # Ramp out at end
        elif t > duration - ramp_time:
            envelope = (duration - t) / ramp_time
        else:
            envelope = 1.0

        return 0.4 * envelope * math.sin(2 * math.pi * hz * t)

    return 0.0

def write_wav(spec, filepath):
    """Write a WAV file from spec with deterministic samples."""
    sample_rate = spec["sample_rate"]
    channels = spec["channels"]
    seconds = spec["seconds"]
    num_frames = int(sample_rate * seconds)

    # Generate samples (16-bit signed)
    samples = []
    for i in range(num_frames):
        for ch in range(channels):
            # Same value for all channels (or apply per-channel variation if needed)
            value = sample_value(spec, i)
            # Clamp to [-1, 1]
            value = max(-1.0, min(1.0, value))
            # Convert to 16-bit signed
            sample_int = int(value * 32767)
            samples.append(struct.pack("<h", sample_int))

    # Write WAV header
    byte_rate = sample_rate * channels * 2
    block_align = channels * 2
    subchunk2_size = len(samples) // 2  # in bytes (each sample is 2 bytes)
    chunk_size = 36 + subchunk2_size

    with open(filepath, "wb") as f:
        # RIFF header
        f.write(b"RIFF")
        f.write(struct.pack("<I", chunk_size))
        f.write(b"WAVE")

        # fmt subchunk
        f.write(b"fmt ")
        f.write(struct.pack("<I", 16))  # subchunk1 size
        f.write(struct.pack("<H", 1))   # audio format (PCM)
        f.write(struct.pack("<H", channels))
        f.write(struct.pack("<I", sample_rate))
        f.write(struct.pack("<I", byte_rate))
        f.write(struct.pack("<H", block_align))
        f.write(struct.pack("<H", 16))  # bits per sample

        # data subchunk
        f.write(b"data")
        f.write(struct.pack("<I", subchunk2_size))
        f.writelines(samples)

def hash_algo():
    """Name of the hash algorithm in use (blake3 if installed, else sha256)."""
    try:
        import blake3  # noqa: F401
        return "blake3"
    except ImportError:
        return "sha256"

def compute_hash(filepath):
    """Hash a file with the available algorithm (see hash_algo)."""
    with open(filepath, "rb") as f:
        data = f.read()
    if hash_algo() == "blake3":
        import blake3
        return blake3.blake3(data).hexdigest()
    return hashlib.sha256(data).hexdigest()

def generate_all(output_dir):
    """Generate all fixtures and return hash manifest."""
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest = {}

    for spec in FIXTURES:
        filepath = output_dir / spec["name"]
        write_wav(spec, filepath)
        file_hash = compute_hash(filepath)
        manifest[spec["name"]] = file_hash
        print(f"Generated: {spec['name']:40} {file_hash[:16]}...")

    return manifest

def ensure_all(output_dir, manifest_path):
    """Ensure all fixtures exist and verify hashes."""
    output_dir.mkdir(parents=True, exist_ok=True)

    # Load manifest
    if manifest_path.exists():
        with open(manifest_path) as f:
            doc = json.load(f)
        manifest = doc["files"]
        pinned_algo = doc.get("hash_algo", "sha256")
        if pinned_algo != hash_algo():
            print(f"NOTE: manifest pinned with {pinned_algo} but this environment "
                  f"hashes with {hash_algo()}; verification will report mismatches. "
                  f"Install the matching hasher or regenerate with --write-manifest.")
    else:
        print("Warning: TESTDATA_MANIFEST.json not found. Generating fresh fixtures...")
        manifest = {}

    # Check each fixture
    all_ok = True
    for spec in FIXTURES:
        filepath = output_dir / spec["name"]

        if not filepath.exists():
            print(f"Missing: {spec['name']} - generating...")
            write_wav(spec, filepath)

        # Verify hash if in manifest
        if spec["name"] in manifest:
            file_hash = compute_hash(filepath)
            expected = manifest[spec["name"]]
            if file_hash == expected:
                print(f"OK: {spec['name']:40} hash verified")
            else:
                print(f"HASH MISMATCH: {spec['name']}")
                print(f"  Expected: {expected}")
                print(f"  Got:      {file_hash}")
                all_ok = False

    return all_ok

def write_manifest(output_dir, manifest):
    """Write manifest to TESTDATA_MANIFEST.json (committed to git)."""
    manifest_path = output_dir / "TESTDATA_MANIFEST.json"
    data = {"hash_algo": hash_algo(), "files": manifest}
    with open(manifest_path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"Wrote manifest: {manifest_path} (hash_algo={hash_algo()})")

def main():
    script_dir = Path(__file__).parent
    output_dir = script_dir
    manifest_path = script_dir / "TESTDATA_MANIFEST.json"

    args = sys.argv[1:]

    if "--write-manifest" in args:
        print("Regenerating all fixtures and manifest...")
        manifest = generate_all(output_dir)
        write_manifest(output_dir, manifest)
        print("Done.")
    elif "--check" in args:
        print("Checking fixtures...")
        if ensure_all(output_dir, manifest_path):
            print("All fixtures OK")
            sys.exit(0)
        else:
            print("Some fixtures failed verification")
            sys.exit(1)
    else:
        # Default: generate missing, verify present
        print("Ensuring fixtures...")
        if ensure_all(output_dir, manifest_path):
            print(f"Fixtures OK ({len(FIXTURES)} files)")
            sys.exit(0)
        else:
            print("Some fixtures failed verification")
            sys.exit(1)

if __name__ == "__main__":
    main()
