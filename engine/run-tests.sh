#!/usr/bin/env bash
# P0-B engine test gate. Everything here is silent at the audio device.
set -euo pipefail
cd "$(dirname "$0")"

# Fixtures FIRST. engine/fixtures/*.wav are gitignored, so on a fresh clone
# agent-surface/tests/import.rs fails with a bare "No such file or directory" —
# which reads like a real regression to every lane that hits it. Generating
# before the workspace test makes a clean clone green.
echo "== fixtures: generate on demand + hash check against MANIFEST.json =="
cargo run -q -p render --bin gen-fixtures

echo "== cargo test (workspace) =="
cargo test --workspace

echo "== agent-surface MCP server: live handshake + tools/list over real HTTP =="
# The MCP server is the whole external agent transport and had ZERO gate
# coverage: `mcp_handshake.rs` is `#![cfg(feature = "mcp")]`, `mcp` is not a
# default feature, and nothing here ever passed it -- so the workspace run
# compiled the file away and printed "running 0 tests ... test result: ok" for
# it, which reads as a pass. Exactly the orphaned-suite failure the Python
# conformance block below already had, in the one place where a regression is
# invisible to every human user of the app and total for every agent.
cargo test -p agent-surface --features mcp --test mcp_handshake

echo "== agent-surface FFI interop: FFI route vs CLI route, bit-identical =="
# The SECOND file with `mcp_handshake.rs`'s defect, found by sweeping every
# `#![cfg(feature = ...)]` in the workspace: `interop.rs` is
# `#![cfg(feature = "ffi")]`, `ffi` is not a default feature, and no gate ever
# passed it. `cargo test -p agent-surface --test interop` printed
# "running 0 tests ... test result: ok" and exited 0 -- the shipped app's OWN
# engine seam (Swift talks to the engine through uniffi, not through the CLI)
# with a green line asserting nothing. The two tests do compile and do pass;
# they were simply never built. Measured before the fix: 0 tests, exit 0.
cargo test -p agent-surface --features ffi --test interop

echo "== agent-surface copilot (Sterling): loop rails + scripted demo =="
# Behind the copilot feature (pulls reqwest) so the default workspace test stays
# light. Covers the tool budget, the blocklist, the Manage confirm gate, key
# scrubbing, and the hands-free arrangement demo against a fake model server.
cargo test -p agent-surface --features copilot --lib copilot::

# The Python conformance suite was ORPHANED: nothing invoked it, so its
# command-count assertion sat red at 102 against a 113-command catalog and no
# gate noticed. A suite nobody runs is not a suite. If pytest is missing we
# FAIL rather than skip -- a silent skip is how this hid in the first place.
echo "== contracts conformance (python) =="
if python3 -c "import pytest" 2>/dev/null; then
    python3 -m pytest contracts/conformance_py -q
else
    echo "FAIL: pytest is not installed; the Python conformance suite cannot run." >&2
    echo "      Install it (python3 -m pip install pytest) or this gate is a lie." >&2
    exit 1
fi

echo "== timeline-core stays wasm32-compilable (no cpal/fs deps) =="
cargo check -p timeline-core --target wasm32-unknown-unknown

echo "== all green =="
