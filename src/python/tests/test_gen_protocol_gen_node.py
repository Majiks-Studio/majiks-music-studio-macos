"""Tests for the gen-node route: _StockAceServerClient and _run_stock_op
against a local stdlib http.server that reproduces the wire shapes read
directly from a live ACE-Step 1.5 api_server on bigboy 2026-07-11 (see
docs/evidence/l4-gen-protocol.md and gen_protocol.py's module docstring,
point 4): POST /release_task -> {"data": {"task_id", "status",
"queue_position"}, "code": 200, ...}, POST /query_result -> {"data": [{
"task_id", "result": "<json-string>", "status": 0|1|2, "progress_text"}]},
GET /v1/audio?path=... -> raw bytes, GET /health -> 200.

Also holds the two smoke tests:
- test_local_smoke_slow_* : real local ACEStepGenerator, skipped when torch/
  acestep are not importable (this Mac's bare Python 3.14 clone).
- test_live_gen_node_smoke_* : real HTTP against a real ACE-Step api_server,
  skipped unless MAJIKS_RUN_LIVE_SMOKE=1 and MAJIKS_GEN_NODE_URL are set.
  Not run by CI; this is the session's manual smoke verification path.
"""
from __future__ import annotations

import http.server
import json
import os
import threading
from pathlib import Path
from typing import Optional

import numpy as np
import pytest
import soundfile as sf

import majik_backend.gen_protocol as gp
from conftest import sine, wait_for_terminal, write_wav, ulid


class _MockAceServerHandler(http.server.BaseHTTPRequestHandler):
    server_version = "MockACEStepAPI/1.0"

    def log_message(self, fmt, *args):  # silence default stderr logging
        pass

    def _send_json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _wrap(self, data):
        return {"data": data, "code": 200, "error": None, "timestamp": 0, "extra": None}

    def do_GET(self):  # noqa: N802 (stdlib method name)
        import urllib.parse as _up

        state = self.server.mock_state  # type: ignore[attr-defined]
        if self.path == "/health":
            self._send_json(self._wrap({"status": "ok", "service": "ACE-Step API"}))
            return
        if self.path.startswith("/v1/audio"):
            # Faithfully reproduce the real ACE-Step api_server's audio route:
            # only serve when the ?path= query param resolves to the served
            # file; 403 otherwise (the temp_audio_dir check). This is what
            # caught the double-encoding download bug in the live smoke, so
            # the mock must enforce it too or the regression can slip back.
            query = _up.urlparse(self.path).query
            requested = _up.parse_qs(query).get("path", [""])[0]
            if requested != state["result_path"]:
                self.send_response(403)
                self.end_headers()
                return
            audio_bytes = state["audio_bytes"]
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(audio_bytes)))
            self.end_headers()
            self.wfile.write(audio_bytes)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        state = self.server.mock_state  # type: ignore[attr-defined]

        if self.path == "/release_task":
            state["release_task_bodies"].append(body)
            if state.get("release_task_error"):
                self._send_json({"data": None, "code": 500, "error": "boom", "timestamp": 0, "extra": None})
                return
            self._send_json(self._wrap({"task_id": state["task_id"], "status": "queued", "queue_position": 1}))
            return

        if self.path == "/query_result":
            state["poll_count"] += 1
            n = state["poll_count"]
            fail_after = state.get("fail_after")
            succeed_after = state.get("succeed_after", 1)
            if fail_after is not None and n >= fail_after:
                result_data = [{"file": "", "status": 2, "error": "mock generation failure"}]
                item = {"task_id": state["task_id"], "result": json.dumps(result_data), "status": 2}
            elif n >= succeed_after:
                # The real server returns `file` as a READY, percent-encoded
                # server-relative download URL fragment (verified live on
                # bigboy): "/v1/audio?path=<encoded abs path>". The gen-node
                # client must GET that as-is, not wrap it again.
                import urllib.parse as _up
                if state.get("file_as_url_fragment", True):
                    file_field = "/v1/audio?path=" + _up.quote(state["result_path"], safe="")
                else:
                    file_field = state["result_path"]
                result_data = [{"file": file_field, "status": 1, "create_time": 0, "env": "test"}]
                item = {"task_id": state["task_id"], "result": json.dumps(result_data), "status": 1}
            else:
                result_data = [{"file": "", "status": 0, "progress": min(0.9, n / succeed_after), "stage": "generating"}]
                item = {"task_id": state["task_id"], "result": json.dumps(result_data), "status": 0}
            self._send_json(self._wrap([item]))
            return

        self.send_response(404)
        self.end_headers()


