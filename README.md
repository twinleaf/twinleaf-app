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

The `Twinleaf.xcodeproj` project is the single source of truth. Open it in
Xcode 26 or later and run the `Twinleaf` scheme (⌘R); the app targets macOS 26
and iOS 26. The scheme's run-script phase compiles the vendored Rust core and
embeds it in the bundle, so there is nothing to build by hand.

The `Makefile` is just that same build from the command line — plain
`xcodebuild` against the shared scheme, no overrides, identical to Xcode's
Build:

```sh
make        # build the macOS app
make ios    # build for the iPad Simulator
make clean  # clean both destinations
```

Prerequisites (the same ones Xcode needs):

- The vendored Rust core submodule: `git submodule update --init --recursive`.
- A Rust toolchain (`cargo`) — install from <https://rustup.rs>. For iPad builds
  also add the device/simulator targets once:
  `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`.
- `cmake` on the PATH for the statically linked HDF5 build (`brew install
  cmake`). The macOS build compiles HDF5 from source through the `hdf5-metno`
  crate; no system HDF5 install is needed. Without HDF5 the app still streams,
  logs, inspects, and exports CSV, but HDF5 export reports that Rust was built
  without HDF5 support.

The macOS build runs `scripts/xcode-build-rust.sh` (packages
`libtwinleaf_core.dylib` into `Contents/Frameworks` and the `tio-bridge` CLI
into `Contents/MacOS`); iPadOS runs `scripts/build-ios-rust.sh` in
static-library mode and links `libtwinleaf_core.a`. Both are invoked by the
Xcode run-script phase — you do not run them directly. During development the
dylib path can be overridden with `TWINLEAF_CORE_PATH`. The iPad app declares
local-network usage because live connections use nearby Twinleaf devices or
local TIO proxies.

## Distribution

Release goes through App Store Connect. Either archive and upload from Xcode's
Organizer (Product → Archive → Distribute App → App Store Connect), or run the
**App Store** GitHub Actions workflow (`.github/workflows/appstore.yml`), which
archives and uploads both the iOS and macOS apps for TestFlight / review. Run it
from the Actions tab, or push a version tag like `v1.2`. CI supplies a unique,
monotonically increasing `CFBundleVersion` for every upload; see the workflow
header for the required App Store Connect secrets.

## Notes

The project currently vendors `twinleaf-rust` as a Git submodule at:

```text
vendor/twinleaf-rust
```

The submodule follows the upstream `firmware-proto` branch (recorded in
`.gitmodules`). After cloning, initialize it with:

```sh
git submodule update --init --recursive
```

### Network access

After connecting to a device, the app checks in the background whether newer published firmware exists for it. The check queries the public firmware catalog at `github.com/twinleaf/twinleaf-firmware-updates` through `api.github.com`; the request identifies only the sensor model name and hardware revision. Firmware images are downloaded over HTTPS when you start an upgrade and cached under the OS cache directory (`~/Library/Caches/twinleaf/firmware` on macOS). Apart from this firmware check, the app makes no network connections other than the device and proxy URLs you configure.

## License

Twinleaf app code is licensed under Apache-2.0. See `LICENSE` for the full license text.

Vendored dependencies retain their own licenses. In particular, `vendor/twinleaf-rust` is distributed under its upstream MIT/Apache licensing.
