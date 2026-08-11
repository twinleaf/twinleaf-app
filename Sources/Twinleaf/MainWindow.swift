// SPDX-License-Identifier: Apache-2.0

import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

private struct PlotCanvasFrameHost: View {
    @ObservedObject var frames: PlotFrameStore
    let pane: PlotPaneSelection
    let independentVerticalAxisMode: VerticalAxisMode
    let showsIndependentAxisLabels: Bool
    let windowSeconds: Double
    let recordingStartSeconds: Double?
    let fftLogX: Bool
    let fftLogY: Bool
    let showKey: Bool
    let showsTimeseriesXAxisLabels: Bool
    var topPlotInset: CGFloat = 0
    var rightAxisReservationCount = 0
    var legendSafeAreaInsets = EdgeInsets()
    var onPlotWidthChange: (Double) -> Void = { _ in }
    var onCopyViewData: () -> Void = {}
    var onTimeseriesPan: (Double) -> Void = { _ in }
    var onTimeseriesZoom: (Double, Double) -> Void = { _, _ in }
    var onPlotColumnsDropped: (PlotColumnDragPayload) -> Void = { _ in }

    var body: some View {
        let series = frames.series(for: pane, maxCount: BridgeClient.maxPlotLineCount)
        let mode = frames.mode(for: pane)
        let usesFFT = mode == .fft

        PlotCanvas(
            paneID: pane.id,
            series: series,
            mode: mode,
            verticalAxisMode: usesFFT ? .shared : independentVerticalAxisMode,
            showsIndependentAxisLabels: usesFFT ? false : showsIndependentAxisLabels,
            windowSeconds: windowSeconds,
            viewportEnd: frames.viewportEnd(for: pane),
            plotRevision: frames.revision(for: pane),
            recordingStartSeconds: recordingStartSeconds,
            fftLogX: fftLogX,
            fftLogY: fftLogY,
            showKey: showKey,
            showsXAxisLabels: usesFFT || showsTimeseriesXAxisLabels,
            topPlotInset: topPlotInset,
            rightAxisReservationCount: rightAxisReservationCount,
            legendSafeAreaInsets: legendSafeAreaInsets,
            onPlotWidthChange: onPlotWidthChange,
            onCopyViewData: onCopyViewData,
            onTimeseriesPan: onTimeseriesPan,
            onTimeseriesZoom: onTimeseriesZoom,
            onPlotColumnsDropped: onPlotColumnsDropped
        )
    }
}

struct DocumentWindow: View {
    @Binding var document: TioLogDocument
    let fileURL: URL?

    @StateObject private var bridge = BridgeClient()
    @AppStorage("smokeThresholdMegabytes") private var smokeThresholdMegabytes = 1024.0
    @State private var showingDevicePicker = true
    @State private var showingPlotSettings = false
    @State private var showingExportPanel = false
    @State private var showingUpgradePopover = false
    @State private var showingHealthPopover = false
    @State private var didStartDocument = false
    @State private var lastExportFormat: ExportFormat = .csv
    @State private var streamSplitVisibility: NavigationSplitViewVisibility = .all
    @State private var isApplyingStreamSplitVisibility = false
    #if os(iOS)
    /// On iPhone (compact), `NavigationSplitView` shows one column at a time.
    /// The sidebar's "View Graph" row flips this to `.detail` to surface the plot.
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var rpcSearchFocusRequest = 0
    @State private var verticalAxisModes: [Int: VerticalAxisMode] = [:]
    @State private var independentAxisLabelVisibility: [Int: Bool] = [:]
    @State private var rpcSliders: [RPCSliderConfiguration] = []
    @State private var activeCaptureRPCID: String?
    @State private var captureAutoEnabled = false
    @State private var isDataLoggingEnabled = true
    @State private var clearDocumentEditedRequest = 0
    @State private var windowObjectID: ObjectIdentifier?
    @State private var isApplyingBoardViewLayout = false
    @State private var restoredBoardViewLayoutDeviceSignature = ""
#if os(macOS)
    @State private var plotPopoutControllers: [Int: PlotPopoutWindowController] = [:]
    @State private var capturePopoutControllers: [String: PlotPopoutWindowController] = [:]
    @State private var sliderPopoutControllers: [String: PlotPopoutWindowController] = [:]
#endif
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ViewPreferenceKeys.theme) private var themeRaw = ThemePreference.system.rawValue
    @AppStorage(ViewPreferenceKeys.distractionFree) private var distractionFree = false
    @AppStorage(ViewPreferenceKeys.showStreamSidebar) private var showStreamSidebar = true
    @AppStorage(ViewPreferenceKeys.showRPCPanel) private var legacyShowRPCPanel = false
    @AppStorage(ViewPreferenceKeys.showLogPanel) private var showLogPanel = false
    @AppStorage(ViewPreferenceKeys.showStatusBar) private var showStatusBar = false
    @AppStorage(ViewPreferenceKeys.showToolbar) private var showToolbar = true
    @AppStorage(ViewPreferenceKeys.showPlotKey) private var showPlotKey = true
    @AppStorage(ViewPreferenceKeys.logOnStartup) private var logOnStartup = false
    @AppStorage(ViewPreferenceKeys.showAllSerialPorts) private var showAllSerialPorts = true
    @AppStorage(ViewPreferenceKeys.streamSidebarWidth) private var streamSidebarWidth = SidebarLayout.defaultStreamWidth
    @AppStorage(ViewPreferenceKeys.rpcPanelWidth) private var rpcPanelWidth = SidebarLayout.defaultRPCWidth
    @AppStorage(ViewPreferenceKeys.boardViewLayouts) private var boardViewLayoutsRaw = ""
    @AppStorage("view.rightSidebarMode") private var legacyRightSidebarModeRaw = ""
    @State private var measuredRightSidebarTopInset: CGFloat = 0
    @State private var didMigrateLegacyRightSidebarMode = false
    @State private var editableSettingIDs: [String] = []
    @FocusState private var focusedField: RpcFocusField?

    private static let splitViewCoordinateSpaceName = "TwinleafSplitView"

    init(document: Binding<TioLogDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        let shouldOpenForInspection = document.wrappedValue.shouldOpenForInspection
        let storedLogOnStartup = UserDefaults.standard.object(forKey: ViewPreferenceKeys.logOnStartup) as? Bool ?? false
        _showingDevicePicker = State(initialValue: !shouldOpenForInspection)
        _isDataLoggingEnabled = State(initialValue: shouldOpenForInspection ? false : storedLogOnStartup)
    }

    private var focusChain: [RpcFocusField] {
        [.search]
            + editableSettingIDs.map(RpcFocusField.rpc)
            + rpcSliders.map { RpcFocusField.slider($0.id) }
    }

    var body: some View {
        documentContentWithPlatformToolbar
            .preferredColorScheme(themePreference.preferredColorScheme)
            .twinleafDocumentMinimumFrame()
            .background {
                ZStack {
                    WindowFrameAutosaver(
                        autosaveName: "TwinleafDocumentWindowFrame",
                        colorScheme: effectiveWindowColorScheme,
                        windowObjectID: $windowObjectID
                    )
                    DocumentEditedStateResetter(clearRequest: clearDocumentEditedRequest)
                }
            }
            .overlay {
                if shouldShowSmoke {
                    SmokeOverlay(
                        fileBytes: bridge.logBytes,
                        thresholdBytes: smokeThresholdBytes
                    )
                    .transition(.opacity)
                }
            }
#if os(macOS)
            .overlay {
                if showingDevicePicker {
                    devicePickerOverlay
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
#else
            .sheet(isPresented: $showingDevicePicker) {
                devicePickerContent
                    .twinleafDevicePickerPresentation()
            }
#endif
            .twinleafIOSNavigationBackButtonHidden()
            .twinleafWindowToolbarVisibility(effectiveShowToolbar)
            .fileExporter(
                isPresented: $showingExportPanel,
                document: ExportDestinationDocument(),
                contentTypes: ExportFormat.allCases.map(\.contentType),
                defaultFilename: exportDefaultFilename
            ) { result in
                handleExportDestination(result)
            }
            .task {
                guard !didStartDocument else { return }
                didStartDocument = true
                bridge.startIfNeeded()
                if document.shouldOpenForInspection {
                    isDataLoggingEnabled = false
                    bridge.openLogFile(at: document.temporaryLogURL)
                } else {
                    isDataLoggingEnabled = logOnStartup
                    if logOnStartup {
                        document.ensureTemporaryLogFile()
                    } else {
                        document.removeTemporaryLogFile()
                        clearDocumentEditedRequest &+= 1
                    }
                    bridge.listDevices(includeAllSerial: showAllSerialPorts)
                }
            }
            .sheet(isPresented: $showingPlotSettings) {
                PlotSettingsWindow(bridge: bridge)
                    .twinleafSettingsPresentation()
            }
            .onChange(of: bridge.logRevision) { _, _ in
                guard isDataLoggingEnabled else { return }
                document.markLogUpdated()
            }
            .onAppear {
                migrateLegacyRightSidebarModeIfNeeded()
                normalizePersistedSidebarWidths()
                applyStreamSplitVisibilityFromPreferences()
            }
            .onPreferenceChange(StreamSidebarWidthPreferenceKey.self) { width in
                updateStreamSidebarWidth(width)
            }
            .onPreferenceChange(EditableSettingIDsKey.self) { ids in
                editableSettingIDs = ids
            }
            #if os(macOS)
            .background(TabFocusMonitor(chain: focusChain, focus: $focusedField))
            #endif
            .onChange(of: distractionFree) { wasDistractionFree, isDistractionFree in
                if wasDistractionFree && !isDistractionFree {
                    showToolbar = true
                    showStreamSidebar = true
                }
                applyStreamSplitVisibilityFromPreferences()
            }
            .onChange(of: showStreamSidebar) { _, _ in
                applyStreamSplitVisibilityFromPreferences()
            }
            .onChange(of: bridge.devices) { _, _ in
                pruneRPCSliders()
                pruneCaptureView()
                restoreBoardViewLayoutsForCurrentDevices()
#if os(macOS)
                let activeRPCIDs = Set(bridge.devices.flatMap(\.rpcs).map(\.id))
                closeCapturePopouts(missingFrom: activeRPCIDs)
                closeSliderPopouts(missingFrom: activeRPCIDs)
#endif
            }
            .onChange(of: bridge.plotPanes) { _, panes in
                saveBoardViewLayoutsForCurrentDevices()
#if os(macOS)
                closePlotPopouts(missingFrom: Set(panes.map(\.id)))
#endif
            }
            .onChange(of: rpcSliders) { _, _ in
                saveBoardViewLayoutsForCurrentDevices()
            }
            .onChange(of: verticalAxisModes) { _, _ in
                saveBoardViewLayoutsForCurrentDevices()
            }
            .onChange(of: independentAxisLabelVisibility) { _, _ in
                saveBoardViewLayoutsForCurrentDevices()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showDevicePicker)) { _ in
                guard !bridge.isInspectionMode else { return }
                bridge.listDevices(includeAllSerial: showAllSerialPorts)
                showingDevicePicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .showExportPanel)) { notification in
                guard receivesWindowCommand(notification) else { return }
                presentExportPanel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .showPlotSettings)) { _ in
                showingPlotSettings = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .togglePlotPause)) { _ in
                bridge.togglePlotPaused()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleDataLogging)) { notification in
                guard receivesWindowCommand(notification) else { return }
                setDataLoggingEnabled(!isDataLoggingEnabled)
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshDeviceList)) { _ in
                guard !bridge.isInspectionMode else { return }
                bridge.listDevices(includeAllSerial: showAllSerialPorts)
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusRPCSearch)) { _ in
                distractionFree = false
                showStreamSidebar = true
                DispatchQueue.main.async {
                    rpcSearchFocusRequest &+= 1
                }
            }
            .onDisappear {
#if os(macOS)
                closeAllPlotPopouts()
                closeAllAuxiliaryPopouts()
#endif
                bridge.disconnect()
#if os(iOS)
                deleteUntouchedDocumentFileIfNeeded()
#endif
            }
    }

    @ViewBuilder
    private var documentContentWithPlatformToolbar: some View {
#if os(macOS)
        documentContent
            .toolbar {
                windowToolbar
            }
#else
        documentContent
#endif
    }

    @ViewBuilder
    private var documentContent: some View {
#if os(macOS)
        GeometryReader { geometry in
            if shouldUseCompactSidebarOnlyLayout(width: geometry.size.width) {
                streamSidebarContent(reportsWidth: false)
                    .navigationTitle("Streams")
                    .frame(
                        maxWidth: SidebarLayout.compactSidebarOnlyMaximumWidth,
                        maxHeight: .infinity
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                splitDocumentContent
            }
        }
        .coordinateSpace(name: Self.splitViewCoordinateSpaceName)
#else
        splitDocumentContent
            .coordinateSpace(name: Self.splitViewCoordinateSpaceName)
#endif
    }

    private var splitDocumentContent: some View {
        #if os(iOS)
        NavigationSplitView(
            columnVisibility: streamColumnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            streamSidebarContent()
                .navigationTitle("Streams")
                .navigationSplitViewColumnWidth(
                    min: CGFloat(SidebarLayout.streamWidthRange.lowerBound),
                    ideal: CGFloat(clampedStreamSidebarWidth),
                    max: CGFloat(SidebarLayout.streamWidthRange.upperBound)
                )
        } detail: {
            detailContent
        }
        #else
        NavigationSplitView(columnVisibility: streamColumnVisibility) {
            streamSidebarContent()
                .navigationTitle("Streams")
                .navigationSplitViewColumnWidth(
                    min: CGFloat(SidebarLayout.streamWidthRange.lowerBound),
                    ideal: CGFloat(clampedStreamSidebarWidth),
                    max: CGFloat(SidebarLayout.streamWidthRange.upperBound)
                )
        } detail: {
            detailContent
        }
        #endif
    }

    /// The "View Graph" shortcut row is only useful when the plot isn't already
    /// on screen — i.e., a compact single-column layout currently showing the
    /// sidebar. In a regular two-column layout (iPad, wide windows) the graph is
    /// always visible, so the row is hidden. Computed at the scene root, where
    /// the size class is authoritative (reading it inside the split view's
    /// sidebar column can report the wrong value).
    private var showsGraphShortcut: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact && preferredCompactColumn == .sidebar
        #else
        false
        #endif
    }

    @ViewBuilder
    private func streamSidebarContent(reportsWidth: Bool = true) -> some View {
        let sidebar = StreamSidebar(
            bridge: bridge,
            rpcFocusRequest: rpcSearchFocusRequest,
            activeSliderIDs: Set(rpcSliders.map(\.id)),
            onToggleSlider: toggleRPCSlider,
            onCaptureRPC: openCaptureView,
            onOpenPlotWindow: openPlotWindowAction,
            onOpenSliderWindow: openSliderWindowAction,
            onOpenCaptureWindow: openCaptureWindowAction,
            focusedField: $focusedField,
            showsGraphShortcut: showsGraphShortcut,
            onShowGraph: {
                #if os(iOS)
                preferredCompactColumn = .detail
                #endif
            }
        )
        // Attached to the sidebar content so the item lives in the sidebar's
        // toolbar section and disappears together with the sidebar.
        if reportsWidth {
            sidebar
                .background(StreamSidebarWidthReporter())
                .toolbar { UnifySensorsToolbarItem(isAvailable: hasUnifiableSensors) }
        } else {
            sidebar
                .toolbar { UnifySensorsToolbarItem(isAvailable: hasUnifiableSensors) }
        }
    }

    /// True when at least two connected sensors share a device type.
    private var hasUnifiableSensors: Bool {
        var counts: [String: Int] = [:]
        for device in bridge.devices where !device.meta.name.isEmpty {
            counts[device.meta.name, default: 0] += 1
            if counts[device.meta.name] == 2 {
                return true
            }
        }
        return false
    }

    private var openPlotWindowAction: (([ColumnKey]) -> Void)? {
#if os(macOS)
        return { keys in
            popOutNewPlot(columns: keys)
        }
#elseif os(iOS)
        return { keys in
            openIPadPlotPopout(columns: keys)
        }
#else
        return nil
#endif
    }

    #if os(iOS)
    @Environment(\.openWindow) private var openIPadWindow

    private func openIPadPlotPopout(columns keys: [ColumnKey]) {
        guard let paneID = bridge.addPlotPane(columns: keys) else { return }
        openIPadWindow(value: PlotPopoutDescriptor(sessionID: bridge.sessionID, paneID: paneID))
    }
    #endif

    private var openSliderWindowAction: ((RpcInfo) -> Void)? {
#if os(macOS)
        return { rpc in
            popOutSlider(for: rpc)
        }
#else
        return nil
#endif
    }

    private var openSliderConfigurationWindowAction: ((RPCSliderConfiguration) -> Void)? {
#if os(macOS)
        return { slider in
            popOutSlider(slider)
        }
#else
        return nil
#endif
    }

    private var openCaptureWindowAction: ((RpcInfo) -> Void)? {
#if os(macOS)
        return { rpc in
            popOutCapture(rpc)
        }
#else
        return nil
#endif
    }

    @ViewBuilder
    private var detailContent: some View {
#if os(iOS)
        detailPane
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                iosCompactSidebarToggle
                iosDocumentToolbar
                windowToolbar
            }
#else
        detailPane
            .navigationTitle(documentDisplayName)
#endif
    }

#if os(iOS)
    /// Explicit "back to sidebar" affordance on iPhone compact. Bound directly
    /// to `preferredCompactColumn` so it works the same direction as the
    /// sidebar's "View Graph" row (which goes the other way). The system back
    /// button is unreliable here — NavigationSplitView's `preferredCompactColumn`
    /// binding doesn't always synthesize one, and any toolbar item we place in
    /// `.topBarLeading` ends up next to it anyway.
    @ToolbarContentBuilder
    private var iosCompactSidebarToggle: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            CompactSidebarToggleButton(preferredCompactColumn: $preferredCompactColumn)
        }
    }
