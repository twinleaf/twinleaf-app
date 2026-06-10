# Twinleaf

Twinleaf is a native SwiftUI document app for plotting and logging Twinleaf sensor data.

The macOS app currently targets macOS 26 or newer on Apple Silicon (the project builds arm64 only) so it can use the latest SwiftUI app and toolbar controls. The iPad app is an active port of the same document and plotting surface.

The app links against Rust for the Twinleaf hardware boundary:

- `Twinleaf`, the single Swift/Xcode app target for both macOS and iPadOS. It owns windows, `.tio` documents, plotting UI, stream selection, and RPC controls.
- `libtwinleaf_core`, a Rust library loaded dynamically on macOS and linked statically on iPad. It owns all Twinleaf device communication through `twinleaf-rust`, writes raw `.tio` packet logs, runs FPCS/FFT processing, and returns plot frames over a binary callback.
- `tio-bridge`, a Rust CLI harness that uses the same core code and remains useful for debugging outside the app.

This keeps the app native while keeping the hardware boundary in Rust, without a subprocess command bridge in the app path.

## Current Shape

- New windows open a device picker.
- The device picker can remember arbitrary Twinleaf URLs for quick reconnects, with the saved list editable in Settings.
- The left sidebar lists devices, streams, and columns that can be plotted.
- The right sidebar lists device RPCs and allows readable RPC refreshes plus simple writable calls.
- Plotting supports one or more columns.
- Timeseries display uses the same FPCS-style min/max decimation strategy as Trendline.
- FFT display uses Welch spectral density through the Rust `welch-sde` crate on a Rust worker thread.
- Live logging writes Twinleaf packets to a temporary `.tio` backing file. Save or Save As snapshots that backing file into the document path, so an Untitled document can begin logging immediately and keep logging through the save transition.
- Opening an existing `.tio` file starts in inspection mode: Rust parses the saved packets, stream ID 1 is selected by default, plotting is paused-only, and the toolbar scrubber moves the displayed time window through the log.
- File > Export writes the raw `.tio` log to CSV or HDF5 through Rust. CSV is available in the default Rust build; HDF5 is available when the Rust core is built with `--features hdf5`.
- After connecting, the app lazily checks whether newer published firmware exists for each connected device. When an update is available, a green update button appears in the toolbar; its popover shows the installed and new versions and flashes the device with live progress. See the Notes section for the network access this involves.

## Build

Build the Rust core first:

```sh
cargo build --manifest-path rust/tio-bridge/Cargo.toml --features hdf5
```

If you omit `--features hdf5`, the app can still stream, log, inspect, and export CSV, but HDF5 export will report that Rust was built without HDF5 support.

Building with `--features hdf5` compiles HDF5 from source through the statically linked `hdf5-metno` crate, which requires `cmake` on the PATH (`brew install cmake`). No system HDF5 installation is needed.

Then run the macOS app:

```sh
swift run --build-path build/swiftpm Twinleaf
```

During development, the Swift app loads `rust/tio-bridge/target/debug/libtwinleaf_core.dylib` directly. You can override the library path with `TWINLEAF_CORE_PATH`.

For Xcode development, open the project and choose the `Twinleaf` scheme:

```sh
open Twinleaf.xcodeproj
```

The `Twinleaf` Xcode scheme builds the native `Twinleaf.app` bundle for the selected destination. For macOS, it runs `scripts/xcode-build-rust.sh` to package `libtwinleaf_core.dylib` into `Contents/Frameworks` and the `tio-bridge` tool into `Contents/MacOS`. If `cargo` is installed, the script rebuilds the Rust bridge for the active Xcode configuration in an isolated Cargo target directory under `build/xcode-rust`; otherwise it uses existing artifacts from that target directory or the legacy `rust/tio-bridge/target` location.

For iPadOS, the same target runs `scripts/build-ios-rust.sh` in static-library mode. That script builds `rust/tio-bridge` with serial support disabled and firmware update support enabled, links the resulting `libtwinleaf_core.a` into the app, and supports both iPad devices and iPad simulators. Install the Rust standard libraries once before building for iPad:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

