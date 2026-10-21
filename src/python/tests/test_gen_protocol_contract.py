"""Cross-checks gen_protocol.py's hand-rolled, dependency-free validation
against the authoritative frozen contract (engine/contracts/gen-protocol.
schemas.json), so drift between the two is a test failure, not a silent
divergence (R7, 00-README-RUNBOOK.txt: "Contracts... are law. Propose
changes in your report; never silently diverge").

gen_protocol.py itself never imports jsonschema or reads this file at
runtime (see its module docstring, point 9, for why: production
independence from the engine/contracts tree). This test file is the one
place that dependency is allowed, since it only runs in dev/CI, never in
the shipped app.

Skips (not fails) if jsonschema or the schema file are unavailable, since
neither is a project runtime dependency.
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

import majik_backend.gen_protocol as gp

try:
    from jsonschema import Draft202012Validator
    _HAVE_JSONSCHEMA = True
except ImportError:
    _HAVE_JSONSCHEMA = False

_CONTRACTS_DIR = Path(__file__).resolve().parents[3] / "engine" / "contracts"
_SCHEMA_PATH = _CONTRACTS_DIR / "gen-protocol.schemas.json"
_FIXTURES_DIR = _CONTRACTS_DIR / "fixtures" / "gen-protocol"

pytestmark = pytest.mark.skipif(
    not (_HAVE_JSONSCHEMA and _SCHEMA_PATH.exists()),
    reason="jsonschema and/or engine/contracts/gen-protocol.schemas.json not available in this checkout",
)

_OP_TO_DEF = {
    "generate": "generateRequest", "revise": "reviseRequest", "extend": "extendRequest",
    "layer": "layerRequest", "retake": "retakeRequest", "autocomplete": "autocompleteRequest",
    "cover": "coverRequest", "separate": "separateRequest", "analyze": "analyzeRequest",
    "finalize": "finalizeRequest",
}


def _load_schema() -> dict:
    with open(_SCHEMA_PATH) as fh:
        return json.load(fh)


def _validator_for(op: str) -> "Draft202012Validator":
    schema = _load_schema()
    defs = schema["$defs"]
    sub_schema = {"$ref": f"#/$defs/{_OP_TO_DEF[op]}"}
    return Draft202012Validator({**sub_schema, "$defs": defs})


class TestRequiredFieldsMatchSchema:
    """gen_protocol._REQUIRED_FIELDS is hand-maintained; this proves it is
    exactly the schema's own "required" list for every op, not a guess."""

    @pytest.mark.parametrize("op", list(_OP_TO_DEF))
    def test_required_fields_match(self, op):
        schema = _load_schema()
        required = set(schema["$defs"][_OP_TO_DEF[op]].get("required", []))
        assert set(gp._REQUIRED_FIELDS[op]) == required

    @pytest.mark.parametrize("op", list(_OP_TO_DEF))
    def test_allowed_fields_match_schema_properties(self, op):
        schema = _load_schema()
        properties = set(schema["$defs"][_OP_TO_DEF[op]].get("properties", {}).keys())
        assert gp._ALLOWED_FIELDS[op] == properties


