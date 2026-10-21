# The gates

The commands every lane must run, why each exists, and the ways each one has
lied. Every trap below burned a real lane on this repo — none is hypothetical.

```bash
rm -rf "$CARGO_TARGET_DIR/tmp/host-fixtures"
cd engine   && ./run-tests.sh                        ; echo "EXIT=$?"   # 1
cd src/swift && ./scripts/build-engine.sh            ; echo "EXIT=$?"   # 2
cd src/swift && ./scripts/check-engine-lock.sh       ; echo "EXIT=$?"   # 2b
rm -rf .build && MAJIKS_ENGINE=mock swift build      ; echo "EXIT=$?"   # 3
MAJIKS_ENGINE=real  swift build                      ; echo "EXIT=$?"   # 4
MAJIKS_ENGINE=real  swift build --build-tests        ; echo "EXIT=$?"   # 5  ← see below
MAJIKS_ENGINE=mock  swift test                       ; echo "EXIT=$?"   # 6
MAJIKS_ENGINE=real  swift test                       ; echo "EXIT=$?"   # 7  ← see below
cd src/swift && ./scripts/stem-aiken.sh              ; echo "EXIT=$?"   # 8
```

## Gate 5 exists because gates 1–4 and 6 cannot see the real-engine tests

`Tests/StudioPianoRollRealEngineTests.swift` — the file whose own header calls
itself **THE JOIN**, written precisely because nobody owned the seam between the
app and the engine — **had not compiled for an unknown length of time.**
`keepPerformance()` widened from `Int` to `StudioKeepOutcome` and two call sites
were never updated. Ten join tests were silently dead.

Nothing caught it, and this was proven rather than assumed. A guaranteed compile
error planted **inside** the `#if REAL_ENGINE` block:

| Gate | Result |
|---|---|
| `MAJIKS_ENGINE=mock swift test` | exit 1 (the usual keychain failure) — **error not caught** |
| `MAJIKS_ENGINE=real swift build` | **exit 0** — error not caught |
| `MAJIKS_ENGINE=real swift build --build-tests` | **exit 1, 10 errors — caught** |

Why: `swift test` runs under `MAJIKS_ENGINE=mock`, so `#if REAL_ENGINE` compiles
the file out entirely. `MAJIKS_ENGINE=real swift build` builds the **app target**
— tests are not part of it. Only `--build-tests` compiles test sources under the
real-engine flag.

⚠️ **A `#if` you never build under is a file you have deleted without noticing.**
If you add another conditionally-compiled test file, make sure a gate builds it,
or it is decoration.

## Gate 7 exists because building a test is not running it

Gate 5 closed half the hole and the other half went unnoticed for hours:
`--build-tests` **compiles** the real-engine tests and stops. Nothing executed
them. So the join between the app and the engine was type-checked and never
run — and the defect that hid there was not subtle.

`RealStudioEngine`'s generic `.catalog` case forwarded parameters verbatim while
every *typed* case first translated the UI's surrogate UUID into the engine's id.
So `device.param.set` — every instrument preset button — answered
`unknown track` **100% of the time**, and `track.rename`, `track.setColor`,
`clip.setGain` and four more did nothing at all on the shipped build.

Why nothing caught it: `StudioMockEngine` resolves `trackId` by parsing it as a
UUID against its **own** ids, so in the mock the two id spaces are the same
string. The conflation lived in the test double — the one place it is invisible
from — and `swift test` is mock-only.

⚠️ **`MAJIKS_ENGINE=mock swift test` cannot see any defect the mock shares.**
When a bug is a disagreement between the app and the real engine, the mock is
the last thing that will tell you. Gate 7 is the only gate that runs that seam.

⚠️ Gate 7 is **slower and needs `build-engine.sh` first** (gate 2). If it is red
while gate 6 is green, suspect the seam, not the test.

## Gate 2b exists because gate 2 is not a gate

`build-engine.sh` acquired the ability to corrupt itself across parallel lanes
and only a structural re-read of the script catches its removal.  Gate 2
compiles the xcframework; gate 2b asserts the concurrency lock, the stale-pid
reclaimer, the timeout, the per-run staging directory, and the cleanup trap all
still exist.

## Gate 8 exists because gates 1–7 cannot hear a screech

