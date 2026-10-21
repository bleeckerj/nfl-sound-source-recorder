#!/bin/bash
#
# Bundles the MCP server into a .app so it has a stable identity + Info.plist.
# An MCP stdio server is launched as a bare binary, but wrapping it gives it:
#   • NSAudioCaptureUsageDescription (required, or the audio-capture API can crash)
#   • a bundle identifier / usage string macOS shows in the permission prompt
#   • LSBackgroundOnly (no Dock icon, no UI)
#
# Point your MCP client at the inner executable:
#   dist/TapDeck MCP.app/Contents/MacOS/nfl-sound-recorder-mcp
#
set -euo pipefail

CONFIG="release"
for argument in "$@"; do
    case "$argument" in
        --debug) CONFIG="debug" ;;
        *) echo "Unknown option: $argument" >&2; exit 1 ;;
    esac
done
APP_NAME="TapDeck MCP"
BUNDLE_ID="com.nfl.tapdeck.mcp"
EXECUTABLE="nfl-sound-recorder-mcp"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/dist/$APP_NAME.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG" --product "$EXECUTABLE"

echo "▸ Assembling bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BUILD_DIR/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"
bash "$ROOT/Scripts/copy-third-party-licenses.sh" "$APP_DIR/Contents/Resources"

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
    <key>LSBackgroundOnly</key>          <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>TapDeck MCP captures audio from the apps you choose so it can record and route it.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>TapDeck MCP records your microphone, on its own or mixed into the captured app/system audio.</string>
</dict>
</plist>
PLIST

echo "▸ Code signing (ad-hoc)…"
codesign --force --sign - "$APP_DIR"

INNER="$APP_DIR/Contents/MacOS/$EXECUTABLE"
echo "✓ Built: $APP_DIR"
echo
echo "  Point your MCP client 'command' at:"
echo "  $INNER"