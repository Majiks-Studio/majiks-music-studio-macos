# License Manifest: Majik's Music Studio DAW Engine (Phase 1)

Dependency license inventory for the engine Rust workspace and the standalone
contracts conformance crate, with the policy the CI harness enforces.

**Policy:** allowed outright: MIT, MIT-0, Apache-2.0 (including WITH
LLVM-exception), BSD (0BSD/1/2/3-Clause), MPL-2.0, Zlib, ISC, Unlicense,
CC0-1.0, Unicode-3.0, Unicode-DFS-2016. SPDX expressions are evaluated
properly: OR passes if any branch is allowed, AND requires every part, WITH
exceptions reduce to the base license, legacy "A/B" slash syntax reads as OR.
The build FAILS on any crate whose expression cannot be satisfied from the
allowlist and that mentions GPL/AGPL/LGPL, and on any registry crate with no
license field (unknown). Non-copyleft oddities are flagged REVIEW without
failing.

**Enforced by:** the `license_check` step in `scripts/ci-check.sh`
(runs `cargo metadata` over both trees listed below on every invocation, so
this document is the human summary and the CI step is the source of truth).

**Last verified:** 2026-07-11 on branch lane/l7-ci-harness (base main cbfec4c).
Result: 192 crates examined (union of both trees), zero DENY, zero REVIEW.

---

## Trees Covered

1. `engine/` workspace (members: `timeline-core`, `render`)
2. `engine/contracts/conformance` (standalone crate, its own lockfile)

## Workspace Members (our code)

| Crate | License | Notes |
|-------|---------|-------|
| timeline-core | Apache-2.0 | from workspace.package |
| render | Apache-2.0 | from workspace.package |
| contracts-conformance | none declared | local, publish=false, repo-internal; reported by CI as a note, not a failure |

## Direct Dependencies

| Crate | License | Used by |
|-------|---------|---------|
| serde | MIT OR Apache-2.0 | both members |
| serde_json | MIT OR Apache-2.0 | both members, conformance |
| thiserror | MIT OR Apache-2.0 | both members |
| cpal | Apache-2.0 | render (audio I/O) |
| hound | Apache-2.0 | render (WAV I/O) |
| rubato | MIT | render (resampling) |
| blake3 | CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception | render fixtures, conformance |
| crossbeam-channel | MIT OR Apache-2.0 | render (RT command channel) |
| libc | MIT OR Apache-2.0 | render (via cpal) |
| jsonschema | MIT | conformance (default-features off, no HTTP resolver) |

## Full-Tree License Expressions (both trees, transitive included)

Exact expressions observed on 2026-07-11; every one satisfiable from the
allowlist. Counts move as Cargo.lock moves; the CI step re-derives this list
each run.

| Expression | Verdict |
|------------|---------|
| MIT OR Apache-2.0 | PASS (106 crates) |
| MIT | PASS |
| Apache-2.0 | PASS |
| Apache-2.0 OR MIT | PASS |
| Apache-2.0/MIT (legacy slash = OR) | PASS |
| MIT/Apache-2.0 (legacy slash = OR) | PASS |
| Unlicense OR MIT, Unlicense/MIT | PASS |
| BSD-2-Clause; BSD-3-Clause; BSD-x OR MIT OR Apache-2.0 | PASS |
| ISC | PASS |
| MIT-0 | PASS |
| Unicode-3.0 | PASS (18 crates, ICU/unicode data) |
| (MIT OR Apache-2.0) AND Unicode-3.0 | PASS (both sides allowed) |
| Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT | PASS |
| CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception | PASS |
| CC0-1.0 OR MIT-0 OR Apache-2.0 | PASS |
| MIT OR Apache-2.0 OR LGPL-2.1-or-later | PASS via MIT branch (r-efi and friends; the LGPL branch is never elected) |

The last row is the one that matters: a naive substring scan flags it as GPL.
Correct SPDX OR semantics accept the crate under MIT and we never take the
LGPL option. If a crate ever appears whose ONLY branches are GPL-family, the
CI step prints it and fails.

## Model Weights and External Assets

Per 04-RESEARCH-NOTES.md section B (stem separation matrix) in the program
docs (~/Documents/majiks-studio-daw/):

| Model | License | Integration | Status |
|-------|---------|-------------|--------|
| ACE-Step 1.5 (text-to-music) | MIT (code + weights, incl. XL 4B variants) | Gen protocol (L4) | approved via D2 |
| htdemucs_ft (Demucs v4 stem separation) | MIT (code + weights) | Media analysis (L3) | approved via D2 |

Known NOT shippable (documented so nobody re-litigates): BS-RoFormer /
Mel-Band RoFormer community weights (unlicensed or GPL-3.0), Open-Unmix umxl
(CC BY-NC-SA), Tracktion Engine / JUCE (GPLv3/AGPLv3 dual-commercial; the
licensing conflict is why D1 chose the in-house engine).

## Running the Check

```bash
# Full harness (license_check is step 5)
scripts/ci-check.sh

# License check alone
SKIP_FMT=1 SKIP_CLIPPY=1 SKIP_CARGO_TEST=1 SKIP_WASM_CHECK=1 \
SKIP_PYTEST_CONTRACTS=1 SKIP_PYTEST_REPAINT=1 SKIP_CONFORMANCE_RUST=1 \
SKIP_SWIFT_BUILD=1 scripts/ci-check.sh
```

## Updating This Manifest

1. Add or bump a dependency in `engine/*/Cargo.toml` or
   `engine/contracts/conformance/Cargo.toml`.
2. Run the license check (above). A DENY fails the build; a REVIEW prints a
   warning for a human call.
3. Update the tables here if the direct-dependency set or the expression list
   changed, and commit both together.
