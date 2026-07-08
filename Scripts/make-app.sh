#!/bin/bash
#
# Builds the menu bar executable and wraps it in a proper .app bundle:
#   • Info.plist with LSUIElement (menu-bar only, no Dock icon)
#   • NSAudioCaptureUsageDescription / NSMicrophoneUsageDescription for the prompts
#   • Developer ID signature + Hardened Runtime + entitlements when a Developer ID
#     Application cert is present (required for notarization / distribution); falls
#     back to an ad-hoc signature for local dev on machines without the cert.
#
# Override the identity with SIGN_IDENTITY="Developer ID Application: …".
# For a notarized, stapled DMG to hand to others, run Scripts/release-app.sh.
#
# Output: dist/TapDeck.app
#
set -euo pipefail

CONFIG="release"
APP_NAME="TapDeck"
BUNDLE_ID="com.nfl.tapdeck"
EXECUTABLE="NFLSoundRecorderApp"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/dist/$APP_NAME.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG" --product "$EXECUTABLE"

echo "▸ Assembling bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"

# App icon — the skeuomorphic cassette. Rebuild it if missing so a fresh clone
# still gets an icon without a separate step.
ICON_SRC="$ROOT/Resources/AppIcon.icns"
[ -f "$ICON_SRC" ] || "$ROOT/Scripts/make-icon.sh"
cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.4</string>
    <!-- Menu-bar-only agent app: no Dock icon, no main window. -->
    <key>LSUIElement</key>               <true/>
    <!-- Shown in the permission prompt when the app first taps audio. -->
    <key>NSAudioCaptureUsageDescription</key>
    <string>TapDeck captures audio from the apps you choose so it can record and route it.</string>
    <!-- Shown in the permission prompt when the app first records the microphone. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>TapDeck records your microphone, on its own or mixed into the captured app/system audio.</string>
</dict>
</plist>
PLIST

ENTITLEMENTS="$ROOT/Scripts/TapDeck.entitlements"
# Prefer a Developer ID Application identity (auto-detected, overridable via
# SIGN_IDENTITY). Fall back to ad-hoc so a fresh clone without the cert still builds.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')}"

if [ -n "$IDENTITY" ]; then
    echo "▸ Code signing (Developer ID + Hardened Runtime)…"
    echo "  identity: $IDENTITY"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" "$APP_DIR"
else
    echo "▸ Code signing (ad-hoc — no Developer ID Application cert found)…"
    codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP_DIR"
fi

echo "▸ Verifying signature…"
codesign --verify --strict --verbose=2 "$APP_DIR"

echo "✓ Built: $APP_DIR"
echo
echo "  Launch it:   open \"$APP_DIR\""
echo "  Then grant:  System Settings ▸ Privacy & Security ▸ Microphone → enable \"$APP_NAME\""
