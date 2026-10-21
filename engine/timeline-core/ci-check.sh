#!/usr/bin/env bash
# L1 timeline-core CI gate. Debug profile only (main drive is tight).
# Run from anywhere: paths are resolved from this script's location.
set -euo pipefail
cd "$(dirname "$0")/.."   # engine/ workspace root

echo "== timeline-core: unit + integration + doctests =="
cargo test -p timeline-core

echo "== timeline-core stays wasm32-compilable (no fs/threads/clock in core) =="
cargo check -p timeline-core --target wasm32-unknown-unknown

echo "== boot-test: build via commands, save, reopen, replay =="
cargo run -q -p timeline-core --example mstudio_roundtrip

echo "== workspace still builds (render compiles against the public API) =="
cargo build --workspace

echo "== all green =="
