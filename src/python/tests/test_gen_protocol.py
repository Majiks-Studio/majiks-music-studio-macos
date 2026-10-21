"""Unit tests for gen_protocol.py (lane L4): request validation, the job
registry lifecycle, capabilities merging, and a mocked-generator end-to-end
pass for every one of the ten Gen Protocol ops (submit -> background thread
-> generator call -> [splice] -> blake3 hash -> terminal state).

Run: python3 -m pytest src/python/tests -k "not slow"
"""
from __future__ import annotations

import re

import numpy as np
import pytest
import soundfile as sf

import majik_backend.gen_protocol as gp
from conftest import MockGenerator, ulid, wait_for_terminal

HASH_RE = re.compile(r"^[0-9a-f]{64}$")


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

class TestValidateRequest:
    def test_unknown_op_rejected(self):
        with pytest.raises(gp.GenProtocolError) as exc:
            gp.validate_request("not-a-real-op", {"requestId": ulid(1)})
        assert exc.value.code == "UNKNOWN_OP"

    def test_missing_required_field_rejected(self):
        with pytest.raises(gp.GenProtocolError) as exc:
            gp.validate_request("generate", {"requestId": ulid(1)})  # missing caption
        assert exc.value.code == "INVALID_REQUEST"
        assert "caption" in exc.value.message

    def test_region_start_zero_is_not_treated_as_missing(self):
        # regionStartSeconds=0.0 is falsy in Python but a legitimate value;
        # validate_request must check presence, not truthiness.
        gp.validate_request("revise", {
            "requestId": ulid(2), "sourceAudioRef": "/tmp/x.wav",
            "regionStartSeconds": 0.0, "regionEndSeconds": 4.0, "instruction": "brighter",
        })

    def test_unknown_field_rejected(self):
        with pytest.raises(gp.GenProtocolError) as exc:
            gp.validate_request("generate", {"requestId": ulid(3), "caption": "x", "notAField": 1})
        assert exc.value.code == "INVALID_REQUEST"
        assert "notAField" in exc.value.message

    def test_bad_ulid_rejected(self):
        with pytest.raises(gp.GenProtocolError):
            gp.validate_request("generate", {"requestId": "not-a-ulid", "caption": "x"})

    def test_ulid_with_disallowed_letter_rejected(self):
        # Crockford32 excludes I, L, O, U.
        bad = "I" + ulid(4)[1:]
        with pytest.raises(gp.GenProtocolError):
            gp.validate_request("generate", {"requestId": bad, "caption": "x"})

    def test_bad_route_rejected(self):
        with pytest.raises(gp.GenProtocolError):
            gp.validate_request("generate", {"requestId": ulid(5), "caption": "x", "route": "carrier-pigeon"})

    def test_valid_route_accepted(self):
        gp.validate_request("generate", {"requestId": ulid(6), "caption": "x", "route": "gen-node"})

    def test_retake_region_pair_incomplete_rejected(self):
        with pytest.raises(gp.GenProtocolError) as exc:
            gp.validate_request("retake", {
                "requestId": ulid(7), "sourceTakeId": "take_1", "regionStartSeconds": 4.0,
            })
        assert "regionStartSeconds" in exc.value.message or "regionEndSeconds" in exc.value.message

    def test_retake_region_pair_complete_accepted(self):
        gp.validate_request("retake", {
            "requestId": ulid(8), "sourceTakeId": "take_1",
            "regionStartSeconds": 4.0, "regionEndSeconds": 8.0,
        })

    def test_retake_whole_song_accepted(self):
        gp.validate_request("retake", {"requestId": ulid(9), "sourceTakeId": "take_1"})

    def test_finalize_bad_rung_rejected(self):
        with pytest.raises(gp.GenProtocolError):
            gp.validate_request("finalize", {
                "requestId": ulid(10), "draftTakeId": "take_1", "targetQualityRung": "ultra-mega",
                "request": {"requestId": ulid(11), "sourceAudioRef": "/tmp/x.wav",
                             "regionStartSeconds": 0.0, "regionEndSeconds": 4.0, "instruction": "x"},
            })

    def test_finalize_validates_nested_revise_request(self):
        with pytest.raises(gp.GenProtocolError):
            gp.validate_request("finalize", {
                "requestId": ulid(12), "draftTakeId": "take_1", "targetQualityRung": "draft",
                "request": {"requestId": ulid(13), "sourceAudioRef": "/tmp/x.wav"},  # missing region/instruction
            })

    def test_finalize_standard_rung_is_a_valid_request_shape(self):
        # "standard" is a legal enum value at the validation layer; execution
        # (submit) is what refuses it, per the open question in
        # gen-protocol-mapping.md (see test_submit_finalize_standard_rejected).
        gp.validate_request("finalize", {
            "requestId": ulid(14), "draftTakeId": "take_1", "targetQualityRung": "standard",
            "request": {"requestId": ulid(15), "sourceAudioRef": "/tmp/x.wav",
                         "regionStartSeconds": 0.0, "regionEndSeconds": 4.0, "instruction": "x"},
        })


