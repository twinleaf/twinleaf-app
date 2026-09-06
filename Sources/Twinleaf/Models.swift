// SPDX-License-Identifier: Apache-2.0

import Foundation
import UniformTypeIdentifiers

enum TwinleafConsole {
    private static let debugEnvironmentKeys = [
        "TWINLEAF_CONSOLE_DEBUG",
        "TWINLEAF_DEBUG_LOGS",
        "TWINLEAF_DEBUG"
    ]

    static var isDebugEnabled: Bool {
        debugEnvironmentKeys.contains { environmentFlagIsEnabled($0) }
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard isDebugEnabled else { return }
        fputs("\(message())\n", stderr)
    }

    static func error(_ message: @autoclosure () -> String) {
        fputs("\(message())\n", stderr)
    }

    private static func environmentFlagIsEnabled(_ key: String) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[key]?.lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }
}

extension UTType {
    static let twinleafTIO = UTType(exportedAs: "com.twinleaf.tio", conformingTo: .data)
    static var twinleafCSV: UTType { UTType(filenameExtension: "csv") ?? .plainText }
    static let twinleafHDF5 = UTType(importedAs: "org.hdfgroup.hdf5", conformingTo: .data)
    static let twinleafPlotColumns = UTType(exportedAs: "com.twarge.twinleaf.plot-columns", conformingTo: .json)
}

struct AvailableDevice: Codable, Hashable, Identifiable {
    var id: String { url }
    let url: String
    let label: String
    let kind: String
    let detail: String
    let routes: [AvailableDeviceRoute]

    init(
        url: String,
        label: String,
        kind: String,
        detail: String,
        routes: [AvailableDeviceRoute] = []
    ) {
        self.url = url
        self.label = label
        self.kind = kind
        self.detail = detail
        self.routes = routes
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case label
        case kind
        case detail
        case routes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        label = try container.decode(String.self, forKey: .label)
        kind = try container.decode(String.self, forKey: .kind)
        detail = try container.decode(String.self, forKey: .detail)
        routes = try container.decodeIfPresent([AvailableDeviceRoute].self, forKey: .routes) ?? []
    }
}

struct AvailableDeviceRoute: Codable, Hashable, Identifiable {
    var id: String { route }
    let route: String
    let name: String?

    var displayName: String {
        guard let name, !name.isEmpty else { return "(no name)" }
        return name
    }

    var isRoot: Bool {
        route.isEmpty || route == "/"
    }

    var depth: Int {
        guard !isRoot else { return 0 }
        return route.split(separator: "/", omittingEmptySubsequences: true).count
    }
}

struct ConnectionProgress: Equatable {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case discovering
        case metadata
        case streaming
        case cancelled
        case failed
    }

    var attemptID: UInt64 = 0
    var phase: Phase = .idle
    var deviceURL = ""
    var deviceLabel = ""
    var deviceKind = ""
    var message = "Idle"
    var startedAt: Date?
    var updatedAt: Date?
    var didEstablishLink = false
    var didLoadMetadata = false
    var didReceiveStreamValues = false
    var didReceiveRPCReply = false
    var deviceCount = 0
    var streamCount = 0
    var streamColumnCount = 0
    var rpcCount = 0
    var readableRPCCount = 0
    var rpcReplyCount = 0
    var rpcFailureCount = 0
    var streamValueCount = 0

    var isVisible: Bool {
        phase != .idle
    }

    var canCancel: Bool {
        if isReadyToDismiss {
            return false
        }
        switch phase {
        case .connecting, .connected, .discovering, .metadata, .streaming:
            return true
        case .idle, .cancelled, .failed:
            return false
        }
    }

    var isReadyToDismiss: Bool {
        phase == .streaming
    }

    var phaseTitle: String {
        switch phase {
        case .idle:
            "Idle"
        case .connecting:
            "Connecting"
        case .connected:
            "Sensor Link Established"
        case .discovering:
            "Discovering Device Routes"
        case .metadata:
            "Loading Metadata"
        case .streaming:
            isReadyToDismiss ? "Connected" : "Waiting for Live Evidence"
        case .cancelled:
            "Connection Canceled"
        case .failed:
            "Connection Failed"
        }
    }

    static func started(attemptID: UInt64, device: AvailableDevice) -> ConnectionProgress {
        ConnectionProgress(
            attemptID: attemptID,
            phase: .connecting,
            deviceURL: device.url,
            deviceLabel: device.label,
            deviceKind: device.kind,
            message: "Connecting to \(device.url)",
            startedAt: Date(),
            updatedAt: Date()
        )
    }
}

