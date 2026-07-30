#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIGURATION="${CONFIGURATION:-Debug}"
# Build the Rust core under Xcode's per-build intermediates (DerivedData) when
# invoked from Xcode, mirroring build-ios-rust.sh, so nothing lands in the repo
# working tree. Fall back to $ROOT_DIR/build only for standalone runs outside
# Xcode (where DERIVED_FILE_DIR is unset).
if [[ -n "${DERIVED_FILE_DIR:-}" ]]; then
	DEFAULT_CARGO_TARGET_DIR="$DERIVED_FILE_DIR/rust-macos/tio-bridge"
else
	DEFAULT_CARGO_TARGET_DIR="$ROOT_DIR/build/xcode-rust/tio-bridge"
fi
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$DEFAULT_CARGO_TARGET_DIR}"

# Xcode runs build-phase scripts with a sanitized PATH that drops the
# typical rustup / Homebrew locations. Surface them here so `cargo` is
# discoverable in a fresh GUI Xcode launch without forcing the user to
# customize their environment.
EXTRA_CARGO_PATHS=(
    "$HOME/.cargo/bin"
    "/opt/homebrew/bin"
    "/usr/local/bin"
    "/usr/local/cargo/bin"
)
for candidate in "${EXTRA_CARGO_PATHS[@]}"; do
    if [[ -d "$candidate" && ":$PATH:" != *":$candidate:"* ]]; then
        PATH="$candidate:$PATH"
    fi
done
export PATH

case "$CONFIGURATION" in
	Release)
		CARGO_PROFILE_DIR="release"
		;;
	*)
		CARGO_PROFILE_DIR="debug"
		;;
esac

CORE_DYLIB="$CARGO_TARGET_DIR/$CARGO_PROFILE_DIR/libtwinleaf_core.dylib"
BRIDGE_TOOL="$CARGO_TARGET_DIR/$CARGO_PROFILE_DIR/tio-bridge"
LEGACY_CORE_DYLIB="$ROOT_DIR/rust/tio-bridge/target/$CARGO_PROFILE_DIR/libtwinleaf_core.dylib"
LEGACY_BRIDGE_TOOL="$ROOT_DIR/rust/tio-bridge/target/$CARGO_PROFILE_DIR/tio-bridge"

if command -v cargo >/dev/null 2>&1; then
	CARGO_COMMAND=(
		cargo build
		--manifest-path "$ROOT_DIR/rust/tio-bridge/Cargo.toml"
		--features hdf5
		--target-dir "$CARGO_TARGET_DIR"
	)
	if [[ "$CONFIGURATION" == "Release" ]]; then
		CARGO_COMMAND+=(--release)
	fi
	"${CARGO_COMMAND[@]}"
elif [[ -r "$CORE_DYLIB" && -r "$BRIDGE_TOOL" ]]; then
	echo "warning: cargo was not found; packaging existing Rust $CARGO_PROFILE_DIR artifacts" >&2
elif [[ -r "$LEGACY_CORE_DYLIB" && -r "$LEGACY_BRIDGE_TOOL" ]]; then
	echo "warning: cargo was not found; packaging existing Rust $CARGO_PROFILE_DIR artifacts from rust/tio-bridge/target" >&2
	CORE_DYLIB="$LEGACY_CORE_DYLIB"
	BRIDGE_TOOL="$LEGACY_BRIDGE_TOOL"
else
	echo "error: cargo is required to build the Twinleaf Rust bridge, and no existing $CARGO_PROFILE_DIR artifacts were found" >&2
	exit 1
fi

: "${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}"
: "${FRAMEWORKS_FOLDER_PATH:?FRAMEWORKS_FOLDER_PATH is required}"
: "${EXECUTABLE_FOLDER_PATH:?EXECUTABLE_FOLDER_PATH is required}"

FRAMEWORKS_DIR="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
MACOS_DIR="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH"
mkdir -p "$FRAMEWORKS_DIR" "$MACOS_DIR"

cp "$CORE_DYLIB" "$FRAMEWORKS_DIR/libtwinleaf_core.dylib"
cp "$BRIDGE_TOOL" "$MACOS_DIR/tio-bridge"
chmod +x "$FRAMEWORKS_DIR/libtwinleaf_core.dylib" "$MACOS_DIR/tio-bridge"

# App Store Connect requires a dSYM for every executable in an uploaded
# archive. Release cargo builds emit packed .dSYM bundles (Cargo.toml sets
# split-debuginfo = "packed"); for profiles that leave debug info unpacked,
# generate the bundle here. During Archive builds DWARF_DSYM_FOLDER_PATH
# points inside the .xcarchive's dSYMs directory.
ensure_dsym() {
	local binary="$1"
	if [[ ! -d "$binary.dSYM" ]] && command -v dsymutil >/dev/null 2>&1; then
		dsymutil "$binary" -o "$binary.dSYM" || true
	fi
}

ensure_dsym "$CORE_DYLIB"
ensure_dsym "$BRIDGE_TOOL"

if [[ -n "${DWARF_DSYM_FOLDER_PATH:-}" ]]; then
	mkdir -p "$DWARF_DSYM_FOLDER_PATH"
	for dsym in "$CORE_DYLIB.dSYM" "$BRIDGE_TOOL.dSYM"; do
		if [[ -d "$dsym" ]]; then
			ditto "$dsym" "$DWARF_DSYM_FOLDER_PATH/$(basename "$dsym")"
		fi
	done
fi

sign_rust_artifact() {
	local path="$1"
	local entitlements="${2:-}"

	if ! command -v codesign >/dev/null 2>&1; then
		return
	fi

	local identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
	if [[ -z "$identity" || "$identity" == "-" ]]; then
		identity="${CODE_SIGN_IDENTITY:-}"
	fi
	if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" || -z "$identity" || "$identity" == "-" ]]; then
		identity="-"
	fi

	local args=(--force --sign "$identity")
	if [[ "$identity" != "-" ]]; then
		args+=(--timestamp=none)
	fi
	if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == "YES" ]]; then
		args+=(--options runtime)
	fi
	if [[ -n "$entitlements" ]]; then
		args+=(--entitlements "$entitlements")
	fi
	codesign "${args[@]}" "$path" >/dev/null
}

sign_rust_artifact "$FRAMEWORKS_DIR/libtwinleaf_core.dylib"
# tio-bridge is a standalone executable in the bundle; App Store validation
# requires it to carry the App Sandbox entitlement like the main app.
sign_rust_artifact "$MACOS_DIR/tio-bridge" "$ROOT_DIR/Packaging/TioBridge.entitlements"