@pytest.fixture
def mock_ace_server(tmp_path):
    result_wav = str(tmp_path / "server_result.wav")
    write_wav(result_wav, sine(2.0), 8000)

    httpd = http.server.HTTPServer(("127.0.0.1", 0), _MockAceServerHandler)
    httpd.mock_state = {
        "task_id": "mock-task-123",
        "result_path": result_wav,
        "audio_bytes": Path(result_wav).read_bytes(),
        "poll_count": 0,
        "succeed_after": 2,
        "fail_after": None,
        "release_task_error": False,
        "release_task_bodies": [],
    }
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    base_url = f"http://127.0.0.1:{httpd.server_address[1]}"
    yield httpd, base_url
    httpd.shutdown()
    thread.join(timeout=5)


class TestStockAceServerClient:
    def test_health_true_when_reachable(self, mock_ace_server):
        _httpd, base_url = mock_ace_server
        client = gp._StockAceServerClient(base_url)
        assert client.health() is True

    def test_health_false_when_unreachable(self):
        client = gp._StockAceServerClient("http://127.0.0.1:1")
        assert client.health() is False

    def test_submit_returns_task_id(self, mock_ace_server):
        _httpd, base_url = mock_ace_server
        client = gp._StockAceServerClient(base_url)
        task_id = client.submit({"task_type": "text2music", "prompt": "x"})
        assert task_id == "mock-task-123"

    def test_submit_sends_json_not_form(self, mock_ace_server):
        # Session brief / P0-A section 1: the form-alias table lacks the
        # repaint fields, so this client must always send JSON.
        httpd, base_url = mock_ace_server
        client = gp._StockAceServerClient(base_url)
        client.submit({"task_type": "repaint", "prompt": "x", "repainting_start": 1.0})
        sent = httpd.mock_state["release_task_bodies"][-1]
        assert sent["task_type"] == "repaint"
        assert sent["repainting_start"] == 1.0

    def test_submit_server_error_raises_gen_protocol_error(self, mock_ace_server):
        httpd, base_url = mock_ace_server
        httpd.mock_state["release_task_error"] = True
        client = gp._StockAceServerClient(base_url)
        with pytest.raises(gp.GenProtocolError) as exc:
            client.submit({"task_type": "text2music", "prompt": "x"})
        assert exc.value.code == "REMOTE_SERVER_ERROR"

    def test_poll_once_running_then_done(self, mock_ace_server):
        _httpd, base_url = mock_ace_server
        client = gp._StockAceServerClient(base_url)
        r1 = client.poll_once("mock-task-123")
        assert r1["status"] == 0
        r2 = client.poll_once("mock-task-123")
        assert r2["status"] == 1
        assert r2["first"]["file"]

    def test_poll_once_failure_status(self, mock_ace_server):
        httpd, base_url = mock_ace_server
        httpd.mock_state["fail_after"] = 1
        client = gp._StockAceServerClient(base_url)
        r = client.poll_once("mock-task-123")
        assert r["status"] == 2
        assert "mock generation failure" in r["first"]["error"]

    def test_get_bytes_wraps_a_bare_filesystem_path(self, mock_ace_server):
        httpd, base_url = mock_ace_server
        client = gp._StockAceServerClient(base_url)
        data = client.get_bytes(httpd.mock_state["result_path"])
        assert data == httpd.mock_state["audio_bytes"]

    def test_get_bytes_uses_a_ready_url_fragment_as_is(self, mock_ace_server):
        # Regression for the live-smoke bug: the stock server returns `file`
        # as "/v1/audio?path=<encoded abs path>"; get_bytes must GET that
        # directly, NOT wrap it in a second /v1/audio?path= layer (which
        # double-encodes and 403s).
        import urllib.parse as _up
        httpd, base_url = mock_ace_server
        client = gp._StockAceServerClient(base_url)
        fragment = "/v1/audio?path=" + _up.quote(httpd.mock_state["result_path"], safe="")
        data = client.get_bytes(fragment)
        assert data == httpd.mock_state["audio_bytes"]

    def test_get_bytes_double_wrap_would_403(self, mock_ace_server):
        # Prove the mock actually enforces the path check (so the URL-fragment
        # test above is meaningful): wrapping a ready fragment a second time
        # must 403, exactly as bigboy did.
        import urllib.parse as _up
        httpd, base_url = mock_ace_server
        client = gp._StockAceServerClient(base_url)
        fragment = "/v1/audio?path=" + _up.quote(httpd.mock_state["result_path"], safe="")
        double = f"{base_url}/v1/audio?path={_up.quote(fragment, safe='')}"
        # Bypass get_bytes' own smart handling to hit the raw mock with a
        # double-wrapped path and confirm the 403.
        import urllib.error
        import urllib.request
        with pytest.raises(urllib.error.HTTPError) as exc:
            urllib.request.urlopen(double, timeout=5)
        assert exc.value.code == 403

    def test_connection_refused_raises_clear_error(self):
        client = gp._StockAceServerClient("http://127.0.0.1:1")
        with pytest.raises(gp.GenProtocolError) as exc:
            client.submit({"task_type": "text2music", "prompt": "x"})
        assert exc.value.code == "REMOTE_CONNECTION_FAILED"


