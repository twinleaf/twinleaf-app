#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Twinleaf"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
DIST_DIR="${DIST_DIR:-$BUILD_DIR/distribution}"
APP_DIR="${APP_DIR:-}"
DIST_WORK_ROOT="${DIST_WORK_ROOT:-}"
DMG_ROOT="${DMG_ROOT:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-${MACOS_SIGN_IDENTITY:-}}"
INSTALLER_IDENTITY="${INSTALLER_SIGN_IDENTITY:-${MACOS_INSTALLER_SIGN_IDENTITY:-}}"
NOTARY_PROFILE="${NOTARY_PROFILE:-${TWINLEAF_NOTARY_PROFILE:-}}"
QUICKLOOK_ENTITLEMENTS="$ROOT_DIR/Packaging/TwinleafQuickLook.entitlements"
APP_ENTITLEMENTS="$ROOT_DIR/Packaging/Twinleaf.entitlements"
BRIDGE_ENTITLEMENTS="$ROOT_DIR/Packaging/TioBridge.entitlements"
BUILD_MACOS=1
BUILD_IOS=1
IOS_SCHEME="${IOS_SCHEME:-Twinleaf}"
IOS_CONFIGURATION="${IOS_CONFIGURATION:-$CONFIGURATION}"
IOS_TEAM_ID="${IOS_TEAM_ID:-${APPLE_TEAM_ID:-${TEAM_ID:-}}}"
IOS_SIGNING_STYLE="${IOS_SIGNING_STYLE:-automatic}"
IOS_SIGNING_CERTIFICATE="${IOS_SIGNING_CERTIFICATE:-Apple Distribution}"
IOS_PROVISIONING_PROFILE="${IOS_PROVISIONING_PROFILE:-}"
IOS_BUNDLE_ID="${IOS_BUNDLE_ID:-}"
IOS_EXPORT_METHOD="${IOS_EXPORT_METHOD:-app-store-connect}"
IOS_UPLOAD_SYMBOLS="${IOS_UPLOAD_SYMBOLS:-YES}"
IOS_MANAGE_APP_VERSION_AND_BUILD_NUMBER="${IOS_MANAGE_APP_VERSION_AND_BUILD_NUMBER:-NO}"
IOS_ALLOW_PROVISIONING_UPDATES="${IOS_ALLOW_PROVISIONING_UPDATES:-1}"
IOS_AUTHENTICATION_KEY_PATH="${IOS_AUTHENTICATION_KEY_PATH:-${APP_STORE_CONNECT_API_KEY_PATH:-}}"
IOS_AUTHENTICATION_KEY_ID="${IOS_AUTHENTICATION_KEY_ID:-${APP_STORE_CONNECT_API_KEY_ID:-}}"
IOS_AUTHENTICATION_KEY_ISSUER_ID="${IOS_AUTHENTICATION_KEY_ISSUER_ID:-${APP_STORE_CONNECT_API_KEY_ISSUER_ID:-}}"
IOS_ARCHIVE_PATH="${IOS_ARCHIVE_PATH:-}"
IOS_EXPORT_PATH="${IOS_EXPORT_PATH:-}"
IOS_EXPORT_OPTIONS_PLIST="${IOS_EXPORT_OPTIONS_PLIST:-}"
SKIP_BUILD=0
SKIP_PKG=0
SKIP_DMG=0
NOTARIZE=1
WORK_ROOT=""
CLEAN_WORK_ROOT=0