struct DeviceInfo: Codable, Hashable, Identifiable {
    var id: String { "\(url)#\(route)" }
    let url: String
    let route: String
    let meta: DeviceMeta
    var streams: [StreamInfo]
    var rpcs: [RpcInfo]
}

struct DeviceMeta: Codable, Hashable {
    let serialNumber: String
    let firmwareHash: String
    let nStreams: Int
    let sessionId: UInt32
    let name: String
}

struct StreamInfo: Codable, Hashable, Identifiable {
    var id: UInt8 { streamId }
    let streamId: UInt8
    let name: String
    let nColumns: Int
    let sampleSize: Int
    let effectiveSamplingRate: Double
    var columns: [ColumnInfo]
}

struct ColumnInfo: Codable, Hashable, Identifiable {
    var id: ColumnKey { key }
    let key: ColumnKey
    let name: String
    let units: String
    let dataType: String
    let description: String
    var displayValue: Double?
}

/// A channel computed from another column rather than received from a device.
///
/// The tag rides on `ColumnKey` so a derived channel is addressable exactly
/// like a raw column — panes, legends, drags and exports need no special case
/// — while clearing the tag recovers the source key. Parameters deliberately
/// live in `DerivedChannelSpec` instead of here, so retuning a channel
/// re-derives it in place rather than invalidating every pane selection and
/// saved layout that referenced it.
enum Derivation: String, Codable, Hashable, Sendable, CaseIterable {
    /// Robust white-noise ASD of the source column's spectrum, sampled over
    /// time. One point per cadence interval, in `source units/√Hz`.
    case noiseFloor

    var sortOrder: Int {
        switch self {
        case .noiseFloor: 0
        }
    }

    var title: String {
        switch self {
        case .noiseFloor: "Noise Floor"
        }
    }

    /// Units for a channel derived from a source measured in `units`.
    func units(fromSource units: String) -> String {
        switch self {
        case .noiseFloor: units.isEmpty ? "1/√Hz" : "\(units)/√Hz"
        }
    }

    func label(fromSource label: String) -> String {
        switch self {
        case .noiseFloor: "\(label) noise floor"
        }
    }
}

struct ColumnKey: Codable, Hashable, Comparable, Sendable {
    let route: String
    let streamId: UInt8
    let columnIndex: Int
    /// `nil` for a column received from a device.
    var derivation: Derivation? = nil

    var isDerived: Bool { derivation != nil }

    /// The raw column this key was derived from. Identity for a raw key.
    var source: ColumnKey {
        ColumnKey(route: route, streamId: streamId, columnIndex: columnIndex)
    }

    func derived(_ derivation: Derivation) -> ColumnKey {
        ColumnKey(
            route: route,
            streamId: streamId,
            columnIndex: columnIndex,
            derivation: derivation
        )
    }

    static func < (lhs: ColumnKey, rhs: ColumnKey) -> Bool {
        if lhs.route != rhs.route { return lhs.route < rhs.route }
        if lhs.streamId != rhs.streamId { return lhs.streamId < rhs.streamId }
        if lhs.columnIndex != rhs.columnIndex { return lhs.columnIndex < rhs.columnIndex }
        // Raw column first, then its derived channels in a stable order.
        return (lhs.derivation?.sortOrder ?? -1) < (rhs.derivation?.sortOrder ?? -1)
    }
}