The iPad app declares local-network usage because live connections use nearby Twinleaf devices or local TIO proxies.

For normal macOS app behavior, build and launch the `.app` bundle:

```sh
scripts/build-app.sh
open build/Twinleaf.app
```

The bundle includes `libtwinleaf_core.dylib` in `Contents/Frameworks`, also includes the `tio-bridge` CLI harness in `Contents/MacOS` for debugging, declares the `.tio` document type, builds Rust with HDF5 export support, and is the preferred way to test menu bar, focus, keyboard shortcuts, and document lifecycle behavior. Running with `swift run --build-path build/swiftpm Twinleaf` remains useful for quick iteration, but it is a command-line launch rather than a full Launch Services app launch.

For a simulator smoke test of the Xcode iPad bundle, boot an iPad simulator and run:

```sh
scripts/smoke-ipad-simulator.sh
```

The script builds `Twinleaf.app`, installs it into the booted simulator, launches it, saves a screenshot under `build/ipad-simulator-smoke/`, and prints recent app log output.

For a release-style bundle:

```sh
scripts/build-app.sh release
open build/Twinleaf.app
```

## Distribution Signing and Notarization

For direct macOS distribution outside the App Store, install both `Developer ID Application` and `Developer ID Installer` certificates in Keychain, then store notarization credentials once with Apple's `notarytool`:

```sh
xcrun notarytool store-credentials "twinleaf-notary" --apple-id "you@example.com" --team-id TEAMID --password "app-specific-password"
```

Build, sign, notarize, staple, and package release artifacts with:

```sh
TWINLEAF_NOTARY_PROFILE=twinleaf-notary APPLE_TEAM_ID=TEAMID scripts/release-app.sh
```

The script signs the app with hardened runtime, signs the embedded Quick Look extension, Rust dylib, and `tio-bridge` tool, notarizes and staples by default, creates a distributable app ZIP at `build/distribution/Twinleaf-macOS.zip`, builds a signed `/Applications` installer package at `build/distribution/Twinleaf-macOS.pkg`, builds a signed drag-install disk image at `build/distribution/Twinleaf-macOS.dmg`, and exports the iPadOS IPA at `build/distribution/Twinleaf-iPadOS.ipa`. iPadOS export lets Xcode create or update signing assets by default; pass `--no-ios-provisioning-updates` for fully manual signing. If you only want to validate signing locally, use `scripts/release-app.sh --skip-notarization --skip-ios`; use `--skip-pkg`, `--skip-dmg`, or `--skip-ios` to omit those artifacts.

For company iPads, distribute Twinleaf as an Apple Business Manager custom app. Build an App Store Connect export with:

```sh
APPLE_TEAM_ID=TEAMID scripts/release-app.sh --only-ios
```

That archives the `Twinleaf` Xcode scheme for an iPadOS destination and exports `build/distribution/Twinleaf-iPadOS.ipa`, suitable for uploading to App Store Connect. From App Store Connect, make the app available as a custom app for the company's Apple Business Manager organization; Apple Business Manager then handles app licenses for MDM assignment. For manual iPadOS signing, pass `--ios-signing-style manual --ios-team-id TEAMID --ios-provisioning-profile "TwinleafPad App Store"`.

## Notes

The project currently vendors `twinleaf-rust` as a Git submodule at:

```text
vendor/twinleaf-rust
```

After cloning, initialize it with:

```sh
git submodule update --init --recursive
```

### Network access

After connecting to a device, the app checks in the background whether newer published firmware exists for it. The check queries the public firmware catalog at `github.com/twinleaf/twinleaf-firmware-updates` through `api.github.com`; the request identifies only the sensor model name and hardware revision. Firmware images are downloaded over HTTPS when you start an upgrade and cached under the OS cache directory (`~/Library/Caches/twinleaf/firmware` on macOS). Apart from this firmware check, the app makes no network connections other than the device and proxy URLs you configure.

## License

Twinleaf app code is licensed under Apache-2.0. See `LICENSE` for the full license text.

Vendored dependencies retain their own licenses. In particular, `vendor/twinleaf-rust` is distributed under its upstream MIT/Apache licensing.