usage() {
	cat <<USAGE
Usage: scripts/release-app.sh [options]

Builds, Developer ID signs, notarizes, staples, and packages Twinleaf for direct macOS distribution.
It also archives and exports the iPadOS app as an App Store Connect IPA for Apple Business Manager custom app distribution by default.

Default outputs:
  build/distribution/Twinleaf-macOS.zip
  build/distribution/Twinleaf-macOS.pkg
  build/distribution/Twinleaf-macOS.dmg
  build/distribution/Twinleaf-iPadOS.ipa

Options:
  --sign-identity NAME       Developer ID Application identity for the app and DMG.
                             Defaults to MACOS_SIGN_IDENTITY, then the first valid matching keychain identity.
  --installer-identity NAME  Developer ID Installer identity for the PKG.
                             Defaults to MACOS_INSTALLER_SIGN_IDENTITY, then the first valid matching keychain identity.
  --notary-profile NAME      notarytool keychain profile.
                             Defaults to NOTARY_PROFILE, then TWINLEAF_NOTARY_PROFILE when set.
  --notarize                 Submit ZIP, PKG, and DMG to Apple notarization. This is the default.
  --skip-notarization        Sign and package without notarizing or stapling.
  --skip-build               Sign the existing APP_DIR or build/Twinleaf.app instead of rebuilding it.
  --skip-pkg                 Build only the app ZIP, not the /Applications installer package.
  --skip-dmg                 Build only the app ZIP/package, not the drag-install disk image.
  --ios                      Build and export the iPadOS IPA. This is the default.
  --only-ios                 Build and export only the iPadOS IPA.
  --skip-ios                 Do not build the iPadOS IPA.
  --ios-team-id TEAMID       Apple Developer Team ID for iPadOS signing.
                             Defaults to IOS_TEAM_ID, APPLE_TEAM_ID, then TEAM_ID.
  --ios-signing-style STYLE  automatic or manual. Defaults to automatic.
  --ios-provisioning-profile NAME_OR_UUID
                             Provisioning profile specifier for manual iPadOS signing.
  --ios-allow-provisioning-updates
                             Allow xcodebuild to create/update signing assets when needed. This is the default.
  --no-ios-provisioning-updates
                             Do not let xcodebuild create/update iPadOS signing assets.
  --ios-export-method METHOD App export method. Defaults to app-store-connect.
  -h, --help                 Show this help.

Notarization authentication:
  Preferred: create a notarytool keychain profile once:
    xcrun notarytool store-credentials "twinleaf-notary" --apple-id "you@example.com" --team-id TEAMID --password "app-specific-password"

  Then run:
    TWINLEAF_NOTARY_PROFILE=twinleaf-notary scripts/release-app.sh

  Alternatively, provide APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD in the environment.

iPadOS App Store Connect export:
  Automatic signing with an Xcode account:
    APPLE_TEAM_ID=TEAMID scripts/release-app.sh --only-ios

  Manual signing:
    scripts/release-app.sh --only-ios --ios-signing-style manual --ios-team-id TEAMID \\
      --ios-provisioning-profile "TwinleafPad App Store"
USAGE
}

fail() {
	echo "error: $*" >&2
	exit 1
}

cleanup() {
	if [[ "$CLEAN_WORK_ROOT" -eq 1 && -n "$WORK_ROOT" ]]; then
		rm -rf "$WORK_ROOT" || true
	fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
	case "$1" in
		--sign-identity)
			[[ $# -ge 2 ]] || fail "--sign-identity requires a value"
			SIGN_IDENTITY="$2"
			shift 2
			;;
		--installer-identity)
			[[ $# -ge 2 ]] || fail "--installer-identity requires a value"
			INSTALLER_IDENTITY="$2"
			shift 2
			;;
		--notary-profile)
			[[ $# -ge 2 ]] || fail "--notary-profile requires a value"
			NOTARY_PROFILE="$2"
			NOTARIZE=1
			shift 2
			;;
		--notarize)
			NOTARIZE=1
			shift
			;;
		--skip-build)
			SKIP_BUILD=1
			shift
			;;
		--skip-notarization)
			NOTARIZE=0
			shift
			;;
		--skip-pkg)
			SKIP_PKG=1
			shift
			;;
		--skip-dmg)
			SKIP_DMG=1
			shift
			;;
		--ios)
			BUILD_IOS=1
			shift
			;;
		--only-ios)
			BUILD_MACOS=0
			BUILD_IOS=1
			shift
			;;
		--skip-ios)
			BUILD_IOS=0
			shift
			;;
		--ios-team-id)
			[[ $# -ge 2 ]] || fail "--ios-team-id requires a value"
			IOS_TEAM_ID="$2"
			shift 2
			;;
		--ios-signing-style)
			[[ $# -ge 2 ]] || fail "--ios-signing-style requires a value"
			IOS_SIGNING_STYLE="$2"
			shift 2
			;;
		--ios-provisioning-profile)
			[[ $# -ge 2 ]] || fail "--ios-provisioning-profile requires a value"
			IOS_PROVISIONING_PROFILE="$2"
			shift 2
			;;
		--ios-allow-provisioning-updates)
			IOS_ALLOW_PROVISIONING_UPDATES=1
			shift
			;;
		--no-ios-provisioning-updates)
			IOS_ALLOW_PROVISIONING_UPDATES=0
			shift
			;;
		--ios-export-method)
			[[ $# -ge 2 ]] || fail "--ios-export-method requires a value"
			IOS_EXPORT_METHOD="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			usage >&2
			fail "unknown option: $1"
			;;
	esac
done

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_file() {
	[[ -f "$1" ]] || fail "required file not found: $1"
}

is_truthy() {
	local value
	value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
	case "$value" in
		1|yes|true|on) return 0 ;;
		*) return 1 ;;
	esac
}

plist_bool() {
	if is_truthy "$1"; then
		printf 'true'
	else
		printf 'false'
	fi
}

normalize_xcode_configuration() {
	case "$1" in
		release|Release) printf 'Release' ;;
		debug|Debug) printf 'Debug' ;;
		*) printf '%s' "$1" ;;
	esac
}