/// How a derived channel is produced.
///
/// Window and cadence are independent knobs and both matter: the window sets
/// the frequency resolution and the statistical scatter of each estimate,
/// while the cadence only sets how often one is taken. With the defaults —
/// a 10 s window every 1 s — successive points share 90% of their input, so
/// the trace is smooth but adjacent points are correlated, not independent
/// measurements.
struct DerivedChannelSpec: Codable, Hashable, Identifiable, Sendable {
    /// Source key with `derivation` applied.
    var key: ColumnKey
    /// Seconds of source data behind each estimate.
    var windowSeconds: Double = DerivedChannelDefaults.windowSeconds
    /// Seconds between emitted points.
    var cadenceSeconds: Double = DerivedChannelDefaults.cadenceSeconds
    /// Mirrors the global FFT detrend; derived channels do not carry a second
    /// copy of that setting.
    var detrend: DetrendMethod = .quadratic

    var id: ColumnKey { key }
    var source: ColumnKey { key.source }
    var derivation: Derivation? { key.derivation }

    private enum CodingKeys: String, CodingKey {
        case key
        case windowSeconds
        case cadenceSeconds
        case detrend
    }
}

enum DerivedChannelDefaults {
    static let windowSeconds = 10.0
    static let cadenceSeconds = 1.0
    static let windowRange: ClosedRange<Double> = 1...1000
    static let cadenceRange: ClosedRange<Double> = 0.1...60

    static func clampedWindow(_ value: Double) -> Double {
        guard value.isFinite else { return windowSeconds }
        return min(max(value, windowRange.lowerBound), windowRange.upperBound)
    }

    static func clampedCadence(_ value: Double) -> Double {
        guard value.isFinite else { return cadenceSeconds }
        return min(max(value, cadenceRange.lowerBound), cadenceRange.upperBound)
    }
}

struct PlotPaneSelection: Hashable, Identifiable {
    let id: Int
    var viewConfig: ViewConfig = ViewConfig()
    var columns: Set<ColumnKey>

    var title: String {
        "Graph \(id + 1)"
    }
}

struct PlotPaneRestoreRequest: Hashable {
    var viewConfig: ViewConfig
    var columns: [ColumnKey]
}

struct PlotColumnDragPayload: Codable, Hashable, Sendable {
    let keys: [ColumnKey]
    let sourcePaneID: Int?

    static let contentType = UTType.twinleafPlotColumns

    init(keys: [ColumnKey], sourcePaneID: Int? = nil) {
        self.keys = Array(Set(keys)).sorted()
        self.sourcePaneID = sourcePaneID
    }

    var itemProvider: NSItemProvider {
        let provider = NSItemProvider()
        guard let data = try? JSONEncoder().encode(self) else { return provider }
        provider.registerDataRepresentation(
            forTypeIdentifier: Self.contentType.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func loadFirst(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor @Sendable (PlotColumnDragPayload?) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(Self.contentType.identifier)
        }) else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: Self.contentType.identifier) { data, _ in
            let payload = data.flatMap { try? JSONDecoder().decode(PlotColumnDragPayload.self, from: $0) }
            Task { @MainActor in
                completion(payload)
            }
        }
        return true
    }
}

enum PlotWindowDuration {
    static let defaultSeconds = 10.0
    static let range: ClosedRange<Double> = 1...1000

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSeconds }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

struct RpcInfo: Codable, Hashable, Identifiable {
    var id: String { "\(route)#\(name)" }
    let route: String
    let name: String
    let size: Int
    let permissions: String
    let argType: String
    let readable: Bool
    let writable: Bool
    let persistent: Bool
    let unknown: Bool
    var value: JSONValue?

    var hasMetadata: Bool {
        let type = argType.trimmingCharacters(in: .whitespacesAndNewlines)
        return !unknown && !type.isEmpty && type != "missing"
    }

    var isVisibleInRPCList: Bool {
        !name.isEmpty && !isInternalRPC && ((readable || writable) || isCaptureRPC)
    }

    var isInternalRPC: Bool {
        name.hasPrefix("rpc.")
    }

    var baseArgType: String {
        argType.split(separator: "<").first.map(String.init) ?? argType
    }

    var isNumericRPC: Bool {
        switch baseArgType {
        case "u8", "u16", "u32", "u64",
             "i8", "i16", "i32", "i64",
             "f32", "f64":
            true
        default:
            false
        }
    }

    var isIntegerRPC: Bool {
        switch baseArgType {
        case "u8", "u16", "u32", "u64",
             "i8", "i16", "i32", "i64":
            true
        default:
            false
        }
    }

