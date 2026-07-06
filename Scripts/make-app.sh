#!/bin/bash
#
# Builds the menu bar executable and wraps it in a proper .app bundle:
#   • Info.plist with LSUIElement (menu-bar only, no Dock icon)
#   • NSAudioCaptureUsageDescription so macOS can grant Audio Recording permission
#   • ad-hoc code signature (fine for local/dev use)
#
# Output: dist/NFL Sound Recorder.app
#
set -euo pipefail

CONFIG="release"
APP_NAME="NFL Sound Recorder"
BUNDLE_ID="com.nfl.soundrecorder"
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

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$EXECUTABLE</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.4</string>
    <!-- Menu-bar-only agent app: no Dock icon, no main window. -->
    <key>LSUIElement</key>               <true/>
    <!-- Shown in the permission prompt when the app first taps audio. -->
    <key>NSAudioCaptureUsageDescription</key>
    <string>NFL Sound Recorder captures audio from the apps you choose so it can record and route it.</string>
</dict>
</plist>
PLIST

echo "▸ Code signing (ad-hoc)…"
codesign --force --sign - "$APP_DIR"

echo "✓ Built: $APP_DIR"
echo
echo "  Launch it:   open \"$APP_DIR\""
echo "  Then grant:  System Settings ▸ Privacy & Security ▸ Microphone → enable \"$APP_NAME\""
