// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

private protocol BridgeRuntime: AnyObject {
    func listDevices(includeAll: Bool)
    func connect(url: String, route: String, logPath: String?)
    func setLogging(enabled: Bool, logPath: String?)
    func openLog(path: String)
    func exportLog(requestId: String, sourcePath: String, outputPath: String, format: ExportFormat)
    func disconnect()
    func setPlayback(position: Double)
    func copyViewData(requestId: String, paneID: Int, viewportEnd: Double?)
    func setPlotPanes(_ panes: [PlotPaneSelection])
    func setView(_ view: ViewConfig)
    func callRpc(requestId: String, route: String, name: String, argument: Any?)
    func checkUpgrade()
    func performUpgrade(route: String)
}

#if os(macOS) || TWINLEAF_STATIC_RUST
extension RustRuntime: BridgeRuntime {}
#else
private final class UnavailableBridgeRuntime: BridgeRuntime {
    func listDevices(includeAll: Bool) {}
    func connect(url: String, route: String, logPath: String?) {}
    func setLogging(enabled: Bool, logPath: String?) {}
    func openLog(path: String) {}
    func exportLog(requestId: String, sourcePath: String, outputPath: String, format: ExportFormat) {}
    func disconnect() {}
    func setPlayback(position: Double) {}
    func copyViewData(requestId: String, paneID: Int, viewportEnd: Double?) {}
    func setPlotPanes(_ panes: [PlotPaneSelection]) {}
    func setView(_ view: ViewConfig) {}
    func callRpc(requestId: String, route: String, name: String, argument: Any?) {}
    func checkUpgrade() {}
    func performUpgrade(route: String) {}
}
#endif

private struct RPCValueUpdate {
    let route: String
    let name: String
    let value: JSONValue
}

private struct StreamDisplayValue {
    var value: Double
    var updatedAt: Date
}

private func logDeviceDiscovery(_ message: String) {
    TwinleafConsole.debug("[Twinleaf][DeviceDiscovery] \(message)")
}

@MainActor
final class PlotFrameStore: ObservableObject {
    struct FrameState {
        var series: [PlotSeries] = []
        var mode: PlotMode = .timeseries
        var viewportEnd: Double?
        var revision: UInt64 = 0
    }

    private var paneFrames: [Int: FrameState] = [:]
    private(set) var latestViewportEnd: Double?

    func apply(
        paneID: Int,
        mode: PlotMode,
        viewportEnd: Double?,
        series: [PlotSeries],
        revision: UInt64
    ) {
        objectWillChange.send()
        latestViewportEnd = viewportEnd
        paneFrames[paneID] = FrameState(
            series: series,
            mode: mode,
            viewportEnd: viewportEnd,
            revision: revision
        )
    }

    func removePane(id: Int) {
        guard paneFrames[id] != nil else { return }
        objectWillChange.send()
        paneFrames[id] = nil
    }

    func clear() {
        guard !paneFrames.isEmpty else { return }
        objectWillChange.send()
        paneFrames.removeAll()
    }

    func resetViewportEnd() {
        guard latestViewportEnd != nil else { return }
        objectWillChange.send()
        latestViewportEnd = nil
    }

    func setViewportEnd(_ viewportEnd: Double?) {
        guard latestViewportEnd != viewportEnd else { return }
        objectWillChange.send()
        latestViewportEnd = viewportEnd
    }

    func series(for pane: PlotPaneSelection, maxCount: Int) -> [PlotSeries] {
        Array((paneFrames[pane.id]?.series ?? []).prefix(maxCount))
    }

    func mode(for pane: PlotPaneSelection) -> PlotMode {
        paneFrames[pane.id]?.mode ?? pane.viewConfig.mode
    }

    func viewportEnd(for pane: PlotPaneSelection) -> Double? {
        paneFrames[pane.id]?.viewportEnd ?? latestViewportEnd
    }

    func viewportEnd(forPaneID paneID: Int) -> Double? {
        paneFrames[paneID]?.viewportEnd ?? latestViewportEnd
    }

    func revision(for pane: PlotPaneSelection) -> UInt64 {
        paneFrames[pane.id]?.revision ?? 0
    }
}

@MainActor
final class BridgeClient: ObservableObject {
    static let maxPlotPaneCount = 5
    static let maxPlotLineCount = PlotTracePalette.colorCount

    @Published var availableDevices: [AvailableDevice] = []
    @Published private(set) var rememberedDeviceURLs: [String] = []
    @Published var devices: [DeviceInfo] = []
    @Published private(set) var activeColumns: Set<ColumnKey> = []
    @Published private(set) var plotPanes: [PlotPaneSelection] = [
        PlotPaneSelection(id: 0, columns: [])
    ]
    let plotFrames = PlotFrameStore()
    @Published var viewConfig = ViewConfig()
    @Published var isPlotPaused = false
    @Published var status = "Idle"
    @Published var statusState = "idle"
    @Published var errors: [String] = []
    /// Devices with a newer published firmware available (from the lazy check).
    @Published private(set) var availableUpgrades: [FirmwareUpgrade] = []
    /// Live progress of an in-flight firmware flash, or nil when none is running.
    @Published private(set) var upgradeProgress: FirmwareUpgradeProgress?
    /// Per-stream timing/rate diagnostics (mirrors `tio health`), refreshed
    /// continuously while connected.
    @Published private(set) var streamHealth: [StreamHealthInfo] = []
    @Published private(set) var logMessages: [LogMessage] = []
    @Published private(set) var logRevision: UInt64 = 0
    @Published private(set) var isInspectionMode = false
    @Published private(set) var playbackStart: Double = 0
    @Published private(set) var playbackEnd: Double = 0
    @Published var playbackPosition: Double = 0
    @Published private(set) var logBytes: UInt64 = 0
    @Published private(set) var logStartSeconds: Double?
    @Published private(set) var logElapsedSeconds: Double?
    @Published private(set) var logTimeReferenceStartSeconds: Double?
    @Published private(set) var livePlotStartSeconds: Double?
    @Published private(set) var logPackets: UInt64 = 0
    @Published private(set) var logSerializeErrors: UInt64 = 0
    @Published private(set) var rpcCacheNeedsReload = false
    @Published private(set) var rpcValueChangeToken: UInt64 = 0
    @Published private(set) var rpcReplyChangeToken: UInt64 = 0
    @Published private(set) var deviceDiscoverySummary = ""
    @Published private(set) var connectionProgress = ConnectionProgress()
    private var rpcValueRevisions: [String: UInt64] = [:]
    private var rpcReplyRevisions: [String: UInt64] = [:]

    private var runtime: (any BridgeRuntime)?
    private var discoveredDevices: [AvailableDevice] = []
    #if os(iOS)
    private var mdnsDevices: [AvailableDevice] = []
    private lazy var bonjourBrowser: BonjourDeviceBrowser = {
        let browser = BonjourDeviceBrowser()
        browser.onChange = { [weak self] devices in
            guard let self else { return }
            self.mdnsDevices = devices
            self.refreshAvailableDevices()
        }
        return browser
    }()
    #endif
    private var pendingPlotSnapshots: [Int: PlotSnapshot] = [:]
    private var lastLogRevisionMark = Date.distantPast
    private var nextPlotPaneID = 1
    private var nextPlotRevision: UInt64 = 1
    private var latestWriteRequestIDByRPCID: [String: String] = [:]
    private var writeRPCIDByRequestID: [String: String] = [:]
    private var lastRPCReadbackAtByRPCID: [String: Date] = [:]
    private var pendingRPCReadbackWorkItems: [String: DispatchWorkItem] = [:]
    private var pendingRPCReadbackGenerations: [String: UInt64] = [:]
    private var nextRPCReadbackGeneration: UInt64 = 1
    private var pendingRPCPreviewValues: [String: RPCValueUpdate] = [:]
    private var isRPCPreviewFlushScheduled = false
    private var streamDisplayValues: [ColumnKey: StreamDisplayValue] = [:]
    private var lastStreamDisplayPublishAt = Date.distantPast
    private var pendingStreamDisplayFlush: DispatchWorkItem?
    private var shouldRetryAllSerialAfterStrictDiscovery = false
    private var nextConnectionAttemptID: UInt64 = 1
    private var connectionRPCReadbackRequestIDs: Set<String> = []
    private let decoder = JSONDecoder()
    private static let rememberedURLsDefaultsKey = "rememberedDeviceURLs"
    private static let rpcReadbackInterval: TimeInterval = 2
    private static let streamDisplayUpdateInterval: TimeInterval = 0.2
    private static let streamDisplayEMATimeConstant: TimeInterval = 0.4

    /// Stable identifier used by the iPad popout-window registry so that a
    /// separate `WindowGroup` scene can find its parent document's bridge.
    /// `nonisolated` so `deinit` (which may run off the main actor) can read it.
    nonisolated let sessionID = UUID()

    init() {
        let defaultWindowSeconds = Self.loadDefaultWindowSeconds()
        viewConfig.windowSeconds = defaultWindowSeconds
        plotPanes = [PlotPaneSelection(id: 0, viewConfig: viewConfig, columns: [])]
        rememberedDeviceURLs = Self.loadRememberedDeviceURLs()
        refreshAvailableDevices()
        logDeviceDiscovery("BridgeClient initialized rememberedURLs=\(rememberedDeviceURLs.count) available=\(availableDevices.count) sessionID=\(sessionID)")
        BridgeSessionRegistry.shared.register(self)
    }

    deinit {
        BridgeSessionRegistry.shared.unregister(sessionID: sessionID)
    }

    var latestLogMessage: LogMessage? {
        logMessages.last
    }

    func startIfNeeded() {
        guard runtime == nil else {
            logDeviceDiscovery("startIfNeeded reused existing runtime")
            return
        }
        logDeviceDiscovery("startIfNeeded creating Rust runtime")
        statusState = "starting"
        status = "Starting Twinleaf runtime"
#if os(macOS) || TWINLEAF_STATIC_RUST
        do {
            runtime = try RustRuntime(owner: self)
            logDeviceDiscovery("Rust runtime created")
        } catch {
            logDeviceDiscovery("Rust runtime failed: \(error.localizedDescription)")
            appendError("Failed to load Twinleaf Rust core: \(error.localizedDescription)")
            status = error.localizedDescription
            statusState = "error"
        }
#else
        runtime = UnavailableBridgeRuntime()
        let message = "Twinleaf runtime is not available on iPad yet"
        appendError(message)
        status = message
        statusState = "error"
#endif
    }

    func listDevices(includeAllSerial: Bool? = nil) {
        startIfNeeded()
        #if os(iOS)
        // Browse the local network natively on iOS (the Rust core's raw-socket
        // mDNS is macOS-only). Idempotent; keeps running and republishes as
        // devices appear or vanish.
        bonjourBrowser.start()
        #endif
        refreshAvailableDevices()
        let includeAll = includeAllSerial ?? Self.loadShowAllSerialPorts()
        shouldRetryAllSerialAfterStrictDiscovery = !includeAll
        logDeviceDiscovery(
            "listDevices requested includeAll=\(includeAll) explicit=\(includeAllSerial.map(String.init(describing:)) ?? "nil") " +
            "storedShowAll=\(Self.loadShowAllSerialPorts()) runtime=\(runtime == nil ? "nil" : "ready") " +
            "remembered=\(rememberedDeviceURLs.count) discovered=\(discoveredDevices.count) available=\(availableDevices.count)"
        )
        runtime?.listDevices(includeAll: includeAll)
    }

    func debugDevicePicker(_ message: String) {
        logDeviceDiscovery("DevicePicker \(message)")
    }

    func connect(to device: AvailableDevice, logURL: URL?) {
        startIfNeeded()
        logDeviceDiscovery("connect selected url=\(device.url) kind=\(device.kind) label=\(device.label)")
        let attemptID = nextConnectionAttemptID
        nextConnectionAttemptID &+= 1
        connectionRPCReadbackRequestIDs.removeAll()
        connectionProgress = .started(attemptID: attemptID, device: device)
        availableUpgrades = []
        upgradeProgress = nil
        streamHealth = []
        isInspectionMode = false
        rpcCacheNeedsReload = false
        clearLogMessages()
        clearRPCReadbackState()
        clearStreamDisplayValues()
        plotFrames.resetViewportEnd()
        updateLogFileSize(at: logURL)
        resetLogTiming()
        resetLivePlotTiming()
        logPackets = 0
        logSerializeErrors = 0
        resetPlotPanes()
        clearPlotOutput()
        isPlotPaused = false
        guard runtime != nil else {
            markConnectionFailed(status.isEmpty ? "Twinleaf runtime is unavailable" : status)
            return
        }
        runtime?.connect(url: device.url, route: "/", logPath: logURL?.path)
        sendPlotPanes()
    }

