#!/usr/bin/env bash
# stem-aiken.sh — verify every separated stem on disk is usable ALONE.
#
# Runs `majiks-studio-cli check-stems` over the default Application Support
# path AND the custom library path (UserDefaults key `majik_custom_library_path`,
# passed as an env var or discovered via `defaults read`).
#
# Any fixture-era stem (a test‑double file that was never re‑separated) fails
# this gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENGINE_DIR="$REPO_ROOT/engine"
MANIFEST="$ENGINE_DIR/Cargo.toml"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-"$ENGINE_DIR/target"}"

echo "==> building majiks-studio-cli (check-stems subcommand)"
cargo build --manifest-path "$MANIFEST" -p agent-surface --bin majiks-studio-cli 2>&1
CLI="$CARGO_TARGET_DIR/debug/majiks-studio-cli"

SCAN_DIRS=()

# 1. Default Application Support path.
DEFAULT_DIR="$HOME/Library/Application Support/MajiksMusicStudio"
if [[ -d "$DEFAULT_DIR" ]]; then
    SCAN_DIRS+=("$DEFAULT_DIR")
fi

# 2. Custom library path from UserDefaults (bundle ID varies by build config).
if command -v defaults &>/dev/null; then
    for bundle in "com.majiks.MajiksMusicStudio" "com.apple.whatever"; do
        CUSTOM=$(defaults read "$bundle" majik_custom_library_path 2>/dev/null || true)
        if [[ -n "$CUSTOM" && -d "$CUSTOM" ]]; then
            SCAN_DIRS+=("$CUSTOM")
            break
        fi
    done
fi

if [[ ${#SCAN_DIRS[@]} -eq 0 ]]; then
    echo "==> no stem directories found to scan — nothing to check"
    exit 0
fi

echo "==> scanning ${SCAN_DIRS[*]}"
"$CLI" check-stems "${SCAN_DIRS[@]}"