class TestBuildStockPayload:
    def test_generate_uses_prompt_not_caption(self):
        req = {"requestId": ulid(1), "caption": "warm lofi", "durationSeconds": 30}
        payload = gp._build_stock_payload("generate", req, "acestep-v15-turbo", 8)
        assert payload["prompt"] == "warm lofi"
        assert "caption" not in payload
        assert payload["task_type"] == "text2music"

    def test_revise_leaves_instruction_field_unset_for_server_auto_resolution(self):
        # P0-A section 2 finding #1: leaving the wire "instruction" field at
        # the server default lets _resolve_instruction() fill in
        # TASK_INSTRUCTIONS["repaint"]; setting it ourselves would reproduce
        # the exact gap P0-A found in the local route.
        req = {"requestId": ulid(2), "sourceAudioRef": "clip_1", "regionStartSeconds": 1.0,
               "regionEndSeconds": 2.0, "instruction": "bigger drums"}
        payload = gp._build_stock_payload("revise", req, "acestep-v15-base", 50)
        assert "instruction" not in payload
        assert payload["prompt"] == "bigger drums"
        assert payload["task_type"] == "repaint"

    def test_revise_sets_explicit_chunk_mask_mode(self):
        # P0-A section 2 finding #3: ~8 dB better outside-region fidelity,
        # no seam-quality cost. Applied only on this new route.
        req = {"requestId": ulid(3), "sourceAudioRef": "clip_1", "regionStartSeconds": 1.0,
               "regionEndSeconds": 2.0, "instruction": "x"}
        payload = gp._build_stock_payload("revise", req, "acestep-v15-base", 50)
        assert payload["chunk_mask_mode"] == "explicit"

    def test_batch_size_always_one(self):
        # The server's own default batch_size=2 would silently double every
        # call; Gen Protocol's variants are handled by the engine issuing
        # sequential calls (mapping.md), not server-side batching.
        req = {"requestId": ulid(4), "caption": "x"}
        payload = gp._build_stock_payload("generate", req, "acestep-v15-turbo", 8)
        assert payload["batch_size"] == 1

    def test_thinking_always_false(self):
        req = {"requestId": ulid(5), "caption": "x"}
        payload = gp._build_stock_payload("generate", req, "acestep-v15-turbo", 8)
        assert payload["thinking"] is False

    def test_region_end_sentinel_omitted_when_minus_one(self):
        req = {"requestId": ulid(6), "sourceAudioRef": "clip_1", "regionStartSeconds": 1.0,
               "regionEndSeconds": -1, "instruction": "x"}
        payload = gp._build_stock_payload("revise", req, "acestep-v15-base", 50)
        assert "repainting_end" not in payload

    def test_layer_uses_track_name_not_instruction(self):
        # P0-A section 2 finding #4: the canonical
        # "Generate the BASS track based on the audio context:" template
        # (built server-side from track_name) reads better than the bare
        # word dropped straight into "instruction".
        req = {"requestId": ulid(7), "instruction": "bass"}
        payload = gp._build_stock_payload("layer", req, "acestep-v15-base", 50)
        assert payload["track_name"] == "bass"
        assert "instruction" not in payload

    def test_seed_sets_use_random_seed_false(self):
        req = {"requestId": ulid(8), "caption": "x", "seed": 42}
        payload = gp._build_stock_payload("generate", req, "acestep-v15-turbo", 8)
        assert payload["use_random_seed"] is False
        assert payload["seed"] == 42

    def test_no_seed_leaves_random(self):
        req = {"requestId": ulid(9), "caption": "x"}
        payload = gp._build_stock_payload("generate", req, "acestep-v15-turbo", 8)
        assert payload["use_random_seed"] is True
        assert "seed" not in payload