    var isUnsignedIntegerRPC: Bool {
        switch baseArgType {
        case "u8", "u16", "u32", "u64":
            true
        default:
            false
        }
    }

    var isEnableSwitchRPC: Bool {
        hasMetadata && baseArgType == "bool"
    }

    var isActionRPC: Bool {
        writable && hasMetadata && baseArgType == "unit"
    }

    var isCaptureRPC: Bool {
        baseArgType == "capture" || name.hasSuffix(".capture")
    }

    var isSliderSuitable: Bool {
        readable && writable && hasMetadata && isNumericRPC && !isEnableSwitchRPC && !name.hasSuffix(".max")
    }
}

struct ViewConfig: Codable, Hashable {
    var mode: PlotMode = .timeseries
    var windowSeconds: Double = PlotWindowDuration.defaultSeconds
    var resolutionMultiplier: Int = 100
    var plotWidthPixels: Int = 800
    var decimationMethod: DecimationMethod = .fpcs
    var detrend: DetrendMethod = .quadratic
    var fftLogX: Bool = true
    var fftLogY: Bool = true
    /// Log vertical axis in timeseries mode. Separate from `fftLogY` so a pane
    /// toggling between modes keeps each axis choice.
    var logY: Bool = false
    /// Reduce the live spectrum to about one point per pixel; off plots every
    /// frequency bin.
    var fftDisplayDecimation: Bool = true

    enum CodingKeys: String, CodingKey {
        case mode
        case windowSeconds
        case resolutionMultiplier
        case plotWidthPixels
        case decimationMethod
        case detrend
        case fftLogX
        case fftLogY
        case logY
        case fftDisplayDecimation
    }
}

extension ViewConfig {
    /// Saved board layouts predate keys added since; a missing key keeps its
    /// default instead of discarding the whole layout. Lives in an extension
    /// so the memberwise and empty initializers stay synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(PlotMode.self, forKey: .mode) ?? mode
        windowSeconds = try container.decodeIfPresent(Double.self, forKey: .windowSeconds) ?? windowSeconds
        resolutionMultiplier = try container.decodeIfPresent(Int.self, forKey: .resolutionMultiplier) ?? resolutionMultiplier
        plotWidthPixels = try container.decodeIfPresent(Int.self, forKey: .plotWidthPixels) ?? plotWidthPixels
        decimationMethod = try container.decodeIfPresent(DecimationMethod.self, forKey: .decimationMethod) ?? decimationMethod
        detrend = try container.decodeIfPresent(DetrendMethod.self, forKey: .detrend) ?? detrend
        fftLogX = try container.decodeIfPresent(Bool.self, forKey: .fftLogX) ?? fftLogX
        fftLogY = try container.decodeIfPresent(Bool.self, forKey: .fftLogY) ?? fftLogY
        logY = try container.decodeIfPresent(Bool.self, forKey: .logY) ?? logY
        fftDisplayDecimation = try container.decodeIfPresent(Bool.self, forKey: .fftDisplayDecimation) ?? fftDisplayDecimation
    }
}

enum ViewPreferenceKeys {
    static let theme = "view.theme"
    static let distractionFree = "view.distractionFree"
    static let showStreamSidebar = "view.showStreamSidebar"
    static let showRPCPanel = "view.showRPCPanel"
    static let showLogPanel = "view.showLogPanel"
    static let showTerminalPanel = "view.showTerminalPanel"
    static let showStatusBar = "view.showStatusBar"
    static let showToolbar = "view.showToolbar"
    static let showStreamDetails = "view.showStreamDetails"
    static let showRPCDetails = "view.showRPCDetails"
    static let showPlotKey = "view.showPlotKey"
    static let streamSidebarWidth = "view.streamSidebarWidth"
    static let rpcPanelWidth = "view.rpcPanelWidth"
    static let defaultWindowSeconds = "view.defaultWindowSeconds"
    static let logOnStartup = "view.logOnStartup"
    static let rpcFloatPrecisionPPM = "view.rpcFloatPrecisionPPM"
    static let rpcSliderRateLimitHz = "view.rpcSliderRateLimitHz"
    static let logMessageLineLimit = "view.logMessageLineLimit"
    static let traceColorPalette = "view.traceColorPalette"
    static let traceColorPaletteLight = "view.traceColorPaletteLight"
    static let traceColorPaletteDark = "view.traceColorPaletteDark"
    static let favoriteRPCs = "view.favoriteRPCs"
    static let suppressCommHubDefaultPlot = "view.suppressCommHubDefaultPlot"
    static let yAxisHysteresis = "view.yAxisHysteresis"
    static let fftAxisHysteresis = "view.fftAxisHysteresis"
    static let noiseFloorWindowSeconds = "view.noiseFloorWindowSeconds"
    static let noiseFloorCadenceSeconds = "view.noiseFloorCadenceSeconds"
    static let captureAutoDelaySeconds = "view.captureAutoDelaySeconds"
    static let boardViewLayouts = "view.boardViewLayouts"
    static let showAllSerialPorts = "view.showAllSerialPorts"
    static let unifySensors = "view.unifySensors"
}

