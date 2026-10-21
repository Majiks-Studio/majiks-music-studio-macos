#!/bin/bash
# CI Check Harness for Majik's Music Studio DAW (Phase 1, Lane L7)
#
# TODO(coordinator): flip fmt + clippy to strict (make their ALLOW_FAIL
# defaults 0) at integration checkpoint I1. Until then both default to
# ALLOW_FAIL=1 because main cbfec4c carries pre-existing rustfmt diffs and a
# clippy derivable_impls lint (details: docs/evidence/l7-ci-harness.md).
#
# Coordinator decisions (2026-07-11) encoded in the defaults below:
#   1. fmt + clippy: ALLOW_FAIL by default until I1, then strict.
#   2. swift build: runs by default (SwiftPM may fetch deps over the network).
#   3. probe runners / ignored tests: stress-only. The step is SKIPPED by
#      default; run scripts/probe-5min.sh or scripts/probe-30min.sh manually,
#      or set SKIP_PROBE_RUNNERS=0 to include a probe here.
#
# Step names: fmt, clippy, cargo_test, wasm_check, license_check,
#             pytest_contracts, pytest_repaint, conformance_rust,
#             swift_build, probe_runners
#
# Flags (per step NAME, uppercased):
#   SKIP_<NAME>=1        skip the step entirely; the skip decision happens
#                        BEFORE any cargo/swift/python invocation.
#                        probe_runners defaults to skip (SKIP_PROBE_RUNNERS=0
#                        opts in); everything else defaults to run.
#   ALLOW_FAIL_<NAME>=1  run the step but do not fail the script when it
#                        errors; the failure is still printed loudly.
#                        fmt and clippy default to 1 until I1 (see TODO).
#
# Exit code: 0 when no un-gated step failed, 1 otherwise.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENGINE_DIR="$PROJECT_ROOT/engine"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

TOTAL_STEPS=0
PASSED_STEPS=0
GATED_STEPS=0
FAILED_STEPS=0
SKIPPED_STEPS=0
FAILED_STEP_NAMES=""
RESULTS=()

# run_step <name> <function...>
# Skip/allow-fail defaults are per-step (see header). The skip check happens
# before the step function is called, so a skipped step never invokes cargo,
# swift, or python at all.
run_step() {
    local step_name="$1"
    shift
    local step_upper
    step_upper=$(echo "$step_name" | tr '[:lower:]' '[:upper:]')
    local skip_var="SKIP_${step_upper}"
    local allow_var="ALLOW_FAIL_${step_upper}"

    local skip_default=0
    local allow_default=0
    local skip_reason=""
    local gate_reason=""
    case "$step_name" in
        probe_runners)
            skip_default=1
            skip_reason="stress-only tool; run scripts/probe-5min.sh or scripts/probe-30min.sh manually, or set SKIP_PROBE_RUNNERS=0 to include it"
            ;;
        fmt)
            allow_default=1
            gate_reason="PREEXISTING(main cbfec4c): rustfmt diffs in P0-B engine code; coordinator flips strict at I1"
            ;;
        clippy)
            allow_default=1
            gate_reason="PREEXISTING(main cbfec4c): clippy::derivable_impls at timeline-core/src/model.rs:23; coordinator flips strict at I1"
            ;;
    esac

    local skip_val="${!skip_var:-$skip_default}"
    ((TOTAL_STEPS++))
    if [[ "$skip_val" == "1" ]]; then
        local why="$skip_reason"
        if [[ -z "$why" ]]; then
            why="skipped via ${skip_var}=1"
        fi
        echo -e "${YELLOW}SKIP${NC}  $step_name ($why)"
        ((SKIPPED_STEPS++))
        RESULTS+=("SKIP|$step_name|-|$why")
        return 0
    fi

    echo ""
    echo "Running: $step_name"
    echo "---"

    local started ended dur rc
    started=$(date +%s)
    "$@"
    rc=$?
    ended=$(date +%s)
    dur=$((ended - started))

    if [[ $rc -eq 0 ]]; then
        echo -e "${GREEN}PASS${NC}  $step_name (${dur}s)"
        ((PASSED_STEPS++))
        RESULTS+=("PASS|$step_name|${dur}s|ok")
    else
        local allow_val="${!allow_var:-$allow_default}"
        if [[ "$allow_val" == "1" ]]; then
            local why="$gate_reason"
            if [[ -z "$why" ]]; then
                why="gated via ${allow_var}=1"
            fi
            echo -e "${YELLOW}FAIL(gated)${NC}  $step_name (exit $rc, ${dur}s)"
            echo -e "${YELLOW}  ^ $why${NC}"
            ((GATED_STEPS++))
            RESULTS+=("FAIL-gated|$step_name|${dur}s|$why")
        else
            echo -e "${RED}FAIL${NC}  $step_name (exit $rc, ${dur}s)"
            ((FAILED_STEPS++))
            FAILED_STEP_NAMES="$FAILED_STEP_NAMES $step_name"
            RESULTS+=("FAIL|$step_name|${dur}s|exit $rc")
        fi
    fi
}

