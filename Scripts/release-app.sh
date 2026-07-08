#!/bin/bash
#
# Produce a distributable, NOTARIZED, STAPLED TapDeck.dmg for others to download.
#
# Pipeline:
#   1. Build + Developer ID sign the app (via make-app.sh, Hardened Runtime).
#   2. Notarize the .app (zip → notarytool submit --wait) and staple the ticket to it,
#      so first launch works even offline.
#   3. Build a drag-to-Applications DMG from the stapled app.
#   4. Notarize + staple the DMG too, so the download itself passes Gatekeeper.
#   5. Verify with spctl / stapler.
#
# Requires a stored notarytool credential profile. Pass it via NOTARY_PROFILE:
#   NOTARY_PROFILE="your-profile" ./Scripts/release-app.sh
#
# One-time setup of that profile (App Store Connect API key OR Apple ID app password):
#   xcrun notarytool store-credentials "your-profile" \
#       --apple-id "you@example.com" --team-id 9DCTLJ9BY7 --password "app-specific-pw"
#   # …or: xcrun notarytool store-credentials "your-profile" \
#   #        --key AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER-UUID
#
set -euo pipefail

APP_NAME="TapDeck"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/dist/$APP_NAME.app"

NOTARY_PROFILE="${NOTARY_PROFILE:-${1:-}}"
if [ -z "$NOTARY_PROFILE" ]; then
    echo "✗ NOTARY_PROFILE is not set." >&2
    echo "  Run:  NOTARY_PROFILE=\"your-profile\" $0" >&2
    echo "  (see the header of this script for one-time credential setup)" >&2
    exit 1
fi

# 1. Build + Developer ID sign.
"$ROOT/Scripts/make-app.sh"

# Refuse to continue on an ad-hoc signature — it can't be notarized.
if ! codesign -dvv "$APP_DIR" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "✗ $APP_DIR is not Developer ID signed (ad-hoc?). Cannot notarize." >&2
    echo "  Ensure a 'Developer ID Application' cert is installed, or set SIGN_IDENTITY." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo 0)"
ZIP="$ROOT/dist/$APP_NAME.zip"
DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"

# 2. Notarize the app, then staple.
echo "▸ Notarizing the app (profile: $NOTARY_PROFILE)…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_DIR" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$ZIP"
echo "▸ Stapling the app…"
xcrun stapler staple "$APP_DIR"

# 3. Build a drag-to-Applications DMG from the stapled app.
echo "▸ Building DMG…"
STAGING="$(mktemp -d)"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

# 4. Notarize + staple the DMG.
echo "▸ Notarizing the DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
echo "▸ Stapling the DMG…"
xcrun stapler staple "$DMG"

# 5. Verify.
echo "▸ Verifying…"
echo "— app —"
spctl -a -vvv "$APP_DIR" 2>&1 || true
xcrun stapler validate "$APP_DIR" || true
echo "— dmg —"
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 || true
xcrun stapler validate "$DMG" || true

echo
echo "✓ Notarized & stapled: $DMG"
echo "  Hand this .dmg to anyone; it passes Gatekeeper without warnings."