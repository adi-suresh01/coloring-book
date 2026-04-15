#!/bin/bash
#
# Packages dist/ColoringBook.app into ColoringBook.dmg and (if credentials
# available) signs + notarizes + staples the DMG so it opens without
# Gatekeeper warnings. Run AFTER scripts/build-app.sh.
#
#   # build + package + notarize + staple
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="coloringbook-notary" \
#       bash scripts/make-dmg.sh
#
#   # unsigned DMG for internal testing
#   bash scripts/make-dmg.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/ColoringBook.app"
DMG="dist/ColoringBook.dmg"

if [[ ! -d "$APP" ]]; then
    echo "No $APP — run scripts/build-app.sh first." >&2
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "create-dmg missing. Install with: brew install create-dmg" >&2
    exit 1
fi

rm -f "$DMG"

echo "→ Building DMG…"
create-dmg \
    --volname "Coloring Book" \
    --window-size 520 320 \
    --icon-size 96 \
    --icon "ColoringBook.app" 130 160 \
    --app-drop-link 380 160 \
    "$DMG" \
    "$APP"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "→ Signing DMG with: $CODESIGN_IDENTITY"
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "→ Submitting to Apple notary service (this can take 1–5 minutes)…"
    xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    echo "→ Stapling notarization ticket…"
    xcrun stapler staple "$DMG"
    echo "→ Verifying the stapled DMG…"
    spctl --assess --type open --context context:primary-signature -vv "$DMG" || {
        echo "spctl rejected the DMG. Inspect the notarization log:" >&2
        xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" | head -5 >&2
        exit 1
    }
    echo "✓ Notarized + stapled: $DMG"
else
    echo "✓ Built $DMG (unsigned / unnotarized — will trigger Gatekeeper)"
fi
