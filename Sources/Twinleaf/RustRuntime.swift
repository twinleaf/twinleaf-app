// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

private func logRustRuntime(_ message: String) {
    TwinleafConsole.debug("[Twinleaf][RustRuntime] \(message)")
}

private typealias RustEventCallback = @convention(c) (
    UInt32,
    UnsafePointer<UInt8>?,
    Int,
    UInt
) -> Void

private typealias RuntimeCreateFn = @convention(c) (RustEventCallback?, UInt) -> OpaquePointer?
private typealias RuntimeDestroyFn = @convention(c) (OpaquePointer?) -> Void
private typealias RuntimeListDevicesFn = @convention(c) (OpaquePointer?, UInt8) -> Void
private typealias RuntimeConnectFn = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
) -> Void
private typealias RuntimeSetLoggingFn = @convention(c) (
    OpaquePointer?,
    UInt8,
    UnsafePointer<CChar>?
) -> Void
private typealias RuntimeOpenLogFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Void
private typealias RuntimeExportLogFn = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UInt8
) -> Void
private typealias RuntimeDisconnectFn = @convention(c) (OpaquePointer?) -> Void
private typealias RuntimeCheckUpgradeFn = @convention(c) (OpaquePointer?) -> Void
private typealias RuntimePerformUpgradeFn = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?
) -> Void
private typealias RuntimeSetPlaybackFn = @convention(c) (OpaquePointer?, Double) -> Void
private typealias RuntimeCopyViewDataFn = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?,
    UInt,
    UInt8,
    Double
) -> Void
private typealias RuntimeSetPlotPanesFn = @convention(c) (
    OpaquePointer?,
    UnsafePointer<UInt>?,
    UnsafePointer<UInt8>?,
    UnsafePointer<Double>?,
    UnsafePointer<UInt>?,
    UnsafePointer<UInt>?,
    UnsafePointer<UInt8>?,
    UnsafePointer<UInt8>?,
    UnsafePointer<UInt8>?,
    UnsafePointer<UInt8>?,
    Int,
    UnsafePointer<UInt>?,
    UnsafePointer<UnsafePointer<CChar>?>?,
    UnsafePointer<UInt8>?,
    UnsafePointer<UInt>?,
    Int
) -> Void
private typealias RuntimeSetViewFn = @convention(c) (
    OpaquePointer?,
    UInt8,
    Double,
    UInt,
    UInt,
    UInt8,
    UInt8,
    UInt8,
    UInt8
) -> Void
private typealias RuntimeCallRpcFn = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
) -> Void
private typealias RuntimeCallRpcValueFn = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafeRawPointer?
) -> Void

private struct RuntimeRpcArgument {
    var tag: UInt8
    var boolValue: UInt8
    var intValue: Int64
    var uintValue: UInt64
    var doubleValue: Double
    var stringValue: UnsafePointer<CChar>?
}

#if TWINLEAF_STATIC_RUST
@_silgen_name("twinleaf_runtime_create")
private func twinleaf_runtime_create(_ callback: RustEventCallback?, _ context: UInt) -> OpaquePointer?

@_silgen_name("twinleaf_runtime_destroy")
private func twinleaf_runtime_destroy(_ runtime: OpaquePointer?)

@_silgen_name("twinleaf_runtime_list_devices")
private func twinleaf_runtime_list_devices(_ runtime: OpaquePointer?, _ includeAll: UInt8)

@_silgen_name("twinleaf_runtime_connect")
private func twinleaf_runtime_connect(
    _ runtime: OpaquePointer?,
    _ url: UnsafePointer<CChar>?,
    _ route: UnsafePointer<CChar>?,
    _ logPath: UnsafePointer<CChar>?
)

@_silgen_name("twinleaf_runtime_set_logging")
private func twinleaf_runtime_set_logging(
    _ runtime: OpaquePointer?,
    _ enabled: UInt8,
    _ logPath: UnsafePointer<CChar>?
)

