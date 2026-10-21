"""Conformance tests for engine/contracts/, run from the repo root with:

    python3 -m pytest engine/contracts/

Dependencies: Python stdlib, the `jsonschema` package, and this package's own
blake3_pure.py fallback (used automatically if the compiled `blake3` package is
not importable; see blake3_compat.py). No other third-party package is
required for these tests to run and pass. PyYAML is used opportunistically for
one structural check on gen-protocol.v1.yaml and that single test is skipped,
not failed, if PyYAML is not installed.

These tests validate the CONTRACT (schemas + fixtures are internally
consistent, hash chain is correct) — no engine or Python-backend behavior is
exercised, per this lane's scope.
"""
import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

from conformance_py.canonical import GENESIS_HASH, compute_entry_hash, verify_chain
from conformance_py.blake3_compat import blake3_hex, HAVE_COMPILED_BLAKE3
from conformance_py import blake3_pure

CONTRACTS_DIR = Path(__file__).resolve().parents[1]
FIXTURES_DIR = CONTRACTS_DIR / "fixtures"


def load_json(path: Path):
    with open(path) as f:
        return json.load(f)


@pytest.fixture(scope="module")
def catalog_schema():
    return load_json(CONTRACTS_DIR / "command-catalog.schema.json")


# The catalog the engine actually EMBEDS (timeline-core/src/catalog.rs
# include_str!). Design 9.6: this suite used to validate command-catalog.v1.json
# while the engine embedded v1.1.json, so the file that IS law was never
# schema-checked. Keep this pointed at whatever catalog.rs includes.
EMBEDDED_CATALOG = "command-catalog.v2.json"


@pytest.fixture(scope="module")
def catalog():
    return load_json(CONTRACTS_DIR / EMBEDDED_CATALOG)


@pytest.fixture(scope="module")
def catalog_by_name(catalog):
    return {c["name"]: c for c in catalog["commands"]}


@pytest.fixture(scope="module")
def project_schema():
    return load_json(CONTRACTS_DIR / "project.schema.json")


@pytest.fixture(scope="module")
def gen_protocol_schemas():
    return load_json(CONTRACTS_DIR / "gen-protocol.schemas.json")


def sub_validator(schema_doc, ref_fragment):
    return Draft202012Validator({**schema_doc, "$ref": ref_fragment})


def full_validate_envelope(envelope, catalog_schema, catalog_by_name):
    """Three-layer conformance check used throughout this file:
    1. envelope shape (command-catalog.schema.json#/$defs/commandEnvelope)
    2. catalog cross-reference: name must exist, params must match that
       command's paramsSchema
    3. undoable/inverse consistency, and (if inverse is non-null) the inverse
       itself must name a real command and match ITS paramsSchema.
    Returns a list of tagged error strings; empty list means fully valid.
    """
    errors = []
    envelope_validator = sub_validator(catalog_schema, "#/$defs/commandEnvelope")
    shape_errors = list(envelope_validator.iter_errors(envelope))
    if shape_errors:
        return [f"shape: {e.message} at {list(e.absolute_path)}" for e in shape_errors]

    name = envelope["name"]
    cmd = catalog_by_name.get(name)
    if cmd is None:
        return [f"catalog: unknown command name '{name}'"]

    params_validator = Draft202012Validator(cmd["paramsSchema"])
    for e in params_validator.iter_errors(envelope["params"]):
        errors.append(f"params: {e.message} at {list(e.absolute_path)}")

    undoable = cmd["undoable"]
    inverse = envelope["inverse"]
    if undoable and inverse is None:
        errors.append("inverse: catalog says undoable=true but envelope inverse is null")
    if not undoable and inverse is not None:
        errors.append("inverse: catalog says undoable=false but envelope inverse is non-null")
    if inverse is not None:
        inv_name = inverse["name"]
        inv_cmd = catalog_by_name.get(inv_name)
        if inv_cmd is None:
            errors.append(f"inverse: inverse.name '{inv_name}' is not a catalog command")
        else:
            inv_validator = Draft202012Validator(inv_cmd["paramsSchema"])
            for e in inv_validator.iter_errors(inverse["params"]):
                errors.append(f"inverse.params: {e.message} at {list(e.absolute_path)}")
    return errors


# ---------------------------------------------------------------------------
# blake3
# ---------------------------------------------------------------------------

