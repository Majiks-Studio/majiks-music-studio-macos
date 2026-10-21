#!/bin/bash
#
# Majiks Studio - Release Build Script
#
# This script does FOUR separable things, and the flags gate them separately.
# Reading "builds, signs, notarizes and uploads" as one breath is how a lane
# submitted an iteration build to Apple's notary service: --skip-upload gates
# ONLY step 9, and notarization at step 8 ran regardless.
#
#   steps 1-7  build, sign, relocate, gate, DMG   — always run
#   step 8     NOTARIZE + STAPLE with Apple       — skipped by --skip-notarize
#   step 9     upload to B2 + notify majiks.studio — skipped by --skip-upload
#
# Notarizing is the owner's step. While iterating, pass --skip-notarize.
#
# Usage:
#   ./build-release.sh                  # Reads version from Info.plist
#   ./build-release.sh --skip-notarize  # Build, sign and DMG only — no Apple submission
#   ./build-release.sh --skip-upload    # No B2 upload or site notification (STILL NOTARIZES)
#   ./build-release.sh --dry-run        # = --skip-notarize --skip-upload
#   ./build-release.sh --ci             # CI mode: uses env vars for credentials
#
# Required env vars in CI mode:
#   B2_APPLICATION_KEY_ID, B2_APPLICATION_KEY
#   MAJIKS_STUDIO_VERSION_TOKEN
#

set -e

# Parse flags
SKIP_UPLOAD=false
SKIP_NOTARIZE=false
CI_MODE=false
for arg in "$@"; do
    case $arg in
        --skip-upload) SKIP_UPLOAD=true ;;
        --skip-notarize) SKIP_NOTARIZE=true ;;
        --dry-run) SKIP_NOTARIZE=true; SKIP_UPLOAD=true ;;
        --ci) CI_MODE=true ;;
        --*) echo "ERROR: unknown flag '$arg'." >&2
             echo "       Known flags: --skip-upload --skip-notarize --dry-run --ci" >&2
             echo "       Refusing to run: a mistyped --skip-notarise would have" >&2
             echo "       silently submitted this build to Apple." >&2
             exit 1 ;;
    esac
done

# An upload of a DMG that was never notarized would ship a build Gatekeeper
# blocks on first launch.
if [ "$SKIP_NOTARIZE" = true ] && [ "$SKIP_UPLOAD" = false ]; then
    echo "ERROR: --skip-notarize without --skip-upload would publish an un-notarized DMG." >&2
    echo "       Use --dry-run to build locally without notarizing or uploading." >&2
    exit 1
fi

# Navigate to project root
cd "$(dirname "$0")"

# Read version from Info.plist
VERSION=$(defaults read "$(pwd)/src/swift/Sources/Info.plist" CFBundleShortVersionString 2>/dev/null || \
          /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "src/swift/Sources/Info.plist")

if [ -z "$VERSION" ]; then
    echo "ERROR: Could not read version from Info.plist"
    exit 1
fi

# Configuration
APP_NAME="Majiks Music Studio"
BUILD_DIR=".build/release"
# Override with an absolute path when the internal disk cannot hold the bundle.
DIST_DIR="${DIST_DIR:-dist}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_NAME="MajiksMusicStudio-v${VERSION}-macOS.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: AARON MAZZONE STRANSKY}"
PYTHON_ENTITLEMENTS="src/swift/Python.entitlements"
# The APP's own entitlements: com.apple.security.device.audio-input and nothing
# else. Signed with the hardened runtime and no entitlements, the app is denied
# audio input, so a release build could not record.
# Not MajiksMusicStudio.entitlements: that is the Xcode (project.yml) file, and
# its keychain-access-groups use Xcode's $(AppIdentifierPrefix) and need a
# provisioning profile, which a Developer ID build signed here does not embed.
APP_ENTITLEMENTS="src/swift/MajiksMusicStudio-release.entitlements"
# Derive the current Homebrew python@3.12 keg — a hardcoded version breaks on every brew upgrade
PYTHON312_PREFIX="$(ls -d /opt/homebrew/Cellar/python@3.12/*/ | sort -V | tail -1)"
PYTHON312="${PYTHON312_PREFIX}bin/python3.12"
PYTHON_FRAMEWORK_SRC="${PYTHON312_PREFIX}Frameworks/Python.framework"
B2_BUCKET="majiks-download-bucket"
B2_DOWNLOAD_BASE="https://f005.backblazeb2.com/file/$B2_BUCKET"

echo "======================================"
echo " Majik's Music Studio v$VERSION Release Build"
echo "======================================"
echo ""

# ============================================================
# Step 1: Build the Rust engine framework, then the Swift binary
# ============================================================
# The Studio DAW runs on the FFI-backed Rust engine, which build-engine.sh
# assembles into src/swift/MajiksEngine.xcframework. That framework is a
# gitignored BUILD PRODUCT: if it is absent when `swift build` runs,
# Package.swift SILENTLY falls back to StudioMockEngine — a no-audio UI
# mannequin (synthetic 8-track fixture, plays nothing, renders/exports
# nothing). A release built that way looks fine and ships a dead DAW.
#
# So we ALWAYS build the framework first and pin MAJIKS_ENGINE=real for the
# swift build. MAJIKS_ENGINE=real makes Package.swift HARD-FAIL when the
# framework is missing instead of quietly selecting the mock, so a broken
# engine build can never masquerade as a shipped release.
echo "[1/9] Building Rust engine framework (real engine)..."
./src/swift/scripts/build-engine.sh
if [ ! -d "src/swift/MajiksEngine.xcframework" ]; then
    echo "ERROR: build-engine.sh did not produce src/swift/MajiksEngine.xcframework." >&2
    echo "       Refusing to build a release that would ship the mock (silent, no-audio) engine." >&2
    exit 1
fi

echo "[1/9] Building release binary (MAJIKS_ENGINE=real)..."
cd src/swift
SWIFT_FLAGS="${SWIFT_FLAGS:-}"
MAJIKS_ENGINE=real swift build -c release $SWIFT_FLAGS
cd ../..
echo "  Done."
echo ""