plist_value() {
	/usr/libexec/PlistBuddy -c "Print :$1" "$APP_DIR/Contents/Info.plist"
}

ipad_bundle_id() {
	if [[ -n "$IOS_BUNDLE_ID" ]]; then
		printf '%s' "$IOS_BUNDLE_ID"
		return
	fi

	# iOS and macOS share one bundle identifier (universal purchase). The
	# Info.plist holds the unexpanded $(PRODUCT_BUNDLE_IDENTIFIER) variable,
	# so the identifier is stated here rather than read from the plist.
	printf '%s' "com.twinleaf.Twinleaf"
}

detect_sign_identity() {
	security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ { print $2; exit }'
}

detect_installer_identity() {
	security find-identity -v -p basic | awk -F '"' '/Developer ID Installer/ { print $2; exit }'
}

notary_args=()
configure_notary_auth() {
	[[ "$NOTARIZE" -eq 1 ]] || return 0

	if [[ -n "$NOTARY_PROFILE" ]]; then
		notary_args=(--keychain-profile "$NOTARY_PROFILE")
		return
	fi

	local team_id="${APPLE_TEAM_ID:-${TEAM_ID:-}}"
	if [[ -n "${APPLE_ID:-}" && -n "$team_id" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
		notary_args=(--apple-id "$APPLE_ID" --team-id "$team_id" --password "$APPLE_APP_PASSWORD")
		return
	fi

	fail "missing notarization credentials. Set TWINLEAF_NOTARY_PROFILE, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD."
}

sign_code() {
	local path="$1"
	shift
	echo "Signing $path"
	codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@" "$path"
}

notarize_submission() {
	local path="$1"
	local kind="$2"

	[[ "$NOTARIZE" -eq 1 ]] || return 0

	echo "Submitting $kind to Apple notarization service"
	xcrun notarytool submit "$path" "${notary_args[@]}" --wait
}

notarize_and_staple() {
	local path="$1"
	local kind="$2"

	[[ "$NOTARIZE" -eq 1 ]] || return 0

	notarize_submission "$path" "$kind"
	echo "Stapling notarization ticket to $kind"
	xcrun stapler staple "$path"
	xcrun stapler validate "$path"
}

ios_auth_args=()
IOS_AUTH_ARGS_PRESENT=0
configure_ios_auth() {
	ios_auth_args=()
	IOS_AUTH_ARGS_PRESENT=0

	if is_truthy "$IOS_ALLOW_PROVISIONING_UPDATES"; then
		ios_auth_args+=(-allowProvisioningUpdates)
		IOS_AUTH_ARGS_PRESENT=1
	fi

	local auth_value_count=0
	[[ -n "$IOS_AUTHENTICATION_KEY_PATH" ]] && auth_value_count=$((auth_value_count + 1))
	[[ -n "$IOS_AUTHENTICATION_KEY_ID" ]] && auth_value_count=$((auth_value_count + 1))
	[[ -n "$IOS_AUTHENTICATION_KEY_ISSUER_ID" ]] && auth_value_count=$((auth_value_count + 1))

	if [[ "$auth_value_count" -gt 0 && "$auth_value_count" -lt 3 ]]; then
		fail "iPadOS App Store Connect API auth requires key path, key ID, and issuer ID."
	fi

	if [[ "$auth_value_count" -eq 3 ]]; then
		require_file "$IOS_AUTHENTICATION_KEY_PATH"
		ios_auth_args+=(
			-authenticationKeyPath "$IOS_AUTHENTICATION_KEY_PATH"
			-authenticationKeyID "$IOS_AUTHENTICATION_KEY_ID"
			-authenticationKeyIssuerID "$IOS_AUTHENTICATION_KEY_ISSUER_ID"
		)
		IOS_AUTH_ARGS_PRESENT=1
	fi
}

write_ios_export_options() {
	local export_options_plist="$1"
	local signing_style
	signing_style="$(printf '%s' "$IOS_SIGNING_STYLE" | tr '[:upper:]' '[:lower:]')"

	case "$signing_style" in
		automatic|manual) ;;
		*) fail "--ios-signing-style must be automatic or manual" ;;
	esac

	if [[ "$signing_style" == "manual" ]]; then
		[[ -n "$IOS_TEAM_ID" ]] || fail "manual iPadOS signing requires --ios-team-id or IOS_TEAM_ID."
		[[ -n "$IOS_PROVISIONING_PROFILE" ]] || fail "manual iPadOS signing requires --ios-provisioning-profile."
	fi

	cat > "$export_options_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST

	/usr/libexec/PlistBuddy -c "Clear dict" "$export_options_plist"
	/usr/libexec/PlistBuddy -c "Add :method string $IOS_EXPORT_METHOD" "$export_options_plist"
	/usr/libexec/PlistBuddy -c "Add :destination string export" "$export_options_plist"
	/usr/libexec/PlistBuddy -c "Add :signingStyle string $signing_style" "$export_options_plist"
	/usr/libexec/PlistBuddy -c "Add :stripSwiftSymbols bool true" "$export_options_plist"
	/usr/libexec/PlistBuddy -c "Add :uploadSymbols bool $(plist_bool "$IOS_UPLOAD_SYMBOLS")" "$export_options_plist"
	/usr/libexec/PlistBuddy -c "Add :manageAppVersionAndBuildNumber bool $(plist_bool "$IOS_MANAGE_APP_VERSION_AND_BUILD_NUMBER")" "$export_options_plist"

	if [[ -n "$IOS_TEAM_ID" ]]; then
		/usr/libexec/PlistBuddy -c "Add :teamID string $IOS_TEAM_ID" "$export_options_plist"
	fi

	if [[ "$signing_style" == "manual" ]]; then
		local bundle_id
		bundle_id="$(ipad_bundle_id)"
		/usr/libexec/PlistBuddy -c "Add :signingCertificate string $IOS_SIGNING_CERTIFICATE" "$export_options_plist"
		/usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$export_options_plist"
		/usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$bundle_id string $IOS_PROVISIONING_PROFILE" "$export_options_plist"
	fi
}

