#!/usr/bin/env bash
# Build Quirky.app from source into ./build/Quirky.app
# Default config: Release. Override: BUILD_CONFIG=Debug ./Scripts/build.sh
# Default identity for Release: Developer ID Application (from apple-developer.md).
# Override: QUIRKY_SIGN_IDENTITY="Apple Development" ./Scripts/build.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Release}"
QUIRKY_SIGN_IDENTITY="${QUIRKY_SIGN_IDENTITY:-Developer ID Application: Kostiantyn Halynskyi (PDB9JGGX74)}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-PDB9JGGX74}"

BUILD_DIR="$ROOT/build"
DD_DIR="$BUILD_DIR/DerivedData"
OUT_DIR="$BUILD_DIR"
APP_NAME="Quirky.app"

rm -rf "$BUILD_DIR"
mkdir -p "$DD_DIR" "$OUT_DIR"

echo "==> xcodebuild Quirky ($BUILD_CONFIG)"
xcodebuild \
    -project Quirky.xcodeproj \
    -scheme Quirky \
    -configuration "$BUILD_CONFIG" \
    -derivedDataPath "$DD_DIR" \
    CODE_SIGN_IDENTITY="$QUIRKY_SIGN_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    -quiet \
    build

PRODUCT_PATH="$DD_DIR/Build/Products/$BUILD_CONFIG/$APP_NAME"
if [ ! -d "$PRODUCT_PATH" ]; then
    echo "Build artifact missing: $PRODUCT_PATH" >&2
    exit 1
fi

cp -R "$PRODUCT_PATH" "$OUT_DIR/$APP_NAME"
echo "==> Built: $OUT_DIR/$APP_NAME"

# Strip quarantine (only matters if you signed locally without notarization yet).
xattr -dr com.apple.quarantine "$OUT_DIR/$APP_NAME" 2>/dev/null || true

# Re-sign every nested component of Sparkle.framework with Developer ID +
# hardened runtime + secure timestamp. Xcode's automatic signing of SPM-resolved
# frameworks sometimes leaves these as ad-hoc or with stale signatures, which
# Apple's notary service rejects ("not signed with a valid Developer ID
# certificate" / "signature does not include a secure timestamp").
APP="$OUT_DIR/$APP_NAME"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    echo "==> Re-signing Sparkle.framework nested components"
    SPARKLE_VER="$SPARKLE/Versions/B"
    if [ ! -d "$SPARKLE_VER" ]; then
        SPARKLE_VER="$(ls -d "$SPARKLE"/Versions/[A-Z] 2>/dev/null | head -n1)"
    fi
    SIGN_OPTS=(--force --options runtime --timestamp --sign "$QUIRKY_SIGN_IDENTITY")
    for target in \
        "$SPARKLE_VER/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
        "$SPARKLE_VER/XPCServices/Installer.xpc" \
        "$SPARKLE_VER/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
        "$SPARKLE_VER/XPCServices/Downloader.xpc" \
        "$SPARKLE_VER/Updater.app/Contents/MacOS/Updater" \
        "$SPARKLE_VER/Updater.app" \
        "$SPARKLE_VER/Autoupdate" \
        "$SPARKLE_VER/Sparkle" \
        "$SPARKLE"; do
        if [ -e "$target" ]; then
            codesign "${SIGN_OPTS[@]}" "$target"
        fi
    done

    # Re-sign the main executable + the .app bundle on top of the freshly
    # signed framework so the embedded code-directory hashes match.
    ENTITLEMENTS="$ROOT/Quirky/Quirky.entitlements"
    codesign "${SIGN_OPTS[@]}" "$APP/Contents/MacOS/Quirky"
    codesign "${SIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
fi

echo "==> codesign verify"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | sed -n '1,12p'
echo "==> Done. Run Scripts/notarize.sh to notarize + staple."
