#!/bin/bash
#
# Renders the skeuomorphic cassette app icon and packs it into an .icns.
#
# Output: Resources/AppIcon.icns  (committed; make-app.sh folds it into the bundle)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/.build/AppIcon.iconset"
OUT="$ROOT/Resources/AppIcon.icns"

echo "▸ Rendering cassette artwork…"
rm -rf "$ICONSET"
swift "$ROOT/Scripts/generate-icon.swift" "$ICONSET"

echo "▸ Packing .icns…"
mkdir -p "$ROOT/Resources"
iconutil -c icns "$ICONSET" -o "$OUT"

echo "✓ Built: $OUT"