# ---------------------------------------------------------------------------
# Job registry
# ---------------------------------------------------------------------------

class TestJobRegistry:
    def test_lifecycle_queued_running_done(self):
        reg = gp.JobRegistry()
        job = reg.create("job1", op="generate", route="local-mlx")
        assert reg.get("job1").to_status_dict() == {"state": "queued", "jobId": "job1"}

        reg.set_running("job1")
        assert reg.get("job1").state == "running"

        reg.update_progress("job1", "generating", 40, "halfway", variant=1)
        st = reg.get("job1").to_status_dict()
        assert st == {"state": "running", "jobId": "job1"}  # running/queued expose no extra fields

        reg.mark_done("job1", [{"kind": "mix", "path": "/x.wav", "contentHash": "a" * 64}],
                      {"model": "acestep-v15-turbo", "device": "cpu"}, latency_seconds=1.5)
        st = reg.get("job1").to_status_dict()
        assert st["state"] == "done"
        assert st["artifacts"][0]["kind"] == "mix"
        assert st["engineIdentity"]["model"] == "acestep-v15-turbo"
        assert st["latencySeconds"] == 1.5

    def test_lifecycle_failed(self):
        reg = gp.JobRegistry()
        reg.create("job2", op="revise", route="local-mlx")
        reg.mark_failed("job2", {"code": "FILE_NOT_FOUND", "message": "nope"})
        st = reg.get("job2").to_status_dict()
        assert st == {"state": "failed", "jobId": "job2", "error": {"code": "FILE_NOT_FOUND", "message": "nope"}}

    def test_cancel_flag_is_idempotent_and_does_not_downgrade_terminal_state(self):
        reg = gp.JobRegistry()
        reg.create("job3", op="generate", route="local-mlx")
        reg.mark_done("job3", [], {"model": "m", "device": "cpu"})
        reg.request_cancel("job3")  # after the fact; should not un-terminal it
        assert reg.get("job3").state == "done"

    def test_status_unknown_job_raises(self):
        with pytest.raises(gp.GenProtocolError) as exc:
            gp.status("does-not-exist")
        assert exc.value.code == "JOB_NOT_FOUND"

    def test_cancel_unknown_job_is_lenient(self):
        # Cancel is a request, not a guarantee (contract: "200 Cancellation
        # requested"); an unknown id should not raise.
        assert gp.cancel("does-not-exist") == {"jobId": "does-not-exist"}


# ---------------------------------------------------------------------------
# submit(): mocked end-to-end per op
# ---------------------------------------------------------------------------

def _submit_local(monkeypatch, op, request, mock_generator):
    monkeypatch.setattr(gp, "get_generator", lambda: mock_generator)
    events = []
    def notify(job_id, stage, percent, message, variant=None):
        events.append((job_id, stage, percent, message, variant))
    result = gp.submit(op, request, notify=notify)
    return result, events