class TestOwnValidatorAgreesWithJsonschema:
    """For a battery of valid and invalid example requests, gen_protocol's
    own validate_request() and the real jsonschema validator must agree on
    accept/reject, so the dependency-free runtime check is not quietly
    looser (or stricter) than the frozen contract."""

    VALID_EXAMPLES = {
        "generate": {"requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "caption": "warm lofi", "nVariants": 2},
        "revise": {"requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "sourceAudioRef": "clip_1",
                   "regionStartSeconds": 4, "regionEndSeconds": 6, "instruction": "bigger drums",
                   "scope": "drums", "seed": 7, "variants": 1},
        "extend": {"requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "sourceAudioRef": "clip_1",
                   "addedDurationSeconds": 16.0},
        "layer": {"requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "instruction": "bass"},
        "retake": {"requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "sourceTakeId": "take_1"},
        "autocomplete": {"requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "sourceAudioRef": "clip_1",
                          "caption": "fill it out"},
        "cover": {"requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "referenceAudioRef": "clip_1",
                  "caption": "jazzier"},
        "separate": {"requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "sourceAudioRef": "clip_1"},
        "analyze": {"requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "sourceAudioRef": "clip_1"},
        "finalize": {"requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "draftTakeId": "take_1",
                     "targetQualityRung": "draft",
                     "request": {"requestId": "01ARZ3NDEKTSV4RRFFQ69G5FAV", "sourceAudioRef": "clip_1",
                                 "regionStartSeconds": 0, "regionEndSeconds": 4, "instruction": "x"}},
    }

    @pytest.mark.parametrize("op", list(_OP_TO_DEF))
    def test_valid_example_accepted_by_both(self, op):
        example = self.VALID_EXAMPLES[op]
        validator = _validator_for(op)
        schema_errors = list(validator.iter_errors(example))
        assert schema_errors == [], f"{op}: jsonschema rejected a supposedly-valid example: {schema_errors}"
        gp.validate_request(op, example)  # must not raise

    @pytest.mark.parametrize("op", list(_OP_TO_DEF))
    def test_missing_required_field_rejected_by_both(self, op):
        example = dict(self.VALID_EXAMPLES[op])
        first_required = gp._REQUIRED_FIELDS[op][0]
        del example[first_required]
        validator = _validator_for(op)
        assert list(validator.iter_errors(example)) != []
        with pytest.raises(gp.GenProtocolError):
            gp.validate_request(op, example)

    @pytest.mark.parametrize("op", list(_OP_TO_DEF))
    def test_unknown_field_rejected_by_both(self, op):
        example = dict(self.VALID_EXAMPLES[op], **{"totallyNotAField": True})
        validator = _validator_for(op)
        assert list(validator.iter_errors(example)) != [], f"{op}: jsonschema accepted an unknown field"
        with pytest.raises(gp.GenProtocolError):
            gp.validate_request(op, example)

    def test_retake_one_sided_region_rejected_by_both(self):
        example = dict(self.VALID_EXAMPLES["retake"], regionStartSeconds=4.0)  # no regionEndSeconds
        # The schema alone does not encode the "both or neither" pairing
        # rule (mapping.md: "conformance tooling should reject this shape");
        # that is exactly why gen_protocol.validate_request adds it on top
        # of plain schema conformance.
        validator = _validator_for("retake")
        assert list(validator.iter_errors(example)) == []
        with pytest.raises(gp.GenProtocolError):
            gp.validate_request("retake", example)


class TestFixturesFromP0C:
    """P0-C's own gen-protocol fixtures (frozen alongside the schema) must
    validate under gen_protocol.validate_request() exactly as they do under
    jsonschema."""

    @pytest.mark.parametrize("op,filename", [
        ("generate", "generate.request.json"),
        ("revise", "revise.request.json"),
        ("analyze", "analyze.request.json"),
    ])
    def test_fixture_request_validates(self, op, filename):
        path = _FIXTURES_DIR / filename
        if not path.exists():
            pytest.skip(f"fixture {filename} not present in this checkout")
        with open(path) as fh:
            request = json.load(fh)
        validator = _validator_for(op)
        assert list(validator.iter_errors(request)) == []
        gp.validate_request(op, request)  # must not raise


class TestAssetHashPattern:
    def test_blake3_hex_matches_asset_hash_regex(self):
        import re  # noqa: PLC0415
        schema = _load_schema()
        pattern = schema["$defs"]["assetHash"]["pattern"]
        digest = gp.blake3_hex(b"contract cross-check")
        assert re.match(pattern, digest)


class TestArtifactKindEnum:
    def test_artifact_kinds_match_schema_enum(self):
        schema = _load_schema()
        enum = set(schema["$defs"]["artifact"]["properties"]["kind"]["enum"])
        assert set(gp.ARTIFACT_KINDS) == enum


class TestQualityRungEnum:
    def test_quality_rungs_are_a_subset_of_the_schema_enum(self):
        schema = _load_schema()
        enum = set(schema["$defs"]["qualityRung"]["enum"])
        # QUALITY_RUNGS deliberately does NOT cover "standard" - see
        # gen_protocol.py module docstring point 7 / test_gen_protocol.py's
        # test_standard_rung_rejected_not_invented. It must still be a
        # subset, not disagree with the enum's spelling.
        assert set(gp.QUALITY_RUNGS) <= enum
        assert "standard" in enum and "standard" not in gp.QUALITY_RUNGS


class TestEngineRouteEnum:
    def test_valid_routes_match_schema_enum(self):
        schema = _load_schema()
        enum = set(schema["$defs"]["engineRoute"]["enum"])
        assert gp.VALID_ROUTES == enum


class TestStemScopeEnum:
    def test_stem_kinds_plus_all_stems_match_schema_enum(self):
        schema = _load_schema()
        enum = set(schema["$defs"]["stemScope"]["enum"])
        assert set(gp.STEM_KINDS) | {"all-stems"} == enum