    func openLogFile(at url: URL) {
        startIfNeeded()
        isInspectionMode = true
        isPlotPaused = true
        rpcCacheNeedsReload = false
        streamHealth = []
        clearLogMessages()
        clearRPCReadbackState()
        clearStreamDisplayValues()
        updateLogFileSize(at: url)
        resetLogTiming()
        resetLivePlotTiming()
        logPackets = 0
        logSerializeErrors = 0
        resetPlotPanes()
        devices.removeAll()
        clearPlotOutput()
        playbackStart = 0
        playbackEnd = 0
        playbackPosition = 0
        plotFrames.resetViewportEnd()
        statusState = "loading"
        status = "Loading \(url.lastPathComponent)"
        runtime?.openLog(path: url.path)
        sendPlotPanes()
    }

    func disconnect() {
        runtime?.disconnect()
        isInspectionMode = false
        rpcCacheNeedsReload = false
        clearRPCReadbackState()
        clearStreamDisplayValues()
        connectionRPCReadbackRequestIDs.removeAll()
        connectionProgress = ConnectionProgress()
        plotFrames.resetViewportEnd()
        resetLogTiming()
        resetLivePlotTiming()
        resetPlotPanes()
        clearPlotOutput()
        isPlotPaused = false
        availableUpgrades = []
        upgradeProgress = nil
        streamHealth = []
    }

    /// Re-run the lazy firmware-availability check for the active session.
    func checkUpgrade() {
        runtime?.checkUpgrade()
    }

    /// Dismiss a finished (complete/error) upgrade progress display.
    func clearUpgradeProgress() {
        upgradeProgress = nil
    }

    /// Begin flashing the latest published firmware to the device at `route`.
    func performUpgrade(route: String) {
        guard !isInspectionMode else { return }
        upgradeProgress = FirmwareUpgradeProgress(
            route: route,
            phase: .starting,
            message: "Preparing upgrade…",
            fraction: nil
        )
        runtime?.performUpgrade(route: route)
    }

    func cancelConnection() {
        guard connectionProgress.canCancel else { return }
        runtime?.disconnect()
        clearRPCReadbackState()
        clearStreamDisplayValues()
        connectionRPCReadbackRequestIDs.removeAll()
        resetLivePlotTiming()
        updateConnectionProgress { progress in
            progress.phase = .cancelled
            progress.message = "Connection canceled"
        }
        statusState = "disconnected"
        status = "Connection canceled"
    }

    func setLogging(enabled: Bool, logURL: URL?) {
        startIfNeeded()
        guard enabled, let logURL else {
            runtime?.setLogging(enabled: false, logPath: nil)
            logBytes = 0
            logPackets = 0
            logSerializeErrors = 0
            resetLogTiming()
            return
        }

        updateLogFileSize(at: logURL)
        resetLogTiming()
        logPackets = 0
        logSerializeErrors = 0
        runtime?.setLogging(enabled: true, logPath: logURL.path)
    }

    func setColumn(_ key: ColumnKey, enabled: Bool) {
        guard let paneID = plotPanes.first?.id else {
            if enabled {
                addPlotPane(columns: [key])
            }
            return
        }
        setColumn(key, in: paneID, enabled: enabled)
    }

    func setColumn(_ key: ColumnKey, in paneID: Int, enabled: Bool) {
        setColumns([key], in: paneID, enabled: enabled)
    }

    func setColumns(_ keys: [ColumnKey], enabled: Bool) {
        guard let paneID = plotPanes.first?.id else {
            if enabled {
                addPlotPane(columns: keys)
            }
            return
        }
        setColumns(keys, in: paneID, enabled: enabled)
    }

    func setColumns(_ keys: [ColumnKey], in paneID: Int, enabled: Bool) {
        guard let index = plotPanes.firstIndex(where: { $0.id == paneID }) else { return }
        if enabled {
            plotPanes[index].columns = columnsByAdding(keys, to: plotPanes[index].columns)
        } else {
            plotPanes[index].columns.subtract(normalizedPlotKeys(keys))
        }
        updateRuntimePlotPanes()
    }

    func toggleColumnsInLowestPlot(_ keys: [ColumnKey]) {
        guard !keys.isEmpty else {
            return
        }
        guard let paneID = plotPanes.last?.id else {
            addPlotPane(columns: keys)
            return
        }
        setColumns(keys, in: paneID, enabled: !areColumns(keys, selectedIn: paneID))
    }

    func areColumnsSelectedInLowestPlot(_ keys: [ColumnKey]) -> Bool {
        guard !keys.isEmpty,
              let paneID = plotPanes.last?.id else {
            return false
        }
        return areColumns(keys, selectedIn: paneID)
    }

    func dropPlotColumns(_ payload: PlotColumnDragPayload, into targetPaneID: Int) {
        let keys = normalizedPlotKeys(payload.keys)
        guard !keys.isEmpty,
              let targetIndex = plotPanes.firstIndex(where: { $0.id == targetPaneID }) else {
            return
        }

        let updatedTargetColumns = columnsByAdding(keys, to: plotPanes[targetIndex].columns)
        let acceptedKeys = Set(keys).intersection(updatedTargetColumns)
        plotPanes[targetIndex].columns = updatedTargetColumns
        if let sourcePaneID = payload.sourcePaneID,
           sourcePaneID != targetPaneID,
           let sourceIndex = plotPanes.firstIndex(where: { $0.id == sourcePaneID }) {
            plotPanes[sourceIndex].columns.subtract(acceptedKeys)
        }
        updateRuntimePlotPanes()
    }

    @discardableResult
    func addPlotPane() -> Int? {
        guard plotPanes.count < Self.maxPlotPaneCount else { return nil }
        let id = nextPlotPaneID
        plotPanes.append(PlotPaneSelection(id: id, viewConfig: viewConfig, columns: []))
        nextPlotPaneID += 1
        sendPlotPanes()
        return id
    }

    @discardableResult
    func addPlotPane(columns keys: [ColumnKey]) -> Int? {
        guard !keys.isEmpty,
              plotPanes.count < Self.maxPlotPaneCount else {
            return nil
        }
        let id = nextPlotPaneID
        plotPanes.append(PlotPaneSelection(
            id: id,
            viewConfig: viewConfig,
            columns: limitedColumnSet(from: keys)
        ))
        nextPlotPaneID += 1
        updateRuntimePlotPanes()
        return id
    }

    var canAddPlotPane: Bool {
        plotPanes.count < Self.maxPlotPaneCount
    }

    func removePlotPane(id: Int) {
        guard let index = plotPanes.firstIndex(where: { $0.id == id }) else { return }
        plotPanes.remove(at: index)
        plotFrames.removePane(id: id)
        pendingPlotSnapshots[id] = nil
        updateRuntimePlotPanes()
    }

    func movePlotPane(id: Int, by offset: Int) {
        guard offset != 0,
              let sourceIndex = plotPanes.firstIndex(where: { $0.id == id }) else {
            return
        }
        let targetIndex = max(0, min(plotPanes.count - 1, sourceIndex + offset))
        guard targetIndex != sourceIndex else { return }
        let pane = plotPanes.remove(at: sourceIndex)
        plotPanes.insert(pane, at: targetIndex)
        updateRuntimePlotPanes()
    }

    @discardableResult
    func replacePlotPanes(with requests: [PlotPaneRestoreRequest]) -> [Int] {
        clearPlotOutput()
        plotPanes.removeAll()

        var restoredIDs: [Int] = []
        for request in requests.prefix(Self.maxPlotPaneCount) {
            let id = nextPlotPaneID
            nextPlotPaneID += 1
            restoredIDs.append(id)
            plotPanes.append(PlotPaneSelection(
                id: id,
                viewConfig: request.viewConfig,
                columns: limitedColumnSet(from: request.columns)
            ))
        }

        updateRuntimePlotPanes()
        return restoredIDs
    }

    func isColumn(_ key: ColumnKey, selectedIn paneID: Int) -> Bool {
        plotPanes.first { $0.id == paneID }?.columns.contains(key) ?? false
    }

    func areColumns(_ keys: [ColumnKey], selectedIn paneID: Int) -> Bool {
        let normalizedKeys = normalizedPlotKeys(keys)
        guard !normalizedKeys.isEmpty,
              let pane = plotPanes.first(where: { $0.id == paneID }) else {
            return false
        }
        return normalizedKeys.allSatisfy { pane.columns.contains($0) }
    }

    func plotSeries(for pane: PlotPaneSelection) -> [PlotSeries] {
        plotFrames.series(for: pane, maxCount: Self.maxPlotLineCount)
    }

    func plotMode(for pane: PlotPaneSelection) -> PlotMode {
        plotFrames.mode(for: pane)
    }

    func displayedWindowSeconds(for pane: PlotPaneSelection) -> Double {
        pane.viewConfig.windowSeconds
    }

    var plotTimeOriginSeconds: Double? {
        isInspectionMode ? logStartSeconds : livePlotStartSeconds
    }

    func viewportEnd(for pane: PlotPaneSelection) -> Double? {
        plotFrames.viewportEnd(for: pane)
    }

    func plotRevision(for pane: PlotPaneSelection) -> UInt64 {
        plotFrames.revision(for: pane)
    }

    func viewConfig(for paneID: Int) -> ViewConfig {
        plotPanes.first { $0.id == paneID }?.viewConfig ?? viewConfig
    }

    func setViewMode(_ mode: PlotMode) {
        guard viewConfig.mode != mode else { return }
        viewConfig.mode = mode
        updateAllPaneViewConfigs { $0.mode = mode }
    }

    func setViewMode(_ mode: PlotMode, for paneID: Int) {
        guard let index = plotPanes.firstIndex(where: { $0.id == paneID }) else { return }

        var nextViewConfig = plotPanes[index].viewConfig
        nextViewConfig.mode = mode
        if mode == .fft {
            nextViewConfig.windowSeconds = viewConfig.windowSeconds
        }

        guard plotPanes[index].viewConfig != nextViewConfig else {
            return
        }
        plotPanes[index].viewConfig = nextViewConfig
        if index == 0 {
            viewConfig.mode = mode
            viewConfig.windowSeconds = nextViewConfig.windowSeconds
        }
        updateRuntimePlotPanes()
    }

    func setWindowSeconds(_ seconds: Double) {
        let clamped = Self.clampedDisplayWindowSeconds(seconds)
        guard abs(viewConfig.windowSeconds - clamped) >= 0.01 else { return }
        viewConfig.windowSeconds = clamped
        updateAllPaneViewConfigs { $0.windowSeconds = clamped }
    }

    func panTimeseriesViewport(by deltaSeconds: Double) {
        guard isInspectionMode, deltaSeconds.isFinite, abs(deltaSeconds) > 0 else { return }
        setPlaybackPosition(playbackPosition + deltaSeconds)
    }

    func zoomTimeseriesWindow(by scale: Double, anchorFraction: Double) {
        guard scale.isFinite, scale > 0 else { return }

        let oldWindow = max(viewConfig.windowSeconds, 1e-6)
        let newWindow = Self.clampedDisplayWindowSeconds(oldWindow / scale)
        guard abs(oldWindow - newWindow) >= 0.01 else { return }

        let anchor = min(max(anchorFraction, 0), 1)
        let viewportEnd = plotFrames.latestViewportEnd ?? playbackPosition
        let anchorTime = viewportEnd - oldWindow + anchor * oldWindow
        let adjustedViewportEnd = anchorTime + (1 - anchor) * newWindow

        setWindowSeconds(newWindow)

        if isInspectionMode, hasPlaybackRange {
            setPlaybackPosition(adjustedViewportEnd)
        }
    }