enum CaptureAutoDelay {
    static let defaultSeconds = 0.5
    static let range: ClosedRange<Double> = 0.05...10

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSeconds }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

enum PlotAxisHysteresis {
    static let defaultFraction = 0.25
    static let range: ClosedRange<Double> = 0...0.95

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultFraction }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

enum ThemePreference: String, Codable, Hashable, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

enum PlotTracePalette {
    static let colorCount = 5
    static let defaultLightHexColors = [
        "#3B8F6D",
        "#497FC2",
        "#B8753B",
        "#B35F73",
        "#7E69B4"
    ]
    static let defaultDarkHexColors = [
        "#7FD9A3",
        "#82B6F0",
        "#E7B06D",
        "#E58DA0",
        "#B99ADF"
    ]
    static let defaultHexColors = defaultLightHexColors
    static let defaultLightRawValue = defaultLightHexColors.joined(separator: ",")
    static let defaultDarkRawValue = defaultDarkHexColors.joined(separator: ",")
    static let defaultRawValue = defaultLightRawValue

    static func hexColors(from rawValue: String, defaults: [String] = defaultHexColors) -> [String] {
        let parsed = rawValue
            .split(separator: ",")
            .compactMap { normalizedHex(String($0)) }
        var colors = Array(parsed.prefix(colorCount))

        if colors.count < colorCount {
            colors.append(contentsOf: defaults.dropFirst(colors.count))
        }
        return colors
    }

    static func rawValue(from hexColors: [String], defaults: [String] = defaultHexColors) -> String {
        (0..<colorCount)
            .map { index in
                if index < hexColors.count,
                   let hex = normalizedHex(hexColors[index]) {
                    return hex
                }
                return defaults[index]
            }
            .joined(separator: ",")
    }

    static func normalizedHex(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6,
              hex.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return "#\(hex.uppercased())"
    }
}

enum LogMessageScrollback {
    static let defaultLineLimit = 100
    static let range: ClosedRange<Int> = 1...100_000

    static func clamped(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Why a raw (terminal) RPC call produced no reply bytes.
enum RawRpcError: LocalizedError, Equatable {
    case notConnected
    /// The bridge never answered; the device's own timeout is much shorter
    /// and arrives as `failed`.
    case timedOut
    /// The bridge's message, plus the device's error code when it refused.
    case failed(message: String, code: UInt16?)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to a device"
        case .timedOut:
            "No reply from the device bridge"
        case .failed(let message, _):
            message
        }
    }
}

struct LogMessage: Hashable, Identifiable {
    let id = UUID()
    let route: String
    let timestampSeconds: Double
    let message: String

    init(route: String, timestampSeconds: Double, message: String) {
        self.route = route
        self.timestampSeconds = timestampSeconds
        self.message = message
    }
}

enum PlotMode: String, Codable, Hashable, CaseIterable, Identifiable {
    case timeseries
    case fft

    var id: String { rawValue }
    var title: String {
        switch self {
        case .timeseries: "Time"
        case .fft: "FFT"
        }
    }
}

enum VerticalAxisMode: String, Codable, Hashable, CaseIterable, Identifiable {
    case independent
    case shared

    var id: String { rawValue }