# ============================================================
# Step 2: Create .app bundle
# ============================================================
echo "[2/9] Creating .app bundle..."
mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "src/swift/$BUILD_DIR/MajiksMusicStudio" "$APP_BUNDLE/Contents/MacOS/"
chmod +x "$APP_BUNDLE/Contents/MacOS/MajiksMusicStudio"
cp "src/swift/Sources/Info.plist" "$APP_BUNDLE/Contents/"

# Icons
[ -f "assets/icons/AppIcon.icns" ] && cp "assets/icons/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
[ -f "assets/icons/app-icon-128.png" ] && cp "assets/icons/app-icon-128.png" "$APP_BUNDLE/Contents/Resources/"
[ -f "assets/icons/the-engineer.png" ] && cp "assets/icons/the-engineer.png" "$APP_BUNDLE/Contents/Resources/"
[ -f "assets/icons/the-engineer-128.png" ] && cp "assets/icons/the-engineer-128.png" "$APP_BUNDLE/Contents/Resources/"
cp "THIRD-PARTY-NOTICES.md" "$APP_BUNDLE/Contents/Resources/"
cp "LICENSE" "$APP_BUNDLE/Contents/Resources/"
echo "  Done."
echo ""

# ============================================================
# Step 3: Bundle Python.framework
# ============================================================
echo "[3/9] Bundling Python.framework..."

FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
PYTHON_FRAMEWORK_DST="$FRAMEWORKS_DIR/Python.framework"
LOADER_PATH_TO_FRAMEWORKS="@loader_path/../../../../../../"
PYTHON_LIB_DYNLOAD="$PYTHON_FRAMEWORK_DST/Versions/3.12/lib/python3.12/lib-dynload"

mkdir -p "$FRAMEWORKS_DIR"
mkdir -p "$APP_BUNDLE/Contents/Resources/python"
mkdir -p "$PYTHON_FRAMEWORK_DST/Versions/3.12"
cp -R "$PYTHON_FRAMEWORK_SRC/Versions/3.12/"* "$PYTHON_FRAMEWORK_DST/Versions/3.12/"

# Remove broken symlinks and PEP 668 marker
find "$PYTHON_FRAMEWORK_DST" -type l ! -exec test -e {} \; -delete 2>/dev/null || true
rm -f "$PYTHON_FRAMEWORK_DST/Versions/3.12/lib/python3.12/EXTERNALLY-MANAGED"

# Create framework symlinks
ln -sf "3.12" "$PYTHON_FRAMEWORK_DST/Versions/Current"
ln -sf "Versions/Current/Python" "$PYTHON_FRAMEWORK_DST/Python"
ln -sf "Versions/Current/Resources" "$PYTHON_FRAMEWORK_DST/Resources"
ln -sf "Versions/Current/Headers" "$PYTHON_FRAMEWORK_DST/Headers" 2>/dev/null || true

# Bundle Homebrew libraries (OpenSSL, mpdecimal, lzma, zstd)
OPENSSL_OPT="/opt/homebrew/opt/openssl@3/lib"
if [ -f "$OPENSSL_OPT/libssl.3.dylib" ]; then
    cp "$OPENSSL_OPT/libssl.3.dylib" "$FRAMEWORKS_DIR/"
    cp "$OPENSSL_OPT/libcrypto.3.dylib" "$FRAMEWORKS_DIR/"
    CELLAR_CRYPTO_PATH=$(otool -L "$FRAMEWORKS_DIR/libssl.3.dylib" | grep libcrypto | awk '{print $1}')
    install_name_tool -change "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib" "@loader_path/libcrypto.3.dylib" "$FRAMEWORKS_DIR/libssl.3.dylib" 2>/dev/null || true
    [ -n "$CELLAR_CRYPTO_PATH" ] && install_name_tool -change "$CELLAR_CRYPTO_PATH" "@loader_path/libcrypto.3.dylib" "$FRAMEWORKS_DIR/libssl.3.dylib" 2>/dev/null || true
    install_name_tool -id "@loader_path/libcrypto.3.dylib" "$FRAMEWORKS_DIR/libcrypto.3.dylib" 2>/dev/null || true
    install_name_tool -id "@loader_path/libssl.3.dylib" "$FRAMEWORKS_DIR/libssl.3.dylib" 2>/dev/null || true

    SSL_MODULE="$PYTHON_LIB_DYNLOAD/_ssl.cpython-312-darwin.so"
    if [ -f "$SSL_MODULE" ]; then
        install_name_tool -change "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib" "${LOADER_PATH_TO_FRAMEWORKS}libssl.3.dylib" "$SSL_MODULE"
        install_name_tool -change "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib" "${LOADER_PATH_TO_FRAMEWORKS}libcrypto.3.dylib" "$SSL_MODULE"
        for cellar_version in /opt/homebrew/Cellar/openssl@3/*/lib; do
            install_name_tool -change "${cellar_version}/libssl.3.dylib" "${LOADER_PATH_TO_FRAMEWORKS}libssl.3.dylib" "$SSL_MODULE" 2>/dev/null || true
            install_name_tool -change "${cellar_version}/libcrypto.3.dylib" "${LOADER_PATH_TO_FRAMEWORKS}libcrypto.3.dylib" "$SSL_MODULE" 2>/dev/null || true
        done
    fi
    HASHLIB_MODULE="$PYTHON_LIB_DYNLOAD/_hashlib.cpython-312-darwin.so"
    if [ -f "$HASHLIB_MODULE" ]; then
        install_name_tool -change "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib" "${LOADER_PATH_TO_FRAMEWORKS}libcrypto.3.dylib" "$HASHLIB_MODULE"
        for cellar_version in /opt/homebrew/Cellar/openssl@3/*/lib; do
            install_name_tool -change "${cellar_version}/libcrypto.3.dylib" "${LOADER_PATH_TO_FRAMEWORKS}libcrypto.3.dylib" "$HASHLIB_MODULE" 2>/dev/null || true
        done
    fi
fi

