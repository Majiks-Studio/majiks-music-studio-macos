# L1 timeline-core evidence

Lane L1 (Phase 1) grew the P0-B seed into the keystone crate: the full project
model, the 71-command catalog bus, the blake3 hash-chained journal, the
transactional session with undo/redo, and `.mstudio` package io. This doc
records the measured results. All numbers are from the debug profile (the main
drive is tight; no release builds were kept).

Branch `lane/l1-timeline-core`, based at `main@cbfec4c` (Phase 0 merged).

## What runs the gate

```
engine/timeline-core/ci-check.sh
```

runs, in order: the whole timeline-core test suite (unit + integration +
doctests), the wasm32 compile check, the boot-test example, and a workspace
build. Debug profile only.

## Test tallies (cargo test --workspace, debug)

| Target | Tests | Notes |
| --- | ---: | --- |
| timeline-core lib unit | 13 | tempo rational math (7), Num wire-shape (2), catalog validator (4) |
| tests/commands.rs (P0-B legacy) | 8 | frame-canonical shim kept green |
| tests/conformance.rs (L1) | 7 | catalog coverage, canonicalization, golden replay |
| tests/properties.rs (L1, proptest) | 4 | 120 cases each = 480 property cases |
| tests/fuzz.rs (L1) | 1 | 10,000 legal commands |
| tests/package_crash.rs (L1) | 4 | round-trip, offline, forward-compat, kill -9 |
| render lib + host_undo + null_and_alloc + playback (P0-B) | 14 | render still compiles + passes against the public API |
| contracts-conformance (P0-C, now a workspace member) | 7 + 23 | its own lib + fixture conformance |
| doctests | pass | package.rs tree fenced as `text` |

The 29 P0-B workspace tests (render 14 + timeline commands 8 + tempo 7) are all
still green. Nothing in `engine/render/**` or `engine/contracts/**` was edited;
`engine/contracts/conformance` was added to the workspace `members` list only.

## Contract conformance (the fixtures cross-check the implementation)

- **71-command coverage.** `tests/conformance.rs` holds a representative valid
  call for every command; the set of names equals `Catalog::names()` exactly
  (71). Each representative validates against the frozen `paramsSchema`, parses
  into a typed `Cmd`, and re-emits params that re-validate.
- **Canonicalization is byte-identical.** For every fixture journal payload plus
  adversarial values, `envelope::canonical_json` equals
  `contracts_conformance::canonical_json_bytes` byte for byte.
- **Fixture chain verifies with my hashing.** Verifying
  `fixtures/project/minimal-journal.jsonl` with L1's own blake3 + canonical form
  reproduces `minimal-project.json`'s `entryCount = 30` and `tipHash`
  `8cf75844...d2bf1bb`. This proves the hash implementation matches P0-C, not
  just that it is internally consistent.
- **Golden replay.** Replaying those 30 commands through the real executor
  reproduces the golden checkpoint's tracks, clips (ticks, gain, fades),
  sections, markers, and automation. (EQ is excluded from this comparison: the
  v1 checkpoint schema has no EQ field. See proposal P2.)
- **Invalid fixtures.** The params-level invalid fixtures (wrong type, missing
  required, unknown command) are rejected by the catalog validator.

## Property tests (proptest, 120 cases each)

- **replay == checkpoint.** For random legal command sequences (3..90 steps),
  replaying the journal from empty reproduces the live model exactly, and the
  replayed tip hash equals the live tip hash.
- **undo(redo(x)) == x.** Full undo then full redo returns the exact prior
  model. The undo/redo unit counts match, and inverse application is journaled
  forward (the journal grows; history is never rewritten).
- **full undo == baseline.** Undoing every unit returns to an empty project
  (no tracks/sections/markers, tempo back to 120).
- **single-command inverse.** For a random legal next command against a random
  state, applying the command then its full inverse sequence restores the exact
  pre-state.

## Fuzz (10,000 commands)

`tests/fuzz.rs` drives 10,000 legal-by-construction commands through a session.
Invariants checked every 500 commands and at the end: no same-track clip
overlap (tick domain), every clip length positive, materialized `start_frame`
equals a fresh tempo-map recompute, clips sorted by frame, and the blake3 chain
intact end to end. A full replay of the fuzzed journal reproduces the live
state. No panic. (Illegal candidates the generator occasionally proposes are
skipped, not applied.)

## Crash safety (kill -9 mid-save)

`tests/package_crash.rs::kill9_mid_save_recovers_to_last_journaled_command`
re-execs the test binary as a child. The child creates a package, journals 5
commands (each line fsynced), writes a **torn** `project.json` (truncated JSON)
to model a half-finished checkpoint, then `SIGKILL`s itself. The parent reopens
the package: the checkpoint fails to parse, open falls back to full journal
replay, and the project recovers to exactly the 5th command (`seq == 5`, tempo
96, both tracks, the placed clip). Also tested: save/open round-trip,
missing-asset degrades to `offline: true` (never a refusal to open), and
unknown checkpoint fields survive a round-trip (forward-compat).

## Position model + tempo

Catalog commands and persistence speak integer ticks (960 PPQ). The model
stores ticks as canonical and materializes sample-frame fields through the
tempo map on every mutation, so `project.setTempo` re-derives every clip's
frames and render keeps reading the same frame fields it read in P0-B. Tempo is
an exact rational (`Bpm { num, den }`); `92.5` BPM is representable
(`from_json_number` reads the wire decimal), and the wire-exact `bpm_wire`
number is preserved for inverses and the checkpoint.

## wasm32 discipline

`cargo check -p timeline-core --target wasm32-unknown-unknown` is clean. The
core has no filesystem, threads, or OS clock; `JournalSink` and the native
`Package`/`FileJournal` are behind `#[cfg(not(target_arch = "wasm32"))]`. The
schema validator uses `regex-lite` (no `regex`/`fancy-regex` C or syscall deps).

## Sizes

timeline-core source is ~4,700 lines across 13 modules; tests + example are
~1,300 lines. The heaviest module is `apply.rs` (the executor, ~1,665 lines:
one arm per command with validate-first / no-partial-apply / full-restore
inverse).

## Decisions recorded in code (V1-DECISION markers)

- Clip removal is blocked while a promoted take is pinned to the clip (discard
  the take first) so take un-splice stays exact.
- `take.discard` is journaled only as the un-promote of a promoted take; a
  never-promoted candidate has no catalog-expressible undo in v1, so discarding
  one is a typed error rather than invented behavior (proposal P5).
- Per-stem take promotion is composed by the host as a txn over stem clips; the
  single `take.promote` splices a single-file take's `mix` asset.
- `clip.split` maps the source offset linearly for warped clips (warp-exact
  split math is an L2 refinement).

## Proposals for the coordinating session

See the lane report. In short: P1 (pin cross-language float canonicalization
before any fractional param enters real journal traffic), P2 (add a first-class
channel-EQ field to `project.schema.json`; L1 persists EQ under `engineEq`
today), P3 (`clip.crossfade.set` needs `lengthTicks: 0` to express "no
crossfade" for its self-inverse, which the schema's `exclusiveMinimum: 0`
forbids), P4 (`clip.split` is catalog-tagged self-inverse but rejoining needs a
command sequence; the runtime inverse is correct, only the single-command
envelope hint is nominal), P5 (`take.discard` of a candidate has no v1 undo
path).
