"""Shared fixtures for the gen_protocol test suite (lane L4).

MockGenerator implements the same method surface as
ace_generator.ACEStepGenerator (generate_music, generate_repaint,
generate_continuation, generate_lego, generate_auto_complete, generate_cover,
generate_extract, generate_variants, export_stems, understand_music,
list_models) closely enough to exercise gen_protocol.py's real pipeline
(job registry -> background thread -> generator call -> splice -> blake3
hash -> terminal state) end to end without torch/acestep. It writes real
(small, synthetic) WAV files so the splice/hash code under test operates on
real audio data, not stand-ins.
"""
from __future__ import annotations

import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

import numpy as np
import pytest
import soundfile as sf

SR = 8000  # small, fast synthetic sample rate for tests


def sine(seconds: float, freq: float = 220.0, sr: int = SR, amplitude: float = 0.2) -> np.ndarray:
    n = int(round(seconds * sr))
    t = np.arange(n, dtype=np.float64) / sr
    return (amplitude * np.sin(2 * np.pi * freq * t)).reshape(-1, 1)


def write_wav(path: str, audio: np.ndarray, sr: int = SR) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    sf.write(path, audio, sr, subtype="FLOAT")


class MockGenerator:
    """Stand-in for ACEStepGenerator / RemoteACEStepGenerator.

    `calls` records every method invocation (name, kwargs) for assertions.
    `device` mirrors ACEStepGenerator.device.
    `fail_op` (if set) makes that one method raise GenerationStepError-shaped
    errors, for terminal-failure tests.
    """

    def __init__(self, sr: int = SR, fail_op: Optional[str] = None,
                 pause_after_stage: Optional[str] = None) -> None:
        self.sr = sr
        self.device = "cpu"
        self.calls: List[Dict[str, Any]] = []
        self.fail_op = fail_op
        self.checkpoint_dir = "/nonexistent/checkpoints"
        # For deterministic cancellation tests: if set, _progress() blocks
        # after emitting a callback whose stage == pause_after_stage until
        # the test calls resume_event.set(). This gives the test a window to
        # call gen_protocol.cancel(job_id) while a job is provably still
        # in-flight, without a real sleep-based race.
        self.pause_after_stage = pause_after_stage
        self.paused_event = threading.Event()  # set by the mock once paused
        self.resume_event = threading.Event()  # set by the test to unpause

    def _record(self, name: str, kwargs: Dict[str, Any]) -> None:
        self.calls.append({"op": name, "kwargs": {k: v for k, v in kwargs.items() if k != "progress_callback"}})

    def _maybe_fail(self, name: str) -> None:
        if self.fail_op == name:
            from majik_backend.gen_protocol import GenerationStepError  # noqa: PLC0415
            raise GenerationStepError(code="PYTHON_CRASH", step=name, message=f"mock failure in {name}",
                                       fix="n/a")

    def _progress(self, cb: Optional[Callable[..., None]], *stages: str) -> None:
        if not cb:
            return
        n = len(stages)
        for i, stage in enumerate(stages):
            cb(stage=stage, percent=int(100 * (i + 1) / n), message=stage)
            if stage == self.pause_after_stage:
                self.paused_event.set()
                self.resume_event.wait(timeout=10.0)

    def list_models(self) -> List[str]:
        return ["acestep-v15-turbo", "acestep-v15-quality", "acestep-v15-base"]

    def generate_music(self, *, caption: str, output_path: str, progress_callback=None, **kwargs) -> Dict[str, Any]:
        self._record("generate_music", dict(caption=caption, output_path=output_path, **kwargs))
        self._maybe_fail("generate_music")
        self._progress(progress_callback, "preparing", "generating", "done")
        duration = kwargs.get("duration") or 2
        write_wav(output_path, sine(float(duration), sr=self.sr), self.sr)
        return {
            "file_path": output_path, "duration": duration, "sample_rate": self.sr,
            "caption": caption, "seed": kwargs.get("seed") or 42,
            "model": kwargs.get("model_name", "acestep-v15-turbo"),
            "num_inference_steps": kwargs.get("num_inference_steps", 8),
        }

    def generate_variants(self, *, caption: str, output_dir: str, count: int, progress_callback=None, **kwargs) -> List[Dict[str, Any]]:
        self._record("generate_variants", dict(caption=caption, output_dir=output_dir, count=count, **kwargs))
        self._maybe_fail("generate_variants")
        out = []
        for i in range(count):
            path = str(Path(output_dir) / f"variant-{i + 1}.wav")
            write_wav(path, sine(2.0, freq=200 + i * 10, sr=self.sr), self.sr)
            self._progress(progress_callback, f"variant-{i + 1}")
            out.append({"file_path": path, "duration": 2.0, "sample_rate": self.sr, "caption": caption,
                        "seed": (kwargs.get("seed") or 0) + i, "model": kwargs.get("model_name", "acestep-v15-turbo"),
                        "num_inference_steps": kwargs.get("num_inference_steps", 8), "variant_index": i + 1})
        return out

    def generate_repaint(self, *, source_audio: str, repainting_start: float, repainting_end: float,
                          caption: str, output_path: str, progress_callback=None, **kwargs) -> Dict[str, Any]:
        self._record("generate_repaint", dict(source_audio=source_audio, repainting_start=repainting_start,
                                                repainting_end=repainting_end, caption=caption,
                                                output_path=output_path, **kwargs))
        self._maybe_fail("generate_repaint")
        self._progress(progress_callback, "preparing", "generating", "done")
        src, sr = sf.read(source_audio, dtype="float32", always_2d=True)
        out = src.astype(np.float64).copy()
        start_i = int(round(repainting_start * sr))
        end_i = src.shape[0] if repainting_end is None or repainting_end < 0 else int(round(repainting_end * sr))
        end_i = min(end_i, src.shape[0])
        # Mimic P0-A's finding: raw repaint output does NOT bit-preserve the
        # untouched region (small renormalization-like gain everywhere)...
        out = out * 0.98
        # ...and clearly rewrites the requested region so splice tests can
        # detect it.
        out[start_i:end_i] = -out[start_i:end_i] * 1.4
        write_wav(output_path, out, sr)
        return {"file_path": output_path, "model": kwargs.get("model_name", "acestep-v15-base"),
                "seed": kwargs.get("seed") or 7, "num_inference_steps": kwargs.get("num_inference_steps", 50)}

    def generate_continuation(self, *, source_audio: str, caption: str, output_path: str,
                               progress_callback=None, **kwargs) -> Dict[str, Any]:
        self._record("generate_continuation", dict(source_audio=source_audio, caption=caption,
                                                     output_path=output_path, **kwargs))
        self._maybe_fail("generate_continuation")
        self._progress(progress_callback, "preparing", "generating", "done")
        src, sr = sf.read(source_audio, dtype="float32", always_2d=True)
        duration = kwargs.get("duration") or (src.shape[0] / sr) * 2
        total_n = int(round(duration * sr))
        tail_n = max(0, total_n - src.shape[0])
        rewritten_head = src.astype(np.float64) * 0.97  # also rewrites the "preserved" span, per P0-A
        tail = sine(tail_n / sr, freq=300, sr=sr)
        out = np.concatenate([rewritten_head, tail], axis=0)
        write_wav(output_path, out, sr)
        return {"file_path": output_path, "model": kwargs.get("model_name", "acestep-v15-turbo"),
                "seed": kwargs.get("seed") or 11, "num_inference_steps": kwargs.get("num_inference_steps", 8)}

    def generate_lego(self, *, source_audio: str, instruction: str, caption: str, output_path: str,
                       progress_callback=None, **kwargs) -> Dict[str, Any]:
        self._record("generate_lego", dict(source_audio=source_audio, instruction=instruction,
                                             caption=caption, output_path=output_path, **kwargs))
        self._maybe_fail("generate_lego")
        self._progress(progress_callback, "preparing", "generating", "done")
        write_wav(output_path, sine(1.5, freq=110, sr=self.sr), self.sr)
        return {"file_path": output_path, "model": kwargs.get("model_name", "acestep-v15-base"),
                "seed": kwargs.get("seed") or 5, "num_inference_steps": kwargs.get("num_inference_steps", 50)}

    def generate_auto_complete(self, *, source_audio: str, caption: str, output_path: str,
                                progress_callback=None, **kwargs) -> Dict[str, Any]:
        self._record("generate_auto_complete", dict(source_audio=source_audio, caption=caption,
                                                      output_path=output_path, **kwargs))
        self._maybe_fail("generate_auto_complete")
        self._progress(progress_callback, "preparing", "done")
        write_wav(output_path, sine(1.5, sr=self.sr), self.sr)
        return {"file_path": output_path, "model": "acestep-v15-base", "seed": kwargs.get("seed") or 3,
                "num_inference_steps": 50}

    def generate_cover(self, *, reference_audio: str, caption: str, output_path: str, cover_strength: float = 0.5,
                        progress_callback=None, **kwargs) -> Dict[str, Any]:
        self._record("generate_cover", dict(reference_audio=reference_audio, caption=caption,
                                              output_path=output_path, cover_strength=cover_strength, **kwargs))
        self._maybe_fail("generate_cover")
        self._progress(progress_callback, "preparing", "done")
        write_wav(output_path, sine(1.5, freq=180, sr=self.sr), self.sr)
        return {"file_path": output_path, "model": "acestep-v15-turbo", "seed": kwargs.get("seed") or 9,
                "num_inference_steps": 8}

    def generate_extract(self, *, source_audio: str, instruction: str, caption: str, output_path: str,
                          progress_callback=None, **kwargs) -> Dict[str, Any]:
        self._record("generate_extract", dict(source_audio=source_audio, instruction=instruction,
                                                caption=caption, output_path=output_path, **kwargs))
        self._maybe_fail("generate_extract")
        write_wav(output_path, sine(1.0, sr=self.sr), self.sr)
        return {"file_path": output_path, "model": "acestep-v15-base", "seed": 1, "num_inference_steps": 50}

    def export_stems(self, source_path: str, output_dir: str) -> Dict[str, Any]:
        self._record("export_stems", dict(source_path=source_path, output_dir=output_dir))
        self._maybe_fail("export_stems")
        src, sr = sf.read(source_path, dtype="float32", always_2d=True)
        stems = {}
        # Deterministic per-stem fractions of the source so tests can assert
        # sum(stems) approximates the source mix.
        fracs = {"vocals": 0.4, "drums": 0.3, "bass": 0.2, "other": 0.1}
        out_path = Path(output_dir)
        out_path.mkdir(parents=True, exist_ok=True)
        for name, frac in fracs.items():
            p = str(out_path / f"{name}.wav")
            write_wav(p, src.astype(np.float64) * frac, sr)
            stems[name] = p
        return {"stems": stems, "output_dir": str(out_path)}

    def understand_music(self, audio_path: str, lm_model_path: str = "acestep-5Hz-lm-1.7B") -> Dict[str, Any]:
        self._record("understand_music", dict(audio_path=audio_path))
        self._maybe_fail("understand_music")
        return {"caption": "mock caption", "lyrics": "", "bpm": 120.0, "key": "C major",
                "duration": 2.0, "language": "en", "time_signature": "4"}