    func setDetrend(_ detrend: DetrendMethod) {
        guard viewConfig.detrend != detrend else { return }
        viewConfig.detrend = detrend
        updateAllPaneViewConfigs { $0.detrend = detrend }
    }

    func setFFTLogX(_ enabled: Bool) {
        guard viewConfig.fftLogX != enabled else { return }
        viewConfig.fftLogX = enabled
        updateAllPaneViewConfigs { $0.fftLogX = enabled }
    }

    func setFFTLogX(_ enabled: Bool, for paneID: Int) {
        guard let index = plotPanes.firstIndex(where: { $0.id == paneID }),
              plotPanes[index].viewConfig.fftLogX != enabled else {
            return
        }
        plotPanes[index].viewConfig.fftLogX = enabled
        if index == 0 {
            viewConfig.fftLogX = enabled
        }
        updateRuntimePlotPanes()
    }

    func setFFTLogY(_ enabled: Bool) {
        guard viewConfig.fftLogY != enabled else { return }
        viewConfig.fftLogY = enabled
        updateAllPaneViewConfigs { $0.fftLogY = enabled }
    }

    func setFFTLogY(_ enabled: Bool, for paneID: Int) {
        guard let index = plotPanes.firstIndex(where: { $0.id == paneID }),
              plotPanes[index].viewConfig.fftLogY != enabled else {
            return
        }
        plotPanes[index].viewConfig.fftLogY = enabled
        if index == 0 {
            viewConfig.fftLogY = enabled
        }
        updateRuntimePlotPanes()
    }

    func setDecimationMethod(_ method: DecimationMethod) {
        guard viewConfig.decimationMethod != method else { return }
        viewConfig.decimationMethod = method
        updateAllPaneViewConfigs { $0.decimationMethod = method }
    }

    func setResolutionMultiplier(_ multiplier: Int) {
        let clamped = min(200, max(20, multiplier))
        guard viewConfig.resolutionMultiplier != clamped else { return }
        viewConfig.resolutionMultiplier = clamped
        updateAllPaneViewConfigs { $0.resolutionMultiplier = clamped }
    }

    func setPlotWidthPixels(_ width: Double) {
        let rounded = max(64, Int(width.rounded()))
        guard abs(viewConfig.plotWidthPixels - rounded) >= 16 else { return }
        viewConfig.plotWidthPixels = rounded
        updateAllPaneViewConfigs { $0.plotWidthPixels = rounded }
    }

    func togglePlotPaused() {
        setPlotPaused(!isPlotPaused)
    }

    func setPlotPaused(_ paused: Bool) {
        guard !isInspectionMode else {
            isPlotPaused = true
            return
        }
        guard isPlotPaused != paused else { return }
        isPlotPaused = paused

        if paused {
            pendingPlotSnapshots.removeAll()
        } else if !pendingPlotSnapshots.isEmpty {
            for snapshot in pendingPlotSnapshots.values {
                applyPlotSnapshot(snapshot)
            }
            pendingPlotSnapshots.removeAll()
        }
    }

    func setPlaybackPosition(_ position: Double) {
        guard isInspectionMode else { return }
        let clamped = min(max(position, playbackSliderRange.lowerBound), playbackSliderRange.upperBound)
        playbackPosition = clamped
        plotFrames.setViewportEnd(clamped)
        runtime?.setPlayback(position: clamped)
    }

    var hasPlaybackRange: Bool {
        playbackEnd > playbackStart
    }

    var canScrubPlayback: Bool {
        playbackEnd - playbackStart > maximumWindowSeconds
    }

    var playbackSliderRange: ClosedRange<Double> {
        guard hasPlaybackRange else { return 0...0 }
        let lowerBound = min(playbackStart + maximumWindowSeconds, playbackEnd)
        return lowerBound...playbackEnd
    }

    private var maximumWindowSeconds: Double {
        plotPanes
            .map(\.viewConfig.windowSeconds)
            .max()
            ?? viewConfig.windowSeconds
    }

    private static func clampedDisplayWindowSeconds(_ seconds: Double) -> Double {
        PlotWindowDuration.clamped(seconds)
    }

    private static func loadDefaultWindowSeconds() -> Double {
        guard let number = UserDefaults.standard.object(forKey: ViewPreferenceKeys.defaultWindowSeconds) as? NSNumber else {
            return PlotWindowDuration.defaultSeconds
        }
        return clampedDisplayWindowSeconds(number.doubleValue)
    }

    func copyCurrentViewDataToClipboard(paneID: Int) {
        let requestId = UUID().uuidString
        runtime?.copyViewData(
            requestId: requestId,
            paneID: paneID,
            viewportEnd: plotFrames.viewportEnd(forPaneID: paneID)
        )
    }

    func exportLog(sourceURL: URL, destinationURL: URL, format: ExportFormat) {
        startIfNeeded()
        let requestId = UUID().uuidString
        statusState = "exporting"
        status = "Exporting \(sourceURL.lastPathComponent) as \(format.title)"
        runtime?.exportLog(
            requestId: requestId,
            sourcePath: sourceURL.path,
            outputPath: destinationURL.path,
            format: format
        )
    }

    @discardableResult
    func addRememberedDeviceURL(_ rawURL: String) -> AvailableDevice? {
        guard let url = Self.cleanedDeviceURL(rawURL) else { return nil }
        let urls = [url] + rememberedDeviceURLs.filter { $0 != url }
        setRememberedDeviceURLs(urls)
        return Self.rememberedDevice(for: url)
    }

    func updateRememberedDeviceURL(_ currentURL: String, to rawURL: String) {
        var urls = rememberedDeviceURLs
        guard let index = urls.firstIndex(of: currentURL) else { return }

        if let newURL = Self.cleanedDeviceURL(rawURL) {
            urls[index] = newURL
        } else {
            urls.remove(at: index)
        }
        setRememberedDeviceURLs(urls)
    }

    func removeRememberedDeviceURL(_ url: String) {
        setRememberedDeviceURLs(rememberedDeviceURLs.filter { $0 != url })
    }

    @discardableResult
    func callRpc(_ rpc: RpcInfo, argumentText: String? = nil, optimisticallyUpdate: Bool = true) -> String {
        let requestId = UUID().uuidString
        let argument = argumentText.flatMap { rpcArgument(for: rpc, text: $0) }
        if argument != nil {
            writeRPCIDByRequestID[requestId] = rpc.id
            latestWriteRequestIDByRPCID[rpc.id] = requestId
        }
        if optimisticallyUpdate,
           argument != nil,
           let argumentText {
            previewRpcValue(rpc, argumentText: argumentText)
        }
        runtime?.callRpc(
            requestId: requestId,
            route: rpc.route,
            name: rpc.name,
            argument: argument
        )
        return requestId
    }