class TestBlake3Pure:
    KNOWN_VECTOR_EMPTY = "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"

    def test_known_vector_empty_string(self):
        # Cross-checked against the compiled `blake3` package directly
        # (2026-07-11, see docs/evidence/p0c-contracts.md); pinned here as a
        # literal so this test catches a regression even in an environment
        # where the compiled package is unavailable to compare against live.
        assert len(self.KNOWN_VECTOR_EMPTY) == 64
        assert blake3_pure.blake3_hex(b"") == self.KNOWN_VECTOR_EMPTY

    def test_digest_is_64_hex_chars(self):
        for data in [b"", b"a", b"abc", b"x" * 1024, b"y" * 2049]:
            h = blake3_pure.blake3_hex(data)
            assert len(h) == 64
            assert all(c in "0123456789abcdef" for c in h)

    def test_deterministic(self):
        assert blake3_pure.blake3_hex(b"repeat me") == blake3_pure.blake3_hex(b"repeat me")

    def test_multichunk_tree_merge(self):
        # >1024 bytes forces the chaining-value-stack / parent-node path, the
        # most bug-prone part of a from-scratch BLAKE3 implementation.
        data = bytes((i * 251 + 7) % 256 for i in range(65537))
        h = blake3_pure.blake3_hex(data)
        assert len(h) == 64

    @pytest.mark.skipif(not HAVE_COMPILED_BLAKE3, reason="compiled blake3 package not installed in this environment")
    def test_pure_blake3_matches_compiled_when_available(self):
        import blake3 as compiled
        for data in [b"", b"a", b"abc" * 1000, bytes(range(256)) * 10]:
            assert blake3_pure.blake3_hex(data) == compiled.blake3(data).hexdigest()

    def test_blake3_compat_picks_a_working_backend(self):
        h = blake3_hex(b"compat check")
        assert len(h) == 64


# ---------------------------------------------------------------------------
# command-catalog.v2.json (the file the engine EMBEDS) / .schema.json
# ---------------------------------------------------------------------------

