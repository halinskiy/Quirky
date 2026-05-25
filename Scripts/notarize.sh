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
#   build/Quirky-<version>.zip       (signed + stapled, ready for GitHub release)

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

STATUS=$(echo "$SUBMIT_LOG" | awk '/status:/{print $2; exit}')
if [ "$STATUS" != "Accepted" ]; then
    echo "Notarization failed (status: $STATUS)" >&2
    SUB_ID=$(echo "$SUBMIT_LOG" | awk '/id:/{print $2; exit}')
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

# 6. Gatekeeper assess.
echo "==> Gatekeeper assess"
spctl --assess --type execute --verbose=2 "$APP" || true

echo ""
echo "✅ Notarized + stapled."
echo "   App: $APP"
echo "   Zip: $ZIP"