check_disk_space() {
    df -h /
    local available available_gb
    # -k pins 1024-byte blocks (macOS df defaults to 512-byte blocks)
    available=$(df -k / | tail -1 | awk '{print $4}')
    available_gb=$((available / 1024 / 1024))
    echo "System disk available: ${available_gb} GB"
    if [[ $available_gb -lt 4 ]]; then
        echo "WARNING: less than 4 GB free on the system disk."
        echo "Repo build artifacts (target/, .build/) land on this repo's volume,"
        echo "but toolchain caches use the system disk. Set CI_IGNORE_DISK=1 to proceed."
        if [[ "${CI_IGNORE_DISK:-0}" != "1" ]]; then
            return 1
        fi
    fi
    return 0
}

# Step 1: rustfmt check (engine workspace)
step_fmt() {
    cd "$ENGINE_DIR" && cargo fmt --check
}

# Step 2: clippy, warnings denied (engine workspace)
step_clippy() {
    cd "$ENGINE_DIR" && cargo clippy -- -D warnings
}

# Step 3: cargo test (engine workspace)
step_cargo_test() {
    cd "$ENGINE_DIR" && cargo test
}

# Step 4: timeline-core must stay wasm32-compilable
step_wasm_check() {
    cd "$ENGINE_DIR" || return 1
    rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
    cargo check --target wasm32-unknown-unknown -p timeline-core
}

# Step 5: license manifest check (engine workspace + conformance crate)
# Proper SPDX expression evaluation:
#   - OR: the crate passes if ANY branch is allowed
#   - AND: every part must be allowed
#   - WITH: "X WITH exception" is treated as X
#   - legacy slash syntax "MIT/Apache-2.0" is treated as OR
#   - parenthesized sub-expressions are supported
# Verdicts: PASS (expression satisfiable from the allowlist), REVIEW (odd but
# not copyleft; non-fatal warning), DENY (GPL/AGPL/LGPL-only or unknown on a
# registry crate; fails the step). Local path crates (our own code) are
# reported but never DENY on a missing license field.
step_license_check() {
    cd "$ENGINE_DIR" || return 1
    python3 - "$ENGINE_DIR" "$ENGINE_DIR/contracts/conformance" << 'PYTHON_EOF'
import json
import re
import subprocess
import sys

ALLOWED = {
    'MIT', 'MIT-0', 'APACHE-2.0',
    'BSD-1-CLAUSE', 'BSD-2-CLAUSE', 'BSD-3-CLAUSE', '0BSD',
    'MPL-2.0', 'ZLIB', 'ISC', 'UNLICENSE', 'CC0-1.0',
    'UNICODE-3.0', 'UNICODE-DFS-2016',
}
COPYLEFT = re.compile(r'\b(AGPL|LGPL|GPL)[A-Z0-9.\-]*\b', re.IGNORECASE)


def tokenize(expr):
    expr = expr.replace('/', ' OR ')
    expr = expr.replace('(', ' ( ').replace(')', ' ) ')
    return expr.split()


class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.pos = 0

    def peek(self):
        return self.tokens[self.pos] if self.pos < len(self.tokens) else None

    def next(self):
        tok = self.peek()
        self.pos += 1
        return tok

    def parse_or(self):
        ok = self.parse_and()
        while self.peek() and self.peek().upper() == 'OR':
            self.next()
            rhs = self.parse_and()
            ok = ok or rhs
        return ok

    def parse_and(self):
        ok = self.parse_atom()
        while self.peek() and self.peek().upper() == 'AND':
            self.next()
            rhs = self.parse_atom()
            ok = ok and rhs
        return ok

    def parse_atom(self):
        tok = self.next()
        if tok is None:
            return False
        if tok == '(':
            ok = self.parse_or()
            if self.peek() == ')':
                self.next()
            return ok
        lic = tok
        if self.peek() and self.peek().upper() == 'WITH':
            self.next()          # WITH
            self.next()          # the exception id; "X WITH e" evaluates as X
        return lic.upper() in ALLOWED


def expr_allowed(expr):
    try:
        return Parser(tokenize(expr)).parse_or()
    except Exception:
        return False


def collect(tree_dir):
    result = subprocess.run(
        ['cargo', 'metadata', '--format-version', '1'],
        stdout=subprocess.PIPE, text=True, check=True, cwd=tree_dir)
    return json.loads(result.stdout)['packages']


packages = {}
for tree in sys.argv[1:]:
    for pkg in collect(tree):
        key = (pkg['name'], pkg['version'])
        packages[key] = pkg

deny = []
review = []
local_notes = []
accepted_exprs = {}

for (name, version), pkg in sorted(packages.items()):
    lic = pkg.get('license')
    is_local = pkg.get('source') is None
    if not lic:
        if is_local:
            local_notes.append(f"{name} {version}: local crate, no license field (repo-internal, publish=false)")
        else:
            deny.append(f"{name} {version}: UNKNOWN (no license field on a registry crate)")
        continue
    lic = lic.strip()
    if expr_allowed(lic):
        accepted_exprs.setdefault(lic, []).append(name)
    elif COPYLEFT.search(lic):
        deny.append(f"{name} {version}: {lic}")
    else:
        review.append(f"{name} {version}: {lic}")

print("License check (engine workspace + contracts/conformance crate)")
print("=" * 64)
print(f"Crates examined: {len(packages)}")
print(f"Accepted license expressions ({len(accepted_exprs)} unique):")
for expr in sorted(accepted_exprs):
    print(f"  PASS  {expr}  [{len(accepted_exprs[expr])} crates]")
for note in local_notes:
    print(f"  note  {note}")
if review:
    print("REVIEW (not copyleft, not on the allowlist; flag for a human):")
    for item in review:
        print(f"  REVIEW  {item}")
if deny:
    print("DENIED (GPL/AGPL/LGPL-only or unknown; fails this step):")
    for item in deny:
        print(f"  DENY  {item}")

print()
print("Model weights (04-RESEARCH-NOTES.md section B): ACE-Step 1.5 = MIT; htdemucs_ft = MIT")

sys.exit(1 if deny else 0)
PYTHON_EOF
}

