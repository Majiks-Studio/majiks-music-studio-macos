#!/bin/bash
#
# relocate-bundle.sh <path-to-.app>
#
# Make every Mach-O inside the bundle load-path independent of the machine that
# built it. The shipped app must not need Homebrew, a conda env, or an Xcode
# toolchain to be present — and until this script existed, it needed all three.
#
# WHAT WAS ACTUALLY WRONG (measured on the notarized 3.5.0 bundle):
#
#   Contents/Frameworks/.../bin/python3.12                  -> /opt/homebrew/Cellar/python@3.12/3.12.13_1/...
#   Contents/Frameworks/.../Resources/Python.app/.../Python -> /opt/homebrew/Cellar/python@3.12/3.12.13_1/...
#   Contents/Frameworks/.../lib-dynload/_sqlite3...so       -> /opt/homebrew/opt/sqlite/lib/libsqlite3.dylib
#   + 78 LC_RPATHs into /opt/homebrew/lib, 56 into CI build dirs that never
#     existed on any user's machine, 30 LC_ID_DYLIBs under delocate's /DLC/
#     placeholder, and a dead /Applications/Xcode.app rpath in the app binary.
#
# The first two were "handled" by build-release.sh with the Cellar version
# HARDCODED as 3.12.7_1 while the installed keg was 3.12.13_1, so the rewrite
# silently matched nothing for every release since that upgrade. Nothing here
# hardcodes a version: it reads what the binary actually says.
#
# ⚠️ ORDERING. install_name_tool INVALIDATES a code signature. This script must
# run BEFORE the signing step, and the signing step must then cover every file
# it touched. Running it after signing seals a bundle whose signature no longer
# matches its contents, and Apple rejects the notarization for exactly that.
#
# ⚠️ This script never RUNS the bundled interpreter. At this point in the build
# the bundle is unsigned or stale-signed and macOS SIGKILLs it (CODESIGNING,
# Code 2 Invalid Page). Everything here is otool/install_name_tool — read and
# rewrite, never execute.
#
# ⚠️ No failure is swallowed. A `|| true` on an install_name_tool call is how
# the original defect stayed invisible through fifteen releases.

set -euo pipefail

APP_BUNDLE="${1:?usage: relocate-bundle.sh <path-to-.app>}"
[ -d "$APP_BUNDLE/Contents" ] || { echo "ERROR: not an app bundle: $APP_BUNDLE" >&2; exit 1; }

CONTENTS="$APP_BUNDLE/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"
mkdir -p "$FRAMEWORKS"
FRAMEWORKS_ABS="$(cd "$FRAMEWORKS" && pwd)"

