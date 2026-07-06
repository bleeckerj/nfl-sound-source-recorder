#!/bin/bash
#
# Wraps the CLI in a .app so it has an Info.plist with NSAudioCaptureUsageDescription.
# A bare SwiftPM binary has no Info.plist, so macOS can't show the audio-capture
# permission prompt — and process taps then return SILENCE. Run the bundled inner
# binary (it still behaves like a normal CLI, just with a usage string next to it):
#
#   "dist/NFL Sound Recorder CLI.app/Contents/MacOS/nfl-sound-recorder" --system --file ~/rec.caf
#
set -euo pipefail

CONFIG="release"
APP_NAME="NFL Sound Recorder CLI"
BUNDLE_ID="com.nfl.soundrecorder.cli"
EXECUTABLE="nfl-sound-recorder"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/dist/$APP_NAME.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG" --product "$EXECUTABLE"

echo "▸ Assembling bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BUILD_DIR/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$EXECUTABLE</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.4</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>NFL Sound Recorder captures audio from the apps you choose so it can record and route it.</string>
</dict>
</plist>
PLIST

echo "▸ Code signing (ad-hoc)…"
codesign --force --sign - "$APP_DIR"

echo "✓ Built: $APP_DIR"
echo
echo "  Run it (grant permission on first use):"
echo "  \"$APP_DIR/Contents/MacOS/$EXECUTABLE\" --system --file ~/rec.caf"