    private func scheduleRPCReadbackAfterWrite(rpcID: String) {
        guard !isInspectionMode,
              let rpc = rpc(id: rpcID),
              rpc.readable,
              rpc.hasMetadata,
              !rpc.isActionRPC else {
            return
        }

        pendingRPCReadbackWorkItems[rpcID]?.cancel()

        let generation = nextRPCReadbackGeneration
        nextRPCReadbackGeneration &+= 1
        pendingRPCReadbackGenerations[rpcID] = generation

        let now = Date()
        let earliestReadback = (lastRPCReadbackAtByRPCID[rpcID] ?? Date.distantPast)
            .addingTimeInterval(Self.rpcReadbackInterval)
        let delay = max(0, earliestReadback.timeIntervalSince(now))

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.performScheduledRPCReadback(rpcID: rpcID, generation: generation)
            }
        }
        pendingRPCReadbackWorkItems[rpcID] = workItem

        if delay <= 0 {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func performScheduledRPCReadback(rpcID: String, generation: UInt64) {
        guard pendingRPCReadbackGenerations[rpcID] == generation else { return }
        pendingRPCReadbackWorkItems[rpcID] = nil
        pendingRPCReadbackGenerations[rpcID] = nil

        guard !isInspectionMode,
              let rpc = rpc(id: rpcID),
              rpc.readable,
              rpc.hasMetadata,
              !rpc.isActionRPC else {
            return
        }

        lastRPCReadbackAtByRPCID[rpcID] = Date()
        callRpc(rpc)
    }

    private func clearRPCReadbackState() {
        for workItem in pendingRPCReadbackWorkItems.values {
            workItem.cancel()
        }
        pendingRPCReadbackWorkItems.removeAll()
        pendingRPCReadbackGenerations.removeAll()
        lastRPCReadbackAtByRPCID.removeAll()
    }

    func previewRpcValue(_ rpc: RpcInfo, argumentText: String) {
        guard let value = rpcValue(for: rpc, text: argumentText) else { return }
        enqueueRPCPreviewValue(route: rpc.route, name: rpc.name, value: value)
    }

    private func enqueueRPCPreviewValue(route: String, name: String, value: JSONValue) {
        pendingRPCPreviewValues[Self.rpcID(route: route, name: name)] = RPCValueUpdate(
            route: route,
            name: name,
            value: value
        )

        guard !isRPCPreviewFlushScheduled else { return }
        isRPCPreviewFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingRPCPreviewValues()
        }
    }

    private func flushPendingRPCPreviewValues() {
        isRPCPreviewFlushScheduled = false
        let updates = Array(pendingRPCPreviewValues.values)
        pendingRPCPreviewValues.removeAll()
        applyRPCValues(updates)
    }

    func rpc(id: String) -> RpcInfo? {
        devices
            .flatMap(\.rpcs)
            .first { $0.id == id }
    }

    func rpc(route: String, name: String) -> RpcInfo? {
        devices
            .first { $0.route == route }?
            .rpcs
            .first { $0.name == name }
    }

    func rpcValueRevision(id: String) -> UInt64 {
        rpcValueRevisions[id] ?? 0
    }

    func rpcReplyRevision(id: String) -> UInt64 {
        rpcReplyRevisions[id] ?? 0
    }

    func reloadAllRPCs() {
        rpcCacheNeedsReload = false
        loadReadableRPCs()
    }

    func trimLogMessages(limit: Int) {
        let limit = LogMessageScrollback.clamped(limit)
        guard logMessages.count > limit else { return }
        logMessages.removeFirst(logMessages.count - limit)
    }

    func clearConnectionProgress() {
        guard !connectionProgress.canCancel else { return }
        connectionRPCReadbackRequestIDs.removeAll()
        connectionProgress = ConnectionProgress()
    }

    func clearLogMessages() {
        logMessages.removeAll()
    }

    private func updateConnectionProgress(_ update: (inout ConnectionProgress) -> Void) {
        guard connectionProgress.isVisible else { return }
        var progress = connectionProgress
        update(&progress)
        progress.updatedAt = Date()
        connectionProgress = progress
    }

    private func markConnectionFailed(_ message: String) {
        updateConnectionProgress { progress in
            progress.phase = .failed
            progress.message = message
        }
        connectionRPCReadbackRequestIDs.removeAll()
    }

    private func updateConnectionStatus(_ event: StatusEvent) {
        updateConnectionProgress { progress in
            progress.message = event.message
            switch event.state {
            case "connecting":
                progress.phase = .connecting
            case "connected":
                progress.phase = .connected
                progress.didEstablishLink = true
            case "discovering":
                progress.phase = .discovering
                progress.didEstablishLink = true
            case "metadata":
                progress.phase = .metadata
                progress.didEstablishLink = true
            case "streaming":
                progress.phase = .streaming
                progress.didEstablishLink = true
            case "disconnected":
                if progress.canCancel {
                    progress.phase = .cancelled
                }
            default:
                break
            }
        }
    }

    private func markConnectionMetadataLoaded(_ nextDevices: [DeviceInfo]) {
        let streams = nextDevices.flatMap(\.streams)
        let streamColumnCount = streams.reduce(0) { $0 + $1.columns.count }
        let rpcs = nextDevices.flatMap(\.rpcs)
        let readableRPCCount = rpcs.filter { $0.readable && $0.hasMetadata && !$0.isCaptureRPC && !$0.isActionRPC }.count

        updateConnectionProgress { progress in
            progress.phase = .metadata
            progress.didEstablishLink = true
            progress.didLoadMetadata = true
            progress.deviceCount = nextDevices.count
            progress.streamCount = streams.count
            progress.streamColumnCount = streamColumnCount
            progress.rpcCount = rpcs.count
            progress.readableRPCCount = readableRPCCount
            progress.message = "Loaded \(nextDevices.count) device(s), \(streams.count) stream(s), \(rpcs.count) setting(s)"
        }
    }

    private func markConnectionStreamValues(count: Int) {
        guard count > 0, connectionProgress.isVisible else { return }
        guard !connectionProgress.didReceiveStreamValues || !connectionProgress.isReadyToDismiss else { return }
        updateConnectionProgress { progress in
            progress.didReceiveStreamValues = true
            progress.streamValueCount += count
        }
    }

    private func markConnectionRPCReply(ok: Bool) {
        updateConnectionProgress { progress in
            progress.didReceiveRPCReply = true
            progress.rpcReplyCount += 1
            if !ok {
                progress.rpcFailureCount += 1
            }
        }
    }

    private func resetPlotPanes() {
        plotPanes = [PlotPaneSelection(id: 0, viewConfig: viewConfig, columns: [])]
        nextPlotPaneID = 1
        activeColumns.removeAll()
    }

    private func removeAllPlotPanes() {
        guard !plotPanes.isEmpty || !activeColumns.isEmpty else { return }
        plotPanes.removeAll()
        activeColumns.removeAll()
        clearPlotOutput()
        sendPlotPanes()
    }

    private var hasStreamMetadata: Bool {
        devices.contains { !$0.streams.isEmpty }
    }

    private func updateRuntimePlotPanes() {
        enforcePlotLineLimit()
        let nextActiveColumns = Set(plotPanes.flatMap(\.columns))
        activeColumns = nextActiveColumns
        sendPlotPanes()
    }

    private func normalizedPlotKeys(_ keys: [ColumnKey]) -> [ColumnKey] {
        Array(Set(keys))
            .sorted()
            .prefix(Self.maxPlotLineCount)
            .map { $0 }
    }

    private func limitedColumnSet(from keys: [ColumnKey]) -> Set<ColumnKey> {
        Set(normalizedPlotKeys(keys))
    }

    private func columnsByAdding(_ keys: [ColumnKey], to existing: Set<ColumnKey>) -> Set<ColumnKey> {
        var result = limitedColumnSet(from: Array(existing))
        guard result.count < Self.maxPlotLineCount else {
            return result
        }

        for key in Array(Set(keys)).sorted() where result.count < Self.maxPlotLineCount {
            result.insert(key)
        }
        return result
    }

    private func enforcePlotLineLimit() {
        for index in plotPanes.indices {
            let limitedColumns = limitedColumnSet(from: Array(plotPanes[index].columns))
            if plotPanes[index].columns != limitedColumns {
                plotPanes[index].columns = limitedColumns
            }
        }
    }

    private func sendPlotPanes() {
        runtime?.setPlotPanes(plotPanes)
    }

    private func updateAllPaneViewConfigs(_ update: (inout ViewConfig) -> Void) {
        guard !plotPanes.isEmpty else {
            sendPlotPanes()
            return
        }

        for index in plotPanes.indices {
            update(&plotPanes[index].viewConfig)
        }
        updateRuntimePlotPanes()
    }

    private func clearPlotOutput() {
        plotFrames.clear()
        pendingPlotSnapshots.removeAll()
    }

    func handleRustEvent(kind: UInt32, data: Data) {
        switch kind {
        case 0:
            handleLine(data)
        case 1:
            handleBinaryPlotFrame(data)
        case 2:
            handleTypedEvent(data)
        default:
            appendError("Unknown Rust event kind \(kind)")
        }
    }

    private func handleBinaryPlotFrame(_ data: Data) {
        let profileStart = BridgeEventProfiler.start()
        do {
            let event = try decodeBinaryPlotFrame(data)
            BridgeEventProfiler.record(
                "plot.receive",
                start: profileStart,
                bytes: data.count,
                seriesCount: event.series.count,
                pointCount: event.pointCount,
                viewportEnd: event.viewportEnd
            )
            handlePlotPayload(
                paneID: event.paneID,
                mode: event.mode,
                viewportEnd: event.viewportEnd,
                series: event.series
            )
        } catch {
            appendError("Failed to decode binary plot frame: \(error.localizedDescription)")
        }
    }

    private func handleTypedEvent(_ data: Data) {
        do {
            var reader = RuntimeEventReader(data: data)
            guard let code = TypedRuntimeEventCode(rawValue: try reader.readUInt16()) else {
                appendError("Unknown typed Rust event")
                return
            }
            if code == .deviceList {
                logDeviceDiscovery("typed deviceList event decoding bytes=\(data.count)")
            }

            switch code {
            case .status:
                let event = StatusEvent(state: try reader.readString(), message: try reader.readString())
                handleStatusEvent(event)
            case .error:
                let event = ErrorEvent(message: try reader.readString())
                handleErrorEvent(event)
            case .debug:
                let event = DebugEvent(message: try reader.readString())
                TwinleafConsole.debug("[Twinleaf] rust debug: \(event.message)")
            case .deviceList:
                handleDeviceList(try reader.readAvailableDevices())
            case .metadata:
                handleMetadataDevices(try reader.readDevices())
            case .playback:
                handlePlaybackEvent(PlaybackEvent(
                    start: try reader.readDouble(),
                    end: try reader.readDouble(),
                    position: try reader.readDouble(),
                    recordingStart: try reader.readOptionalDouble(),
                    timeReferenceStart: try reader.readOptionalDouble()
                ))
            case .logProgress:
                handleLogProgressEvent(LogProgressEvent(
                    packets: try reader.readUInt64(),
                    bytes: try reader.readUInt64(),
                    fileBytes: try reader.readOptionalUInt64(),
                    startSeconds: try reader.readOptionalDouble(),
                    elapsedSeconds: try reader.readOptionalDouble(),
                    timeReferenceStart: try reader.readOptionalDouble(),
                    serializeErrors: try reader.readOptionalUInt64()
                ))
            case .streamValues:
                let profileStart = BridgeEventProfiler.start()
                let event = StreamValuesEvent(values: try reader.readStreamValues())
                BridgeEventProfiler.record(
                    "streamValues.receive",
                    start: profileStart,
                    bytes: data.count,
                    seriesCount: 0,
                    pointCount: event.values.count,
                    viewportEnd: nil
                )
                handleStreamValuesEvent(event)
            case .viewData:
                handleViewDataEvent(ViewDataEvent(
                    requestId: try reader.readString(),
                    ok: try reader.readBool(),
                    text: try reader.readOptionalString(),
                    rows: try reader.readOptionalInt(),
                    error: try reader.readOptionalString()
                ))
            case .exportResult:
                handleExportResult(ExportResultEvent(
                    requestId: try reader.readString(),
                    ok: try reader.readBool(),
                    outputPath: try reader.readOptionalString(),
                    format: try reader.readOptionalString().flatMap(ExportFormat.init(rawValue:)),
                    rows: try reader.readOptionalInt(),
                    bytes: try reader.readOptionalUInt64(),
                    error: try reader.readOptionalString()
                ))
            case .logMessage:
                handleLogMessageEvent(TioLogMessageEvent(
                    route: try reader.readString(),
                    timestampSeconds: try reader.readDouble(),
                    message: try reader.readString()
                ))
            case .rpcResult:
                handleRpcResult(RpcResultEvent(
                    requestId: try reader.readString(),
                    ok: try reader.readBool(),
                    route: try reader.readOptionalString(),
                    name: try reader.readOptionalString(),
                    value: try reader.readOptionalJSONValue(),
                    error: try reader.readOptionalString()
                ))
            case .rpcInvalidated:
                handleRpcInvalidated(RpcInvalidatedEvent(
                    route: try reader.readString(),
                    name: try reader.readOptionalString(),
                    rpcId: try reader.readOptionalUInt16()
                ))
            case .deviceEvent:
                handleDeviceEvent(DeviceEventEvent(
                    route: try reader.readString(),
                    event: try reader.readString()
                ))
            case .activeColumns:
                activeColumns = Set(try reader.readColumnKeys())
            case .proxyEvent:
                _ = try reader.readString()
            }
            try reader.finish()
        } catch {
            appendError("Failed to decode typed Rust event: \(error.localizedDescription)")
        }
    }

    private func handleLine(_ data: Data) {
        do {
            let kind = try decoder.decode(EventKind.self, from: data)
            switch kind.type {
            case "deviceList":
                handleDeviceList(try decoder.decode(DeviceListEvent.self, from: data).devices)
            case "metadata":
                handleMetadataDevices(try decoder.decode(MetadataEvent.self, from: data).devices)
            case "playback":
                handlePlaybackEvent(try decoder.decode(PlaybackEvent.self, from: data))
            case "logProgress":
                handleLogProgressEvent(try decoder.decode(LogProgressEvent.self, from: data))
            case "streamValues":
                let profileStart = BridgeEventProfiler.start()
                let event = try decoder.decode(StreamValuesEvent.self, from: data)
                BridgeEventProfiler.record(
                    "streamValues.receive",
                    start: profileStart,
                    bytes: data.count,
                    seriesCount: 0,
                    pointCount: event.values.count,
                    viewportEnd: nil
                )
                handleStreamValuesEvent(event)
            case "viewData":
                handleViewDataEvent(try decoder.decode(ViewDataEvent.self, from: data))
            case "exportResult":
                handleExportResult(try decoder.decode(ExportResultEvent.self, from: data))
            case "status":
                let event = try decoder.decode(StatusEvent.self, from: data)
                handleStatusEvent(event)
            case "error":
                let event = try decoder.decode(ErrorEvent.self, from: data)
                handleErrorEvent(event)
            case "debug":
                let event = try decoder.decode(DebugEvent.self, from: data)
                TwinleafConsole.debug("[Twinleaf] rust debug: \(event.message)")
            case "logMessage":
                handleLogMessageEvent(try decoder.decode(TioLogMessageEvent.self, from: data))
            case "rpcResult":
                handleRpcResult(try decoder.decode(RpcResultEvent.self, from: data))
            case "rpcInvalidated":
                handleRpcInvalidated(try decoder.decode(RpcInvalidatedEvent.self, from: data))
            case "deviceEvent":
                handleDeviceEvent(try decoder.decode(DeviceEventEvent.self, from: data))
            case "upgradeStatus":
                let event = try decoder.decode(UpgradeStatusEvent.self, from: data)
                availableUpgrades = event.available
            case "upgradeProgress":
                handleUpgradeProgressEvent(try decoder.decode(FirmwareUpgradeProgress.self, from: data))
            case "health":
                streamHealth = try decoder.decode(StreamHealthEvent.self, from: data).streams
            default:
                break
            }
        } catch {
            let text = String(data: data, encoding: .utf8) ?? "<binary>"
            appendError("Failed to decode Rust event: \(error.localizedDescription): \(text)")
        }
    }

    private func handleMetadataDevices(_ nextDevices: [DeviceInfo]) {
        clearStreamDisplayValues()
        devices = nextDevices
        rpcCacheNeedsReload = false
        markConnectionMetadataLoaded(nextDevices)
        logStreamMetadataGaps()
        if hasStreamMetadata {
            enableDefaultStreamSelection()
        } else {
            removeAllPlotPanes()
        }
        loadReadableRPCs()
    }

    private func handleDeviceList(_ devices: [AvailableDevice]) {
        #if os(iOS)
        // The Rust side seeds `tcp://localhost` as a convenience for desktop
        // users running `tio-proxy`. On iOS there's no local proxy to reach,
        // so filter it out of the picker.
        discoveredDevices = devices.filter { $0.url != "tcp://localhost" }
        #else
        discoveredDevices = devices
        #endif
        let serialDevices = devices.filter { $0.url.hasPrefix("serial://") }
        let attachedSensors = devices
            .flatMap(\.routes)
            .filter { !$0.isRoot }
            .count
        let attachedSummary = attachedSensors > 0
            ? ", \(attachedSensors) attached sensor\(attachedSensors == 1 ? "" : "s")"
            : ""
        deviceDiscoverySummary = "\(devices.count) device\(devices.count == 1 ? "" : "s"), \(serialDevices.count) serial\(attachedSummary)"
        let rawDevices = devices
            .map {
                let routes = $0.routes
                    .map { "\($0.route)=\($0.name ?? "")" }
                    .joined(separator: ",")
                return "\($0.kind)|\($0.label)|\($0.url)|\($0.detail)|\(routes)"
            }
            .joined(separator: " ; ")
        logDeviceDiscovery("deviceList decoded summary=\(deviceDiscoverySummary) raw=[\(rawDevices)]")
        refreshAvailableDevices()

        if shouldRetryAllSerialAfterStrictDiscovery && serialDevices.isEmpty {
            shouldRetryAllSerialAfterStrictDiscovery = false
            logDeviceDiscovery("strict serial discovery found no serial ports; retrying with includeAll=true")
            runtime?.listDevices(includeAll: true)
        } else {
            shouldRetryAllSerialAfterStrictDiscovery = false
        }
    }

    private func handleStatusEvent(_ event: StatusEvent) {
        TwinleafConsole.debug("[Twinleaf] rust status: \(event.state): \(event.message)")
        statusState = event.state
        status = event.message
        updateConnectionStatus(event)
        if event.state == "inspection" || event.state == "loading" {
            isInspectionMode = true
            isPlotPaused = true
        }
        if event.state == "logging" {
            markLogActivity(force: true)
        }
    }

    private func handleErrorEvent(_ event: ErrorEvent) {
        TwinleafConsole.error("[Twinleaf] rust error: \(event.message)")
        markConnectionFailed(event.message)
        appendError(event.message)
        status = event.message
        statusState = "error"
    }

    private func appendError(_ message: String) {
        errors.append(message)
    }

    private func handleLogMessageEvent(_ event: TioLogMessageEvent) {
        appendLogMessage(route: event.route, timestampSeconds: event.timestampSeconds, message: event.message)
    }

    private func appendLogMessage(route: String, timestampSeconds: Double, message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !trimmed.isEmpty else { return }
        logMessages.append(LogMessage(
            route: route,
            timestampSeconds: timestampSeconds,
            message: trimmed
        ))
        trimLogMessages(limit: Self.preferredLogMessageLimit())
    }

    private static func preferredLogMessageLimit() -> Int {
        let value = UserDefaults.standard.object(forKey: ViewPreferenceKeys.logMessageLineLimit) as? Int
            ?? LogMessageScrollback.defaultLineLimit
        return LogMessageScrollback.clamped(value)
    }

    private func handlePlotPayload(
        paneID: Int,
        mode: PlotMode,
        viewportEnd: Double?,
        series: [PlotSeries]
    ) {
        if !isInspectionMode {
            markLogActivity()
            updateLivePlotStartIfNeeded(mode: mode, viewportEnd: viewportEnd, series: series)
        }

        let snapshot = PlotSnapshot(
            paneID: paneID,
            mode: mode,
            viewportEnd: viewportEnd,
            series: series
        )

        if isInspectionMode {
            applyPlotSnapshot(snapshot)
            pendingPlotSnapshots[paneID] = nil
            return
        }

        if isPlotPaused {
            pendingPlotSnapshots[paneID] = snapshot
        } else {
            applyPlotSnapshot(snapshot)
        }
    }

    private func handlePlaybackEvent(_ event: PlaybackEvent) {
        isInspectionMode = true
        isPlotPaused = true
        playbackStart = event.start
        playbackEnd = event.end
        playbackPosition = event.position
        plotFrames.setViewportEnd(event.position)
        logStartSeconds = event.recordingStart ?? (event.start.isFinite ? event.start : nil)
        logTimeReferenceStartSeconds = sanitizedTimeReference(event.timeReferenceStart)
        if let start = logStartSeconds, event.end.isFinite {
            logElapsedSeconds = max(0, event.end - start)
        }
    }

    private func handleLogProgressEvent(_ event: LogProgressEvent) {
        logBytes = event.fileBytes ?? event.bytes
        logStartSeconds = event.startSeconds
        logElapsedSeconds = event.elapsedSeconds
        logTimeReferenceStartSeconds = sanitizedTimeReference(event.timeReferenceStart)
        logPackets = event.packets
        logSerializeErrors = event.serializeErrors ?? 0
        markLogActivity(force: true)
    }

    private func handleStreamValuesEvent(_ event: StreamValuesEvent) {
        let profileStart = BridgeEventProfiler.start()
        let now = Date()
        markConnectionStreamValues(count: event.values.count)

        for item in event.values {
            updateSmoothedStreamDisplayValue(item.value, for: item.key, at: now)
        }

        let appliedValues = publishStreamDisplayValuesIfNeeded(at: now)

        BridgeEventProfiler.record(
            "streamValues.apply",
            start: profileStart,
            bytes: nil,
            seriesCount: 0,
            pointCount: appliedValues,
            viewportEnd: nil
        )
    }

    private func updateSmoothedStreamDisplayValue(_ rawValue: Double, for key: ColumnKey, at now: Date) {
        guard var state = streamDisplayValues[key] else {
            streamDisplayValues[key] = StreamDisplayValue(value: rawValue, updatedAt: now)
            return
        }

        let elapsed = max(0, now.timeIntervalSince(state.updatedAt))
        state.updatedAt = now

        guard elapsed > 0,
              rawValue.isFinite,
              state.value.isFinite else {
            state.value = rawValue
            streamDisplayValues[key] = state
            return
        }

        let alpha = 1 - exp(-elapsed / Self.streamDisplayEMATimeConstant)
        state.value += alpha * (rawValue - state.value)
        streamDisplayValues[key] = state
    }

    private func publishStreamDisplayValuesIfNeeded(at now: Date, force: Bool = false) -> Int {
        guard !streamDisplayValues.isEmpty else { return 0 }

        let elapsed = now.timeIntervalSince(lastStreamDisplayPublishAt)
        if !force, elapsed < Self.streamDisplayUpdateInterval {
            scheduleStreamDisplayFlush(after: Self.streamDisplayUpdateInterval - elapsed)
            return 0
        }

        return flushStreamDisplayValues(at: now)
    }

    private func scheduleStreamDisplayFlush(after delay: TimeInterval) {
        guard pendingStreamDisplayFlush == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingStreamDisplayValues()
        }
        pendingStreamDisplayFlush = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: workItem)
    }

    private func flushPendingStreamDisplayValues() {
        pendingStreamDisplayFlush = nil
        _ = publishStreamDisplayValuesIfNeeded(at: Date(), force: true)
    }

    @discardableResult
    private func flushStreamDisplayValues(at now: Date) -> Int {
        pendingStreamDisplayFlush?.cancel()
        pendingStreamDisplayFlush = nil

        var nextDevices = devices
        var appliedValues = 0
        for (key, state) in streamDisplayValues {
            if updateColumnDisplayValue(state.value, for: key, in: &nextDevices) {
                appliedValues += 1
            }
        }

        if appliedValues > 0 {
            devices = nextDevices
        }
        lastStreamDisplayPublishAt = now
        return appliedValues
    }

    private func clearStreamDisplayValues() {
        pendingStreamDisplayFlush?.cancel()
        pendingStreamDisplayFlush = nil
        streamDisplayValues.removeAll()
        lastStreamDisplayPublishAt = Date.distantPast
    }

    private func handleViewDataEvent(_ event: ViewDataEvent) {
        guard event.ok, let text = event.text else {
            let message = event.error ?? "Failed to copy view data"
            appendError(message)
            status = message
            statusState = "error"
            return
        }

        copyTextToClipboard(text)
        status = "Copied \(event.rows ?? 0) data row(s) to clipboard"
        statusState = isInspectionMode ? "inspection" : "streaming"
    }

    private func copyTextToClipboard(_ text: String) {
#if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#elseif os(iOS)
        UIPasteboard.general.string = text
#endif
    }

    private func handleExportResult(_ event: ExportResultEvent) {
        if event.ok {
            let filename = event.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "export"
            let rowText = event.rows.map { "\($0) row(s)" } ?? "data"
            status = "Exported \(rowText) to \(filename)"
            statusState = isInspectionMode ? "inspection" : "streaming"
            return
        }

        let message = event.error ?? "Export failed"
        TwinleafConsole.error("[Twinleaf] rust export error: \(message)")
        appendError(message)
        status = message
        statusState = "error"
    }

    private func setRememberedDeviceURLs(_ urls: [String]) {
        rememberedDeviceURLs = Self.normalizedRememberedDeviceURLs(urls)
        UserDefaults.standard.set(rememberedDeviceURLs, forKey: Self.rememberedURLsDefaultsKey)
        refreshAvailableDevices()
    }

    private func refreshAvailableDevices() {
        var seenURLs = Set<String>()
        var devices: [AvailableDevice] = []

        for url in rememberedDeviceURLs where seenURLs.insert(url).inserted {
            devices.append(Self.rememberedDevice(for: url))
        }

        for device in discoveredDevices where seenURLs.insert(device.url).inserted {
            devices.append(device)
        }

        #if os(iOS)
        for device in mdnsDevices where seenURLs.insert(device.url).inserted {
            devices.append(device)
        }
        #endif

        availableDevices = devices
        let rendered = devices.map { "\($0.kind)|\($0.url)" }.joined(separator: " ; ")
        logDeviceDiscovery("availableDevices refreshed count=\(devices.count) rendered=[\(rendered)]")
    }

    private func applyPlotSnapshot(_ snapshot: PlotSnapshot) {
        let profileStart = BridgeEventProfiler.start()
        plotFrames.apply(
            paneID: snapshot.paneID,
            mode: snapshot.mode,
            viewportEnd: snapshot.viewportEnd,
            series: snapshot.series,
            revision: nextPlotRevision
        )
        nextPlotRevision &+= 1
        BridgeEventProfiler.record(
            "plot.apply",
            start: profileStart,
            bytes: nil,
            seriesCount: snapshot.series.count,
            pointCount: snapshot.pointCount,
            viewportEnd: snapshot.viewportEnd
        )
    }

    private func decodeBinaryPlotFrame(_ data: Data) throws -> BinaryPlotEvent {
        try data.withUnsafeBytes { rawBuffer in
            var reader = BinaryPlotReader(rawBuffer)
            let modeCode = try reader.readUInt8()
            let mode: PlotMode
            switch modeCode {
            case 0:
                mode = .timeseries
            case 1:
                mode = .fft
            default:
                throw BinaryPlotDecodeError.invalidMode(modeCode)
            }

            let flags = try reader.readUInt8()
            let frameVersion = try reader.readUInt16()
            let paneID: Int
            let seriesCount: UInt32
            if frameVersion >= 2 {
                paneID = Int(try reader.readUInt32())
                seriesCount = try reader.readUInt32()
            } else {
                paneID = 0
                seriesCount = try reader.readUInt32()
            }
            let viewportValue = try reader.readDouble()
            let viewportEnd = (flags & 0x01) == 0 ? nil : viewportValue

            var series: [PlotSeries] = []
            series.reserveCapacity(Int(seriesCount))

            for _ in 0..<seriesCount {
                let routeLength = Int(try reader.readUInt16())
                let route = try reader.readString(byteCount: routeLength)
                let streamId = try reader.readUInt8()
                let columnIndex = Int(try reader.readUInt32())
                let sampleRate = try reader.readDouble()
                let seriesFlags = frameVersion >= 3 ? try reader.readUInt8() : 0
                let pointCount = Int(try reader.readUInt32())
                let key = ColumnKey(
                    route: route,
                    streamId: streamId,
                    columnIndex: columnIndex
                )
                let metadata = plotMetadata(for: key)
                var points: [PlotPoint] = []
                points.reserveCapacity(pointCount)
                for _ in 0..<pointCount {
                    points.append(PlotPoint(
                        x: try reader.readDouble(),
                        y: try reader.readDouble()
                    ))
                }
                series.append(PlotSeries(
                    key: key,
                    label: metadata.label,
                    units: metadata.units,
                    sampleRate: sampleRate,
                    points: points,
                    isOutsideTimeWindow: (seriesFlags & 0x01) != 0
                ))
            }

            try reader.finish()
            return BinaryPlotEvent(paneID: paneID, mode: mode, viewportEnd: viewportEnd, series: series)
        }
    }

    private func plotMetadata(for key: ColumnKey) -> (label: String, units: String) {
        guard let resolved = resolveColumnIndex(for: key, in: devices) else {
            return (
                "\(key.route) stream \(key.streamId) column \(key.columnIndex)",
                ""
            )
        }

        let device = devices[resolved.device]
        let stream = device.streams[resolved.stream]
        let column = stream.columns[resolved.column]
        var label = "\(device.meta.name) \(stream.name).\(column.name)"

        // With several routes in the session (multiple sensors or a hub),
        // identical device types produce identical labels; prefix the route
        // and serial so legend entries stay distinguishable.
        if Set(devices.map(\.route)).count > 1 {
            let serial = device.meta.serialNumber
            let prefix = serial.isEmpty ? device.route : "\(device.route) \(serial)"
            label = "\(prefix) · \(label)"
        }

        return (label, column.units)
    }

    private func updateColumnDisplayValue(
        _ value: Double,
        for key: ColumnKey,
        in targetDevices: inout [DeviceInfo]
    ) -> Bool {
        guard let resolved = resolveColumnIndex(for: key, in: targetDevices) else {
            return false
        }

        if targetDevices[resolved.device].streams[resolved.stream].columns[resolved.column].displayValue == value {
            return false
        }

        targetDevices[resolved.device].streams[resolved.stream].columns[resolved.column].displayValue = value
        return true
    }

    private func resolveColumnIndex(
        for key: ColumnKey,
        in targetDevices: [DeviceInfo]
    ) -> (device: Int, stream: Int, column: Int)? {
        if let exact = findColumnIndex(for: key, in: targetDevices) {
            return exact
        }

        var uniqueMatch: (device: Int, stream: Int, column: Int)?
        for deviceIndex in targetDevices.indices {
            for streamIndex in targetDevices[deviceIndex].streams.indices
            where targetDevices[deviceIndex].streams[streamIndex].streamId == key.streamId {
                for columnIndex in targetDevices[deviceIndex].streams[streamIndex].columns.indices
                where targetDevices[deviceIndex].streams[streamIndex].columns[columnIndex].key.columnIndex == key.columnIndex {
                    guard uniqueMatch == nil else { return nil }
                    uniqueMatch = (deviceIndex, streamIndex, columnIndex)
                }
            }
        }
        return uniqueMatch
    }

    private func findColumnIndex(
        for key: ColumnKey,
        in targetDevices: [DeviceInfo]
    ) -> (device: Int, stream: Int, column: Int)? {
        guard let deviceIndex = targetDevices.firstIndex(where: { $0.route == key.route }),
              let streamIndex = targetDevices[deviceIndex].streams.firstIndex(where: { $0.streamId == key.streamId }),
              let columnIndex = targetDevices[deviceIndex].streams[streamIndex].columns.firstIndex(where: { $0.key == key }) else {
            return nil
        }
        return (deviceIndex, streamIndex, columnIndex)
    }

    private func markLogActivity(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastLogRevisionMark) >= 0.5 else { return }
        lastLogRevisionMark = now
        logRevision &+= 1
    }

    private func updateLogFileSize(at url: URL?) {
        guard let url else {
            logBytes = 0
            resetLogTiming()
            return
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber {
                logBytes = size.uint64Value
            }
        } catch {
            logBytes = 0
            resetLogTiming()
        }
    }

    private func resetLogTiming() {
        logStartSeconds = nil
        logElapsedSeconds = nil
        logTimeReferenceStartSeconds = nil
    }

    private func resetLivePlotTiming() {
        livePlotStartSeconds = nil
    }

    private func updateLivePlotStartIfNeeded(
        mode: PlotMode,
        viewportEnd: Double?,
        series: [PlotSeries]
    ) {
        guard livePlotStartSeconds == nil,
              mode == .timeseries else {
            return
        }

        let firstPointTime = series
            .lazy
            .flatMap(\.points)
            .map(\.x)
            .filter { $0.isFinite }
            .min()
        let fallbackTime = viewportEnd?.isFinite == true ? viewportEnd : nil
        guard let start = firstPointTime ?? fallbackTime else {
            return
        }
        livePlotStartSeconds = start
    }

    private func sanitizedTimeReference(_ seconds: Double?) -> Double? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private func enableDefaultStreamSelection() {
        guard activeColumns.isEmpty else { return }
        guard let firstPaneID = plotPanes.first?.id else { return }

        let defaults = devices
            .lazy
            .compactMap { device -> [ColumnKey]? in
                guard !self.shouldSuppressDefaultStreamSelection(for: device) else { return nil }
                // The first stream that actually carries data columns, in
                // stream-id order. (Previously hardcoded to stream id 1, which
                // skipped devices whose data stream is id 0, e.g. `vector`.)
                let columns = device.streams
                    .filter { !$0.columns.isEmpty }
                    .min { $0.streamId < $1.streamId }?
                    .columns
                    .map(\.key)
                return (columns?.isEmpty == false) ? columns : nil
            }
            .first ?? []

        guard !defaults.isEmpty else { return }
        setColumns(defaults, in: firstPaneID, enabled: true)
    }

    private func shouldSuppressDefaultStreamSelection(for device: DeviceInfo) -> Bool {
        guard Self.loadSuppressCommHubDefaultPlot() else { return false }
        return Self.isCommOrHubBoardName(device.meta.name) || Self.isCommOrHubBoardName(device.route)
    }

    private static func isCommOrHubBoardName(_ rawValue: String) -> Bool {
        let name = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return name.hasPrefix("comm") || name.hasPrefix("hub")
    }

    private static func loadSuppressCommHubDefaultPlot() -> Bool {
        UserDefaults.standard.object(forKey: ViewPreferenceKeys.suppressCommHubDefaultPlot) as? Bool ?? true
    }

    private static func loadShowAllSerialPorts() -> Bool {
        UserDefaults.standard.object(forKey: ViewPreferenceKeys.showAllSerialPorts) as? Bool ?? true
    }

    private func logStreamMetadataGaps() {
        let missingStreams = devices.flatMap { device in
            device.streams.compactMap { stream -> String? in
                guard stream.nColumns > 0, stream.columns.isEmpty else { return nil }
                let name = device.meta.name.isEmpty ? device.route : device.meta.name
                return "\(name) route=\(device.route) stream=\(stream.streamId) expectedColumns=\(stream.nColumns)"
            }
        }

        guard !missingStreams.isEmpty else { return }
        TwinleafConsole.debug(
            "[Twinleaf] stream metadata incomplete: \(missingStreams.joined(separator: "; "))"
        )
    }

    private func loadReadableRPCs() {
        guard !isInspectionMode else { return }
        // `isActionRPC` (writable unit-typed) is excluded: even when the device
        // reports such an RPC as readable, "reading" a unit RPC executes the
        // action — `dev.conf.save/load/reset` etc. would all fire on startup.
        let readableRPCs = devices
            .flatMap(\.rpcs)
            .filter { $0.readable && $0.hasMetadata && !$0.isCaptureRPC && !$0.isActionRPC }
        guard !readableRPCs.isEmpty else { return }

        TwinleafConsole.debug("[Twinleaf] loading \(readableRPCs.count) readable RPC value(s)")
        for rpc in readableRPCs {
            let requestID = callRpc(rpc)
            if connectionProgress.isVisible && connectionProgress.canCancel {
                connectionRPCReadbackRequestIDs.insert(requestID)
            }
        }
    }

    private func handleRpcResult(_ event: RpcResultEvent) {
        if connectionRPCReadbackRequestIDs.remove(event.requestId) != nil {
            markConnectionRPCReply(ok: event.ok)
        }

        let writeRPCID = writeRPCIDByRequestID.removeValue(forKey: event.requestId)

        guard event.ok else {
            if let writeRPCID,
               latestWriteRequestIDByRPCID[writeRPCID] == event.requestId {
                latestWriteRequestIDByRPCID[writeRPCID] = nil
                scheduleRPCReadbackAfterWrite(rpcID: writeRPCID)
            }
            if let route = event.route,
               let name = event.name {
                bumpRPCReplyRevision(for: Self.rpcID(route: route, name: name))
                appendError("\(route) \(name): \(event.error ?? "RPC failed")")
            } else {
                appendError(event.error ?? "RPC failed")
            }
            return
        }
        guard let route = event.route,
              let name = event.name else {
            if let writeRPCID,
               latestWriteRequestIDByRPCID[writeRPCID] == event.requestId {
                latestWriteRequestIDByRPCID[writeRPCID] = nil
                scheduleRPCReadbackAfterWrite(rpcID: writeRPCID)
            }
            return
        }

        let rpcID = Self.rpcID(route: route, name: name)
        let isWriteResult = writeRPCID == rpcID
        if let writeRPCID,
           !isWriteResult,
           latestWriteRequestIDByRPCID[writeRPCID] == event.requestId {
            latestWriteRequestIDByRPCID[writeRPCID] = nil
            scheduleRPCReadbackAfterWrite(rpcID: writeRPCID)
        }
        if isWriteResult {
            guard latestWriteRequestIDByRPCID[rpcID] == event.requestId else {
                return
            }
            latestWriteRequestIDByRPCID[rpcID] = nil
            scheduleRPCReadbackAfterWrite(rpcID: rpcID)
        }

        bumpRPCReplyRevision(for: rpcID)

        guard let value = event.value else { return }
        if isWriteResult,
           case .null = value {
            return
        }

        applyRPCValue(route: route, name: name, value: value)
    }

    private func handleRpcInvalidated(_: RpcInvalidatedEvent) {
        rpcCacheNeedsReload = true
    }

    private func handleUpgradeProgressEvent(_ progress: FirmwareUpgradeProgress) {
        upgradeProgress = progress
        switch progress.phase {
        case .complete:
            // Upgrade landed: the device reboots into the new firmware, so the
            // pending offer for this route is no longer valid.
            availableUpgrades.removeAll { $0.route == progress.route }
        case .error:
            if let message = progress.message {
                appendError("Firmware upgrade failed: \(message)")
            }
        default:
            break
        }
    }

    private func bumpRPCReplyRevision(for id: String) {
        rpcReplyRevisions[id] = (rpcReplyRevisions[id] ?? 0) &+ 1
        rpcReplyChangeToken &+= 1
    }

    private func bumpRPCValueRevisions(for ids: [String]) {
        for id in ids {
            rpcValueRevisions[id] = (rpcValueRevisions[id] ?? 0) &+ 1
        }
        rpcValueChangeToken &+= 1
    }

    private func applyRPCValue(route: String, name: String, value: JSONValue) {
        applyRPCValues([RPCValueUpdate(route: route, name: name, value: value)])
    }

    private func applyRPCValues(_ updates: [RPCValueUpdate]) {
        guard !updates.isEmpty else { return }
        var nextDevices = devices
        var updatedRPCIDs: Set<String> = []

        for update in updates {
            applyRPCValue(update, to: &nextDevices, updatedRPCIDs: &updatedRPCIDs)
        }

        guard !updatedRPCIDs.isEmpty else { return }
        devices = nextDevices
        bumpRPCValueRevisions(for: Array(updatedRPCIDs))
    }

    private func applyRPCValue(
        _ update: RPCValueUpdate,
        to nextDevices: inout [DeviceInfo],
        updatedRPCIDs: inout Set<String>
    ) {
        for deviceIndex in nextDevices.indices where nextDevices[deviceIndex].route == update.route {
            for rpcIndex in nextDevices[deviceIndex].rpcs.indices
            where nextDevices[deviceIndex].rpcs[rpcIndex].name == update.name {
                guard nextDevices[deviceIndex].rpcs[rpcIndex].value != update.value else {
                    continue
                }
                nextDevices[deviceIndex].rpcs[rpcIndex].value = update.value
                updatedRPCIDs.insert(nextDevices[deviceIndex].rpcs[rpcIndex].id)
            }
        }
    }

    private static func rpcID(route: String, name: String) -> String {
        "\(route)#\(name)"
    }

    private func handleDeviceEvent(_ event: DeviceEventEvent) {
        guard event.event.hasPrefix("RpcInvalidated(") else { return }
        handleRpcInvalidated(RpcInvalidatedEvent(
            route: event.route,
            name: Self.rpcInvalidatedName(from: event.event),
            rpcId: Self.rpcInvalidatedID(from: event.event)
        ))
    }

    private static func rpcInvalidatedName(from event: String) -> String? {
        let marker = "RpcInvalidated(Name(\""
        guard let start = event.range(of: marker)?.upperBound,
              let end = event[start...].range(of: "\"))")?.lowerBound else {
            return nil
        }
        return String(event[start..<end])
    }

    private static func rpcInvalidatedID(from event: String) -> UInt16? {
        let marker = "RpcInvalidated(Id("
        guard let start = event.range(of: marker)?.upperBound,
              let end = event[start...].range(of: "))")?.lowerBound else {
            return nil
        }
        return UInt16(event[start..<end])
    }

    private func rpcArgument(for rpc: RpcInfo, text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let base = rpc.argType.split(separator: "<").first.map(String.init) ?? rpc.argType
        switch base {
        case "unit", "":
            return nil
        case "bool":
            return Self.parseBoolArgument(trimmed)
        case "string":
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        case "f32", "f64":
            guard !trimmed.isEmpty else { return nil }
            return Double(trimmed)
        case "i8", "i16", "i32", "i64":
            guard !trimmed.isEmpty else { return nil }
            return Int64(trimmed)
        case "u8", "u16", "u32", "u64":
            guard !trimmed.isEmpty else { return nil }
            return UInt64(trimmed)
        default:
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        }
    }

    private static func parseBoolArgument(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "on", "1":
            true
        case "false", "no", "off", "0":
            false
        default:
            nil
        }
    }

    private func rpcValue(for rpc: RpcInfo, text: String) -> JSONValue? {
        guard let argument = rpcArgument(for: rpc, text: text) else { return nil }

        switch argument {
        case let value as String:
            return .string(value)
        case let value as Double:
            return .number(value)
        case let value as Int64:
            return .number(Double(value))
        case let value as UInt64:
            return .number(Double(value))
        default:
            return nil
        }
    }

    nonisolated static var packageRoot: URL {
        let source = URL(fileURLWithPath: #filePath)
        return source
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var workingDirectory: URL {
        let root = packageRoot
        if FileManager.default.fileExists(atPath: root.path) {
            return root
        }
        return Bundle.main.resourceURL ?? URL(fileURLWithPath: "/")
    }

    private static func loadRememberedDeviceURLs() -> [String] {
        normalizedRememberedDeviceURLs(
            UserDefaults.standard.stringArray(forKey: rememberedURLsDefaultsKey) ?? []
        )
    }

    private static func normalizedRememberedDeviceURLs(_ urls: [String]) -> [String] {
        var seenURLs = Set<String>()
        var normalized: [String] = []

        for rawURL in urls {
            guard let url = cleanedDeviceURL(rawURL), seenURLs.insert(url).inserted else {
                continue
            }
            normalized.append(url)
        }

        return normalized
    }

    private static func cleanedDeviceURL(_ rawURL: String) -> String? {
        // A remembered entry may hold several whitespace-separated URLs (a
        // multi-sensor mount); canonicalize to single-space separation.
        let url = rawURL
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return url.isEmpty ? nil : url
    }

    private static func rememberedDevice(for url: String) -> AvailableDevice {
        AvailableDevice(
            url: url,
            label: rememberedDeviceLabel(for: url),
            kind: "remembered",
            detail: rememberedDeviceDetail(for: url)
        )
    }

    private static func rememberedDeviceLabel(for url: String) -> String {
        guard let components = URLComponents(string: url) else {
            return "Saved Device"
        }

        if let host = components.host, !host.isEmpty {
            return host
        }
        if !components.path.isEmpty {
            return URL(fileURLWithPath: components.path).lastPathComponent
        }
        return "Saved Device"
    }

    private static func rememberedDeviceDetail(for url: String) -> String {
        guard let scheme = URLComponents(string: url)?.scheme, !scheme.isEmpty else {
            return "Remembered URL"
        }
        return "Remembered \(scheme.uppercased()) URL"
    }
}

private struct EventKind: Decodable {
    let type: String
}

private struct DeviceListEvent: Decodable {
    let devices: [AvailableDevice]
}

private struct MetadataEvent: Decodable {
    let devices: [DeviceInfo]
}

private struct BinaryPlotEvent {
    let paneID: Int
    let mode: PlotMode
    let viewportEnd: Double?
    let series: [PlotSeries]

    var pointCount: Int {
        series.reduce(0) { $0 + $1.points.count }
    }
}

private struct PlaybackEvent: Decodable {
    let start: Double
    let end: Double
    let position: Double
    let recordingStart: Double?
    let timeReferenceStart: Double?
}

private struct LogProgressEvent: Decodable {
    let packets: UInt64
    let bytes: UInt64
    let fileBytes: UInt64?
    let startSeconds: Double?
    let elapsedSeconds: Double?
    let timeReferenceStart: Double?
    let serializeErrors: UInt64?
}

private struct StreamValuesEvent: Decodable {
    let values: [StreamValueEvent]
}

private struct StreamValueEvent: Decodable {
    let key: ColumnKey
    let value: Double
}

private struct ViewDataEvent: Decodable {
    let requestId: String
    let ok: Bool
    let text: String?
    let rows: Int?
    let error: String?
}

private struct ExportResultEvent: Decodable {
    let requestId: String
    let ok: Bool
    let outputPath: String?
    let format: ExportFormat?
    let rows: Int?
    let bytes: UInt64?
    let error: String?
}

private struct PlotSnapshot {
    let paneID: Int
    let mode: PlotMode
    let viewportEnd: Double?
    let series: [PlotSeries]

    var pointCount: Int {
        series.reduce(0) { $0 + $1.points.count }
    }
}

private struct StatusEvent: Decodable {
    let state: String
    let message: String
}

private struct ErrorEvent: Decodable {
    let message: String
}

// MARK: - Health diagnostics models (module-internal: used by the UI layer)

/// Per-stream timing/rate diagnostics from the bridge's health monitor.
struct StreamHealthInfo: Decodable, Hashable, Identifiable {
    let route: String
    let streamId: Int
    let name: String
    let rateHz: Double?
    let ppm: Double?
    let driftSeconds: Double?
    let jitterMs: Double?
    let received: UInt64
    let dropped: UInt64
    let sessionId: UInt32?
    let stale: Bool

    var id: String { "\(route)#\(streamId)" }
}

private struct StreamHealthEvent: Decodable {
    let streams: [StreamHealthInfo]
}

// MARK: - Firmware upgrade models (module-internal: used by the UI layer)

/// A device with a newer published firmware available.
struct FirmwareUpgrade: Decodable, Hashable, Identifiable {
    let route: String
    let deviceName: String
    let currentVersion: String
    let newVersion: String
    let newHash: String
    let filename: String

    var id: String { route }
}

private struct UpgradeStatusEvent: Decodable {
    let available: [FirmwareUpgrade]
}

/// Phases of a firmware flash, mirroring the Rust `FlashEvent` progression.
enum FirmwareUpgradePhase: String, Decodable, Hashable {
    case starting
    case downloading
    case stopping
    case stopped
    case uploading
    case committing
    case finalizing
    case complete
    case error
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FirmwareUpgradePhase(rawValue: raw) ?? .unknown
    }

    var isTerminal: Bool { self == .complete || self == .error }
}