    var title: String {
        switch self {
        case .independent: "Independent"
        case .shared: "Shared"
        }
    }
}

enum DetrendMethod: String, Codable, Hashable, CaseIterable, Identifiable {
    case none
    case mean
    case linear
    case quadratic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .mean: "Mean"
        case .linear: "Linear"
        case .quadratic: "Quadratic"
        }
    }
}

enum DecimationMethod: String, Codable, Hashable, CaseIterable, Identifiable {
    case none
    case fpcs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Raw"
        case .fpcs: "FPCS"
        }
    }
}

enum ExportFormat: String, Codable, Hashable, CaseIterable, Identifiable {
    case csv
    case hdf5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .csv: "CSV"
        case .hdf5: "HDF5"
        }
    }

    var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .hdf5: "h5"
        }
    }

    var contentType: UTType {
        switch self {
        case .csv: .twinleafCSV
        case .hdf5: .twinleafHDF5
        }
    }

    var acceptedExtensions: Set<String> {
        switch self {
        case .csv: ["csv"]
        case .hdf5: ["h5", "hdf5"]
        }
    }

    func normalizedURL(_ url: URL) -> URL {
        if acceptedExtensions.contains(url.pathExtension.lowercased()) {
            return url
        }
        return url.deletingPathExtension().appendingPathExtension(fileExtension)
    }
}

struct PlotPoint: Codable {
    let x: Double
    let y: Double
}

// Intentionally not Hashable/Equatable: SwiftUI must not deep-compare points
// arrays on every frame. Identity/freshness is gated by the per-pane revision
// token assigned in BridgeClient.applyPlotSnapshot.
struct PlotSeries: Codable, Identifiable {
    var id: ColumnKey { key }
    let key: ColumnKey
    let label: String
    let units: String
    let sampleRate: Double
    let points: [PlotPoint]
    /// Robust white-noise ASD estimate for FFT data, in `units/sqrt(Hz)`.
    var noiseFloor: Double? = nil
    /// True when the column has live data but none of it falls inside the
    /// pane's displayed time window (its time reference is incompatible with
    /// the pane's anchor stream). Shown with a warning in the legend.
    var isOutsideTimeWindow = false
    /// True for a derived channel that has not yet accumulated a full source
    /// window. Nothing is wrong — there is simply no estimate yet — so the
    /// legend says so rather than showing the time-reference warning or
    /// dropping the trace entirely.
    var isWarmingUp = false

    /// Both states mean "no trace to draw right now", so the legend entry is
    /// shown subdued either way; only the trailing annotation differs.
    var isDimmedInLegend: Bool { isOutsideTimeWindow || isWarmingUp }
}

enum JSONValue: Codable, Hashable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int64.self) {
            self = .number(Double(int))
        } else if let double = try? container.decode(Double.self) {
            self = .number(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var description: String {
        switch self {
        case .string(let value):
            value
        case .number(let value):
            value.formatted(.number.precision(.significantDigits(6)))
        case .bool(let value):
            value ? "true" : "false"
        case .object(let value):
            "\(value)"
        case .array(let value):
            value.map(\.description).joined(separator: ", ")
        case .null:
            "null"
        }
    }

    var editableText: String {
        switch self {
        case .string(let value):
            value
        case .number(let value):
            String(format: "%.17g", value)
        case .bool(let value):
            value ? "true" : "false"
        case .object(let value):
            "\(value)"
        case .array(let value):
            value.map(\.editableText).joined(separator: ", ")
        case .null:
            ""
        }
    }

    var numberValue: Double? {
        switch self {
        case .number(let value):
            value
        default:
            nil
        }
    }

    func rpcDisplayText(argType: String, floatPrecisionPPM: Double) -> String {
        switch self {
        case .number(let value) where Self.isFloatingPointRPCType(argType):
            NumericDisplayPolicy.rpcFloat(value, precisionPPM: floatPrecisionPPM)
        default:
            editableText
        }
    }

    private static func isFloatingPointRPCType(_ argType: String) -> Bool {
        switch argType.split(separator: "<").first.map(String.init) ?? argType {
        case "f32", "f64":
            true
        default:
            false
        }
    }
}
