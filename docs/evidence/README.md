# Evidence Documentation Index

This folder holds measured results and reproducible findings from all Phase 0 and Phase 1 lanes.

## Phase 0 (Proof & Setup)

- [P0A: Repaint Harness](p0a-repaint.md): ACE-Step repaint pipeline, tempo/grid mapping, fixture generation
- [P0B: Engine Proof](p0b-engine-proof.md): Rust engine compile, render callback, null-alloc & playback tests
- [P0C: Contracts](p0c-contracts.md): Command catalog conformance, schema validation, JSON fixtures

## Phase 1 Lanes

Each lane commits its evidence doc when it lands; entries below marked
(pending) do not exist yet.

- L1 Timeline Core: l1-timeline-core.md (pending)
- L2 Render Graph: l2-render-graph.md (pending)
- L3 Media Analysis: l3-media-analysis.md (pending)
- L4 Gen Protocol: l4-gen-protocol.md (pending)
- L5 Studio Shell: l5-studio-shell.md (pending)
- L7 CI + Fixtures + Licenses: [l7-ci-harness.md](l7-ci-harness.md)

## Probe Test Logs

Dynamic logs from long-running stress tests:

- `probe-5min_*.log`: 5-minute fast stress test (desktop iteration)
- `probe-30min_*.log`: 30-minute full stress test (release mode, nightly)

## How to Read Evidence

Each lane evidence doc includes:
1. **Summary**: git hash, platform, toolchain version
2. **What Ran**: list of steps and their PASS/FAIL status
3. **Measured Numbers**: build times, test counts, disk usage
4. **Deviations**: pre-existing failures, platform quirks, workarounds
5. **How to Reproduce**: exact commands and env flags

## Using TEMPLATE.md

When your lane completes, copy `TEMPLATE.md` to `l<N>-<lane-name>.md` and fill in the measured numbers.

If a step fails on current main (predates your lane), document it under "Deviations" and run the full suite with `ALLOW_FAIL_<STEP>=1` to gate that step while remaining honest.

## Questions?

See `~/Documents/majiks-studio-daw/03-PROGRAM.md` for the Phase/Lane definitions and binding rules.