class TestCommandCatalog:
    def test_schema_is_valid_json_schema(self, catalog_schema):
        Draft202012Validator.check_schema(catalog_schema)

    def test_catalog_validates_against_schema(self, catalog, catalog_schema):
        v = sub_validator(catalog_schema, "#/$defs/catalogDocument")
        errors = list(v.iter_errors(catalog))
        assert errors == [], "\n".join(f"{list(e.absolute_path)}: {e.message}" for e in errors)

    def test_frozen_v1_catalog_still_validates(self, catalog_schema):
        """A schema edit made for v2 must not invalidate the frozen v1 file."""
        v = sub_validator(catalog_schema, "#/$defs/catalogDocument")
        doc = load_json(CONTRACTS_DIR / "command-catalog.v1.json")
        errors = list(v.iter_errors(doc))
        assert errors == [], "\n".join(f"{list(e.absolute_path)}: {e.message}" for e in errors)

    def test_v1_1_has_a_known_pre_existing_schema_violation(self, catalog_schema):
        """The 8 midi.* commands in v1.1 omit the conditionally-required
        nonUndoableReason. v1.1 is frozen, so v2 carries the fix; this pins the
        defect so it cannot be 'fixed' by editing the frozen file."""
        v = sub_validator(catalog_schema, "#/$defs/catalogDocument")
        doc = load_json(CONTRACTS_DIR / "command-catalog.v1.1.json")
        errors = list(v.iter_errors(doc))
        assert len(errors) == 8, "\n".join(
            f"{list(e.absolute_path)}: {e.message}" for e in errors
        )
        assert all("nonUndoableReason" in e.message for e in errors)

    def test_no_duplicate_command_names(self, catalog):
        names = [c["name"] for c in catalog["commands"]]
        assert len(names) == len(set(names)), "duplicate command name(s) in catalog"

    def test_every_params_schema_is_itself_valid(self, catalog):
        for c in catalog["commands"]:
            Draft202012Validator.check_schema(c["paramsSchema"])

    def test_undoable_requires_self_or_explicit_inverse_mode(self, catalog):
        for c in catalog["commands"]:
            if c["undoable"]:
                assert c["inverseRule"]["mode"] in ("self", "explicit"), c["name"]
            else:
                assert c["inverseRule"]["mode"] == "none", c["name"]

    def test_non_transport_non_undoable_has_reason(self, catalog):
        for c in catalog["commands"]:
            if not c["undoable"] and c["category"] != "transport":
                assert c.get("nonUndoableReason"), f"{c['name']} needs nonUndoableReason"

    def test_explicit_inverse_names_a_real_command(self, catalog, catalog_by_name):
        for c in catalog["commands"]:
            if c["inverseRule"]["mode"] == "explicit":
                target = c["inverseRule"]["name"]
                assert target in catalog_by_name, f"{c['name']}'s inverse '{target}' is not a catalog command"

    def test_expected_command_count(self, catalog):
        # v1:   67 bulleted in 02-ARCH section 4 + gen.landed (named in prose) +
        #       txn.begin/txn.commit (named in prose, "Multi-op user gestures
        #       wrap in txn.begin/txn.commit") + marker.remove (P0-C proposal 1,
        #       APPROVED by the coordinating session 2026-07-11) = 71.
        # v1.1: + clip.phaseAnchor.set, take.purge/restore, the midi.* wave and
        #       the record.* wave = 87.
        assert len(load_json(CONTRACTS_DIR / "command-catalog.v1.json")["commands"]) == 71
        assert len(load_json(CONTRACTS_DIR / "command-catalog.v1.1.json")["commands"]) == 87
        assert len(catalog["commands"]) == 119

    def test_read_surface_present(self, catalog):
        names = {r["name"] for r in catalog["readSurface"]}
        expected = {
            "project.snapshot", "track.meters", "transport.state", "takes.list",
            "lineage.get", "journal.page", "waveform.tiles", "engine.stats",
        }
        assert expected <= names

    def test_transport_commands_are_unjournaled_and_not_undoable(self, catalog):
        for c in catalog["commands"]:
            if c["category"] == "transport":
                assert c["journaled"] is False, c["name"]
                assert c["undoable"] is False, c["name"]

    def test_gen_request_commands_are_journaled_not_undoable(self, catalog, catalog_by_name):
        for name in ["gen.song", "gen.revise", "gen.extend", "gen.layer", "gen.retake",
                     "gen.autocomplete", "gen.cover", "gen.separate", "gen.finalize"]:
            c = catalog_by_name[name]
            assert c["journaled"] is True, name
            assert c["undoable"] is False, name
            assert c.get("async") is True, name

    def test_gen_landed_is_system_authored(self, catalog_by_name):
        c = catalog_by_name["gen.landed"]
        assert c.get("systemAuthored") is True
        assert c["undoable"] is False

    def test_export_family_journaled_but_not_undoable(self, catalog_by_name):
        for name in ["export.master", "export.stems", "export.region", "export.manifest"]:
            c = catalog_by_name[name]
            assert c["journaled"] is True, name
            assert c["undoable"] is False, name
            assert c["inverseRule"]["mode"] == "none", name


# ---------------------------------------------------------------------------
# project.schema.json
# ---------------------------------------------------------------------------

class TestProjectSchema:
    def test_schema_is_valid_json_schema(self, project_schema):
        Draft202012Validator.check_schema(project_schema)

    def test_additional_properties_true_at_root(self, project_schema):
        # Forward-compat is a deliberate, load-bearing property of this
        # schema (README.md); guard against an edit accidentally tightening it.
        assert project_schema["additionalProperties"] is True

    def test_fixture_validates(self, project_schema):
        proj = load_json(FIXTURES_DIR / "project" / "minimal-project.json")
        v = Draft202012Validator(project_schema)
        errors = list(v.iter_errors(proj))
        assert errors == [], "\n".join(f"{list(e.absolute_path)}: {e.message}" for e in errors)

    def test_unknown_fields_round_trip(self, project_schema):
        proj = load_json(FIXTURES_DIR / "project" / "minimal-project.json")
        proj = dict(proj)
        proj["futureFieldFromV2"] = {"anything": True}
        v = Draft202012Validator(project_schema)
        errors = list(v.iter_errors(proj))
        assert errors == [], "an unknown top-level field must not fail validation (forward-compat)"


# ---------------------------------------------------------------------------
# fixtures/project/: hash chain + checkpoint linkage
# ---------------------------------------------------------------------------