build_ios_app() {
	require_command xcodebuild
	require_command xcrun
	require_file /usr/libexec/PlistBuddy

	local ios_configuration
	local archive_path
	local export_path
	local export_options_plist
	local final_ipa
	local exported_ipa
	local signing_style
	ios_configuration="$(normalize_xcode_configuration "$IOS_CONFIGURATION")"
	archive_path="${IOS_ARCHIVE_PATH:-$DIST_DIR/$APP_NAME-iPadOS.xcarchive}"
	export_path="${IOS_EXPORT_PATH:-$DIST_DIR/iPadOS}"
	export_options_plist="${IOS_EXPORT_OPTIONS_PLIST:-$WORK_ROOT/TwinleafPad-exportOptions.plist}"
	final_ipa="$DIST_DIR/$APP_NAME-iPadOS.ipa"
	signing_style="$(printf '%s' "$IOS_SIGNING_STYLE" | tr '[:upper:]' '[:lower:]')"

	mkdir -p "$DIST_DIR"
	rm -rf "$archive_path" "$export_path"
	rm -f "$final_ipa"

	configure_ios_auth
	write_ios_export_options "$export_options_plist"

	local archive_args=(
		-project "$ROOT_DIR/Twinleaf.xcodeproj"
		-scheme "$IOS_SCHEME"
		-configuration "$ios_configuration"
		-destination "generic/platform=iOS"
		-archivePath "$archive_path"
	)

	if [[ -n "$IOS_TEAM_ID" ]]; then
		archive_args+=(DEVELOPMENT_TEAM="$IOS_TEAM_ID")
	fi

	if [[ "$signing_style" == "manual" ]]; then
		archive_args+=(
			CODE_SIGN_STYLE=Manual
			CODE_SIGN_IDENTITY="$IOS_SIGNING_CERTIFICATE"
			PROVISIONING_PROFILE_SPECIFIER="$IOS_PROVISIONING_PROFILE"
		)
	else
		archive_args+=(CODE_SIGN_STYLE=Automatic)
	fi

	echo "Archiving iPadOS app with scheme $IOS_SCHEME"
	if [[ "$IOS_AUTH_ARGS_PRESENT" -eq 1 ]]; then
		xcodebuild "${archive_args[@]}" "${ios_auth_args[@]}" archive
	else
		xcodebuild "${archive_args[@]}" archive
	fi

	echo "Exporting iPadOS App Store Connect IPA"
	if [[ "$IOS_AUTH_ARGS_PRESENT" -eq 1 ]]; then
		xcodebuild \
			-exportArchive \
			-archivePath "$archive_path" \
			-exportPath "$export_path" \
			-exportOptionsPlist "$export_options_plist" \
			"${ios_auth_args[@]}"
	else
		xcodebuild \
			-exportArchive \
			-archivePath "$archive_path" \
			-exportPath "$export_path" \
			-exportOptionsPlist "$export_options_plist"
	fi

	exported_ipa="$(find "$export_path" -name "*.ipa" -print -quit)"
	[[ -n "$exported_ipa" && -f "$exported_ipa" ]] || fail "iPadOS export finished without producing an IPA in $export_path."
	cp "$exported_ipa" "$final_ipa"
	echo "iPadOS App Store Connect IPA: $final_ipa"
}