class TestSubmitGenerate:
    def test_single_variant(self, monkeypatch, mock_generator):
        req = {"requestId": ulid(20), "caption": "lofi beat", "durationSeconds": 30, "seed": 42}
        result, events = _submit_local(monkeypatch, "generate", req, mock_generator)
        assert result == {"jobId": ulid(20)}
        st = wait_for_terminal(ulid(20))
        assert st["state"] == "done"
        assert len(st["artifacts"]) == 1
        assert st["artifacts"][0]["kind"] == "mix"
        assert HASH_RE.match(st["artifacts"][0]["contentHash"])
        assert st["engineIdentity"]["device"] == "cpu"
        assert st["engineIdentity"]["seed"] == 42
        assert any(e[1] == "done" for e in events)
        assert mock_generator.calls[0]["op"] == "generate_music"

    def test_multi_variant_calls_generate_variants(self, monkeypatch, mock_generator):
        req2 = {"requestId": ulid(22), "caption": "lofi beat", "nVariants": 3}
        result, _ = _submit_local(monkeypatch, "generate", req2, mock_generator)
        st = wait_for_terminal(ulid(22))
        assert st["state"] == "done"
        assert len(st["artifacts"]) == 3
        assert mock_generator.calls[-1]["op"] == "generate_variants"

    def test_generation_failure_reaches_failed_state(self, monkeypatch):
        mg = MockGenerator(fail_op="generate_music")
        req = {"requestId": ulid(23), "caption": "will fail"}
        _submit_local(monkeypatch, "generate", req, mg)
        st = wait_for_terminal(ulid(23))
        assert st["state"] == "failed"
        assert st["error"]["code"] == "PYTHON_CRASH"


class TestSubmitRevise:
    def test_all_stems_splices_bit_exact_outside_region(self, monkeypatch, mock_generator, source_wav):
        req = {
            "requestId": ulid(30), "sourceAudioRef": source_wav,
            "regionStartSeconds": 1.0, "regionEndSeconds": 2.0,
            "instruction": "bigger drums", "scope": "all-stems", "seed": 7,
        }
        _submit_local(monkeypatch, "revise", req, mock_generator)
        st = wait_for_terminal(ulid(30))
        assert st["state"] == "done"
        assert len(st["artifacts"]) == 1
        assert st["artifacts"][0]["kind"] == "mix"

        out_audio, out_sr = sf.read(st["artifacts"][0]["path"], dtype="float64", always_2d=True)
        src_audio, src_sr = sf.read(source_wav, dtype="float64", always_2d=True)
        assert out_sr == src_sr
        start_i = int(round(1.0 * src_sr))
        end_i = int(round(2.0 * src_sr))
        # Outside the region (beyond the fade edges): must be bit-exact vs source.
        assert np.array_equal(out_audio[: start_i], src_audio[: start_i])
        assert np.array_equal(out_audio[end_i:], src_audio[end_i:])
        # Well inside the region: must differ from source (the mock inverted+
        # scaled it) -> proves the repaint content actually landed. Uses RMS
        # over the region rather than a single sample, since a sine wave has
        # incidental near-zero-crossing samples that are "close" under any
        # sign for reasons unrelated to whether the splice worked.
        region_rms_diff = np.sqrt(np.mean((out_audio[start_i:end_i] - src_audio[start_i:end_i]) ** 2))
        assert region_rms_diff > 1e-3

    def test_stem_scope_produces_mix_plus_scoped_stem_artifacts(self, monkeypatch, mock_generator, source_wav):
        req = {
            "requestId": ulid(31), "sourceAudioRef": source_wav,
            "regionStartSeconds": 1.0, "regionEndSeconds": 1.5,
            "instruction": "half-time drums", "scope": "drums", "seed": 11,
        }
        _submit_local(monkeypatch, "revise", req, mock_generator)
        st = wait_for_terminal(ulid(31))
        assert st["state"] == "done"
        kinds = sorted(a["kind"] for a in st["artifacts"])
        assert kinds == ["drums", "mix"]
        for a in st["artifacts"]:
            assert HASH_RE.match(a["contentHash"])
        # export_stems must have been called twice: once for the original
        # window, once for the repainted window (P0-A section 6 pipeline).
        assert [c["op"] for c in mock_generator.calls].count("export_stems") == 2

    def test_variants_issue_sequential_calls_with_incrementing_seed(self, monkeypatch, mock_generator, source_wav):
        req = {
            "requestId": ulid(32), "sourceAudioRef": source_wav,
            "regionStartSeconds": 1.0, "regionEndSeconds": 1.5,
            "instruction": "brighter", "scope": "all-stems", "seed": 100, "variants": 3,
        }
        _submit_local(monkeypatch, "revise", req, mock_generator)
        st = wait_for_terminal(ulid(32))
        assert st["state"] == "done"
        assert len(st["artifacts"]) == 3
        repaint_calls = [c for c in mock_generator.calls if c["op"] == "generate_repaint"]
        assert [c["kwargs"]["seed"] for c in repaint_calls] == [100, 101, 102]

    def test_source_file_missing_fails_clearly(self, monkeypatch, mock_generator):
        req = {
            "requestId": ulid(33), "sourceAudioRef": "/no/such/file.wav",
            "regionStartSeconds": 0.0, "regionEndSeconds": 1.0, "instruction": "x",
        }
        _submit_local(monkeypatch, "revise", req, mock_generator)
        st = wait_for_terminal(ulid(33))
        assert st["state"] == "failed"
        assert st["error"]["code"] == "FILE_NOT_FOUND"