MPDEC_OPT="/opt/homebrew/opt/mpdecimal/lib"
if [ -f "$MPDEC_OPT/libmpdec.4.dylib" ]; then
    cp "$(readlink -f "$MPDEC_OPT/libmpdec.4.dylib" 2>/dev/null || echo "$MPDEC_OPT/libmpdec.4.dylib")" "$FRAMEWORKS_DIR/libmpdec.4.dylib"
    install_name_tool -id "@loader_path/libmpdec.4.dylib" "$FRAMEWORKS_DIR/libmpdec.4.dylib" 2>/dev/null || true
    DECIMAL_MODULE="$PYTHON_LIB_DYNLOAD/_decimal.cpython-312-darwin.so"
    if [ -f "$DECIMAL_MODULE" ]; then
        install_name_tool -change "/opt/homebrew/opt/mpdecimal/lib/libmpdec.4.dylib" "${LOADER_PATH_TO_FRAMEWORKS}libmpdec.4.dylib" "$DECIMAL_MODULE"
        for cellar_version in /opt/homebrew/Cellar/mpdecimal/*/lib; do
            install_name_tool -change "${cellar_version}/libmpdec.4.dylib" "${LOADER_PATH_TO_FRAMEWORKS}libmpdec.4.dylib" "$DECIMAL_MODULE" 2>/dev/null || true
        done
    fi
fi

LZMA_OPT="/opt/homebrew/opt/xz/lib"
if [ -f "$LZMA_OPT/liblzma.5.dylib" ]; then
    cp "$LZMA_OPT/liblzma.5.dylib" "$FRAMEWORKS_DIR/"
    install_name_tool -id "@loader_path/liblzma.5.dylib" "$FRAMEWORKS_DIR/liblzma.5.dylib" 2>/dev/null || true
    LZMA_MODULE="$PYTHON_LIB_DYNLOAD/_lzma.cpython-312-darwin.so"
    if [ -f "$LZMA_MODULE" ]; then
        install_name_tool -change "/opt/homebrew/opt/xz/lib/liblzma.5.dylib" "${LOADER_PATH_TO_FRAMEWORKS}liblzma.5.dylib" "$LZMA_MODULE"
        for cellar_version in /opt/homebrew/Cellar/xz/*/lib; do
            install_name_tool -change "${cellar_version}/liblzma.5.dylib" "${LOADER_PATH_TO_FRAMEWORKS}liblzma.5.dylib" "$LZMA_MODULE" 2>/dev/null || true
        done
    fi
fi