# A path is "external" if it is absolute and points outside the bundle, other
# than the OS locations every Mac has. /usr/lib and /System are guaranteed
# present on macOS 14+ and are the correct way to link libz, libSystem, etc.
is_external() {
    case "$1" in
        /usr/lib/*|/System/*) return 1 ;;
        /*)                   return 0 ;;
        *)                    return 1 ;;   # @rpath / @loader_path / @executable_path
    esac
}

resolve_link() {
    readlink -f "$1" 2>/dev/null || python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"
}

# @loader_path-relative route from the directory holding $1 to $FRAMEWORKS.
loader_path_to_frameworks() {
    local from_dir rel
    from_dir="$(cd "$(dirname "$1")" && pwd)"
    rel=""
    while [ "$from_dir" != "$FRAMEWORKS_ABS" ] && [ "$from_dir" != "/" ]; do
        rel="../$rel"
        from_dir="$(dirname "$from_dir")"
    done
    if [ "$from_dir" = "/" ]; then
        echo "ERROR: $1 is not inside $FRAMEWORKS" >&2
        return 1
    fi
    printf '@loader_path/%s' "$rel"
}

# otool -L, minus the header line, minus the " (compatibility version ...)"
# suffix. Path-with-spaces safe; `awk '{print $1}'` is not.
dylib_deps() {
    otool -L "$1" | tail -n +2 | sed -e 's/^[[:space:]]*//' -e 's/ (compatibility version .*$//'
}

dylib_id() {
    otool -D "$1" 2>/dev/null | tail -n +2 | head -1
}

rpaths_of() {
    otool -l "$1" | awk '
        /^ *cmd LC_RPATH$/ { f=1; next }
        f && /^ *path / { line=$0; sub(/^ *path /,"",line); sub(/ \(offset [0-9]+\)$/,"",line); print line; f=0 }
    '
}

# ------------------------------------------------------------------
# Vendor an external dylib into Frameworks/, chasing its own deps.
# ------------------------------------------------------------------
vendor_dylib() {
    local src real base dst dep depbase
    src="$1"
    base="$(basename "$src")"   # keep the name the loader asked for, not the versioned realpath
    dst="$FRAMEWORKS/$base"
    if [ ! -f "$dst" ]; then
        real="$(resolve_link "$src")"
        cp "$real" "$dst"
        chmod u+w "$dst"
        install_name_tool -id "@loader_path/$base" "$dst"
        printf '%s\n' "$base" >> "$VENDOR_LOG"
        echo "    vendored $base  <- $src" >&2
        while IFS= read -r dep; do
            [ -n "$dep" ] || continue
            is_external "$dep" || continue
            depbase="$(vendor_dylib "$dep")"
            install_name_tool -change "$dep" "@loader_path/$depbase" "$dst"
        done < <(dylib_deps "$dst")
    fi
    printf '%s' "$base"
}

MACHO_LIST="$(mktemp)"
# ⚠️ vendor_dylib runs inside $( ), i.e. a SUBSHELL, so a shell variable it
# increments is discarded the moment it returns. The fixpoint below therefore
# counts lines in a FILE — a side effect that survives the subshell — instead of
# a counter that would have read 0 forever and made the loop look settled.
VENDOR_LOG="$(mktemp)"
trap 'rm -f "$MACHO_LIST" "$VENDOR_LOG"' EXIT

scan_machos() {
    find "$CONTENTS" -type f ! -name '*.py' ! -name '*.pyc' ! -name '*.txt' \
         ! -name '*.json' ! -name '*.h' ! -name '*.pyi' ! -name '*.md' -print0 \
    | xargs -0 -n 200 file --mime-type -- 2>/dev/null \
    | grep -v ' (for architecture [^)]*):' \
    | sed -n 's/:[[:space:]]*application\/x-mach-binary$//p' > "$MACHO_LIST"
}

REWROTE_LOAD=0
REWROTE_ID=0
DELETED_RPATH=0
MISSING=0

# A dylib vendored into Frameworks/ during a pass was NOT in that pass's file
# list, so its OWN rpaths and ids were never cleaned. That is not theoretical:
# the first run of this script left
#   Frameworks/libsqlite3.dylib  LC_RPATH  /opt/homebrew/Cellar/sqlite/3.53.3/lib
# behind, and the gate caught it. So run to a fixpoint: repeat while the last
# pass pulled anything new in. Bounded, because an unbounded loop over a
# mis-detected change is a hang, not a fix.
for pass in 1 2 3; do
VENDORED_BEFORE=$(wc -l < "$VENDOR_LOG" | tr -d ' ')

echo "  Scanning bundle for Mach-O binaries (pass $pass)..."
scan_machos
MACHO_COUNT=$(wc -l < "$MACHO_LIST" | tr -d ' ')
if [ "$MACHO_COUNT" -lt 100 ]; then
    echo "  FATAL: only $MACHO_COUNT Mach-O files found — expected hundreds." >&2
    echo "  The scan is broken, so a clean result from it would prove nothing." >&2
    exit 1
fi
echo "  Found $MACHO_COUNT Mach-O binaries."

while IFS= read -r macho; do
    [ -f "$macho" ] || continue
    self_id="$(dylib_id "$macho")"

    # --- LC_LOAD_DYLIB / weak / reexport -------------------------------
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        # An `A && B && continue` here is exempt from set -e only by a rule
        # most readers do not carry in their head. Spell it out.
        if [ -n "$self_id" ] && [ "$dep" = "$self_id" ]; then continue; fi
        is_external "$dep" || continue

        case "$dep" in
            */Python.framework/Versions/3.12/Python)
                # Any Python framework outside the bundle — a Cellar keg,
                # /opt/homebrew/opt/..., a python.org install — becomes OURS.
                # Matched on shape, never on a pinned version string; that pin
                # is precisely what broke.
                target="$(loader_path_to_frameworks "$macho")Python.framework/Versions/3.12/Python"
                ;;
            *)
                if [ -e "$dep" ]; then
                    target="$(loader_path_to_frameworks "$macho")$(vendor_dylib "$dep")"
                else
                    # Referenced, but absent on THIS machine too: a build-host
                    # artefact that has never resolved anywhere. Report it and
                    # leave it for the gate — rewriting it to a file we do not
                    # have would be a lie.
                    echo "    WARNING: $macho loads missing $dep" >&2
                    MISSING=$((MISSING + 1))
                    continue
                fi
                ;;
        esac
        install_name_tool -change "$dep" "$target" "$macho"
        REWROTE_LOAD=$((REWROTE_LOAD + 1))
    done < <(dylib_deps "$macho")

    # --- LC_ID_DYLIB ---------------------------------------------------
    # delocate stamps vendored wheel dylibs with /DLC/<pkg>/.dylibs/<name>;
    # Homebrew stamps its own prefix. Nothing loads them by that path today
    # (consumers use @loader_path), but an absolute external ID is exactly the
    # thing that starts resolving to the WRONG library the day that directory
    # exists. Point each at itself.
    if [ -n "$self_id" ] && is_external "$self_id"; then
        install_name_tool -id "@loader_path/$(basename "$self_id")" "$macho"
        REWROTE_ID=$((REWROTE_ID + 1))
    fi

    # --- LC_RPATH ------------------------------------------------------
    # An rpath into /opt/homebrew/lib or /Users/runner/... is a search path on
    # somebody else's disk. On a customer's Mac it is dead; on a developer's it
    # is worse than dead, because it can satisfy a load from a library the
    # bundle was never tested against.
    while IFS= read -r rp; do
        [ -n "$rp" ] || continue
        is_external "$rp" || continue
        # A duplicated LC_RPATH needs deleting more than once; a delete that
        # fails for any OTHER reason is fatal, not shrugged off.
        while rpaths_of "$macho" | grep -qxF "$rp"; do
            if ! install_name_tool -delete_rpath "$rp" "$macho" 2>/dev/null; then
                echo "  FATAL: could not delete rpath '$rp' from $macho" >&2
                exit 1
            fi
            DELETED_RPATH=$((DELETED_RPATH + 1))
        done
    done < <(rpaths_of "$macho" | sort -u)

