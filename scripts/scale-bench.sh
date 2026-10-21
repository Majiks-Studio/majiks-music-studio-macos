#!/bin/bash
# Large-session scale harness. Silent: offline render only, no CoreAudio device.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/docs/evidence/scale-bench.json}"
if [[ "$OUT" != /* ]]; then OUT="$ROOT/$OUT"; fi
mkdir -p "$(dirname "$OUT")"
cd "$ROOT/engine"
cargo run --release -p render --bin engine-proof -- \
  scale-bench --tracks "${SCALE_TRACKS:-32}" \
  --clips-per-track "${SCALE_CLIPS_PER_TRACK:-48}" --json "$OUT"
echo "scale report: $OUT"