class TestRunStockOpEndToEnd:
    def test_generate_over_gen_node_mocked(self, monkeypatch, mock_ace_server):
        _httpd, base_url = mock_ace_server
        monkeypatch.setenv("MAJIKS_GEN_NODE_URL", base_url)
        req = {"requestId": ulid(10), "caption": "warm lofi", "durationSeconds": 4, "route": "gen-node"}
        gp.submit("generate", req, notify=lambda *a, **k: None)
        st = wait_for_terminal(ulid(10), timeout=15)
        assert st["state"] == "done"
        assert st["artifacts"][0]["kind"] == "mix"
        assert st["engineIdentity"]["device"] == "remote"

    def test_revise_over_gen_node_splices_client_side(self, monkeypatch, mock_ace_server, source_wav):
        httpd, base_url = mock_ace_server
        monkeypatch.setenv("MAJIKS_GEN_NODE_URL", base_url)
        # Serve a result whose length matches source_wav so the splice math
        # has a well-defined region to work with.
        src_audio, sr = sf.read(source_wav, dtype="float64", always_2d=True)
        modified = src_audio.copy()
        modified[:] = -modified  # whole track "rewritten", like a real repaint
        result_path = str(Path(source_wav).parent / "gen_node_repaint_result.wav")
        write_wav(result_path, modified, sr)
        httpd.mock_state["result_path"] = result_path
        httpd.mock_state["audio_bytes"] = Path(result_path).read_bytes()

        req = {
            "requestId": ulid(11), "sourceAudioRef": source_wav, "regionStartSeconds": 1.0,
            "regionEndSeconds": 2.0, "instruction": "bigger drums", "route": "gen-node",
        }
        gp.submit("revise", req, notify=lambda *a, **k: None)
        st = wait_for_terminal(ulid(11), timeout=15)
        assert st["state"] == "done"
        out_audio, out_sr = sf.read(st["artifacts"][0]["path"], dtype="float64", always_2d=True)
        start_i, end_i = int(1.0 * sr), int(2.0 * sr)
        assert np.array_equal(out_audio[:start_i], src_audio[:start_i])
        assert np.array_equal(out_audio[end_i:], src_audio[end_i:])

    def test_separate_has_no_route_field_in_the_frozen_schema(self, monkeypatch, mock_ace_server):
        # Like analyze, separateRequest has no "route" property at all
        # (htdemucs and ace-extract are both always local in this lane) -
        # rejected at validation, matching test_gen_protocol.py's
        # test_analyze_has_no_route_field_in_the_frozen_schema.
        _httpd, base_url = mock_ace_server
        monkeypatch.setenv("MAJIKS_GEN_NODE_URL", base_url)
        req = {"requestId": ulid(12), "sourceAudioRef": "/tmp/x.wav", "route": "gen-node"}
        with pytest.raises(gp.GenProtocolError) as exc:
            gp.submit("separate", req, notify=lambda *a, **k: None)
        assert exc.value.code == "INVALID_REQUEST"
        assert "route" in exc.value.message

    def test_generation_failure_on_gen_node_reaches_failed_state(self, monkeypatch, mock_ace_server):
        httpd, base_url = mock_ace_server
        httpd.mock_state["fail_after"] = 1
        monkeypatch.setenv("MAJIKS_GEN_NODE_URL", base_url)
        req = {"requestId": ulid(13), "caption": "x", "route": "gen-node"}
        gp.submit("generate", req, notify=lambda *a, **k: None)
        st = wait_for_terminal(ulid(13), timeout=15)
        assert st["state"] == "failed"
        assert st["error"]["code"] == "REMOTE_GENERATION_FAILED"

    def test_no_gen_node_url_configured_fails_clearly(self, monkeypatch):
        monkeypatch.delenv("MAJIKS_GEN_NODE_URL", raising=False)
        req = {"requestId": ulid(14), "caption": "x", "route": "gen-node"}
        gp.submit("generate", req, notify=lambda *a, **k: None)
        st = wait_for_terminal(ulid(14))
        assert st["state"] == "failed"
        assert st["error"]["code"] == "REMOTE_CONNECTION_FAILED"


