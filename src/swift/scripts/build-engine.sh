#!/usr/bin/env bash
# build-engine.sh - build the Majik's Music Studio agent-surface Rust crate as a
# static library, generate UniFFI Swift bindings, and assemble the
# MajiksEngine.xcframework the SwiftUI app links.
#
# Mirrors majiks-dj/macos/scripts/build-core.sh. Output layout:
#   src/swift/Sources/Engine/Generated/majiks_engine.swift   (committed bindings)
#   src/swift/MajiksEngine.xcframework                        (build product, gitignored)
#
# The crate exposes the FFI object (feature `ffi`) plus the in-process MCP
# server (feature `mcp`); both ship in the app, so we build `--features ffi,mcp`.
# Every path is quoted: the canonical repo lives under a path with spaces.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENGINE_DIR="$REPO_ROOT/engine"
MANIFEST="$ENGINE_DIR/Cargo.toml"
SWIFT_DIR="$REPO_ROOT/src/swift"
GEN_DIR="$SWIFT_DIR/Sources/Engine/Generated"
XCFRAMEWORK="$SWIFT_DIR/MajiksEngine.xcframework"
TARGET_DIR="$(cargo metadata --manifest-path "$MANIFEST" --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"

LIB_BASENAME="libagent_surface"
FEATURES="ffi,mcp"
ARM_TARGET="aarch64-apple-darwin"
X86_TARGET="x86_64-apple-darwin"

# Pin the Rust slices to the app's macOS floor (Package.swift is .macOS(.v14)).
# Without this the slices build for the host SDK and the linker warns that the
# staticlib was built for a newer macOS than the app targets; pinning also stops
# any dependency from binding an API newer than the app supports. Override by
# exporting MACOSX_DEPLOYMENT_TARGET before invoking this script.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

echo "==> repo root  : $REPO_ROOT"
echo "==> features   : $FEATURES"

# ---------------------------------------------------------------------------
# 0. ONE RUN AT A TIME PER TARGET DIRECTORY, AND A STAGING DIRECTORY OF OUR OWN.
#
# This script used to `rm -rf` a FIXED staging path, "$TARGET_DIR/xcframework-
# staging", at the top of the assembly step. Two runs sharing a
# CARGO_TARGET_DIR therefore deleted each other's headers mid-assembly. That
# cost a lane a full re-run and is a plausible cause of other "transient"
# parallel-lane failures. Same family as the fixed
# $TMPDIR/l13-encode-test/tone.m4a in engine/render/src/encode.rs, whose
# collision across ~30 worktrees surfaced as "m4a suspiciously small: 28 bytes"
# — a red gate that looked like an encoder bug.
#
# The per-run staging directory below is necessary but NOT sufficient, and this
# is the part a staging fix alone would miss: two runs sharing a
# CARGO_TARGET_DIR also share "$TARGET_DIR/$ARM_TARGET/release/$LIB_BASENAME.a".
# Cargo's own lock stops them WRITING it at the same moment; nothing stops run A
# from lipo-ing and packaging the library run B has just rebuilt from different
# sources. That is the outcome to fear — an xcframework that exits 0, is
# well-formed, and contains somebody else's engine. No gate can see it.
#
# So the second run WAITS, out loud, and if it gives up it says so and builds
# nothing. A silent partial is the one result this must never produce.
#
# ⚠️ The lock is keyed on $TARGET_DIR because that is what the corruption is
# keyed on. Two runs of the SAME worktree under two DIFFERENT CARGO_TARGET_DIRs
# would not serialise, and would still race on $XCFRAMEWORK and $GEN_DIR. That
# is not a configuration anything here uses — each lane exports exactly one
# target dir — and it is recorded rather than guarded so the key is a choice
# somebody made and not one they can mistake for total coverage.
mkdir -p "$TARGET_DIR"
LOCK_DIR="$TARGET_DIR/build-engine.lock"
LOCK_TIMEOUT="${MAJIKS_ENGINE_LOCK_TIMEOUT:-1800}"
LOCK_HELD=0

release_lock() {
    if [[ "$LOCK_HELD" == "1" ]]; then
        LOCK_HELD=0
        rm -rf "$LOCK_DIR"
    fi
}

cleanup() {
    # Never leave a staging directory behind: the old fixed path accumulated
    # exactly one and nothing ever removed it, which is how "is that dir mine?"
    # stopped being answerable.
    if [[ -n "${STAGING:-}" ]]; then rm -rf "$STAGING"; fi
    release_lock
}

acquire_lock() {
    local waited=0 holder pid
    # `mkdir` is atomic on every filesystem this repo builds on. macOS ships no
    # flock(1), and a "test, then create" lock is not a lock at all.
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        holder="$(cat "$LOCK_DIR/owner" 2>/dev/null || echo "an unknown worktree")"
        pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
        # A killed run leaves its lock behind. Reclaiming it is right, but SAY
        # so — a lock that silently disappears is this same class of bug in a
        # different hat.
        if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
            echo "==> stale lock from dead pid $pid ($holder); reclaiming it" >&2
            rm -rf "$LOCK_DIR"
            continue
        fi
        if (( waited == 0 )); then
            echo "==> another build-engine.sh already owns $TARGET_DIR"
            echo "    (pid ${pid:-unknown}, $holder). Waiting up to ${LOCK_TIMEOUT}s:"
            echo "    running both at once would package each other's static library."
        elif (( waited % 30 == 0 )); then
            echo "    still waiting for pid ${pid:-unknown} (${waited}s of ${LOCK_TIMEOUT}s)..."
        fi
        if (( waited >= LOCK_TIMEOUT )); then
            echo "ERROR: gave up after ${LOCK_TIMEOUT}s waiting for $LOCK_DIR" >&2
            echo "       (held by pid ${pid:-unknown}, $holder). NOTHING WAS BUILT — the" >&2
            echo "       xcframework and the Swift bindings are exactly as you found them." >&2
            echo "       If that pid is gone, delete the directory by hand." >&2
            exit 1
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done
    LOCK_HELD=1
    echo "$$" > "$LOCK_DIR/pid"
    echo "$SWIFT_DIR" > "$LOCK_DIR/owner"
}

