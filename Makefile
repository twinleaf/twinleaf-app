# SPDX-License-Identifier: Apache-2.0
#
# Single entry point for building the Twinleaf app.
#
# Every build target drives the Xcode project through xcodebuild, so `make`
# produces exactly what Xcode's Build & Run produces: the Rust core is compiled
# by the project's own "Build Rust core" run-script phase
# (scripts/xcode-build-rust.sh on macOS, scripts/build-ios-rust.sh on iOS),
# not by a separate build system. There is no SwiftPM package to drift out of
# sync — the .xcodeproj is the one source of truth.

PROJECT   := Twinleaf.xcodeproj
SCHEME    := Twinleaf
CONFIG    := Debug
BUILD_DIR := build
APP       := $(BUILD_DIR)/Twinleaf.app

.DEFAULT_GOAL := build

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

# The Rust core lives in the vendored twinleaf-rust git submodule and is
# compiled by Xcode's run-script phase during the app build. All this step has
# to guarantee is that the submodule is checked out and a Rust toolchain is
# present; Xcode/cargo does the actual Rust compile as part of `build`.
.PHONY: deps
deps:
	@command -v cargo >/dev/null 2>&1 || { \
		echo "error: cargo (Rust toolchain) not found — install from https://rustup.rs" >&2; \
		exit 1; }
	@git submodule update --init --recursive

# iPad builds cross-compile the Rust core; install those std libraries once.
.PHONY: ios-deps
ios-deps: deps
	rustup target add aarch64-apple-ios aarch64-apple-ios-sim

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

# Default: build the macOS app exactly as Xcode's Build & Run would, then copy
# the bundle to build/Twinleaf.app. scripts/build-app.sh is a thin xcodebuild
# wrapper (Debug by default; pass release for a Release bundle).
.PHONY: build
build: deps
	scripts/build-app.sh $(CONFIG)

.PHONY: release
release: deps
	scripts/build-app.sh release

# Build the macOS app and launch it.
.PHONY: run
run: build
	open "$(APP)"

# Build for the iPad Simulator (no code signing required).
.PHONY: ios
ios: ios-deps
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination 'generic/platform=iOS Simulator' \
		CODE_SIGNING_ALLOWED=NO \
		build

# ---------------------------------------------------------------------------
# Tests / housekeeping
# ---------------------------------------------------------------------------

# Rust core unit tests (matches the CI `rust` job).
.PHONY: test
test: deps
	cargo test --manifest-path rust/tio-bridge/Cargo.toml --features hdf5

.PHONY: clean
clean:
	-xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean >/dev/null 2>&1
	rm -rf $(BUILD_DIR)

.PHONY: help
help:
	@echo "Targets:"
	@echo "  make            Build the macOS app (== Xcode Build & Run) -> $(APP)"
	@echo "  make run        Build and launch the macOS app"
	@echo "  make release    Build a Release macOS bundle"
	@echo "  make ios        Build for the iPad Simulator"
	@echo "  make test       Run the Rust core unit tests"
	@echo "  make deps       Check out submodules / verify the Rust toolchain"
	@echo "  make clean      Remove build artifacts"