class TestJournalFixture:
    @pytest.fixture(scope="class")
    def entries(self):
        path = FIXTURES_DIR / "project" / "minimal-journal.jsonl"
        with open(path) as f:
            return [json.loads(line) for line in f if line.strip()]

    def test_has_30_entries(self, entries):
        assert len(entries) == 30

    def test_every_entry_validates_as_envelope(self, entries, catalog_schema, catalog_by_name):
        for e in entries:
            errs = full_validate_envelope(e, catalog_schema, catalog_by_name)
            assert errs == [], f"{e['id']} ({e['name']}): {errs}"

    def test_hash_chain_verifies(self, entries):
        ok, tip_hash, count = verify_chain(entries)
        assert ok, f"chain broke at index {count}"
        assert count == 30

    def test_first_entry_chains_from_genesis(self, entries):
        first = entries[0]
        recomputed = compute_entry_hash(GENESIS_HASH, {
            k: first[k] for k in ("id", "ts", "actor", "name", "params", "inverse", "result")
        })
        assert recomputed == first["hash"]

    def test_tamper_detection(self, entries):
        # Flipping one param must break the chain from that point forward.
        tampered = json.loads(json.dumps(entries))  # deep copy
        tampered[5]["params"]["color"] = "#000000"
        ok, _, break_index = verify_chain(tampered)
        assert not ok
        assert break_index == 5

    def test_checkpoint_matches_journal(self, entries):
        proj = load_json(FIXTURES_DIR / "project" / "minimal-project.json")
        j = proj["journal"]
        ok, tip_hash, count = verify_chain(entries)
        assert ok
        assert j["entryCount"] == count
        assert j["tipHash"] == tip_hash
        assert j["tipId"] == entries[-1]["id"]
        assert j["genesisHash"] == GENESIS_HASH

    def test_txn_begin_commit_pairing(self, entries):
        open_txn = None
        for e in entries:
            if e["name"] == "txn.begin":
                assert open_txn is None, f"nested txn.begin while {open_txn} still open"
                open_txn = e["params"]["txnId"]
            elif e["name"] == "txn.commit":
                assert open_txn == e["params"]["txnId"], (
                    f"txn.commit for {e['params']['txnId']} does not match open txn {open_txn}"
                )
                open_txn = None
        assert open_txn is None, f"journal ends with an unclosed txn: {open_txn}"

    def test_journaled_flag_matches_catalog(self, entries, catalog_by_name):
        # Every command actually appearing in the journal must be
        # journaled:true in the catalog (transport commands, e.g., should
        # never appear here at all).
        for e in entries:
            cmd = catalog_by_name[e["name"]]
            assert cmd["journaled"] is True, f"{e['name']} appears in the journal but is journaled:false"


# ---------------------------------------------------------------------------
# fixtures/commands/valid/ + invalid/
# ---------------------------------------------------------------------------

def _load_manifest(kind):
    return load_json(FIXTURES_DIR / "commands" / kind / "manifest.json")


VALID_FILES = [item["file"] for item in _load_manifest("valid")["fixtures"]]
INVALID_FILES = [item["file"] for item in _load_manifest("invalid")["fixtures"]]


class TestFloatJournalFixture:
    """Catalog v2, deferred proposal 1 (ACCEPTED) + design 9.4.

    Before v2 BOTH contract canonicalizers hard-rejected floats while
    timeline-core's emitted them, and the cross-language byte-parity test had
    zero float coverage. A real project with a fractional gain therefore
    produced a journal the conformance suite could not hash at all. This
    fixture is that coverage: its hashes were computed by THIS module, and
    contracts/conformance's independent Rust implementation verifies the same
    chain.
    """

    TIP = "58436fe927fa6097a17536a2ac25cc8f1aa379f65dd4736637e4ac28abf9b799"

    @pytest.fixture(scope="class")
    def entries(self):
        path = FIXTURES_DIR / "project" / "float-journal.jsonl"
        with open(path) as f:
            return [json.loads(line) for line in f if line.strip()]

    def test_chain_verifies(self, entries):
        ok, tip, count = verify_chain(entries)
        assert ok, f"chain broke at index {count}"
        assert count == 8
        assert tip == self.TIP

    def test_every_entry_validates_as_envelope(self, entries, catalog_schema, catalog_by_name):
        for e in entries:
            errs = full_validate_envelope(e, catalog_schema, catalog_by_name)
            assert errs == [], f"{e['id']} ({e['name']}): {errs}"

    def test_it_actually_contains_floats(self, entries):
        floats = [
            v
            for e in entries
            for v in e["params"].values()
            if isinstance(v, float)
        ]
        assert len(floats) >= 6, "the point of this fixture is float coverage"

    def test_canonicalization_normalizes_the_float_token_not_the_shape(self):
        from conformance_py.canonical import canonical_json_bytes

        # Shortest round-trip: 1e3 -> 1000.0, 1.50 -> 1.5.
        assert canonical_json_bytes({"v": 1e3}) == b'{"v":1000.0}'
        assert canonical_json_bytes({"v": 1.50}) == b'{"v":1.5}'
        # But the integer/float SHAPE is never changed.
        assert canonical_json_bytes({"v": 2}) == b'{"v":2}'
        assert canonical_json_bytes({"v": 2.0}) == b'{"v":2.0}'
        # -0.0 is a distinct token and therefore a distinct hash.
        assert canonical_json_bytes({"v": -0.0}) == b'{"v":-0.0}'
        assert canonical_json_bytes({"v": -0.0}) != canonical_json_bytes({"v": 0.0})

    def test_non_finite_values_are_still_refused(self):
        from conformance_py.canonical import canonical_json_bytes

        for bad in (float("nan"), float("inf"), float("-inf")):
            with pytest.raises(ValueError):
                canonical_json_bytes({"v": bad})