#endif

    private var detailPane: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                plotArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if effectiveShowLogPanel {
                    logSlideOverPane
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: effectiveShowLogPanel)

            if effectiveShowStatusBar {
                Divider()
                statusBar
            }
        }
        #if os(macOS)
        // The 700×640 floor keeps the plot area usable on macOS where the user
        // can resize the window arbitrarily. On iOS the screen IS the minimum
        // — forcing a 700pt floor would push the plot off the right edge of
        // every iPhone in portrait. Let the view shrink to the available size.
        .frame(minWidth: SidebarLayout.detailMinimumWidth, minHeight: 640)
        #endif
    }

    private var devicePickerOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(effectiveWindowColorScheme == .dark ? 0.24 : 0.12))
                .ignoresSafeArea()

            let panelShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            devicePickerContent
                .background {
                    panelShape
                        .fill(.clear)
                        .glassEffect(.regular, in: panelShape)
                }
                .shadow(color: .black.opacity(effectiveWindowColorScheme == .dark ? 0.45 : 0.18), radius: 22, x: 0, y: 12)
                .padding(.vertical, 40)
        }
    }

    private var devicePickerContent: some View {
        DevicePicker(
            bridge: bridge,
            fileURL: fileURL,
            temporaryLogURL: document.temporaryLogURL,
            loggingEnabled: logFromStartBinding,
            onDismiss: {
                showingDevicePicker = false
            }
        )
    }

    /// Connect-window switch binding: reflects the live logging state, and on
    /// toggle both flips the current session's logging AND persists the choice
    /// to `logOnStartup` so future Connects default the same way.
    private var logFromStartBinding: Binding<Bool> {
        Binding(
            get: { isDataLoggingEnabled },
            set: { newValue in
                setDataLoggingEnabled(newValue)
                logOnStartup = newValue
            }
        )
    }

    private func presentExportPanel() {
        showingExportPanel = true
    }

    private var exportBaseName: String {
        let stem = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return stem.isEmpty ? "Twinleaf Export" : stem
    }

    private var exportDefaultFilename: String {
        exportBaseName.appending(".\(lastExportFormat.fileExtension)")
    }

    private var documentDisplayName: String {
        fileURL?.lastPathComponent ?? "Untitled .tio"
    }

    private var documentShareURL: URL {
        fileURL ?? document.temporaryLogURL
    }

    private func handleExportDestination(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let format = selectedExportFormat(from: url)
            lastExportFormat = format
            bridge.exportLog(
                sourceURL: document.temporaryLogURL,
                destinationURL: format.normalizedURL(url),
                format: format
            )
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            bridge.status = "Export failed: \(error.localizedDescription)"
            bridge.statusState = "error"
        }
    }

    private func selectedExportFormat(from url: URL) -> ExportFormat {
        let pathExtension = url.pathExtension.lowercased()
        return ExportFormat.allCases.first { $0.acceptedExtensions.contains(pathExtension) } ?? lastExportFormat
    }

    private var themePreference: ThemePreference {
        ThemePreference(rawValue: themeRaw) ?? .system
    }

    private var effectiveWindowColorScheme: ColorScheme {
        themePreference.preferredColorScheme ?? colorScheme
    }

    private var effectiveShowStreamSidebar: Bool {
        !distractionFree && showStreamSidebar
    }

    private func shouldUseCompactSidebarOnlyLayout(width: CGFloat) -> Bool {
        effectiveShowStreamSidebar
            && width.isFinite
            && width <= SidebarLayout.compactSidebarOnlyMaximumWidth
    }

    private var effectiveShowLogPanel: Bool {
        !distractionFree && showLogPanel
    }

    private var effectiveShowStatusBar: Bool {
        !distractionFree && showStatusBar
    }

    private var effectiveShowToolbar: Bool {
        !distractionFree && showToolbar
    }

    private var effectiveShowPlotControls: Bool {
#if os(iOS)
        true
#else
        !distractionFree
#endif
    }

    private var shouldAlwaysShowPlotControls: Bool {
#if os(iOS)
        true
#else
        false
#endif
    }

    private var canControlDataLogging: Bool {
        !document.shouldOpenForInspection && !bridge.isInspectionMode
    }

    private func receivesWindowCommand(_ notification: Notification) -> Bool {
        guard let targetWindowID = notification.object as? ObjectIdentifier else {
            return true
        }
        return targetWindowID == windowObjectID
    }

    private var dataLoggingEnabledBinding: Binding<Bool> {
        Binding(
            get: { isDataLoggingEnabled },
            set: { setDataLoggingEnabled($0) }
        )
    }

    private var logSlideOverPane: some View {
        HStack(spacing: 0) {
            SidebarResizeHandle(
                width: $rpcPanelWidth,
                range: SidebarLayout.rpcWidthRange,
                dragDirection: .leftEdge,
                accessibilityLabel: "Resize log pane"
            )

            LogSidebar(bridge: bridge)
                .padding(.top, effectiveRightSidebarContentTopInset)
                .frame(width: clampedRPCPanelWidth)
        }
        .frame(width: CGFloat(clampedRPCPanelWidth) + SidebarLayout.resizeHandleWidth)
        .frame(maxHeight: .infinity)
        .background(TwinleafSurfaceColors.slideOverBackgroundColor(for: effectiveWindowColorScheme))
        .background {
            WindowContentTopInsetReporter(topInset: $measuredRightSidebarTopInset)
        }
        .shadow(color: .black.opacity(effectiveWindowColorScheme == .dark ? 0.34 : 0.16), radius: 18, x: -8, y: 0)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var effectiveRightSidebarContentTopInset: CGFloat {
        guard effectiveShowToolbar else { return 0 }
        if measuredRightSidebarTopInset > 1 {
            return measuredRightSidebarTopInset
        }
        return SidebarLayout.fallbackToolbarContentTopInset
    }

    private var logInspectorSelectionBinding: Binding<Bool> {
        Binding(
            get: {
                effectiveShowLogPanel
            },
            set: { isSelected in
                distractionFree = false
                showLogPanel = isSelected
            }
        )
    }

    private func migrateLegacyRightSidebarModeIfNeeded() {
        guard !didMigrateLegacyRightSidebarMode else { return }
        didMigrateLegacyRightSidebarMode = true

        switch legacyRightSidebarModeRaw {
        case "log" where legacyShowRPCPanel:
            showLogPanel = true
        default:
            break
        }

        if legacyShowRPCPanel {
            showStreamSidebar = true
            legacyShowRPCPanel = false
        }
        legacyRightSidebarModeRaw = ""
    }

    private var streamColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                streamSplitVisibility
            },
            set: { visibility in
                streamSplitVisibility = visibility
                guard !distractionFree, !isApplyingStreamSplitVisibility else { return }
                showStreamSidebar = visibility != .detailOnly
            }
        )
    }

    private func applyStreamSplitVisibilityFromPreferences() {
        let target: NavigationSplitViewVisibility = effectiveShowStreamSidebar ? .all : .detailOnly
        guard streamSplitVisibility != target else { return }

        isApplyingStreamSplitVisibility = true
        streamSplitVisibility = target
        DispatchQueue.main.async {
            isApplyingStreamSplitVisibility = false
        }
    }

    private var clampedStreamSidebarWidth: Double {
        clamp(streamSidebarWidth, to: SidebarLayout.streamWidthRange)
    }

    private var clampedRPCPanelWidth: Double {
        clamp(rpcPanelWidth, to: SidebarLayout.rpcWidthRange)
    }

    private func normalizePersistedSidebarWidths() {
        let normalizedStreamWidth = clampedStreamSidebarWidth
        if abs(streamSidebarWidth - normalizedStreamWidth) >= 0.5 {
            streamSidebarWidth = normalizedStreamWidth
        }

        let normalizedRPCWidth = clampedRPCPanelWidth
        if abs(rpcPanelWidth - normalizedRPCWidth) >= 0.5 {
            rpcPanelWidth = normalizedRPCWidth
        }
    }

    private func updateStreamSidebarWidth(_ width: CGFloat?) {
        guard effectiveShowStreamSidebar,
              let width,
              width.isFinite,
              width >= CGFloat(SidebarLayout.streamWidthRange.lowerBound) - 1 else {
            return
        }

        let clampedWidth = clamp(Double(width), to: SidebarLayout.streamWidthRange)
        guard abs(streamSidebarWidth - clampedWidth) >= 0.5 else { return }
        streamSidebarWidth = clampedWidth
    }

    #if os(iOS)
    /// iOS `DocumentGroup` creates the file at "Connect" time, before the user
    /// has had a chance to log anything. If the file on disk is still empty
    /// at close, it's just litter from the connect flow — silently delete it.
    /// (We can't distinguish "freshly created" from "opened existing": iOS
    /// DocumentGroup round-trips new docs through the file system, so every
    /// opened document looks loaded-from-file. A zero-byte file is the
    /// strongest signal that nothing was actually recorded or imported.)
    private func deleteUntouchedDocumentFileIfNeeded() {
        guard let fileURL else { return }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(
            writingItemAt: fileURL,
            options: .forDeleting,
            error: &coordError
        ) { url in
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  size == 0 else {
                return
            }
            try? fm.removeItem(at: url)
        }
    }
    #endif

    private var currentBoardViewLayoutDeviceSignature: String {
        bridge.devices
            .map { "\(BoardViewLayoutStore.boardKey(for: $0))#\($0.route)" }
            .sorted()
            .joined(separator: "|")
    }

    private func restoreBoardViewLayoutsForCurrentDevices() {
        let signature = currentBoardViewLayoutDeviceSignature
        guard !signature.isEmpty, !bridge.isInspectionMode else {
            restoredBoardViewLayoutDeviceSignature = signature
            return
        }
        guard signature != restoredBoardViewLayoutDeviceSignature else {
            return
        }

        let store = BoardViewLayoutStore(rawValue: boardViewLayoutsRaw)
        let devicesWithLayouts = bridge.devices.compactMap { device -> (DeviceInfo, BoardViewLayout)? in
            let key = BoardViewLayoutStore.boardKey(for: device)
            guard let layout = store.boards[key] else { return nil }
            return (device, layout)
        }
        guard !devicesWithLayouts.isEmpty else {
            restoredBoardViewLayoutDeviceSignature = signature
            return
        }

        var paneRestores: [RestoredBoardPlotPane] = []
        var sliderRestores: [RPCSliderConfiguration] = []
        var savedPaneCount = 0

        for (device, layout) in devicesWithLayouts {
            savedPaneCount += layout.panes.count
            for pane in layout.panes {
                let columns = pane.columns.compactMap { columnKey(for: $0, in: device) }
                guard !columns.isEmpty else { continue }
                var viewConfig = bridge.viewConfig
                viewConfig.mode = pane.mode
                paneRestores.append(RestoredBoardPlotPane(
                    request: PlotPaneRestoreRequest(viewConfig: viewConfig, columns: columns),
                    axisMode: pane.axisMode,
                    showsIndependentAxisLabels: pane.showsIndependentAxisLabels
                ))
            }

            for slider in layout.sliders {
                guard let rpc = bridge.rpc(route: device.route, name: slider.name),
                      rpc.isSliderSuitable else {
                    continue
                }
                sliderRestores.append(RPCSliderConfiguration(
                    route: device.route,
                    name: rpc.name,
                    minimum: slider.validMinimum,
                    maximum: slider.validMaximum,
                    maximumRPCName: slider.maximumRPCName,
                    maximumEdited: slider.maximumEdited,
                    isExpanded: slider.isExpanded
                ))
            }
        }

        if savedPaneCount > 0 && paneRestores.isEmpty {
            if bridge.devices.contains(where: { !$0.streams.isEmpty }) {
                restoredBoardViewLayoutDeviceSignature = signature
            }
            return
        }

        isApplyingBoardViewLayout = true
        restoredBoardViewLayoutDeviceSignature = signature
        let restoredIDs = bridge.replacePlotPanes(with: paneRestores.map(\.request))
        verticalAxisModes.removeAll()
        independentAxisLabelVisibility.removeAll()
        for (paneID, pane) in zip(restoredIDs, paneRestores) {
            verticalAxisModes[paneID] = pane.axisMode
            independentAxisLabelVisibility[paneID] = pane.showsIndependentAxisLabels
        }
        rpcSliders = uniqueSliders(sliderRestores)
        pruneRPCSliders()
        isApplyingBoardViewLayout = false
    }

    private func saveBoardViewLayoutsForCurrentDevices() {
        guard !isApplyingBoardViewLayout,
              !bridge.isInspectionMode else {
            return
        }

        let signature = currentBoardViewLayoutDeviceSignature
        guard !signature.isEmpty,
              signature == restoredBoardViewLayoutDeviceSignature else {
            return
        }

        var store = BoardViewLayoutStore(rawValue: boardViewLayoutsRaw)
        for device in bridge.devices {
            let key = BoardViewLayoutStore.boardKey(for: device)
            var layout = boardViewLayout(for: device)
            layout.expandedStreams = store.boards[key]?.expandedStreams
            store.boards[key] = layout
        }
        boardViewLayoutsRaw = store.rawValue
    }

    private func boardViewLayout(for device: DeviceInfo) -> BoardViewLayout {
        let panes = bridge.plotPanes.compactMap { pane -> BoardPlotPaneLayout? in
            let columns = pane.columns
                .filter { $0.route == device.route }
                .sorted()
                .map { BoardColumnReference(streamId: $0.streamId, columnIndex: $0.columnIndex) }
            guard !columns.isEmpty else { return nil }
            return BoardPlotPaneLayout(
                columns: columns,
                mode: pane.viewConfig.mode,
                axisMode: effectiveVerticalAxisMode(for: pane.id),
                showsIndependentAxisLabels: showsIndependentAxisLabels(for: pane.id)
            )
        }

        let sliders = rpcSliders
            .filter { $0.route == device.route }
            .map(BoardRPCSliderLayout.init)

        return BoardViewLayout(panes: panes, sliders: sliders)
    }

    private func columnKey(for reference: BoardColumnReference, in device: DeviceInfo) -> ColumnKey? {
        guard let stream = device.streams.first(where: { $0.streamId == reference.streamId }),
              stream.columns.contains(where: { $0.key.columnIndex == reference.columnIndex }) else {
            return nil
        }
        return ColumnKey(
            route: device.route,
            streamId: reference.streamId,
            columnIndex: reference.columnIndex
        )
    }

    private func uniqueSliders(_ sliders: [RPCSliderConfiguration]) -> [RPCSliderConfiguration] {
        var seen: Set<String> = []
        return sliders.filter { seen.insert($0.id).inserted }
    }

    private func toggleRPCSlider(_ rpc: RpcInfo) {
        if rpcSliders.contains(where: { $0.id == rpc.id }) {
            rpcSliders.removeAll { $0.id == rpc.id }
        } else {
            addRPCSlider(for: rpc)
        }
    }

    private func addRPCSlider(for rpc: RpcInfo) {
        let maximumRPC = bridge.rpc(route: rpc.route, name: "\(rpc.name).max")
        if let maximumRPC, maximumRPC.readable {
            bridge.callRpc(maximumRPC)
        }

        rpcSliders.append(sliderConfiguration(for: rpc, maximumRPC: maximumRPC))
    }

    private func sliderConfiguration(for rpc: RpcInfo, maximumRPC: RpcInfo? = nil) -> RPCSliderConfiguration {
        let currentValue = rpc.value?.numberValue ?? 0
        let resolvedMaximumRPC = maximumRPC ?? bridge.rpc(route: rpc.route, name: "\(rpc.name).max")
        let maximum = defaultSliderMaximum(
            currentValue: currentValue,
            maximumRPCValue: resolvedMaximumRPC?.value?.numberValue
        )
        return RPCSliderConfiguration(
            route: rpc.route,
            name: rpc.name,
            minimum: 0,
            maximum: maximum,
            maximumRPCName: resolvedMaximumRPC?.isNumericRPC == true ? resolvedMaximumRPC?.name : nil
        )
    }

    private func pruneRPCSliders() {
        rpcSliders.removeAll { bridge.rpc(id: $0.id) == nil }
    }

    private func openCaptureView(for rpc: RpcInfo) {
        let didChangeCapture = activeCaptureRPCID != rpc.id
        activeCaptureRPCID = rpc.id
        if didChangeCapture {
            captureAutoEnabled = false
        }
        triggerCapture(rpc)
    }

    private func triggerCapture(_ rpc: RpcInfo) {
        bridge.callRpc(rpc, optimisticallyUpdate: false)
    }

    private func closeCaptureView() {
        activeCaptureRPCID = nil
        captureAutoEnabled = false
    }

    private func pruneCaptureView() {
        guard let activeCaptureRPCID,
              bridge.rpc(id: activeCaptureRPCID) == nil else {
            return
        }
        closeCaptureView()
    }

    private var activeCaptureRPC: RpcInfo? {
        activeCaptureRPCID.flatMap { bridge.rpc(id: $0) }
    }

    private func defaultSliderMaximum(currentValue: Double, maximumRPCValue: Double?) -> Double {
        if let maximumRPCValue,
           maximumRPCValue.isFinite,
           maximumRPCValue > 0 {
            return maximumRPCValue
        }

        let magnitude = abs(currentValue)
        guard magnitude > 0 else { return 1 }
        return pow(10, ceil(log10(magnitude)))
    }

    private var plotArea: some View {
        VStack(spacing: 0) {
            if bridge.isInspectionMode {
                playbackScrubber
                Divider()
            }

            if shouldUseSliderOnlyPlotArea {
                if let captureRPC = activeCaptureRPC {
#if os(macOS)
                    let popOutCaptureAction: (() -> Void)? = { popOutCapture(captureRPC) }
#else
                    let popOutCaptureAction: (() -> Void)? = nil
#endif
                    // With no graphs visible, the capture plot takes all the
                    // free vertical space, like a graph would.
                    CaptureResultPane(
                        bridge: bridge,
                        rpcID: captureRPC.id,
                        isAutoEnabled: $captureAutoEnabled,
                        alwaysShowsRail: shouldAlwaysShowPlotControls,
                        maximumHeight: .infinity,
                        onTrigger: triggerCapture,
                        onPopOut: popOutCaptureAction,
                        onClose: closeCaptureView
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Spacer(minLength: 0)
                }
                if !rpcSliders.isEmpty {
                    if activeCaptureRPC != nil { Divider() }
                    RPCSliderTray(
                        bridge: bridge,
                        sliders: $rpcSliders,
                        onOpenSliderWindow: openSliderConfigurationWindowAction,
                        focusedField: $focusedField
                    )
                }
                if activeCaptureRPC == nil {
                    Spacer(minLength: 0)
                }
            } else {
                GeometryReader { plotAreaGeometry in
                    VStack(spacing: 0) {
                        if !visiblePlotPanes.isEmpty {
                            stackedPlots
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }

                        if let captureRPC = activeCaptureRPC {
#if os(macOS)
                            let popOutCaptureAction: (() -> Void)? = { popOutCapture(captureRPC) }
#else
                            let popOutCaptureAction: (() -> Void)? = nil
#endif
                            if !visiblePlotPanes.isEmpty {
                                Divider()
                            }
                            // Share the vertical space evenly with the graphs:
                            // the capture plot takes one graph-sized slot.
                            CaptureResultPane(
                                bridge: bridge,
                                rpcID: captureRPC.id,
                                isAutoEnabled: $captureAutoEnabled,
                                alwaysShowsRail: shouldAlwaysShowPlotControls,
                                maximumHeight: .infinity,
                                onTrigger: triggerCapture,
                                onPopOut: popOutCaptureAction,
                                onClose: closeCaptureView
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: captureShareHeight(in: plotAreaGeometry))
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        if !rpcSliders.isEmpty {
                            if !visiblePlotPanes.isEmpty || activeCaptureRPC != nil {
                                Divider()
                            }
                            RPCSliderTray(
                                bridge: bridge,
                                sliders: $rpcSliders,
                                onOpenSliderWindow: openSliderConfigurationWindowAction,
                                focusedField: $focusedField
                            )
                        } else if visiblePlotPanes.isEmpty {
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One graph-sized slot for the capture plot: the available height divided
    /// evenly among the visible graphs plus the capture pane.
    private func captureShareHeight(in geometry: GeometryProxy) -> CGFloat? {
        let paneCount = visiblePlotPanes.count
        guard paneCount > 0 else { return nil }
        return max(180, geometry.size.height / CGFloat(paneCount + 1))
    }

    /// True when the user has a slider or capture active but no plot pane is
    /// actually displaying anything (all panes have empty `columns`). Lets the
    /// layout collapse the empty "Select one or more streams" placeholder and
    /// vertically center the slider / capture surface in the available area.
    private var shouldUseSliderOnlyPlotArea: Bool {
        let hasNonEmptyPane = visiblePlotPanes.contains { !$0.columns.isEmpty }
        let hasOverlayContent = !rpcSliders.isEmpty || activeCaptureRPC != nil
        return hasOverlayContent && !hasNonEmptyPane
    }

    private var visiblePlotPanes: [PlotPaneSelection] {
#if os(macOS)
        let detachedPaneIDs = Set(plotPopoutControllers.keys)
        return bridge.plotPanes.filter { !detachedPaneIDs.contains($0.id) }
#else
        return bridge.plotPanes
#endif
    }

    private var stackedPlots: some View {
        GeometryReader { geometry in
            let panes = visiblePlotPanes
            let paneCount = max(1, panes.count)
            let axisInsets = paneAxisInsets(for: panes)
            let totalAxisInset = axisInsets.reduce(0, +)
            let graphFrameHeight = max(1, (geometry.size.height - totalAxisInset) / CGFloat(paneCount))
            let rightAxisReservationCount = sharedRightAxisReservationCount(for: panes)

            VStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                    plotPane(
                        pane,
                        index: index,
                        paneCount: panes.count,
                        paneHeight: graphFrameHeight + axisInsets[index],
                        rightAxisReservationCount: rightAxisReservationCount
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private func plotPane(
        _ pane: PlotPaneSelection,
        index: Int,
        paneCount: Int,
        paneHeight: CGFloat,
        rightAxisReservationCount: Int
    ) -> some View {
        ZStack(alignment: .top) {
            GeometryReader { geometry in
                let leadingBleed = graphLeadingBleed(
                    forDetailMinX: geometry.frame(in: .named(Self.splitViewCoordinateSpaceName)).minX
                )
                let safeInsets = geometry.safeAreaInsets
                let canvasWidth = geometry.size.width + leadingBleed
                let legendSafeInsets = EdgeInsets(
                    top: safeInsets.top,
                    leading: max(safeInsets.leading, leadingBleed),
                    bottom: safeInsets.bottom,
                    trailing: safeInsets.trailing
                )

                PlotCanvasFrameHost(
                    frames: bridge.plotFrames,
                    pane: pane,
                    independentVerticalAxisMode: effectiveVerticalAxisMode(for: pane.id),
                    showsIndependentAxisLabels: showsIndependentAxisLabels(for: pane.id),
                    windowSeconds: bridge.displayedWindowSeconds(for: pane),
                    recordingStartSeconds: bridge.plotTimeOriginSeconds,
                    fftLogX: pane.viewConfig.fftLogX,
                    fftLogY: pane.viewConfig.fftLogY,
                    showKey: showPlotKey,
                    showsTimeseriesXAxisLabels: index == paneCount - 1,
                    topPlotInset: topPlotInset(for: pane, index: index),
                    rightAxisReservationCount: rightAxisReservationCount,
                    legendSafeAreaInsets: legendSafeInsets,
                    onPlotWidthChange: index == 0 ? bridge.setPlotWidthPixels : { _ in },
                    onCopyViewData: { bridge.copyCurrentViewDataToClipboard(paneID: pane.id) },
                    onTimeseriesPan: { deltaSeconds in
                        bridge.panTimeseriesViewport(by: deltaSeconds)
                    },
                    onTimeseriesZoom: { scale, anchorFraction in
                        bridge.zoomTimeseriesWindow(by: scale, anchorFraction: anchorFraction)
                    },
                    onPlotColumnsDropped: { payload in
                        bridge.dropPlotColumns(payload, into: pane.id)
                    }
                )
                .frame(width: canvasWidth, height: geometry.size.height)
                .offset(x: -leadingBleed)
            }

            if effectiveShowPlotControls {
                GeometryReader { geometry in
                    FadingGraphControlPane(alwaysVisible: shouldAlwaysShowPlotControls) {
                        plotControlSection(for: pane)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, max(0, topPlotInset(for: pane, index: index)) + 6)
                    .padding(.trailing, plotControlTrailingInset(
                        for: pane,
                        size: geometry.size,
                        rightAxisReservationCount: rightAxisReservationCount
                    ))
                }
                .zIndex(1)
            }
        }
        .frame(height: paneHeight)
    }

    private func graphLeadingBleed(forDetailMinX detailMinX: CGFloat) -> CGFloat {
        guard detailMinX.isFinite else {
            return effectiveShowStreamSidebar ? CGFloat(clampedStreamSidebarWidth) : 0
        }

        let liveLeadingInset = max(0, detailMinX)
        return liveLeadingInset < 0.5 ? 0 : liveLeadingInset
    }

    private func effectiveVerticalAxisMode(for paneID: Int) -> VerticalAxisMode {
        verticalAxisModes[paneID, default: .independent]
    }

    private func showsIndependentAxisLabels(for paneID: Int) -> Bool {
        independentAxisLabelVisibility[paneID] ?? false
    }

    private func canvasVerticalAxisMode(for pane: PlotPaneSelection) -> VerticalAxisMode {
        bridge.plotMode(for: pane) == .fft ? .shared : effectiveVerticalAxisMode(for: pane.id)
    }

    private func canvasShowsIndependentAxisLabels(for pane: PlotPaneSelection) -> Bool {
        bridge.plotMode(for: pane) == .fft ? false : showsIndependentAxisLabels(for: pane.id)
    }

    private func plotControlTrailingInset(
        for pane: PlotPaneSelection,
        size: CGSize,
        rightAxisReservationCount: Int
    ) -> CGFloat {
        PlotCanvas.rightAxisInset(
            size: size,
            verticalAxisMode: canvasVerticalAxisMode(for: pane),
            seriesCount: bridge.plotSeries(for: pane).count,
            rightAxisReservationCount: rightAxisReservationCount,
            showsIndependentAxisLabels: canvasShowsIndependentAxisLabels(for: pane)
        ) + 6
    }

    private func sharedRightAxisReservationCount(for panes: [PlotPaneSelection]) -> Int {
        panes
            .map { pane in
                let seriesCount = bridge.plotSeries(for: pane).count
                let usesIndependentAxes = canvasVerticalAxisMode(for: pane) == .independent
                let showsAxisLabels = canvasShowsIndependentAxisLabels(for: pane)
                return usesIndependentAxes && showsAxisLabels && seriesCount > 1 ? seriesCount : 0
            }
            .max() ?? 0
    }

    private func paneAxisInsets(for panes: [PlotPaneSelection]) -> [CGFloat] {
        panes.enumerated().map { index, pane in
            PlotCanvas.bottomAxisInset(
                showsXAxisLabels: showsXAxisLabels(for: pane, index: index, paneCount: panes.count),
                mode: bridge.plotMode(for: pane),
                recordingStartSeconds: bridge.plotTimeOriginSeconds
            )
        }
    }

    private func showsXAxisLabels(for pane: PlotPaneSelection, index: Int, paneCount: Int) -> Bool {
        bridge.plotMode(for: pane) == .fft || index == paneCount - 1
    }

    private func topPlotInset(for pane: PlotPaneSelection, index: Int) -> CGFloat {
        bridge.plotMode(for: pane) == .fft && index > 0 ? 6 : 0
    }

    private func canMovePlotPane(_ pane: PlotPaneSelection, by offset: Int) -> Bool {
        guard let index = bridge.plotPanes.firstIndex(where: { $0.id == pane.id }) else {
            return false
        }
        let targetIndex = index + offset
        return targetIndex >= 0 && targetIndex < bridge.plotPanes.count
    }

    private func plotOpenWindowAction(for pane: PlotPaneSelection) -> (() -> Void)? {
#if os(macOS)
        return {
            popOutPlot(pane)
        }
#else
        return nil
#endif
    }

    private func plotControlSection(for pane: PlotPaneSelection) -> some View {
        HStack(spacing: 6) {
            let isFFT = bridge.viewConfig(for: pane.id).mode == .fft
            let isOffset = effectiveVerticalAxisMode(for: pane.id) == .independent
            let showsAxisLabels = showsIndependentAxisLabels(for: pane.id)
            let fftLogX = pane.viewConfig.fftLogX
            let fftLogY = pane.viewConfig.fftLogY

            if !isFFT {
                GraphControlToggleButton(
                    title: "Offset",
                    icon: .offset,
                    isOn: isOffset,
                    action: {
                        verticalAxisModes[pane.id] = isOffset ? .shared : .independent
                    }
                )

                GraphControlToggleButton(
                    title: "Labels",
                    icon: .labels,
                    isOn: showsAxisLabels,
                    action: {
                        independentAxisLabelVisibility[pane.id] = !showsAxisLabels
                    }
                )
            } else {
                GraphControlToggleButton(
                    title: "Log X",
                    icon: .logX,
                    isOn: fftLogX,
                    action: {
                        bridge.setFFTLogX(!fftLogX, for: pane.id)
                    }
                )

                GraphControlToggleButton(
                    title: "Log Y",
                    icon: .logY,
                    isOn: fftLogY,
                    action: {
                        bridge.setFFTLogY(!fftLogY, for: pane.id)
                    }
                )
            }

            GraphControlToggleButton(
                title: "FFT",
                icon: .fft,
                isOn: isFFT,
                action: {
                    bridge.setViewMode(isFFT ? .timeseries : .fft, for: pane.id)
                }
            )

#if os(macOS)
            GraphControlActionButton(
                title: "Window",
                systemImage: "arrow.up.right.square",
                action: {
                    popOutPlot(pane)
                }
            )
#endif

            GraphRailGripMenu(
                title: "Plot",
                canMoveUp: canMovePlotPane(pane, by: -1),
                canMoveDown: canMovePlotPane(pane, by: 1),
                onMoveUp: {
                    bridge.movePlotPane(id: pane.id, by: -1)
                },
                onMoveDown: {
                    bridge.movePlotPane(id: pane.id, by: 1)
                },
                onOpenWindow: plotOpenWindowAction(for: pane)
            )

            Divider()
                .frame(height: 22)

            plotCloseButton(for: pane)
        }
        .padding(6)
    }

    private func plotCloseButton(for pane: PlotPaneSelection) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
#if os(macOS)
                closePlotPopout(id: pane.id)
#endif
                independentAxisLabelVisibility[pane.id] = nil
                verticalAxisModes[pane.id] = nil
                bridge.removePlotPane(id: pane.id)
            }
        } label: {
            Image(systemName: "xmark.circle")
                .font(.body)
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.secondary)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help("Close plot")
        .accessibilityLabel("Close plot")
    }

#if os(macOS)
    private func popOutPlot(_ pane: PlotPaneSelection) {
        if let controller = plotPopoutControllers[pane.id],
           let window = controller.window {
            window.title = popoutTitle(for: pane)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let paneID = pane.id
        let controller = PlotPopoutWindowController(
            title: popoutTitle(for: pane),
            rootView: PlotPopoutWindowView(
                bridge: bridge,
                paneID: paneID,
                verticalAxisModes: $verticalAxisModes,
                independentAxisLabelVisibility: $independentAxisLabelVisibility
            )
        )
        controller.onClose = {
            plotPopoutControllers[paneID] = nil
        }
        plotPopoutControllers[paneID] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func popOutNewPlot(columns keys: [ColumnKey]) {
        guard let paneID = bridge.addPlotPane(columns: keys),
              let pane = bridge.plotPanes.first(where: { $0.id == paneID }) else {
            return
        }
        popOutPlot(pane)
    }

    private func popOutSlider(for rpc: RpcInfo) {
        if let existingSlider = rpcSliders.first(where: { $0.id == rpc.id }) {
            popOutSlider(existingSlider)
            return
        }

        let maximumRPC = bridge.rpc(route: rpc.route, name: "\(rpc.name).max")
        if let maximumRPC, maximumRPC.readable {
            bridge.callRpc(maximumRPC)
        }
        popOutSlider(sliderConfiguration(for: rpc, maximumRPC: maximumRPC))
    }

    private func popOutSlider(_ slider: RPCSliderConfiguration) {
        if let controller = sliderPopoutControllers[slider.id],
           let window = controller.window {
            window.title = sliderPopoutTitle(for: slider)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let sliderID = slider.id
        let controller = PlotPopoutWindowController(
            title: sliderPopoutTitle(for: slider),
            rootView: SliderPopoutWindowView(bridge: bridge, initialSlider: slider)
        )
        controller.onClose = {
            sliderPopoutControllers[sliderID] = nil
        }
        sliderPopoutControllers[sliderID] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func popOutCapture(_ rpc: RpcInfo) {
        if let controller = capturePopoutControllers[rpc.id],
           let window = controller.window {
            window.title = capturePopoutTitle(for: rpc)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rpcID = rpc.id
        let controller = PlotPopoutWindowController(
            title: capturePopoutTitle(for: rpc),
            rootView: CapturePopoutWindowView(bridge: bridge, rpcID: rpcID)
        )
        controller.onClose = {
            capturePopoutControllers[rpcID] = nil
        }
        capturePopoutControllers[rpcID] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func sliderPopoutTitle(for slider: RPCSliderConfiguration) -> String {
        slider.name
    }

    private func capturePopoutTitle(for rpc: RpcInfo) -> String {
        "\(rpc.route) \(rpc.name)"
    }

    private func popoutTitle(for pane: PlotPaneSelection) -> String {
        let labels = bridge.plotSeries(for: pane)
            .map(\.label)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let firstLabel = labels.first else {
            return pane.title
        }
        if labels.count == 1 {
            return firstLabel
        }
        return "\(firstLabel) + \(labels.count - 1)"
    }

    private func closePlotPopouts(missingFrom activePaneIDs: Set<Int>) {
        let stalePaneIDs = plotPopoutControllers.keys.filter { !activePaneIDs.contains($0) }
        for paneID in stalePaneIDs {
            closePlotPopout(id: paneID)
        }
    }

    private func closePlotPopout(id paneID: Int) {
        guard let controller = plotPopoutControllers.removeValue(forKey: paneID) else { return }
        controller.onClose = nil
        controller.close()
    }

    private func closeCapturePopouts(missingFrom activeRPCIDs: Set<String>) {
        let staleRPCIDs = capturePopoutControllers.keys.filter { !activeRPCIDs.contains($0) }
        for rpcID in staleRPCIDs {
            closeCapturePopout(id: rpcID)
        }
    }

    private func closeCapturePopout(id rpcID: String) {
        guard let controller = capturePopoutControllers.removeValue(forKey: rpcID) else { return }
        controller.onClose = nil
        controller.close()
    }

    private func closeSliderPopouts(missingFrom activeRPCIDs: Set<String>) {
        let staleRPCIDs = sliderPopoutControllers.keys.filter { !activeRPCIDs.contains($0) }
        for rpcID in staleRPCIDs {
            closeSliderPopout(id: rpcID)
        }
    }

    private func closeSliderPopout(id rpcID: String) {
        guard let controller = sliderPopoutControllers.removeValue(forKey: rpcID) else { return }
        controller.onClose = nil
        controller.close()
    }

    private func closeAllPlotPopouts() {
        for paneID in Array(plotPopoutControllers.keys) {
            closePlotPopout(id: paneID)
        }
    }

    private func closeAllAuxiliaryPopouts() {
        for rpcID in Array(capturePopoutControllers.keys) {
            closeCapturePopout(id: rpcID)
        }
        for rpcID in Array(sliderPopoutControllers.keys) {
            closeSliderPopout(id: rpcID)
        }
    }
#endif

    private var shouldConnectButtonDisconnect: Bool {
        guard !bridge.isInspectionMode else { return false }
        return [
            "connecting",
            "connected",
            "discovering",
            "metadata",
            "logging",
            "streaming"
        ].contains(bridge.statusState)
    }

    private func activateConnectionButton() {
        if shouldConnectButtonDisconnect {
            bridge.disconnect()
        } else {
            bridge.listDevices(includeAllSerial: showAllSerialPorts)
            showingDevicePicker = true
        }
    }

    private func setDataLoggingEnabled(_ enabled: Bool) {
        guard canControlDataLogging else {
            isDataLoggingEnabled = false
            return
        }
        guard enabled != isDataLoggingEnabled else { return }

        isDataLoggingEnabled = enabled
        if enabled {
            document.ensureTemporaryLogFile()
            bridge.setLogging(enabled: true, logURL: document.temporaryLogURL)
            bridge.reloadAllRPCs()
        } else {
            bridge.setLogging(enabled: false, logURL: nil)
            // Stopping a recording must not throw the recording away: the log
            // *is* the document's data, so "record, stop, save" has to keep it.
            // Only discard the log when nothing was captured, which is what
            // this cleanup was for — it keeps an untouched document from going
            // dirty and leaving a 0-byte .tio behind.
            if document.temporaryLogIsEmpty {
                document.removeTemporaryLogFile()
                clearDocumentEditedRequest &+= 1
            }
        }
    }

    private var showHealthToolbarButton: Bool {
        !bridge.streamHealth.isEmpty
    }

    private var showUpgradeToolbarButton: Bool {
        !bridge.isInspectionMode
            && (!bridge.availableUpgrades.isEmpty || bridge.upgradeProgress != nil)
    }

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            if showUpgradeToolbarButton {
                Button {
                    showingUpgradePopover = true
                } label: {
                    Label("Firmware Update", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.green)
                }
                .help("Firmware update available")
                .popover(isPresented: $showingUpgradePopover, arrowEdge: .bottom) {
                    FirmwareUpgradePopover(bridge: bridge)
                }
            }

            if showHealthToolbarButton {
                Button {
                    showingHealthPopover = true
                } label: {
                    Label("Device Health", systemImage: "info.circle")
                }
                .labelStyle(.iconOnly)
                .help("Device timing and rate diagnostics")
                .popover(isPresented: $showingHealthPopover, arrowEdge: .bottom) {
                    DeviceHealthPopover(bridge: bridge)
                }
            }

            Button {
                bridge.addPlotPane()
            } label: {
                Label("Add Graph", systemImage: "plus")
            }
            .labelStyle(.iconOnly)
            .disabled(!bridge.canAddPlotPane)
            .help(bridge.canAddPlotPane
                ? "Add another graph"
                : "Maximum of \(BridgeClient.maxPlotPaneCount) graphs")

            Button {
                bridge.togglePlotPaused()
            } label: {
                Label(
                    bridge.isPlotPaused ? "Resume" : "Pause",
                    systemImage: bridge.isPlotPaused ? "play.fill" : "pause.fill"
                )
            }
            .labelStyle(.iconOnly)
            .disabled(bridge.isInspectionMode)
            .help(bridge.isInspectionMode
                ? "Inspecting a saved log"
                : (bridge.isPlotPaused ? "Resume live plot updates" : "Pause plot updates"))

            Toggle(isOn: dataLoggingEnabledBinding) {
                Label {
                    Text("Log Data")
                } icon: {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(isDataLoggingEnabled ? Color.primary : Color.secondary)
                }
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .disabled(!canControlDataLogging)
            .help(isDataLoggingEnabled ? "Stop data logging" : "Start data logging")

            Button {
                activateConnectionButton()
            } label: {
                Label("Connect", systemImage: "cable.connector")
            }
            .labelStyle(.iconOnly)
            .disabled(bridge.isInspectionMode)
            .help(shouldConnectButtonDisconnect ? "Disconnect from the current device" : "Connect to a Twinleaf device")

            Button {
                showingPlotSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .labelStyle(.iconOnly)
            .help("Show settings")
        }

        ToolbarItemGroup(placement: .automatic) {
            Toggle(isOn: logInspectorSelectionBinding) {
                Label("Log", systemImage: "text.alignleft")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(effectiveShowLogPanel ? "Hide log slide-over" : "Show log slide-over")
            .accessibilityValue(effectiveShowLogPanel ? "Selected" : "Not selected")
        }
    }

#if os(iOS)
    @ToolbarContentBuilder
    private var iosDocumentToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                ShareLink(item: documentShareURL) {
                    Label("Share Log", systemImage: "square.and.arrow.up")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(documentDisplayName)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .help("Document actions")
        }
    }
#endif

    private var playbackScrubber: some View {
        HStack(spacing: 8) {
            Image(systemName: "backward.end")
                .foregroundStyle(.secondary)
            if bridge.canScrubPlayback {
                Slider(
                    value: Binding(
                        get: { bridge.playbackPosition },
                        set: { bridge.setPlaybackPosition($0) }
                    ),
                    in: bridge.playbackSliderRange
                )
            } else {
                Slider(value: .constant(0), in: 0...1)
                    .disabled(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .help("Scrub through the loaded log")
    }

    private var smokeThresholdBytes: UInt64 {
        UInt64(max(1, smokeThresholdMegabytes) * 1_000_000)
    }

    private var shouldShowSmoke: Bool {
        bridge.logBytes >= smokeThresholdBytes
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(fileURL?.lastPathComponent ?? "Untitled .tio")
                .font(.caption)
                .foregroundStyle(.secondary)
            if fileURL == nil {
                Label("Temporary log", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if bridge.isInspectionMode {
                Label("Inspection", systemImage: "pause.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Label(formatFileSize(bridge.logBytes), systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(shouldShowSmoke ? .orange : .secondary)
                .help("Current .tio log size")
            if let elapsedSeconds = bridge.logElapsedSeconds {
                Label(formatPlaybackTime(elapsedSeconds), systemImage: "timer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Elapsed time covered by the logged data")
            }
            if let startSeconds = bridge.logTimeReferenceStartSeconds {
                Label(formatRecordingStartDate(startSeconds), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Time reference at the beginning of the logged data")
            }
            Text(bridge.status)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(bridge.statusState == "error" ? .red : .secondary)
                .help("Connection status")
            Spacer()
            if bridge.isPlotPaused {
                Label("Paused", systemImage: "pause.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let latestLogMessage = bridge.latestLogMessage {
                Text("\(latestLogMessage.route) \(latestLogMessage.message)")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360, alignment: .trailing)
                    .help(logMessageHelp(latestLogMessage))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

#if os(macOS)
private final class PlotPopoutWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init<Content: View>(title: String, rootView: Content) {
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
#endif

private struct PlotPopoutWindowView: View {
    @ObservedObject var bridge: BridgeClient
    let paneID: Int
    @Binding var verticalAxisModes: [Int: VerticalAxisMode]
    @Binding var independentAxisLabelVisibility: [Int: Bool]
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ViewPreferenceKeys.theme) private var themeRaw = ThemePreference.system.rawValue
    @AppStorage(ViewPreferenceKeys.showPlotKey) private var showPlotKey = true
    private static let graphMargin: CGFloat = 36

    var body: some View {
        ZStack {
            TwinleafSurfaceColors.canvasBackgroundColor(for: effectiveColorScheme)
                .ignoresSafeArea()

            GeometryReader { geometry in
                if let pane = bridge.plotPanes.first(where: { $0.id == paneID }) {
                    plotPane(pane, in: geometry)
                } else {
                    ContentUnavailableView(
                        "Plot Closed",
                        systemImage: "chart.xyaxis.line",
                        description: Text("This plot is no longer available.")
                    )
                }
            }
            .padding(Self.graphMargin)
        }
        .frame(minWidth: 520, minHeight: 360)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(themePreference.preferredColorScheme)
    }

    private func plotPane(_ pane: PlotPaneSelection, in geometry: GeometryProxy) -> some View {
        let series = bridge.plotSeries(for: pane)
        let mode = bridge.plotMode(for: pane)
        let rightAxisReservationCount = rightAxisReservationCount(for: series, pane: pane, mode: mode)

        return ZStack(alignment: .top) {
            PlotCanvasFrameHost(
                frames: bridge.plotFrames,
                pane: pane,
                independentVerticalAxisMode: verticalAxisModes[pane.id, default: .independent],
                showsIndependentAxisLabels: independentAxisLabelVisibility[pane.id, default: false],
                windowSeconds: bridge.displayedWindowSeconds(for: pane),
                recordingStartSeconds: bridge.plotTimeOriginSeconds,
                fftLogX: pane.viewConfig.fftLogX,
                fftLogY: pane.viewConfig.fftLogY,
                showKey: showPlotKey,
                showsTimeseriesXAxisLabels: true,
                rightAxisReservationCount: rightAxisReservationCount,
                legendSafeAreaInsets: geometry.safeAreaInsets,
                onPlotWidthChange: bridge.setPlotWidthPixels,
                onCopyViewData: { bridge.copyCurrentViewDataToClipboard(paneID: pane.id) },
                onTimeseriesPan: { deltaSeconds in
                    bridge.panTimeseriesViewport(by: deltaSeconds)
                },
                onTimeseriesZoom: { scale, anchorFraction in
                    bridge.zoomTimeseriesWindow(by: scale, anchorFraction: anchorFraction)
                },
                onPlotColumnsDropped: { payload in
                    bridge.dropPlotColumns(payload, into: pane.id)
                }
            )

            GeometryReader { controlGeometry in
                FadingGraphControlPane(alwaysVisible: false) {
                    plotControlSection(for: pane)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 6)
                .padding(.trailing, plotControlTrailingInset(
                    for: pane,
                    size: controlGeometry.size,
                    rightAxisReservationCount: rightAxisReservationCount
                ))
            }
            .zIndex(1)
        }
    }

    private var themePreference: ThemePreference {
        ThemePreference(rawValue: themeRaw) ?? .system
    }

    private var effectiveColorScheme: ColorScheme {
        themePreference.preferredColorScheme ?? colorScheme
    }

    private func canvasVerticalAxisMode(for pane: PlotPaneSelection, mode: PlotMode) -> VerticalAxisMode {
        mode == .fft ? .shared : verticalAxisModes[pane.id, default: .independent]
    }

    private func canvasShowsIndependentAxisLabels(for pane: PlotPaneSelection, mode: PlotMode) -> Bool {
        mode == .fft ? false : independentAxisLabelVisibility[pane.id, default: false]
    }

    private func rightAxisReservationCount(
        for series: [PlotSeries],
        pane: PlotPaneSelection,
        mode: PlotMode
    ) -> Int {
        let usesIndependentAxes = canvasVerticalAxisMode(for: pane, mode: mode) == .independent
        let showsAxisLabels = canvasShowsIndependentAxisLabels(for: pane, mode: mode)
        return usesIndependentAxes && showsAxisLabels && series.count > 1 ? series.count : 0
    }

    private func plotControlTrailingInset(
        for pane: PlotPaneSelection,
        size: CGSize,
        rightAxisReservationCount: Int
    ) -> CGFloat {
        PlotCanvas.rightAxisInset(
            size: size,
            verticalAxisMode: canvasVerticalAxisMode(for: pane, mode: bridge.plotMode(for: pane)),
            seriesCount: bridge.plotSeries(for: pane).count,
            rightAxisReservationCount: rightAxisReservationCount,
            showsIndependentAxisLabels: canvasShowsIndependentAxisLabels(for: pane, mode: bridge.plotMode(for: pane))
        ) + 6
    }

    private func canMovePlotPane(_ pane: PlotPaneSelection, by offset: Int) -> Bool {
        guard let index = bridge.plotPanes.firstIndex(where: { $0.id == pane.id }) else {
            return false
        }
        let targetIndex = index + offset
        return targetIndex >= 0 && targetIndex < bridge.plotPanes.count
    }

    private func plotControlSection(for pane: PlotPaneSelection) -> some View {
        HStack(spacing: 6) {
            let isFFT = bridge.viewConfig(for: pane.id).mode == .fft
            let isOffset = verticalAxisModes[pane.id, default: .independent] == .independent
            let showsAxisLabels = independentAxisLabelVisibility[pane.id] ?? false
            let fftLogX = pane.viewConfig.fftLogX
            let fftLogY = pane.viewConfig.fftLogY

            if !isFFT {
                GraphControlToggleButton(
                    title: "Offset",
                    icon: .offset,
                    isOn: isOffset,
                    action: {
                        verticalAxisModes[pane.id] = isOffset ? .shared : .independent
                    }
                )

                GraphControlToggleButton(
                    title: "Labels",
                    icon: .labels,
                    isOn: showsAxisLabels,
                    action: {
                        independentAxisLabelVisibility[pane.id] = !showsAxisLabels
                    }
                )
            } else {
                GraphControlToggleButton(
                    title: "Log X",
                    icon: .logX,
                    isOn: fftLogX,
                    action: {
                        bridge.setFFTLogX(!fftLogX, for: pane.id)
                    }
                )

                GraphControlToggleButton(
                    title: "Log Y",
                    icon: .logY,
                    isOn: fftLogY,
                    action: {
                        bridge.setFFTLogY(!fftLogY, for: pane.id)
                    }
                )
            }

            GraphControlToggleButton(
                title: "FFT",
                icon: .fft,
                isOn: isFFT,
                action: {
                    bridge.setViewMode(isFFT ? .timeseries : .fft, for: pane.id)
                }
            )

            GraphRailGripMenu(
                title: "Plot",
                canMoveUp: canMovePlotPane(pane, by: -1),
                canMoveDown: canMovePlotPane(pane, by: 1),
                onMoveUp: {
                    bridge.movePlotPane(id: pane.id, by: -1)
                },
                onMoveDown: {
                    bridge.movePlotPane(id: pane.id, by: 1)
                },
                onOpenWindow: nil
            )

            Divider()
                .frame(height: 22)

            plotCloseButton(for: pane)
        }
        .padding(6)
    }

    private func plotCloseButton(for pane: PlotPaneSelection) -> some View {
        Button {
            independentAxisLabelVisibility[pane.id] = nil
            verticalAxisModes[pane.id] = nil
            bridge.removePlotPane(id: pane.id)
        } label: {
            Image(systemName: "xmark.circle")
                .font(.body)
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.secondary)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help("Close plot")
        .accessibilityLabel("Close plot")
    }
}

#if os(iOS)
/// Host view for an iPad pop-out plot scene. Resolves the parent document's
/// bridge from `BridgeSessionRegistry` using the descriptor's `sessionID`, then
/// renders the same `PlotPopoutWindowView` the macOS popout window uses. The
/// axis-mode bindings are local to this scene — each popout customizes its own
/// axes independently of the parent document.
struct IPadPlotPopoutScene: View {
    let descriptor: PlotPopoutDescriptor
    @State private var verticalAxisModes: [Int: VerticalAxisMode] = [:]
    @State private var independentAxisLabelVisibility: [Int: Bool] = [:]

    var body: some View {
        if let bridge = BridgeSessionRegistry.shared.bridge(for: descriptor.sessionID) {
            PlotPopoutWindowView(
                bridge: bridge,
                paneID: descriptor.paneID,
                verticalAxisModes: $verticalAxisModes,
                independentAxisLabelVisibility: $independentAxisLabelVisibility
            )
            .navigationTitle(plotTitle(bridge: bridge))
        } else {
            ContentUnavailableView(
                "Plot Unavailable",
                systemImage: "chart.xyaxis.line",
                description: Text("The original document is no longer open.")
            )
        }
    }

    private func plotTitle(bridge: BridgeClient) -> String {
        guard let pane = bridge.plotPanes.first(where: { $0.id == descriptor.paneID }) else {
            return "Plot"
        }
        let labels = bridge.plotSeries(for: pane)
            .map(\.label)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = labels.first else { return pane.title }
        return labels.count == 1 ? first : "\(first) + \(labels.count - 1)"
    }
}
#endif

#if os(macOS)
private struct CapturePopoutWindowView: View {
    @ObservedObject var bridge: BridgeClient
    let rpcID: String
    @State private var isAutoEnabled = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ViewPreferenceKeys.theme) private var themeRaw = ThemePreference.system.rawValue
    private static let graphMargin: CGFloat = 36

    var body: some View {
        ZStack {
            TwinleafSurfaceColors.canvasBackgroundColor(for: effectiveColorScheme)
                .ignoresSafeArea()

            CaptureResultPane(
                bridge: bridge,
                rpcID: rpcID,
                isAutoEnabled: $isAutoEnabled,
                alwaysShowsRail: false,
                maximumHeight: .infinity,
                onTrigger: { rpc in
                    bridge.callRpc(rpc, optimisticallyUpdate: false)
                },
                onPopOut: nil,
                onClose: nil
            )
            .padding(Self.graphMargin)
        }
        .frame(minWidth: 520, minHeight: 360)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(themePreference.preferredColorScheme)
    }

    private var themePreference: ThemePreference {
        ThemePreference(rawValue: themeRaw) ?? .system
    }

    private var effectiveColorScheme: ColorScheme {
        themePreference.preferredColorScheme ?? colorScheme
    }
}

private struct SliderPopoutWindowView: View {
    @ObservedObject var bridge: BridgeClient
    @State private var slider: RPCSliderConfiguration
    @FocusState private var focusedField: RpcFocusField?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ViewPreferenceKeys.theme) private var themeRaw = ThemePreference.system.rawValue
    private static let contentMargin: CGFloat = 36

    init(bridge: BridgeClient, initialSlider: RPCSliderConfiguration) {
        self.bridge = bridge
        _slider = State(initialValue: initialSlider)
    }

    var body: some View {
        ZStack {
            TwinleafSurfaceColors.canvasBackgroundColor(for: effectiveColorScheme)
                .ignoresSafeArea()

            RPCSliderControlRow(
                bridge: bridge,
                slider: $slider,
                onRemove: nil,
                onOpenWindow: nil,
                focusedField: $focusedField
            )
            .padding(Self.contentMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(minWidth: 360, minHeight: 180)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(themePreference.preferredColorScheme)
    }

    private var themePreference: ThemePreference {
        ThemePreference(rawValue: themeRaw) ?? .system
    }

    private var effectiveColorScheme: ColorScheme {
        themePreference.preferredColorScheme ?? colorScheme
    }
}
#endif

private struct ExportDestinationDocument: FileDocument {
    static var readableContentTypes: [UTType] { ExportFormat.allCases.map(\.contentType) }
    static var writableContentTypes: [UTType] { ExportFormat.allCases.map(\.contentType) }

    init() {}

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}

#if os(iOS)
/// Hides the system back button only on regular size classes (iPad split view,
/// large iPhones in landscape). On compact (iPhone portrait), keep the back
/// button so users can return from the plot detail to the streams sidebar.
private struct SizeClassAwareBackButtonHidden: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        content.navigationBarBackButtonHidden(horizontalSizeClass == .regular)
    }
}

/// Toolbar leading-edge button on iPhone compact that switches
/// `NavigationSplitView` back to the sidebar column. Renders empty on regular
/// size classes (iPad) where both columns are already visible.
private struct CompactSidebarToggleButton: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var preferredCompactColumn: Binding<NavigationSplitViewColumn>

    var body: some View {
        if horizontalSizeClass == .compact {
            Button {
                preferredCompactColumn.wrappedValue = .sidebar
            } label: {
                Label("Streams", systemImage: "sidebar.left")
            }
            .accessibilityLabel("Back to streams")
            .help("Back to streams")
        }
    }
}
#endif

private extension View {
    @ViewBuilder
    func twinleafDocumentNavigationTitle(_ title: String) -> some View {
#if os(macOS)
        navigationTitle(title)
#else
        self
#endif
    }

    @ViewBuilder
    func twinleafWindowToolbarVisibility(_ isVisible: Bool) -> some View {
#if os(macOS)
        toolbar(isVisible ? .visible : .hidden, for: .windowToolbar)
#else
        self
#endif
    }

    @ViewBuilder
    func twinleafDocumentMinimumFrame() -> some View {
        // Pin a minimum window size on macOS so the layout stays usable when
        // the user drags the resize handle in. On iOS the device screen is the
        // upper bound, not the lower — a 360×640 floor overflows iPhone in
        // landscape (~375pt tall) — so let SwiftUI use the available size.
#if os(macOS)
        frame(minWidth: SidebarLayout.compactWindowMinimumWidth, minHeight: 640)
#else
        self
#endif
    }

    @ViewBuilder
    func twinleafIOSNavigationBackButtonHidden() -> some View {
#if os(iOS)
        modifier(SizeClassAwareBackButtonHidden())
#else
        self
#endif
    }

    @ViewBuilder
    func twinleafCheckboxToggleStyle() -> some View {
#if os(macOS)
        toggleStyle(.checkbox)
#else
        self
#endif
    }

    @ViewBuilder
    func plotColumnDragSource(keys: [ColumnKey], sourcePaneID: Int? = nil) -> some View {
        if keys.isEmpty {
            self
        } else {
            onDrag {
                PlotColumnDragPayload(keys: keys, sourcePaneID: sourcePaneID).itemProvider
            }
        }
    }

    @ViewBuilder
    func twinleafOnExitCommand(_ action: @escaping () -> Void) -> some View {
#if os(macOS)
        onExitCommand(perform: action)
#else
        self
#endif
    }

    @ViewBuilder
    func twinleafSettingsWindowFrame() -> some View {
#if os(iOS)
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
#else
        frame(width: 480)
            .frame(minHeight: 520)
#endif
    }

    @ViewBuilder
    func twinleafSettingsPresentation() -> some View {
#if os(iOS)
        presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
#else
        self
#endif
    }

    @ViewBuilder
    func twinleafDevicePickerFrame(isConnectionProgressVisible: Bool) -> some View {
#if os(iOS)
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
#else
        // Fixed width, but grow vertically with the window. The overlay adds a
        // margin so the panel stops short of the window edges; the device list
        // inside absorbs the extra height.
        frame(width: 520)
            .frame(minHeight: isConnectionProgressVisible ? 460 : 360, maxHeight: .infinity)
#endif
    }

    @ViewBuilder
    func twinleafDevicePickerPresentation() -> some View {
#if os(iOS)
        modifier(DevicePickerSheetPresentationModifier())
#else
        self
#endif
    }

    @ViewBuilder
    func twinleafDeviceURLTextInput() -> some View {
#if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
#else
        autocorrectionDisabled(true)
#endif
    }

    @ViewBuilder
    func twinleafDevicePickerButtonStyle(_ prominence: DevicePickerButtonProminence = .standard) -> some View {
#if os(iOS)
        buttonStyle(DevicePickerGlassButtonStyle(prominence))
#else
        self
#endif
    }

    @ViewBuilder
    func twinleafDevicePickerHeaderIconButtonStyle() -> some View {
#if os(iOS)
        labelStyle(.iconOnly)
            .twinleafDevicePickerButtonStyle(.icon)
#else
        labelStyle(.iconOnly)
            .frame(width: 28, height: 28)
#endif
    }

    @ViewBuilder
    func twinleafDevicePickerInlineRowStyle() -> some View {
#if os(iOS)
        contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            }
#else
        self
#endif
    }

    @ViewBuilder
    func twinleafDevicePickerRowSelectionStyle(isSelected: Bool) -> some View {
#if os(iOS)
        contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
#else
        contentShape(Rectangle())
#endif
    }
}

#if os(iOS)
private struct DevicePickerSheetPresentationModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        if horizontalSizeClass == .compact {
            content
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(28)
        } else {
            content
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(28)
        }
    }
}
#endif

private struct WindowFrameAutosaver: View {
    let autosaveName: String
    let colorScheme: ColorScheme
    @Binding var windowObjectID: ObjectIdentifier?

    var body: some View {
#if os(macOS)
        WindowFrameAutosaverBridge(
            autosaveName: autosaveName,
            colorScheme: colorScheme,
            windowObjectID: $windowObjectID
        )
#else
        Color.clear
#endif
    }
}

private struct DocumentEditedStateResetter: View {
    let clearRequest: Int

    var body: some View {
#if os(macOS)
        DocumentEditedStateResetterBridge(clearRequest: clearRequest)
#else
        Color.clear
#endif
    }
}

#if os(macOS)
private struct WindowFrameAutosaverBridge: NSViewRepresentable {
    let autosaveName: String
    let colorScheme: ColorScheme
    @Binding var windowObjectID: ObjectIdentifier?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            applyAutosaveName(from: view, context: context)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            applyAutosaveName(from: view, context: context)
        }
    }

    private func applyAutosaveName(from view: NSView, context: Context) {
        guard let window = view.window else { return }
        let windowID = ObjectIdentifier(window)
        if context.coordinator.reportedWindowID != windowID {
            context.coordinator.reportedWindowID = windowID
            windowObjectID = windowID
        }
        if context.coordinator.restoredWindowIDs.insert(windowID).inserted {
            _ = window.setFrameUsingName(autosaveName)
        }
        _ = window.setFrameAutosaveName(autosaveName)
        applyWindowChromeStyle(to: window)
    }

    private func applyWindowChromeStyle(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = TwinleafSurfaceColors.windowBackgroundColor(for: colorScheme)
        window.titlebarAppearsTransparent = true
    }

    final class Coordinator {
        var restoredWindowIDs: Set<ObjectIdentifier> = []
        var reportedWindowID: ObjectIdentifier?
    }
}

private struct DocumentEditedStateResetterBridge: NSViewRepresentable {
    let clearRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard clearRequest != 0,
              clearRequest != context.coordinator.lastClearRequest else {
            return
        }
        context.coordinator.lastClearRequest = clearRequest
        DispatchQueue.main.async {
            clearEditedState(from: view)
        }
    }

    private func clearEditedState(from view: NSView) {
        guard let window = view.window else { return }
        let document = (window.windowController?.document as? NSDocument)
            ?? NSDocumentController.shared.documents.first { candidate in
                candidate.windowControllers.contains { $0.window === window }
            }
        document?.updateChangeCount(.changeCleared)
    }

    final class Coordinator {
        var lastClearRequest = 0
    }
}
#endif

private struct WindowContentTopInsetReporter: View {
    @Binding var topInset: CGFloat

    var body: some View {
#if os(macOS)
        WindowContentTopInsetReporterBridge(topInset: $topInset)
#else
        Color.clear
            .onAppear {
                topInset = 0
            }
#endif
    }
}

#if os(macOS)
private struct WindowContentTopInsetReporterBridge: NSViewRepresentable {
    @Binding var topInset: CGFloat

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView(frame: .zero)
        view.onTopInsetChange = { inset in
            topInset = inset
        }
        return view
    }

    func updateNSView(_ view: ReporterView, context: Context) {
        view.onTopInsetChange = { inset in
            topInset = inset
        }
        view.scheduleReport()
    }

    final class ReporterView: NSView {
        var onTopInsetChange: ((CGFloat) -> Void)?
        private var lastTopInset: CGFloat = -1

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleReport()
        }

        override func layout() {
            super.layout()
            scheduleReport()
        }

        func scheduleReport() {
            DispatchQueue.main.async { [weak self] in
                self?.report()
            }
        }

        private func report() {
            guard let window else {
                publish(0)
                return
            }

            let contentTop = window.contentView?.frame.maxY ?? 0
            let contentLayoutTopInset = max(0, contentTop - window.contentLayoutRect.maxY)
            let contentViewSafeInset = window.contentView?.safeAreaInsets.top ?? 0
            publish(max(contentLayoutTopInset, contentViewSafeInset))
        }

        private func publish(_ inset: CGFloat) {
            guard abs(inset - lastTopInset) >= 0.5 else { return }
            lastTopInset = inset
            onTopInsetChange?(inset)
        }
    }
}
#endif

enum TwinleafSurfaceColors {
    static let darkCanvasColor = Color(red: 0.012, green: 0.014, blue: 0.018)
    static let lightCanvasColor = Color(red: 0.965, green: 0.965, blue: 0.97)
    static let sidebarBackgroundColor = Color.primary.opacity(0.055)

    static func slideOverBackgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.085, green: 0.087, blue: 0.094)
            : Color(red: 0.955, green: 0.955, blue: 0.96)
    }

    static func canvasBackgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkCanvasColor : lightCanvasColor
    }

#if os(macOS)
    static func windowBackgroundColor(for colorScheme: ColorScheme) -> NSColor {
        if colorScheme == .dark {
            return NSColor(
                srgbRed: 0.012,
                green: 0.014,
                blue: 0.018,
                alpha: 1
            )
        }
        return NSColor.windowBackgroundColor
    }
#endif
}

private extension ThemePreference {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .dark:
            .dark
        case .light:
            .light
        }
    }
}

private enum SidebarLayout {
    static let streamWidthRange: ClosedRange<Double> = 220...420
    static let rpcWidthRange: ClosedRange<Double> = 260...560
    static let defaultStreamWidth = 280.0
    static let defaultRPCWidth = 320.0
    static let detailMinimumWidth: CGFloat = 700
    static let compactWindowMinimumWidth: CGFloat = 360
    static let compactSidebarOnlyMaximumWidth: CGFloat = 500
    static let resizeHandleWidth: CGFloat = 9
    static let fallbackToolbarContentTopInset: CGFloat = 54
}

private enum RPCSliderRateLimit {
    static let defaultHz = 10.0
    static let range: ClosedRange<Double> = 1...120
}

private func clampedRPCSliderRateLimitHz(_ value: Double) -> Double {
    guard value.isFinite else { return RPCSliderRateLimit.defaultHz }
    return clamp(value, to: RPCSliderRateLimit.range)
}

private enum RPCFavorites {
    static func ids(from rawValue: String) -> [String] {
        var seen: Set<String> = []
        return rawValue
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    static func rawValue(from ids: [String]) -> String {
        ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, id in
                if !result.contains(id) {
                    result.append(id)
                }
            }
            .joined(separator: "\n")
    }

    static func defaultID(for rpc: RpcInfo) -> String {
        rpc.name
    }

    static func routeScopedID(for rpc: RpcInfo) -> String {
        rpc.id
    }

    static func contains(_ rpc: RpcInfo, in ids: [String]) -> Bool {
        ids.contains { matches(rpc, id: $0) }
    }

    static func matches(_ rpc: RpcInfo, id: String) -> Bool {
        if id.contains("#") {
            return id == routeScopedID(for: rpc)
        }

        return id == rpc.name
    }

    static func removing(_ rpc: RpcInfo, from ids: [String]) -> [String] {
        ids.filter { !matches(rpc, id: $0) }
    }
}

private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}

private struct StreamSidebarWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct StreamSidebarWidthReporter: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .preference(key: StreamSidebarWidthPreferenceKey.self, value: geometry.size.width)
        }
    }
}

private struct SidebarResizeHandle: View {
    enum DragDirection {
        case leftEdge

        func adjustedWidth(startWidth: Double, translation: CGFloat) -> Double {
            switch self {
            case .leftEdge:
                startWidth - Double(translation)
            }
        }
    }

    @Binding var width: Double
    let range: ClosedRange<Double>
    let dragDirection: DragDirection
    let accessibilityLabel: String

    @State private var dragStartWidth: Double?

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
            Rectangle()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 1)
        }
        .frame(width: SidebarLayout.resizeHandleWidth)
        .contentShape(Rectangle())
        .background(ResizeCursorArea())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let startWidth = dragStartWidth ?? width
                    if dragStartWidth == nil {
                        dragStartWidth = startWidth
                    }
                    width = clamp(
                        dragDirection.adjustedWidth(
                            startWidth: startWidth,
                            translation: value.translation.width
                        ),
                        to: range
                    )
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct ResizeCursorArea: View {
    var body: some View {
#if os(macOS)
        ResizeCursorRepresentable()
#else
        Color.clear
#endif
    }
}

#if os(macOS)
private struct ResizeCursorRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        CursorView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }
}
#endif

private struct GraphControlToggleButton: View {
    let title: String
    let icon: GraphControlIcon.Kind
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                GraphControlIcon(kind: icon, isSelected: isOn)
                    .frame(width: 24, height: 16)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isOn ? Color.accentColor.opacity(0.34) : Color.secondary.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
        .help("\(title) \(isOn ? "on" : "off")")
    }
}