class TestSubmitExtend:
    def test_head_preserved_tail_appended(self, monkeypatch, mock_generator, source_wav):
        req = {"requestId": ulid(40), "sourceAudioRef": source_wav, "addedDurationSeconds": 2.0, "seed": 5}
        _submit_local(monkeypatch, "extend", req, mock_generator)
        st = wait_for_terminal(ulid(40))
        assert st["state"] == "done"
        out_audio, out_sr = sf.read(st["artifacts"][0]["path"], dtype="float64", always_2d=True)
        src_audio, src_sr = sf.read(source_wav, dtype="float64", always_2d=True)
        assert out_audio.shape[0] > src_audio.shape[0]
        fade_n = int(round(gp.DEFAULT_SPLICE_FADE_SECONDS * src_sr))
        # Head is bit-exact up to (join - fade).
        assert np.array_equal(out_audio[: src_audio.shape[0] - fade_n], src_audio[: src_audio.shape[0] - fade_n])


class TestSubmitLayer:
    @pytest.mark.parametrize("seed,instruction,expected_kind", [
        (50, "bass", "bass"), (51, "BASS", "bass"), (52, "drums", "drums"),
        (53, "lead vocals", "vocals"), (54, "sax lead", "other"),
    ])
    def test_kind_inference(self, monkeypatch, mock_generator, seed, instruction, expected_kind):
        req = {"requestId": ulid(seed), "instruction": instruction}
        _submit_local(monkeypatch, "layer", req, mock_generator)
        st = wait_for_terminal(req["requestId"])
        assert st["state"] == "done"
        assert st["artifacts"][0]["kind"] == expected_kind


class TestSubmitAutocompleteCover:
    def test_autocomplete(self, monkeypatch, mock_generator, source_wav):
        req = {"requestId": ulid(60), "sourceAudioRef": source_wav, "caption": "fill it out"}
        _submit_local(monkeypatch, "autocomplete", req, mock_generator)
        st = wait_for_terminal(ulid(60))
        assert st["state"] == "done"
        assert st["artifacts"][0]["kind"] == "mix"

    def test_cover(self, monkeypatch, mock_generator, source_wav):
        req = {"requestId": ulid(61), "referenceAudioRef": source_wav, "caption": "like this but jazzier",
               "coverStrength": 0.7}
        _submit_local(monkeypatch, "cover", req, mock_generator)
        st = wait_for_terminal(ulid(61))
        assert st["state"] == "done"
        assert mock_generator.calls[-1]["kwargs"]["cover_strength"] == 0.7


class TestSubmitSeparate:
    def test_demucs_returns_four_stems(self, monkeypatch, mock_generator, source_wav):
        req = {"requestId": ulid(70), "sourceAudioRef": source_wav, "engine": "demucs"}
        _submit_local(monkeypatch, "separate", req, mock_generator)
        st = wait_for_terminal(ulid(70))
        assert st["state"] == "done"
        assert sorted(a["kind"] for a in st["artifacts"]) == sorted(gp.STEM_KINDS)
        assert st["engineIdentity"]["model"] == "htdemucs"

    def test_ace_extract_labeled_generative_in_lineage(self, monkeypatch, mock_generator, source_wav):
        req = {"requestId": ulid(71), "sourceAudioRef": source_wav, "engine": "ace-extract",
               "instruction": "vocals, drums"}
        _submit_local(monkeypatch, "separate", req, mock_generator)
        st = wait_for_terminal(ulid(71))
        assert st["state"] == "done"
        # engineIdentity.model must be an ACE-Step model name, never "htdemucs"
        # (02-ARCH section 5: the two separate engines must be distinguishable
        # in lineage).
        assert st["engineIdentity"]["model"] != "htdemucs"
        assert sorted(a["kind"] for a in st["artifacts"]) == ["drums", "vocals"]