class TestValidCommandFixtures:
    def test_manifest_lists_13(self):
        # 12 in the original P0-C set + marker_remove.json (P0-C proposal 1,
        # APPROVED by the coordinating session 2026-07-11).
        assert len(VALID_FILES) == 13

    @pytest.mark.parametrize("filename", VALID_FILES)
    def test_fixture_is_fully_valid(self, filename, catalog_schema, catalog_by_name):
        envelope = load_json(FIXTURES_DIR / "commands" / "valid" / filename)
        errors = full_validate_envelope(envelope, catalog_schema, catalog_by_name)
        assert errors == [], f"{filename}: {errors}"

    def test_clip_move_matches_architecture_doc_worked_example(self, catalog_by_name):
        envelope = load_json(FIXTURES_DIR / "commands" / "valid" / "clip_move.json")
        assert envelope["name"] == "clip.move"
        assert envelope["ts"] == "2026-07-11T20:04:11Z"
        assert set(envelope["params"].keys()) == {"clipId", "trackId", "startTicks"}

    def test_gen_finalize_fixture_present(self):
        # Session adaptation requirement: gen.finalize must be in the catalog
        # AND exercised by a valid fixture.
        envelope = load_json(FIXTURES_DIR / "commands" / "valid" / "gen_finalize.json")
        assert envelope["name"] == "gen.finalize"
        assert "draftTakeId" in envelope["params"]
        assert "targetQualityRung" in envelope["params"]


class TestInvalidCommandFixtures:
    # Each invalid fixture's designed failure must show up as an error whose
    # tag matches what the fixture was built to violate - not just "some
    # error, any error".
    EXPECTED_TAG_SUBSTRING = {
        "unknown_command_name.json": "catalog:",
        "missing_required_field.json": "shape:",
        "bad_id_format.json": "shape:",
        "bad_hash_format.json": "shape:",
        "bad_timestamp_format.json": "shape:",
        "bad_actor_kind.json": "shape:",
        "params_wrong_type.json": "params:",
        "params_missing_required.json": "params:",
        "undoable_missing_inverse.json": "inverse:",
        "nonundoable_has_inverse.json": "inverse:",
        "additional_properties_rejected.json": "shape:",
        "result_ok_false_missing_error.json": "shape:",
    }

    def test_manifest_lists_12(self):
        assert len(INVALID_FILES) == 12

    def test_expected_tag_table_covers_every_file(self):
        assert set(self.EXPECTED_TAG_SUBSTRING.keys()) == set(INVALID_FILES)

    @pytest.mark.parametrize("filename", INVALID_FILES)
    def test_fixture_fails_for_the_expected_reason(self, filename, catalog_schema, catalog_by_name):
        envelope = load_json(FIXTURES_DIR / "commands" / "invalid" / filename)
        errors = full_validate_envelope(envelope, catalog_schema, catalog_by_name)
        assert errors, f"{filename} was expected to be invalid but validated cleanly"
        expected_tag = self.EXPECTED_TAG_SUBSTRING[filename]
        assert any(e.startswith(expected_tag) for e in errors), (
            f"{filename}: expected an error tagged '{expected_tag}', got {errors}"
        )


# ---------------------------------------------------------------------------
# fixtures/gen-protocol/
# ---------------------------------------------------------------------------