@_silgen_name("twinleaf_runtime_open_log")
private func twinleaf_runtime_open_log(_ runtime: OpaquePointer?, _ path: UnsafePointer<CChar>?)

@_silgen_name("twinleaf_runtime_export_log")
private func twinleaf_runtime_export_log(
    _ runtime: OpaquePointer?,
    _ requestId: UnsafePointer<CChar>?,
    _ sourcePath: UnsafePointer<CChar>?,
    _ outputPath: UnsafePointer<CChar>?,
    _ format: UInt8
)

@_silgen_name("twinleaf_runtime_disconnect")
private func twinleaf_runtime_disconnect(_ runtime: OpaquePointer?)

@_silgen_name("twinleaf_runtime_set_playback")
private func twinleaf_runtime_set_playback(_ runtime: OpaquePointer?, _ position: Double)

@_silgen_name("twinleaf_runtime_copy_view_data")
private func twinleaf_runtime_copy_view_data(
    _ runtime: OpaquePointer?,
    _ requestId: UnsafePointer<CChar>?,
    _ paneID: UInt,
    _ hasViewportEnd: UInt8,
    _ viewportEnd: Double
)

@_silgen_name("twinleaf_runtime_set_plot_panes")
private func twinleaf_runtime_set_plot_panes(
    _ runtime: OpaquePointer?,
    _ paneIDs: UnsafePointer<UInt>?,
    _ modes: UnsafePointer<UInt8>?,
    _ windowSeconds: UnsafePointer<Double>?,
    _ resolutionMultipliers: UnsafePointer<UInt>?,
    _ plotWidthPixels: UnsafePointer<UInt>?,
    _ decimationMethods: UnsafePointer<UInt8>?,
    _ detrends: UnsafePointer<UInt8>?,
    _ fftLogXs: UnsafePointer<UInt8>?,
    _ fftLogYs: UnsafePointer<UInt8>?,
    _ paneCount: Int,
    _ columnPaneIDs: UnsafePointer<UInt>?,
    _ routes: UnsafePointer<UnsafePointer<CChar>?>?,
    _ streamIDs: UnsafePointer<UInt8>?,
    _ columnIndices: UnsafePointer<UInt>?,
    _ columnCount: Int
)

@_silgen_name("twinleaf_runtime_set_view")
private func twinleaf_runtime_set_view(
    _ runtime: OpaquePointer?,
    _ mode: UInt8,
    _ windowSeconds: Double,
    _ resolutionMultiplier: UInt,
    _ plotWidthPixels: UInt,
    _ decimationMethod: UInt8,
    _ detrend: UInt8,
    _ fftLogX: UInt8,
    _ fftLogY: UInt8
)

@_silgen_name("twinleaf_runtime_call_rpc")
private func twinleaf_runtime_call_rpc(
    _ runtime: OpaquePointer?,
    _ requestId: UnsafePointer<CChar>?,
    _ route: UnsafePointer<CChar>?,
    _ name: UnsafePointer<CChar>?,
    _ argJson: UnsafePointer<CChar>?
)

@_silgen_name("twinleaf_runtime_call_rpc_value")
private func twinleaf_runtime_call_rpc_value(
    _ runtime: OpaquePointer?,
    _ requestId: UnsafePointer<CChar>?,
    _ route: UnsafePointer<CChar>?,
    _ name: UnsafePointer<CChar>?,
    _ arg: UnsafeRawPointer?
)

@_silgen_name("twinleaf_runtime_check_upgrade")
private func twinleaf_runtime_check_upgrade(_ runtime: OpaquePointer?)

@_silgen_name("twinleaf_runtime_perform_upgrade")
private func twinleaf_runtime_perform_upgrade(
    _ runtime: OpaquePointer?,
    _ route: UnsafePointer<CChar>?
)
#endif

private final class RustRuntimeCallbackBox {
    weak var owner: BridgeClient?

    init(owner: BridgeClient) {
        self.owner = owner
    }
}

