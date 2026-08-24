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
private typealias RuntimeSetDiscoveryFn = @convention(c) (OpaquePointer?, UInt8, UInt8) -> Void
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
private typealias RuntimeSendCommandJsonFn = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?
) -> Bool
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

@_silgen_name("twinleaf_runtime_set_discovery")
private func twinleaf_runtime_set_discovery(
    _ runtime: OpaquePointer?,
    _ active: UInt8,
    _ includeAll: UInt8
)

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

@_silgen_name("twinleaf_runtime_send_command_json")
private func twinleaf_runtime_send_command_json(
    _ runtime: OpaquePointer?,
    _ json: UnsafePointer<CChar>?
) -> Bool

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
    private let setDiscoveryFn: RuntimeSetDiscoveryFn
    private let connectFn: RuntimeConnectFn
    private let setLoggingFn: RuntimeSetLoggingFn
    private let openLogFn: RuntimeOpenLogFn
    private let exportLogFn: RuntimeExportLogFn
    private let disconnectFn: RuntimeDisconnectFn
    private let checkUpgradeFn: RuntimeCheckUpgradeFn
    private let performUpgradeFn: RuntimePerformUpgradeFn
    private let setPlaybackFn: RuntimeSetPlaybackFn
    private let copyViewDataFn: RuntimeCopyViewDataFn
    private let sendCommandJsonFn: RuntimeSendCommandJsonFn
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
        setDiscoveryFn = twinleaf_runtime_set_discovery
        connectFn = twinleaf_runtime_connect
        setLoggingFn = twinleaf_runtime_set_logging
        openLogFn = twinleaf_runtime_open_log
        exportLogFn = twinleaf_runtime_export_log
        disconnectFn = twinleaf_runtime_disconnect
        checkUpgradeFn = twinleaf_runtime_check_upgrade
        performUpgradeFn = twinleaf_runtime_perform_upgrade
        setPlaybackFn = twinleaf_runtime_set_playback
        copyViewDataFn = twinleaf_runtime_copy_view_data
        sendCommandJsonFn = twinleaf_runtime_send_command_json
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
        setDiscoveryFn = try Self.load(library, "twinleaf_runtime_set_discovery")
        connectFn = try Self.load(library, "twinleaf_runtime_connect")
        setLoggingFn = try Self.load(library, "twinleaf_runtime_set_logging")
        openLogFn = try Self.load(library, "twinleaf_runtime_open_log")
        exportLogFn = try Self.load(library, "twinleaf_runtime_export_log")
        disconnectFn = try Self.load(library, "twinleaf_runtime_disconnect")
        checkUpgradeFn = try Self.load(library, "twinleaf_runtime_check_upgrade")
        performUpgradeFn = try Self.load(library, "twinleaf_runtime_perform_upgrade")
        setPlaybackFn = try Self.load(library, "twinleaf_runtime_set_playback")
        copyViewDataFn = try Self.load(library, "twinleaf_runtime_copy_view_data")
        sendCommandJsonFn = try Self.load(library, "twinleaf_runtime_send_command_json")
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

    func setDiscovery(active: Bool, includeAll: Bool) {
        logRustRuntime("calling twinleaf_runtime_set_discovery active=\(active) includeAll=\(includeAll)")
        setDiscoveryFn(runtime, active ? 1 : 0, includeAll ? 1 : 0)
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
        send(SetPlotPanesCommand(panes: panes.map(PlotPaneConfigPayload.init)))
    }

    func setDerivedChannels(_ channels: [DerivedChannelSpec]) {
        send(SetDerivedChannelsCommand(
            channels: channels.sorted { $0.key < $1.key }.map(DerivedChannelPayload.init)
        ))
    }

    func setView(_ view: ViewConfig) {
        send(SetViewCommand(view: view))
    }

    /// Structured commands cross the FFI boundary as JSON.
    ///
    /// The alternative — a dozen parallel C arrays per command, as plot panes
    /// used to be passed — cost an array on both sides for every new field and
    /// silently misbehaved if the two sides fell out of step. These commands
    /// fire on user actions, not per frame, so encoding is not on any hot path.
    private func send<Command: Encodable>(_ command: Command) {
        guard let data = try? JSONEncoder().encode(command),
              let json = String(data: data, encoding: .utf8) else {
            logRustRuntime("failed to encode runtime command")
            return
        }
        let accepted = json.withCString { sendCommandJsonFn(runtime, $0) }
        if !accepted {
            logRustRuntime("runtime rejected command: \(json.prefix(200))")
        }
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
            "Could not find \(name). Build the app with Xcode or `make`, or set TWINLEAF_CORE_PATH."
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

// MARK: - Runtime command payloads
//
// These mirror the Rust `ClientCommand` variants exactly: the tag field is
// `type`, and every key is camelCase. They exist as separate types rather than
// encoding the UI models directly because the UI models carry things the
// runtime has no use for (pane titles, selection sets) and name things
// differently (`viewConfig` vs the runtime's `view`).

private struct SetPlotPanesCommand: Encodable {
    let type = "setPlotPanes"
    let panes: [PlotPaneConfigPayload]
}

private struct SetDerivedChannelsCommand: Encodable {
    let type = "setDerivedChannels"
    let channels: [DerivedChannelPayload]
}

private struct SetViewCommand: Encodable {
    let type = "setView"
    let view: ViewConfig
}

private struct PlotPaneConfigPayload: Encodable {
    let id: Int
    let view: ViewConfig
    let columns: [ColumnKey]

    init(_ pane: PlotPaneSelection) {
        id = pane.id
        view = pane.viewConfig
        // Sorted so an unchanged selection encodes identically every time;
        // `columns` is a Set on the UI side and would otherwise reorder.
        columns = pane.columns.sorted()
    }
}

private struct DerivedChannelPayload: Encodable {
    let key: ColumnKey
    let windowSeconds: Double
    let cadenceSeconds: Double
    let detrend: DetrendMethod

    init(_ spec: DerivedChannelSpec) {
        key = spec.key
        windowSeconds = DerivedChannelDefaults.clampedWindow(spec.windowSeconds)
        cadenceSeconds = DerivedChannelDefaults.clampedCadence(spec.cadenceSeconds)
        detrend = spec.detrend
    }
}