class TestSubmitAnalyze:
    def test_full_mode_returns_analyze_response_directly_not_a_job(self, monkeypatch, mock_generator, source_wav):
        monkeypatch.setattr(gp, "get_generator", lambda: mock_generator)
        req = {"requestId": ulid(80), "sourceAudioRef": source_wav, "mode": "full"}
        result = gp.submit("analyze", req)
        # analyze's contract response is analyzeResponse (200), not
        # submitResponse (202 {"jobId"}) - see module docstring.
        assert "jobId" not in result
        assert result["bpm"] == 120.0
        assert result["key"] == "C major"
        assert result["downbeats"] is None
        assert result["loudnessLufs"] is None
        with pytest.raises(gp.GenProtocolError):
            gp.status(ulid(80))  # no job was ever created for analyze

    def test_fast_mode_uses_signal_only_path(self, monkeypatch, mock_generator, source_wav):
        monkeypatch.setattr(gp, "get_generator", lambda: mock_generator)
        req = {"requestId": ulid(81), "sourceAudioRef": source_wav, "mode": "fast"}
        result = gp.submit("analyze", req)
        assert "jobId" not in result
        assert "duration" in result
        assert mock_generator.calls == []  # fast mode never touches the generator

    def test_analyze_has_no_route_field_in_the_frozen_schema(self, monkeypatch, mock_generator, source_wav):
        # analyzeRequest (gen-protocol.schemas.json) has no "route" property
        # at all, unlike the other nine ops - analyze is implicitly
        # local-mlx-only. A caller attempting to route it elsewhere is
        # rejected at validation, not silently ignored or downgraded.
        monkeypatch.setattr(gp, "get_generator", lambda: mock_generator)
        req = {"requestId": ulid(82), "sourceAudioRef": source_wav, "route": "gen-node"}
        with pytest.raises(gp.GenProtocolError) as exc:
            gp.submit("analyze", req)
        assert exc.value.code == "INVALID_REQUEST"
        assert "route" in exc.value.message


class TestSubmitFinalize:
    def test_draft_rung_uses_turbo_8_and_reuses_seed(self, monkeypatch, mock_generator, source_wav):
        inner = {"requestId": ulid(90), "sourceAudioRef": source_wav, "regionStartSeconds": 1.0,
                 "regionEndSeconds": 1.5, "instruction": "match the draft", "seed": 55}
        req = {"requestId": ulid(91), "draftTakeId": "take_1", "targetQualityRung": "draft", "request": inner}
        _submit_local(monkeypatch, "finalize", req, mock_generator)
        st = wait_for_terminal(ulid(91))
        assert st["state"] == "done"
        assert st["engineIdentity"]["model"] == "acestep-v15-turbo"
        assert st["engineIdentity"]["steps"] == 8
        repaint_call = [c for c in mock_generator.calls if c["op"] == "generate_repaint"][-1]
        assert repaint_call["kwargs"]["seed"] == 55  # reused, not fresh

    def test_full_rung_uses_base_50(self, monkeypatch, mock_generator, source_wav):
        inner = {"requestId": ulid(92), "sourceAudioRef": source_wav, "regionStartSeconds": 1.0,
                 "regionEndSeconds": 1.5, "instruction": "match the draft", "seed": 77}
        req = {"requestId": ulid(93), "draftTakeId": "take_1", "targetQualityRung": "full", "request": inner}
        _submit_local(monkeypatch, "finalize", req, mock_generator)
        st = wait_for_terminal(ulid(93))
        assert st["engineIdentity"]["model"] == "acestep-v15-base"
        assert st["engineIdentity"]["steps"] == 50

    def test_standard_rung_rejected_not_invented(self, monkeypatch, mock_generator, source_wav):
        inner = {"requestId": ulid(94), "sourceAudioRef": source_wav, "regionStartSeconds": 1.0,
                 "regionEndSeconds": 1.5, "instruction": "x"}
        req = {"requestId": ulid(95), "draftTakeId": "take_1", "targetQualityRung": "standard", "request": inner}
        _submit_local(monkeypatch, "finalize", req, mock_generator)
        st = wait_for_terminal(ulid(95))
        assert st["state"] == "failed"
        assert st["error"]["code"] == "QUALITY_RUNG_NOT_CONFIGURED"


