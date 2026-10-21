#!/bin/bash
#
# check-bundle-portability.sh <path-to-.app>
#
# FAILS THE BUILD if the finished bundle still needs something that only exists
# on the machine that built it. This is the deliverable that lasts: the
# relocation is a one-time fix, this is what stops it coming back.
#
# The defect it was written for: the notarized 3.5.0 bundle's own interpreter
# carried
#   LC_LOAD_DYLIB /opt/homebrew/Cellar/python@3.12/3.12.13_1/.../Python
# so on a customer's Mac — no Homebrew — the bundled Python could not load at
# all, and the entire Python backend (generation, stem separation) was dead.
# Every gate in the repo was green. build-release.sh even PRINTED the warning
# that it had invalidated that binary's signature, and nothing read it.
#
# ⚠️ THIS ASSERTS THE ARTIFACT, NOT AN EXIT CODE. It refuses to pass when it
# scanned implausibly few binaries, because "found no problems" and "looked at
# nothing" are the same green line otherwise. Same shape as the .pyc count at
# the bytecode-bake step.
#
# What it checks, and why each one is separate:
#   1. Mach-O load commands, dylib ids and rpaths — no absolute path outside
#      the bundle other than /usr/lib and /System.
#   2. The string table of Contents/MacOS/* — a spawn path like
#      /opt/homebrew/bin/python3 is a STRING, not a load command, so check 1
#      cannot see it. Scoped to our own executables so third-party wheels'
#      build-path debris does not drown the signal. NOTE: the compiler emits a
#      literal even when its branch is unreachable, so keeping such a path out
#      of the artifact needs #if DEBUG, not merely a runtime `if`.
#   3. Console-script shebangs under site-packages/bin — `pip install --target`
#      writes the BUILD machine's interpreter into ~45 of them.
#   4. Every relative reference must actually RESOLVE to a file in the bundle.
#      Checks 1-3 would pass "@loader_path/../Python" pointing at nothing.
#   5. The CA bundle shipped for the bundled OpenSSL, and sitecustomize pointing
#      SSL_CERT_FILE at it. libcrypto's default is /opt/homebrew/etc/openssl@3/
#      cert.pem. That is a compiled-in string, not a load command, so checks
#      1-4 cannot see it. urllib uses it, and the file is not on a customer's Mac.
#
# Exit 0 = all five clean, over a plausible number of binaries.
# Exit 1 = at least one violation, or the scan was too small to be trusted.

set -uo pipefail

APP_BUNDLE="${1:?usage: check-bundle-portability.sh <path-to-.app>}"
CONTENTS="$APP_BUNDLE/Contents"
[ -d "$CONTENTS" ] || { echo "GATE FAIL: not an app bundle: $APP_BUNDLE" >&2; exit 1; }

# The scan is only meaningful if it actually found the bundle's binaries. This
# floor is deliberately far below the real count (552 on 3.5.0) and far above
# zero. The env override exists so the shebang and string checks can be
# exercised against a small fixture; build-release.sh never sets it, so a real
# build always gets the floor.
MIN_MACHOS="${MIN_MACHOS:-100}"

REPORT="$(mktemp)"
MACHO_LIST="$(mktemp)"
trap 'rm -f "$REPORT" "$MACHO_LIST"' EXIT

