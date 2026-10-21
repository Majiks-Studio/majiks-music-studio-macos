#!/bin/bash
# 5-minute realtime stress probe (manual stress tool; NOT part of the default
# ci-check.sh run).
#
# Wraps the P0-B probe: the engine-proof binary's `probe` subcommand
# (engine/render/src/bin/engine_proof.rs, engine/render/src/probe.rs). There
# are no #[ignore] tests in the engine; the probe is a binary subcommand.
# It opens a LIVE, silence-gated cpal output stream and hammers the control
# surface from a non-audio thread (methodology: docs/evidence/p0b-engine-proof.md).
#
# Requires a release build: realtime numbers are meaningless in debug.
# Override for a quick wiring smoke test only:
#   PROBE_SECONDS=2 PROBE_PROFILE=debug scripts/probe-5min.sh
#
# Output tees to docs/evidence/probe-5min_<timestamp>.log and the JSON report
# lands next to it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE_DIR="$PROJECT_ROOT/engine"
EVIDENCE_DIR="$PROJECT_ROOT/docs/evidence"

PROBE_SECONDS="${PROBE_SECONDS:-300}"
PROBE_PROFILE="${PROBE_PROFILE:-release}"

mkdir -p "$EVIDENCE_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$EVIDENCE_DIR/probe-5min_${TIMESTAMP}.log"
JSON_FILE="$EVIDENCE_DIR/probe-5min_${TIMESTAMP}.json"

echo "Probe runner: realtime stress probe, ${PROBE_SECONDS}s, profile=${PROBE_PROFILE}"
echo "Log:  $LOG_FILE"
echo "JSON: $JSON_FILE"
df -h / | tail -1
echo ""

cd "$ENGINE_DIR"

if [[ "$PROBE_PROFILE" == "release" ]]; then
    cargo build --release -p render --bin engine-proof
    BIN="target/release/engine-proof"
else
    cargo build -p render --bin engine-proof
    BIN="target/debug/engine-proof"
fi

"$BIN" probe --seconds "$PROBE_SECONDS" --json "$JSON_FILE" 2>&1 | tee "$LOG_FILE"

echo ""
echo "Probe run complete. Log: $LOG_FILE"