class TestSubmitRetake:
    @staticmethod
    def _resolver(origin):
        return lambda take_id: origin

    def test_region_retake_routes_to_repaint_with_fresh_seed(self, monkeypatch, mock_generator, source_wav):
        monkeypatch.setattr(gp, "get_generator", lambda: mock_generator)
        origin = {"sourceAudioRef": source_wav, "caption": "original prompt"}
        req = {"requestId": ulid(100), "sourceTakeId": "take_9",
               "regionStartSeconds": 1.0, "regionEndSeconds": 1.5, "seed": 999}
        gp.submit("retake", req, notify=lambda *a, **k: None, lineage_resolver=self._resolver(origin))
        st = wait_for_terminal(ulid(100))
        assert st["state"] == "done"
        repaint_call = [c for c in mock_generator.calls if c["op"] == "generate_repaint"][-1]
        assert repaint_call["kwargs"]["seed"] == 999
        assert repaint_call["kwargs"]["caption"] == "original prompt"

    def test_whole_song_retake_routes_to_generate(self, monkeypatch, mock_generator):
        monkeypatch.setattr(gp, "get_generator", lambda: mock_generator)
        origin = {"caption": "original whole-song prompt", "bpm": 120}
        req = {"requestId": ulid(101), "sourceTakeId": "take_10", "seed": 321}
        gp.submit("retake", req, notify=lambda *a, **k: None, lineage_resolver=self._resolver(origin))
        st = wait_for_terminal(ulid(101))
        assert st["state"] == "done"
        music_call = [c for c in mock_generator.calls if c["op"] == "generate_music"][-1]
        assert music_call["kwargs"]["seed"] == 321
        assert music_call["kwargs"]["caption"] == "original whole-song prompt"
        # generate_variants (the batch-of-N primitive) must NOT be used for
        # retake - it jitters bpm/key per index, which is not "same prompt,
        # new seed" (gen-protocol-mapping.md).
        assert not any(c["op"] == "generate_variants" for c in mock_generator.calls)

    def test_no_lineage_resolver_fails_clearly_not_invented(self, monkeypatch, mock_generator):
        monkeypatch.setattr(gp, "get_generator", lambda: mock_generator)
        req = {"requestId": ulid(102), "sourceTakeId": "take_11"}
        gp.submit("retake", req, notify=lambda *a, **k: None)  # no lineage_resolver
        st = wait_for_terminal(ulid(102))
        assert st["state"] == "failed"
        assert st["error"]["code"] == "LINEAGE_STORE_NOT_AVAILABLE"


# ---------------------------------------------------------------------------
# Cancellation (deterministic: pause_after_stage + resume_event)
# ---------------------------------------------------------------------------

class TestCancel:
    def test_cancel_during_generation_reaches_cancelled_state(self, monkeypatch):
        mg = MockGenerator(pause_after_stage="preparing")
        monkeypatch.setattr(gp, "get_generator", lambda: mg)
        req = {"requestId": ulid(110), "caption": "cancel me"}
        gp.submit("generate", req, notify=lambda *a, **k: None)

        assert mg.paused_event.wait(timeout=5.0), "mock never reached the pause point"
        gp.cancel(ulid(110))
        mg.resume_event.set()

        st = wait_for_terminal(ulid(110))
        assert st == {"state": "cancelled", "jobId": ulid(110)}

    def test_cancel_before_lock_acquired_short_circuits(self, monkeypatch):
        # Two jobs share _LOCAL_EXEC_LOCK; cancel the second while the first
        # still holds it, then let the first finish - the second must never
        # call the generator at all.
        mg = MockGenerator(pause_after_stage="preparing")
        monkeypatch.setattr(gp, "get_generator", lambda: mg)
        first = {"requestId": ulid(111), "caption": "first"}
        second = {"requestId": ulid(112), "caption": "second"}
        gp.submit("generate", first, notify=lambda *a, **k: None)
        assert mg.paused_event.wait(timeout=5.0)

        gp.submit("generate", second, notify=lambda *a, **k: None)
        gp.cancel(ulid(112))  # cancel while it's still queued behind the lock
        mg.resume_event.set()

        st_first = wait_for_terminal(ulid(111))
        assert st_first["state"] == "done"
        st_second = wait_for_terminal(ulid(112))
        assert st_second["state"] == "cancelled"
        assert [c["kwargs"].get("caption") for c in mg.calls] == ["first"]


# ---------------------------------------------------------------------------
# capabilities()
# ---------------------------------------------------------------------------