private let twinleafRustEventCallback: RustEventCallback = { kind, bytes, count, context in
    guard context != 0,
          let boxPointer = UnsafeRawPointer(bitPattern: Int(context)) else {
        return
    }

    let box = Unmanaged<RustRuntimeCallbackBox>.fromOpaque(boxPointer).takeUnretainedValue()
    guard let owner = box.owner else { return }

    let data: Data
    if let bytes, count > 0 {
        data = Data(bytes: bytes, count: count)
    } else {
        data = Data()
    }

    Task { @MainActor in
        owner.handleRustEvent(kind: kind, data: data)
    }
}

final class RustRuntime {
    private let library: UnsafeMutableRawPointer?
    private let callbackBox: RustRuntimeCallbackBox
    private var runtime: OpaquePointer?
    private var didCloseLibrary = false

    private let destroyFn: RuntimeDestroyFn
    private let listDevicesFn: RuntimeListDevicesFn
    private let connectFn: RuntimeConnectFn
    private let setLoggingFn: RuntimeSetLoggingFn
    private let openLogFn: RuntimeOpenLogFn
    private let exportLogFn: RuntimeExportLogFn
    private let disconnectFn: RuntimeDisconnectFn
    private let checkUpgradeFn: RuntimeCheckUpgradeFn
    private let performUpgradeFn: RuntimePerformUpgradeFn
    private let setPlaybackFn: RuntimeSetPlaybackFn
    private let copyViewDataFn: RuntimeCopyViewDataFn
    private let setPlotPanesFn: RuntimeSetPlotPanesFn
    private let setViewFn: RuntimeSetViewFn
    private let callRpcValueFn: RuntimeCallRpcValueFn

    init(owner: BridgeClient) throws {
        let callbackBox = RustRuntimeCallbackBox(owner: owner)
        self.callbackBox = callbackBox

#if TWINLEAF_STATIC_RUST
        library = nil
        logRustRuntime("using statically linked Rust runtime")
        let createFn: RuntimeCreateFn = twinleaf_runtime_create
        destroyFn = twinleaf_runtime_destroy
        listDevicesFn = twinleaf_runtime_list_devices
        connectFn = twinleaf_runtime_connect
        setLoggingFn = twinleaf_runtime_set_logging
        openLogFn = twinleaf_runtime_open_log
        exportLogFn = twinleaf_runtime_export_log
        disconnectFn = twinleaf_runtime_disconnect
        checkUpgradeFn = twinleaf_runtime_check_upgrade
        performUpgradeFn = twinleaf_runtime_perform_upgrade
        setPlaybackFn = twinleaf_runtime_set_playback
        copyViewDataFn = twinleaf_runtime_copy_view_data
        setPlotPanesFn = twinleaf_runtime_set_plot_panes
        setViewFn = twinleaf_runtime_set_view
        callRpcValueFn = twinleaf_runtime_call_rpc_value
#else
        let libraryURL = try Self.findLibraryURL()
        logRustRuntime("loading Rust dylib from \(libraryURL.path)")
        guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw RuntimeError.loadFailed(String(cString: dlerror()))
        }
        logRustRuntime("loaded Rust dylib")

        self.library = library

        let createFn: RuntimeCreateFn = try Self.load(library, "twinleaf_runtime_create")
        destroyFn = try Self.load(library, "twinleaf_runtime_destroy")
        listDevicesFn = try Self.load(library, "twinleaf_runtime_list_devices")
        connectFn = try Self.load(library, "twinleaf_runtime_connect")
        setLoggingFn = try Self.load(library, "twinleaf_runtime_set_logging")
        openLogFn = try Self.load(library, "twinleaf_runtime_open_log")
        exportLogFn = try Self.load(library, "twinleaf_runtime_export_log")
        disconnectFn = try Self.load(library, "twinleaf_runtime_disconnect")
        checkUpgradeFn = try Self.load(library, "twinleaf_runtime_check_upgrade")
        performUpgradeFn = try Self.load(library, "twinleaf_runtime_perform_upgrade")
        setPlaybackFn = try Self.load(library, "twinleaf_runtime_set_playback")
        copyViewDataFn = try Self.load(library, "twinleaf_runtime_copy_view_data")
        setPlotPanesFn = try Self.load(library, "twinleaf_runtime_set_plot_panes")
        setViewFn = try Self.load(library, "twinleaf_runtime_set_view")
        callRpcValueFn = try Self.load(library, "twinleaf_runtime_call_rpc_value")
#endif

