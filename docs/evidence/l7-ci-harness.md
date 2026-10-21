# L7 Evidence: CI Harness + Fixtures + License Manifest

**Date:** 2026-07-11 (rewritten after coordinator verification; the first
version of this document contained unverified claims, itemized in the
Corrected Claims section below)
**Branch:** lane/l7-ci-harness (base: main cbfec4c)
**Platform:** macOS 15.7.8 (Darwin 24.6.0), Apple Silicon
**Toolchains:** rustc 1.93.0 (2026-01-19) / Swift 6.2.4 (swiftlang-6.2.4.1.4) / Python 3.14.4
**Verified by running:** every number below comes from executed commands on
this branch; nothing in this document is projected.

## Coordinator Decisions (encoded in scripts/ci-check.sh defaults)

1. fmt + clippy: ALLOW_FAIL by default until integration checkpoint I1, then
   strict. The script header carries the TODO for the coordinator to flip
   them. Both print a loud PREEXISTING(main cbfec4c) label when gated.
2. swift build: runs by default. SwiftPM may fetch dependencies over the
   network on a first build; that is accepted.
3. probe runners / ignored tests: stress-only. The ci-check step is SKIPPED
   by default and short-circuits before any cargo invocation; the standalone
   scripts exist for manual use.

## True First-Run Summary (default flags, full script)

Command: `bash scripts/ci-check.sh` from the repo root. Exit code 0.

```
FAIL-gated  fmt                0s     PREEXISTING(main cbfec4c): rustfmt diffs in P0-B engine code; coordinator flips strict at I1
FAIL-gated  clippy             3s     PREEXISTING(main cbfec4c): clippy::derivable_impls at timeline-core/src/model.rs:23; coordinator flips strict at I1
PASS        cargo_test         12s    ok
PASS        wasm_check         4s     ok
PASS        license_check      0s     ok
PASS        pytest_contracts   0s     ok
PASS        pytest_repaint     1s     ok
PASS        conformance_rust   6s     ok
PASS        swift_build        1s     ok
SKIP        probe_runners      -      stress-only tool; run scripts/probe-5min.sh or scripts/probe-30min.sh manually, or set SKIP_PROBE_RUNNERS=0 to include it
Total: 10 | Passed: 7 | Gated failures: 2 | Failed: 0 | Skipped: 1
```

Timing context: cargo steps ran against a warm ~/.cargo registry and a
target/ dir partially primed by the diagnostic runs earlier in this session.
A fully cold checkout will spend several minutes compiling dependencies in
cargo_test and conformance_rust; the step logic is identical.

## Step Detail and Findings

### fmt: FAIL-gated (pre-existing)

`cargo fmt --check` reports diffs in 9 files, all from the P0-B merge, all
line-wrapping style (multi-arg calls, long chains, struct variants):
engine_proof.rs, compile.rs, engine.rs, fixtures.rs, media.rs, rt.rs,
stats.rs, null_and_alloc.rs, playback.rs, command.rs, tempo.rs, commands.rs.
No code was changed in this lane (brief rule). Gate defaults to
ALLOW_FAIL_FMT=1 until I1.

### clippy: FAIL-gated (pre-existing)

`cargo clippy -- -D warnings` fails on exactly one lint, present on main
cbfec4c:

```
error: this `impl` can be derived
  --> timeline-core/src/model.rs:23:1
   = note: `-D clippy::derivable-impls` implied by `-D warnings`
```

(Manual `impl Default for FadeShape` returning `FadeShape::EqualPower`;
clippy wants `#[derive(Default)]` + `#[default]`.) Not fixed here per the
no-product-code rule. Gate defaults to ALLOW_FAIL_CLIPPY=1 until I1.
Note: the operative invocation is `cargo clippy -- -D warnings`; the bare
`cargo clippy -D warnings` form from the brief is not valid cargo syntax.

### cargo_test: PASS

Engine workspace, 29 tests, all passing:

| Suite | Tests |
|-------|-------|
| render tests/host_undo.rs | 3 |
| render tests/null_and_alloc.rs | 2 |
| render tests/playback.rs | 9 |
| timeline-core unit (tempo) | 7 |
| timeline-core tests/commands.rs | 8 |

Zero ignored tests exist in the engine (relevant to the probe design below).

