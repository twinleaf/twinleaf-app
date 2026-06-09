#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/xcode-pad-sim}"
MODULE_CACHE_PATH="${MODULE_CACHE_PATH:-$ROOT_DIR/build/ModuleCache}"
SIMCTL_DEVICE="${SIMCTL_DEVICE:-booted}"
BUNDLE_ID="${BUNDLE_ID:-com.twinleaf.TwinleafPad}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphonesimulator/Twinleaf.app"
SCREENSHOT_DIR="${SCREENSHOT_DIR:-$ROOT_DIR/build/ipad-simulator-smoke}"
SCREENSHOT_PATH="${SCREENSHOT_PATH:-$SCREENSHOT_DIR/Twinleaf.png}"

mkdir -p "$SCREENSHOT_DIR"

echo "Building Twinleaf for iPad simulator"
xcodebuild \
	-project "$ROOT_DIR/Twinleaf.xcodeproj" \
	-scheme Twinleaf \
	-configuration "$CONFIGURATION" \
	-sdk iphonesimulator \
	-destination "generic/platform=iOS Simulator" \
	-derivedDataPath "$DERIVED_DATA_PATH" \
	CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_PATH" \
	CODE_SIGNING_ALLOWED=NO \
	build \
	-hideShellScriptEnvironment

if [[ ! -d "$APP_PATH" ]]; then
	echo "error: expected simulator app was not produced: $APP_PATH" >&2
	exit 1
fi

if ! xcrun simctl bootstatus "$SIMCTL_DEVICE" -b >/dev/null 2>&1; then
	echo "error: no booted iPad simulator found. Boot one in Simulator.app, or set SIMCTL_DEVICE to a device UUID." >&2
	exit 69
fi

echo "Installing Twinleaf into simulator: $SIMCTL_DEVICE"
xcrun simctl install "$SIMCTL_DEVICE" "$APP_PATH"

echo "Launching $BUNDLE_ID"
xcrun simctl launch --terminate-running-process "$SIMCTL_DEVICE" "$BUNDLE_ID"

sleep 1
xcrun simctl io "$SIMCTL_DEVICE" screenshot "$SCREENSHOT_PATH"
echo "Saved screenshot: $SCREENSHOT_PATH"

echo "Recent Twinleaf app-specific log output:"
xcrun simctl spawn "$SIMCTL_DEVICE" log show --last 30s --style compact \
	--predicate 'process == "Twinleaf" AND (eventMessage CONTAINS[c] "[Twinleaf]" OR eventMessage CONTAINS[c] "Failed to open log file" OR eventMessage CONTAINS[c] "Log file is empty" OR eventMessage CONTAINS[c] "org.hdfgroup.hdf5" OR eventMessage CONTAINS[c] "Fatal error")' || true
