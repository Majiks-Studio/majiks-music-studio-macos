# Majik's Music Studio engine

This workspace is the Rust core of the Majik's Music Studio DAW. It owns the
timeline model and command bus, the realtime render graph, the media analysis
pipeline, and the machine-checked contract schemas that define the wire formats
between lanes.

## Crates

### `timeline-core`

The keystone crate. It owns the full project model (`Project`, `Track`, `Clip`,
`Source`, `TempoMap`), the 87-command catalog bus (catalog v1.1), the blake3
hash-chained journal with undo/redo, transactional sessions, and `.mstudio`
package I/O.

The public API is documented in `INTERFACE.md` and carries an L1 guarantee:
fields and methods may be added, nothing listed is renamed, removed, or retyped.
Breaking changes require a written proposal.

Evidence: `engine/docs/evidence/l1-timeline-core.md`. The crate has 29 library
unit tests plus integration tests covering catalog coverage (all 87 commands),
canonicalization byte-identity, golden replay of the fixture journal (30 entries,
tip hash `8cf75844...d2bf1bb`), proptest property cases (480 total), a 10,000
command fuzz run, and crash-safety via `kill -9` mid-save. Source is roughly
4,700 lines across 13 modules.

### `render`

The realtime render core. It builds an N-track channel strip (clip sum, gain,
equal-power pan, 4-band EQ, two post-fader sends), two fixed buses (Freeverb
reverb, tempo-synced ping-pong delay), and a master bus with a true-peak
lookahead limiter and EBU R128 LUFS metering. It provides sample-accurate
multi-clip scheduling, per-clip warp (Signalsmith Stretch primary, WSOLA
fallback) on a separate thread, sample-accurate automation (volume, pan), and
offline bounce through the same render function.

Evidence: `docs/evidence/l2-render-graph.md`. It is covered by unit and integration tests. A 30-minute
stress probe recorded 0 underruns, 0 deadline misses, 0 command overruns, 0
leaked buffers, callback compute p95 of 0.1 ms against a ~2.9 ms budget, and
bit-identical offline-vs-realtime null output.

### `media`

Decode, sample-rate conversion, waveform peak tile generation, and audio analysis
(tempo beat-tracking, key detection via chroma, loudness via EBU R128). It ships
a single symphonia 0.6 decode service with rubato windowed-sinc SRC, blake3
content hashing on ingest, and an async cancel-safe tile job with disk cache.

Evidence: `docs/evidence/l3-media-analysis.md`. The crate has 29 passing tests
(2 ignored when no local audio files are present). The pure-math surface
(tempo, key, waveform peaks) compiles to wasm32. The `native` feature (default)
gates file I/O, decoding, and the tile job.

### `agent-surface`

The agent and app-integration surface over the `timeline-core` command bus. It
owns the UniFFI FFI the Swift app links, the MCP server, the in-app Sterling
copilot, the revise/extend/layer and Open in Studio landing pipelines, and the
`majiks_studio_cli` binary.

Its MCP tool registry is generated from the command catalog: one `studio_<name>`
tool per catalog command (input schema taken verbatim from the catalog
`paramsSchema`), plus the host surface (read tools, the Gen Protocol proxy, the
revise/extend/layer workflow tools, undo/redo, the metronome / note-preview /
retro-capture session tools, the landing bridge, and take maintenance). Catalog
v2.0 yields 146 tools with one documented exclusion (`gen.landed`, written by
the engine, not agent-invocable). The committed
manifest is `engine/docs/generated/mcp-tools.v1.json`; the parity gate
(`tests/parity.rs`) fails the build if the generated surface and the committed
JSON disagree, or if any catalog command lacks a tool without a documented
exclusion.

The MCP server is an `rmcp` localhost streamable-HTTP server on 127.0.0.1:8478
(path `/mcp`), authenticated by a bearer PAT, off by default and failing closed:
it refuses to start unless enabled with a non-empty PAT and binds 127.0.0.1
only. Perform and Manage tool calls are rate limited; Manage tools require
`confirm: true`.

Sterling, the in-app copilot, is an in-process OpenAI-compatible chat
tool-calling loop that enumerates the same registry and dispatches through the
same choke point every transport uses, so a Sterling edit is a journaled command
identical to a human click or an external MCP client. That is agent parity.
Sterling carries a per-turn tool budget, a model-call cap, a credential and
self-config blocklist checked before dispatch, and API-key scrubbing on every
event.

