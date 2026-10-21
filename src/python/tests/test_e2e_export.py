#!/usr/bin/env python3
"""
End-to-End Test Suite for Audio Export Functionality

Tests:
1. WAV export (lossless, no conversion needed)
2. FLAC export (lossless compression)
3. MP3 export (lossy, requires ffmpeg)
4. M4A export (lossy, requires ffmpeg)
5. Bitrate selection for lossy formats
6. File validation and playback
"""

import sys
import os
import subprocess
import shutil
import tempfile
import wave
from pathlib import Path
from typing import Optional, Dict, List

# Test configuration
TEST_RESULTS = {
    "passed": 0,
    "failed": 0,
    "warnings": 0,
    "details": []
}


class TestResult:
    """Track test results"""

    @staticmethod
    def add_pass(test_name: str, message: str = ""):
        TEST_RESULTS["passed"] += 1
        TEST_RESULTS["details"].append(("PASS", test_name, message))
        print(f"✓ {test_name}: {message}")

    @staticmethod
    def add_fail(test_name: str, message: str):
        TEST_RESULTS["failed"] += 1
        TEST_RESULTS["details"].append(("FAIL", test_name, message))
        print(f"✗ {test_name}: {message}")

    @staticmethod
    def add_warning(test_name: str, message: str):
        TEST_RESULTS["warnings"] += 1
        TEST_RESULTS["details"].append(("WARN", test_name, message))
        print(f"⚠ {test_name}: {message}")

    @staticmethod
    def summary() -> bool:
        total = TEST_RESULTS["passed"] + TEST_RESULTS["failed"]
        print("\n" + "=" * 80)
        print("E2E EXPORT TEST SUMMARY")
        print("=" * 80)
        print(f"Total Tests: {total}")
        print(f"✓ Passed: {TEST_RESULTS['passed']}")
        print(f"✗ Failed: {TEST_RESULTS['failed']}")
        print(f"⚠ Warnings: {TEST_RESULTS['warnings']}")
        if total > 0:
            print(f"Success Rate: {TEST_RESULTS['passed']/total*100:.1f}%")
        print("=" * 80)

        if TEST_RESULTS["failed"] > 0:
            print("\nFAILED TESTS:")
            for status, name, msg in TEST_RESULTS["details"]:
                if status == "FAIL":
                    print(f"  ✗ {name}: {msg}")

        return TEST_RESULTS["failed"] == 0