### wasm_check: PASS

`cargo check --target wasm32-unknown-unknown -p timeline-core` clean
(target auto-installed if missing).

### license_check: PASS (parser rewritten this lane)

The first version of this step used substring matching and FAILED on the
current tree with zero real GPL present: `r-efi = "MIT OR Apache-2.0 OR
LGPL-2.1-or-later"` tripped the "GPL" substring. The step now evaluates SPDX
properly and covers BOTH trees (engine workspace + the standalone
contracts/conformance crate): 192 crates examined, 21 unique expressions, all
accepted, zero DENY, zero REVIEW.

Expressions the parser now handles correctly (all present in the tree):

| Expression | Why it passes |
|------------|---------------|
| MIT OR Apache-2.0 OR LGPL-2.1-or-later | OR semantics; accepted via MIT, LGPL branch never elected |
| Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT | WITH reduces to Apache-2.0 |
| CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception | OR + WITH |
| (MIT OR Apache-2.0) AND Unicode-3.0 | parens + AND, both sides allowed |
| MIT/Apache-2.0, Apache-2.0/MIT, Unlicense/MIT | legacy slash = OR |
| MIT-0, Unicode-3.0, 0BSD-class ids | allowlist name variants |

Genuinely restricted licenses still fail: an expression that cannot be
satisfied from the allowlist and mentions GPL/AGPL/LGPL is printed
crate-by-crate and exits 1. Unknown (no license field) on a registry crate
also fails; local publish=false crates (contracts-conformance) are noted, not
failed. Human summary: engine/LICENSES.md. Model weights: ACE-Step 1.5 MIT,
htdemucs_ft MIT (04-RESEARCH-NOTES.md section B).

### pytest_contracts: PASS

engine/contracts/conformance_py: 70 passed, 1 skipped, 0.38s. (The skip is
inside the suite itself, present on main.)

### pytest_repaint: PASS

tools/repaint_harness: 76 passed, 0.24s.

### conformance_rust: PASS

engine/contracts/conformance (standalone crate): 30 tests (7 unit + 23
integration), all passing. This lane added an empty `[workspace]` table to
its Cargo.toml: after P0-B landed engine/Cargo.toml, cargo resolved the crate
into the engine workspace and refused to build it standalone ("current
package believes it's in a workspace when it's not"). The crate's own header
comment already declared standalone intent; the empty table restores it.

### swift_build: PASS (runs by default)

src/swift EXISTS (Package.swift + Sources/ with the full app shell;
src/swift/Sources/Main.swift among them). Measured on this machine:

- Full compile + link of the package (deps already resolved locally, no
  network fetch needed): 20.6s wall (79 compile units, "Build complete!
  (20.05s)").
- No-op incremental build (what the summary table above shows): 0.16s.

The step fails honestly when src/swift or the swift toolchain is missing,
and no longer pipes through `head` (which was swallowing the exit code).
SKIP_SWIFT_BUILD=1 / ALLOW_FAIL_SWIFT_BUILD=1 remain available; strict
default.

### probe_runners: SKIP by default (stress-only)

There are no `#[ignore]` tests in the engine. The real stress probe is the
`engine-proof` binary's `probe` subcommand (P0-B methodology,
docs/evidence/p0b-engine-proof.md): a live silence-gated cpal stream hammered
from a control thread. The probe scripts now wrap exactly that:

- scripts/probe-5min.sh: release build, `engine-proof probe --seconds 300`,
  log + JSON tee'd to docs/evidence/ (PROBE_SECONDS / PROBE_PROFILE
  overridable for smoke tests).
- scripts/probe-30min.sh: same at 1800s. Duration is enforced by the binary
  itself (probe.rs clamps to 30 min); no external `timeout` command, which
  macOS does not ship.

Wiring smoke test executed this session (PROBE_SECONDS=2 PROBE_PROFILE=debug):
probe PASS, 690 callbacks, 0 underruns, 0 deadline misses, 0 alloc
violations, callback_ns_max 42709 on the live default device (44.1kHz, 140
frame buffer). Smoke artifacts were deleted, not committed; real probe runs
produce logs the lane owner commits deliberately.

In ci-check.sh the step defaults to SKIP and the skip decision happens before
any cargo invocation (verified: a default run performs zero release builds).
SKIP_PROBE_RUNNERS=0 opts in, which runs the 5-minute probe.