@pytest.fixture
def mock_generator() -> MockGenerator:
    return MockGenerator()


@pytest.fixture
def source_wav(tmp_path) -> str:
    path = str(tmp_path / "source.wav")
    write_wav(path, sine(4.0, freq=220), SR)
    return path


@pytest.fixture(autouse=True)
def _isolated_output_dir(tmp_path, monkeypatch):
    """Every test gets its own gen_protocol output root so parallel test
    runs (and repeated runs) never collide, and nothing lands under the
    real Application Support path."""
    monkeypatch.setenv("MAJIKS_GEN_PROTOCOL_OUTPUT_DIR", str(tmp_path / "gen_protocol_out"))
    yield


@pytest.fixture(autouse=True)
def _reset_registry():
    """gen_protocol's job registry is a module-level singleton; give each
    test a clean one so job-id collisions/leftover state can't leak between
    tests."""
    import majik_backend.gen_protocol as gp  # noqa: PLC0415
    gp._REGISTRY = gp.JobRegistry()
    yield


def wait_for_terminal(job_id: str, timeout: float = 10.0):
    import majik_backend.gen_protocol as gp  # noqa: PLC0415
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = gp.status(job_id)
        if last.get("state") in ("done", "failed", "cancelled"):
            return last
        time.sleep(0.02)
    raise TimeoutError(f"job {job_id} did not reach a terminal state in {timeout}s (last={last})")


def ulid(seed: int) -> str:
    """Deterministic, valid-shaped ULID for tests (not a real monotonic
    generator; mirrors engine/contracts/fixtures/tools/generate_fixtures.py's
    own test-only ulid() helper)."""
    crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    digits = []
    n = seed + 10**15  # push into a stable, nonzero range
    for _ in range(25):
        digits.append(crockford[n % 32])
        n //= 32
    first = crockford[(seed // 7) % 8]  # keep within 0-7 per the ULID pattern
    return first + "".join(reversed(digits))