The defect that shipped was a test fixture as the default separator.  The
fixture was swapped out at the source, but the **stem files it already wrote
are still on disk** — every one is 75% silence and somically unusable.  Gate 8
scans the app's stem storage directories with the same `measure_wav` oracle the
engine's own contract tests use (`stem_usability.rs`) and fails if any
fixture-era stem remains.  CI has no stems; a developer machine that shows
fixture-era stems must re-separate or delete them.

## The traps, all observed

- ⚠️ **Never pipe a gate through `tee`, `tail` or `grep`.** You get *that*
  command's exit code, not the build's. The coordinator hit this three times in
  one session and once reported a still-running build as finished; a lane read
  `cargo test --workspace | grep …` as "60 targets green" when it was grep's 0.
  **Redirect to a file and read `$?`.**
- ⚠️ **`swift test` exits 1 on a clean tree.** There is exactly ONE known
  pre-existing failure — `StudioMCPHostTests.swift:177`, a keychain assertion.
  Capture your own baseline **before** changing anything and compare byte for
  byte. Never weaken that test to go green.
- ⚠️ **A filtered run's exit code is untrustworthy.** `swift test --filter X` has
  reported `Executed 0 tests` and exited **0**. Use filters to iterate, never to
  gate. Always confirm `passed + failed > 0`.
- ⚠️ **Plain `cargo test` fail-fasts after the lib target**, so integration tests
  never run and the result looks cleaner than it is. Use `--no-fail-fast` when
  sweeping.
- ⚠️ **A test target can run zero tests and print `ok`.** `mcp_handshake.rs` was
  `#![cfg(feature = "mcp")]` and the feature was never passed, so the entire
  agent transport printed `running 0 tests ... ok` — a green line asserting
  nothing. Same shape as the `--filter` trap, one level up.
- ⚠️ **`./scripts/build-engine.sh` must run before any `MAJIKS_ENGINE=real`
  command**, or it silently falls back to the mock and proves nothing.
- ⚠️ **`engine/run-tests.sh`, not a bare `cargo test --workspace`** — the bare
  form fails two `import.rs` tests on gitignored fixtures.
- ⚠️ **`guard::violations()` is process-wide.** An allocation assertion can fail
  because a *different* test allocated inside your measurement window.

## Timing bounds

Two are load-sensitive and are **isolated, not weakened**:

- `midi_input_latency` — the latency claim is `p50 < 1.0`, a **median**, which is
  load-robust by construction. The 10 s deadline in the spin loop is a **hang
  guard**, not the measurement.
- `landing` — `total_seconds < 60.0` is a real product claim and is unchanged. It
  **skips on a saturated machine** (load > 1.5 × cores) because a bound that
  cannot measure should not fail, and it **says so** when it skips. `MAJIKS_PERF=1`
  forces it for a deliberate acceptance run on a quiet box.

Two Swift MIDI-render perf assertions have the same sensitivity. Re-run on a
quiet machine before calling any of these a regression.

## Adding a command

A new command means **eleven count sites in ONE commit**: `catalog.rs`,
`timeline-core/tests/conformance.rs` (×2), `contracts/conformance/tests/conformance.rs`,
`contracts/conformance_py/test_conformance.py`, `parity.rs` (×2), `registry.rs`,
`support::representative_commands`, `deferred_proposals.rs`, `inverse_shape.rs`.

Plus **three more the old list did not name**, each caught by its own guard
rather than by reading:

- `engine/contracts/COMMAND-REFERENCE.md` (regenerate)
- `src/swift/Sources/Studio/CatalogNames.swift` **and**
  `src/swift/Sources/Studio/CatalogSchemas.swift` — regenerate BOTH with
  `src/swift/scripts/generate-catalog-names.sh`. The script is new; for the
  whole life of `CatalogNames.swift` its header named a generator that **did
  not exist anywhere in the repo**, so the file was hand-maintained under a
  comment saying it was not. `CatalogSchemas.swift` is what lets the mock
  engine refuse a wrong parameter name the way the real engine does, and a
  stale copy of it fails `StudioCatalogContractTests` by name.
- hardcoded counts in `StudioShellMathTests.swift` and `StudioHelpTests.swift`

And `engine/docs/generated/mcp-tools.v1.json` — **regenerate it, never hand-merge
it.** Two lanes adding tools in parallel will conflict there, and the only
correct resolution is to re-run:

```bash
cd engine && cargo run -p agent-surface --bin majiks-studio-cli \
    --features ffi,mcp -- tools --write docs/generated/mcp-tools.v1.json
```