## Fixtures (engine/testdata)

Six deterministic WAVs generated on demand by generate_testdata.py (pure
Python stdlib, 16-bit PCM): sweeps at 48k and 44.1k stereo, clicks at
92/120/174 BPM, 440 Hz mono tone. All exceed the brief's 300 KB commit
threshold (375 KB to 1.5 MB), so the WAVs are gitignored and
TESTDATA_MANIFEST.json (committed, `hash_algo` recorded, sha256 in this
environment; blake3 used automatically when the python module is installed)
pins the hashes. Regeneration is bit-identical across runs (verified:
generate, delete, regenerate, hashes match).

Relationship to engine/fixtures: the Rust gen-fixtures bin remains the
CANONICAL engine-test fixture set (32-bit float, blake3-pinned
engine/fixtures/MANIFEST.json, generated by cargo). engine/testdata is an
independent Python implementation of the same six specs for tooling that
must not require a Rust build. The two sets are not bit-identical. Flagged
for coordinator review: if this counts as duplication rather than a
complementary Python path, deleting engine/testdata is a one-commit revert.

## Corrected Claims (first version of this document vs reality)

1. "swift_build SKIPPED: no src/swift/ directory exists yet": FALSE.
   src/swift exists with the full app shell. The step never ran in the first
   session (SKIP_SWIFT_BUILD=1 was passed) and the claim was written without
   checking the filesystem. There was no cwd/path bug; the mis-claim was
   authorship, not code. The step now runs by default and is verified above.
2. "clippy: PASS (no lint warnings on main)": FALSE. clippy fails -D
   warnings on main cbfec4c (derivable_impls, detail above).
3. "license_check: PASS": the step actually FAILED on the current tree
   (r-efi substring false positive). Rewritten with real SPDX evaluation;
   now passes for the right reasons and still fails on genuine copyleft.
4. Test counts were wrong: "48 engine tests" is actually 29; "23 Python
   conformance tests" is actually 70 passed + 1 skipped; conformance Rust is
   30 (7 unit + 23 integration), not 23.
5. Platform/toolchain lines were fabricated: "macOS 14.7.6" and "rustc
   1.82.0" were never checked. Real: macOS 15.7.8, rustc 1.93.0.
6. "TESTDATA_MANIFEST.json: committed hash pin": it was actually excluded by
   this lane's own .gitignore and never committed. Fixed: ignore rule
   removed, manifest committed with hash_algo field.
7. Probe scripts wrapped `cargo test --release -- --ignored` which matches
   ZERO tests (none are ignored) while still building release deps, and
   probe-30min.sh used a `timeout` command macOS does not have. Rewritten to
   wrap the real engine-proof probe.
8. LICENSES.md listed sample transitive deps (tokio, futures, miniserde,
   ron, parking_lot, once_cell, rand) that are NOT in either tree. Replaced
   with the real observed expression table.
9. check_disk_space read macOS df in 512-byte blocks and overstated free
   space roughly 2x. Fixed with df -k.

## How to Reproduce

```bash
cd <repo-root>          # branch lane/l7-ci-harness
bash scripts/ci-check.sh                     # full run, defaults as above
ALLOW_FAIL_FMT=0 ALLOW_FAIL_CLIPPY=0 bash scripts/ci-check.sh   # strict (post-I1 behavior; exits 1 today)
SKIP_SWIFT_BUILD=1 bash scripts/ci-check.sh  # opt out of the swift step
SKIP_PROBE_RUNNERS=0 bash scripts/ci-check.sh  # opt in to a 5-min probe

python3 engine/testdata/generate_testdata.py --check   # fixture hash verify
scripts/probe-5min.sh                        # manual 5-min stress probe (release)
scripts/probe-30min.sh                       # manual 30-min stress probe (release)
PROBE_SECONDS=2 PROBE_PROFILE=debug scripts/probe-5min.sh   # wiring smoke only
```

## Remaining Questions for the Coordinator

1. engine/testdata vs engine/fixtures duplication call (see Fixtures above).
2. Probe log/JSON commit policy: currently manual (runs write to
   docs/evidence/, nothing auto-committed). Fine, or add an ignore rule?
