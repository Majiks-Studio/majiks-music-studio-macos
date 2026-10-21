# Evidence Template: CI Harness Lane L7

Use this template to document measured results from ci-check.sh runs and probe testing. Include this document in your pull request with full output, measured numbers, and how to reproduce.

## Summary

**Date:** [YYYY-MM-DD]  
**Branch:** lane/l7-ci-harness  
**Git Hash:** [commit hash]  
**Platform:** [macOS/Linux/other, version]  
**Rust Version:** [toolchain version]  

## What Ran

List each step executed and its result:

```
cargo fmt --check        : PASS
cargo clippy             : PASS
cargo test (engine)      : PASS
wasm check               : PASS
license check            : PASS
pytest (contracts)       : PASS
pytest (repaint harness) : PASS
conformance (Rust)       : PASS
swift build              : PASS
probe runners            : PASS
```

## Measured Numbers

### Build Times
- fmt check: [X.XXs]
- clippy: [X.XXs]
- cargo test (debug): [X.XXs]
- wasm check: [X.XXs]
- conformance Rust: [X.XXs]
- swift build: [X.XXs]

### Test Results
- Engine workspace tests: [N passed, M skipped]
- Contracts conformance: [N passed, M skipped]
- Repaint harness: [N passed, M skipped]

### Disk Usage
- Before: [X GB free]
- After: [X GB free]
- Peak build artifacts: [X GB]

## Deviations & Findings

Note any pre-existing failures, warnings, or unusual behavior:

- If step X fails on current main (pre-dates this lane), document it here with the ALLOW_FAIL_<STEP> workaround applied.
- If disk space approaches 4 GB limit, note it.
- If Swift toolchain is missing, note how it was installed.

### Example: Pre-existing Clippy Warnings

> Clippy found 3 pre-existing warnings in timeline-core (not from this lane):
> - `unused_imports` in src/lib.rs:42
> - (description)
> 
> Run with `ALLOW_FAIL_CLIPPY=1` to gate this step; this lane does not fix pre-existing issues.

## How to Reproduce

Full command to run the entire CI check from a clean checkout:

```bash
cd /path/to/repo/wt-l7
scripts/ci-check.sh
```

To run individual steps:

```bash
SKIP_FMT=1 SKIP_CLIPPY=1 scripts/ci-check.sh  # skip format and lint
SKIP_SWIFT_BUILD=1 scripts/ci-check.sh         # skip Swift on Linux
ALLOW_FAIL_CLIPPY=1 scripts/ci-check.sh        # allow pre-existing clippy warnings
```

To run probe tests:

```bash
scripts/probe-5min.sh                          # quick 5-minute stress test
scripts/probe-30min.sh                         # full 30-minute stress test
```

## Licenses Checked

Engine workspace dependency summary:

| Crate | License | Status |
|-------|---------|--------|
| timeline-core | Apache-2.0 | OK |
| render | Apache-2.0 | OK |
| serde | MIT | OK |
| serde_json | MIT | OK |
| thiserror | MIT | OK |

Model weights (from 04-RESEARCH-NOTES.md):
- ACE-Step 1.5: MIT
- htdemucs_ft: MIT

No GPL/AGPL/unknown licenses found.

## Questions

List any ambiguities or concerns from the ci-check.sh build:

1. [Question?]
2. [Known limitation?]