if [[ "$BUILD_MACOS" -eq 0 && "$BUILD_IOS" -eq 0 ]]; then
	fail "nothing to build. Enable macOS output or pass --ios."
fi

require_command mktemp

if [[ "$BUILD_MACOS" -eq 1 ]]; then
require_command codesign
require_command ditto
require_command hdiutil
require_command install_name_tool
require_command pkgutil
require_command productbuild
require_command security
require_command xcrun

if [[ "$NOTARIZE" -eq 1 ]]; then
	require_command spctl
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
	SIGN_IDENTITY="$(detect_sign_identity)"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
	fail "no Developer ID Application signing identity found. Install one in Keychain or pass --sign-identity."
fi

if [[ "$SKIP_PKG" -eq 0 && -z "$INSTALLER_IDENTITY" ]]; then
	INSTALLER_IDENTITY="$(detect_installer_identity)"
fi

if [[ "$SKIP_PKG" -eq 0 && -z "$INSTALLER_IDENTITY" ]]; then
	fail "no Developer ID Installer signing identity found. Install one in Keychain, pass --installer-identity, or use --skip-pkg."
fi
fi

mkdir -p "$BUILD_DIR"
if [[ -z "$DIST_WORK_ROOT" ]]; then
	WORK_ROOT="$(mktemp -d "$BUILD_DIR/distribution-work.XXXXXX")"
	CLEAN_WORK_ROOT=1
else
	WORK_ROOT="$DIST_WORK_ROOT"
	mkdir -p "$WORK_ROOT"
fi

if [[ "$BUILD_MACOS" -eq 1 ]]; then
if [[ -z "$APP_DIR" ]]; then
	if [[ "$SKIP_BUILD" -eq 1 ]]; then
		APP_DIR="$BUILD_DIR/$APP_NAME.app"
	else
		APP_DIR="$WORK_ROOT/$APP_NAME.app"
	fi
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
	APP_DIR="$APP_DIR" \
		TWINLEAF_DISABLE_SWIFTPM_SANDBOX="${TWINLEAF_DISABLE_SWIFTPM_SANDBOX:-1}" \
		"$ROOT_DIR/scripts/build-app.sh" "$CONFIGURATION"
fi

[[ -d "$APP_DIR" ]] || fail "app bundle not found: $APP_DIR"

configure_notary_auth

BUNDLE_ID="$(plist_value CFBundleIdentifier)"
VERSION="$(plist_value CFBundleShortVersionString)"
PACKAGE_ID="$BUNDLE_ID.pkg"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
MACOS_DIR="$APP_DIR/Contents/MacOS"
CORE_DYLIB="$FRAMEWORKS_DIR/libtwinleaf_core.dylib"
BRIDGE_TOOL="$MACOS_DIR/tio-bridge"
QUICKLOOK_APPEX="$APP_DIR/Contents/PlugIns/TwinleafQuickLook.appex"

[[ -f "$CORE_DYLIB" ]] || fail "missing Rust core dylib: $CORE_DYLIB"
[[ -f "$BRIDGE_TOOL" ]] || fail "missing Rust bridge tool: $BRIDGE_TOOL"
[[ -d "$QUICKLOOK_APPEX" ]] || fail "Quick Look extension not found: $QUICKLOOK_APPEX"
[[ -f "$QUICKLOOK_ENTITLEMENTS" ]] || fail "Quick Look entitlements not found: $QUICKLOOK_ENTITLEMENTS"
[[ -f "$APP_ENTITLEMENTS" ]] || fail "app entitlements not found: $APP_ENTITLEMENTS"
[[ -f "$BRIDGE_ENTITLEMENTS" ]] || fail "tio-bridge entitlements not found: $BRIDGE_ENTITLEMENTS"