# /usr/lib and /System ship with macOS 14+ and are the correct absolute
# dependencies. Everything else absolute is a machine-specific path.
is_external() {
    case "$1" in
        /usr/lib/*|/System/*) return 1 ;;
        /*)                   return 0 ;;
        *)                    return 1 ;;
    esac
}

find "$CONTENTS" -type f ! -name '*.py' ! -name '*.pyc' ! -name '*.txt' \
     ! -name '*.json' ! -name '*.h' ! -name '*.pyi' ! -name '*.md' -print0 \
| xargs -0 -n 200 file --mime-type -- 2>/dev/null \
| grep -v ' (for architecture [^)]*):' \
| sed -n 's/:[[:space:]]*application\/x-mach-binary$//p' > "$MACHO_LIST"
# ⚠️ Two ways `file` output lies to a naive parser, both hit here:
#  1. It PADS the type column when given a batch of paths, so the separator is
#     ":" plus VARIABLE whitespace. Matching a literal ": " found 3 binaries in
#     a 74,000-file bundle and reported the whole thing clean.
#  2. For a FAT binary it prints an extra line per architecture,
#     "path (for architecture arm64e):  application/x-mach-binary", which parses
#     into a filename that does not exist — inflating the count that the floor
#     below is supposed to police.

MACHO_COUNT=$(wc -l < "$MACHO_LIST" | tr -d ' ')
if [ "$MACHO_COUNT" -lt "$MIN_MACHOS" ]; then
    echo "GATE FAIL: scanned only $MACHO_COUNT Mach-O binaries (floor $MIN_MACHOS)." >&2
    echo "           A clean result from a scan this small proves nothing." >&2
    exit 1
fi

# ---- 1. Load commands, dylib ids and rpaths -------------------------------
# Dumped ONCE for every binary; both check 1 and check 4 read this file, so the
# expensive otool sweep happens a single time.
ALLCMDS="$(mktemp)"
trap 'rm -f "$REPORT" "$MACHO_LIST" "$ALLCMDS"' EXIT

while IFS= read -r macho; do
    [ -f "$macho" ] || continue
    otool -l "$macho" 2>/dev/null | awk -v F="$macho" '
        /^ *cmd LC_(ID_DYLIB|LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LOAD_UPWARD_DYLIB|RPATH)$/ { c=substr($2,4); next }
        c != "" && /^ *(name|path) / {
            # A load-command path may contain spaces, so take the whole field
            # and strip the label and the trailing " (offset N)". $2 would cut
            # "/Volumes/Studio Storage/..." in half and report it clean.
            line=$0
            sub(/^ *(name|path) /, "", line)
            sub(/ \(offset [0-9]+\)$/, "", line)
            print F "\t" c "\t" line
            c=""
        }
    '
done < "$MACHO_LIST" > "$ALLCMDS"

while IFS=$'\t' read -r f cmd p; do
    is_external "$p" && printf '%s\t%s\t%s\n' "$f" "$cmd" "$p"
done < "$ALLCMDS" > "$REPORT"

# ---- 2. Absolute external paths baked into OUR OWN executables ------------
# The Mach-O sweep above cannot see these: /opt/homebrew/bin/python3 in the app
# binary is a STRING the Swift source spawns, not a load command. Scoped to
# Contents/MacOS so third-party wheels' debug strings do not drown the signal.
#
# ⚠️ Deliberately NOT "any absolute path". A release binary legitimately
# contains build paths it never opens — this one carries
# /Users/<dev>/.cargo/registry/... in Rust panic messages, which no
# --remap-path-prefix is set to strip. Flagging those would make the gate
# noisy, and a noisy gate gets disabled. The prefixes below are package
# managers: a path under one of them is a TOOL the app intends to RUN, which
# is the exact defect this exists to catch.
PKG_PREFIXES='/opt/homebrew|/opt/local|/usr/local/Cellar|/opt/miniconda|/opt/anaconda'
for own in "$CONTENTS/MacOS"/*; do
    [ -f "$own" ] || continue
    while IFS= read -r hit; do
        printf '%s\tHARDCODED_STRING\t%s\n' "$own" "$hit" >> "$REPORT"
    done < <(strings -a "$own" 2>/dev/null \
             | grep -oE "($PKG_PREFIXES)[A-Za-z0-9._/@+-]*" | sort -u)
done

# ---- 3. Console-script shebangs ------------------------------------------
SP_BIN="$CONTENTS/Frameworks/Python.framework/Versions/3.12/lib/python3.12/site-packages/bin"
if [ -d "$SP_BIN" ]; then
    while IFS= read -r script; do
        sb="$(head -1 "$script" 2>/dev/null)"
        case "$sb" in
            '#!/opt/homebrew'*|'#!/Users/'*|'#!/private/'*|'#!/tmp/'*)
                printf '%s\tSHEBANG\t%s\n' "$script" "$sb" >> "$REPORT" ;;
        esac
    done < <(find "$SP_BIN" -type f)
fi

# ---- 4. Every relative reference must RESOLVE inside the bundle -----------
# Checks 1-3 only prove no path is absolute-and-external. They would pass a
# bundle whose interpreter loads "@loader_path/../Python" when nothing is at
# that offset — a rewrite that looks correct in otool and fails at launch. This
# resolves each reference against the file that declares it and asserts the
# target is really there. Assert the artifact, not the string.
python3 - "$APP_BUNDLE" "$ALLCMDS" >> "$REPORT" <<'PYEOF'
import os, sys

bundle = os.path.realpath(sys.argv[1])
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[2]) if l.count("\t") == 2]

rpaths = {}
for f, cmd, p in rows:
    if cmd == "RPATH":
        rpaths.setdefault(f, []).append(p)

# @executable_path is ambiguous: a .so in the framework may be loaded by the app
# binary OR by the bundle's own python3.12. Accept either, and only complain
# when neither resolves.
exec_dirs = [os.path.join(bundle, "Contents", "MacOS"),
             os.path.join(bundle, "Contents", "Frameworks",
                          "Python.framework", "Versions", "3.12", "bin")]

LOADS = {"LOAD_DYLIB", "LOAD_WEAK_DYLIB", "REEXPORT_DYLIB", "LOAD_UPWARD_DYLIB"}

def candidates(macho, p):
    d = os.path.dirname(macho)
    if p.startswith("@loader_path/"):
        return [os.path.join(d, p[len("@loader_path/"):])]
    if p.startswith("@executable_path/"):
        tail = p[len("@executable_path/"):]
        return [os.path.join(e, tail) for e in exec_dirs]
    if p.startswith("@rpath/"):
        tail = p[len("@rpath/"):]
        out = []
        for rp in rpaths.get(macho, []):
            if rp.startswith("@loader_path"):
                out.append(os.path.join(d, rp[len("@loader_path/"):] if rp.startswith("@loader_path/") else "", tail))
            elif rp.startswith("@executable_path"):
                for e in exec_dirs:
                    out.append(os.path.join(e, rp[len("@executable_path/"):] if rp.startswith("@executable_path/") else "", tail))
            else:
                out.append(os.path.join(rp, tail))
        return out
    return []

for f, cmd, p in rows:
    if cmd not in LOADS:
        continue
    cands = candidates(f, p)
    if not cands:
        continue                      # absolute — already judged by check 1
    if any(os.path.exists(c) for c in cands):
        continue
    print("%s\tUNRESOLVED\t%s" % (f, p))
PYEOF

# ---- 5. Bundled CA trust store ---------------------------------------------
# Checked on the file, not on a handshake. scripts/check-bundled-tls.py is the
# handshake, and it can only run after the bundle is signed. This gate runs
# before signing too, so a missing cert fails here instead of ten minutes later.
CERT_PEM="$CONTENTS/Frameworks/Python.framework/Versions/3.12/etc/ssl/cert.pem"
SITECUSTOMIZE="$CONTENTS/Frameworks/Python.framework/Versions/3.12/lib/python3.12/sitecustomize.py"
if [ ! -s "$CERT_PEM" ] || ! grep -q "BEGIN CERTIFICATE" "$CERT_PEM"; then
    echo "GATE FAIL: bundled CA file missing or not a PEM bundle:" >&2
    echo "           $CERT_PEM" >&2
    echo "           Without it, urllib trusts /opt/homebrew/etc/openssl@3/cert.pem" >&2
    echo "           and every HTTPS download fails on a customer's Mac." >&2
    exit 1
fi
if [ ! -f "$SITECUSTOMIZE" ] || ! grep -q "SSL_CERT_FILE" "$SITECUSTOMIZE"; then
    echo "GATE FAIL: sitecustomize.py does not set SSL_CERT_FILE." >&2
    echo "           The CA file is in the bundle and nothing points Python at it." >&2
    exit 1
fi

VIOLATIONS=$(wc -l < "$REPORT" | tr -d ' ')

if [ "$VIOLATIONS" -ne 0 ]; then
    echo "" >&2
    echo "GATE FAIL: $VIOLATIONS absolute external reference(s) in the finished bundle." >&2
    echo "           Each of these needs a file that does not exist on a customer's Mac." >&2
    echo "" >&2
    sed "s|$APP_BUNDLE/||" "$REPORT" | sort | head -60 >&2
    [ "$VIOLATIONS" -gt 60 ] && echo "           ... and $((VIOLATIONS - 60)) more" >&2
    echo "" >&2
    echo "           Fix: scripts/relocate-bundle.sh runs before signing and should" >&2
    echo "           have rewritten these. If it did not, it needs a new case." >&2
    exit 1
fi

echo "  Portability gate: $MACHO_COUNT Mach-O binaries, 0 absolute external references."
exit 0