ZSTD_OPT="/opt/homebrew/opt/zstd/lib"
if [ -f "$ZSTD_OPT/libzstd.1.dylib" ]; then
    cp "$(readlink -f "$ZSTD_OPT/libzstd.1.dylib" 2>/dev/null || echo "$ZSTD_OPT/libzstd.1.dylib")" "$FRAMEWORKS_DIR/libzstd.1.dylib"
    install_name_tool -id "@loader_path/libzstd.1.dylib" "$FRAMEWORKS_DIR/libzstd.1.dylib" 2>/dev/null || true
    ZSTD_MODULE="$PYTHON_LIB_DYNLOAD/_zstd.cpython-312-darwin.so"
    if [ -f "$ZSTD_MODULE" ]; then
        install_name_tool -change "/opt/homebrew/opt/zstd/lib/libzstd.1.dylib" "${LOADER_PATH_TO_FRAMEWORKS}libzstd.1.dylib" "$ZSTD_MODULE"
        for cellar_version in /opt/homebrew/Cellar/zstd/*/lib; do
            install_name_tool -change "${cellar_version}/libzstd.1.dylib" "${LOADER_PATH_TO_FRAMEWORKS}libzstd.1.dylib" "$ZSTD_MODULE" 2>/dev/null || true
        done
    fi
fi

# The framework's MAIN dylib gets its proper relative install name here. This
# one line was always correct, which is why the app itself never looked broken.
FRAMEWORK_DYLIB="$PYTHON_FRAMEWORK_DST/Versions/3.12/Python"
[ -f "$FRAMEWORK_DYLIB" ] && install_name_tool -id "@executable_path/../Frameworks/Python.framework/Versions/3.12/Python" "$FRAMEWORK_DYLIB"

PYTHON_APP_BIN="$PYTHON_FRAMEWORK_DST/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
FRAMEWORK_PYTHON_BIN="$PYTHON_FRAMEWORK_DST/Versions/3.12/bin/python3.12"

# ⚠️ WHAT USED TO BE HERE, AND WHY IT IS GONE.
#
# Two blocks rewrote the Cellar reference in Python.app and bin/python3.12 with
# the Cellar version HARDCODED as 3.12.7_1. The installed keg is 3.12.13_1, so
# from the day Homebrew upgraded, both `install_name_tool -change` calls matched
# nothing and did nothing — silently, because -change on an absent path is a
# no-op with exit 0. Every release since shipped an interpreter carrying
#
#   LC_LOAD_DYLIB /opt/homebrew/Cellar/python@3.12/3.12.13_1/.../Python
#
# which cannot load on a machine without Homebrew, i.e. on every customer's.
#
# Replacing the pin with $PYTHON312_PREFIX would fix today's build and leave the
# same shape of bug (nothing asserts the rewrite landed, and there were two more
# offenders nobody had looked for). So the rewriting moved to step 5, which
# reads what each binary ACTUALLY references instead of guessing, and step 5 is
# followed by a gate that fails the build if anything absolute survives.
echo "  Done."
echo ""

# ============================================================
# Step 4: Install Python dependencies
# ============================================================
echo "[4/9] Installing Python dependencies..."

SITE_PACKAGES="$PYTHON_FRAMEWORK_DST/Versions/3.12/lib/python3.12/site-packages"
mkdir -p "$SITE_PACKAGES"

TEMP_SITE_PACKAGES=$(mktemp -d)

# Core dependencies (includes MLX for Apple Silicon native acceleration)
"$PYTHON312" -m pip install --target "$TEMP_SITE_PACKAGES" --break-system-packages \
    librosa "mlx>=0.25.2" "mlx-lm>=0.20.0" mutagen numpy scipy anthropic openai pydantic requests certifi soundfile huggingface_hub pip 2>&1 | tail -3

# Stem separation (demucs). The bundle already carries torch/torchaudio, so this
# adds only demucs and its small helpers -- no second Python runtime, no venv
# duplicating a 2 GB torch. numpy is installed ABOVE and re-asserted below on
# purpose: `pip install demucs` does NOT pull numpy, but demucs imports it at
# module load, so a bundle without it fails with an ImportError traceback
# instead of a clean "install demucs" message. Verified below, not assumed.
"$PYTHON312" -m pip install --target "$TEMP_SITE_PACKAGES" --break-system-packages \
    demucs numpy 2>&1 | tail -3

# ACE-Step dependencies
"$PYTHON312" -m pip install --target "$TEMP_SITE_PACKAGES" --break-system-packages \
    "torch>=2.10.0" "torchaudio>=2.10.0" torchvision diffusers accelerate "transformers>=4.57.0,<5.0.0" \
    hangul-romanize num2words spacy cutlet "fugashi[unidic-lite]" \
    datasets pytorch_lightning matplotlib click peft py3langid pypinyin \
    tensorboard tensorboardX einops loguru \
    vector_quantize_pytorch 2>&1 | tail -3

# ACE-Step 1.5 v0.1.6 from GitHub (native MLX support for Apple Silicon, XL model support)
"$PYTHON312" -m pip install --target "$TEMP_SITE_PACKAGES" --break-system-packages \
    "git+https://github.com/ace-step/ACE-Step-1.5.git@v0.1.6" 2>&1 | tail -3

# Remove torchcodec (torchaudio uses soundfile fallback)
rm -rf "$TEMP_SITE_PACKAGES/torchcodec" "$TEMP_SITE_PACKAGES/torchcodec-"*.dist-info

# Pin transformers to 4.57.x (5.x breaks ACE-Step model loading)
rm -rf "$TEMP_SITE_PACKAGES/transformers" "$TEMP_SITE_PACKAGES/transformers-"*.dist-info
"$PYTHON312" -m pip install --target "$TEMP_SITE_PACKAGES" --break-system-packages \
    --no-deps "transformers==4.57.6" 2>&1 | tail -2

# Pin huggingface-hub to 0.x (transformers 4.57.x requires <1.0)
rm -rf "$TEMP_SITE_PACKAGES/huggingface_hub" "$TEMP_SITE_PACKAGES/huggingface_hub-"*.dist-info
"$PYTHON312" -m pip install --target "$TEMP_SITE_PACKAGES" --break-system-packages \
    --no-deps "huggingface-hub==0.36.2" 2>&1 | tail -2

# Pin tokenizers to what transformers 4.57.6 accepts (>=0.22.0,<=0.23.0; there is
# no final 0.23.0, so 0.22.2). mlx-lm in the first install pulls transformers 5.x,
# which since 5.16 wants tokenizers>=0.23.1, and --target never replaces a package
# already in the directory. 3.6.3 shipped 0.23.1, 3.6.4 shipped 0.23.2, and
# `import transformers` refused to load: local generation was dead.
rm -rf "$TEMP_SITE_PACKAGES/tokenizers" "$TEMP_SITE_PACKAGES/tokenizers-"*.dist-info
"$PYTHON312" -m pip install --target "$TEMP_SITE_PACKAGES" --break-system-packages \
    --no-deps "tokenizers==0.22.2" 2>&1 | tail -2

# ACE-Step module strategy:
# - MLX backend (default): Use native ACE-Step 1.5 package (has full MLX support)
# - MPS fallback: Overlay vendored modules with MPS-specific patches
# Set ACE_STEP_BACKEND=mps to use vendored overrides for legacy MPS path
ACESTEP_PKG_DIR="$TEMP_SITE_PACKAGES/acestep"
if [ "${ACE_STEP_BACKEND:-mlx}" = "mps" ] && [ -d "$ACESTEP_PKG_DIR" ] && [ -d "src/python/acestep_modules" ]; then
    echo "  MPS backend: applying vendored ACE-Step module overrides..."
    for module in handler.py inference.py llm_inference.py audio_utils.py constants.py \
                  constrained_logits_processor.py dit_alignment_score.py gpu_config.py \
                  model_downloader.py acestep_v15_pipeline.py genres_vocab.txt; do
        [ -f "src/python/acestep_modules/$module" ] && cp "src/python/acestep_modules/$module" "$ACESTEP_PKG_DIR/"
    done
else
    echo "  MLX backend: using native ACE-Step 1.5 package (no vendored overrides)"
fi

# Native extensions
"$PYTHON312" -m pip install --target "$TEMP_SITE_PACKAGES" --break-system-packages \
    srsly cymem preshed murmurhash blis thinc mojimoji 2>&1 | tail -3

# Copy to bundled framework
cp -R "$TEMP_SITE_PACKAGES/"* "$SITE_PACKAGES/"
rm -rf "$TEMP_SITE_PACKAGES"

# Clean up duplicate dist-info
for pkg_name in tokenizers numpy transformers huggingface_hub safetensors accelerate; do
    pkg_count=$(find "$SITE_PACKAGES" -maxdepth 1 -name "${pkg_name}-*.dist-info" -type d 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pkg_count" -gt 1 ]; then
        newest=$(find "$SITE_PACKAGES" -maxdepth 1 -name "${pkg_name}-*.dist-info" -type d 2>/dev/null | sort -V | tail -1)
        find "$SITE_PACKAGES" -maxdepth 1 -name "${pkg_name}-*.dist-info" -type d 2>/dev/null | sort -V | while IFS= read -r old_dir; do
            if [ "$old_dir" != "$newest" ]; then rm -rf "$old_dir"; fi
        done
    fi
done

# ---------------------------------------------------------------------------
# Console scripts a PIN left behind.
#
# The two pins above are "rm -rf the package directory and its dist-info, then
# reinstall the wanted version with --no-deps". That takes the LIBRARY back but
# not site-packages/bin: `pip install --target ... --no-deps` writes no console
# scripts at all, so the launchers the FIRST (unpinned) install wrote survive,
# still importing the newer release's module layout. Reproduced in isolation,
# not inferred.
#
# The 3.5.0 bundle shipped two of them, both dead on every machine:
#   bin/huggingface-cli -> huggingface_hub.cli.deprecated_cli
#        hub is pinned to 0.36.2, whose own entry_points.txt names
#        huggingface_hub.commands.huggingface_cli. The script is hub 1.x's.
#   bin/transformers    -> transformers.cli.transformers
#        transformers is pinned to 4.57.6, which names
#        transformers.commands.transformers_cli. The script is 5.x's.
#
# REMOVED rather than repaired. Nothing invokes either: GenerationModelStore
# runs the module directly ("<bundled python> -m
# huggingface_hub.commands.huggingface_cli download") precisely because the
# script was unusable, and its external-CLI fallbacks look in /opt/homebrew,
# /usr/local and ~/.local — never in the bundle. Repairing would mean
# hand-authoring a launcher (pip will not regenerate one under --target
# --no-deps) and hand-maintaining it for an executable no code path calls.
rm -f "$SITE_PACKAGES/bin/huggingface-cli" "$SITE_PACKAGES/bin/transformers"

# ASSERT THE ARTIFACT. Deleting two names by hand fixes today's bundle; it does
# nothing about the next pin. This fails the build if ANY console script imports
# a module that is not in the bundle, and refuses to pass on a scan too small to
# mean anything — same rule as the .pyc floor below and the Mach-O floor in
# check-bundle-portability.sh.
./scripts/check-bundle-console-scripts.sh "$SITE_PACKAGES" || exit 1

# Trust store. libcrypto in this bundle is Homebrew's OpenSSL, and its
# compiled-in default CA file is /opt/homebrew/etc/openssl@3/cert.pem. That
# string is not a load command, so step 5 cannot rewrite it and the Mach-O
# portability scan cannot see it. urllib uses it. The file exists on the
# build machine and on no customer's Mac, which is the setup wizard's
# CERTIFICATE_VERIFY_FAILED ("unable to get local issuer certificate").
#
# Copy certifi's bundle into the framework and point SSL_CERT_FILE at it from
# sitecustomize, which runs for every start of this interpreter. Do not write
# the file at runtime: the bundle is sealed by step 6, and a runtime write
# breaks the notarization.
CERT_SRC="$SITE_PACKAGES/certifi/cacert.pem"
CERT_DST="$PYTHON_FRAMEWORK_DST/Versions/3.12/etc/ssl/cert.pem"
if [ ! -s "$CERT_SRC" ]; then
    echo "FATAL: certifi CA bundle missing at $CERT_SRC" >&2
    echo "       The shipped interpreter would trust /opt/homebrew/etc/openssl@3/cert.pem." >&2
    exit 1
fi
mkdir -p "$(dirname "$CERT_DST")"
cp "$CERT_SRC" "$CERT_DST"
grep -q "BEGIN CERTIFICATE" "$CERT_DST" || {
    echo "FATAL: $CERT_DST is not a PEM bundle" >&2
    exit 1
}

# Python path configuration
cat > "$PYTHON_FRAMEWORK_DST/Versions/3.12/lib/python3.12/sitecustomize.py" << 'PYEOF'
import sys
import os

framework_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
site_packages = os.path.join(framework_dir, 'lib', 'python3.12', 'site-packages')
if site_packages not in sys.path:
    sys.path.insert(0, site_packages)

app_bundle = os.path.dirname(os.path.dirname(os.path.dirname(framework_dir)))
resources_python = os.path.join(app_bundle, 'Resources', 'python')
if os.path.exists(resources_python) and resources_python not in sys.path:
    sys.path.insert(0, resources_python)

# Versions/3.12/lib/python3.12/sitecustomize.py -> Versions/3.12/etc/ssl/cert.pem
# Keep this relative in step with majik_backend.tls.framework_cafile.
_ca = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "etc", "ssl", "cert.pem"))
if os.path.isfile(_ca):
    _current = os.environ.get("SSL_CERT_FILE")
    if not _current or not os.path.isfile(_current):
        os.environ["SSL_CERT_FILE"] = _ca
    for _key in ("REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE"):
        _existing = os.environ.get(_key)
        if not _existing or not os.path.isfile(_existing):
            os.environ[_key] = _ca
PYEOF

# Copy backend code (clear stale bytecode from source and destination)
find "src/python" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "src/python" -name "*.pyc" -delete 2>/dev/null || true
cp -r "src/python/majik_backend" "$APP_BUNDLE/Contents/Resources/python/"
find "$APP_BUNDLE/Contents/Resources/python" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true

# Bake bytecode for everything importable BEFORE signing, so no interpreter can
# ever write a .pyc into the sealed bundle at runtime (a runtime write breaks
# the code-signature seal — Gatekeeper then rejects the app). pip pre-compiles
# most of site-packages, but .pth-imported modules (e.g. _distutils_hack) and
# the copied backend tree are not guaranteed — compile them all now so the
# baked bytecode ships inside the seal.
#
# ⚠️ USE THE HOST INTERPRETER ($PYTHON312), NEVER "$FRAMEWORK_PYTHON_BIN" HERE.
# Step 3 runs install_name_tool over the bundled python3.12 and its .so files,
# which INVALIDATES their code signatures — and signing does not happen until
# step 5. macOS SIGKILLs an invalidly-signed binary the instant it dlopens one
# of those .so files:
#
#     Termination Reason: CODESIGNING, Code 2 Invalid Page
#     SIGKILL (Code Signature Invalid)
#
# So the bundled interpreter is UNRUNNABLE at this point in the script, by
# construction. It is not a broken bundle — it is simply not sealed yet.
# `compileall` only READS .py and WRITES .pyc, so it never needs the bundle's
# own interpreter; it needs a matching bytecode magic number, and $PYTHON312 is
# the very keg this framework was copied from.
#
# ⚠️ DO NOT restore `2>/dev/null || true`. That is how this shipped broken:
# both invocations were being killed, the script printed "Done.", and the
# bundle sealed with NO baked bytecode — so the runtime wrote .pyc into the
# sealed bundle, which is precisely the seal break this step exists to prevent.
# The failure was invisible twice over: stderr discarded AND the exit code
# forced to 0.
bake_bytecode() {
    local target="$1"
    "$PYTHON312" -E -s -m compileall -q "$target" >/dev/null 2>&1
    local rc=$?
    # compileall exits 1 when an INDIVIDUAL file fails to compile — some
    # site-packages ship py2-only or deliberately-invalid modules, and that is
    # tolerable. Death by signal is not: 128+n means the interpreter never ran.
    if [ "$rc" -ge 128 ]; then
        echo "  FATAL: compileall on $target died with signal $((rc - 128))." >&2
        echo "  If that is SIGKILL (9), the interpreter's signature is invalid." >&2
        exit 1
    fi
}

echo "  Baking Python bytecode into the bundle (pre-seal)..."
bake_bytecode "$SITE_PACKAGES"
bake_bytecode "$APP_BUNDLE/Contents/Resources/python"

# Assert the ARTIFACT, not the exit code. A green compileall that wrote nothing
# is the same silent failure in a different costume.
BAKED_PYC=$(find "$SITE_PACKAGES" "$APP_BUNDLE/Contents/Resources/python" -name "*.pyc" 2>/dev/null | wc -l | tr -d ' ')
if [ "$BAKED_PYC" -lt 100 ]; then
    echo "  FATAL: only $BAKED_PYC .pyc files baked — expected thousands." >&2
    echo "  The bundle would write bytecode at runtime and break its own seal." >&2
    exit 1
fi
echo "  Done ($BAKED_PYC .pyc baked)."
echo ""

# ============================================================
# Step 5: Relocate absolute external references
# ============================================================
# Everything in the bundle must load from inside the bundle (or from /usr/lib
# and /System, which every Mac has). Until this step existed, the shipped app
# needed the DEVELOPER's Homebrew: the bundled interpreter linked
# /opt/homebrew/Cellar/python@3.12/3.12.13_1/... by absolute path, _sqlite3
# linked /opt/homebrew/opt/sqlite/..., and 78 modules carried an rpath into
# /opt/homebrew/lib.
#
# ⚠️ ORDERING — BOTH DIRECTIONS HAVE ALREADY BITTEN THIS SCRIPT.
#
#   * install_name_tool INVALIDATES a code signature, so this MUST run BEFORE
#     step 6. Step 6 then re-signs every file this touched.
#   * It must run AFTER step 4, because step 4's pip install is what writes the
#     site-packages .so files being relocated.
#   * It must NOT run the bundled interpreter. At this point the bundle is
#     unsigned or stale-signed and macOS SIGKILLs it (CODESIGNING, Code 2
#     Invalid Page). relocate-bundle.sh is otool/install_name_tool only.
#
# It is also placed after the bytecode bake purely so the two mutating steps
# stay adjacent; compileall reads .py and writes .pyc and never touches Mach-O,
# so the two do not interact.
echo "[5/9] Relocating absolute external references..."
./scripts/relocate-bundle.sh "$APP_BUNDLE"

# Fail fast, before spending ten minutes signing a bundle that cannot ship.
# The authoritative run is after signing, on the finished artifact.
./scripts/check-bundle-portability.sh "$APP_BUNDLE"
echo ""

# ============================================================
# Step 6: Code signing (7 phases)
# ============================================================
echo "[6/9] Code signing..."

BUNDLED_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Python.framework"
SP="$BUNDLED_FRAMEWORK/Versions/3.12/lib/python3.12/site-packages"

# Phase 1: Sign .so and .dylib in site-packages
find "$SP" \( -name "*.so" -o -name "*.dylib" \) -type f 2>/dev/null | while read -r file; do
    codesign --sign "$SIGNING_IDENTITY" --force --options runtime --timestamp \
        --entitlements "$PYTHON_ENTITLEMENTS" "$file" 2>/dev/null || true
done
SP_TOTAL=$(find "$SP" \( -name "*.so" -o -name "*.dylib" \) -type f 2>/dev/null | wc -l | tr -d ' ')
echo "  Phase 1: Signed $SP_TOTAL binaries in site-packages"

# Phase 2: Sign lib-dynload
LIB_DYNLOAD="$BUNDLED_FRAMEWORK/Versions/3.12/lib/python3.12/lib-dynload"
if [ -d "$LIB_DYNLOAD" ]; then
    find "$LIB_DYNLOAD" \( -name "*.so" -o -name "*.dylib" \) -type f 2>/dev/null | while read -r file; do
        codesign --sign "$SIGNING_IDENTITY" --force --options runtime --timestamp \
            --entitlements "$PYTHON_ENTITLEMENTS" "$file" 2>/dev/null || true
    done
fi

# Phase 3: Sign remaining Mach-O binaries
find "$BUNDLED_FRAMEWORK" -type f \( -name "*.dylib" -o -perm +111 \) | while read -r file; do
    if file "$file" | grep -q "Mach-O"; then
        codesign --sign "$SIGNING_IDENTITY" --force --options runtime --timestamp \
            --entitlements "$PYTHON_ENTITLEMENTS" "$file" 2>/dev/null || true
    fi
done

# Phase 4: Sign top-level framework dylibs
find "$APP_BUNDLE/Contents/Frameworks" -maxdepth 1 -name "*.dylib" -type f 2>/dev/null | while read -r file; do
    codesign --sign "$SIGNING_IDENTITY" --force --options runtime --timestamp \
        --entitlements "$PYTHON_ENTITLEMENTS" "$file" 2>/dev/null || true
done

# Phase 5: Sign Python.app
if [ -d "$BUNDLED_FRAMEWORK/Versions/3.12/Resources/Python.app" ]; then
    codesign --sign "$SIGNING_IDENTITY" --force --options runtime --timestamp \
        --entitlements "$PYTHON_ENTITLEMENTS" \
        "$BUNDLED_FRAMEWORK/Versions/3.12/Resources/Python.app"
fi

# Phase 6: Sign Python.framework
codesign --sign "$SIGNING_IDENTITY" --force --options runtime --timestamp \
    --entitlements "$PYTHON_ENTITLEMENTS" "$BUNDLED_FRAMEWORK"

# Phase 7: Sign main app
# ⚠️ The BUNDLE line must carry APP_ENTITLEMENTS. Signing the bundle re-signs
# the main executable with --force, which replaces its signature entitlements
# and all: an entitlement given only on the executable line is gone afterwards
# (reproduced with an ad-hoc bundle). Both lines carry it so they agree.
codesign --sign "$SIGNING_IDENTITY" --force --options runtime --timestamp \
    --entitlements "$APP_ENTITLEMENTS" "$APP_BUNDLE/Contents/MacOS/MajiksMusicStudio"
codesign --sign "$SIGNING_IDENTITY" --force --options runtime --timestamp \
    --entitlements "$APP_ENTITLEMENTS" "$APP_BUNDLE"

# Verify
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
echo "  Done."

# The htdemucs separator shells into this interpreter. If it cannot import
# demucs (or numpy, which demucs needs but does not depend on), "Open in Studio"
# is dead in the shipped app and the only symptom is a refusal at runtime. Fail
# the BUILD instead.
#
# ⚠️ THIS MUST RUN AFTER SIGNING, AND THAT IS NOT A STYLE CHOICE. pip has just
# written torch's dylibs into the bundle; on Apple Silicon, loading a dylib
# whose signature is absent or stale is an immediate SIGKILL. Run before
# signing, `import numpy` passes (small, few dylibs) and `import torch` dies
# with "Killed: 9" -- which the loop below would report as "cannot import
# torch", a confident and completely wrong diagnosis. That cost two builds.
#
# A signal death is therefore reported AS a signal death, never as a missing
# module, and stderr is kept rather than discarded so the reason survives.
#
# sqlite3, ssl, lzma and decimal are in this list because step 5 relocated the
# dylibs behind them (libsqlite3 is VENDORED into Frameworks/ by step 5; libssl,
# libcrypto, liblzma and libmpdec by step 3). Each of those is loaded through a
# path this build rewrote and then re-signed, and importing the module is the
# only thing that exercises both at once. `otool -L` says the path is relative;
# this says the file at the end of it is there, signed, and loads.
echo "  Verifying the bundled runtime can separate..."
# transformers checks its own pins when imported; mlx_lm and acestep.llm_inference
# are what the chat LLM and ACE-Step load. 3.6.3 and 3.6.4 passed this list and
# shipped a generator that could not import transformers.
for module in numpy torch demucs sqlite3 ssl lzma decimal transformers mlx_lm acestep.llm_inference; do
    # -B and PYTHONDONTWRITEBYTECODE: the bundle is SEALED by now, and an
    # interpreter that writes a single .pyc into it invalidates the signature
    # of the framework AND the app. Apple rejects the notarization with "the
    # signature of the binary is invalid" -- which is exactly what happened
    # when this check was first moved here.
    probe_err="$(PYTHONDONTWRITEBYTECODE=1 "$FRAMEWORK_PYTHON_BIN" -B -E -s -c "import $module" 2>&1)"; probe_rc=$?
    if [ "$probe_rc" -gt 128 ]; then
        echo "FAIL: probing '$module' was killed by signal $((probe_rc - 128)) (not an import failure)." >&2
        echo "      A SIGKILL here usually means a dylib signature is stale -- check that this step" >&2
        echo "      still runs AFTER codesign, and that the machine is not out of memory." >&2
        exit 1
    elif [ "$probe_rc" -ne 0 ]; then
        echo "FAIL: the bundled Python cannot import $module. The Python backend (generation," >&2
        echo "      stem separation) would be dead in this build." >&2
        echo "      $probe_err" >&2
        exit 1
    fi
done

# The seal must still be intact AFTER probing. If a future edit drops -B, this
# catches it here instead of 20 minutes later in Apple's notary queue.
codesign --verify --strict --verbose=2 "$APP_BUNDLE" || {
    echo "FAIL: probing the bundled runtime broke the code signature (a .pyc was written into the sealed bundle)." >&2
    exit 1
}
echo "  Done."

# HTTPS from this interpreter must not depend on the build machine. libcrypto's
# default CA file is /opt/homebrew/etc/openssl@3/cert.pem, which is present here
# and absent on a customer's Mac. The probe unsets every CA env var so a passing
# result can only come from sitecustomize pointing at the cert we just shipped.
# It runs after signing for the same reason as the import probe above: loading
# _ssl.so before its signature is sealed is a SIGKILL, not a TLS failure.
#
# -B and PYTHONDONTWRITEBYTECODE: a .pyc written into the sealed bundle fails
# notarization. The probe script lives outside the bundle.
echo "  Verifying HTTPS trust comes from the bundle, not Homebrew..."
tls_err="$(
    env -u SSL_CERT_FILE -u REQUESTS_CA_BUNDLE -u CURL_CA_BUNDLE \
        PYTHONDONTWRITEBYTECODE=1 \
        "$FRAMEWORK_PYTHON_BIN" -B "$PWD/scripts/check-bundled-tls.py" 2>&1
)"; tls_rc=$?
if [ "$tls_rc" -ne 0 ]; then
    echo "FAIL: bundled Python cannot verify huggingface.co without the build machine's CA file." >&2
    echo "$tls_err" >&2
    exit 1
fi
echo "$tls_err"
echo ""

# ============================================================
# Step 6b: Portability gate on the FINISHED bundle
# ============================================================
# The authoritative run. Step 5 checked what it had just rewritten; this checks
# what is actually going into the DMG, after signing and after the runtime probe
# — so a future step that copies a Homebrew dylib in cannot slip past.
#
# Read-only (otool and strings), so it cannot break the seal it is inspecting.
echo "  Checking bundle portability (finished artifact)..."
./scripts/check-bundle-portability.sh "$APP_BUNDLE"
echo ""

# ============================================================
# Step 7: Create DMG
# ============================================================
echo "[7/9] Creating DMG..."

for i in {1..10}; do
    hdiutil detach "/Volumes/Majiks Music Studio $i" -force 2>/dev/null || true
done
hdiutil detach "/Volumes/Majiks Music Studio" -force 2>/dev/null || true

rm -f "$DMG_PATH"
TMP_DMG="$DIST_DIR/tmp-release.dmg"
rm -f "$TMP_DMG"

APP_SIZE=$(du -sm "$APP_BUNDLE" | awk '{print $1}')
DMG_SIZE=$((APP_SIZE + 500))

hdiutil create -size ${DMG_SIZE}m -fs HFS+ -volname "Majiks Music Studio" "$TMP_DMG" -quiet
hdiutil attach "$TMP_DMG" -nobrowse -quiet
MOUNT_DIR="/Volumes/Majiks Music Studio"

ditto "$APP_BUNDLE" "$MOUNT_DIR/$APP_NAME.app"
ln -s /Applications "$MOUNT_DIR/Applications"

cat > "$MOUNT_DIR/README.txt" << EOF
MAJIK'S MUSIC STUDIO v${VERSION}
================================

Drag "Majiks Music Studio.app" to Applications, then launch.
The Setup Wizard will guide you through downloading models.

Requirements: macOS 14+, Apple Silicon, 16GB RAM recommended.

Website: https://majiks.studio
Support: support@magicunicorn.tech
Copyright 2026 Magic Unicorn Unconventional Technology & Stuff Inc.
EOF

osascript << 'APPLESCRIPT'
tell application "Finder"
    tell disk "Majiks Music Studio"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 600, 400}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        delay 1
        close
    end tell
end tell
APPLESCRIPT

hdiutil detach "$MOUNT_DIR" -quiet
hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG_PATH" -quiet
rm "$TMP_DMG"

# Sign DMG
codesign --sign "$SIGNING_IDENTITY" --force "$DMG_PATH"
echo "  Done."
echo ""

# ============================================================
# Step 8: Notarize
# ============================================================
# ⚠️ This is gated by --skip-notarize, NOT by --skip-upload. It used to be
# ungated, so every iteration build was submitted to Apple's notary service.
NOTARIZED=false
if [ "$SKIP_NOTARIZE" = true ]; then
    echo "[8/9] Skipping notarization (--skip-notarize). The DMG is signed but NOT notarized:"
    echo "      Gatekeeper will block it on any machine but this one. Do not distribute it."
else
    echo "[8/9] Notarizing with Apple..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "majiks-notary" --wait 2>&1 | tee /tmp/notarize-output.txt

    if grep -q "status: Accepted" /tmp/notarize-output.txt; then
        xcrun stapler staple "$DMG_PATH"
        echo "  Notarized and stapled."
        NOTARIZED=true
    else
        echo "ERROR: Notarization failed. Check output above."
        exit 1
    fi
fi
echo ""

# ============================================================
# Step 9: Upload and notify
# ============================================================
if [ "$SKIP_UPLOAD" = true ]; then
    echo "[9/9] Skipping upload (--skip-upload flag)"
else
    echo "[9/9] Uploading to B2 and notifying majiks.studio..."

    # Upload to Backblaze B2
    DMG_SIZE_BYTES=$(stat -f%z "$DMG_PATH" 2>/dev/null || stat -c%s "$DMG_PATH" 2>/dev/null)
    DMG_SIZE_MB=$((DMG_SIZE_BYTES / 1048576))

    if [ "$CI_MODE" = true ]; then
        b2 account authorize "$B2_APPLICATION_KEY_ID" "$B2_APPLICATION_KEY" 2>&1 | tail -1
    fi

    echo "  Uploading $DMG_NAME ($DMG_SIZE_MB MB) to B2..."
    b2 file upload "$B2_BUCKET" "$DMG_PATH" "$DMG_NAME"
    DOWNLOAD_URL="$B2_DOWNLOAD_BASE/$DMG_NAME"
    echo "  Uploaded: $DOWNLOAD_URL"

    # Notify majiks.studio (matches Broadcaster's working pattern)
    if [ -n "$MAJIKS_STUDIO_VERSION_TOKEN" ]; then
        echo "  Notifying majiks.studio..."
        # Extract changelog from README, sanitize for JSON (escape quotes, collapse to single line)
        RELEASE_NOTES=$(sed -n "/^### v${VERSION}/,/^### v/{/^### v${VERSION}/d;/^### v/d;p;}" README.md \
            | head -20 | sed '/^$/d' \
            | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/ /g' \
            | tr '\n' '|' | sed 's/|/\\n/g')
        [ -z "$RELEASE_NOTES" ] && RELEASE_NOTES="v${VERSION} release"

        HTTP_CODE=$(curl -s -o /tmp/version-update-response.txt -w "%{http_code}" \
            -X POST "https://majiks.studio/api/version/update" \
            -H "Authorization: Bearer $MAJIKS_STUDIO_VERSION_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{
                \"product\": \"music-studio\",
                \"version\": \"$VERSION\",
                \"downloadUrl\": \"$DOWNLOAD_URL\",
                \"changelog\": \"$RELEASE_NOTES\",
                \"size\": \"$DMG_SIZE_MB MB\"
            }")

        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
            echo "  Site updated (HTTP $HTTP_CODE). Changes propagate within 60s."
        else
            echo "  WARNING: Site update returned HTTP $HTTP_CODE"
            cat /tmp/version-update-response.txt 2>/dev/null
            echo ""
        fi
    else
        echo "  MAJIKS_STUDIO_VERSION_TOKEN not set — skipping site notification."
        echo "  Tell the site dev to update version.json manually:"
        echo "    Version: $VERSION"
        echo "    URL: $DOWNLOAD_URL"
        echo "    Size: $DMG_SIZE_MB MB"
    fi
fi

echo ""
echo "======================================"
echo " Majik's Music Studio v$VERSION — DONE"
echo "======================================"
DMG_SIZE_HUMAN=$(du -h "$DMG_PATH" | awk '{print $1}')
echo "  DMG: $DMG_PATH ($DMG_SIZE_HUMAN)"
if [ "$NOTARIZED" = true ]; then
    echo "  Signed: Yes | Notarized: Yes"
else
    echo "  Signed: Yes | Notarized: NO (--skip-notarize) — not distributable"
fi
[ "$SKIP_UPLOAD" = false ] && echo "  Download: $DOWNLOAD_URL"
echo ""