done < "$MACHO_LIST"

VENDORED=$(wc -l < "$VENDOR_LOG" | tr -d ' ')
if [ "$VENDORED" -eq "$VENDORED_BEFORE" ]; then
    break
fi
echo "  Pass $pass vendored $((VENDORED - VENDORED_BEFORE)) new dylib(s); re-scanning."
done

VENDORED=$(wc -l < "$VENDOR_LOG" | tr -d ' ')
echo "  Rewrote $REWROTE_LOAD load command(s), $REWROTE_ID dylib id(s); deleted $DELETED_RPATH external rpath(s); vendored $VENDORED dylib(s)."
if [ "$MISSING" -gt 0 ]; then
    echo "  $MISSING dangling reference(s) left for the gate to report." >&2
fi

# ------------------------------------------------------------------
# Console-script shebangs
# ------------------------------------------------------------------
# `pip install --target` writes ~45 entry-point scripts under site-packages/bin
# whose shebang is the BUILD MACHINE's interpreter
# (#!/opt/homebrew/opt/python@3.12/bin/python3.12). Not Mach-O; same defect — a
# path that exists only here. Replace with an sh/python polyglot that resolves
# the bundle's own interpreter relative to the script's own location.
SP_BIN="$FRAMEWORKS/Python.framework/Versions/3.12/lib/python3.12/site-packages/bin"
SHEBANGS_FIXED=0
if [ -d "$SP_BIN" ]; then
    for script in "$SP_BIN"/*; do
        [ -f "$script" ] || continue
        sb="$(head -1 "$script" 2>/dev/null || true)"
        case "$sb" in
            '#!/opt/homebrew'*|'#!/Users/'*|'#!/private/'*|'#!/tmp/'*) ;;
            *) continue ;;
        esac
        {
            printf '#!/bin/sh\n'
            # sh reads ''''exec … as `exec …` (two empty words then the builtin);
            # python reads the whole line as one triple-quoted string literal.
            # Four levels up from site-packages/bin is Versions/3.12, which is
            # where the bundle's own bin/python3.12 lives.
            printf "''''exec \"\$(dirname \"\$0\")/../../../../bin/python3.12\" \"\$0\" \"\$@\" # '''\n"
            tail -n +2 "$script"
        } > "$script.relocated"
        chmod 755 "$script.relocated"
        mv "$script.relocated" "$script"
        SHEBANGS_FIXED=$((SHEBANGS_FIXED + 1))
    done
fi
echo "  Rewrote $SHEBANGS_FIXED console-script shebang(s)."

echo "  Relocation complete."
