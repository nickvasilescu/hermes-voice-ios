#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$ROOT/ios/HermesVoice"
DERIVED_DATA="$ROOT/.context/ReadmeDerivedData"
APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/HermesVoice.app"
SIMULATOR_ID="$(bash "$ROOT/scripts/select-ios-simulator.sh")"

mkdir -p "$ROOT/docs/images" "$ROOT/.context"
cd "$PROJECT_ROOT"
xcodegen generate
xcodebuild build \
  -project HermesVoice.xcodeproj \
  -scheme HermesVoice \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  PRODUCT_BUNDLE_IDENTIFIER=com.example.HermesVoice

xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl install "$SIMULATOR_ID" "$APP"
xcrun simctl status_bar "$SIMULATOR_ID" override \
  --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
trap 'xcrun simctl status_bar "$SIMULATOR_ID" clear >/dev/null 2>&1 || true' EXIT

capture() {
  local mode="$1" output="$2"
  xcrun simctl launch --terminate-running-process \
    "$SIMULATOR_ID" com.example.HermesVoice "--readme-demo-$mode"
  sleep 2
  xcrun simctl io "$SIMULATOR_ID" screenshot "$output"
}

capture active "$ROOT/docs/images/hermes-voice-active.png"
capture paused "$ROOT/docs/images/hermes-voice-paused.png"

echo "README screenshots updated in docs/images"
