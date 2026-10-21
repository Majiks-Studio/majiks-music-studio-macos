#!/bin/bash
# 30-minute realtime stress probe (manual stress tool; NOT part of the default
# ci-check.sh run). Same probe as probe-5min.sh with a 1800 s duration; the
# duration is passed to engine-proof itself (probe.rs clamps to 30 min), so no
# external timeout command is needed (macOS has none by default).
#
# Long run guidance (from P0-B): for a detached run use
#   nohup scripts/probe-30min.sh > /dev/null 2>&1 &
# and watch docs/evidence/probe-30min_<timestamp>.log.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE_DIR="$PROJECT_ROOT/engine"
EVIDENCE_DIR="$PROJECT_ROOT/docs/evidence"

PROBE_SECONDS="${PROBE_SECONDS:-1800}"

mkdir -p "$EVIDENCE_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$EVIDENCE_DIR/probe-30min_${TIMESTAMP}.log"
JSON_FILE="$EVIDENCE_DIR/probe-30min_${TIMESTAMP}.json"

echo "Probe runner: realtime stress probe, ${PROBE_SECONDS}s, profile=release"
echo "Log:  $LOG_FILE"
echo "JSON: $JSON_FILE"
echo "Start: $(date)"
df -h / | tail -1
echo ""

cd "$ENGINE_DIR"
cargo build --release -p render --bin engine-proof

target/release/engine-proof probe --seconds "$PROBE_SECONDS" --json "$JSON_FILE" 2>&1 | tee "$LOG_FILE"

echo ""
echo "Probe run complete. Log: $LOG_FILE"
echo "End: $(date)"