/// Live progress of an in-flight firmware flash. Decoded directly from the
/// `upgradeProgress` bridge event (extra keys like `type` are ignored).
struct FirmwareUpgradeProgress: Decodable, Hashable {
    let route: String
    let phase: FirmwareUpgradePhase
    var chunk: Int?
    var total: Int?
    var fraction: Double?
    var message: String?
    var newVersion: String?
    var filename: String?

    init(
        route: String,
        phase: FirmwareUpgradePhase,
        message: String?,
        fraction: Double?
    ) {
        self.route = route
        self.phase = phase
        self.message = message
        self.fraction = fraction
    }
}

private struct DebugEvent: Decodable {
    let message: String
}

private struct TioLogMessageEvent: Decodable {
    let route: String
    let timestampSeconds: Double
    let message: String
}

private struct DeviceEventEvent: Decodable {
    let route: String
    let event: String
}

private struct RpcResultEvent: Decodable {
    let requestId: String
    let ok: Bool
    let route: String?
    let name: String?
    let value: JSONValue?
    let error: String?
}

private struct RpcInvalidatedEvent: Decodable {
    let route: String
    let name: String?
    let rpcId: UInt16?
}

private enum TypedRuntimeEventCode: UInt16 {
    case status = 1
    case error = 2
    case debug = 3
    case deviceList = 4
    case metadata = 5
    case playback = 6
    case logProgress = 7
    case streamValues = 8
    case viewData = 9
    case exportResult = 10
    case logMessage = 11
    case rpcResult = 12
    case rpcInvalidated = 13
    case deviceEvent = 14
    case activeColumns = 15
    case proxyEvent = 16
}