class TestCapabilities:
    def test_shape_matches_contract(self, monkeypatch):
        monkeypatch.delenv("ACE_STEP_SERVER_URL", raising=False)
        monkeypatch.delenv("MAJIKS_GEN_NODE_URL", raising=False)
        result = gp.capabilities()
        routes = {e["route"] for e in result["endpoints"]}
        assert routes == {"local-mlx", "remote-ace", "gen-node", "uc-cloud"}
        for endpoint in result["endpoints"]:
            assert set(endpoint.keys()) == {"route", "ops", "models", "concurrentSlots"}

    def test_local_mlx_reports_full_op_set_when_generator_available(self, monkeypatch):
        result = gp.capabilities()
        local = next(e for e in result["endpoints"] if e["route"] == "local-mlx")
        assert set(local["ops"]) == set(gp.OPS)
        assert local["concurrentSlots"] == 1

    def test_remote_ace_is_generate_only(self, monkeypatch):
        monkeypatch.delenv("ACE_STEP_SERVER_URL", raising=False)
        result = gp.capabilities()
        remote = next(e for e in result["endpoints"] if e["route"] == "remote-ace")
        assert remote["ops"] == ["generate"]
        assert remote["concurrentSlots"] == 0  # no ACE_STEP_SERVER_URL configured

    def test_remote_ace_reports_slots_when_configured(self, monkeypatch):
        monkeypatch.setenv("ACE_STEP_SERVER_URL", "http://example.invalid:9999")
        result = gp.capabilities()
        remote = next(e for e in result["endpoints"] if e["route"] == "remote-ace")
        assert remote["concurrentSlots"] > 0

    def test_gen_node_graceful_unknown_when_unconfigured(self, monkeypatch):
        monkeypatch.delenv("MAJIKS_GEN_NODE_URL", raising=False)
        result = gp.capabilities()
        gen_node = next(e for e in result["endpoints"] if e["route"] == "gen-node")
        assert gen_node == {"route": "gen-node", "ops": [], "models": [], "concurrentSlots": 0}

    def test_gen_node_graceful_unknown_when_unreachable(self, monkeypatch):
        monkeypatch.setenv("MAJIKS_GEN_NODE_URL", "http://127.0.0.1:1")  # nothing listens on port 1
        result = gp.capabilities()
        gen_node = next(e for e in result["endpoints"] if e["route"] == "gen-node")
        assert gen_node["ops"] == []
        assert gen_node["concurrentSlots"] == 0

    def test_uc_cloud_not_implemented(self):
        result = gp.capabilities()
        uc = next(e for e in result["endpoints"] if e["route"] == "uc-cloud")
        assert uc == {"route": "uc-cloud", "ops": [], "models": [], "concurrentSlots": 0}


# ---------------------------------------------------------------------------
# remote-ace route (legacy ServerPool bridge): generate only, clear rejection
# for everything else.
# ---------------------------------------------------------------------------

class TestRemoteAceRoute:
    def test_revise_over_remote_ace_is_rejected_not_silently_downgraded(self, monkeypatch):
        req = {
            "requestId": ulid(120), "sourceAudioRef": "/tmp/x.wav", "regionStartSeconds": 0.0,
            "regionEndSeconds": 1.0, "instruction": "x", "route": "remote-ace",
        }
        gp.submit("revise", req, notify=lambda *a, **k: None)
        st = wait_for_terminal(ulid(120))
        assert st["state"] == "failed"
        assert st["error"]["code"] == "ROUTE_OP_NOT_SUPPORTED"

    def test_generate_over_remote_ace_without_server_url_fails_clearly(self, monkeypatch):
        monkeypatch.delenv("ACE_STEP_SERVER_URL", raising=False)
        req = {"requestId": ulid(121), "caption": "x", "route": "remote-ace"}
        gp.submit("generate", req, notify=lambda *a, **k: None)
        st = wait_for_terminal(ulid(121))
        assert st["state"] == "failed"
        assert st["error"]["code"] == "REMOTE_CONNECTION_FAILED"


class TestUcCloudRoute:
    def test_uc_cloud_route_fails_clearly_not_implemented(self, monkeypatch, mock_generator):
        monkeypatch.setattr(gp, "get_generator", lambda: mock_generator)
        req = {"requestId": ulid(130), "caption": "x", "route": "uc-cloud"}
        gp.submit("generate", req, notify=lambda *a, **k: None)
        st = wait_for_terminal(ulid(130))
        assert st["state"] == "failed"
        assert st["error"]["code"] == "NOT_IMPLEMENTED"
