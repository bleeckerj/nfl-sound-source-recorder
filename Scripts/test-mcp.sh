#!/bin/bash
#
# Protocol smoke test for the MCP server. This does not start an audio tap;
# it verifies the stdio handshake, tool registry, and idle status call.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/debug/nfl-sound-recorder-mcp"
OUTPUT="$(mktemp -t tapdeck-mcp-smoke.XXXXXX)"
trap 'rm -f "$OUTPUT"' EXIT

swift build --product nfl-sound-recorder-mcp >/dev/null

printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"recording_status","arguments":{}}}' \
  | "$BIN" > "$OUTPUT"

grep -q '"serverInfo"' "$OUTPUT"
grep -Eq '"name"[[:space:]]*:[[:space:]]*"pause_recording"' "$OUTPUT"
grep -Eq '"name"[[:space:]]*:[[:space:]]*"resume_recording"' "$OUTPUT"
grep -Eq '"name"[[:space:]]*:[[:space:]]*"set_routing_device"' "$OUTPUT"
grep -Eq '"name"[[:space:]]*:[[:space:]]*"set_recording_levels"' "$OUTPUT"
grep -Eq 'isRecording.*false' "$OUTPUT"

echo "MCP smoke test passed."