private struct GraphControlActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .frame(width: 24, height: 16)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(title))
        .help(title)
    }
}

private struct GraphRailGripMenu: View {
    let title: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onOpenWindow: (() -> Void)?

    var body: some View {
        Menu {
            Button {
                onMoveUp()
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(!canMoveUp)

            Button {
                onMoveDown()
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(!canMoveDown)

            if let onOpenWindow {
                Divider()

                Button {
                    onOpenWindow()
                } label: {
                    Label("Open in Window", systemImage: "arrow.up.right.square")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.secondary)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Move \(title)")
        .accessibilityLabel("Move \(title)")
    }
}

private struct FadingGraphControlPane<Content: View>: View {
    let alwaysVisible: Bool
    @State private var isHovering = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .opacity(alwaysVisible || isHovering ? 1 : 0)
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard !alwaysVisible else { return }
                switch phase {
                case .active:
                    isHovering = true
                case .ended:
                    isHovering = false
                }
            }
    }
}

private struct CaptureResultPane: View {
    @ObservedObject var bridge: BridgeClient
    let rpcID: String
    @Binding var isAutoEnabled: Bool
    let alwaysShowsRail: Bool
    let maximumHeight: CGFloat
    let onTrigger: (RpcInfo) -> Void
    let onPopOut: (() -> Void)?
    let onClose: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ViewPreferenceKeys.captureAutoDelaySeconds) private var captureAutoDelaySeconds = CaptureAutoDelay.defaultSeconds

    var body: some View {
        let plotData = capturePlotData

        ZStack(alignment: .topTrailing) {
            TwinleafSurfaceColors.canvasBackgroundColor(for: colorScheme)

            if let plotData {
                CapturePlotView(data: plotData)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Capture", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            FadingGraphControlPane(alwaysVisible: alwaysShowsRail) {
                captureControlSection
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 6)
            .padding(.trailing, 12)
        }
        .frame(minHeight: 180, idealHeight: 260, maxHeight: maximumHeight)
        .onAppear {
            if rpc == nil {
                onClose?()
            }
        }
        .task(id: CaptureAutoTaskKey(
            rpcID: rpcID,
            isEnabled: isAutoEnabled,
            delaySeconds: CaptureAutoDelay.clamped(captureAutoDelaySeconds)
        )) {
            guard isAutoEnabled else { return }
            await runAutoCapture()
        }
    }

    private var captureControlSection: some View {
        HStack(spacing: 6) {
            GraphControlActionButton(
                title: "Trigger",
                systemImage: "bolt.fill",
                action: trigger
            )
            .disabled(rpc == nil)

            GraphControlToggleButton(
                title: "Auto",
                icon: .auto,
                isOn: isAutoEnabled,
                action: {
                    isAutoEnabled.toggle()
                }
            )
            .disabled(rpc == nil)

            if let onPopOut {
                GraphControlActionButton(
                    title: "Window",
                    systemImage: "arrow.up.right.square",
                    action: onPopOut
                )
                .disabled(rpc == nil)
            }

            if onPopOut != nil {
                GraphRailGripMenu(
                    title: "Capture",
                    canMoveUp: false,
                    canMoveDown: false,
                    onMoveUp: {},
                    onMoveDown: {},
                    onOpenWindow: onPopOut
                )
            }

            if let onClose {
                Divider()
                    .frame(height: 22)

                Button(action: onClose) {
                    Image(systemName: "xmark.circle")
                        .font(.body)
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help("Close capture")
                .accessibilityLabel("Close capture")
            }
        }
        .padding(6)
    }

    private var rpc: RpcInfo? {
        bridge.rpc(id: rpcID)
    }

    private var captureTitle: String {
        guard let rpc else { return "Capture" }
        return "\(rpc.route) \(rpc.name)"
    }

    private var capturePlotData: CapturePlotData? {
        CapturePlotData(value: rpc?.value, fallbackTitle: captureTitle)
    }

    private func trigger() {
        guard let rpc else { return }
        onTrigger(rpc)
    }

    private func runAutoCapture() async {
        while !Task.isCancelled {
            guard isAutoEnabled,
                  rpc != nil else {
                return
            }

            let startingRevision = bridge.rpcReplyRevision(id: rpcID)
            trigger()
            await waitForCaptureReply(after: startingRevision)

            guard !Task.isCancelled,
                  isAutoEnabled else {
                return
            }

            let delay = CaptureAutoDelay.clamped(captureAutoDelaySeconds)
            try? await Task.sleep(nanoseconds: captureAutoDelayNanoseconds(delay))
        }
    }

    private func waitForCaptureReply(after startingRevision: UInt64) async {
        while !Task.isCancelled {
            guard isAutoEnabled else { return }
            if bridge.rpcReplyRevision(id: rpcID) != startingRevision {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func captureAutoDelayNanoseconds(_ seconds: Double) -> UInt64 {
        UInt64((CaptureAutoDelay.clamped(seconds) * 1_000_000_000).rounded())
    }
}

private struct CaptureAutoTaskKey: Hashable {
    var rpcID: String
    var isEnabled: Bool
    var delaySeconds: Double
}

private struct CapturePlotData {
    let title: String
    let xTitle: String
    let yTitle: String
    let points: [PlotPoint]

    init?(value: JSONValue?, fallbackTitle: String) {
        guard case .object(let object)? = value else { return nil }
        let metadata = Self.object(object["metadata"]) ?? [:]
        let points = Self.points(from: object)
        guard !points.isEmpty else { return nil }

        let name = Self.string(metadata["name"]) ?? fallbackTitle
        let units = Self.string(metadata["units"]) ?? ""
        let xName = Self.string(metadata["xName"]) ?? "x"
        let xUnits = Self.string(metadata["xUnits"]) ?? ""

        title = name
        xTitle = Self.axisTitle(name: xName, units: xUnits)
        yTitle = Self.axisTitle(name: name, units: units)
        self.points = points
    }

    private static func points(from object: [String: JSONValue]) -> [PlotPoint] {
        if case .array(let rows)? = object["points"] {
            let points = rows.compactMap { row -> PlotPoint? in
                guard case .array(let pair) = row,
                      pair.count >= 2,
                      let x = finiteDouble(pair[0]),
                      let y = finiteDouble(pair[1]) else {
                    return nil
                }
                return PlotPoint(x: x, y: y)
            }
            if !points.isEmpty {
                return points
            }
        }

        guard case .string(let text)? = object["text"] else { return [] }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line -> PlotPoint? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]),
                  x.isFinite,
                  y.isFinite else {
                return nil
            }
            return PlotPoint(x: x, y: y)
        }
    }

    private static func axisTitle(name: String, units: String) -> String {
        units.isEmpty ? name : "\(name) (\(units))"
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object)? = value else { return nil }
        return object
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value else { return nil }
        return string
    }

    private static func finiteDouble(_ value: JSONValue) -> Double? {
        guard case .number(let number) = value, number.isFinite else { return nil }
        return number
    }
}

private struct CapturePlotView: View {
    let data: CapturePlotData

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ViewPreferenceKeys.traceColorPaletteLight) private var traceColorPaletteLightRaw = PlotTracePalette.defaultLightRawValue
    @AppStorage(ViewPreferenceKeys.traceColorPaletteDark) private var traceColorPaletteDarkRaw = PlotTracePalette.defaultDarkRawValue