        let context = UInt(bitPattern: Unmanaged.passUnretained(callbackBox).toOpaque())
        guard let runtime = createFn(twinleafRustEventCallback, context) else {
            if let library = self.library {
                dlclose(library)
            }
            throw RuntimeError.createFailed
        }
        self.runtime = runtime
        logRustRuntime("created runtime pointer")
    }

    deinit {
        shutdown()
    }

    func shutdown() {
        if let runtime {
            destroyFn(runtime)
            self.runtime = nil
        }
        if let library, !didCloseLibrary {
            dlclose(library)
            didCloseLibrary = true
        }
    }

    func listDevices(includeAll: Bool) {
        logRustRuntime("calling twinleaf_runtime_list_devices includeAll=\(includeAll)")
        listDevicesFn(runtime, includeAll ? 1 : 0)
    }

    func connect(url: String, route: String, logPath: String?) {
        url.withCString { urlPointer in
            route.withCString { routePointer in
                withOptionalCString(logPath) { logPathPointer in
                    connectFn(runtime, urlPointer, routePointer, logPathPointer)
                }
            }
        }
    }

    func setLogging(enabled: Bool, logPath: String?) {
        withOptionalCString(logPath) { logPathPointer in
            setLoggingFn(runtime, enabled ? 1 : 0, logPathPointer)
        }
    }

    func openLog(path: String) {
        path.withCString { pathPointer in
            openLogFn(runtime, pathPointer)
        }
    }

    func exportLog(requestId: String, sourcePath: String, outputPath: String, format: ExportFormat) {
        requestId.withCString { requestPointer in
            sourcePath.withCString { sourcePointer in
                outputPath.withCString { outputPointer in
                    exportLogFn(runtime, requestPointer, sourcePointer, outputPointer, format.runtimeCode)
                }
            }
        }
    }

    func disconnect() {
        disconnectFn(runtime)
    }

    func checkUpgrade() {
        checkUpgradeFn(runtime)
    }

    func performUpgrade(route: String) {
        route.withCString { routePointer in
            performUpgradeFn(runtime, routePointer)
        }
    }

    func setPlayback(position: Double) {
        setPlaybackFn(runtime, position)
    }

    func copyViewData(requestId: String, paneID: Int, viewportEnd: Double?) {
        requestId.withCString { requestPointer in
            copyViewDataFn(runtime, requestPointer, UInt(paneID), viewportEnd == nil ? 0 : 1, viewportEnd ?? 0)
        }
    }

    func setPlotPanes(_ panes: [PlotPaneSelection]) {
        let paneIDs = panes.map { UInt($0.id) }
        let modes = panes.map { $0.viewConfig.mode.runtimeCode }
        let windowSeconds = panes.map { $0.viewConfig.windowSeconds }
        let resolutionMultipliers = panes.map { UInt($0.viewConfig.resolutionMultiplier) }
        let plotWidths = panes.map { UInt($0.viewConfig.plotWidthPixels) }
        let decimationMethods = panes.map { $0.viewConfig.decimationMethod.runtimeCode }
        let detrends = panes.map { $0.viewConfig.detrend.runtimeCode }
        let fftLogXs = panes.map { $0.viewConfig.fftLogX ? UInt8(1) : UInt8(0) }
        let fftLogYs = panes.map { $0.viewConfig.fftLogY ? UInt8(1) : UInt8(0) }
        let columns = panes.flatMap { pane in
            pane.columns.sorted().map { column in
                (paneID: UInt(pane.id), column: column)
            }
        }
        let columnPaneIDs = columns.map { $0.paneID }
        let routeStrings = columns.map { strdup($0.column.route)! }
        defer {
            for pointer in routeStrings {
                free(pointer)
            }
        }
        let routePointers: [UnsafePointer<CChar>?] = routeStrings.map { UnsafePointer($0) }
        let streamIDs = columns.map { $0.column.streamId }
        let columnIndices = columns.map { UInt($0.column.columnIndex) }

        paneIDs.withUnsafeBufferPointer { paneIDBuffer in
            modes.withUnsafeBufferPointer { modeBuffer in
                windowSeconds.withUnsafeBufferPointer { windowBuffer in
                    resolutionMultipliers.withUnsafeBufferPointer { resolutionBuffer in
                        plotWidths.withUnsafeBufferPointer { widthBuffer in
                            decimationMethods.withUnsafeBufferPointer { decimationBuffer in
                                detrends.withUnsafeBufferPointer { detrendBuffer in
                                    fftLogXs.withUnsafeBufferPointer { fftLogXBuffer in
                                        fftLogYs.withUnsafeBufferPointer { fftLogYBuffer in
                                            columnPaneIDs.withUnsafeBufferPointer { columnPaneBuffer in
                                                routePointers.withUnsafeBufferPointer { routesBuffer in
                                                    streamIDs.withUnsafeBufferPointer { streamIDsBuffer in
                                                        columnIndices.withUnsafeBufferPointer { columnIndicesBuffer in
                                                            setPlotPanesFn(
                                                                runtime,
                                                                paneIDBuffer.baseAddress,
                                                                modeBuffer.baseAddress,
                                                                windowBuffer.baseAddress,
                                                                resolutionBuffer.baseAddress,
                                                                widthBuffer.baseAddress,
                                                                decimationBuffer.baseAddress,
                                                                detrendBuffer.baseAddress,
                                                                fftLogXBuffer.baseAddress,
                                                                fftLogYBuffer.baseAddress,
                                                                panes.count,
                                                                columnPaneBuffer.baseAddress,
                                                                routesBuffer.baseAddress,
                                                                streamIDsBuffer.baseAddress,
                                                                columnIndicesBuffer.baseAddress,
                                                                columns.count
                                                            )
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func setView(_ view: ViewConfig) {
        setViewFn(
            runtime,
            view.mode.runtimeCode,
            view.windowSeconds,
            UInt(view.resolutionMultiplier),
            UInt(view.plotWidthPixels),
            view.decimationMethod.runtimeCode,
            view.detrend.runtimeCode,
            view.fftLogX ? 1 : 0,
            view.fftLogY ? 1 : 0
        )
    }

    func callRpc(requestId: String, route: String, name: String, argument: Any?) {
        requestId.withCString { requestPointer in
            route.withCString { routePointer in
                name.withCString { namePointer in
                    withRuntimeRpcArgument(argument) { argumentPointer in
                        callRpcValueFn(runtime, requestPointer, routePointer, namePointer, argumentPointer)
                    }
                }
            }
        }
    }

    private static func findLibraryURL() throws -> URL {
        let fileName = "libtwinleaf_core.dylib"
        let environment = ProcessInfo.processInfo.environment

        if let override = environment["TWINLEAF_CORE_PATH"],
           FileManager.default.isReadableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let bundledFramework = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/\(fileName)")
        if FileManager.default.isReadableFile(atPath: bundledFramework.path) {
            return bundledFramework
        }

        if let bundledResource = Bundle.main.url(forResource: "libtwinleaf_core", withExtension: "dylib") {
            return bundledResource
        }

        let root = BridgeClient.packageRoot
        let debug = root.appendingPathComponent("rust/tio-bridge/target/debug/\(fileName)")
        if FileManager.default.isReadableFile(atPath: debug.path) {
            return debug
        }

        let release = root.appendingPathComponent("rust/tio-bridge/target/release/\(fileName)")
        if FileManager.default.isReadableFile(atPath: release.path) {
            return release
        }

        throw RuntimeError.libraryNotFound(fileName)
    }

    private static func load<T>(_ library: UnsafeMutableRawPointer, _ symbol: String) throws -> T {
        guard let pointer = dlsym(library, symbol) else {
            throw RuntimeError.symbolNotFound(symbol)
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    private func withOptionalCString<T>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> T
    ) -> T {
        guard let value else {
            return body(nil)
        }
        return value.withCString(body)
    }

    private func withRuntimeRpcArgument<T>(
        _ value: Any?,
        _ body: (UnsafeRawPointer?) -> T
    ) -> T {
        guard let value else {
            return body(nil)
        }

        if let value = value as? Bool {
            var argument = RuntimeRpcArgument(
                tag: 1,
                boolValue: value ? 1 : 0,
                intValue: 0,
                uintValue: 0,
                doubleValue: 0,
                stringValue: nil
            )
            return withUnsafePointer(to: &argument) { body(UnsafeRawPointer($0)) }
        }

        if let value = value as? String {
            return value.withCString { pointer in
                var argument = RuntimeRpcArgument(
                    tag: 2,
                    boolValue: 0,
                    intValue: 0,
                    uintValue: 0,
                    doubleValue: 0,
                    stringValue: pointer
                )
                return withUnsafePointer(to: &argument) { body(UnsafeRawPointer($0)) }
            }
        }

        if let value = value as? Double {
            var argument = RuntimeRpcArgument(
                tag: 3,
                boolValue: 0,
                intValue: 0,
                uintValue: 0,
                doubleValue: value,
                stringValue: nil
            )
            return withUnsafePointer(to: &argument) { body(UnsafeRawPointer($0)) }
        }

        if let value = value as? Int64 {
            var argument = RuntimeRpcArgument(
                tag: 4,
                boolValue: 0,
                intValue: value,
                uintValue: 0,
                doubleValue: 0,
                stringValue: nil
            )
            return withUnsafePointer(to: &argument) { body(UnsafeRawPointer($0)) }
        }

        if let value = value as? UInt64 {
            var argument = RuntimeRpcArgument(
                tag: 5,
                boolValue: 0,
                intValue: 0,
                uintValue: value,
                doubleValue: 0,
                stringValue: nil
            )
            return withUnsafePointer(to: &argument) { body(UnsafeRawPointer($0)) }
        }

        return body(nil)
    }
}

private enum RuntimeError: LocalizedError {
    case libraryNotFound(String)
    case loadFailed(String)
    case symbolNotFound(String)
    case createFailed

    var errorDescription: String? {
        switch self {
        case .libraryNotFound(let name):
            "Could not find \(name). Run scripts/build-app.sh or set TWINLEAF_CORE_PATH."
        case .loadFailed(let message):
            "Could not load Twinleaf Rust core: \(message)"
        case .symbolNotFound(let symbol):
            "Twinleaf Rust core is missing \(symbol)"
        case .createFailed:
            "Twinleaf Rust core failed to create a runtime"
        }
    }
}

private extension PlotMode {
    var runtimeCode: UInt8 {
        switch self {
        case .timeseries: 0
        case .fft: 1
        }
    }
}

private extension DecimationMethod {
    var runtimeCode: UInt8 {
        switch self {
        case .none: 0
        case .fpcs: 1
        }
    }
}

private extension DetrendMethod {
    var runtimeCode: UInt8 {
        switch self {
        case .none: 0
        case .mean: 1
        case .linear: 2
        case .quadratic: 3
        }
    }
}

private extension ExportFormat {
    var runtimeCode: UInt8 {
        switch self {
        case .csv: 0
        case .hdf5: 1
        }
    }
}