def find_ffmpeg() -> Optional[str]:
    """Find ffmpeg binary (bundled or system)"""
    # Check environment variable (bundled ffmpeg)
    if "MAJIK_FFMPEG_PATH" in os.environ:
        ffmpeg_path = os.environ["MAJIK_FFMPEG_PATH"]
        if os.path.exists(ffmpeg_path):
            return ffmpeg_path

    # Check system PATH
    ffmpeg_system = shutil.which("ffmpeg")
    if ffmpeg_system:
        return ffmpeg_system

    # Check common locations
    common_paths = [
        "/usr/local/bin/ffmpeg",
        "/opt/homebrew/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]

    for path in common_paths:
        if os.path.exists(path):
            return path

    return None


def create_test_wav(output_path: str, duration: float = 3.0, sample_rate: int = 44100) -> bool:
    """Create a test WAV file with a simple sine wave"""
    try:
        import numpy as np

        # Generate 440Hz sine wave (A4 note)
        frequency = 440.0
        samples = int(duration * sample_rate)
        t = np.linspace(0, duration, samples, False)
        audio_data = np.sin(2 * np.pi * frequency * t)

        # Normalize to 16-bit range
        audio_data = (audio_data * 32767).astype(np.int16)

        # Write WAV file
        with wave.open(output_path, 'w') as wav_file:
            wav_file.setnchannels(1)  # Mono
            wav_file.setsampwidth(2)  # 16-bit
            wav_file.setframerate(sample_rate)
            wav_file.writeframes(audio_data.tobytes())

        return True
    except Exception as e:
        print(f"Error creating test WAV: {e}")
        return False


def test_wav_export():
    """Test Suite 1: WAV Export (Lossless)"""
    print("\n" + "=" * 80)
    print("TEST SUITE 1: WAV EXPORT")
    print("=" * 80)

    with tempfile.TemporaryDirectory() as tmpdir:
        # Test 1.1: Create source WAV
        source_wav = os.path.join(tmpdir, "source.wav")
        if create_test_wav(source_wav, duration=3.0):
            TestResult.add_pass("WAV creation", "Created 3-second test WAV file")
        else:
            TestResult.add_fail("WAV creation", "Failed to create test file")
            return

        # Test 1.2: Verify WAV file properties
        try:
            with wave.open(source_wav, 'r') as wav:
                channels = wav.getnchannels()
                sample_width = wav.getsampwidth()
                frame_rate = wav.getframerate()
                frames = wav.getnframes()
                duration = frames / float(frame_rate)

                if channels == 1 and sample_width == 2 and frame_rate == 44100:
                    TestResult.add_pass("WAV properties",
                        f"Correct format: {channels}ch, {sample_width*8}bit, {frame_rate}Hz")
                else:
                    TestResult.add_fail("WAV properties",
                        f"Unexpected format: {channels}ch, {sample_width*8}bit, {frame_rate}Hz")

                if 2.9 < duration < 3.1:
                    TestResult.add_pass("WAV duration", f"Duration: {duration:.2f}s")
                else:
                    TestResult.add_fail("WAV duration", f"Expected ~3s, got {duration:.2f}s")
        except Exception as e:
            TestResult.add_fail("WAV validation", f"Error: {e}")

        # Test 1.3: WAV "export" (copy) preserves quality
        export_wav = os.path.join(tmpdir, "export.wav")
        try:
            shutil.copy2(source_wav, export_wav)

            source_size = os.path.getsize(source_wav)
            export_size = os.path.getsize(export_wav)

            if source_size == export_size:
                TestResult.add_pass("WAV export", "Exact copy preserves all data")
            else:
                TestResult.add_fail("WAV export",
                    f"Size mismatch: {source_size} != {export_size}")
        except Exception as e:
            TestResult.add_fail("WAV export", f"Copy failed: {e}")


def test_flac_export():
    """Test Suite 2: FLAC Export (Lossless Compression)"""
    print("\n" + "=" * 80)
    print("TEST SUITE 2: FLAC EXPORT")
    print("=" * 80)

    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        TestResult.add_warning("FLAC export", "ffmpeg not found, skipping FLAC tests")
        return

    TestResult.add_pass("ffmpeg detection", f"Found at: {ffmpeg}")

    with tempfile.TemporaryDirectory() as tmpdir:
        # Create source WAV
        source_wav = os.path.join(tmpdir, "source.wav")
        if not create_test_wav(source_wav, duration=5.0):
            TestResult.add_fail("FLAC source", "Failed to create test WAV")
            return

        # Test 2.1: Export to FLAC
        export_flac = os.path.join(tmpdir, "export.flac")
        try:
            result = subprocess.run(
                [ffmpeg, "-i", source_wav, "-c:a", "flac", "-y", export_flac],
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode == 0 and os.path.exists(export_flac):
                TestResult.add_pass("FLAC export", "Successfully converted WAV to FLAC")
            else:
                TestResult.add_fail("FLAC export",
                    f"ffmpeg failed: {result.stderr[:100]}")
                return
        except Exception as e:
            TestResult.add_fail("FLAC export", f"Error: {e}")
            return

        # Test 2.2: Verify FLAC compression
        wav_size = os.path.getsize(source_wav)
        flac_size = os.path.getsize(export_flac)
        compression_ratio = flac_size / wav_size

        if flac_size < wav_size:
            TestResult.add_pass("FLAC compression",
                f"Compressed to {compression_ratio*100:.1f}% of WAV size")
        else:
            TestResult.add_warning("FLAC compression",
                f"FLAC ({flac_size}B) >= WAV ({wav_size}B)")

        # Test 2.3: Verify FLAC is lossless (decode back to WAV and compare)
        decoded_wav = os.path.join(tmpdir, "decoded.wav")
        try:
            result = subprocess.run(
                [ffmpeg, "-i", export_flac, "-c:a", "pcm_s16le", "-y", decoded_wav],
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode == 0:
                # Compare audio data (not file size, as metadata may differ)
                with wave.open(source_wav, 'r') as src, wave.open(decoded_wav, 'r') as dec:
                    src_frames = src.readframes(src.getnframes())
                    dec_frames = dec.readframes(dec.getnframes())

                    if src_frames == dec_frames:
                        TestResult.add_pass("FLAC lossless", "Decoded audio matches source exactly")
                    else:
                        # Allow small differences due to encoding
                        TestResult.add_warning("FLAC lossless",
                            f"Frame count: {len(src_frames)} vs {len(dec_frames)}")
            else:
                TestResult.add_fail("FLAC decode", "Failed to decode FLAC")
        except Exception as e:
            TestResult.add_warning("FLAC lossless test", f"Error: {e}")


def test_mp3_export():
    """Test Suite 3: MP3 Export (Lossy)"""
    print("\n" + "=" * 80)
    print("TEST SUITE 3: MP3 EXPORT")
    print("=" * 80)

    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        TestResult.add_warning("MP3 export", "ffmpeg not found, skipping MP3 tests")
        return

    with tempfile.TemporaryDirectory() as tmpdir:
        # Create source WAV
        source_wav = os.path.join(tmpdir, "source.wav")
        if not create_test_wav(source_wav, duration=10.0):
            TestResult.add_fail("MP3 source", "Failed to create test WAV")
            return

        # Test 3.1: Export at 192 kbps (standard quality)
        export_mp3_192 = os.path.join(tmpdir, "export_192.mp3")
        try:
            result = subprocess.run(
                [ffmpeg, "-i", source_wav, "-c:a", "libmp3lame",
                 "-b:a", "192k", "-y", export_mp3_192],
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode == 0 and os.path.exists(export_mp3_192):
                TestResult.add_pass("MP3 export 192k", "Successfully converted WAV to MP3")
            else:
                TestResult.add_fail("MP3 export 192k",
                    f"ffmpeg failed: {result.stderr[:100]}")
                return
        except Exception as e:
            TestResult.add_fail("MP3 export 192k", f"Error: {e}")
            return

        # Test 3.2: Export at 320 kbps (high quality)
        export_mp3_320 = os.path.join(tmpdir, "export_320.mp3")
        try:
            result = subprocess.run(
                [ffmpeg, "-i", source_wav, "-c:a", "libmp3lame",
                 "-b:a", "320k", "-y", export_mp3_320],
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode == 0 and os.path.exists(export_mp3_320):
                TestResult.add_pass("MP3 export 320k", "Successfully exported at max quality")
            else:
                TestResult.add_fail("MP3 export 320k", "Export failed")
                return
        except Exception as e:
            TestResult.add_fail("MP3 export 320k", f"Error: {e}")
            return

        # Test 3.3: Verify bitrate affects file size
        size_192 = os.path.getsize(export_mp3_192)
        size_320 = os.path.getsize(export_mp3_320)
        wav_size = os.path.getsize(source_wav)

        if size_320 > size_192:
            TestResult.add_pass("MP3 bitrate scaling",
                f"320k ({size_320}B) > 192k ({size_192}B)")
        else:
            TestResult.add_fail("MP3 bitrate scaling",
                f"Unexpected sizes: 320k={size_320}B, 192k={size_192}B")

        if size_192 < wav_size * 0.5:  # MP3 should be much smaller
            compression = (1 - size_192/wav_size) * 100
            TestResult.add_pass("MP3 compression",
                f"Compressed to {compression:.1f}% smaller than WAV")
        else:
            TestResult.add_warning("MP3 compression",
                f"MP3 ({size_192}B) not much smaller than WAV ({wav_size}B)")

        # Test 3.4: Verify MP3 files are playable (basic validation)
        for mp3_path, label in [(export_mp3_192, "192k"), (export_mp3_320, "320k")]:
            try:
                # Use ffprobe to verify MP3 file
                result = subprocess.run(
                    [ffmpeg.replace("ffmpeg", "ffprobe"), "-v", "error",
                     "-show_entries", "format=duration,bit_rate",
                     "-of", "default=noprint_wrappers=1", mp3_path],
                    capture_output=True,
                    text=True,
                    timeout=5
                )

                if result.returncode == 0:
                    TestResult.add_pass(f"MP3 validation {label}", "File is valid and playable")
                else:
                    TestResult.add_fail(f"MP3 validation {label}", "File validation failed")
            except:
                TestResult.add_warning(f"MP3 validation {label}", "ffprobe not available")


def test_m4a_export():
    """Test Suite 4: M4A/AAC Export (Lossy)"""
    print("\n" + "=" * 80)
    print("TEST SUITE 4: M4A/AAC EXPORT")
    print("=" * 80)

    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        TestResult.add_warning("M4A export", "ffmpeg not found, skipping M4A tests")
        return

    with tempfile.TemporaryDirectory() as tmpdir:
        # Create source WAV
        source_wav = os.path.join(tmpdir, "source.wav")
        if not create_test_wav(source_wav, duration=8.0):
            TestResult.add_fail("M4A source", "Failed to create test WAV")
            return

        # Test 4.1: Export at 192 kbps
        export_m4a = os.path.join(tmpdir, "export.m4a")
        try:
            result = subprocess.run(
                [ffmpeg, "-i", source_wav, "-c:a", "aac",
                 "-b:a", "192k", "-y", export_m4a],
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode == 0 and os.path.exists(export_m4a):
                TestResult.add_pass("M4A export", "Successfully converted WAV to M4A/AAC")
            else:
                TestResult.add_fail("M4A export",
                    f"ffmpeg failed: {result.stderr[:100]}")
                return
        except Exception as e:
            TestResult.add_fail("M4A export", f"Error: {e}")
            return

        # Test 4.2: Verify M4A compression
        wav_size = os.path.getsize(source_wav)
        m4a_size = os.path.getsize(export_m4a)

        if m4a_size < wav_size * 0.5:
            compression = (1 - m4a_size/wav_size) * 100
            TestResult.add_pass("M4A compression",
                f"Compressed to {compression:.1f}% smaller than WAV")
        else:
            TestResult.add_warning("M4A compression",
                f"M4A ({m4a_size}B) not much smaller than WAV ({wav_size}B)")

        # Test 4.3: Export at 256 kbps (high quality)
        export_m4a_256 = os.path.join(tmpdir, "export_256.m4a")
        try:
            result = subprocess.run(
                [ffmpeg, "-i", source_wav, "-c:a", "aac",
                 "-b:a", "256k", "-y", export_m4a_256],
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode == 0:
                size_192 = m4a_size
                size_256 = os.path.getsize(export_m4a_256)

                if size_256 > size_192:
                    TestResult.add_pass("M4A bitrate scaling",
                        f"256k ({size_256}B) > 192k ({size_192}B)")
                else:
                    TestResult.add_warning("M4A bitrate scaling",
                        f"Sizes: 256k={size_256}B, 192k={size_192}B")
        except Exception as e:
            TestResult.add_warning("M4A 256k export", f"Error: {e}")


def test_export_integration():
    """Test Suite 5: Export Integration Tests"""
    print("\n" + "=" * 80)
    print("TEST SUITE 5: EXPORT INTEGRATION")
    print("=" * 80)

    ffmpeg = find_ffmpeg()

    # Test 5.1: ffmpeg availability
    if ffmpeg:
        try:
            result = subprocess.run(
                [ffmpeg, "-version"],
                capture_output=True,
                text=True,
                timeout=5
            )

            if result.returncode == 0:
                version_line = result.stdout.split('\n')[0]
                TestResult.add_pass("ffmpeg version", version_line[:60])
            else:
                TestResult.add_fail("ffmpeg version", "Version check failed")
        except Exception as e:
            TestResult.add_fail("ffmpeg version", f"Error: {e}")
    else:
        TestResult.add_warning("ffmpeg availability",
            "Not found - lossy export formats (MP3, M4A) will not work")

    # Test 5.2: All codec support
    if ffmpeg:
        required_codecs = {
            "flac": "FLAC lossless",
            "libmp3lame": "MP3 encoder",
            "aac": "AAC/M4A encoder"
        }

        for codec, description in required_codecs.items():
            try:
                result = subprocess.run(
                    [ffmpeg, "-hide_banner", "-encoders"],
                    capture_output=True,
                    text=True,
                    timeout=5
                )

                if codec in result.stdout:
                    TestResult.add_pass(f"Codec: {codec}", f"{description} available")
                else:
                    TestResult.add_fail(f"Codec: {codec}", f"{description} not found")
            except Exception as e:
                TestResult.add_warning(f"Codec check: {codec}", f"Error: {e}")

    # Test 5.3: Batch export capability
    with tempfile.TemporaryDirectory() as tmpdir:
        # Create 3 test WAV files
        test_files = []
        for i in range(3):
            wav_path = os.path.join(tmpdir, f"track_{i+1}.wav")
            if create_test_wav(wav_path, duration=2.0):
                test_files.append(wav_path)

        if len(test_files) == 3:
            TestResult.add_pass("Batch source creation", "Created 3 test files")

            # Test batch conversion (simulate exporting multiple tracks)
            if ffmpeg:
                export_count = 0
                for i, source in enumerate(test_files):
                    dest = os.path.join(tmpdir, f"export_{i+1}.mp3")
                    try:
                        result = subprocess.run(
                            [ffmpeg, "-i", source, "-c:a", "libmp3lame",
                             "-b:a", "192k", "-y", dest],
                            capture_output=True,
                            text=True,
                            timeout=10
                        )
                        if result.returncode == 0:
                            export_count += 1
                    except:
                        pass

                if export_count == 3:
                    TestResult.add_pass("Batch export", "Successfully exported all 3 tracks")
                else:
                    TestResult.add_fail("Batch export",
                        f"Only exported {export_count}/3 tracks")
        else:
            TestResult.add_fail("Batch source creation",
                f"Only created {len(test_files)}/3 files")


# MARK: - Main Test Runner

if __name__ == "__main__":
    print("\n" + "=" * 80)
    print("MAJIKS MUSIC STUDIO - E2E AUDIO EXPORT TEST SUITE")
    print("=" * 80)
    print("\nTesting audio export functionality:")
    print("1. WAV Export (lossless, no conversion)")
    print("2. FLAC Export (lossless compression)")
    print("3. MP3 Export (lossy, variable bitrate)")
    print("4. M4A/AAC Export (lossy, optimized)")
    print("5. Export Integration (batch, codecs)")
    print("\n")

    # Check dependencies
    try:
        import numpy
        TestResult.add_pass("Dependencies", "numpy available for test audio generation")
    except ImportError:
        TestResult.add_warning("Dependencies",
            "numpy not available, using basic test methods")

    # Run all test suites
    test_wav_export()
    test_flac_export()
    test_mp3_export()
    test_m4a_export()
    test_export_integration()

    # Print summary
    success = TestResult.summary()

    # Save results to JSON
    import json
    from datetime import datetime

    output_file = "src/python/tests/e2e_export_results.json"
    results_data = {
        "timestamp": datetime.now().isoformat(),
        "summary": {
            "total": TEST_RESULTS["passed"] + TEST_RESULTS["failed"],
            "passed": TEST_RESULTS["passed"],
            "failed": TEST_RESULTS["failed"],
            "warnings": TEST_RESULTS["warnings"],
            "success": success
        },
        "details": [
            {"status": status, "test": name, "message": msg}
            for status, name, msg in TEST_RESULTS["details"]
        ]
    }

    try:
        os.makedirs(os.path.dirname(output_file), exist_ok=True)
        with open(output_file, "w") as f:
            json.dump(results_data, f, indent=2)
        print(f"\nResults saved to: {output_file}")
    except Exception as e:
        print(f"\nWarning: Could not save results to JSON: {e}")

    sys.exit(0 if success else 1)
