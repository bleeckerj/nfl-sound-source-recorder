#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/dist/TapDeck Speaker Check.app"
echo "Building speaker qualification command…"
cd "$ROOT"
swift build --product tapdeck-speaker-check
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$ROOT/.build/debug/tapdeck-speaker-check" "$APP_DIR/Contents/MacOS/"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>TapDeck Speaker Check</string>
<key>CFBundleIdentifier</key><string>com.nfl.tapdeck.speaker-check</string>
<key>CFBundleExecutable</key><string>tapdeck-speaker-check</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key>
<string>TapDeck compares raw and echo-cancelled microphone audio in a short speaker qualification test.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
echo "Built: $APP_DIR"
