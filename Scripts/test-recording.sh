#!/bin/bash
#
# End-to-end "is it actually recording?" test. Builds the bundled CLI, plays a
# known sound through the system output, captures it for a few seconds, and
# reports whether any signal was captured. Writes to /tmp (not a TCC-protected
# folder) so the file is easy to inspect.
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/dist/TapDeck CLI.app/Contents/MacOS/nfl-sound-recorder"
OUT="/tmp/nfl-test.caf"
SOUND="/System/Library/Sounds/Ping.aiff"

echo "▸ Building bundled CLI…"
"$ROOT/Scripts/make-cli-app.sh" >/dev/null

echo "▸ Playing a test sound through system output for the capture…"
( while :; do afplay "$SOUND"; done ) &
LOOP=$!
trap 'kill "$LOOP" 2>/dev/null; pkill -P "$LOOP" 2>/dev/null; pkill afplay 2>/dev/null' EXIT

echo "▸ Capturing all system audio for 6 seconds…"
echo "  (If a permission prompt appears, click Allow, then re-run this script.)"
echo
"$CLI" --system --duration 6 --file "$OUT"

kill "$LOOP" 2>/dev/null; pkill -P "$LOOP" 2>/dev/null; pkill afplay 2>/dev/null

echo
echo "▸ File written: $OUT"
ls -la "$OUT" 2>/dev/null || true
echo
echo "  Listen back with:  afplay \"$OUT\""
echo "  Inspect with:      afinfo \"$OUT\""
