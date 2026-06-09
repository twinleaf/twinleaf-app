#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$BUILD_DIR/xcode-app}"
APP_DIR="${APP_DIR:-$BUILD_DIR/Twinleaf.app}"
PROJECT="$ROOT_DIR/Twinleaf.xcodeproj"
SCHEME="Twinleaf"

case "$CONFIGURATION" in
	debug|Debug)
		XCODE_CONFIGURATION="Debug"
		;;
	release|Release)
		XCODE_CONFIGURATION="Release"
		;;
	*)
		echo "usage: $0 [debug|release]" >&2
		exit 64
		;;
esac

echo "Building Twinleaf.app with Xcode ($XCODE_CONFIGURATION)"
xcodebuild \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration "$XCODE_CONFIGURATION" \
	-destination "generic/platform=macOS" \
	-derivedDataPath "$DERIVED_DATA_PATH" \
	-hideShellScriptEnvironment \
	build

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$XCODE_CONFIGURATION/Twinleaf.app"
[[ -d "$BUILT_APP" ]] || {
	echo "error: built app not found: $BUILT_APP" >&2
	exit 1
}

if [[ -e "$APP_DIR" ]]; then
	chmod -R u+w "$APP_DIR" 2>/dev/null || true
	if ! rm -rf "$APP_DIR"; then
		echo "error: failed to replace $APP_DIR" >&2
		echo "It may contain files owned by another user; move or remove it, or set APP_DIR to a different path." >&2
		exit 1
	fi
fi
mkdir -p "$(dirname "$APP_DIR")"
ditto "$BUILT_APP" "$APP_DIR"

echo "Built $APP_DIR"
echo "Launch with: open \"$APP_DIR\""
