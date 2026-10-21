#!/usr/bin/env bash
# check-engine-lock.sh — guard the concurrency fix in build-engine.sh.
#
# build-engine.sh was shipping two runs' static libraries into one xcframework
# when run in parallel across two worktrees sharing CARGO_TARGET_DIR.  The fix
# added an atomic mkdir‑based lock, a stale‑pid reclaimer, a timeout, a
# per‑run staging directory, and a cleanup trap.  Removing any of these
# reopens an intermittent corruption that no gate can see.
#
# This guard greps for the lock mechanism — it does NOT parse the script.
# A structural refactor that renames the functions must update this guard.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build-engine.sh"

missing=0

check() {
    local label="$1" expected="$2"
    if grep -Fq "$expected" "$BUILD_SCRIPT" 2>/dev/null; then
        echo "  ✓ $label"
    else
        echo "  ✗ $label — expected pattern not found: $expected"
        missing=$((missing + 1))
    fi
}

echo "==> verifying concurrency guards in build-engine.sh"

check "atomic lock directory (mkdir)"      'mkdir "$LOCK_DIR"'
check "lock owner file"                    'echo "$SWIFT_DIR" > "$LOCK_DIR/owner"'
check "lock pid file"                      'echo "$$" > "$LOCK_DIR/pid"'
check "stale-pid reclaimer"                'kill -0 "$pid"'
check "lock timeout"                       'LOCK_TIMEOUT='
check "per-run staging (mktemp)"           'mktemp -d "$TARGET_DIR/xcframework-staging.XXXXXXXX"'
check "cleanup trap"                       'trap cleanup EXIT'
check "release_lock in cleanup"            'release_lock'
check "LOCK_HELD flag"                     'LOCK_HELD=0'
check "release_lock function"              'release_lock()'
check "acquire_lock function"              'acquire_lock()'

if (( missing > 0 )); then
    echo ""
    echo "FAIL: $missing concurrency guard(s) are missing from build-engine.sh."
    echo "     The lock + staging + trap mechanism is required to prevent"
    echo "     two parallel builds from corrupting each other's xcframework."
    echo "     See build-engine.sh lines 39-126 for the full pattern."
    exit 1
fi

echo "  all 11 concurrency guards present."
