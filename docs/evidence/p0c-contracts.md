# P0-C evidence: contract freeze (command catalog, Gen Protocol, .mstudio format)

Lane: `lane/p0c-contracts`. Commit under test: `6ba2ec1` ("P0-C: freeze command
catalog, Gen Protocol, and .mstudio contracts"), branched from
`main@1869a5e`. Verified 2026-07-11.

## What validated

Both boot-test one-liners were run twice: once in the working worktree, and
once (the run recorded below) against a **fresh `git clone` of the pushed
branch into an unrelated directory** — a real clean checkout, not the worktree
these files were authored in.

```
$ git clone --branch lane/p0c-contracts <remote> clean-checkout-test
$ cd clean-checkout-test
$ python3 -m pytest engine/contracts/
============================= test session starts ==============================
platform darwin -- Python 3.14.4, pytest-9.0.2, pluggy-1.6.0
collected 70 items

engine/contracts/conformance_py/test_conformance.py ....s............... [ 28%]
..................................................                       [100%]

======================== 69 passed, 1 skipped in 0.36s =========================
```

The 1 skip is `TestBlake3Pure::test_pure_blake3_matches_compiled_when_available`,
skipped because the compiled `blake3` PyPI package is not installed in this
environment's default `python3` (Homebrew Python 3.14.4) — exactly the
condition the pure-Python fallback exists for. It is not a failure and does not
affect the suite's stdlib+jsonschema-only dependency contract.

```
$ cd engine/contracts/conformance && cargo test
   Compiling contracts-conformance v0.1.0 (.../clean-checkout-test/engine/contracts/conformance)
    Finished `test` profile [unoptimized + debuginfo] target(s) in 5.89s
     Running unittests src/lib.rs

running 7 tests
test result: ok. 7 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out

     Running tests/conformance.rs

running 23 tests
test result: ok. 23 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out

   Doc-tests contracts_conformance
test result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

**30/30 Rust tests green, 69/70 Python tests green (1 skip, not a failure),
zero flakes across two independent runs (worktree + clean clone).**

Toolchain this was verified against: `rustc 1.93.0 (254b59607 2026-01-19)`,
`cargo 1.93.0 (083ac5135 2025-12-15)`, `Python 3.14.4` (Homebrew,
`/opt/homebrew/bin/python3`), `jsonschema` 4.26.0 (already present in that
Python's global site-packages; not vendored by this lane).

## The one non-obvious correctness step: a pure-Python BLAKE3, cross-checked

The session brief required the pytest side to run with only stdlib +
`jsonschema` + a pure-Python `blake3` fallback, because the compiled `blake3`
wheel is not installed in this Mac's default Python 3.14 environment (verified:
`import blake3` fails; a `cp314` wheel does exist on PyPI but installing it is
an extra setup step the boot-test one-liner must not require).

Before trusting a from-scratch BLAKE3 implementation to produce the fixtures'
"hand-computed" hash chain, it was cross-validated byte-for-byte against the
real compiled `blake3` package (installed into a disposable venv purely for
this verification, not part of the shipped conformance path) across 39 inputs:
empty input; every length from 1 to 65537 bytes at block boundaries (63/64/65),
chunk boundaries (1023/1024/1025), and multi-chunk tree-merge boundaries
(2047/2048/2049, up to 65537 = well past 64 chunks); and Unicode content. All
39 matched exactly. The known BLAKE3 test vector for the empty string
(`af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262`) is pinned
literally in both `conformance_py/test_conformance.py` and
`conformance/src/lib.rs` so a regression is caught even in an environment where
the compiled package is unavailable to compare against live.

## Cross-language proof, not just two self-consistent implementations

The Rust crate does not import the fixtures Python wrote and trust them; it
independently recomputes the entire 30-entry hash chain using its own
from-scratch `canonical_json_bytes`/`compute_entry_hash`
(`conformance/src/lib.rs`) and asserts the result matches the `hash` field
Python's `fixtures/tools/generate_fixtures.py` wrote into
`fixtures/project/minimal-journal.jsonl`
(`journal_hash_chain_verifies_against_python_generated_hashes` in
`conformance/tests/conformance.rs`). That test passing is the real evidence
the two implementations of "Canonicalization and the hash chain"
(`engine/contracts/README.md`) agree, not merely that each one doesn't
contradict itself.

Getting there caught three real transcription bugs during development, each
from hand-typing a long hex/ULID string and getting the length wrong by one or
a few characters (a 106-char string typed for a 64-char constant; a 63-char
BLAKE3 digest missing its last hex digit; an off-by-one ULID in early manual
smoke tests) — each one caught by a `len()` check or a failing test, never by
eyeballing the string. The fix in every case was to generate the value
programmatically (or copy it from a verified source) and verify its length in
code before trusting it, rather than transcribing by hand a second time. This
is why `fixtures/tools/generate_fixtures.py` computes every id/hash in the
committed fixtures programmatically instead of any fixture file being
hand-typed, and why `conformance/src/lib.rs`'s two Unicode-escaping unit tests
build both their input and their expected output from Python's `json.dumps`
as generated ground truth rather than from literal characters pasted into the
Rust source.

## Coverage table

| Contract artifact | Validated by |
|---|---|
| `command-catalog.v1.json` structure | Both suites: validates against `command-catalog.schema.json#/$defs/catalogDocument` |
| Every command's `paramsSchema` is itself a valid JSON Schema | Both suites |
| No duplicate command names | Both suites |
| `undoable` <-> `inverseRule.mode` <-> `nonUndoableReason` consistency | Both suites (Python also enforced structurally via the schema's `allOf`/`if`/`then`) |
| `explicit` inverse names a real catalog command | Python (`test_explicit_inverse_names_a_real_command`) |
| Command count is exactly 70 (67 bulleted in 02-ARCH section 4 + `gen.landed` + `txn.begin`/`txn.commit`, all named in section 4's prose) | Both suites |
| `readSurface` covers all 8 named read APIs | Python |
| transport.* unjournaled + not undoable | Both suites |
| gen.* request ops journaled + not undoable + async | Python |
| `gen.landed` system-authored | Python |
| export.* journaled + not undoable + `inverseRule.mode=none` | Both suites |
| `project.schema.json` structure | Both suites: schema self-check + `additionalProperties:true` guard (forward-compat is load-bearing, guarded against an accidental future tightening) |
| `minimal-project.json` validates against `project.schema.json` | Both suites |
| Unknown fields on `project.json` round-trip without failing validation | Both suites (explicit forward-compat regression test) |
| `minimal-journal.jsonl` has exactly 30 entries | Both suites |
| Every journal entry is itself a valid, catalog-cross-referenced command envelope | Both suites |
| Full 30-entry hash chain verifies from genesis | Both suites, and cross-language (Rust reproduces Python-generated hashes) |
| First entry chains from `GENESIS_HASH` (64 zero chars) correctly | Both suites |
| Tampering with one entry breaks the chain from exactly that point forward | Both suites (explicit tamper-detection test) |
| `project.json`'s `journal` checkpoint block (`entryCount`/`tipHash`/`tipId`/`genesisHash`) matches an independent chain recomputation | Both suites - this is the "replay equals the checkpoint" fixture requirement, proved as a checkpoint-pointer integrity check (see `project-format.v1.md` and README.md for why this lane proves the pointer, not a full semantic command replay, which is timeline-core's job) |
| `txn.begin`/`txn.commit` pairing (no nesting, every commit matches an open begin) | Both suites |
| Every journal entry's command is `journaled:true` in the catalog | Both suites |
| 12/13 valid (12 at freeze + marker_remove via approved proposal 1) command fixtures fully validate (shape + catalog params + inverse consistency) | Both suites, parametrized per fixture |
| 12/12 invalid command fixtures fail, each for its specific documented reason (not just "some error") | Both suites, each fixture's failure tagged (`shape:`/`catalog:`/`params:`/`inverse:`) and asserted against a table, not just non-empty |
| `clip.move` valid fixture matches 02-ARCH section 4's worked example verbatim (fields + timestamp) | Python |
| `gen.finalize` valid + Rust fixture present with `draftTakeId` + `targetQualityRung` | Both suites (this is the session-adaptation-required op) |
| `gen-protocol.schemas.json` structure | Both suites |
| 3/3 Gen Protocol request/response pairs validate | Both suites, parametrized |
| `jobId` echoes `requestId` in submit responses | Both suites |
| `analyze` response's `downbeats`/`loudnessLufs` gap fields are present-but-null (not silently dropped, not fabricated) | Both suites |
| `finalizeRequest` schema correctly nests a full `reviseRequest` | Both suites |
| `gen-protocol.v1.yaml` parses as OpenAPI 3.1 and every `$ref` into `gen-protocol.schemas.json` resolves | Python only, and only opportunistically: **skipped**, not failed, if PyYAML is not importable, so this check never becomes a hard dependency of the stdlib+jsonschema boot-test contract. PyYAML happened to be present in this environment, so it ran and passed (13 paths, 16 distinct `$defs` referenced, 0 missing). |

## What this lane did NOT verify (by design, not oversight)

- No engine or Python-backend behavior was exercised. `gen-protocol-mapping.md`
  was built by reading the actual shipped `ace_generator.py`/`rpc_server.py`
  source (function signatures, RPC wire `params.get(...)` calls, response
  shapes) but nothing in this lane calls that code.
- "Replay equals the checkpoint" is proved as hash-chain + checkpoint-pointer
  integrity, not as a full command-interpreter replay into a reconstructed
  project model. Building a generic command executor would be engine
  behavior, out of this lane's scope. `minimal-project.json`'s actual
  `tracks`/`clips`/`sections` content is still hand-traced to match what the
  30 journal commands should produce, so it remains a usable golden fixture
  for whoever builds that executor.

## Proposals (also in README.md and the final report, repeated here for the record)

1. `marker.set` has no `marker.remove` counterpart in 02-ARCH section 4's
   catalog list. A marker's creation cannot be undone via an inverse
   `marker.set` call. Proposing `marker.remove` at the next contract revision.
2. Gen Protocol `analyze`'s `downbeats` and `loudnessLufs` have no current
   producer anywhere in the Python backend (`loudnessLufs` is planned for the
   Rust engine's `media` crate per 02-ARCH section 3, not Python; `downbeats`
   has no owner at all yet). Both nullable, always null in v1 fixtures.
3. `gen.finalize`'s `standard` quality rung (`acestep-v15-quality`) has no
   step-count default observed in any shipped backend call site — the model
   name exists (`list_models()`), but no `generate_*` method defaults to or
   documents its step count.

## File inventory

54 files under `engine/contracts/` (`git ls-files engine/contracts | wc -l`),
zero build artifacts committed (`conformance/target/` and
`conformance_py/__pycache__/` are gitignored; `conformance/Cargo.lock` is
committed deliberately, standard practice for this kind of leaf
test/tool package, and stops mattering once the crate joins a real workspace
at merge). 70 catalog commands, 8 read-surface entries, 10 Gen Protocol ops
(9 from 02-ARCH section 5 + `gen.finalize` per this session's adaptation),
30-entry journal fixture, 12+12 command envelope fixtures, 3 Gen Protocol
request/response pairs.