# Step 6: contracts conformance, Python side
step_pytest_contracts() {
    cd "$ENGINE_DIR/contracts" && python3 -m pytest conformance_py/ -q
}

# Step 7: repaint harness tests
step_pytest_repaint() {
    cd "$PROJECT_ROOT" && python3 -m pytest tools/repaint_harness/ -q
}

# Step 8: contracts conformance, Rust side (standalone crate, NOT an engine
# workspace member; it has its own empty [workspace] table)
step_conformance_rust() {
    cd "$ENGINE_DIR/contracts/conformance" && cargo test
}

# Step 9: swift build (src/swift, macOS app shell). Runs by default; SwiftPM
# may fetch dependencies over the network on the first build.
step_swift_build() {
    local sw_dir="$PROJECT_ROOT/src/swift"
    if [[ ! -d "$sw_dir" ]]; then
        echo "src/swift not found at $sw_dir"
        return 1
    fi
    if ! command -v swift >/dev/null 2>&1; then
        echo "swift toolchain not found on PATH"
        return 1
    fi
    cd "$sw_dir" || return 1
    local log rc
    log=$(mktemp -t swift-build-ci)
    swift build >"$log" 2>&1
    rc=$?
    tail -n 30 "$log"
    if [[ $rc -ne 0 ]]; then
        echo "swift build FAILED (exit $rc); full log kept at: $log"
    else
        rm -f "$log"
    fi
    return $rc
}

# Step 10: realtime stress probe. SKIPPED BY DEFAULT (see header); reached
# only when SKIP_PROBE_RUNNERS=0 is set explicitly. Runs the 5-minute probe
# via scripts/probe-5min.sh (PROBE_SECONDS overrides the duration).
step_probe_runners() {
    "$SCRIPT_DIR/probe-5min.sh"
}

echo "Majik's Music Studio DAW - CI Check Harness"
echo "==========================================="
echo "Project: $PROJECT_ROOT"
echo "Engine:  $ENGINE_DIR"
echo ""

check_disk_space || exit 1

echo ""
echo "Starting CI checks..."

run_step "fmt"              step_fmt
run_step "clippy"           step_clippy
run_step "cargo_test"       step_cargo_test
run_step "wasm_check"       step_wasm_check
run_step "license_check"    step_license_check
run_step "pytest_contracts" step_pytest_contracts
run_step "pytest_repaint"   step_pytest_repaint
run_step "conformance_rust" step_conformance_rust
run_step "swift_build"      step_swift_build
run_step "probe_runners"    step_probe_runners

echo ""
echo "==========================================="
echo "CI CHECK SUMMARY"
echo "==========================================="
for line in "${RESULTS[@]}"; do
    IFS='|' read -r status name dur why <<< "$line"
    printf "%-11s %-18s %-6s %s\n" "$status" "$name" "$dur" "$why"
done
echo "-------------------------------------------"
echo "Total: $TOTAL_STEPS | Passed: $PASSED_STEPS | Gated failures: $GATED_STEPS | Failed: $FAILED_STEPS | Skipped: $SKIPPED_STEPS"

if [[ $FAILED_STEPS -gt 0 ]]; then
    echo ""
    echo -e "${RED}FAILED STEPS:${NC}$FAILED_STEP_NAMES"
    exit 1
fi
if [[ $GATED_STEPS -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}Gated failures present (pre-existing on main cbfec4c; strict at I1).${NC}"
fi
echo -e "${GREEN}CI CHECK OK${NC}"
exit 0
