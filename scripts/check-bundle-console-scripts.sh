#!/bin/bash
#
# check-bundle-console-scripts.sh <site-packages-dir>
#
# FAILS THE BUILD if a console script under site-packages/bin imports a module
# that is not in the bundle. Such a script is dead on every machine, including
# the one that built it — it is not a portability problem, which is why
# check-bundle-portability.sh (whose whole subject is "needs something only the
# build machine has") is the wrong home for it.
#
# The defect it was written for: build-release.sh pins two packages by deleting
# the package directory and its dist-info and reinstalling the wanted version
# with `pip install --target ... --no-deps`. That reinstall writes NO console
# scripts, so the ones the earlier unpinned install wrote survive — still
# importing the newer release's module layout. The 3.5.0 bundle shipped two:
#
#   bin/huggingface-cli -> huggingface_hub.cli.deprecated_cli  (from hub 1.x;
#                          hub 0.36.2 names huggingface_hub.commands.huggingface_cli)
#   bin/transformers    -> transformers.cli.transformers       (from transformers 5.x;
#                          4.57.6 names transformers.commands.transformers_cli)
#
# Both die with ModuleNotFoundError. Neither was caught by anything, because a
# broken executable nobody runs produces no signal at all.
#
# ⚠️ THIS ASSERTS THE ARTIFACT, NOT AN EXIT CODE, and it refuses to pass on a
# scan too small to mean anything — same rule as the Mach-O floor in
# check-bundle-portability.sh and the .pyc floor in build-release.sh. "Every
# script is fine" and "there were no scripts" are otherwise the same green line.
#
# Exit 0 = every console script resolves, over a plausible number of scripts.
# Exit 1 = at least one dead import, or the scan was too small to be trusted.

set -uo pipefail

SP="${1:?usage: check-bundle-console-scripts.sh <site-packages-dir>}"
[ -d "$SP" ] || { echo "GATE FAIL: not a directory: $SP" >&2; exit 1; }

# The real bundle carries 43 console scripts after the removals above. The floor
# is far below that and far above zero; the override exists so this can be
# exercised against a small fixture, and build-release.sh never sets it.
MIN_SCRIPTS="${MIN_CONSOLE_SCRIPTS:-20}"

python3 - "$SP" "$MIN_SCRIPTS" <<'PYEOF'
import os
import re
import sys

sp, floor = sys.argv[1], int(sys.argv[2])
bindir = os.path.join(sp, "bin")
if not os.path.isdir(bindir):
    print("GATE FAIL: no %s" % bindir, file=sys.stderr)
    sys.exit(1)

# The pip console-script template is `from <module> import <name>`. numba ships
# a hand-written script with a `from __future__` line first, so EVERY import in
# the file is checked and stdlib names are skipped rather than only reading the
# first match — reading only the first would have judged numba on __future__.
IMPORT = re.compile(r"^\s*from ([A-Za-z_][\w.]*) import ", re.M)
STDLIB = set(sys.stdlib_module_names)

def resolves(sp, module):
    parts = module.split(".")
    if parts[0] in STDLIB:
        return True
    base = os.path.join(sp, *parts)
    if os.path.isdir(base) or os.path.isfile(base + ".py"):
        return True
    # An extension module: numpy/core/_multiarray_umath.cpython-312-darwin.so
    parent, leaf = os.path.dirname(base), os.path.basename(base)
    try:
        siblings = os.listdir(parent)
    except OSError:
        return False
    return any(s == leaf + ".so" or (s.startswith(leaf + ".") and s.endswith(".so"))
               for s in siblings)

scanned, dead = 0, []
for name in sorted(os.listdir(bindir)):
    path = os.path.join(bindir, name)
    if not os.path.isfile(path):
        continue
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError):
        continue                      # a compiled launcher, not a python script
    hits = IMPORT.findall(text)
    if not hits:
        continue
    scanned += 1
    for module in hits:
        if not resolves(sp, module):
            dead.append((name, module))

if dead:
    print("", file=sys.stderr)
    print("GATE FAIL: %d console script(s) import a module that is not in the bundle."
          % len(dead), file=sys.stderr)
    for name, module in dead:
        print("           bin/%-24s -> %s" % (name, module), file=sys.stderr)
    print("", file=sys.stderr)
    print("           Almost certainly a PIN left the old release's script behind:", file=sys.stderr)
    print("           `pip install --target --no-deps` writes no console scripts, so", file=sys.stderr)
    print("           removing the package directory is not enough. Remove the stale", file=sys.stderr)
    print("           script in build-release.sh's pin block, next to the others.", file=sys.stderr)
    sys.exit(1)

if scanned < floor:
    print("GATE FAIL: only %d console script(s) scanned (floor %d)." % (scanned, floor),
          file=sys.stderr)
    print("           A clean result from a scan this small proves nothing.", file=sys.stderr)
    sys.exit(1)

print("  Console-script gate: %d scripts, every import resolves inside the bundle." % scanned)
PYEOF