    var body: some View {
        Canvas { context, size in
            draw(context: &context, size: size)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(data.title)
    }

    private var traceColor: Color {
        if colorScheme == .dark {
            return PlotTracePalette.colors(
                from: traceColorPaletteDarkRaw,
                defaults: PlotTracePalette.defaultDarkHexColors
            )[0]
        }
        return PlotTracePalette.colors(
            from: traceColorPaletteLightRaw,
            defaults: PlotTracePalette.defaultLightHexColors
        )[0]
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        guard size.width > 120, size.height > 120 else { return }

        let plotRect = CGRect(
            x: 10,
            y: 16,
            width: max(40, size.width - 82),
            height: max(40, size.height - 58)
        )
        let xRange = Self.paddedRange(data.points.map(\.x), fraction: 0.02)
        let yRange = Self.paddedRange(data.points.map(\.y), fraction: 0.08)
        let xTicks = Self.majorTicks(in: xRange, targetCount: Self.tickTarget(for: plotRect.width))
        let yTicks = Self.majorTicks(in: yRange, targetCount: Self.tickTarget(for: plotRect.height))

        drawGrid(context: &context, rect: plotRect, xRange: xRange, yRange: yRange, xTicks: xTicks, yTicks: yTicks)
        drawTrace(context: &context, rect: plotRect, xRange: xRange, yRange: yRange)
        drawAxisLabels(context: &context, size: size, rect: plotRect, xRange: xRange, yRange: yRange, xTicks: xTicks, yTicks: yTicks)
    }

    private func drawGrid(
        context: inout GraphicsContext,
        rect: CGRect,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        xTicks: [Double],
        yTicks: [Double]
    ) {
        var grid = Path()
        for tick in xTicks {
            let x = rect.minX + rect.width * CGFloat(Self.fraction(tick, in: xRange))
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for tick in yTicks {
            let y = rect.maxY - rect.height * CGFloat(Self.fraction(tick, in: yRange))
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

        var frame = Path()
        frame.addRect(rect)
        context.stroke(frame, with: .color(.secondary.opacity(0.38)), lineWidth: 1)
    }

    private func drawTrace(
        context: inout GraphicsContext,
        rect: CGRect,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>
    ) {
        var path = Path()
        var didStart = false
        for point in data.points {
            let x = rect.minX + rect.width * CGFloat(Self.fraction(point.x, in: xRange))
            let y = rect.maxY - rect.height * CGFloat(Self.fraction(point.y, in: yRange))
            let screenPoint = CGPoint(x: x, y: y)
            if didStart {
                path.addLine(to: screenPoint)
            } else {
                path.move(to: screenPoint)
                didStart = true
            }
        }
        context.stroke(path, with: .color(traceColor), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
    }

    private func drawAxisLabels(
        context: inout GraphicsContext,
        size: CGSize,
        rect: CGRect,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        xTicks: [Double],
        yTicks: [Double]
    ) {
        for tick in xTicks {
            let x = rect.minX + rect.width * CGFloat(Self.fraction(tick, in: xRange))
            let label = Text(Self.formatTick(tick))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            let clampedX = min(max(x, rect.minX + 3), rect.maxX - 3)
            let anchor: UnitPoint = if x <= rect.minX + 3 {
                .leading
            } else if x >= rect.maxX - 3 {
                .trailing
            } else {
                .center
            }
            context.draw(label, at: CGPoint(x: clampedX, y: rect.maxY + 14), anchor: anchor)
        }

        for tick in yTicks {
            let y = rect.maxY - rect.height * CGFloat(Self.fraction(tick, in: yRange))
            let label = Text(Self.formatTick(tick))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: rect.maxX + 7, y: y), anchor: .leading)
        }

        let xTitle = Text(data.xTitle)
            .font(.body)
            .foregroundStyle(.secondary)
        context.draw(xTitle, at: CGPoint(x: rect.midX, y: size.height - 10), anchor: .bottom)

        var labelContext = context
        labelContext.translateBy(x: min(rect.maxX + 68, size.width - 12), y: rect.midY)
        labelContext.rotate(by: .degrees(90))
        let yTitle = Text(data.yTitle)
            .font(.body)
            .foregroundStyle(.secondary)
        labelContext.draw(yTitle, at: .zero, anchor: .center)
    }

    private static func paddedRange(_ values: [Double], fraction: Double) -> ClosedRange<Double> {
        let finiteValues = values.filter(\.isFinite)
        guard var lower = finiteValues.min(), var upper = finiteValues.max() else {
            return 0...1
        }
        if lower == upper {
            let padding = max(1, abs(lower) * 0.05)
            lower -= padding
            upper += padding
        } else {
            let padding = (upper - lower) * fraction
            lower -= padding
            upper += padding
        }
        return lower...upper
    }

    private static func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0, span.isFinite else { return 0.5 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private static func tickTarget(for length: CGFloat) -> Int {
        min(max(Int(length / 95), 2), 6)
    }

    private static func majorTicks(in range: ClosedRange<Double>, targetCount: Int) -> [Double] {
        let span = range.upperBound - range.lowerBound
        guard span > 0, span.isFinite else { return [range.lowerBound] }
        let step = niceStep(span / Double(max(targetCount - 1, 1)))
        guard step > 0, step.isFinite else { return [] }
        let first = ceil(range.lowerBound / step) * step
        var ticks: [Double] = []
        var tick = first
        var count = 0
        while tick <= range.upperBound + step * 0.5, count < 12 {
            ticks.append(tick)
            tick += step
            count += 1
        }
        return ticks
    }

    private static func niceStep(_ rawStep: Double) -> Double {
        guard rawStep > 0, rawStep.isFinite else { return 1 }
        let exponent = floor(log10(rawStep))
        let base = pow(10, exponent)
        let fraction = rawStep / base
        let niceFraction: Double
        if fraction <= 1 {
            niceFraction = 1
        } else if fraction <= 2 {
            niceFraction = 2
        } else if fraction <= 5 {
            niceFraction = 5
        } else {
            niceFraction = 10
        }
        return niceFraction * base
    }

    private static func formatTick(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude > 0, magnitude < 0.001 || magnitude >= 10_000 {
            return String(format: "%.2e", value)
        }
        if magnitude < 10 {
            return String(format: "%.3g", value)
        }
        return String(format: "%.4g", value)
    }
}

private struct GraphControlIcon: View {
    enum Kind {
        case fft
        case offset
        case labels
        case logX
        case logY
        case auto
    }

    let kind: Kind
    let isSelected: Bool

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            let primary = isSelected ? Color.accentColor : Color.primary
            let secondary = isSelected ? Color.accentColor.opacity(0.68) : Color.secondary
            let stroke = StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round)

            switch kind {
            case .fft:
                context.stroke(
                    lorentzianPath(in: rect),
                    with: .color(primary),
                    style: stroke
                )
            case .offset:
                context.stroke(
                    wavePath(in: rect, phase: 0, center: 0.36, amplitude: 0.2),
                    with: .color(primary),
                    style: stroke
                )
                context.stroke(
                    wavePath(in: rect, phase: .pi / 2, center: 0.66, amplitude: 0.2),
                    with: .color(secondary),
                    style: stroke
                )
            case .labels:
                var axis = Path()
                axis.move(to: CGPoint(x: rect.midX - rect.width * 0.14, y: rect.minY))
                axis.addLine(to: CGPoint(x: rect.midX - rect.width * 0.14, y: rect.maxY))
                for y in [rect.minY, rect.midY, rect.maxY] {
                    axis.move(to: CGPoint(x: rect.midX - rect.width * 0.26, y: y))
                    axis.addLine(to: CGPoint(x: rect.midX + rect.width * 0.08, y: y))
                }
                context.stroke(axis, with: .color(primary), style: stroke)

                for y in [rect.minY + 1.5, rect.midY, rect.maxY - 1.5] {
                    var mark = Path()
                    mark.move(to: CGPoint(x: rect.midX + rect.width * 0.22, y: y))
                    mark.addLine(to: CGPoint(x: rect.maxX, y: y))
                    context.stroke(mark, with: .color(secondary), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            case .logX:
                var axis = Path()
                axis.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                axis.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                for fraction in [0.0, 0.48, 1.0] {
                    let x = rect.minX + rect.width * fraction
                    axis.move(to: CGPoint(x: x, y: rect.maxY))
                    axis.addLine(to: CGPoint(x: x, y: rect.maxY - rect.height * 0.28))
                }
                context.stroke(axis, with: .color(primary), style: stroke)

                context.stroke(
                    risingLogPath(in: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.16)),
                    with: .color(secondary),
                    style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
                )
            case .logY:
                var axis = Path()
                axis.move(to: CGPoint(x: rect.minX, y: rect.minY))
                axis.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                for fraction in [0.0, 0.48, 1.0] {
                    let y = rect.minY + rect.height * fraction
                    axis.move(to: CGPoint(x: rect.minX, y: y))
                    axis.addLine(to: CGPoint(x: rect.minX + rect.width * 0.28, y: y))
                }
                context.stroke(axis, with: .color(primary), style: stroke)

                context.stroke(
                    risingLogPath(in: rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.08)),
                    with: .color(secondary),
                    style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
                )
            case .auto:
                let radius = min(rect.width, rect.height) * 0.36
                let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
                let clockRect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                var clock = Path(ellipseIn: clockRect)
                clock.move(to: CGPoint(x: center.x, y: center.y))
                clock.addLine(to: CGPoint(x: center.x, y: center.y - radius * 0.62))
                clock.move(to: CGPoint(x: center.x, y: center.y))
                clock.addLine(to: CGPoint(x: center.x + radius * 0.52, y: center.y + radius * 0.16))
                context.stroke(clock, with: .color(primary), style: stroke)

                var tick = Path()
                tick.move(to: CGPoint(x: rect.midX - rect.width * 0.16, y: rect.minY))
                tick.addLine(to: CGPoint(x: rect.midX + rect.width * 0.16, y: rect.minY))
                context.stroke(tick, with: .color(secondary), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }

    private func wavePath(
        in rect: CGRect,
        phase: CGFloat,
        center: CGFloat,
        amplitude: CGFloat
    ) -> Path {
        var path = Path()
        let samples = 36
        let centerY = rect.minY + rect.height * center
        let amplitudeY = rect.height * amplitude

        for index in 0..<samples {
            let t = CGFloat(index) / CGFloat(samples - 1)
            let x = rect.minX + rect.width * t
            let y = centerY - sin(t * .pi * 2.35 + phase) * amplitudeY
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        return path
    }

    private func risingLogPath(in rect: CGRect) -> Path {
        var path = Path()
        let samples = 28
        for index in 0..<samples {
            let t = CGFloat(index) / CGFloat(samples - 1)
            let x = rect.minX + rect.width * t
            let fraction = CGFloat(log1p(Double(t * 8)) / log1p(8))
            let y = rect.maxY - fraction * rect.height
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    private func lorentzianPath(in rect: CGRect) -> Path {
        var path = Path()
        let samples = 44
        let baseline = rect.maxY - 1
        let peakHeight = rect.height * 0.86
        let halfWidth = rect.width * 0.13
        let centerX = rect.midX

        for index in 0..<samples {
            let t = CGFloat(index) / CGFloat(samples - 1)
            let x = rect.minX + rect.width * t
            let scaled = (x - centerX) / max(halfWidth, 1)
            let peak = 1 / (1 + scaled * scaled)
            let y = baseline - peak * peakHeight
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        return path
    }
}

private enum TracePalettePreference {
    case light
    case dark
}

struct TwinleafInterfaceStateControls: View {
    let includesToolbar: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Interface")
                .font(.headline)

            TwinleafDistractionFreeControl(usesMenuShortcut: false)
            TwinleafInterfaceVisibilityControls(
                includesToolbar: includesToolbar,
                usesMenuShortcuts: false
            )
            TwinleafInterfaceDetailControls()
        }
        .twinleafCheckboxToggleStyle()
    }
}

struct TwinleafDistractionFreeControl: View {
    let usesMenuShortcut: Bool

    @AppStorage(ViewPreferenceKeys.distractionFree) private var distractionFree = false

    var body: some View {
        shortcutToggle(
            "Distraction-Free",
            isOn: $distractionFree,
            key: "f",
            modifiers: [.command, .option]
        )
    }

    @ViewBuilder
    private func shortcutToggle(
        _ title: String,
        isOn: Binding<Bool>,
        key: KeyEquivalent,
        modifiers: EventModifiers
    ) -> some View {
        if usesMenuShortcut {
            Toggle(title, isOn: isOn)
                .keyboardShortcut(key, modifiers: modifiers)
        } else {
            Toggle(title, isOn: isOn)
        }
    }
}

struct TwinleafInterfaceVisibilityControls: View {
    let includesToolbar: Bool
    let usesMenuShortcuts: Bool

    @AppStorage(ViewPreferenceKeys.distractionFree) private var distractionFree = false
    @AppStorage(ViewPreferenceKeys.showStreamSidebar) private var showStreamSidebar = true
    @AppStorage(ViewPreferenceKeys.showLogPanel) private var showLogPanel = false
    @AppStorage(ViewPreferenceKeys.showStatusBar) private var showStatusBar = false
    @AppStorage(ViewPreferenceKeys.showToolbar) private var showToolbar = true

    var body: some View {
        Group {
            if includesToolbar {
                shortcutToggle(
                    "Show Toolbar",
                    isOn: toolbarVisibility,
                    key: "t",
                    modifiers: [.command, .option]
                )
            }
            Toggle("Show Status Bar", isOn: statusBarVisibility)
            shortcutToggle(
                "Show Streams Sidebar",
                isOn: streamSidebarVisibility,
                key: "s",
                modifiers: [.command, .option]
            )
            Toggle("Show Log Pane", isOn: logPanelVisibility)
        }
    }

    private var toolbarVisibility: Binding<Bool> {
        twinleafInterfaceVisibilityBinding(distractionFree: $distractionFree, storage: $showToolbar)
    }

    private var statusBarVisibility: Binding<Bool> {
        twinleafInterfaceVisibilityBinding(distractionFree: $distractionFree, storage: $showStatusBar)
    }

    private var streamSidebarVisibility: Binding<Bool> {
        twinleafInterfaceVisibilityBinding(distractionFree: $distractionFree, storage: $showStreamSidebar)
    }

    private var logPanelVisibility: Binding<Bool> {
        twinleafInterfaceVisibilityBinding(distractionFree: $distractionFree, storage: $showLogPanel)
    }

    @ViewBuilder
    private func shortcutToggle(
        _ title: String,
        isOn: Binding<Bool>,
        key: KeyEquivalent,
        modifiers: EventModifiers
    ) -> some View {
        if usesMenuShortcuts {
            Toggle(title, isOn: isOn)
                .keyboardShortcut(key, modifiers: modifiers)
        } else {
            Toggle(title, isOn: isOn)
        }
    }
}

/// Sidebar-toolbar toggle for unify mode. Because it's declared on the
/// sidebar column's content, it hides whenever the sidebar is hidden; it also
/// only appears when at least two same-type sensors are connected.
private struct UnifySensorsToolbarItem: ToolbarContent {
    let isAvailable: Bool
    @AppStorage(ViewPreferenceKeys.unifySensors) private var unifySensors = false

    var body: some ToolbarContent {
        if isAvailable {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $unifySensors) {
                    Label("Unify Matching Sensors", systemImage: "arrow.triangle.merge")
                }
                .toggleStyle(.button)
                .help(unifySensors
                    ? "Show each sensor separately"
                    : "Unify matching sensors: group same-type sensors' streams and settings")
            }
        }
    }
}

struct TwinleafInterfaceDetailControls: View {
    @AppStorage(ViewPreferenceKeys.showStreamDetails) private var showStreamDetails = false
    @AppStorage(ViewPreferenceKeys.showRPCDetails) private var showRPCDetails = false
    @AppStorage(ViewPreferenceKeys.showPlotKey) private var showPlotKey = true
    @AppStorage(ViewPreferenceKeys.unifySensors) private var unifySensors = false

    var body: some View {
        Group {
            Toggle("Show Stream Details", isOn: $showStreamDetails)
            Toggle("Show Setting Details", isOn: $showRPCDetails)
            Toggle("Show Plot Key", isOn: $showPlotKey)
            Toggle("Unify Matching Sensors", isOn: $unifySensors)
        }
    }
}

@MainActor
func twinleafInterfaceVisibilityBinding(distractionFree: Binding<Bool>, storage: Binding<Bool>) -> Binding<Bool> {
    Binding(
        get: {
            !distractionFree.wrappedValue && storage.wrappedValue
        },
        set: { isVisible in
            distractionFree.wrappedValue = false
            storage.wrappedValue = isVisible
        }
    )
}

private struct PlotSettingsWindow: View {
    @ObservedObject var bridge: BridgeClient

    @Environment(\.dismiss) private var dismiss
    @Environment(\.self) private var environment
    @AppStorage(ViewPreferenceKeys.theme) private var themeRaw = ThemePreference.system.rawValue
    @AppStorage("smokeThresholdMegabytes") private var smokeThresholdMegabytes = 1024.0
    @AppStorage(ViewPreferenceKeys.defaultWindowSeconds) private var defaultWindowSeconds = PlotWindowDuration.defaultSeconds
    @AppStorage(ViewPreferenceKeys.suppressCommHubDefaultPlot) private var suppressCommHubDefaultPlot = true
    @AppStorage(ViewPreferenceKeys.logOnStartup) private var logOnStartup = false
    @AppStorage(ViewPreferenceKeys.rpcFloatPrecisionPPM) private var rpcFloatPrecisionPPM = NumericDisplayPolicy.defaultRPCFloatPrecisionPPM
    @AppStorage(ViewPreferenceKeys.rpcSliderRateLimitHz) private var rpcSliderRateLimitHz = RPCSliderRateLimit.defaultHz
    @AppStorage(ViewPreferenceKeys.captureAutoDelaySeconds) private var captureAutoDelaySeconds = CaptureAutoDelay.defaultSeconds
    @AppStorage(ViewPreferenceKeys.logMessageLineLimit) private var logMessageLineLimit = LogMessageScrollback.defaultLineLimit
    @AppStorage(ViewPreferenceKeys.yAxisHysteresis) private var yAxisHysteresis = PlotAxisHysteresis.defaultFraction
    @AppStorage(ViewPreferenceKeys.fftAxisHysteresis) private var fftAxisHysteresis = PlotAxisHysteresis.defaultFraction
    @AppStorage(ViewPreferenceKeys.traceColorPaletteLight) private var traceColorPaletteLightRaw = PlotTracePalette.defaultLightRawValue
    @AppStorage(ViewPreferenceKeys.traceColorPaletteDark) private var traceColorPaletteDarkRaw = PlotTracePalette.defaultDarkRawValue
    @AppStorage(ViewPreferenceKeys.favoriteRPCs) private var favoriteRPCsRaw = ""
    @State private var newRememberedURL = ""
    @State private var newFavoriteRPCID = ""

    var body: some View {
        settingsPanel
            .twinleafSettingsWindowFrame()
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Settings", systemImage: "gearshape")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Appearance")
                            .font(.headline)

                        Picker("Theme", selection: themeBinding) {
                            ForEach(ThemePreference.allCases) { theme in
                                Text(theme.title).tag(theme)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Divider()

#if os(iOS)
                    TwinleafInterfaceStateControls(includesToolbar: false)

                    Divider()

#endif
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Timeseries")
                            .font(.headline)

                        Toggle("FPCS downsampling", isOn: Binding(
                            get: { bridge.viewConfig.decimationMethod == .fpcs },
                            set: { bridge.setDecimationMethod($0 ? .fpcs : .none) }
                        ))
                        .twinleafCheckboxToggleStyle()

                        Toggle("Skip comm/hub default graph", isOn: $suppressCommHubDefaultPlot)
                            .twinleafCheckboxToggleStyle()

                        HStack(spacing: 12) {
                            Text("Default window")
                                .frame(width: 92, alignment: .leading)
                            TextField("Seconds", value: defaultWindowSecondsBinding, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 96)
                            Text("s")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        HStack(spacing: 12) {
                            Text("Resolution")
                                .frame(width: 92, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { Double(bridge.viewConfig.resolutionMultiplier) },
                                    set: { bridge.setResolutionMultiplier(Int($0.rounded())) }
                                ),
                                in: 20...200,
                                step: 20
                            )
                            Text("\((Double(bridge.viewConfig.resolutionMultiplier) / 100.0).formatted(.number.precision(.fractionLength(2))))x")
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }

                        HStack(spacing: 12) {
                            Text("Y-axis hysteresis")
                                .frame(width: 112, alignment: .leading)
                            Slider(
                                value: yAxisHysteresisBinding,
                                in: PlotAxisHysteresis.range,
                                step: 0.05
                            )
                            Text(yAxisHysteresisPercentText)
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                        .help("Timeseries y-axis range hysteresis. Larger values make axis range changes less frequent.")
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Trace Colors")
                                .font(.headline)
                            Spacer()
                            Button("Reset") {
                                traceColorPaletteLightRaw = PlotTracePalette.defaultLightRawValue
                                traceColorPaletteDarkRaw = PlotTracePalette.defaultDarkRawValue
                            }
                            .disabled(traceColorPalettesAreDefault)
                        }

                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                            GridRow {
                                Color.clear
                                    .frame(width: 56, height: 1)
                                    .accessibilityHidden(true)
                                Text("Light")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Dark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            ForEach(0..<PlotTracePalette.colorCount, id: \.self) { index in
                                GridRow {
                                    Text("Trace \(index + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)

                                    ColorPicker(
                                        "Light trace \(index + 1)",
                                        selection: traceColorBinding(at: index, palette: .light),
                                        supportsOpacity: false
                                    )
                                    .labelsHidden()

                                    ColorPicker(
                                        "Dark trace \(index + 1)",
                                        selection: traceColorBinding(at: index, palette: .dark),
                                        supportsOpacity: false
                                    )
                                    .labelsHidden()
                                }
                                .help("Trace \(index + 1) color")
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("FFT")
                            .font(.headline)

                        Picker("Detrend", selection: Binding(
                            get: { bridge.viewConfig.detrend },
                            set: { bridge.setDetrend($0) }
                        )) {
                            ForEach(DetrendMethod.allCases) { method in
                                Text(method.title).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 12) {
                            Toggle("Log Frequency", isOn: Binding(
                                get: { bridge.viewConfig.fftLogX },
                                set: { bridge.setFFTLogX($0) }
                            ))
                            Toggle("Log Amplitude", isOn: Binding(
                                get: { bridge.viewConfig.fftLogY },
                                set: { bridge.setFFTLogY($0) }
                            ))
                        }
                        .twinleafCheckboxToggleStyle()

                        HStack(spacing: 12) {
                            Text("Axis hysteresis")
                                .frame(width: 112, alignment: .leading)
                            Slider(
                                value: fftAxisHysteresisBinding,
                                in: PlotAxisHysteresis.range,
                                step: 0.05
                            )
                            Text(fftAxisHysteresisPercentText)
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                        .help("FFT axis range hysteresis. Log axes use this as a fraction of an order of magnitude.")
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Settings")
                            .font(.headline)

                        HStack(spacing: 12) {
                            Text("Float precision")
                                .frame(width: 112, alignment: .leading)
                            TextField("Precision", value: rpcFloatPrecisionPPMBinding, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 96)
                            Text("ppm")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        HStack(spacing: 12) {
                            Text("Slider rate")
                                .frame(width: 112, alignment: .leading)
                            TextField("Rate", value: rpcSliderRateLimitHzBinding, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 96)
                            Text("Hz")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        HStack(spacing: 12) {
                            Text("Capture delay")
                                .frame(width: 112, alignment: .leading)
                            TextField("Delay", value: captureAutoDelaySecondsBinding, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 96)
                            Text("s")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .help("How long Auto capture waits after a capture reply is read out before triggering the next capture.")

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Favorite settings")
                                .font(.subheadline)

                            HStack(spacing: 8) {
                                TextField("setting.name", text: $newFavoriteRPCID)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(addFavoriteRPC)

                                Button {
                                    addFavoriteRPC()
                                } label: {
                                    Image(systemName: "plus")
                                }
                                .disabled(trimmedNewFavoriteRPCID.isEmpty)
                                .help("Add favorite setting")
                            }

                            if favoriteRPCIDs.isEmpty {
                                Text("No favorite settings")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(favoriteRPCIDs, id: \.self) { rpcID in
                                        FavoriteRPCRow(
                                            rpcID: rpcID,
                                            onCommit: updateFavoriteRPC,
                                            onDelete: removeFavoriteRPC
                                        )
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Log")
                            .font(.headline)

                        Toggle("Log on startup", isOn: $logOnStartup)

                        HStack(spacing: 12) {
                            Text("Smoke")
                                .frame(width: 92, alignment: .leading)
                            Slider(
                                value: smokeThresholdSliderValue,
                                in: 0...5,
                                step: 0.25
                            )
                            Text(formatFileSize(UInt64(smokeThresholdMegabytes * 1_000_000)))
                                .monospacedDigit()
                                .frame(width: 82, alignment: .trailing)
                        }

                        HStack(spacing: 12) {
                            Text("Scrollback")
                                .frame(width: 92, alignment: .leading)
                            TextField("Lines", value: logMessageLineLimitBinding, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 96)
                            Text("lines")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .twinleafCheckboxToggleStyle()

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Device URLs")
                            .font(.headline)

                        HStack(spacing: 8) {
                            TextField("tcp://localhost", text: $newRememberedURL)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addRememberedURL)

                            Button {
                                addRememberedURL()
                            } label: {
                                Image(systemName: "plus")
                            }
                            .disabled(trimmedNewRememberedURL.isEmpty)
                            .help("Remember device URL")
                        }

                        if bridge.rememberedDeviceURLs.isEmpty {
                            Text("No remembered URLs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(bridge.rememberedDeviceURLs, id: \.self) { url in
                                    RememberedURLRow(
                                        url: url,
                                        onCommit: bridge.updateRememberedDeviceURL,
                                        onDelete: bridge.removeRememberedDeviceURL
                                    )
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var trimmedNewRememberedURL: String {
        newRememberedURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNewFavoriteRPCID: String {
        newFavoriteRPCID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var favoriteRPCIDs: [String] {
        RPCFavorites.ids(from: favoriteRPCsRaw)
    }

    private var themeBinding: Binding<ThemePreference> {
        Binding(
            get: {
                ThemePreference(rawValue: themeRaw) ?? .system
            },
            set: { theme in
                themeRaw = theme.rawValue
            }
        )
    }

    private var defaultWindowSecondsBinding: Binding<Double> {
        Binding(
            get: {
                PlotWindowDuration.clamped(defaultWindowSeconds)
            },
            set: { value in
                let seconds = PlotWindowDuration.clamped(value.rounded())
                defaultWindowSeconds = seconds
                bridge.setWindowSeconds(seconds)
            }
        )
    }

    private var smokeThresholdSliderValue: Binding<Double> {
        Binding(
            get: {
                log10(max(1, smokeThresholdMegabytes))
            },
            set: { value in
                smokeThresholdMegabytes = pow(10, min(max(value, 0), 5))
            }
        )
    }

    private var rpcFloatPrecisionPPMBinding: Binding<Double> {
        Binding(
            get: {
                NumericDisplayPolicy.clampedRPCFloatPrecisionPPM(rpcFloatPrecisionPPM)
            },
            set: { value in
                rpcFloatPrecisionPPM = NumericDisplayPolicy.clampedRPCFloatPrecisionPPM(value)
            }
        )
    }

    private var rpcSliderRateLimitHzBinding: Binding<Double> {
        Binding(
            get: {
                clampedRPCSliderRateLimitHz(rpcSliderRateLimitHz)
            },
            set: { value in
                rpcSliderRateLimitHz = clampedRPCSliderRateLimitHz(value)
            }
        )
    }

    private var captureAutoDelaySecondsBinding: Binding<Double> {
        Binding(
            get: {
                CaptureAutoDelay.clamped(captureAutoDelaySeconds)
            },
            set: { value in
                captureAutoDelaySeconds = CaptureAutoDelay.clamped(value)
            }
        )
    }

    private var yAxisHysteresisBinding: Binding<Double> {
        Binding(
            get: {
                PlotAxisHysteresis.clamped(yAxisHysteresis)
            },
            set: { value in
                yAxisHysteresis = PlotAxisHysteresis.clamped(value)
            }
        )
    }

    private var yAxisHysteresisPercentText: String {
        "\(Int((PlotAxisHysteresis.clamped(yAxisHysteresis) * 100).rounded()))%"
    }

    private var fftAxisHysteresisBinding: Binding<Double> {
        Binding(
            get: {
                PlotAxisHysteresis.clamped(fftAxisHysteresis)
            },
            set: { value in
                fftAxisHysteresis = PlotAxisHysteresis.clamped(value)
            }
        )
    }

    private var fftAxisHysteresisPercentText: String {
        "\(Int((PlotAxisHysteresis.clamped(fftAxisHysteresis) * 100).rounded()))%"
    }

    private var logMessageLineLimitBinding: Binding<Int> {
        Binding(
            get: {
                LogMessageScrollback.clamped(logMessageLineLimit)
            },
            set: { value in
                let limit = LogMessageScrollback.clamped(value)
                logMessageLineLimit = limit
                bridge.trimLogMessages(limit: limit)
            }
        )
    }

    private var traceColorPalettesAreDefault: Bool {
        traceColorPaletteLightRaw == PlotTracePalette.defaultLightRawValue
            && traceColorPaletteDarkRaw == PlotTracePalette.defaultDarkRawValue
    }

    private func traceColorBinding(at index: Int, palette: TracePalettePreference) -> Binding<Color> {
        Binding(
            get: {
                let colors = PlotTracePalette.colors(
                    from: traceColorRawValue(for: palette),
                    defaults: traceColorDefaults(for: palette)
                )
                guard colors.indices.contains(index) else {
                    return PlotTracePalette.colors(
                        from: traceColorDefaultRawValue(for: palette),
                        defaults: traceColorDefaults(for: palette)
                    )[0]
                }
                return colors[index]
            },
            set: { color in
                var hexColors = PlotTracePalette.hexColors(
                    from: traceColorRawValue(for: palette),
                    defaults: traceColorDefaults(for: palette)
                )
                guard hexColors.indices.contains(index) else {
                    return
                }
                let hex = PlotTracePalette.hexString(from: color, in: environment)
                hexColors[index] = hex
                setTraceColorRawValue(
                    PlotTracePalette.rawValue(
                        from: hexColors,
                        defaults: traceColorDefaults(for: palette)
                    ),
                    for: palette
                )
            }
        )
    }

    private func traceColorRawValue(for palette: TracePalettePreference) -> String {
        switch palette {
        case .light: traceColorPaletteLightRaw
        case .dark: traceColorPaletteDarkRaw
        }
    }

    private func traceColorDefaultRawValue(for palette: TracePalettePreference) -> String {
        switch palette {
        case .light: PlotTracePalette.defaultLightRawValue
        case .dark: PlotTracePalette.defaultDarkRawValue
        }
    }

    private func traceColorDefaults(for palette: TracePalettePreference) -> [String] {
        switch palette {
        case .light: PlotTracePalette.defaultLightHexColors
        case .dark: PlotTracePalette.defaultDarkHexColors
        }
    }

    private func setTraceColorRawValue(_ value: String, for palette: TracePalettePreference) {
        switch palette {
        case .light:
            traceColorPaletteLightRaw = value
        case .dark:
            traceColorPaletteDarkRaw = value
        }
    }

    private func addRememberedURL() {
        guard !trimmedNewRememberedURL.isEmpty else { return }
        bridge.addRememberedDeviceURL(trimmedNewRememberedURL)
        newRememberedURL = ""
    }

    private func addFavoriteRPC() {
        let rpcID = trimmedNewFavoriteRPCID
        guard !rpcID.isEmpty else { return }
        setFavoriteRPCIDs(favoriteRPCIDs + [rpcID])
        newFavoriteRPCID = ""
    }

    private func updateFavoriteRPC(_ oldRPCID: String, _ newRPCID: String) {
        let trimmedNewRPCID = newRPCID.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextIDs = favoriteRPCIDs.reduce(into: [String]()) { result, rpcID in
            let candidate = rpcID == oldRPCID ? trimmedNewRPCID : rpcID
            guard !candidate.isEmpty, !result.contains(candidate) else { return }
            result.append(candidate)
        }
        setFavoriteRPCIDs(nextIDs)
    }

    private func removeFavoriteRPC(_ rpcID: String) {
        setFavoriteRPCIDs(favoriteRPCIDs.filter { $0 != rpcID })
    }

    private func setFavoriteRPCIDs(_ ids: [String]) {
        favoriteRPCsRaw = RPCFavorites.rawValue(from: ids)
    }
}

private struct RememberedURLRow: View {
    let url: String
    let onCommit: (String, String) -> Void
    let onDelete: (String) -> Void

    @State private var draft: String

    init(
        url: String,
        onCommit: @escaping (String, String) -> Void,
        onDelete: @escaping (String) -> Void
    ) {
        self.url = url
        self.onCommit = onCommit
        self.onDelete = onDelete
        _draft = State(initialValue: url)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("URL", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)

            Button {
                commit()
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .disabled(trimmedDraft == url)
            .help("Save URL")

            Button(role: .destructive) {
                onDelete(url)
            } label: {
                Image(systemName: "trash")
            }
            .help("Forget URL")
        }
        .onChange(of: url) { _, newURL in
            draft = newURL
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        onCommit(url, trimmedDraft)
    }
}

private struct FavoriteRPCRow: View {
    let rpcID: String
    let onCommit: (String, String) -> Void
    let onDelete: (String) -> Void

    @State private var draft: String

    init(
        rpcID: String,
        onCommit: @escaping (String, String) -> Void,
        onDelete: @escaping (String) -> Void
    ) {
        self.rpcID = rpcID
        self.onCommit = onCommit
        self.onDelete = onDelete
        _draft = State(initialValue: rpcID)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("setting.name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit(commit)

            Button {
                commit()
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .disabled(trimmedDraft == rpcID)
            .help("Save favorite setting")

            Button(role: .destructive) {
                onDelete(rpcID)
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove favorite setting")
        }
        .onChange(of: rpcID) { _, newRPCID in
            draft = newRPCID
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        onCommit(rpcID, trimmedDraft)
    }
}

private enum DevicePickerButtonProminence {
    case icon
    case standard
    case primary
    case destructive
}

#if os(iOS)
private struct DevicePickerGlassButtonStyle: ButtonStyle {
    let prominence: DevicePickerButtonProminence

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    init(_ prominence: DevicePickerButtonProminence = .standard) {
        self.prominence = prominence
    }

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)

        configuration.label
            .font(buttonFont)
            .lineLimit(1)
            .frame(minWidth: minimumWidth, minHeight: 44)
            .padding(.horizontal, horizontalPadding)
            .contentShape(shape)
            .foregroundStyle(foregroundStyle)
            .background {
                shape
                    .fill(Color.clear)
                    .glassEffect(.regular.tint(glassTint), in: shape)
                    .overlay {
                        shape.fill(fillOverlay)
                    }
                    .overlay {
                        shape.strokeBorder(strokeColor, lineWidth: 1)
                    }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var minimumWidth: CGFloat {
        switch prominence {
        case .icon, .destructive:
            44
        case .primary:
            104
        case .standard:
            86
        }
    }

    private var horizontalPadding: CGFloat {
        switch prominence {
        case .icon, .destructive:
            0
        case .primary:
            18
        case .standard:
            16
        }
    }

    private var buttonFont: Font {
        switch prominence {
        case .primary:
            .body.weight(.semibold)
        default:
            .body.weight(.medium)
        }
    }

    private var foregroundStyle: Color {
        guard isEnabled else { return .secondary }
        switch prominence {
        case .destructive:
            return .red
        default:
            return .primary
        }
    }

    private var glassTint: Color {
        let baseOpacity = colorScheme == .dark ? 0.16 : 0.28
        switch prominence {
        case .primary:
            return Color.accentColor.opacity(colorScheme == .dark ? 0.26 : 0.34)
        case .destructive:
            return Color.red.opacity(colorScheme == .dark ? 0.18 : 0.24)
        default:
            return Color.white.opacity(baseOpacity)
        }
    }

    private var fillOverlay: Color {
        switch prominence {
        case .primary:
            return Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.13)
        case .destructive:
            return Color.red.opacity(colorScheme == .dark ? 0.06 : 0.08)
        default:
            return Color.white.opacity(colorScheme == .dark ? 0.045 : 0.10)
        }
    }

    private var strokeColor: Color {
        switch prominence {
        case .primary:
            return Color.accentColor.opacity(colorScheme == .dark ? 0.34 : 0.40)
        case .destructive:
            return Color.red.opacity(colorScheme == .dark ? 0.30 : 0.34)
        default:
            return Color.white.opacity(colorScheme == .dark ? 0.22 : 0.36)
        }
    }
}
#endif

private struct DevicePicker: View {
    @ObservedObject var bridge: BridgeClient
    let fileURL: URL?
    let temporaryLogURL: URL
    @Binding var loggingEnabled: Bool
    let onDismiss: () -> Void

    @State private var selection: AvailableDevice.ID?
    @State private var isAddingURL = false
    @State private var editingRememberedURL: String?
    @State private var urlDraft = ""
    @AppStorage(ViewPreferenceKeys.showAllSerialPorts) private var showAllSerialPorts = true

    /// Re-scan for devices (serial probes + mDNS network discovery) on a slow
    /// cadence so freshly-powered or newly-advertised sensors appear without a
    /// manual refresh.
    private let autoRefreshTicker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Connect Device")
                    .font(.title2)
                Spacer()
                Button {
                    startAddingURL()
                } label: {
                    Label("Add Device URL", systemImage: "plus")
                }
                .twinleafDevicePickerHeaderIconButtonStyle()
                .help("Add device URL")
                .disabled(bridge.connectionProgress.canCancel || isAddingURL)

                Button {
                    refreshDevices()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .twinleafDevicePickerHeaderIconButtonStyle()
                .help("Refresh")
                .disabled(bridge.connectionProgress.canCancel)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if bridge.connectionProgress.isVisible {
                // Once a connection attempt starts, collapse the list to the
                // row being connected so the status panel below gets the room.
                if let device = connectingDevice {
                    DevicePickerRow(
                        device: device,
                        isSelected: true,
                        onSelect: {},
                        onConnect: {},
                        onEdit: nil,
                        onForget: {}
                    )
                    .allowsHitTesting(false)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
                }

                if !bridge.connectionProgress.canCancel,
                   !bridge.connectionProgress.isReadyToDismiss {
                    // Terminal state (failed/cancelled): offer a way back to
                    // the full list to pick a different device.
                    Button {
                        bridge.clearConnectionProgress()
                    } label: {
                        Label("Choose Another Device", systemImage: "chevron.left")
                    }
                    .twinleafDevicePickerButtonStyle()
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
                }

                ConnectionProgressPanel(progress: bridge.connectionProgress)
                    .padding(.horizontal)
                    .padding(.bottom, 10)

                Spacer(minLength: 0)
            } else {
                List(selection: $selection) {
                    if isAddingURL {
                        DevicePickerURLInlineRow(
                            draft: $urlDraft,
                            initialURL: "",
                            commitTitle: "Add",
                            routes: [],
                            onCommit: addRememberedURL,
                            onCancel: cancelInlineURLEditing
                        )
                    }

                    ForEach(bridge.availableDevices) { device in
                        if editingRememberedURL == device.url, device.kind == "remembered" {
                            DevicePickerURLInlineRow(
                                draft: $urlDraft,
                                initialURL: device.url,
                                commitTitle: "Save",
                                routes: device.routes,
                                onCommit: { updateRememberedURL(device, to: $0) },
                                onCancel: cancelInlineURLEditing
                            )
                        } else {
                            DevicePickerRow(
                                device: device,
                                isSelected: selection == device.id,
                                onSelect: { selection = device.id },
                                onConnect: { connect(device) },
                                onEdit: device.kind == "remembered" ? { startEditing(device) } : nil,
                                onForget: { removeRememberedURL(device) }
                            )
                            .tag(device.id)
                        }
                    }
                }
                .frame(minHeight: 200, maxHeight: .infinity)
            }

            Divider()

            // Renders as a switch on iOS and a checkbox on macOS by default.
            Toggle("Log data from start", isOn: $loggingEnabled)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .disabled(bridge.connectionProgress.canCancel)

#if os(macOS)
            Toggle("Show all serial ports", isOn: $showAllSerialPorts)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .disabled(bridge.connectionProgress.canCancel)
                .onChange(of: showAllSerialPorts) { _, _ in
                    bridge.debugDevicePicker("showAllSerialPorts changed to \(showAllSerialPorts)")
                    refreshDevices()
                }
#endif

            HStack(spacing: 12) {
                if loggingEnabled {
                    Label(
                        loggingStatusText,
                        systemImage: "circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .help(temporaryLogURL.path)
                    .lineLimit(2)
                }

                Spacer()

                Button(bridge.connectionProgress.canCancel ? "Cancel Connection" : "Cancel") {
                    cancelOrDismiss()
                }
                .twinleafDevicePickerButtonStyle()
                .keyboardShortcut(.cancelAction)

                Button(bridge.connectionProgress.isReadyToDismiss ? "Connected" : "Connect") {
                    connectCommittingDraft()
                }
                .twinleafDevicePickerButtonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(bridge.availableDevices.isEmpty || bridge.connectionProgress.canCancel || bridge.connectionProgress.isReadyToDismiss)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .twinleafDevicePickerFrame(isConnectionProgressVisible: bridge.connectionProgress.isVisible)
        .onAppear {
            bridge.debugDevicePicker(
                "onAppear showAllSerialPorts=\(showAllSerialPorts) " +
                "available=\(bridge.availableDevices.count) summary=\(bridge.deviceDiscoverySummary)"
            )
            selection = bridge.availableDevices.first?.id
            refreshDevices()
        }
        .onReceive(autoRefreshTicker) { _ in
            // Skip while a connection attempt is underway (the list is hidden
            // and a rescan would churn the bridge mid-connect) or while the
            // user is typing a URL.
            guard !bridge.connectionProgress.isVisible,
                  !isAddingURL,
                  editingRememberedURL == nil else {
                return
            }
            refreshDevices()
        }
        .onChange(of: bridge.connectionProgress.isReadyToDismiss) { _, isReady in
            guard isReady else { return }
            let attemptID = bridge.connectionProgress.attemptID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard bridge.connectionProgress.attemptID == attemptID,
                      bridge.connectionProgress.isReadyToDismiss else {
                    return
                }
                bridge.clearConnectionProgress()
                onDismiss()
            }
        }
        .onChange(of: bridge.availableDevices) { _, devices in
            let rendered = devices.map { "\($0.kind)|\($0.url)" }.joined(separator: " ; ")
            bridge.debugDevicePicker("availableDevices changed count=\(devices.count) rendered=[\(rendered)]")
            guard selection == nil || !devices.contains(where: { $0.id == selection }) else {
                return
            }
            selection = devices.first?.id
        }
        .twinleafOnExitCommand {
            cancelOrDismiss()
        }
        .animation(.easeInOut(duration: 0.18), value: bridge.connectionProgress.isVisible)
    }

    /// The device the in-flight (or just-finished) connection attempt targets,
    /// for the collapsed single-row display. Falls back to a synthesized entry
    /// from the progress fields if the device list no longer contains the URL.
    private var connectingDevice: AvailableDevice? {
        let progress = bridge.connectionProgress
        if let device = bridge.availableDevices.first(where: { $0.url == progress.deviceURL }) {
            return device
        }
        guard !progress.deviceURL.isEmpty else { return nil }
        return AvailableDevice(
            url: progress.deviceURL,
            label: progress.deviceLabel.isEmpty ? progress.deviceURL : progress.deviceLabel,
            kind: progress.deviceKind,
            detail: progress.deviceURL
        )
    }

    private func startAddingURL() {
        editingRememberedURL = nil
        isAddingURL = true
        urlDraft = ""
        selection = nil
    }

    private func startEditing(_ device: AvailableDevice) {
        guard device.kind == "remembered" else { return }
        isAddingURL = false
        editingRememberedURL = device.url
        urlDraft = device.url
        // Deliberately not changing `selection` here: a selection change makes
        // the List scroll the row into a new position, clipping the row top.
    }

    private func cancelInlineURLEditing() {
        isAddingURL = false
        editingRememberedURL = nil
    }

    private func connect(_ device: AvailableDevice) {
        bridge.debugDevicePicker("connect url=\(device.url) kind=\(device.kind)")
        bridge.connect(to: device, logURL: loggingEnabled ? temporaryLogURL : nil)
    }

    /// Footer Connect button: if a URL is being added or edited, commit the
    /// draft first and connect to what was typed; otherwise connect to the
    /// selection.
    private func connectCommittingDraft() {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAddingURL || editingRememberedURL != nil, !trimmed.isEmpty {
            if let editingURL = editingRememberedURL,
               let device = bridge.availableDevices.first(where: { $0.url == editingURL }) {
                updateRememberedURL(device, to: trimmed)
            } else {
                addRememberedURL(trimmed)
            }
            let target = bridge.availableDevices.first { $0.url == trimmed }
                ?? AvailableDevice(url: trimmed, label: trimmed, kind: "remembered", detail: trimmed)
            selection = target.id
            connect(target)
            return
        }

        cancelInlineURLEditing()
        let selected = bridge.availableDevices.first { $0.id == selection }
            ?? bridge.availableDevices.first
        if let selected {
            connect(selected)
        }
    }

    private func cancelOrDismiss() {
        if bridge.connectionProgress.canCancel {
            bridge.cancelConnection()
        } else {
            bridge.clearConnectionProgress()
            onDismiss()
        }
    }

    private func refreshDevices() {
        bridge.debugDevicePicker("refreshDevices showAllSerialPorts=\(showAllSerialPorts)")
        bridge.listDevices(includeAllSerial: showAllSerialPorts)
    }

    private var loggingStatusText: String {
        if let fileURL {
            return "Logging through temporary buffer for \(fileURL.lastPathComponent)"
        }
        return "Logging to a temporary .tio"
    }

    private func addRememberedURL(_ url: String) {
        bridge.debugDevicePicker("addRememberedURL \(url)")
        if let device = bridge.addRememberedDeviceURL(url) {
            selection = device.id
        }
        isAddingURL = false
        editingRememberedURL = nil
    }

    private func updateRememberedURL(_ device: AvailableDevice, to url: String) {
        guard device.kind == "remembered" else { return }
        bridge.debugDevicePicker("updateRememberedURL \(device.url) -> \(url)")
        bridge.updateRememberedDeviceURL(device.url, to: url)
        isAddingURL = false
        editingRememberedURL = nil
    }

    private func removeRememberedURL(_ device: AvailableDevice) {
        guard device.kind == "remembered" else { return }
        bridge.debugDevicePicker("removeRememberedURL \(device.url)")
        bridge.removeRememberedDeviceURL(device.url)
        if editingRememberedURL == device.url {
            editingRememberedURL = nil
        }
        if selection == device.id {
            selection = bridge.availableDevices.first?.id
        }
    }
}

private enum ConnectionProgressRowState {
    case waiting
    case active
    case complete
    case skipped
    case failed

    var systemImage: String {
        switch self {
        case .waiting:
            "circle"
        case .active:
            "arrow.triangle.2.circlepath"
        case .complete:
            "checkmark.circle.fill"
        case .skipped:
            "minus.circle.fill"
        case .failed:
            "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .waiting:
            .secondary
        case .active:
            .accentColor
        case .complete:
            .green
        case .skipped:
            .secondary
        case .failed:
            .red
        }
    }
}

/// Live timing & rate diagnostics (the `tio health` data) grouped by device
/// route, shown from the toolbar info button.
private struct DeviceHealthPopover: View {
    @ObservedObject var bridge: BridgeClient

    /// All streams sorted by route then stream id (route appears per row, so no
    /// grouping headers are needed — keeps it compact for iPhone).
    private var streams: [StreamHealthInfo] {
        bridge.streamHealth.sorted {
            ($0.route, $0.streamId) < ($1.route, $1.streamId)
        }
    }

    // Fixed widths for the second-line data columns so they align across rows.
    private static let rateWidth: CGFloat = 78
    private static let driftWidth: CGFloat = 86
    private static let droppedWidth: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection Health")
                .font(.headline)

            if bridge.streamHealth.isEmpty {
                Text("No live streams.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(streams) { stream in
                            healthRow(stream)
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .padding(16)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder
    private func healthRow(_ stream: StreamHealthInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Line 1: status dot + route and stream name.
            HStack(spacing: 6) {
                Circle()
                    .fill(stream.stale ? Color.secondary : Color.green)
                    .frame(width: 7, height: 7)
                Text("\(stream.route)  \(stream.name.isEmpty ? "stream \(stream.streamId)" : stream.name)")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Line 2: data columns, indented under the name.
            HStack(spacing: 0) {
                metric("Rate", rateText(stream.rateHz), unit: "Hz",
                       width: Self.rateWidth,
                       color: stream.stale ? .secondary : .primary)
                metric("Drift", ppmText(stream.ppm), unit: "ppm",
                       width: Self.driftWidth,
                       color: ppmColor(stream.ppm))
                metric("Drop", "\(stream.dropped)", unit: nil,
                       width: Self.droppedWidth,
                       color: stream.dropped > 0 ? .orange : .primary)
            }
            .padding(.leading, 13)
        }
    }

    private func metric(_ label: String, _ value: String, unit: String?, width: CGFloat, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(unit.map { "\(label) (\($0))" } ?? label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(width: width, alignment: .leading)
    }

    private func rateText(_ hz: Double?) -> String {
        guard let hz, hz.isFinite else { return "—" }
        if hz >= 100 { return String(format: "%.0f", hz) }
        if hz >= 1 { return String(format: "%.1f", hz) }
        return String(format: "%.3f", hz)
    }

    private func ppmText(_ ppm: Double?) -> String {
        guard let ppm, ppm.isFinite else { return "—" }
        return String(format: "%+.0f", ppm)
    }

    private func ppmColor(_ ppm: Double?) -> Color {
        guard let ppm, ppm.isFinite else { return .primary }
        let magnitude = abs(ppm)
        if magnitude >= 200 { return .red }
        if magnitude >= 100 { return .orange }
        return .primary
    }
}

private struct FirmwareUpgradePopover: View {
    @ObservedObject var bridge: BridgeClient

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Firmware Update")
                .font(.headline)

            if let progress = bridge.upgradeProgress {
                progressContent(progress)
            } else if bridge.availableUpgrades.isEmpty {
                Text("No firmware updates available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bridge.availableUpgrades) { upgrade in
                    availableRow(upgrade)
                    if upgrade.id != bridge.availableUpgrades.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    @ViewBuilder
    private func availableRow(_ upgrade: FirmwareUpgrade) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(upgrade.deviceName)
                .font(.subheadline.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("Installed").foregroundStyle(.secondary)
                    Text(upgrade.currentVersion).monospacedDigit()
                }
                GridRow {
                    Text("New").foregroundStyle(.secondary)
                    Text("\(upgrade.newVersion) (\(upgrade.newHash))")
                        .monospacedDigit()
                        .foregroundStyle(.green)
                }
            }
            .font(.caption)

            Button {
                bridge.performUpgrade(route: upgrade.route)
            } label: {
                Label("Update firmware", systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func progressContent(_ progress: FirmwareUpgradeProgress) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                switch progress.phase {
                case .complete:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .error:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                default:
                    ProgressView().controlSize(.small)
                }
                Text(progress.message ?? phaseTitle(progress.phase))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if progress.phase == .uploading, let chunk = progress.chunk, let total = progress.total {
                ProgressView(value: Double(chunk), total: Double(max(total, 1)))
                Text("\(chunk) / \(total) chunks")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if !progress.phase.isTerminal {
                ProgressView(value: progress.fraction ?? 0)
                    .opacity(progress.fraction == nil ? 0.4 : 1)
            }

            if progress.phase == .finalizing {
                Text("Do not disconnect the device.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if progress.phase.isTerminal {
                Button("Done") { bridge.clearUpgradeProgress() }
                    .frame(maxWidth: .infinity)
                    .controlSize(.large)
            }
        }
    }

    private func phaseTitle(_ phase: FirmwareUpgradePhase) -> String {
        switch phase {
        case .starting: return "Preparing…"
        case .downloading: return "Downloading firmware…"
        case .stopping: return "Stopping device…"
        case .stopped: return "Device stopped"
        case .uploading: return "Uploading firmware…"
        case .committing: return "Committing…"
        case .finalizing: return "Finalizing…"
        case .complete: return "Upgrade complete"
        case .error: return "Upgrade failed"
        case .unknown: return "Working…"
        }
    }
}

private struct ConnectionProgressPanel: View {
    let progress: ConnectionProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if progress.canCancel {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: progress.phase == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(progress.phase == .failed ? .red : .green)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.phaseTitle)
                        .font(.headline)
                    Text(progress.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 7) {
                ConnectionProgressRow(
                    title: "Link",
                    detail: progress.didEstablishLink ? "Sensor connection established" : progress.deviceURL,
                    state: linkState
                )
                ConnectionProgressRow(
                    title: "Stream Metadata",
                    detail: progress.didLoadMetadata
                        ? "\(progress.streamCount) \(plural("stream", progress.streamCount)), \(progress.streamColumnCount) \(plural("column", progress.streamColumnCount))"
                        : "Waiting for stream metadata",
                    state: metadataState
                )
                ConnectionProgressRow(
                    title: "Settings Metadata",
                    detail: progress.didLoadMetadata
                        ? "\(progress.rpcCount) \(plural("setting", progress.rpcCount))"
                        : "Waiting for RPC metadata",
                    state: metadataState
                )
                ConnectionProgressRow(
                    title: "Command Replies",
                    detail: commandReplyDetail,
                    state: commandReplyState
                )
                ConnectionProgressRow(
                    title: "Stream Data",
                    detail: streamDataDetail,
                    state: streamDataState
                )
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var linkState: ConnectionProgressRowState {
        if progress.phase == .failed { return .failed }
        if progress.didEstablishLink { return .complete }
        return progress.canCancel ? .active : .waiting
    }

    private var metadataState: ConnectionProgressRowState {
        if progress.phase == .failed { return .failed }
        if progress.didLoadMetadata { return .complete }
        return progress.canCancel ? .active : .waiting
    }

    private var commandReplyState: ConnectionProgressRowState {
        if progress.phase == .failed { return .failed }
        if progress.didReceiveRPCReply { return .complete }
        if progress.didLoadMetadata && progress.readableRPCCount == 0 { return .skipped }
        return progress.didLoadMetadata ? .active : .waiting
    }

    private var streamDataState: ConnectionProgressRowState {
        if progress.phase == .failed { return .failed }
        if progress.didReceiveStreamValues { return .complete }
        if progress.didLoadMetadata && progress.streamColumnCount == 0 { return .skipped }
        return progress.phase == .streaming ? .active : .waiting
    }

    private var commandReplyDetail: String {
        if progress.didLoadMetadata && progress.readableRPCCount == 0 {
            return "Metadata command returned; no readable settings to probe"
        }
        var detail = "\(progress.rpcReplyCount)/\(progress.readableRPCCount) \(plural("reply", progress.rpcReplyCount))"
        if progress.rpcFailureCount > 0 {
            detail += ", \(progress.rpcFailureCount) failed"
        }
        return detail
    }

    private var streamDataDetail: String {
        if progress.didLoadMetadata && progress.streamColumnCount == 0 {
            return "No stream columns advertised"
        }
        if progress.streamValueCount > 0 {
            return "\(progress.streamValueCount) live \(plural("value", progress.streamValueCount))"
        }
        return "Waiting for live stream values"
    }

    private func plural(_ word: String, _ count: Int) -> String {
        count == 1 ? word : "\(word)s"
    }
}

private struct ConnectionProgressRow: View {
    let title: String
    let detail: String
    let state: ConnectionProgressRowState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: state.systemImage)
                .font(.caption)
                .foregroundStyle(state.color)
                .frame(width: 14)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

private struct DevicePickerURLInlineRow: View {
    @Binding var draft: String
    let initialURL: String
    let commitTitle: String
    let routes: [AvailableDeviceRoute]
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var isURLFieldFocused: Bool
    @State private var isExpanded = false
    private static let editorLineHeight: CGFloat = 20

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                toggleExpanded()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Single device URL" : "Connect several devices at once")

            VStack(alignment: .leading, spacing: 4) {
                if isExpanded {
                    multiURLEditor
                } else {
                    TextField("tcp://localhost", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .twinleafDeviceURLTextInput()
                        .focused($isURLFieldFocused)
                        .onSubmit(commit)
                }

                if !routes.isEmpty {
                    DeviceRouteList(routes: routes)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)

            Button {
                commit()
            } label: {
                Label(commitTitle, systemImage: "checkmark")
            }
            .labelStyle(.iconOnly)
            .twinleafDevicePickerButtonStyle(.icon)
            .keyboardShortcut(.defaultAction)
            .disabled(trimmedDraft.isEmpty || trimmedDraft == initialURL)
            .help(commitTitle)

            Button {
                onCancel()
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .twinleafDevicePickerButtonStyle(.icon)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .twinleafDevicePickerInlineRowStyle()
        .onAppear {
            if draftURLs.count > 1 {
                isExpanded = true
                draft = draftURLs.joined(separator: "\n")
            }
            DispatchQueue.main.async {
                isURLFieldFocused = true
            }
        }
    }

    /// Multi-line editor with a /0, /1, ... gutter: one URL per line, each
    /// line labeled with the route the sensor will be mounted at.
    private var multiURLEditor: some View {
        let lines = draft.components(separatedBy: "\n")
        var urlIndex = 0
        let gutter = lines
            .map { line -> String in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return " " }
                defer { urlIndex += 1 }
                return "/\(urlIndex)"
            }
            .joined(separator: "\n")
        let lineCount = max(2, min(lines.count + 1, 6))

        return HStack(alignment: .top, spacing: 6) {
            Text(gutter)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineSpacing(Self.editorLineSpacing)
                .padding(.top, 8)
            TextEditor(text: $draft)
                .font(.callout.monospaced())
                .lineSpacing(Self.editorLineSpacing)
                .twinleafDeviceURLTextInput()
                .focused($isURLFieldFocused)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: CGFloat(lineCount) * Self.editorLineHeight + 16)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.background)
                        .stroke(.separator, lineWidth: 1)
                )
        }
    }

    private static let editorLineSpacing: CGFloat = 2

    private func toggleExpanded() {
        if isExpanded {
            // Collapse: back to a single line, URLs space-separated.
            draft = draftURLs.joined(separator: " ")
            isExpanded = false
        } else {
            // Expand: one URL per line so the gutter shows the /N mounts.
            let urls = draftURLs
            draft = urls.isEmpty ? "" : urls.joined(separator: "\n")
            isExpanded = true
        }
    }

    private var draftURLs: [String] {
        draft.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    private var trimmedDraft: String {
        // Normalize any space/newline-delimited list to single-space form,
        // which is the canonical stored representation.
        draftURLs.joined(separator: " ")
    }

    private func commit() {
        guard !trimmedDraft.isEmpty else { return }
        onCommit(trimmedDraft)
    }
}

private struct DevicePickerRow: View {
    let device: AvailableDevice
    let isSelected: Bool
    let onSelect: () -> Void
    let onConnect: () -> Void
    let onEdit: (() -> Void)?
    let onForget: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if device.kind == "remembered" {
                    // Remembered entries are just URLs: show the URL as the
                    // primary line, with known connected devices below. A
                    // multi-sensor entry lists each URL with its /N mount.
                    let urls = device.url.split(separator: " ").map(String.init)
                    if urls.count > 1 {
                        ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("/\(index)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(url)
                                    .font(.callout.monospaced().weight(.semibold))
                            }
                        }
                    } else {
                        Text(device.url)
                            .font(.callout.monospaced().weight(.semibold))
                    }
                } else {
                    Text(device.label)
                        .font(.headline)
                    Text(device.url)
                        .font(.callout.monospaced())
                    Text(device.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !device.routes.isEmpty {
                    DeviceRouteList(routes: device.routes)
                        .padding(.top, 2)
                }
            }

            Spacer()

            if device.kind == "remembered" {
                Button {
                    onEdit?()
                } label: {
                    Label("Edit URL", systemImage: "pencil")
                }
                .labelStyle(.iconOnly)
                .twinleafDevicePickerButtonStyle(.icon)
                .help("Edit URL")
                .disabled(onEdit == nil)

                Button(role: .destructive) {
                    onForget()
                } label: {
                    Label("Forget URL", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .twinleafDevicePickerButtonStyle(.destructive)
                .help("Forget URL")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
        .twinleafDevicePickerRowSelectionStyle(isSelected: isSelected)
        .onTapGesture {
            onSelect()
        }
        .onTapGesture(count: 2) {
            onConnect()
        }
    }
}

private struct DeviceRouteList: View {
    let routes: [AvailableDeviceRoute]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(routes) { route in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(route.isRoot ? "/" : route.route)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(route.displayName)
                        .font(.caption)
                        .foregroundStyle(route.isRoot ? .secondary : .primary)
                        .lineLimit(1)
                }
                .padding(.leading, CGFloat(route.depth) * 12)
            }
        }
    }
}

private struct StreamSidebar: View {
    @ObservedObject var bridge: BridgeClient
    let rpcFocusRequest: Int
    let activeSliderIDs: Set<String>
    let onToggleSlider: (RpcInfo) -> Void
    let onCaptureRPC: (RpcInfo) -> Void
    let onOpenPlotWindow: (([ColumnKey]) -> Void)?
    let onOpenSliderWindow: ((RpcInfo) -> Void)?
    let onOpenCaptureWindow: ((RpcInfo) -> Void)?
    let focusedField: FocusState<RpcFocusField?>.Binding
    /// Whether to show the "View Graph" shortcut row — true only when the plot
    /// isn't already visible (compact layout showing the sidebar). Decided by
    /// the container at the scene root.
    let showsGraphShortcut: Bool
    /// Invoked when the user taps the "View Graph" row. The container flips
    /// `preferredCompactColumn` to `.detail` so the plot pane takes over.
    let onShowGraph: () -> Void
    @AppStorage(ViewPreferenceKeys.showStreamDetails) private var showStreamDetails = false
    @AppStorage(ViewPreferenceKeys.unifySensors) private var unifySensors = false
    @State private var sidebarSearchText = ""
    @State private var isSidebarSearchPresented = false
    @State private var expandedStreamIDs: Set<String> = []
    @State private var isApplyingExpandedStreamLayout = false
    @State private var restoredExpandedStreamDeviceSignature = ""
    @AppStorage(ViewPreferenceKeys.boardViewLayouts) private var boardViewLayoutsRaw = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            SidebarLogoWatermark()
                .allowsHitTesting(false)

            streamContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            restoreExpandedStreamLayoutsForCurrentDevices()
            focusSidebarSearchIfRequested()
        }
        .onChange(of: rpcFocusRequest) { _, _ in
            focusSidebarSearchIfRequested()
        }
        .onChange(of: bridge.devices) { _, _ in
            restoreExpandedStreamLayoutsForCurrentDevices()
        }
        .onChange(of: expandedStreamIDs) { _, _ in
            saveExpandedStreamLayoutsForCurrentDevices()
        }
    }

    @ViewBuilder
    private var streamContent: some View {
        if bridge.devices.isEmpty {
            ContentUnavailableView("No Streams", systemImage: "waveform", description: Text("Connect a Twinleaf device to list streams."))
                .padding()
        } else {
            List {
                if showsGraphShortcut {
                    Button(action: onShowGraph) {
                        HStack(spacing: 10) {
                            Image(systemName: "chart.xyaxis.line")
                                .foregroundStyle(.tint)
                            Text("View Graph")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                }

                if !visibleStreamGroups.isEmpty || sidebarSearchQuery.isEmpty {
                    Section {
                        ForEach(streamDeviceEntries) { entry in
                            switch entry {
                            case .single(let device):
                                singleDeviceStreamRows(device: device)
                            case .unified(let name, let devices):
                                UnifiedDeviceSectionHeader(name: name, devices: devices)
                                    .listRowInsets(denseDeviceHeaderRowInsets)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)

                                unifiedStreamRows(groupName: name, devices: devices)
                            }
                        }
                    }
                    header: {
                        SidebarGroupHeader(title: "Streams", systemImage: "waveform")
                    }
                    .listSectionSeparator(.hidden)
                }

                SettingsSidebarSections(
                    bridge: bridge,
                    searchText: sidebarSearchText,
                    activeSliderIDs: activeSliderIDs,
                    onToggleSlider: onToggleSlider,
                    onCaptureRPC: onCaptureRPC,
                    onOpenSliderWindow: onOpenSliderWindow,
                    onOpenCaptureWindow: onOpenCaptureWindow,
                    focusedField: focusedField
                )
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 16)
            .searchable(
                text: $sidebarSearchText,
                isPresented: $isSidebarSearchPresented,
                placement: .sidebar,
                prompt: "Search Streams and Settings"
            )
            .searchFocused(focusedField, equals: .search)
        }
    }

    private var sidebarSearchQuery: String {
        sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var visibleStreamGroups: [StreamSidebarDeviceGroup] {
        bridge.devices.compactMap { device in
            let rows = streamRows(for: device).filter { matchesStream($0.stream, device: device) }
            guard !rows.isEmpty else { return nil }
            return StreamSidebarDeviceGroup(device: device, rows: rows)
        }
    }

    private var streamDeviceEntries: [SidebarDeviceEntry] {
        sidebarDeviceEntries(visibleStreamGroups.map(\.device), unify: unifySensors)
    }

    @ViewBuilder
    private func singleDeviceStreamRows(device: DeviceInfo) -> some View {
        if let group = visibleStreamGroups.first(where: { $0.device.id == device.id }) {
            DeviceSectionHeader(device: group.device)
                .listRowInsets(denseDeviceHeaderRowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            ForEach(group.rows) { row in
                StreamHeaderRow(
                    stream: row.stream,
                    showDetails: showStreamDetails,
                    isExpanded: expansionBinding(for: row.id),
                    bridge: bridge,
                    plotState: plotState(for: row.stream.columns.map(\.key)),
                    onOpenPlotWindow: onOpenPlotWindow
                )
                .listRowInsets(denseSidebarRowInsets)

                if expandedStreamIDs.contains(row.id) {
                    if row.stream.columns.isEmpty {
                        StreamMetadataUnavailableRow(stream: row.stream)
                            .padding(.leading, streamChildRowLeadingPadding)
                            .listRowInsets(denseSidebarRowInsets)
                    } else {
                        ForEach(row.stream.columns) { column in
                            StreamColumnRow(
                                column: column,
                                showDetails: showStreamDetails,
                                bridge: bridge,
                                plotState: plotState(for: [column.key]),
                                onOpenPlotWindow: onOpenPlotWindow
                            )
                            .equatable()
                            .padding(.leading, streamChildRowLeadingPadding)
                            .listRowInsets(denseSidebarRowInsets)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func unifiedStreamRows(groupName: String, devices: [DeviceInfo]) -> some View {
        let firstRows = visibleStreamGroups.first { $0.device.id == devices.first?.id }?.rows ?? []
        ForEach(firstRows) { row in
            let rowID = "unified:\(groupName)#\(row.stream.streamId)"
            let allKeys = unifiedStreamKeys(streamId: row.stream.streamId, devices: devices)

            StreamHeaderRow(
                stream: row.stream,
                showDetails: showStreamDetails,
                isExpanded: expansionBinding(for: rowID),
                bridge: bridge,
                plotState: plotState(for: allKeys),
                onOpenPlotWindow: onOpenPlotWindow,
                plotKeysOverride: allKeys
            )
            .listRowInsets(denseSidebarRowInsets)

            if expandedStreamIDs.contains(rowID) {
                if row.stream.columns.isEmpty {
                    StreamMetadataUnavailableRow(stream: row.stream)
                        .padding(.leading, streamChildRowLeadingPadding)
                        .listRowInsets(denseSidebarRowInsets)
                } else {
                    ForEach(row.stream.columns) { column in
                        unifiedColumnCaption(column: column, devices: devices)
                            .padding(.leading, streamChildRowLeadingPadding)
                            .listRowInsets(denseSidebarRowInsets)

                        ForEach(devices) { device in
                            if let deviceColumn = deviceColumn(
                                device,
                                streamId: row.stream.streamId,
                                columnIndex: column.key.columnIndex
                            ) {
                                StreamColumnRow(
                                    column: deviceColumn,
                                    showDetails: showStreamDetails,
                                    bridge: bridge,
                                    plotState: plotState(for: [deviceColumn.key]),
                                    onOpenPlotWindow: onOpenPlotWindow,
                                    labelOverride: unifiedDeviceKeyLabel(device)
                                )
                                .equatable()
                                .padding(.leading, streamChildRowLeadingPadding * 2)
                                .listRowInsets(denseSidebarRowInsets)
                            }
                        }
                    }
                }
            }
        }
    }

    private func unifiedColumnCaption(column: ColumnInfo, devices: [DeviceInfo]) -> some View {
        let keys = devices.compactMap { device in
            deviceColumn(device, streamId: column.key.streamId, columnIndex: column.key.columnIndex)?.key
        }
        let state = plotState(for: keys)
        return Button {
            bridge.toggleColumnsInLowestPlot(keys)
        } label: {
            Text(column.description.isEmpty ? column.name : column.description)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(state.isPlottedInAnyPlot ? Color.accentColor : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .plotColumnDragSource(keys: keys)
        .help("Plot \(column.name) from all sensors in the lowest graph")
    }

    private func deviceColumn(_ device: DeviceInfo, streamId: UInt8, columnIndex: Int) -> ColumnInfo? {
        device.streams
            .first { $0.streamId == streamId }?
            .columns
            .first { $0.key.columnIndex == columnIndex }
    }

    private func unifiedStreamKeys(streamId: UInt8, devices: [DeviceInfo]) -> [ColumnKey] {
        devices.flatMap { device in
            device.streams.first { $0.streamId == streamId }?.columns.map(\.key) ?? []
        }
    }

    private var allStreamIDs: Set<String> {
        Set(bridge.devices.flatMap { device in
            streamRows(for: device).map(\.id)
        })
    }

    private var currentStreamExpansionDeviceSignature: String {
        bridge.devices
            .map { device in
                let streamIDs = device.streams.map(\.streamId).sorted().map(String.init).joined(separator: ",")
                return "\(BoardViewLayoutStore.boardKey(for: device))#\(device.route)#\(streamIDs)"
            }
            .sorted()
            .joined(separator: "|")
    }

    private func streamRows(for device: DeviceInfo) -> [StreamSidebarItem] {
        device.streams.map { stream in
            StreamSidebarItem(
                id: streamID(device: device, stream: stream),
                stream: stream
            )
        }
    }

    private func streamID(device: DeviceInfo, stream: StreamInfo) -> String {
        "\(device.id)#stream-\(stream.streamId)"
    }

    private func restoreExpandedStreamLayoutsForCurrentDevices() {
        let signature = currentStreamExpansionDeviceSignature
        guard !signature.isEmpty else {
            restoredExpandedStreamDeviceSignature = signature
            return
        }
        guard signature != restoredExpandedStreamDeviceSignature else { return }

        let store = BoardViewLayoutStore(rawValue: boardViewLayoutsRaw)
        var nextExpandedStreamIDs: Set<String> = []

        for device in bridge.devices {
            let rows = streamRows(for: device)
            let key = BoardViewLayoutStore.boardKey(for: device)
            guard let expandedStreams = store.boards[key]?.expandedStreams else {
                nextExpandedStreamIDs.formUnion(rows.map(\.id))
                continue
            }

            let expandedStreamIDs = Set(expandedStreams.map(\.streamId))
            for row in rows where expandedStreamIDs.contains(row.stream.streamId) {
                nextExpandedStreamIDs.insert(row.id)
            }
        }

        isApplyingExpandedStreamLayout = true
        restoredExpandedStreamDeviceSignature = signature
        expandedStreamIDs = nextExpandedStreamIDs
        isApplyingExpandedStreamLayout = false
    }

    private func saveExpandedStreamLayoutsForCurrentDevices() {
        guard !isApplyingExpandedStreamLayout else { return }
        let signature = currentStreamExpansionDeviceSignature
        guard !signature.isEmpty,
              signature == restoredExpandedStreamDeviceSignature else {
            return
        }

        var store = BoardViewLayoutStore(rawValue: boardViewLayoutsRaw)
        for device in bridge.devices {
            let key = BoardViewLayoutStore.boardKey(for: device)
            var layout = store.boards[key] ?? BoardViewLayout()
            layout.expandedStreams = streamRows(for: device)
                .filter { expandedStreamIDs.contains($0.id) }
                .map { BoardStreamReference(streamId: $0.stream.streamId) }
            store.boards[key] = layout
        }
        boardViewLayoutsRaw = store.rawValue
    }

    private func matchesStream(_ stream: StreamInfo, device: DeviceInfo) -> Bool {
        let query = sidebarSearchQuery
        guard !query.isEmpty else { return true }
        return streamSearchText(for: stream, device: device).contains(query)
    }

    private func streamSearchText(for stream: StreamInfo, device: DeviceInfo) -> String {
        let columns = stream.columns.flatMap { column in
            [
                column.name,
                column.description,
                column.units,
                column.dataType
            ]
        }

        return ([
            stream.name,
            String(stream.streamId),
            String(stream.effectiveSamplingRate),
            device.route,
            device.meta.name,
            device.meta.serialNumber
        ] + columns)
        .joined(separator: " ")
        .lowercased()
    }

    private func plotState(for keys: [ColumnKey]) -> StreamPlotRowState {
        let normalizedKeys = normalizedPlotKeys(keys)
        let panes = bridge.plotPanes
        let entries = panes.enumerated().map { index, pane in
            StreamPlotMenuEntry(
                id: pane.id,
                index: index,
                isSelected: areColumns(normalizedKeys, selectedIn: pane)
            )
        }

        return StreamPlotRowState(
            paneEntries: entries,
            isSelectedInLowestPlot: panes.last.map { areColumns(normalizedKeys, selectedIn: $0) } ?? false,
            isPlottedInAnyPlot: entries.contains(where: \.isSelected),
            canAddPlotPane: bridge.canAddPlotPane
        )
    }

    private func normalizedPlotKeys(_ keys: [ColumnKey]) -> [ColumnKey] {
        Array(Set(keys))
            .sorted()
            .prefix(BridgeClient.maxPlotLineCount)
            .map { $0 }
    }

    private func areColumns(_ keys: [ColumnKey], selectedIn pane: PlotPaneSelection) -> Bool {
        !keys.isEmpty && keys.allSatisfy { pane.columns.contains($0) }
    }

    private func matchesSetting(_ rpc: RpcInfo, device: DeviceInfo) -> Bool {
        let query = sidebarSearchQuery
        guard !query.isEmpty else { return true }
        return settingSearchText(for: rpc, device: device).contains(query)
    }

    private func focusSidebarSearchIfRequested() {
        guard rpcFocusRequest > 0 else { return }
        DispatchQueue.main.async {
            focusSidebarSearch()
        }
    }

    private func focusSidebarSearch() {
        isSidebarSearchPresented = true
        focusedField.wrappedValue = .search
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedStreamIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedStreamIDs.insert(id)
                } else {
                    expandedStreamIDs.remove(id)
                }
            }
        )
    }

}

private struct StreamSidebarDeviceGroup: Identifiable {
    var id: String { device.id }
    let device: DeviceInfo
    let rows: [StreamSidebarItem]
}

private let denseSidebarRowInsets = EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 6)
private let denseDeviceHeaderRowInsets = EdgeInsets(top: 6, leading: 8, bottom: 1, trailing: 8)
private let denseRPCRowInsets = EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8)
private let denseLogRowInsets = EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8)

private struct SidebarGroupHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .textCase(nil)
    }
}

private struct SidebarLogoWatermark: View {
    var body: some View {
        Image("TwinleafLogoBW")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(.secondary)
            .opacity(0.16)
            .frame(maxWidth: 150)
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 18)
    }
}

private struct StreamSidebarItem: Identifiable {
    let id: String
    let stream: StreamInfo
}

private struct StreamPlotMenuEntry: Identifiable, Equatable {
    let id: Int
    let index: Int
    let isSelected: Bool
}

private struct StreamPlotRowState: Equatable {
    let paneEntries: [StreamPlotMenuEntry]
    let isSelectedInLowestPlot: Bool
    let isPlottedInAnyPlot: Bool
    let canAddPlotPane: Bool
}

private struct StreamHeaderRow: View {
    let stream: StreamInfo
    let showDetails: Bool
    @Binding var isExpanded: Bool
    let bridge: BridgeClient
    let plotState: StreamPlotRowState
    let onOpenPlotWindow: (([ColumnKey]) -> Void)?
    /// Unify mode: plot/drag keys spanning every sensor in the group rather
    /// than just this stream's own device.
    var plotKeysOverride: [ColumnKey]? = nil

    var body: some View {
        SidebarValueRowLayout() {
            headerContent
            Color.clear
                .frame(width: streamValueColumnWidth, height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(helpText)
    }

    private var headerContent: some View {
        HStack(spacing: 8) {
            disclosureButton

            streamNameControl
                .frame(minWidth: sidebarInlineLabelMinimumWidth, alignment: .leading)
        }
    }

    private var disclosureButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 18, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide stream columns" : "Show stream columns")
    }

    private var streamNameControl: some View {
        Button {
            bridge.toggleColumnsInLowestPlot(plotKeys)
        } label: {
            labelContent
        }
        .buttonStyle(.plain)
        .disabled(plotKeys.isEmpty)
        .plotColumnDragSource(keys: plotKeys)
        .contextMenu {
            streamPlotMenu
        }
    }

    private var labelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(stream.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(plotState.isPlottedInAnyPlot ? Color.accentColor : Color.primary)
            if showDetails {
                Text("\(NumericDisplayPolicy.fixed(stream.effectiveSamplingRate, fractionDigits: 0)) Hz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var plotKeys: [ColumnKey] {
        plotKeysOverride ?? stream.columns.map(\.key)
    }

    @ViewBuilder
    private var streamPlotMenu: some View {
        if !plotState.paneEntries.isEmpty {
            ForEach(plotState.paneEntries) { entry in
                Button {
                    bridge.setColumns(plotKeys, in: entry.id, enabled: !entry.isSelected)
                } label: {
                    if entry.isSelected {
                        Label("Plot \(entry.index + 1)", systemImage: "checkmark")
                    } else {
                        Text("Plot \(entry.index + 1)")
                    }
                }
                .disabled(plotKeys.isEmpty)
            }

            Divider()
        }

        Button {
            bridge.addPlotPane(columns: plotKeys)
        } label: {
            Label("New Plot", systemImage: "plus")
        }
        .disabled(plotKeys.isEmpty || !plotState.canAddPlotPane)

        if let onOpenPlotWindow {
            Divider()

            Button {
                onOpenPlotWindow(plotKeys)
            } label: {
                Label("Open in Window", systemImage: "arrow.up.right.square")
            }
            .disabled(plotKeys.isEmpty || !plotState.canAddPlotPane)
        }
    }

    private var isSelectedInLowestPlot: Bool {
        plotState.isSelectedInLowestPlot
    }

    private var helpText: String {
        if plotKeys.isEmpty {
            return "No columns available to plot"
        }
        let verb = isSelectedInLowestPlot ? "Remove" : "Plot"
        return "\(verb) all columns in \(stream.name) in the lowest graph"
    }
}

private struct StreamMetadataUnavailableRow: View {
    let stream: StreamInfo

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var message: String {
        guard stream.nColumns > 0 else {
            return "No columns"
        }
        return "Column metadata unavailable (\(stream.nColumns) expected)"
    }
}

private struct StreamColumnRow: View, @MainActor Equatable {
    let column: ColumnInfo
    let showDetails: Bool
    let bridge: BridgeClient
    let plotState: StreamPlotRowState
    let onOpenPlotWindow: (([ColumnKey]) -> Void)?
    /// Unify mode: label per-device value rows by sensor route/serial instead
    /// of repeating the column name.
    var labelOverride: String? = nil

    static func == (lhs: StreamColumnRow, rhs: StreamColumnRow) -> Bool {
        lhs.column == rhs.column
            && lhs.showDetails == rhs.showDetails
            && lhs.plotState == rhs.plotState
            && lhs.labelOverride == rhs.labelOverride
    }

    var body: some View {
        SidebarValueRowLayout() {
            labelContent
            valueContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            bridge.toggleColumnsInLowestPlot([column.key])
        }
        .plotColumnDragSource(keys: [column.key])
        .contextMenu {
            columnPlotMenu
        }
        .help(helpText)
    }

    private var labelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(labelOverride ?? (column.description.isEmpty ? column.name : column.description))
                .lineLimit(1)
                .truncationMode(labelOverride == nil ? .tail : .middle)
                .foregroundStyle(plotState.isPlottedInAnyPlot ? Color.accentColor : Color.primary)

            if showDetails {
                Text(streamDetailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var valueContent: some View {
        Text(displayValue)
            .font(.body.monospacedDigit())
            .foregroundStyle(column.displayValue == nil ? .secondary : .primary)
            .lineLimit(1)
            .frame(width: streamValueColumnWidth, alignment: .trailing)
    }

    private var displayValue: String {
        let value = formatStreamValue(column.displayValue)
        if column.units.isEmpty {
            return value
        }
        return "\(value) \(column.units)"
    }

    private var streamDetailText: String {
        if column.units.isEmpty {
            return column.dataType
        }
        return "\(column.dataType) \(column.units)"
    }

    @ViewBuilder
    private var columnPlotMenu: some View {
        if !plotState.paneEntries.isEmpty {
            ForEach(plotState.paneEntries) { entry in
                Button {
                    bridge.setColumns(plotKeys, in: entry.id, enabled: !entry.isSelected)
                } label: {
                    if entry.isSelected {
                        Label("Plot \(entry.index + 1)", systemImage: "checkmark")
                    } else {
                        Text("Plot \(entry.index + 1)")
                    }
                }
            }

            Divider()
        }

        Button {
            bridge.addPlotPane(columns: plotKeys)
        } label: {
            Label("New Plot", systemImage: "plus")
        }
        .disabled(!plotState.canAddPlotPane)

        if let onOpenPlotWindow {
            Divider()

            Button {
                onOpenPlotWindow(plotKeys)
            } label: {
                Label("Open in Window", systemImage: "arrow.up.right.square")
            }
            .disabled(!plotState.canAddPlotPane)
        }
    }

    private var plotKeys: [ColumnKey] {
        [column.key]
    }

    private var isSelectedInLowestPlot: Bool {
        plotState.isSelectedInLowestPlot
    }

    private var helpText: String {
        let label = column.description.isEmpty ? column.name : column.description
        let verb = isSelectedInLowestPlot ? "Remove" : "Plot"
        return "\(verb) \(label) in the lowest graph"
    }
}

private let streamValueColumnWidth: CGFloat = 96
private let sidebarInlineLabelMinimumWidth: CGFloat = 96
private let streamChildRowLeadingPadding: CGFloat = 20

private struct SidebarValueRowLayout: Layout {
    var labelMinimumWidth: CGFloat = sidebarInlineLabelMinimumWidth
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count >= 2 else { return .zero }

        let availableWidth = proposal.width ?? .infinity
        let controlSize = subviews[1].sizeThatFits(.unspecified)
        if usesHorizontalLayout(width: availableWidth, controlWidth: controlSize.width) {
            let labelWidth = max(labelMinimumWidth, availableWidth - horizontalSpacing - controlSize.width)
            let labelSize = subviews[0].sizeThatFits(ProposedViewSize(width: labelWidth, height: proposal.height))
            let width = proposal.width ?? labelSize.width + horizontalSpacing + controlSize.width
            return CGSize(width: width, height: max(labelSize.height, controlSize.height))
        }

        let labelSize = subviews[0].sizeThatFits(ProposedViewSize(width: availableWidth, height: proposal.height))
        let width = proposal.width ?? max(labelSize.width, controlSize.width)
        return CGSize(width: width, height: labelSize.height + verticalSpacing + controlSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }

        let controlSize = subviews[1].sizeThatFits(.unspecified)
        if usesHorizontalLayout(width: bounds.width, controlWidth: controlSize.width) {
            let labelWidth = max(labelMinimumWidth, bounds.width - horizontalSpacing - controlSize.width)
            let labelSize = subviews[0].sizeThatFits(ProposedViewSize(width: labelWidth, height: bounds.height))
            let labelY = bounds.minY + max(0, (bounds.height - labelSize.height) / 2)
            let controlY = bounds.minY + max(0, (bounds.height - controlSize.height) / 2)

            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: labelY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: labelWidth, height: labelSize.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX - controlSize.width, y: controlY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: controlSize.width, height: controlSize.height)
            )
        } else {
            let labelSize = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: labelSize.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX - controlSize.width, y: bounds.minY + labelSize.height + verticalSpacing),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: controlSize.width, height: controlSize.height)
            )
        }
    }

    private func usesHorizontalLayout(width: CGFloat, controlWidth: CGFloat) -> Bool {
        guard width.isFinite else { return true }
        return width >= labelMinimumWidth + horizontalSpacing + controlWidth
    }
}

private struct DeviceSectionHeader: View {
    let device: DeviceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(device.meta.name.isEmpty ? device.route : device.meta.name)
                .font(.subheadline.weight(.semibold))
            if !device.meta.serialNumber.isEmpty {
                Text(device.meta.serialNumber)
                    .font(.caption2)
                    .textCase(nil)
            }
        }
    }
}

// MARK: - Unify mode

/// One entry in the sidebar's device list: either a lone device rendered as
/// today, or several same-type sensors folded into one unified group.
private enum SidebarDeviceEntry: Identifiable {
    case single(DeviceInfo)
    case unified(name: String, devices: [DeviceInfo])

    var id: String {
        switch self {
        case .single(let device):
            return "single:\(device.id)"
        case .unified(let name, _):
            return "unified:\(name)"
        }
    }
}

/// Group same-type sensors (matching `meta.name`) when unify mode is on.
/// Groups appear at the position of their first member; devices with no name
/// or no same-type sibling stay as singles.
private func sidebarDeviceEntries(_ devices: [DeviceInfo], unify: Bool) -> [SidebarDeviceEntry] {
    guard unify else { return devices.map { .single($0) } }

    var counts: [String: Int] = [:]
    for device in devices where !device.meta.name.isEmpty {
        counts[device.meta.name, default: 0] += 1
    }

    var emitted: Set<String> = []
    var entries: [SidebarDeviceEntry] = []
    for device in devices {
        let name = device.meta.name
        if name.isEmpty || counts[name, default: 0] < 2 {
            entries.append(.single(device))
        } else if emitted.insert(name).inserted {
            entries.append(.unified(
                name: name,
                devices: devices.filter { $0.meta.name == name }
            ))
        }
    }
    return entries
}

/// Short identifier for one sensor inside a unified group: route plus serial.
private func unifiedDeviceKeyLabel(_ device: DeviceInfo) -> String {
    let route = device.route.isEmpty ? "/" : device.route
    if device.meta.serialNumber.isEmpty {
        return route
    }
    return "\(route) · \(device.meta.serialNumber)"
}

private struct UnifiedDeviceSectionHeader: View {
    let name: String
    let devices: [DeviceInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.subheadline.weight(.semibold))
            }
            Text(devices.map(unifiedDeviceKeyLabel).joined(separator: "   "))
                .font(.caption2)
                .textCase(nil)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct BoardViewLayoutStore: Codable {
    var boards: [String: BoardViewLayout] = [:]

    init() {}

    init(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            self.init()
            return
        }
        self = decoded
    }

    var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    static func boardKey(for device: DeviceInfo) -> String {
        let candidates = [device.meta.name, device.route, device.url]
        for candidate in candidates {
            let key = normalizedBoardKey(candidate)
            if !key.isEmpty {
                return key
            }
        }
        return "unknown"
    }

    private static func normalizedBoardKey(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}

private struct BoardViewLayout: Codable, Equatable {
    var panes: [BoardPlotPaneLayout] = []
    var sliders: [BoardRPCSliderLayout] = []
    var expandedStreams: [BoardStreamReference]? = nil
}

private struct BoardPlotPaneLayout: Codable, Equatable {
    var columns: [BoardColumnReference]
    var mode: PlotMode
    var axisMode: VerticalAxisMode
    var showsIndependentAxisLabels: Bool
}

private struct BoardColumnReference: Codable, Hashable {
    var streamId: UInt8
    var columnIndex: Int
}

private struct BoardStreamReference: Codable, Hashable {
    var streamId: UInt8
}

private struct BoardRPCSliderLayout: Codable, Equatable {
    var name: String
    var minimum: Double
    var maximum: Double
    var maximumRPCName: String?
    var maximumEdited: Bool
    var isExpanded: Bool

    init(
        name: String,
        minimum: Double,
        maximum: Double,
        maximumRPCName: String?,
        maximumEdited: Bool,
        isExpanded: Bool
    ) {
        self.name = name
        self.minimum = minimum
        self.maximum = maximum
        self.maximumRPCName = maximumRPCName
        self.maximumEdited = maximumEdited
        self.isExpanded = isExpanded
    }

    init(_ slider: RPCSliderConfiguration) {
        self.init(
            name: slider.name,
            minimum: slider.minimum,
            maximum: slider.maximum,
            maximumRPCName: slider.maximumRPCName,
            maximumEdited: slider.maximumEdited,
            isExpanded: slider.isExpanded
        )
    }

    var validMinimum: Double {
        minimum.isFinite ? minimum : 0
    }

    var validMaximum: Double {
        maximum.isFinite && maximum > validMinimum ? maximum : validMinimum + 1
    }
}

private struct RestoredBoardPlotPane {
    var request: PlotPaneRestoreRequest
    var axisMode: VerticalAxisMode
    var showsIndependentAxisLabels: Bool
}

private struct RPCSliderConfiguration: Identifiable, Hashable {
    var id: String { "\(route)#\(name)" }
    let route: String
    let name: String
    var minimum: Double
    var maximum: Double
    var maximumRPCName: String?
    var maximumEdited = false
    var isExpanded = true
}

private struct RPCSliderTray: View {
    @ObservedObject var bridge: BridgeClient
    @Binding var sliders: [RPCSliderConfiguration]
    let onOpenSliderWindow: ((RPCSliderConfiguration) -> Void)?
    let focusedField: FocusState<RpcFocusField?>.Binding

    var body: some View {
        VStack(spacing: 6) {
            ForEach($sliders) { $slider in
                RPCSliderControlRow(
                    bridge: bridge,
                    slider: $slider,
                    onRemove: { removeSlider(id: slider.id) },
                    onOpenWindow: onOpenSliderWindow.map { open in
                        { open(slider) }
                    },
                    focusedField: focusedField
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func removeSlider(id: String) {
        sliders.removeAll { $0.id == id }
    }
}

private struct RPCSliderControlRow: View {
    @ObservedObject var bridge: BridgeClient
    @Binding var slider: RPCSliderConfiguration
    let onRemove: (() -> Void)?
    let onOpenWindow: (() -> Void)?
    let focusedField: FocusState<RpcFocusField?>.Binding

    @AppStorage(ViewPreferenceKeys.rpcFloatPrecisionPPM) private var rpcFloatPrecisionPPM = NumericDisplayPolicy.defaultRPCFloatPrecisionPPM
    @AppStorage(ViewPreferenceKeys.rpcSliderRateLimitHz) private var rpcSliderRateLimitHz = RPCSliderRateLimit.defaultHz
    @State private var draftValue: Double?
    @State private var valueDraftText = ""
    @State private var committedValueText = ""
    @State private var valueSelection: TextSelection?
    @State private var pendingValueStepCaretOffset: Int?
    @State private var pendingValueStepRestoreUntil = Date.distantPast
    @State private var observedRPCValueRevision: UInt64 = 0
    @State private var isEditing = false
    @State private var didMoveSliderDuringEditing = false
    @State private var lastSentAt = Date.distantPast
    @State private var pendingSendWorkItem: DispatchWorkItem?
    @State private var minimumDraftText = ""
    @State private var maximumDraftText = ""
    @FocusState private var isValueFieldFocused: Bool
    @FocusState private var focusedBoundsField: BoundsField?

    private enum BoundsField {
        case minimum
        case maximum
    }
    private let sliderBoundFieldWidth: CGFloat = 76
    private let sliderValueFieldWidth: CGFloat = 118

    var body: some View {
        if let rpc = bridge.rpc(id: slider.id) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(rpc.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contextMenu {
                            sliderNameMenu
                        }

                    Spacer(minLength: 12)

                    if let onRemove {
                        Button(action: onRemove) {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove setting slider")
                    }
                }

                sliderControl(for: rpc)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 0) {
                    TextField("Min", text: $minimumDraftText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: sliderBoundFieldWidth)
                        .focused($focusedBoundsField, equals: .minimum)
                        .onSubmit(commitMinimumDraft)
                        .help("Minimum slider value")

                    Spacer(minLength: 8)

                    valueField(for: rpc)
                        .frame(width: sliderValueFieldWidth)

                    Spacer(minLength: 8)

                    TextField("Max", text: $maximumDraftText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: sliderBoundFieldWidth)
                        .focused($focusedBoundsField, equals: .maximum)
                        .onSubmit(commitMaximumDraft)
                        .help("Maximum slider value")
                }
            }
            .frame(maxWidth: .infinity)
            .onAppear {
                observedRPCValueRevision = bridge.rpcValueRevision(id: rpc.id)
                refreshMaximumRPC()
                syncValueDraft(for: rpc, force: true)
                syncBoundsDrafts()
            }
            .onDisappear {
                pendingSendWorkItem?.cancel()
            }
            .onChange(of: isValueFieldFocused) { oldValue, newValue in
                guard oldValue, !newValue else { return }
                updateValueDraftIfChanged(for: latestRPC(fallback: rpc))
            }
            .onChange(of: focusedBoundsField) { oldValue, newValue in
                // Commit on focus loss; never coerce mid-edit.
                if oldValue == .minimum, newValue != .minimum {
                    commitMinimumDraft()
                }
                if oldValue == .maximum, newValue != .maximum {
                    commitMaximumDraft()
                }
            }
            .onChange(of: slider) { _, _ in
                syncBoundsDrafts()
            }
            .onChange(of: rpc.value) { _, newValue in
                if newValue != nil {
                    syncValueDraft(for: latestRPC(fallback: rpc))
                }
            }
            .onChange(of: bridge.rpcValueChangeToken) { _, _ in
                syncValueDraftIfRPCValueChanged()
                // The slider maximum can follow a device-reported `<name>.max`
                // RPC; refresh the Max draft when that value arrives.
                syncBoundsDrafts()
            }
            .onChange(of: rpcFloatPrecisionPPM) { _, _ in
                let latest = latestRPC(fallback: rpc)
                guard latest.value != nil,
                      !isValueFieldFocused else { return }
                syncValueDraft(for: latest)
            }
        }
    }

    @ViewBuilder
    private var sliderNameMenu: some View {
        if let onOpenWindow {
            Button {
                onOpenWindow()
            } label: {
                Label("Open in Window", systemImage: "arrow.up.right.square")
            }
        }

        if let onRemove {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove Slider", systemImage: "xmark.circle")
            }
        }
    }

    private func valueField(for rpc: RpcInfo) -> some View {
        TextField("Value", text: $valueDraftText, selection: $valueSelection)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($isValueFieldFocused)
            .focused(focusedField, equals: .slider(slider.id))
            .onSubmit {
                updateValueDraft(for: latestRPC(fallback: rpc))
            }
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                guard !press.modifiers.contains(.shift),
                      !press.modifiers.contains(.option),
                      !press.modifiers.contains(.control),
                      !press.modifiers.contains(.command) else {
                    return .ignored
                }
                return stepValueDraft(
                    direction: press.key == .upArrow ? 1 : -1,
                    for: latestRPC(fallback: rpc)
                )
            }
            .help("Setting value")
    }

    /// Refresh both bounds drafts from the model, leaving whichever field the
    /// user is actively editing untouched so external updates (or the other
    /// field's coercion) never rewrite text mid-edit.
    private func syncBoundsDrafts() {
        if focusedBoundsField != .minimum {
            minimumDraftText = formatBoundsValue(slider.minimum)
        }
        if focusedBoundsField != .maximum {
            maximumDraftText = formatBoundsValue(effectiveMaximum)
        }
    }

    private func commitMinimumDraft() {
        defer { syncBoundsDrafts() }
        guard let value = parseBoundsValue(minimumDraftText), value.isFinite else {
            minimumDraftText = formatBoundsValue(slider.minimum)
            return
        }
        slider.minimum = value
        if effectiveMaximum <= value {
            slider.maximum = value + 1
            slider.maximumEdited = true
        }
    }

    private func commitMaximumDraft() {
        defer { syncBoundsDrafts() }
        guard let value = parseBoundsValue(maximumDraftText), value.isFinite else {
            maximumDraftText = formatBoundsValue(effectiveMaximum)
            return
        }
        slider.maximum = value
        slider.maximumEdited = true
    }

    private func formatBoundsValue(_ value: Double) -> String {
        value.formatted(.number.grouping(.never))
    }

    private func parseBoundsValue(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = try? Double(trimmed, format: .number) {
            return value
        }
        return Double(trimmed)
    }

    private var effectiveMaximum: Double {
        if !slider.maximumEdited,
           let maximumRPCName = slider.maximumRPCName,
           let value = bridge.rpc(route: slider.route, name: maximumRPCName)?.value?.numberValue,
           value.isFinite,
           value > slider.minimum {
            return value
        }

        guard slider.maximum.isFinite, slider.maximum > slider.minimum else {
            return slider.minimum + 1
        }
        return slider.maximum
    }

    private var sliderRange: ClosedRange<Double> {
        slider.minimum...effectiveMaximum
    }

    @ViewBuilder
    private func sliderControl(for rpc: RpcInfo) -> some View {
        RPCValueSlider(
            value: sliderValueBinding(for: rpc),
            range: sliderRange,
            step: rpc.isIntegerRPC ? 1 : nil,
            labelFormatter: { sliderTickLabel($0, for: rpc) },
            onEditingChanged: { editing in
                handleEditingChanged(editing, for: rpc)
            }
        )
        .frame(height: SliderTrackMetrics.frameHeight)
    }

    private func sliderValueBinding(for rpc: RpcInfo) -> Binding<Double> {
        Binding(
            get: {
                clampedSliderValue(for: rpc)
            },
            set: { value in
                let normalized = normalizedSliderValue(value, for: rpc)
                let previousDraft = draftValue ?? clampedSliderValue(for: rpc)
                draftValue = normalized
                guard abs(normalized - previousDraft) > sliderMovementEpsilon else {
                    return
                }
                didMoveSliderDuringEditing = true
                sendRPCValue(normalized, for: rpc)
            }
        )
    }

    private func handleEditingChanged(_ editing: Bool, for rpc: RpcInfo) {
        isEditing = editing
        if editing {
            draftValue = clampedSliderValue(for: rpc)
            didMoveSliderDuringEditing = false
        } else {
            if didMoveSliderDuringEditing {
                let value = draftValue ?? clampedSliderValue(for: rpc)
                sendRPCValue(value, for: rpc, force: true)
            }
            draftValue = nil
            didMoveSliderDuringEditing = false
        }
    }

    private func clampedSliderValue(for rpc: RpcInfo) -> Double {
        clamp(currentValue(for: rpc), to: sliderRange)
    }

    private func currentValue(for rpc: RpcInfo) -> Double {
        let activeDraft = isEditing ? draftValue : nil
        return activeDraft ?? rpc.value?.numberValue ?? slider.minimum
    }

    private func normalizedSliderValue(_ value: Double, for rpc: RpcInfo) -> Double {
        typedRPCValue(clamp(value, to: sliderRange), for: rpc)
    }

    private var sliderMovementEpsilon: Double {
        max(1e-12, abs(effectiveMaximum - slider.minimum) * 1e-12)
    }

    private func sliderTickLabel(_ value: Double, for rpc: RpcInfo) -> String {
        if rpc.isIntegerRPC {
            return String(format: "%.0f", value.rounded())
        }
        return NumericDisplayPolicy.significant(value, maximumDigits: 4)
    }

    private func typedRPCValue(_ value: Double, for rpc: RpcInfo) -> Double {
        if rpc.isUnsignedIntegerRPC {
            return max(0, value.rounded())
        }
        if rpc.isIntegerRPC {
            return value.rounded()
        }
        return value
    }

    private func latestRPC(fallback rpc: RpcInfo) -> RpcInfo {
        bridge.rpc(id: slider.id) ?? rpc
    }

    private func syncValueDraftToLatestRPC() {
        guard let rpc = bridge.rpc(id: slider.id) else { return }
        syncValueDraft(for: rpc)
    }

    private func syncValueDraftIfRPCValueChanged() {
        let revision = bridge.rpcValueRevision(id: slider.id)
        guard revision != observedRPCValueRevision else { return }
        observedRPCValueRevision = revision
        syncValueDraftToLatestRPC()
    }

    private func syncValueDraft(for rpc: RpcInfo, force: Bool = false) {
        guard force || rpc.value?.numberValue != nil || isEditing else { return }

        let newText = displayValue(for: rpc)
        committedValueText = newText
        let shouldRestoreStepFocus = pendingValueStepCaretOffset != nil
            && Date() <= pendingValueStepRestoreUntil
            && isValueFieldFocused
        if newText != valueDraftText {
            valueDraftText = newText
            if shouldRestoreStepFocus {
                restoreValueFieldFocus()
            } else {
                valueSelection = nil
            }
        } else if shouldRestoreStepFocus {
            restoreValueFieldFocus()
        }
    }

    private func updateValueDraft(for rpc: RpcInfo) {
        guard rpc.writable else { return }
        committedValueText = valueDraftText
        bridge.callRpc(rpc, argumentText: valueDraftText)
    }

    private func updateValueDraftIfChanged(for rpc: RpcInfo) {
        guard rpc.writable,
              valueDraftText != committedValueText else { return }
        updateValueDraft(for: rpc)
    }

    private func stepValueDraft(direction: Int, for rpc: RpcInfo) -> KeyPress.Result {
        guard rpc.writable,
              let stepped = RPCNumericStepper.step(
                valueDraftText,
                selection: valueSelection,
                direction: direction,
                fixedFractionDigits: rpc.isIntegerRPC ? nil : 3
              ) else {
            return .ignored
        }

        valueDraftText = stepped.text
        committedValueText = stepped.text
        valueSelection = stepped.selection
        pendingValueStepCaretOffset = stepped.caretOffset
        pendingValueStepRestoreUntil = Date().addingTimeInterval(5)
        bridge.callRpc(rpc, argumentText: stepped.text)
        restoreValueFieldFocus()
        return .handled
    }

    private func sendRPCValue(_ value: Double, for rpc: RpcInfo, force: Bool = false) {
        bridge.previewRpcValue(rpc, argumentText: argumentText(value, for: rpc))
        guard rpc.writable else { return }
        if force {
            pendingSendWorkItem?.cancel()
            pendingSendWorkItem = nil
            sendRPCValueNow(value, for: rpc)
            return
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastSentAt)
        let interval = rateLimitInterval
        if elapsed < interval {
            scheduleRPCValue(value, for: rpc, after: interval - elapsed)
            return
        }

        pendingSendWorkItem?.cancel()
        pendingSendWorkItem = nil
        sendRPCValueNow(value, for: rpc)
    }

    private func scheduleRPCValue(_ value: Double, for rpc: RpcInfo, after delay: TimeInterval) {
        pendingSendWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            sendRPCValueNow(value, for: rpc)
            pendingSendWorkItem = nil
        }
        pendingSendWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func sendRPCValueNow(_ value: Double, for rpc: RpcInfo) {
        let now = Date()
        lastSentAt = now
        bridge.callRpc(rpc, argumentText: argumentText(value, for: rpc), optimisticallyUpdate: false)
    }

    private var rateLimitInterval: TimeInterval {
        1 / clampedRPCSliderRateLimitHz(rpcSliderRateLimitHz)
    }

    private func argumentText(_ value: Double, for rpc: RpcInfo) -> String {
        if rpc.isUnsignedIntegerRPC {
            return String(format: "%.0f", max(0, value.rounded()))
        }
        if rpc.isIntegerRPC {
            return String(format: "%.0f", value.rounded())
        }
        return String(format: "%.17g", value)
    }

    private func displayValue(for rpc: RpcInfo) -> String {
        let value = currentValue(for: rpc)
        return displayText(value, for: rpc)
    }

    private func displayText(_ value: Double, for rpc: RpcInfo) -> String {
        if rpc.isIntegerRPC {
            return String(format: "%.0f", value.rounded())
        }
        return fixedRPCFloatText(value)
    }

    private func restoreValueFieldFocus() {
        guard let pendingValueStepCaretOffset,
              Date() <= pendingValueStepRestoreUntil else {
            return
        }

        applyValueFieldFocus(caretOffset: pendingValueStepCaretOffset)

        DispatchQueue.main.async {
            applyValueFieldFocus(caretOffset: pendingValueStepCaretOffset)
        }
    }

    private func applyValueFieldFocus(caretOffset: Int) {
        let offset = min(max(0, caretOffset), valueDraftText.count)
        let index = valueDraftText.index(valueDraftText.startIndex, offsetBy: offset)
        isValueFieldFocused = true
        valueSelection = TextSelection(insertionPoint: index)
    }

    private func refreshMaximumRPC() {
        guard let maximumRPCName = slider.maximumRPCName,
              let maximumRPC = bridge.rpc(route: slider.route, name: maximumRPCName),
              maximumRPC.readable else {
            return
        }
        bridge.callRpc(maximumRPC)
    }
}

private struct SliderTickMark: Identifiable, Hashable {
    enum Kind: Hashable {
        case major
        case minor
    }

    let value: Double
    let label: String?
    let kind: Kind

    var id: String {
        "\(kind)-\(value)"
    }
}

private struct RPCValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double?
    let labelFormatter: (Double) -> String
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let metrics = SliderTrackMetrics(width: geometry.size.width)
            let ticks = sliderTicks(trackWidth: metrics.trackWidth)

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.26))
                    .frame(width: metrics.trackWidth, height: 3)
                    .position(x: metrics.trackMidX, y: metrics.trackY)

                ForEach(ticks) { tick in
                    Rectangle()
                        .fill(tick.kind == .major ? Color.secondary.opacity(0.5) : Color.secondary.opacity(0.28))
                        .frame(width: 1, height: tick.kind == .major ? 6 : 3)
                        .position(x: metrics.x(for: tick.value, in: range), y: metrics.tickY)
                }

                ForEach(ticks.filter { $0.label != nil }) { tick in
                    Text(tick.label ?? "")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(
                            width: metrics.labelWidth,
                            alignment: metrics.labelAlignment(for: tick.value, in: range)
                        )
                        .position(
                            x: metrics.labelFrameX(for: tick.value, in: range),
                            y: metrics.labelY
                        )
                }

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: metrics.thumbDiameter, height: metrics.thumbDiameter)
                    .overlay {
                        Circle()
                            .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.14), radius: 1.5, x: 0, y: 1)
                    .position(x: metrics.x(for: value, in: range), y: metrics.trackY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        value = snappedValue(at: drag.location.x, metrics: metrics)
                    }
                    .onEnded { drag in
                        value = snappedValue(at: drag.location.x, metrics: metrics)
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Setting slider")
        .accessibilityValue(labelFormatter(value))
    }

    private func snappedValue(at x: CGFloat, metrics: SliderTrackMetrics) -> Double {
        let fraction = metrics.fraction(for: x)
        let rawValue = range.lowerBound + (range.upperBound - range.lowerBound) * fraction
        let steppedValue: Double
        if let step, step > 0 {
            steppedValue = (rawValue / step).rounded() * step
        } else {
            steppedValue = rawValue
        }
        return clamp(steppedValue, to: range)
    }

    private func sliderTicks(trackWidth: CGFloat) -> [SliderTickMark] {
        let lower = range.lowerBound
        let upper = range.upperBound
        let span = upper - lower
        guard trackWidth > 0, span.isFinite, span > 0 else { return [] }

        let targetMajorSegments = targetMajorSegmentCount(trackWidth: trackWidth)
        let majorStep = niceTickStep(span / Double(targetMajorSegments))
        let majorValues = majorTickValues(step: majorStep)
        let minorValues = minorTickValues(majorStep: majorStep, trackWidth: trackWidth)
        let majorSet = majorValues.reduce(into: [Double]()) { result, value in
            result.append(value)
        }

        var ticks = minorValues.compactMap { value -> SliderTickMark? in
            guard !majorSet.contains(where: { approximatelyEqual($0, value, tolerance: majorStep * 1e-6) }) else {
                return nil
            }
            return SliderTickMark(value: value, label: nil, kind: .minor)
        }

        let labeledMajorValues = labels(for: majorValues, trackWidth: trackWidth)
        ticks += majorValues.map { value in
            SliderTickMark(
                value: value,
                label: labeledMajorValues[value],
                kind: .major
            )
        }

        return ticks.sorted { lhs, rhs in
            if approximatelyEqual(lhs.value, rhs.value, tolerance: span * 1e-10) {
                return lhs.kind == .minor && rhs.kind == .major
            }
            return lhs.value < rhs.value
        }
    }

    private func majorTickValues(step: Double) -> [Double] {
        let lower = range.lowerBound
        let upper = range.upperBound
        guard step.isFinite, step > 0 else { return [lower, upper] }

        var values = [lower, upper]
        if lower < 0, upper > 0 {
            values.append(0)
        }

        let first = ceil(lower / step) * step
        var value = first
        var iteration = 0
        while value <= upper + step * 1e-6 && iteration < 1000 {
            if value >= lower - step * 1e-6 {
                values.append(normalizedZero(value))
            }
            value += step
            iteration += 1
        }

        return uniqueSorted(values, tolerance: step * 1e-6)
    }

    private func minorTickValues(majorStep: Double, trackWidth: CGFloat) -> [Double] {
        let lower = range.lowerBound
        let upper = range.upperBound
        let span = upper - lower
        guard majorStep.isFinite, majorStep > 0, span > 0 else { return [] }

        let subdivisions = [10.0, 5.0, 4.0, 2.0].first { subdivision in
            let tickSpacing = trackWidth * CGFloat((majorStep / subdivision) / span)
            return tickSpacing >= minimumMinorTickSpacing(trackWidth: trackWidth)
        }
        guard let subdivisions else { return [] }

        let minorStep = majorStep / subdivisions
        let first = ceil(lower / minorStep) * minorStep
        var values: [Double] = []
        var value = first
        var iteration = 0
        while value <= upper + minorStep * 1e-6 && iteration < 4000 {
            if value >= lower - minorStep * 1e-6 {
                values.append(normalizedZero(value))
            }
            value += minorStep
            iteration += 1
        }
        return uniqueSorted(values, tolerance: minorStep * 1e-6)
    }

    private func labels(for values: [Double], trackWidth: CGFloat) -> [Double: String] {
        let minimumSpacing = minimumLabelSpacing(trackWidth: trackWidth)
        let metrics = SliderTrackMetrics(width: trackWidth + SliderTrackMetrics.horizontalInset * 2)
        var result: [Double: String] = [:]
        var lastLabelX = -CGFloat.infinity
        var seenLabels: Set<String> = []

        for value in values {
            let label = labelFormatter(value)
            let x = metrics.x(for: value, in: range)
            guard x - lastLabelX >= minimumSpacing || result.isEmpty else { continue }
            guard seenLabels.insert(label).inserted else { continue }
            result[value] = label
            lastLabelX = x
        }

        if let last = values.last,
           result[last] == nil {
            let label = labelFormatter(last)
            if seenLabels.insert(label).inserted {
                result[last] = label
            }
        }

        return result
    }

    private func targetMajorSegmentCount(trackWidth: CGFloat) -> Int {
        let targetSpacing: CGFloat
        switch trackWidth {
        case ..<360:
            targetSpacing = 74
        case ..<720:
            targetSpacing = 62
        default:
            targetSpacing = 52
        }
        return max(1, min(36, Int((trackWidth / targetSpacing).rounded())))
    }

    private func minimumMinorTickSpacing(trackWidth: CGFloat) -> CGFloat {
        switch trackWidth {
        case ..<360:
            return 8
        case ..<720:
            return 7
        default:
            return 5
        }
    }

    private func minimumLabelSpacing(trackWidth: CGFloat) -> CGFloat {
        switch trackWidth {
        case ..<360:
            return 56
        case ..<720:
            return 50
        default:
            return 44
        }
    }

    private func niceTickStep(_ rawStep: Double) -> Double {
        guard rawStep.isFinite, rawStep > 0 else { return 1 }
        let exponent = floor(log10(rawStep))
        let magnitude = pow(10, exponent)
        let normalized = rawStep / magnitude
        let nice: Double
        switch normalized {
        case ...1:
            nice = 1
        case ...2:
            nice = 2
        case ...5:
            nice = 5
        default:
            nice = 10
        }
        return nice * magnitude
    }

    private func normalizedZero(_ value: Double) -> Double {
        abs(value) < 1e-12 ? 0 : value
    }

    private func uniqueSorted(_ values: [Double], tolerance: Double) -> [Double] {
        values
            .filter { $0.isFinite }
            .sorted()
            .reduce(into: [Double]()) { result, value in
                guard !result.contains(where: { approximatelyEqual($0, value, tolerance: tolerance) }) else {
                    return
                }
                result.append(value)
            }
    }

    private func approximatelyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double) -> Bool {
        abs(lhs - rhs) <= max(tolerance, 1e-12)
    }
}

private struct SliderTrackMetrics {
    static let horizontalInset: CGFloat = 8
    /// Total slider control height. Larger on iOS so the thumb and the
    /// drag/tap area meet Apple's 44pt touch-target guidance comfortably.
#if os(iOS)
    static let frameHeight: CGFloat = 56
#else
    static let frameHeight: CGFloat = 42
#endif
    let width: CGFloat

    var horizontalInset: CGFloat {
        Self.horizontalInset
    }

    var thumbDiameter: CGFloat {
#if os(iOS)
        return 28
#else
        return 14
#endif
    }

    var trackWidth: CGFloat {
        max(1, width - horizontalInset * 2)
    }

    var trackMidX: CGFloat {
        horizontalInset + trackWidth / 2
    }

    var trackY: CGFloat {
#if os(iOS)
        return 16
#else
        return 11
#endif
    }

    var tickY: CGFloat {
#if os(iOS)
        return 32
#else
        return 22
#endif
    }

    var labelY: CGFloat {
#if os(iOS)
        return 46
#else
        return 34
#endif
    }

    var labelWidth: CGFloat {
        48
    }

    func x(for value: Double, in range: ClosedRange<Double>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span.isFinite, span > 0 else { return horizontalInset }
        let fraction = CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
        return horizontalInset + trackWidth * fraction
    }

    func labelFrameX(for value: Double, in range: ClosedRange<Double>) -> CGFloat {
        let rawX = x(for: value, in: range)
        let halfLabelWidth = labelWidth / 2
        if rawX <= horizontalInset + 0.5 {
            return min(width - halfLabelWidth, rawX + halfLabelWidth)
        }
        if rawX >= horizontalInset + trackWidth - 0.5 {
            return max(halfLabelWidth, rawX - halfLabelWidth)
        }
        return min(max(rawX, halfLabelWidth), max(halfLabelWidth, width - halfLabelWidth))
    }

    func labelAlignment(for value: Double, in range: ClosedRange<Double>) -> Alignment {
        let rawX = x(for: value, in: range)
        if rawX <= horizontalInset + 0.5 {
            return .leading
        }
        if rawX >= horizontalInset + trackWidth - 0.5 {
            return .trailing
        }
        return .center
    }

    func fraction(for x: CGFloat) -> Double {
        guard trackWidth > 0 else { return 0 }
        return Double(min(max((x - horizontalInset) / trackWidth, 0), 1))
    }
}

private struct LogMessageHeader: View {
    @ObservedObject var bridge: BridgeClient

    var body: some View {
        HStack(spacing: 8) {
            Label("Log", systemImage: "text.alignleft")
                .font(.headline)

            Spacer()

            Text("\(bridge.logMessages.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                bridge.clearLogMessages()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(bridge.logMessages.isEmpty)
            .help("Clear log messages")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .textCase(nil)
    }
}

private struct LogMessageRow: View {
    let message: LogMessage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(logMessageTime(message.timestampSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)

            Text(message.route)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 52, alignment: .leading)

            Text(message.message)
                .font(.caption2)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LogSidebar: View {
    @ObservedObject var bridge: BridgeClient

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LogMessageHeader(bridge: bridge)

            if bridge.logMessages.isEmpty {
                ContentUnavailableView(
                    "No Log Messages",
                    systemImage: "text.alignleft",
                    description: Text("TIO stream log messages will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(bridge.logMessages.reversed())) { message in
                        LogMessageRow(message: message)
                            .listRowInsets(denseLogRowInsets)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 24)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
    }
}

private struct SettingsSidebarSections: View {
    @ObservedObject var bridge: BridgeClient
    let searchText: String
    let activeSliderIDs: Set<String>
    let onToggleSlider: (RpcInfo) -> Void
    let onCaptureRPC: (RpcInfo) -> Void
    let onOpenSliderWindow: ((RpcInfo) -> Void)?
    let onOpenCaptureWindow: ((RpcInfo) -> Void)?
    let focusedField: FocusState<RpcFocusField?>.Binding
    @AppStorage(ViewPreferenceKeys.showRPCDetails) private var showRPCDetails = false
    @AppStorage(ViewPreferenceKeys.favoriteRPCs) private var favoriteRPCsRaw = ""
    @AppStorage(ViewPreferenceKeys.unifySensors) private var unifySensors = false

    @ViewBuilder
    var body: some View {
        if shouldShowSettingsSection {
            rpcContent
                .preference(key: EditableSettingIDsKey.self, value: editableRPCIDs)
        } else {
            Color.clear
                .frame(height: 0)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .preference(key: EditableSettingIDsKey.self, value: [])
        }
    }

    private var rpcHeader: some View {
        HStack {
            SidebarGroupHeader(title: "Settings", systemImage: "gearshape")

            Spacer()

            if bridge.rpcCacheNeedsReload {
                Button {
                    bridge.reloadAllRPCs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(!canReloadRPCs)
                .help(canReloadRPCs ? "Reload all readable setting values" : "No readable settings to reload")
            }
        }
    }

    private var canReloadRPCs: Bool {
        !bridge.isInspectionMode
            && bridge.devices.flatMap(\.rpcs).contains { $0.readable && $0.hasMetadata && !$0.isCaptureRPC }
    }

    private var shouldShowSettingsSection: Bool {
        searchQuery.isEmpty || !visibleDevices.flatMap(\.rpcs).isEmpty
    }

    @ViewBuilder
    private var rpcContent: some View {
        Section {
            if visibleDevices.flatMap(\.rpcs).isEmpty {
                ContentUnavailableView(
                    bridge.isInspectionMode ? "Settings Unavailable" : "No Settings",
                    systemImage: "gearshape",
                    description: Text(bridge.isInspectionMode ? "Saved logs can be inspected but not queried." : "Connect a Twinleaf device to list settings.")
                )
                .frame(minHeight: 160)
                .listRowInsets(denseRPCRowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(deviceEntries) { entry in
                    switch entry {
                    case .single(let device):
                        DeviceSectionHeader(device: device)
                            .listRowInsets(denseDeviceHeaderRowInsets)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)

                        ForEach(device.rpcs) { rpc in
                            standardRow(for: rpc)
                        }
                    case .unified(let name, let devices):
                        UnifiedDeviceSectionHeader(name: name, devices: devices)
                            .listRowInsets(denseDeviceHeaderRowInsets)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)

                        unifiedRows(groupName: name, devices: devices)
                    }
                }
            }
        } header: {
            rpcHeader
        }
        .listSectionSeparator(.hidden)
    }

    @ViewBuilder
    private func standardRow(for rpc: RpcInfo, labelOverride: String? = nil, indented: Bool = false) -> some View {
        RpcRow(
            bridge: bridge,
            rpc: rpc,
            showDetails: showRPCDetails,
            isSliderActive: activeSliderIDs.contains(rpc.id),
            isFavorite: RPCFavorites.contains(rpc, in: favoriteRPCIDs),
            onToggleSlider: onToggleSlider,
            onCaptureRPC: onCaptureRPC,
            onOpenSliderWindow: onOpenSliderWindow,
            onOpenCaptureWindow: onOpenCaptureWindow,
            onToggleFavorite: toggleFavorite,
            focusedField: focusedField,
            labelOverride: labelOverride
        )
        .equatable()
        .padding(.leading, indented ? streamChildRowLeadingPadding : 0)
        .listRowInsets(denseRPCRowInsets)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func unifiedRows(groupName: String, devices: [DeviceInfo]) -> some View {
        ForEach(unifiedRPCGroups(devices: devices), id: \.id) { group in
            if group.rpcs.count < 2 || group.rpcs[0].isCaptureRPC {
                // Not unifiable (only one device has it, or capture rows act
                // per device): render plain rows labeled by sensor.
                ForEach(group.rpcs) { rpc in
                    standardRow(
                        for: rpc,
                        labelOverride: group.rpcs.count < 2
                            ? rpc.name
                            : "\(rpc.name) — \(deviceKeyLabel(for: rpc, devices: devices))"
                    )
                }
            } else {
                UnifiedRpcRow(
                    bridge: bridge,
                    groupName: groupName,
                    rpcs: group.rpcs,
                    showDetails: showRPCDetails,
                    focusedField: focusedField
                )
                .listRowInsets(denseRPCRowInsets)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                if unifiedRPCValuesDiffer(group.rpcs) {
                    ForEach(group.rpcs) { rpc in
                        standardRow(
                            for: rpc,
                            labelOverride: deviceKeyLabel(for: rpc, devices: devices),
                            indented: true
                        )
                    }
                }
            }
        }
    }

    private struct UnifiedRPCGroup: Identifiable {
        let id: String
        let rpcs: [RpcInfo]
    }

    /// Same-named RPCs across the group's devices, ordered by the first
    /// device's RPC list, with any names unique to later devices appended.
    private func unifiedRPCGroups(devices: [DeviceInfo]) -> [UnifiedRPCGroup] {
        var seen: Set<String> = []
        var groups: [UnifiedRPCGroup] = []
        for device in devices {
            for rpc in device.rpcs where seen.insert(rpc.name).inserted {
                let matching = devices.compactMap { candidate in
                    candidate.rpcs.first { $0.name == rpc.name }
                }
                groups.append(UnifiedRPCGroup(id: rpc.name, rpcs: matching))
            }
        }
        return groups
    }

    private func deviceKeyLabel(for rpc: RpcInfo, devices: [DeviceInfo]) -> String {
        guard let device = devices.first(where: { $0.route == rpc.route }) else {
            return rpc.route
        }
        return unifiedDeviceKeyLabel(device)
    }

    private var deviceEntries: [SidebarDeviceEntry] {
        sidebarDeviceEntries(visibleDevices, unify: unifySensors)
    }

    private var visibleDevices: [DeviceInfo] {
        return bridge.devices.compactMap { device in
            var visibleDevice = device
            let filteredRPCs = device.rpcs.filter { rpc in
                guard rpc.isVisibleInRPCList else { return false }
                guard !searchQuery.isEmpty else { return true }
                return settingSearchText(for: rpc, device: device).contains(searchQuery)
            }
            let favoriteRPCs = favoriteRPCIDs.reduce(into: [RpcInfo]()) { result, favoriteID in
                for rpc in filteredRPCs where RPCFavorites.matches(rpc, id: favoriteID) {
                    if !result.contains(where: { $0.id == rpc.id }) {
                        result.append(rpc)
                    }
                }
            }
            let favoriteIDs = Set(favoriteRPCs.map(\.id))
            visibleDevice.rpcs = favoriteRPCs + filteredRPCs.filter { !favoriteIDs.contains($0.id) }
            return visibleDevice.rpcs.isEmpty ? nil : visibleDevice
        }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var favoriteRPCIDs: [String] {
        RPCFavorites.ids(from: favoriteRPCsRaw)
    }

    private func toggleFavorite(_ rpc: RpcInfo) {
        if RPCFavorites.contains(rpc, in: favoriteRPCIDs) {
            favoriteRPCsRaw = RPCFavorites.rawValue(from: RPCFavorites.removing(rpc, from: favoriteRPCIDs))
        } else {
            favoriteRPCsRaw = RPCFavorites.rawValue(from: favoriteRPCIDs + [RPCFavorites.defaultID(for: rpc)])
        }
    }

    private func isEditableSetting(_ rpc: RpcInfo) -> Bool {
        rpc.writable && rpc.hasMetadata && !rpc.isActionRPC && !rpc.isCaptureRPC && !rpc.isEnableSwitchRPC
    }

    private var editableRPCIDs: [String] {
        deviceEntries.flatMap { entry -> [String] in
            switch entry {
            case .single(let device):
                return device.rpcs.filter(isEditableSetting).map(\.id)
            case .unified(let name, let devices):
                return unifiedRPCGroups(devices: devices).flatMap { group -> [String] in
                    if group.rpcs.count < 2 || group.rpcs[0].isCaptureRPC {
                        return group.rpcs.filter(isEditableSetting).map(\.id)
                    }
                    guard isEditableSetting(group.rpcs[0]) else { return [] }
                    var ids = [unifiedRPCFieldID(groupName: name, rpcName: group.rpcs[0].name)]
                    if unifiedRPCValuesDiffer(group.rpcs) {
                        ids += group.rpcs.map(\.id)
                    }
                    return ids
                }
            }
        }
    }
}

private func settingSearchText(for rpc: RpcInfo, device: DeviceInfo) -> String {
    [
        rpc.name,
        rpc.route,
        rpc.permissions,
        rpc.argType,
        device.meta.name,
        device.meta.serialNumber
    ]
    .joined(separator: " ")
    .lowercased()
}

private enum RpcFocusField: Hashable {
    case search
    case rpc(String)
    case slider(String)
}

/// Editable setting IDs in sidebar display order, published up to `DocumentWindow`
/// so it can build the Tab focus chain.
private struct EditableSettingIDsKey: PreferenceKey {
    static let defaultValue: [String] = []

    static func reduce(value: inout [String], nextValue: () -> [String]) {
        let next = nextValue()
        if !next.isEmpty {
            value = next
        }
    }
}

private let favoriteRPCTextColor = Color.green

private struct RpcRow: View, @MainActor Equatable {
    let bridge: BridgeClient
    let rpc: RpcInfo
    let showDetails: Bool
    let isSliderActive: Bool
    let isFavorite: Bool
    let onToggleSlider: (RpcInfo) -> Void
    let onCaptureRPC: (RpcInfo) -> Void
    let onOpenSliderWindow: ((RpcInfo) -> Void)?
    let onOpenCaptureWindow: ((RpcInfo) -> Void)?
    let onToggleFavorite: (RpcInfo) -> Void
    let focusedField: FocusState<RpcFocusField?>.Binding
    /// Replaces the RPC name in the row label; used by unify mode's
    /// per-device sub-rows to label rows by route/serial instead.
    var labelOverride: String? = nil

    @AppStorage(ViewPreferenceKeys.rpcFloatPrecisionPPM) private var rpcFloatPrecisionPPM = NumericDisplayPolicy.defaultRPCFloatPrecisionPPM
    @State private var argument = ""
    @State private var committedArgument = ""

    static func == (lhs: RpcRow, rhs: RpcRow) -> Bool {
        lhs.rpc == rhs.rpc
            && lhs.showDetails == rhs.showDetails
            && lhs.isSliderActive == rhs.isSliderActive
            && lhs.isFavorite == rhs.isFavorite
            && lhs.labelOverride == rhs.labelOverride
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarValueRowLayout() {
                labelContent
                    .layoutPriority(1)
                trailingControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .onAppear {
            if let value = rpc.value {
                syncArgument(with: value)
            } else {
                committedArgument = argument
            }
        }
        .onChange(of: rpc.value) { _, newValue in
            if let newValue {
                syncArgument(with: newValue)
            }
        }
        .onChange(of: focusedField.wrappedValue) { oldValue, newValue in
            guard oldValue == .rpc(rpc.id), newValue != .rpc(rpc.id) else { return }
            updateRPCIfChanged()
        }
        .onChange(of: rpcFloatPrecisionPPM) { _, _ in
            guard let value = rpc.value,
                  focusedField.wrappedValue != .rpc(rpc.id) else { return }
            syncArgument(with: value)
        }
    }

    private var labelContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            settingNameControl
            if showDetails {
                Text("\(rpc.permissions) \(rpcDisplayType)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var settingNameControl: some View {
        if rpc.isSliderSuitable {
            Button {
                onToggleSlider(rpc)
            } label: {
                settingNameText
            }
            .buttonStyle(.plain)
            .help(isSliderActive ? "Remove setting slider" : "Add setting slider")
            .contextMenu {
                settingNameMenu
            }
        } else {
            settingNameText
                .contextMenu {
                    settingNameMenu
                }
        }
    }

    private var settingNameText: some View {
        Text(labelOverride ?? rpc.name)
            .font(.body)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(settingNameColor)
    }

    private var settingNameColor: Color {
        if isFavorite {
            return favoriteRPCTextColor
        }
        if isSliderActive {
            return Color.accentColor
        }
        return Color.primary
    }

    @ViewBuilder
    private var settingNameMenu: some View {
        Button {
            bridge.callRpc(rpc)
        } label: {
            Label("Reload", systemImage: "arrow.clockwise")
        }
        .disabled(!rpc.readable)

        Button {
            onToggleFavorite(rpc)
        } label: {
            Label(isFavorite ? "Remove Favorite" : "Favorite", systemImage: isFavorite ? "star.slash" : "star")
        }

        if rpc.isSliderSuitable,
           let onOpenSliderWindow {
            Divider()

            Button {
                onOpenSliderWindow(rpc)
            } label: {
                Label("Open Slider in Window", systemImage: "arrow.up.right.square")
            }
        }

        if rpc.isCaptureRPC,
           let onOpenCaptureWindow {
            Divider()

            Button {
                onOpenCaptureWindow(rpc)
            } label: {
                Label("Open Capture in Window", systemImage: "arrow.up.right.square")
            }
        }
    }

    private var trailingControls: some View {
        rpcValueControl
    }

    @ViewBuilder
    private var rpcValueControl: some View {
        if rpc.isCaptureRPC {
            Button {
                onCaptureRPC(rpc)
            } label: {
                Text("Capture")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 108)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: 128, alignment: .trailing)
            .help("Trigger \(rpc.name)")
            .contextMenu {
                if let onOpenCaptureWindow {
                    Button {
                        onOpenCaptureWindow(rpc)
                    } label: {
                        Label("Open Capture in Window", systemImage: "arrow.up.right.square")
                    }
                }
            }
        } else if rpc.isActionRPC {
            Button {
                bridge.callRpc(rpc)
            } label: {
                Text(actionButtonTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 108)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!rpc.writable)
            .frame(width: 128, alignment: .trailing)
            .help("Run \(rpc.name)")
        } else if rpc.isEnableSwitchRPC {
            Toggle(isOn: enableBinding) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .disabled(!rpc.writable)
            .frame(width: 128, alignment: .trailing)
            .help(rpc.writable ? "Set \(rpc.name)" : "\(rpc.name) is read-only")
        } else {
            #if os(macOS)
            SteppableRPCField(
                text: $argument,
                focus: focusedField,
                focusTag: .rpc(rpc.id),
                placeholder: rpcDisplayType,
                isEnabled: rpc.writable && rpc.hasMetadata,
                fixedFractionDigits: rpc.isIntegerRPC ? nil : 3,
                onStep: commitSteppedValue,
                onCommit: updateRPC
            )
            .frame(width: 128)
            .focused(focusedField, equals: .rpc(rpc.id))
            #else
            TextField(rpcDisplayType, text: $argument)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .disabled(!rpc.writable || !rpc.hasMetadata)
                .frame(width: 128)
                .focused(focusedField, equals: .rpc(rpc.id))
                .onSubmit(updateRPC)
            #endif
        }
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: {
                enableValue
            },
            set: { isEnabled in
                guard rpc.writable else { return }
                committedArgument = enableArgumentText(isEnabled)
                argument = committedArgument
                bridge.callRpc(rpc, argumentText: committedArgument)
            }
        )
    }

    private var enableValue: Bool {
        guard let value = rpc.value else { return false }
        switch value {
        case .bool(let value):
            return value
        case .number(let value):
            return value != 0
        case .string(let value):
            return ["true", "yes", "on", "1"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default:
            return false
        }
    }

    private func enableArgumentText(_ value: Bool) -> String {
        switch rpc.baseArgType {
        case "bool", "string":
            value ? "true" : "false"
        default:
            value ? "1" : "0"
        }
    }

    private var rpcDisplayType: String {
        if rpc.isActionRPC {
            return "action"
        }
        if rpc.isCaptureRPC {
            return "capture"
        }
        if rpc.isEnableSwitchRPC {
            return "bool"
        }
        let type = rpc.argType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rpc.hasMetadata || type.isEmpty {
            return "missing"
        }
        if type == "unit" {
            return "string"
        }
        return type
    }

    private var actionButtonTitle: String {
        rpc.name
            .split(separator: ".")
            .last
            .map(String.init)
            ?? rpc.name
    }

    private func argumentText(for value: JSONValue) -> String {
        rpcArgumentDisplayText(value, rpc: rpc, floatPrecisionPPM: rpcFloatPrecisionPPM)
    }

    private func syncArgument(with value: JSONValue) {
        let newText = argumentText(for: value)
        committedArgument = newText
        guard focusedField.wrappedValue != .rpc(rpc.id) else { return }
        if newText != argument {
            argument = newText
        }
    }

    private func updateRPC() {
        guard rpc.writable, rpc.hasMetadata else { return }
        committedArgument = argument
        bridge.callRpc(rpc, argumentText: argument)
    }

    private func updateRPCIfChanged() {
        guard rpc.writable,
              rpc.hasMetadata,
              argument != committedArgument else { return }
        updateRPC()
    }

    private func commitSteppedValue(_ newText: String) {
        guard rpc.writable, rpc.hasMetadata else { return }
        committedArgument = newText
        bridge.callRpc(rpc, argumentText: newText)
    }

}

/// Whether the same-named RPCs across a unified sensor group currently report
/// different values (a nil among known values counts as differing).
private func unifiedRPCValuesDiffer(_ rpcs: [RpcInfo]) -> Bool {
    guard rpcs.count > 1 else { return false }
    if rpcs.allSatisfy({ $0.value == nil }) { return false }
    guard let first = rpcs.first?.value else { return true }
    return !rpcs.dropFirst().allSatisfy { $0.value == first }
}

/// Focus/tab identifier for a unified settings field.
private func unifiedRPCFieldID(groupName: String, rpcName: String) -> String {
    "unified:\(groupName)#\(rpcName)"
}

/// One settings row representing the same RPC across several same-type
/// sensors. When every sensor reports the same value, the row shows that
/// value once, marked with a merge icon; edits are written to all sensors.
/// When values differ, the field is empty (placeholder "mixed") and the
/// caller renders one editable sub-row per sensor below.
private struct UnifiedRpcRow: View {
    let bridge: BridgeClient
    let groupName: String
    let rpcs: [RpcInfo]
    let showDetails: Bool
    let focusedField: FocusState<RpcFocusField?>.Binding

    @AppStorage(ViewPreferenceKeys.rpcFloatPrecisionPPM) private var rpcFloatPrecisionPPM = NumericDisplayPolicy.defaultRPCFloatPrecisionPPM
    @State private var argument = ""
    @State private var committedArgument = ""

    private var primary: RpcInfo { rpcs[0] }

    private var fieldID: String {
        unifiedRPCFieldID(groupName: groupName, rpcName: primary.name)
    }

    /// The common value across all sensors, or nil when they differ or none
    /// is known yet.
    private var unifiedValue: JSONValue? {
        guard let first = primary.value,
              rpcs.dropFirst().allSatisfy({ $0.value == first }) else {
            return nil
        }
        return first
    }

    private var valuesDiffer: Bool {
        unifiedRPCValuesDiffer(rpcs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarValueRowLayout() {
                labelContent
                    .layoutPriority(1)
                trailingControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .onAppear {
            syncArgument()
        }
        .onChange(of: unifiedValue) { _, _ in
            syncArgument()
        }
        .onChange(of: focusedField.wrappedValue) { oldValue, newValue in
            guard oldValue == .rpc(fieldID), newValue != .rpc(fieldID) else { return }
            commitIfChanged()
        }
    }

    private var labelContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(primary.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .contextMenu {
                    Button {
                        reloadAll()
                    } label: {
                        Label("Reload All", systemImage: "arrow.clockwise")
                    }
                    .disabled(!primary.readable)
                }
            if showDetails {
                Text("\(primary.permissions) \(primary.argType) ×\(rpcs.count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.merge")
                .font(.caption)
                .foregroundStyle(valuesDiffer ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .help(valuesDiffer
                    ? "Sensors report different values; edit below or type here to set all"
                    : "All sensors share this value; edits apply to every sensor")

            unifiedControl
        }
    }

    @ViewBuilder
    private var unifiedControl: some View {
        if primary.isActionRPC {
            Button {
                for rpc in rpcs where rpc.writable {
                    bridge.callRpc(rpc)
                }
            } label: {
                Text(actionButtonTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 108)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!primary.writable)
            .frame(width: 128, alignment: .trailing)
            .help("Run \(primary.name) on all sensors")
        } else if primary.isEnableSwitchRPC {
            Toggle(isOn: unifiedEnableBinding) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .disabled(!primary.writable)
            .frame(width: 128, alignment: .trailing)
            .help(valuesDiffer
                ? "Sensors differ; toggling sets all sensors"
                : "Set \(primary.name) on all sensors")
        } else {
            #if os(macOS)
            SteppableRPCField(
                text: $argument,
                focus: focusedField,
                focusTag: .rpc(fieldID),
                placeholder: valuesDiffer ? "mixed" : rpcDisplayType,
                isEnabled: primary.writable && primary.hasMetadata,
                fixedFractionDigits: primary.isIntegerRPC ? nil : 3,
                onStep: { writeAll($0) },
                onCommit: commit
            )
            .frame(width: 128)
            .focused(focusedField, equals: .rpc(fieldID))
            #else
            TextField(valuesDiffer ? "mixed" : rpcDisplayType, text: $argument)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .disabled(!primary.writable || !primary.hasMetadata)
                .frame(width: 128)
                .focused(focusedField, equals: .rpc(fieldID))
                .onSubmit(commit)
            #endif
        }
    }

    private var unifiedEnableBinding: Binding<Bool> {
        Binding(
            get: {
                guard case .bool(let value)? = unifiedValue else {
                    if case .number(let value)? = unifiedValue { return value != 0 }
                    return false
                }
                return value
            },
            set: { isEnabled in
                let text: String
                switch primary.baseArgType {
                case "bool", "string":
                    text = isEnabled ? "true" : "false"
                default:
                    text = isEnabled ? "1" : "0"
                }
                writeAll(text)
            }
        )
    }

    private var rpcDisplayType: String {
        let type = primary.argType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !primary.hasMetadata || type.isEmpty {
            return "missing"
        }
        return type == "unit" ? "string" : type
    }

    private var actionButtonTitle: String {
        primary.name
            .split(separator: ".")
            .last
            .map(String.init)
            ?? primary.name
    }

    private func syncArgument() {
        let newText = unifiedValue.map {
            rpcArgumentDisplayText($0, rpc: primary, floatPrecisionPPM: rpcFloatPrecisionPPM)
        } ?? ""
        committedArgument = newText
        guard focusedField.wrappedValue != .rpc(fieldID) else { return }
        if newText != argument {
            argument = newText
        }
    }

    private func commit() {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        writeAll(argument)
    }

    private func commitIfChanged() {
        guard argument != committedArgument else { return }
        commit()
    }

    private func writeAll(_ text: String) {
        committedArgument = text
        if argument != text {
            argument = text
        }
        for rpc in rpcs where rpc.writable && rpc.hasMetadata {
            bridge.callRpc(rpc, argumentText: text)
        }
    }

    private func reloadAll() {
        for rpc in rpcs where rpc.readable {
            bridge.callRpc(rpc)
        }
    }
}

#if os(macOS)
/// AppKit-backed numeric field for the settings sidebar.
///
/// SwiftUI's `.onKeyPress` never fires for views inside a `List` on macOS, so
/// arrow-key digit stepping has to be handled at the AppKit layer. This wraps an
/// `NSTextField` and catches the field editor's `moveUp:`/`moveDown:` commands
/// directly, stepping the value in place.
private struct SteppableRPCField: NSViewRepresentable {
    @Binding var text: String
    var focus: FocusState<RpcFocusField?>.Binding
    let focusTag: RpcFocusField
    let placeholder: String
    let isEnabled: Bool
    let fixedFractionDigits: Int?
    let onStep: (String) -> Void
    let onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.isEditable = true
        field.isSelectable = true
        field.alignment = .right
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = placeholder
        field.stringValue = text
        field.isEnabled = isEnabled
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self

        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
        if field.isEnabled != isEnabled {
            field.isEnabled = isEnabled
        }
        // Never overwrite text while the user is editing.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        // SwiftUI -> AppKit focus: promote this field when it should be focused.
        // Deferred so SwiftUI's focus updates settle first; re-check at the
        // async tick to avoid stealing focus during a transition.
        if focus.wrappedValue == focusTag, field.currentEditor() == nil {
            let myTag = focusTag
            let focusRef = focus
            DispatchQueue.main.async { [weak field] in
                guard let field, field.currentEditor() == nil else { return }
                guard focusRef.wrappedValue == myTag, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SteppableRPCField

        init(_ parent: SteppableRPCField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if parent.focus.wrappedValue != parent.focusTag {
                parent.focus.wrappedValue = parent.focusTag
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Clear focus only if the field genuinely lost it (the user clicked
            // away to something untracked, or the window blurred). Deferred so
            // a focus transition that resigned this field has time to land its
            // new value before we read it — otherwise we'd clobber it.
            let myTag = parent.focusTag
            let focusRef = parent.focus
            DispatchQueue.main.async {
                if focusRef.wrappedValue == myTag {
                    focusRef.wrappedValue = nil
                }
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                return step(textView, direction: 1)
            case #selector(NSResponder.moveDown(_:)):
                return step(textView, direction: -1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                return true
            default:
                return false
            }
        }

        private func step(_ textView: NSTextView, direction: Int) -> Bool {
            guard let stepped = RPCNumericStepper.step(
                textView.string,
                caretUTF16Offset: textView.selectedRange().location,
                direction: direction,
                fixedFractionDigits: parent.fixedFractionDigits
            ) else {
                return false
            }

            textView.string = stepped.text
            let length = (stepped.text as NSString).length
            let caret = min(max(0, stepped.caretOffset), length)
            textView.setSelectedRange(NSRange(location: caret, length: 0))

            parent.text = stepped.text
            parent.onStep(stepped.text)
            return true
        }
    }
}

/// Window-level Tab interception.
///
/// The settings fields live inside a `List` and the sliders live in a separate
/// pane, so neither the AppKit key-view loop nor SwiftUI's `.onKeyPress` can give
/// an exact `search → settings → sliders` Tab order. This installs a local
/// key-down monitor that advances the shared focus through an explicit chain.
private struct TabFocusMonitor: NSViewRepresentable {
    var chain: [RpcFocusField]
    var focus: FocusState<RpcFocusField?>.Binding

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(hostView: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TabFocusMonitor
        private var monitor: Any?
        private weak var hostView: NSView?

        init(_ parent: TabFocusMonitor) {
            self.parent = parent
        }

        func install(hostView: NSView) {
            self.hostView = hostView
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.keyCode == 48 else { return event }   // Tab
            guard let window = hostView?.window,
                  window.isKeyWindow,
                  event.window === window else {
                return event
            }

            let chain = parent.chain
            guard chain.count > 1,
                  let current = parent.focus.wrappedValue,
                  let index = chain.firstIndex(of: current) else {
                return event
            }

            let backward = event.modifierFlags.contains(.shift)
            let count = chain.count
            let nextIndex = backward ? (index - 1 + count) % count : (index + 1) % count
            parent.focus.wrappedValue = chain[nextIndex]
            return nil
        }
    }
}
#endif

private struct RPCNumericStep {
    let text: String
    let selection: TextSelection
    let caretOffset: Int
}

private enum RPCNumericStepper {
    private static let numberPattern = #"[+-]?(?:(?:\d+(?:\.\d*)?)|(?:\.\d+))(?:[eE][+-]?\d+)?"#

    private enum CaretAffinity {
        case before
        case after
    }

    static func step(
        _ text: String,
        selection: TextSelection?,
        direction: Int,
        fixedFractionDigits: Int? = nil
    ) -> RPCNumericStep? {
        guard !text.isEmpty,
              let caret = caretIndex(in: text, selection: selection),
              let digitIndex = targetDigitIndex(in: text, near: caret),
              let match = numericMatch(in: text, containing: digitIndex) else {
            return nil
        }

        let token = String(text[match.range])
        let digitOffset = text.distance(from: match.range.lowerBound, to: digitIndex)
        let tokenDigitIndex = token.index(token.startIndex, offsetBy: digitOffset)
        let targetPower = mantissaPower(in: token, digitIndex: tokenDigitIndex)
        let caretAffinity = caret > digitIndex ? CaretAffinity.after : .before
        let originalCaretOffset = text.distance(
            from: match.range.lowerBound,
            to: min(max(caret, match.range.lowerBound), match.range.upperBound)
        )

        guard let newToken = steppedToken(
            token,
            digitOffset: digitOffset,
            direction: direction,
            fixedFractionDigits: fixedFractionDigits,
            powerOffset: fractionalStepPowerOffset(in: token, digitIndex: tokenDigitIndex, fixedFractionDigits: fixedFractionDigits)
        ) else {
            return nil
        }

        let prefixCount = text.distance(from: text.startIndex, to: match.range.lowerBound)
        var updated = text
        updated.replaceSubrange(match.range, with: newToken)

        let newTokenStart = updated.index(updated.startIndex, offsetBy: prefixCount)
        let newCaretOffset = targetPower.flatMap {
            caretOffset(in: newToken, matchingMantissaPower: $0, affinity: caretAffinity)
        } ?? min(originalCaretOffset, newToken.count)
        let newCaret = updated.index(newTokenStart, offsetBy: newCaretOffset, limitedBy: updated.endIndex) ?? updated.endIndex
        return RPCNumericStep(
            text: updated,
            selection: TextSelection(insertionPoint: newCaret),
            caretOffset: updated.distance(from: updated.startIndex, to: newCaret)
        )
    }

    static func step(
        _ text: String,
        caretUTF16Offset: Int,
        direction: Int,
        fixedFractionDigits: Int?
    ) -> RPCNumericStep? {
        let length = (text as NSString).length
        let clamped = min(max(0, caretUTF16Offset), length)
        guard let range = Range(NSRange(location: clamped, length: 0), in: text) else {
            return nil
        }
        return step(
            text,
            selection: TextSelection(insertionPoint: range.lowerBound),
            direction: direction,
            fixedFractionDigits: fixedFractionDigits
        )
    }

    private static func caretIndex(in text: String, selection: TextSelection?) -> String.Index? {
        guard let selection else { return text.endIndex }
        switch selection.indices {
        case .selection(let range):
            return range.lowerBound
        case .multiSelection:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func targetDigitIndex(in text: String, near caret: String.Index) -> String.Index? {
        if caret > text.startIndex {
            let previous = text.index(before: caret)
            if text[previous].isWholeNumber {
                return previous
            }
        }

        if caret < text.endIndex, text[caret].isWholeNumber {
            return caret
        }

        return nil
    }

    private static func numericMatch(in text: String, containing digitIndex: String.Index) -> (range: Range<String.Index>, nsRange: NSRange)? {
        guard let regex = try? NSRegularExpression(pattern: numberPattern) else { return nil }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let digitLocation = NSRange(digitIndex..<text.index(after: digitIndex), in: text).location

        for match in regex.matches(in: text, range: fullRange) {
            guard digitLocation >= match.range.location,
                  digitLocation < match.range.location + match.range.length,
                  let range = Range(match.range, in: text) else {
                continue
            }
            return (range, match.range)
        }

        return nil
    }

    private static func steppedToken(
        _ token: String,
        digitOffset: Int,
        direction: Int,
        fixedFractionDigits: Int?,
        powerOffset: Int
    ) -> String? {
        let digitIndex = token.index(token.startIndex, offsetBy: digitOffset)
        guard token[digitIndex].isWholeNumber else { return nil }

        if let exponentIndex = token.firstIndex(where: { $0 == "e" || $0 == "E" }),
           digitIndex > exponentIndex {
            return steppedExponentToken(token, digitIndex: digitIndex, exponentIndex: exponentIndex, direction: direction)
        }

        guard let value = Double(token),
              let rawPower = mantissaPower(in: token, digitIndex: digitIndex) else {
            return nil
        }

        let power = rawPower + powerOffset
        guard power > -308,
              power < 308 else {
            return nil
        }

        let step = pow(10.0, Double(power))
        let updatedValue = value + Double(direction) * step
        return format(updatedValue, like: token, fixedFractionDigits: fixedFractionDigits)
    }

    private static func mantissaPower(in token: String, digitIndex: String.Index) -> Int? {
        let exponentIndex = token.firstIndex { $0 == "e" || $0 == "E" }
        let mantissaEnd = exponentIndex ?? token.endIndex
        guard digitIndex < mantissaEnd else { return nil }

        let exponent = parsedExponent(in: token, exponentIndex: exponentIndex)
        if let decimalIndex = token[..<mantissaEnd].firstIndex(of: ".") {
            if digitIndex < decimalIndex {
                let digitsAfter = token[token.index(after: digitIndex)..<decimalIndex]
                    .filter(\.isWholeNumber)
                    .count
                return digitsAfter + exponent
            }

            guard digitIndex > decimalIndex else { return nil }
            let afterDecimal = token[token.index(after: decimalIndex)..<token.index(after: digitIndex)]
                .filter(\.isWholeNumber)
                .count + 1
            return -afterDecimal + exponent
        }

        let digitsAfter = token[token.index(after: digitIndex)..<mantissaEnd]
            .filter(\.isWholeNumber)
            .count
        return digitsAfter + exponent
    }

    private static func fractionalStepPowerOffset(
        in token: String,
        digitIndex: String.Index,
        fixedFractionDigits: Int?
    ) -> Int {
        guard fixedFractionDigits != nil,
              let decimalIndex = token.firstIndex(of: "."),
              digitIndex > decimalIndex else {
            return 0
        }
        return 1
    }

    private static func parsedExponent(in token: String, exponentIndex: String.Index?) -> Int {
        guard let exponentIndex else { return 0 }
        let exponentStart = token.index(after: exponentIndex)
        guard exponentStart < token.endIndex else { return 0 }
        return Int(token[exponentStart...]) ?? 0
    }

    private static func steppedExponentToken(
        _ token: String,
        digitIndex: String.Index,
        exponentIndex: String.Index,
        direction: Int
    ) -> String? {
        let exponentStart = token.index(after: exponentIndex)
        guard exponentStart < token.endIndex,
              var exponent = Int(token[exponentStart...]) else {
            return nil
        }

        let digitsAfter = token[token.index(after: digitIndex)..<token.endIndex]
            .filter(\.isWholeNumber)
            .count
        let step = integerPowerOfTen(digitsAfter)
        exponent += direction * step

        let mantissaAndMarker = token[..<exponentStart]
        if token[exponentStart] == "+", exponent >= 0 {
            return "\(mantissaAndMarker)+\(exponent)"
        }
        return "\(mantissaAndMarker)\(exponent)"
    }

    private static func integerPowerOfTen(_ exponent: Int) -> Int {
        guard exponent > 0 else { return 1 }
        return (0..<exponent).reduce(1) { value, _ in value * 10 }
    }

    private static func format(_ value: Double, like token: String, fixedFractionDigits: Int?) -> String? {
        guard value.isFinite else { return nil }

        if let fixedFractionDigits {
            let normalizedValue = normalizedZero(value, fractionDigits: fixedFractionDigits)
            return String(format: "%.\(fixedFractionDigits)f", normalizedValue)
        }

        if let exponentIndex = token.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let mantissa = token[..<exponentIndex]
            let fractionDigits = fractionalDigitCount(in: String(mantissa))
            let marker = token[exponentIndex]
            let formatted = String(format: "%.\(fractionDigits)e", value)
            return marker == "E" ? formatted.replacingOccurrences(of: "e", with: "E") : formatted
        }

        if token.contains(".") {
            return String(format: "%.\(fractionalDigitCount(in: token))f", value)
        }

        return String(format: "%.0f", value.rounded())
    }

    private static func caretOffset(
        in token: String,
        matchingMantissaPower targetPower: Int,
        affinity: CaretAffinity
    ) -> Int? {
        let exponentIndex = token.firstIndex { $0 == "e" || $0 == "E" }
        let mantissaEnd = exponentIndex ?? token.endIndex

        for index in token.indices where index < mantissaEnd && token[index].isWholeNumber {
            guard mantissaPower(in: token, digitIndex: index) == targetPower else { continue }
            let offset = token.distance(from: token.startIndex, to: index)
            return affinity == .after ? offset + 1 : offset
        }

        return nil
    }

    private static func normalizedZero(_ value: Double, fractionDigits: Int) -> Double {
        let threshold = 0.5 * pow(10.0, -Double(max(0, fractionDigits)))
        return abs(value) < threshold ? 0 : value
    }

    private static func fractionalDigitCount(in token: String) -> Int {
        guard let decimalIndex = token.firstIndex(of: ".") else { return 0 }
        let end = token.firstIndex { $0 == "e" || $0 == "E" } ?? token.endIndex
        guard decimalIndex < end else { return 0 }
        return token[token.index(after: decimalIndex)..<end]
            .filter(\.isWholeNumber)
            .count
    }
}

private struct SmokeOverlay: View {
    let fileBytes: UInt64
    let thresholdBytes: UInt64

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let threshold = max(Double(thresholdBytes), 1)
                let excess = max(0, Double(fileBytes) - threshold) / threshold
                let count = min(84, 24 + Int(excess * 24))
                let baseX = size.width * 0.74
                let baseY = size.height - 42

                for index in 0..<count {
                    let speed = 0.035 + random(index * 17 + 3) * 0.07
                    let phase = CGFloat((time * speed + random(index * 31 + 11)).truncatingRemainder(dividingBy: 1))
                    let drift = CGFloat(sin(time * (0.45 + random(index + 5)) + Double(index)) * 38)
                    let spread = (CGFloat(random(index * 47 + 19)) - 0.5) * size.width * 0.28
                    let x = baseX + spread + drift * phase
                    let y = baseY - phase * size.height * 0.72
                    let radius = 24 + CGFloat(random(index * 13 + 7) * 42) + phase * 36
                    let alpha = max(0, 0.24 * Double(1 - phase)) * min(1.0, 0.55 + excess * 0.25)
                    let rect = CGRect(
                        x: x - radius,
                        y: y - radius * 0.55,
                        width: radius * 2.2,
                        height: radius * 1.25
                    )

                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(.gray.opacity(alpha))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func random(_ seed: Int) -> Double {
        let value = sin(Double(seed) * 12.9898) * 43_758.5453
        return value - floor(value)
    }
}

private func formatFileSize(_ bytes: UInt64) -> String {
    let value = Double(bytes)
    if bytes >= 1_000_000_000 {
        return String(format: "%.2f GB", value / 1_000_000_000)
    }
    return String(format: "%.1f MB", value / 1_000_000)
}

private func formatPlaybackTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "--:--" }
    let totalSeconds = max(0, Int(seconds.rounded()))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let secs = totalSeconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

private func formatRecordingStartDate(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date(timeIntervalSince1970: seconds))
}

private func logMessageTime(_ seconds: Double) -> String {
    let totalMilliseconds = seconds.isFinite ? max(0, Int((seconds * 1_000).rounded())) : 0
    let hours = totalMilliseconds / 3_600_000
    let minutes = (totalMilliseconds / 60_000) % 60
    let seconds = (totalMilliseconds / 1_000) % 60
    let milliseconds = totalMilliseconds % 1_000
    return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
}

private func logMessageHelp(_ message: LogMessage) -> String {
    "\(logMessageTime(message.timestampSeconds)) \(message.route) \(message.message)"
}

private func formatStreamValue(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "---" }
    let absoluteValue = abs(value)
    if absoluteValue == 0 {
        return "0.000"
    }
    if NumericDisplayPolicy.usesScientificNotation(value) {
        return String(format: "%.2e", value)
    }
    if absoluteValue < 0.001 {
        return NumericDisplayPolicy.fixed(
            value,
            fractionDigits: NumericDisplayPolicy.scientificDecimalDistance
        )
    }
    return NumericDisplayPolicy.fixed(value, fractionDigits: 3)
}

private func fixedRPCFloatText(_ value: Double) -> String {
    guard value.isFinite else { return String(format: "%.3f", value) }
    let normalized = abs(value) < 0.0005 ? 0 : value
    return String(format: "%.3f", normalized)
}

/// Canonical display text for an RPC value in an editable settings field.
private func rpcArgumentDisplayText(
    _ value: JSONValue,
    rpc: RpcInfo,
    floatPrecisionPPM: Double
) -> String {
    if case .number(let number) = value,
       rpc.isNumericRPC,
       !rpc.isIntegerRPC {
        return fixedRPCFloatText(number)
    }

    return value.rpcDisplayText(
        argType: rpc.argType,
        floatPrecisionPPM: floatPrecisionPPM
    )
}

private func sidebarHeader(_ title: String, systemImage: String) -> some View {
    HStack {
        Label(title, systemImage: systemImage)
            .font(.headline)
        Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.bar)
}