private enum RuntimeEventDecodeError: LocalizedError {
    case truncated
    case invalidString
    case invalidJSONTag(UInt8)
    case trailingBytes(Int)

    var errorDescription: String? {
        switch self {
        case .truncated:
            "Unexpected end of typed Rust event"
        case .invalidString:
            "Invalid UTF-8 string in typed Rust event"
        case .invalidJSONTag(let tag):
            "Invalid typed JSON value tag \(tag)"
        case .trailingBytes(let count):
            "Typed Rust event has \(count) trailing byte(s)"
        }
    }
}

private struct RuntimeEventReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func readUInt8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    mutating func readUInt16() throws -> UInt16 {
        UInt16(try readLittleEndianInteger(byteCount: 2))
    }

    mutating func readUInt32() throws -> UInt32 {
        UInt32(try readLittleEndianInteger(byteCount: 4))
    }

    mutating func readUInt64() throws -> UInt64 {
        try readLittleEndianInteger(byteCount: 8)
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    mutating func readString() throws -> String {
        let byteCount = Int(clamping: try readUInt32())
        try require(byteCount)
        let start = offset
        offset += byteCount
        guard let value = String(bytes: bytes[start..<offset], encoding: .utf8) else {
            throw RuntimeEventDecodeError.invalidString
        }
        return value
    }

    mutating func readOptionalString() throws -> String? {
        guard try readBool() else { return nil }
        return try readString()
    }

    mutating func readOptionalUInt64() throws -> UInt64? {
        guard try readBool() else { return nil }
        return try readUInt64()
    }

    mutating func readOptionalUInt16() throws -> UInt16? {
        try readOptionalUInt64().map { UInt16(clamping: $0) }
    }

    mutating func readOptionalInt() throws -> Int? {
        try readOptionalUInt64().map { Int(clamping: $0) }
    }

    mutating func readOptionalDouble() throws -> Double? {
        guard try readBool() else { return nil }
        return try readDouble()
    }

    mutating func readOptionalJSONValue() throws -> JSONValue? {
        guard try readBool() else { return nil }
        return try readJSONValue()
    }

    mutating func readJSONValue() throws -> JSONValue {
        let tag = try readUInt8()
        switch tag {
        case 0:
            return .null
        case 1:
            return .bool(try readBool())
        case 2:
            return .number(try readDouble())
        case 3:
            return .string(try readString())
        case 4:
            let count = try readCount()
            var values: [JSONValue] = []
            values.reserveCapacity(count)
            for _ in 0..<count {
                values.append(try readJSONValue())
            }
            return .array(values)
        case 5:
            let count = try readCount()
            var object: [String: JSONValue] = [:]
            object.reserveCapacity(count)
            for _ in 0..<count {
                object[try readString()] = try readJSONValue()
            }
            return .object(object)
        default:
            throw RuntimeEventDecodeError.invalidJSONTag(tag)
        }
    }

    mutating func readAvailableDevices() throws -> [AvailableDevice] {
        let count = try readCount()
        var devices: [AvailableDevice] = []
        devices.reserveCapacity(count)
        for _ in 0..<count {
            let url = try readString()
            let label = try readString()
            let kind = try readString()
            let detail = try readString()
            let routeCount = try readCount()
            var routes: [AvailableDeviceRoute] = []
            routes.reserveCapacity(routeCount)
            for _ in 0..<routeCount {
                routes.append(AvailableDeviceRoute(
                    route: try readString(),
                    name: try readOptionalString()
                ))
            }
            devices.append(AvailableDevice(
                url: url,
                label: label,
                kind: kind,
                detail: detail,
                routes: routes
            ))
        }
        return devices
    }

    mutating func readDevices() throws -> [DeviceInfo] {
        let count = try readCount()
        var devices: [DeviceInfo] = []
        devices.reserveCapacity(count)
        for _ in 0..<count {
            devices.append(DeviceInfo(
                url: try readString(),
                route: try readString(),
                meta: try readDeviceMeta(),
                streams: try readStreams(),
                rpcs: try readRPCs()
            ))
        }
        return devices
    }

    mutating func readStreamValues() throws -> [StreamValueEvent] {
        let count = try readCount()
        var values: [StreamValueEvent] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(StreamValueEvent(
                key: try readColumnKey(),
                value: try readDouble()
            ))
        }
        return values
    }

    mutating func readColumnKeys() throws -> [ColumnKey] {
        let count = try readCount()
        var keys: [ColumnKey] = []
        keys.reserveCapacity(count)
        for _ in 0..<count {
            keys.append(try readColumnKey())
        }
        return keys
    }

    func finish() throws {
        let trailing = bytes.count - offset
        guard trailing == 0 else {
            throw RuntimeEventDecodeError.trailingBytes(trailing)
        }
    }

    private mutating func readDeviceMeta() throws -> DeviceMeta {
        DeviceMeta(
            serialNumber: try readString(),
            firmwareHash: try readString(),
            nStreams: Int(clamping: try readUInt64()),
            sessionId: UInt32(clamping: try readUInt64()),
            name: try readString()
        )
    }

    private mutating func readStreams() throws -> [StreamInfo] {
        let count = try readCount()
        var streams: [StreamInfo] = []
        streams.reserveCapacity(count)
        for _ in 0..<count {
            streams.append(StreamInfo(
                streamId: try readUInt8(),
                name: try readString(),
                nColumns: Int(clamping: try readUInt64()),
                sampleSize: Int(clamping: try readUInt64()),
                effectiveSamplingRate: try readDouble(),
                columns: try readColumns()
            ))
        }
        return streams
    }

    private mutating func readColumns() throws -> [ColumnInfo] {
        let count = try readCount()
        var columns: [ColumnInfo] = []
        columns.reserveCapacity(count)
        for _ in 0..<count {
            columns.append(ColumnInfo(
                key: try readColumnKey(),
                name: try readString(),
                units: try readString(),
                dataType: try readString(),
                description: try readString(),
                displayValue: try readOptionalDouble()
            ))
        }
        return columns
    }

    private mutating func readRPCs() throws -> [RpcInfo] {
        let count = try readCount()
        var rpcs: [RpcInfo] = []
        rpcs.reserveCapacity(count)
        for _ in 0..<count {
            rpcs.append(RpcInfo(
                route: try readString(),
                name: try readString(),
                size: Int(clamping: try readUInt64()),
                permissions: try readString(),
                argType: try readString(),
                readable: try readBool(),
                writable: try readBool(),
                persistent: try readBool(),
                unknown: try readBool(),
                value: try readOptionalJSONValue()
            ))
        }
        return rpcs
    }

    private mutating func readColumnKey() throws -> ColumnKey {
        ColumnKey(
            route: try readString(),
            streamId: try readUInt8(),
            columnIndex: max(0, Int(clamping: try readInt64()))
        )
    }

    private mutating func readCount() throws -> Int {
        Int(clamping: try readUInt32())
    }

    private mutating func readLittleEndianInteger(byteCount: Int) throws -> UInt64 {
        try require(byteCount)
        defer { offset += byteCount }
        var value: UInt64 = 0
        for index in 0..<byteCount {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private func require(_ count: Int) throws {
        guard count >= 0, offset + count <= bytes.count else {
            throw RuntimeEventDecodeError.truncated
        }
    }
}

private enum BinaryPlotDecodeError: LocalizedError {
    case truncated
    case invalidMode(UInt8)
    case invalidString
    case trailingBytes(Int)

    var errorDescription: String? {
        switch self {
        case .truncated:
            "Unexpected end of binary plot frame"
        case .invalidMode(let mode):
            "Invalid binary plot mode \(mode)"
        case .invalidString:
            "Invalid UTF-8 string in binary plot frame"
        case .trailingBytes(let count):
            "Binary plot frame has \(count) trailing byte(s)"
        }
    }
}

private struct BinaryPlotReader {
    private let bytes: UnsafeRawBufferPointer
    private var offset = 0

    init(_ bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    mutating func readUInt8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        try require(2)
        defer { offset += 2 }
        return UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    mutating func readUInt32() throws -> UInt32 {
        try require(4)
        defer { offset += 4 }
        return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    mutating func readDouble() throws -> Double {
        try require(8)
        defer { offset += 8 }
        let bits = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        return Double(bitPattern: bits)
    }

    mutating func readString(byteCount: Int) throws -> String {
        try require(byteCount)
        let start = offset
        offset += byteCount
        let slice = bytes[start..<offset]
        guard let value = String(bytes: slice, encoding: .utf8) else {
            throw BinaryPlotDecodeError.invalidString
        }
        return value
    }

    func finish() throws {
        let trailing = bytes.count - offset
        guard trailing == 0 else {
            throw BinaryPlotDecodeError.trailingBytes(trailing)
        }
    }

    private func require(_ count: Int) throws {
        guard count >= 0, offset + count <= bytes.count else {
            throw BinaryPlotDecodeError.truncated
        }
    }
}

@MainActor
private enum BridgeEventProfiler {
    private struct Cadence {
        var windowStart = DispatchTime.now().uptimeNanoseconds
        var count = 0
        var totalMicros: UInt64 = 0
        var totalBytes = 0
        var totalPoints = 0
        var lastSeriesCount = 0
        var lastPointCount = 0
        var lastViewportEnd: Double?
    }

    private static var cadenceByName: [String: Cadence] = [:]

    static let enabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return isEnabled(environment["TWINLEAF_PLOT_PROFILE"])
            || isEnabled(environment["TWINLEAF_STREAM_PROFILE"])
            || UserDefaults.standard.bool(forKey: "PlotProfilingEnabled")
    }()

    private static func isEnabled(_ value: String?) -> Bool {
        switch value?.lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    static func start() -> UInt64 {
        guard enabled else { return 0 }
        return DispatchTime.now().uptimeNanoseconds
    }

    static func record(
        _ name: String,
        start: UInt64,
        bytes: Int?,
        seriesCount: Int,
        pointCount: Int,
        viewportEnd: Double?
    ) {
        guard enabled, start > 0 else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        var cadence = cadenceByName[name] ?? Cadence(windowStart: now)
        cadence.count += 1
        cadence.totalMicros += UInt64((now - start) / 1_000)
        cadence.totalBytes += bytes ?? 0
        cadence.totalPoints += pointCount
        cadence.lastSeriesCount = seriesCount
        cadence.lastPointCount = pointCount
        cadence.lastViewportEnd = viewportEnd

        let elapsedNanos = now - cadence.windowStart
        guard elapsedNanos >= 1_000_000_000 else {
            cadenceByName[name] = cadence
            return
        }

        let seconds = Double(elapsedNanos) / 1_000_000_000
        let rate = Double(cadence.count) / seconds
        let avgMs = Double(cadence.totalMicros) / Double(cadence.count) / 1_000
        let avgKB = Double(cadence.totalBytes) / Double(max(cadence.count, 1)) / 1_024
        let avgPoints = Double(cadence.totalPoints) / Double(cadence.count)
        let viewport = cadence.lastViewportEnd.map { String(format: "%.6f", $0) } ?? "none"

        fputs(
            "[Twinleaf] profile \(name): \(String(format: "%.1f", rate))/s avg=\(String(format: "%.2f", avgMs)) ms avgKB=\(String(format: "%.1f", avgKB)) avgPoints=\(String(format: "%.0f", avgPoints)) lastSeries=\(cadence.lastSeriesCount) lastPoints=\(cadence.lastPointCount) lastViewport=\(viewport)\n",
            stderr
        )

        cadenceByName[name] = Cadence(windowStart: now)
    }
}

#if os(iOS)
/// iOS-native mDNS/Bonjour discovery of Twinleaf network devices.
///
/// macOS gets network discovery from the Rust core (raw multicast under the
/// sandbox). iOS forbids raw multicast without the approval-gated multicast
/// entitlement, so on iOS we browse with `NetServiceBrowser` instead, which
/// needs only the Local Network permission plus the `NSBonjourServices`
/// Info.plist keys. Resolving each service yields its advertised `.local`
/// hostname and port, so connect URLs read `tcp://twinleaf-00076.local:7855`
/// (no raw IP / interface scope). TCP is preferred when a device advertises
/// both transports.
///
/// Not `@MainActor`: `NetService`/`NetServiceBrowser` deliver delegate
/// callbacks on the run loop they are scheduled on. Everything here is driven
/// on the main run loop, and `onChange` is hopped onto the main actor when
/// fired.
final class BonjourDeviceBrowser: NSObject {
    /// Called on the main actor whenever the discovered set changes.
    var onChange: (@MainActor ([AvailableDevice]) -> Void)?

    private static let serviceTypes = ["_twinleaf._tcp.", "_twinleaf._udp."]

    private var browsers: [NetServiceBrowser] = []
    /// Services currently being resolved or already resolved, retained so they
    /// are not deallocated mid-resolution. Keyed by "scheme|instanceName".
    private var services: [String: NetService] = [:]
    private var devicesByKey: [String: AvailableDevice] = [:]

    func start() {
        guard browsers.isEmpty else { return }
        for type in Self.serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.schedule(in: .main, forMode: .common)
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
    }

    func stop() {
        for browser in browsers {
            browser.stop()
        }
        browsers.removeAll()
        for service in services.values {
            service.stop()
        }
        services.removeAll()
        devicesByKey.removeAll()
    }

    private static func scheme(for type: String) -> String {
        type.contains("_udp") ? "udp" : "tcp"
    }

    private func key(scheme: String, name: String) -> String {
        "\(scheme)|\(name)"
    }

    /// Merge per-scheme entries into one device per instance name, preferring
    /// the TCP advertisement when a device offers both, then notify.
    private func publish() {
        var byName: [String: AvailableDevice] = [:]
        for (entryKey, device) in devicesByKey {
            let name = entryKey.split(separator: "|", maxSplits: 1).last.map(String.init) ?? entryKey
            if let existing = byName[name], existing.url.hasPrefix("tcp") {
                continue
            }
            byName[name] = device
        }
        let merged = byName.values.sorted { $0.url < $1.url }
        // Capture only Sendable locals (not self) so the main-actor hop is
        // data-race-free under Swift 6. Delegate callbacks already run on the
        // main run loop, so this asserts isolation rather than dispatching.
        let callback = onChange
        MainActor.assumeIsolated {
            callback?(merged)
        }
    }
}

extension BonjourDeviceBrowser: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let scheme = Self.scheme(for: service.type)
        let entryKey = key(scheme: scheme, name: service.name)
        services[entryKey] = service
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let scheme = Self.scheme(for: service.type)
        let entryKey = key(scheme: scheme, name: service.name)
        services[entryKey]?.stop()
        services.removeValue(forKey: entryKey)
        if devicesByKey.removeValue(forKey: entryKey) != nil {
            publish()
        }
    }
}

extension BonjourDeviceBrowser: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        let hostText = host.hasSuffix(".") ? String(host.dropLast()) : host
        let scheme = Self.scheme(for: sender.type)
        let entryKey = key(scheme: scheme, name: sender.name)
        devicesByKey[entryKey] = AvailableDevice(
            url: "\(scheme)://\(hostText):\(sender.port)",
            label: sender.name,
            kind: "network",
            detail: "\(scheme.uppercased()) \u{00B7} \(hostText):\(sender.port)"
        )
        publish()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let scheme = Self.scheme(for: sender.type)
        services.removeValue(forKey: key(scheme: scheme, name: sender.name))
    }
}
#endif