class TestCapabilitiesProbeAgainstMockServer:
    def test_gen_node_capabilities_populated_when_reachable(self, monkeypatch, mock_ace_server):
        _httpd, base_url = mock_ace_server
        monkeypatch.setenv("MAJIKS_GEN_NODE_URL", base_url)
        result = gp.capabilities()
        gen_node = next(e for e in result["endpoints"] if e["route"] == "gen-node")
        assert "generate" in gen_node["ops"]
        assert "revise" in gen_node["ops"]
        assert gen_node["concurrentSlots"] == 1
        # separate/analyze have no REST equivalent on the stock server.
        assert "separate" not in gen_node["ops"]
        assert "analyze" not in gen_node["ops"]


# ---------------------------------------------------------------------------
# Slow, real-generator local smoke: skipped unless torch/acestep are
# importable (session adaptation: bare Python 3.14 clone lacks both).
# ---------------------------------------------------------------------------

def _torch_and_acestep_available() -> bool:
    try:
        import torch  # noqa: F401,PLC0415
        import acestep  # noqa: F401,PLC0415
        return True
    except ImportError:
        return False


@pytest.mark.skipif(
    not _torch_and_acestep_available(),
    reason="torch/acestep not installed in this environment (bare Python 3.14 clone, session note)",
)
def test_local_smoke_slow_generate_8_bars(monkeypatch):
    """Real ACEStepGenerator, real gen.submit, one 8-bar clip. Only runs
    where torch+acestep are actually importable."""
    req = {"requestId": ulid(200), "caption": "simple acoustic guitar loop", "durationSeconds": 16,
           "steps": 8, "model": "acestep-v15-turbo", "seed": 1}
    gp.submit("generate", req, notify=lambda *a, **k: None)
    st = wait_for_terminal(ulid(200), timeout=180)
    assert st["state"] == "done"
    assert Path(st["artifacts"][0]["path"]).exists()


# ---------------------------------------------------------------------------
# Live remote smoke: opt-in only (MAJIKS_RUN_LIVE_SMOKE=1 +
# MAJIKS_GEN_NODE_URL), never runs in CI or the default `-k "not slow"` gate.
# See docs/evidence/l4-gen-protocol.md for the transcript from the actual
# run against bigboy.
# ---------------------------------------------------------------------------

_LIVE_SMOKE_ENABLED = os.environ.get("MAJIKS_RUN_LIVE_SMOKE") == "1" and os.environ.get("MAJIKS_GEN_NODE_URL")


@pytest.mark.skipif(not _LIVE_SMOKE_ENABLED, reason="set MAJIKS_RUN_LIVE_SMOKE=1 and MAJIKS_GEN_NODE_URL to run")
def test_live_gen_node_smoke_slow_generate_and_revise(tmp_path):
    """Manual, opt-in: one gen.submit generate (8 bars, wav32) + one
    gen.submit revise (repaint a 4-bar region) against a real ACE-Step
    api_server. See docs/evidence/l4-gen-protocol.md for the transcript."""
    gen_req = {
        "requestId": ulid(210), "caption": "simple acoustic guitar loop, 4/4, steady strum",
        "durationSeconds": 16, "route": "gen-node", "seed": 1234,
    }
    gp.submit("generate", gen_req, notify=lambda *a, **k: None)
    gen_st = wait_for_terminal(ulid(210), timeout=180)
    assert gen_st["state"] == "done", gen_st
    source_path = gen_st["artifacts"][0]["path"]

    revise_req = {
        "requestId": ulid(211), "sourceAudioRef": source_path,
        "regionStartSeconds": 4.0, "regionEndSeconds": 8.0,
        "instruction": "add a tambourine shaking on the offbeat", "route": "gen-node", "seed": 5678,
    }
    gp.submit("revise", revise_req, notify=lambda *a, **k: None)
    revise_st = wait_for_terminal(ulid(211), timeout=180)
    assert revise_st["state"] == "done", revise_st
    assert revise_st["artifacts"][0]["kind"] == "mix"