Reference docs: `docs/AGENT_API.md` (the agent guide), `docs/MCP_API.md` (the
tool reference), and `engine/docs/generated/mcp-tools.v1.json` (the generated
registry).

### `contracts/conformance`

Schema and hash-chain conformance tests for the binding contracts in
`engine/contracts/` (command catalog, Gen Protocol, `.mstudio` project format).
No engine behavior lives here. It validates fixtures against JSON schemas and
verifies the blake3 journal hash chain.

Evidence: `engine/contracts/README.md`. The crate has 7 lib tests and 23 fixture
conformance tests. Both the Rust runner and a parallel Python pytest suite
cross-check the same fixtures.

## Build and test

```bash
# From the engine/ directory:

# Full workspace build and all tests
cargo build --workspace
cargo test --workspace

# Timeline-core CI gate (unit + integration + doctests + wasm check +
# boot-test example + workspace build)
engine/timeline-core/ci-check.sh

# Render crate tests only
cargo test -p render

# Media crate tests
cd engine/media && cargo test

# wasm32 compile checks
cargo check -p timeline-core --target wasm32-unknown-unknown
cargo check --target wasm32-unknown-unknown --no-default-features -p media

# Contracts conformance (Rust)
cd engine/contracts/conformance && cargo test

# Contracts conformance (Python, from repo root)
python3 -m pytest engine/contracts/

# Render proof binaries (release)
cargo build --release --workspace
target/release/engine-proof demo
target/release/engine-proof boot-test
target/release/engine-proof null-test
target/release/engine-proof probe --seconds 300
target/release/engine-proof bounce

# Media analyze example
cargo run -q -p media --example analyze

# License check (full CI harness, step 5)
SKIP_FMT=1 SKIP_CLIPPY=1 SKIP_CARGO_TEST=1 SKIP_WASM_CHECK=1 \
SKIP_PYTEST_CONTRACTS=1 SKIP_PYTEST_REPAINT=1 SKIP_CONFORMANCE_RUST=1 \
SKIP_SWIFT_BUILD=1 scripts/ci-check.sh
```

## Rules that do not bend

**Render callback discipline.** The render callback may not allocate, lock, or
perform I/O. This is enforced at runtime by the counting global allocator active
during every test and probe run, and by code discipline (single render function,
fixed state, `try_recv`/`try_send` only, no printing on the audio thread).

**Contracts are law.** The schemas and fixtures in `engine/contracts/` are the
machine-checked wire formats. If a lane needs a field that does not exist, it
must propose a change to the coordinating session. Contracts change by explicit
merge, never as a side effect of another lane. The change-control precedent is
`marker.remove` (proposal 1), which was added to the catalog as an approved
proposal rather than silently edited in.

**Evidence doc per lane.** Each lane has an evidence document that records what
it does, test numbers, and measured results. Do not guess at a crate's behavior
without reading the evidence doc for that lane first.

**wasm32 builds are gated.** `timeline-core` compiles to `wasm32-unknown-unknown`
with no filesystem, threads, or OS clock in core paths. `media` compiles to
wasm32 behind `--no-default-features --features wasm`, which strips the native
I/O, decode, and tile-job gates.

## Layout

```
engine/
  Cargo.toml                    # workspace root: members, shared deps, release profile
  LICENSES.md                   # dependency license inventory and policy
  contracts/
    command-catalog.v1.1.json   # 87 commands (v1.1), params schemas, undo/journal flags
    gen-protocol.v1.yaml        # OpenAPI 3.1: 10 ops + job lifecycle + capabilities
    project-format.v1.md        # .mstudio package prose
    fixtures/                   # golden project, valid/invalid command envelopes
    conformance/                # Rust crate: validates schemas + hash chain
  timeline-core/
    INTERFACE.md                # public API (L1 guarantee)
    ci-check.sh                 # CI gate: tests + wasm + boot-test + workspace
    src/                        # Project, Session, Cmd, Journal, Package, schema
    tests/                      # conformance, fuzz, properties, package_crash
  render/
    src/                        # RenderCore, rt (lock-free core), host, DSP
    tests/                      # graph, warp_and_device, null_and_alloc
  media/
    src/                        # decode, tempo, key, loudness, tiles, hash
    tests/                      # decode_roundtrip, golden_tempo, field_parity
  agent-surface/
    src/                        # ffi, mcp server, dispatch, registry, copilot, revise, landing
    tests/                      # parity, mcp_handshake, revise, takes, export, import, landing
  docs/generated/
    mcp-tools.v1.json           # generated MCP tool registry (146 tools, catalog v2.0)
```