trap cleanup EXIT
acquire_lock

# Per RUN, not per target directory: even with the lock above, a fixed shared
# path is a footgun waiting for the next person who bypasses it. `mktemp -d`
# under $TARGET_DIR keeps the lipo output on the same filesystem as the slices.
STAGING="$(mktemp -d "$TARGET_DIR/xcframework-staging.XXXXXXXX")"

# ---------------------------------------------------------------------------
# 1. Build the Rust core (staticlib for the framework + cdylib for bindgen
#    metadata) for Apple Silicon; the x86_64 slice is optional.
# ---------------------------------------------------------------------------
echo "==> building agent-surface (release, $ARM_TARGET)"
cargo build --manifest-path "$MANIFEST" -p agent-surface --no-default-features \
    --features "$FEATURES" --lib --release --target "$ARM_TARGET"

ARM_A="$TARGET_DIR/$ARM_TARGET/release/$LIB_BASENAME.a"
ARM_DYLIB="$TARGET_DIR/$ARM_TARGET/release/$LIB_BASENAME.dylib"
[[ -f "$ARM_A" ]] || { echo "ERROR: $ARM_A not found" >&2; exit 1; }

X86_A=""
if [[ "${MAJIKS_ENGINE_ARM64_ONLY:-0}" == "1" ]]; then
    echo "==> MAJIKS_ENGINE_ARM64_ONLY=1: skipping the Intel slice (local arm64 build)"
elif rustup target list --installed | grep -qx "$X86_TARGET"; then
    echo "==> building agent-surface (release, $X86_TARGET)"
    cargo build --manifest-path "$MANIFEST" -p agent-surface --no-default-features \
        --features "$FEATURES" --lib --release --target "$X86_TARGET"
    X86_A="$TARGET_DIR/$X86_TARGET/release/$LIB_BASENAME.a"
else
    echo "==> $X86_TARGET not installed; building arm64-only xcframework" \
         "(rustup target add $X86_TARGET to add the Intel slice)"
fi

# ---------------------------------------------------------------------------
# 2. Generate Swift bindings with uniffi-bindgen (library mode, reading UniFFI
#    metadata from the built dylib). The bindgen bin is feature-gated so
#    default builds keep exactly ONE bin (the CLI).
# ---------------------------------------------------------------------------
echo "==> generating Swift bindings into $GEN_DIR"
mkdir -p "$GEN_DIR"
( cd "$ENGINE_DIR" && cargo run --manifest-path "$MANIFEST" -p agent-surface \
    --no-default-features --features "ffi-bindgen,mcp" --bin uniffi-bindgen -- \
    generate --library "$ARM_DYLIB" --language swift --out-dir "$GEN_DIR" )

SWIFT_FILE="$GEN_DIR/majiks_engine.swift"
HEADER_FILE="$GEN_DIR/majiks_engineFFI.h"
MODULEMAP_FILE="$GEN_DIR/majiks_engineFFI.modulemap"
for f in "$SWIFT_FILE" "$HEADER_FILE" "$MODULEMAP_FILE"; do
    [[ -f "$f" ]] || { echo "ERROR: expected bindgen output missing: $f" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# 3. Assemble the xcframework: (fat) staticlib + FFI header + module map.
# ---------------------------------------------------------------------------
echo "==> assembling $XCFRAMEWORK"
# $STAGING is this run's own, freshly made and empty; only $XCFRAMEWORK — the
# output xcodebuild refuses to overwrite — has to be cleared.
rm -rf "$XCFRAMEWORK"
mkdir -p "$STAGING/headers"
cp "$HEADER_FILE" "$STAGING/headers/"
# xcodebuild expects the clang standard name for the module map.
cp "$MODULEMAP_FILE" "$STAGING/headers/module.modulemap"

LIB_FOR_FRAMEWORK="$ARM_A"
if [[ -n "$X86_A" && -f "$X86_A" ]]; then
    echo "==> lipo: universal staticlib (arm64 + x86_64)"
    LIB_FOR_FRAMEWORK="$STAGING/$LIB_BASENAME.a"
    lipo -create "$ARM_A" "$X86_A" -output "$LIB_FOR_FRAMEWORK"
fi

xcodebuild -create-xcframework \
    -library "$LIB_FOR_FRAMEWORK" \
    -headers "$STAGING/headers" \
    -output "$XCFRAMEWORK"

echo "==> done"
echo "    swift bindings : $SWIFT_FILE"
echo "    xcframework    : $XCFRAMEWORK"
lipo -info "$LIB_FOR_FRAMEWORK" | sed 's/^/    /'
