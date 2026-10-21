"""Contract tests for Music Studio's Majiks Artwork HTTP client."""

from __future__ import annotations

import json
import time
from typing import Any
from urllib.request import Request

from majik_backend import rpc_server


class _JSONResponse:
    def __init__(self, payload: Any) -> None:
        self._body = json.dumps(payload).encode("utf-8")

    def __enter__(self) -> "_JSONResponse":
        return self

    def __exit__(self, *_args: object) -> None:
        return None

    def read(self) -> bytes:
        return self._body


def _run_with_responses(
    monkeypatch: Any,
    responses: list[dict[str, Any]],
) -> tuple[dict[str, Any], list[tuple[str, str]]]:
    remaining = iter(responses)
    requests: list[tuple[str, str]] = []

    def fake_urlopen(request: Request, timeout: float) -> _JSONResponse:
        del timeout
        requests.append((request.get_method(), request.full_url))
        return _JSONResponse(next(remaining))

    monkeypatch.setattr(rpc_server.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(time, "sleep", lambda _seconds: None)
    result = rpc_server._art_studio_generate(
        "/studio/track-artwork",
        {"title": "Signal", "artist": "Majik", "prompt": "Prismatic signal"},
    )
    return result, requests


def test_canonical_artwork_status_contract_completes(monkeypatch: Any) -> None:
    """Artwork 1.5 reports job state in `status`, not legacy `state`."""
    result, requests = _run_with_responses(
        monkeypatch,
        [
            {"job_id": "job-123", "status": "queued", "prompt": "Prismatic signal"},
            {"status": "generating", "progress": 45, "message": "Generating"},
            {
                "status": "completed",
                "progress": 100,
                "message": "Done",
                "image_path": "/tmp/majiks-artwork/job-123.png",
                "error": None,
            },
        ],
    )

    assert result == {
        "job_id": "job-123",
        "image_path": "/tmp/majiks-artwork/job-123.png",
        "prompt": "Prismatic signal",
    }
    assert requests == [
        ("POST", "http://localhost:8420/studio/track-artwork"),
        ("GET", "http://localhost:8420/status/job-123"),
        ("GET", "http://localhost:8420/status/job-123"),
    ]


def test_canonical_status_wins_over_conflicting_legacy_state(monkeypatch: Any) -> None:
    result, _ = _run_with_responses(
        monkeypatch,
        [
            {"job_id": "job-456", "status": "queued"},
            {
                "status": "completed",
                "state": "failed",
                "image_path": "/tmp/majiks-artwork/job-456.png",
            },
        ],
    )

    assert result["image_path"] == "/tmp/majiks-artwork/job-456.png"
    assert "error" not in result


def test_legacy_state_remains_compatible_during_suite_upgrade(monkeypatch: Any) -> None:
    result, _ = _run_with_responses(
        monkeypatch,
        [
            {"job_id": "job-legacy", "state": "queued"},
            {"state": "completed", "image_path": "/tmp/legacy.png"},
        ],
    )

    assert result["image_path"] == "/tmp/legacy.png"


def test_cancelled_job_is_terminal_and_preserves_provider_message(monkeypatch: Any) -> None:
    result, _ = _run_with_responses(
        monkeypatch,
        [
            {"job_id": "job-cancelled", "status": "queued"},
            {"status": "cancelled", "message": "Cancelled by user"},
        ],
    )

    assert result == {"error": "Cancelled by user", "job_id": "job-cancelled"}


def test_completed_job_without_image_path_fails_closed(monkeypatch: Any) -> None:
    result, _ = _run_with_responses(
        monkeypatch,
        [
            {"job_id": "job-missing-image", "status": "queued"},
            {"status": "completed", "message": "Done", "image_path": None},
        ],
    )

    assert result == {
        "error": "Art Studio completed without an image path",
        "job_id": "job-missing-image",
    }


def test_non_object_generation_response_fails_closed(monkeypatch: Any) -> None:
    calls: list[str] = []

    def fake_urlopen(request: Request, timeout: float) -> _JSONResponse:
        del timeout
        calls.append(request.full_url)
        return _JSONResponse(["unexpected"])

    monkeypatch.setattr(rpc_server.urllib.request, "urlopen", fake_urlopen)
    result = rpc_server._art_studio_generate("/studio/track-artwork", {"title": "Signal"})

    assert result == {"error": "Art Studio returned an invalid generation response"}
    assert calls == ["http://localhost:8420/studio/track-artwork"]
