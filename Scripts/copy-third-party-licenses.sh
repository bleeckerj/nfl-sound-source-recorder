#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="$1/ThirdPartyLicenses"
mkdir -p "$DESTINATION"
cp "$ROOT/Vendor/WebRTCAudio/WebRTC-COPYING" "$DESTINATION/WebRTC-COPYING"
cp "$ROOT/Vendor/WebRTCAudio/Abseil-LICENSE" "$DESTINATION/Abseil-LICENSE"
cp -R "$ROOT/Vendor/WebRTCAudio/Licenses" "$DESTINATION/"
