#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-${CONFIGURATION:-debug}}"
MODE="${IOS_RUST_MODE:-xcframework}"
DEFAULT_OUT_DIR="$ROOT_DIR/build/rust-ios"
DEFAULT_CARGO_TARGET_DIR="$DEFAULT_OUT_DIR/tio-bridge"
if [[ "$MODE" == "staticlib" && -n "${BUILT_PRODUCTS_DIR:-}" ]]; then
	DEFAULT_OUT_DIR="$BUILT_PRODUCTS_DIR"
	DEFAULT_CARGO_TARGET_DIR="${DERIVED_FILE_DIR:-$BUILT_PRODUCTS_DIR}/rust-ios/tio-bridge"
fi
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$DEFAULT_CARGO_TARGET_DIR}"
OUT_DIR="${OUT_DIR:-$DEFAULT_OUT_DIR}"
HEADER_DIR="${HEADER_DIR:-$ROOT_DIR/rust/tio-bridge/include}"
XCFRAMEWORK_PATH="${XCFRAMEWORK_PATH:-$OUT_DIR/TwinleafCore.xcframework}"
TARGETS="${IOS_RUST_TARGETS:-aarch64-apple-ios aarch64-apple-ios-sim}"
FEATURES="${IOS_RUST_FEATURES:-firmware}"

append_target() {
	case " $TARGETS " in
		*" $1 "*)
			;;
		*)
			TARGETS="${TARGETS:+$TARGETS }$1"
			;;
	esac
}

if [[ -d "$HOME/.cargo/bin" && ":$PATH:" != *":$HOME/.cargo/bin:"* ]]; then
	PATH="$HOME/.cargo/bin:$PATH"
	export PATH
fi

case "$CONFIGURATION" in
	debug|Debug)
		CARGO_PROFILE_DIR="debug"
		;;
	release|Release)
		CARGO_PROFILE_DIR="release"
		RELEASE_FLAG="--release"
		;;
	*)
		echo "usage: $0 [debug|release]" >&2
		exit 64
		;;
esac

case "$MODE" in
	xcframework|staticlib)
		;;
	*)
		echo "error: unsupported IOS_RUST_MODE: $MODE" >&2
		exit 64
		;;
esac

if [[ "$MODE" == "staticlib" && -z "${IOS_RUST_TARGETS:-}" ]]; then
	TARGETS=""
	case "${SDK_NAME:-}" in
		iphoneos*)
			append_target aarch64-apple-ios
			;;
		iphonesimulator*)
			for arch in ${ARCHS:-arm64}; do
				case "$arch" in
					arm64)
						append_target aarch64-apple-ios-sim
						;;
					x86_64)
						append_target x86_64-apple-ios
						;;
					*)
						echo "error: unsupported simulator Rust arch: $arch" >&2
						exit 64
						;;
				esac
			done
			;;
		"")
			echo "error: IOS_RUST_MODE=staticlib requires SDK_NAME or IOS_RUST_TARGETS" >&2
			exit 64
			;;
		*)
			echo "error: unsupported SDK_NAME for iOS Rust staticlib: $SDK_NAME" >&2
			exit 64
			;;
	esac
fi

require_command() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "error: required command not found: $1" >&2
		exit 1
	}
}

require_command cargo
require_command xcodebuild
if [[ "$MODE" == "staticlib" ]]; then
	require_command lipo
fi

mkdir -p "$OUT_DIR"

cargo_args=(
	build
	--manifest-path "$ROOT_DIR/rust/tio-bridge/Cargo.toml"
	--lib
	--no-default-features
	--target-dir "$CARGO_TARGET_DIR"
)
if [[ -n "${RELEASE_FLAG:-}" ]]; then
	cargo_args+=("$RELEASE_FLAG")
fi
if [[ -n "$FEATURES" ]]; then
	cargo_args+=(--features "$FEATURES")
fi

xcframework_args=(-create-xcframework)
static_lib_count=0
static_libs=()
for target in $TARGETS; do
	echo "Building Twinleaf Rust core for $target ($CONFIGURATION)"
	if ! cargo "${cargo_args[@]}" --target "$target"; then
		echo "error: failed to build Rust target $target" >&2
		echo "hint: install the Rust standard library for this target, for example:" >&2
		echo "      rustup target add $target" >&2
		exit 1
	fi

	static_lib="$CARGO_TARGET_DIR/$target/$CARGO_PROFILE_DIR/libtwinleaf_core.a"
	if [[ ! -r "$static_lib" ]]; then
		echo "error: expected static library was not produced: $static_lib" >&2
		exit 1
	fi
	static_lib_count=$((static_lib_count + 1))
	if [[ "$MODE" == "staticlib" ]]; then
		static_libs+=("$static_lib")
		continue
	fi
	xcframework_args+=(-library "$static_lib" -headers "$HEADER_DIR")
done

if [[ "$MODE" == "staticlib" ]]; then
	if [[ "$static_lib_count" -eq 1 ]]; then
		cp "${static_libs[0]}" "$OUT_DIR/libtwinleaf_core.a"
	else
		lipo -create "${static_libs[@]}" -output "$OUT_DIR/libtwinleaf_core.a"
	fi
	echo "Built $OUT_DIR/libtwinleaf_core.a"
	exit 0
fi

rm -rf "$XCFRAMEWORK_PATH"
echo "Creating $XCFRAMEWORK_PATH"
xcodebuild "${xcframework_args[@]}" -output "$XCFRAMEWORK_PATH"

echo "Built $XCFRAMEWORK_PATH"