class TestGenProtocolSchemas:
    def test_schema_is_valid_json_schema(self, gen_protocol_schemas):
        Draft202012Validator.check_schema(gen_protocol_schemas)

    REQUEST_DEF_BY_OP = {
        "generate": "generateRequest",
        "revise": "reviseRequest",
        "analyze": "analyzeRequest",
    }
    RESPONSE_DEF_BY_OP = {
        "generate": "submitResponse",
        "revise": "submitResponse",
        "analyze": "analyzeResponse",
    }

    @pytest.fixture(scope="class")
    def pairs_manifest(self):
        return load_json(FIXTURES_DIR / "gen-protocol" / "manifest.json")

    def test_manifest_lists_3_pairs(self, pairs_manifest):
        assert pairs_manifest["count"] == 3
        assert len(pairs_manifest["pairs"]) == 3

    @pytest.mark.parametrize("op", ["generate", "revise", "analyze"])
    def test_request_and_response_validate(self, op, gen_protocol_schemas, pairs_manifest):
        pair = next(p for p in pairs_manifest["pairs"] if p["op"] == op)
        req = load_json(FIXTURES_DIR / "gen-protocol" / pair["request"])
        resp = load_json(FIXTURES_DIR / "gen-protocol" / pair["response"])

        req_v = sub_validator(gen_protocol_schemas, f"#/$defs/{self.REQUEST_DEF_BY_OP[op]}")
        resp_v = sub_validator(gen_protocol_schemas, f"#/$defs/{self.RESPONSE_DEF_BY_OP[op]}")

        req_errors = list(req_v.iter_errors(req))
        resp_errors = list(resp_v.iter_errors(resp))
        assert req_errors == [], f"{op} request: {[e.message for e in req_errors]}"
        assert resp_errors == [], f"{op} response: {[e.message for e in resp_errors]}"

    @pytest.mark.parametrize("op", ["generate", "revise"])
    def test_job_id_echoes_request_id(self, op, pairs_manifest):
        pair = next(p for p in pairs_manifest["pairs"] if p["op"] == op)
        req = load_json(FIXTURES_DIR / "gen-protocol" / pair["request"])
        resp = load_json(FIXTURES_DIR / "gen-protocol" / pair["response"])
        assert resp["jobId"] == req["requestId"]

    def test_analyze_response_gap_fields_are_null(self, pairs_manifest):
        pair = next(p for p in pairs_manifest["pairs"] if p["op"] == "analyze")
        resp = load_json(FIXTURES_DIR / "gen-protocol" / pair["response"])
        assert resp["downbeats"] is None
        assert resp["loudnessLufs"] is None

    def test_finalize_request_schema_nests_revise_request(self, gen_protocol_schemas):
        v = sub_validator(gen_protocol_schemas, "#/$defs/finalizeRequest")
        sample = {
            "requestId": "10000000000000000000000001",
            "draftTakeId": "take-1",
            "targetQualityRung": "full",
            "request": {
                "requestId": "10000000000000000000000002",
                "sourceAudioRef": "clip-1",
                "regionStartSeconds": 1,
                "regionEndSeconds": 2,
                "instruction": "test",
            },
        }
        assert list(v.iter_errors(sample)) == []


class TestGenProtocolYamlOptional:
    """gen-protocol.v1.yaml is documentation-first OpenAPI; the authoritative
    machine-checked schemas are gen-protocol.schemas.json (tested above, no
    YAML parser required). This one structural sanity check uses PyYAML
    opportunistically and is SKIPPED, not failed, when PyYAML is unavailable,
    so it never blocks the stdlib+jsonschema-only boot-test contract."""

    def test_yaml_parses_and_refs_resolve(self, gen_protocol_schemas):
        try:
            import yaml
        except ImportError:
            pytest.skip("PyYAML not installed; gen-protocol.schemas.json tests above are authoritative")

        with open(CONTRACTS_DIR / "gen-protocol.v1.yaml") as f:
            doc = yaml.safe_load(f)

        assert doc["openapi"].startswith("3.1")
        assert len(doc["paths"]) == 13

        defs = set(gen_protocol_schemas["$defs"].keys())
        refs = set()

        def walk(node):
            if isinstance(node, dict):
                ref = node.get("$ref")
                if isinstance(ref, str) and ref.startswith("gen-protocol.schemas.json#/$defs/"):
                    refs.add(ref.rsplit("/", 1)[-1])
                for v in node.values():
                    walk(v)
            elif isinstance(node, list):
                for v in node:
                    walk(v)

        walk(doc)
        missing = refs - defs
        assert not missing, f"gen-protocol.v1.yaml references $defs not present in gen-protocol.schemas.json: {missing}"
