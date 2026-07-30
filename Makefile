# Builds are identical to pressing Build in Xcode (⌘R): plain xcodebuild against
# the shared Twinleaf scheme, default derived data, automatic signing — no
# overrides. The scheme's run-script phase compiles and embeds the vendored Rust
# core, so a checked-out submodule (git submodule update --init --recursive) and
# a Rust toolchain are prerequisites, exactly as they are for Xcode itself.

SCHEME := Twinleaf
CONFIGURATION := Debug

.PHONY: all macos ios clean

all: macos

macos:
	xcodebuild build -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination 'platform=macOS'

ios:
	xcodebuild build -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination 'generic/platform=iOS Simulator'

clean:
	xcodebuild clean -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination 'platform=macOS'
	xcodebuild clean -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination 'generic/platform=iOS Simulator'
