#!/usr/bin/env bash
# Build + sign + notarize + staple Quirky for direct distribution.
#
# Requirements (one-time setup, see apple-developer.md):
#   1. Developer ID Application identity in login.keychain-db.
#   2. Notarytool keychain profile (default: Corder — shared across all
#      Mac products of this developer):
#        xcrun notarytool store-credentials Corder \
#            --apple-id "hegona3@gmail.com" \
#            --team-id "PDB9JGGX74" \
#            --password "<app-specific password>"
#      Override with: NOTARY_PROFILE=<other> ./Scripts/notarize.sh
#
# Outputs:
#   build/Quirky.app                 (signed + stapled)
#   build/Quirky-<version>.zip       (signed + stapled — Sparkle auto-update payload)
#   build/Quirky-<version>.dmg       (signed + stapled — primary download)
#   build/Quirky.dmg                 (copy of above, used by /releases/latest/download/Quirky.dmg)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NOTARY_PROFILE="${NOTARY_PROFILE:-Corder}"
QUIRKY_SIGN_IDENTITY="${QUIRKY_SIGN_IDENTITY:-Developer ID Application: Kostiantyn Halynskyi (PDB9JGGX74)}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-PDB9JGGX74}"

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Quirky.app"

# 1. Build (always Release, always signed).
BUILD_CONFIG=Release \
QUIRKY_SIGN_IDENTITY="$QUIRKY_SIGN_IDENTITY" \
DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
"$ROOT/Scripts/build.sh"

# 2. Read version for output naming.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$BUILD_DIR/Quirky-$VERSION.zip"

# 3. Pack into ditto-zip (preserves bundle structure, what notarytool wants).
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting $ZIP to Apple notary service (profile: $NOTARY_PROFILE)"
SUBMIT_LOG=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)
echo "$SUBMIT_LOG"

# notarytool prints both "Current status: <foo>" progress lines and a
# final "status: Accepted" once processing finishes. Grab the LAST
# non-progress status line so we don't read "In Progress" as the final.
STATUS=$(echo "$SUBMIT_LOG" | awk '/^[[:space:]]*status:/{val=$2} END{print val}')
if [ "$STATUS" != "Accepted" ]; then
    echo "Notarization failed (status: $STATUS)" >&2
    SUB_ID=$(echo "$SUBMIT_LOG" | awk '/^[[:space:]]*id:/{val=$2} END{print val}')
    if [ -n "$SUB_ID" ]; then
        echo "==> Fetching submission log for $SUB_ID"
        xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" || true
    fi
    exit 1
fi

# 4. Staple the ticket onto the .app so it works offline.
echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 5. Re-zip the stapled bundle.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 6. Gatekeeper assess (.app).
echo "==> Gatekeeper assess (.app)"
spctl --assess --type execute --verbose=2 "$APP" || true

# 7. Build a styled DMG installer with drag-to-Applications layout, sign,
#    notarize, and staple. Produced after the .app is fully signed +
#    stapled so the bundle inside the DMG is already trusted.
DMG="$BUILD_DIR/Quirky-$VERSION.dmg"
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_BG_SRC="$ROOT/Scripts/dmg-background.svg"
DMG_BG_PNG_1X="$BUILD_DIR/dmg-bg-1x.png"
DMG_BG_PNG_2X="$BUILD_DIR/dmg-bg.png"
DMG_BG_TIFF="$BUILD_DIR/dmg-bg.tiff"

if [ ! -f "$DMG_BG_SRC" ]; then
    echo "Missing $DMG_BG_SRC — DMG background source not found" >&2
    exit 1
fi
if ! command -v rsvg-convert >/dev/null; then
    echo "rsvg-convert not found (brew install librsvg)" >&2
    exit 1
fi
if ! command -v create-dmg >/dev/null; then
    echo "create-dmg not found (brew install create-dmg)" >&2
    exit 1
fi

rsvg-convert -w 1080 -h 800 "$DMG_BG_SRC" -o "$DMG_BG_PNG_2X"
rsvg-convert -w 540 -h 400 "$DMG_BG_SRC" -o "$DMG_BG_PNG_1X"
tiffutil -cathidpicheck "$DMG_BG_PNG_1X" "$DMG_BG_PNG_2X" -out "$DMG_BG_TIFF" >/dev/null

rm -rf "$DMG_STAGING" "$DMG"
mkdir -p "$DMG_STAGING"
cp -R "$APP" "$DMG_STAGING/Quirky.app"

echo "==> Building styled DMG"
create-dmg \
    --volname "Quirky" \
    --background "$DMG_BG_TIFF" \
    --window-pos 240 120 \
    --window-size 540 400 \
    --icon-size 128 \
    --icon "Quirky.app" 140 200 \
    --hide-extension "Quirky.app" \
    --app-drop-link 400 200 \
    --no-internet-enable \
    --skip-jenkins \
    --codesign "$QUIRKY_SIGN_IDENTITY" \
    "$DMG" "$DMG_STAGING/"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type install --verbose=2 "$DMG" || true

# 8. Mirror as Quirky.dmg (unversioned) so /releases/latest/download/Quirky.dmg
#    keeps working as a stable URL across releases.
cp "$DMG" "$BUILD_DIR/Quirky.dmg"

echo ""
echo "✅ Notarized + stapled."
echo "   App: $APP"
echo "   Zip: $ZIP"
echo "   DMG: $DMG"
echo "   DMG (stable URL alias): $BUILD_DIR/Quirky.dmg"