echo "Normalizing Rust dylib install name"
install_name_tool -id "@rpath/libtwinleaf_core.dylib" "$CORE_DYLIB"

sign_code "$CORE_DYLIB"
sign_code "$BRIDGE_TOOL" --entitlements "$BRIDGE_ENTITLEMENTS"
sign_code "$QUICKLOOK_APPEX" --entitlements "$QUICKLOOK_ENTITLEMENTS"
sign_code "$APP_DIR" --entitlements "$APP_ENTITLEMENTS"

codesign --verify --strict --verbose=2 "$QUICKLOOK_APPEX"
codesign --verify --strict --verbose=2 "$APP_DIR"

mkdir -p "$DIST_DIR"
APP_NOTARY_ZIP="$DIST_DIR/$APP_NAME-app-notary-upload.zip"
FINAL_ZIP="$DIST_DIR/$APP_NAME-macOS.zip"
FINAL_PKG="$DIST_DIR/$APP_NAME-macOS.pkg"
FINAL_DMG="$DIST_DIR/$APP_NAME-macOS.dmg"
rm -f "$APP_NOTARY_ZIP" "$FINAL_ZIP" "$FINAL_PKG" "$FINAL_DMG"

if [[ "$NOTARIZE" -eq 1 ]]; then
	echo "Creating app notarization upload archive"
	ditto -c -k --keepParent "$APP_DIR" "$APP_NOTARY_ZIP"
	notarize_submission "$APP_NOTARY_ZIP" "app ZIP"
	xcrun stapler staple "$APP_DIR"
	xcrun stapler validate "$APP_DIR"
	codesign --verify --strict --verbose=2 "$APP_DIR"
	spctl --assess --type execute --verbose=4 "$APP_DIR"
fi

echo "Creating app ZIP"
ditto -c -k --keepParent "$APP_DIR" "$FINAL_ZIP"
echo "App ZIP: $FINAL_ZIP"

if [[ "$SKIP_PKG" -eq 0 ]]; then
	echo "Building signed /Applications installer product archive"
	productbuild \
		--component "$APP_DIR" /Applications \
		--identifier "$PACKAGE_ID" \
		--version "$VERSION" \
		--sign "$INSTALLER_IDENTITY" \
		"$FINAL_PKG"
	pkgutil --check-signature "$FINAL_PKG"

	notarize_and_staple "$FINAL_PKG" "installer package"
	if [[ "$NOTARIZE" -eq 1 ]]; then
		pkgutil --check-signature "$FINAL_PKG"
		spctl --assess --type install --verbose=4 "$FINAL_PKG"
	fi

	echo "Installer package: $FINAL_PKG"
fi

if [[ "$SKIP_DMG" -eq 0 ]]; then
	echo "Creating drag-install disk image staging root"
	DMG_ROOT="${DMG_ROOT:-$WORK_ROOT/dmg-root}"
	rm -rf "$DMG_ROOT"
	mkdir -p "$DMG_ROOT"
	ditto "$APP_DIR" "$DMG_ROOT/$APP_NAME.app"
	ln -s /Applications "$DMG_ROOT/Applications"
	codesign --verify --strict --verbose=2 "$DMG_ROOT/$APP_NAME.app"

	echo "Building signed drag-install disk image"
	hdiutil create \
		-volname "$APP_NAME" \
		-srcfolder "$DMG_ROOT" \
		-format UDZO \
		-imagekey zlib-level=9 \
		-ov \
		"$FINAL_DMG"

	codesign --force --timestamp --sign "$SIGN_IDENTITY" "$FINAL_DMG"
	codesign --verify --verbose=2 "$FINAL_DMG"
	hdiutil verify "$FINAL_DMG"

	notarize_and_staple "$FINAL_DMG" "disk image"
	if [[ "$NOTARIZE" -eq 1 ]]; then
		codesign --verify --verbose=2 "$FINAL_DMG"
		spctl --assess --type open --context context:primary-signature --verbose=4 "$FINAL_DMG"
	fi

	echo "Disk image: $FINAL_DMG"
fi

fi

if [[ "$BUILD_IOS" -eq 1 ]]; then
	build_ios_app
fi
