#!/bin/bash
#
# Builds ColoringBook.app from the SPM executable. If CODESIGN_IDENTITY is set,
# the bundle is code-signed with the hardened runtime and the camera
# entitlement. Otherwise an ad-hoc signature is applied so the app launches
# locally during dev but will trigger Gatekeeper warnings elsewhere.
#
#   # dev (unsigned, local only)
#   bash scripts/build-app.sh
#
#   # release (signed, notarize-ready)
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#       bash scripts/build-app.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
echo "→ Compiling ColoringBook ($CONFIG)…"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/ColoringBook"
if [[ ! -x "$BIN" ]]; then
    echo "Build failed: $BIN not found or not executable." >&2
    exit 1
fi

APP="dist/ColoringBook.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ColoringBook"
cp Info.plist "$APP/Contents/Info.plist"
printf "APPL????" > "$APP/Contents/PkgInfo"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "→ Signing with identity: $CODESIGN_IDENTITY"
    codesign --force --deep --options runtime \
        --entitlements Entitlements.plist \
        --timestamp \
        --sign "$CODESIGN_IDENTITY" \
        "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    echo "✓ Signed $APP"
else
    # Ad-hoc sign so the bundle is acceptable to TCC on the local machine.
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
    echo "✓ Ad-hoc signed $APP (dev only; will fail Gatekeeper elsewhere)"
fi

echo "  Open with: open $APP"
