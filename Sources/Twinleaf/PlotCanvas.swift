// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import Foundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

fileprivate enum PlotAxisLayout {
    static let plotFrameEdgeInset: CGFloat = 0.5
    static let sharedVerticalAxisInset: CGFloat = 104
    static let rightTickLabelPadding: CGFloat = 8
    static let rightTickLabelLaneWidth: CGFloat = 72
    static let independentAxisGutterGap: CGFloat = 10
    static let independentAxisSlotWidth: CGFloat = 36
    static let xAxisTitleYOffset: CGFloat = 32
    static let xAxisTitleWithOffsetYOffset: CGFloat = 41
}

fileprivate struct PlotSidebarMaterialBackground: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glassTint = colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.white.opacity(0.24)
        let highlightOpacity = colorScheme == .dark ? 0.22 : 0.34

        shape
            .fill(Color.clear)
            .glassEffect(.regular.tint(glassTint), in: shape)
            .overlay {
                shape
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.10))
            }
            .overlay {
                shape
                    .strokeBorder(Color.white.opacity(highlightOpacity), lineWidth: 1)
            }
    }
}

// MARK: - File-private math + formatting helpers
//
// These are pure functions shared by both PlotCanvas (for cursor work) and
// PlotTraceLayer (for grid/axes/labels). Living at file scope means the
// trace layer can render without reaching back into the host view.

@inline(__always)
fileprivate func plotAxisValue(_ value: Double, useLog: Bool) -> Double {
    useLog ? log10(max(value, .leastNonzeroMagnitude)) : value
}

@inline(__always)
fileprivate func plotAxisFraction(_ value: Double, in range: ClosedRange<Double>, useLog: Bool) -> Double {
    let lower = plotAxisValue(range.lowerBound, useLog: useLog)
    let upper = plotAxisValue(range.upperBound, useLog: useLog)
    let v = plotAxisValue(value, useLog: useLog)
    return (v - lower) / max(upper - lower, .leastNonzeroMagnitude)
}

@inline(__always)
fileprivate func plotAxisCoordinate(fraction: Double, in range: ClosedRange<Double>, useLog: Bool) -> Double {
    let lower = plotAxisValue(range.lowerBound, useLog: useLog)
    let upper = plotAxisValue(range.upperBound, useLog: useLog)
    let value = lower + min(max(fraction, 0), 1) * (upper - lower)
    return useLog ? pow(10, value) : value
}

fileprivate func plotNiceTicks(from minValue: Double, to maxValue: Double, targetCount: Int) -> [Double] {
    guard minValue.isFinite, maxValue.isFinite, minValue < maxValue, targetCount > 1 else {
        return []
    }
    let span = maxValue - minValue
    let rawStep = span / Double(targetCount - 1)
    let magnitude = pow(10.0, floor(log10(rawStep)))
    let normalized = rawStep / magnitude
    let niceNormalized: Double
    if normalized <= 1 {
        niceNormalized = 1
    } else if normalized <= 2 {
        niceNormalized = 2
    } else if normalized <= 5 {
        niceNormalized = 5
    } else {
        niceNormalized = 10
    }
    let step = niceNormalized * magnitude
    let first = ceil(minValue / step) * step
    var ticks: [Double] = []
    var tick = first
    while tick <= maxValue + step * 0.5 {
        if tick >= minValue - step * 0.5 {
            ticks.append(tick)
        }
        tick += step
    }
    return ticks
}

fileprivate func plotLogTicks(from minValue: Double, to maxValue: Double, maxCount: Int = 12) -> [Double] {
    guard minValue.isFinite, maxValue.isFinite, minValue > 0, minValue < maxValue else {
        return []
    }
    let lowerPower = Int(floor(log10(minValue)))
    let upperPower = Int(ceil(log10(maxValue)))

    // Try progressively sparser per-decade multiplier sets so that thinning
    // drops the 2×/5× ticks first and the decades (1×10ⁿ) are always labeled.
    for multipliers in [[1.0, 2.0, 5.0], [1.0, 3.0], [1.0]] {
        var ticks: [Double] = []
        for power in lowerPower...upperPower {
            let decade = pow(10.0, Double(power))
            for multiplier in multipliers {
                let tick = multiplier * decade
                if tick >= minValue && tick <= maxValue {
                    ticks.append(tick)
                }
            }
        }
        if ticks.count <= maxCount {
            return ticks
        }
    }

    // More decades than maxCount: keep every Nth decade, anchored at exponents
    // divisible by the stride so the surviving labels sit at round powers.
    let decadeCount = upperPower - lowerPower + 1
    let stride = max(2, Int(ceil(Double(decadeCount) / Double(max(maxCount, 1)))))
    var ticks: [Double] = []
    for power in lowerPower...upperPower where power.isMultiple(of: stride) {
        let tick = pow(10.0, Double(power))
        if tick >= minValue && tick <= maxValue {
            ticks.append(tick)
        }
    }
    return ticks
}

fileprivate func plotMinorTicks(in range: ClosedRange<Double>, majorTicks: [Double], useLog: Bool) -> [Double] {
    if useLog {
        return plotLogMinorTicks(from: range.lowerBound, to: range.upperBound, majorTicks: majorTicks)
    }
    return plotLinearMinorTicks(in: range, majorTicks: majorTicks)
}

fileprivate func plotLinearMinorTicks(in range: ClosedRange<Double>, majorTicks: [Double]) -> [Double] {
    let visibleMajorTicks = majorTicks.filter { range.contains($0) }.sorted()
    guard visibleMajorTicks.count >= 2 else { return [] }
    let subdivisions = 5
    var ticks: [Double] = []
    for (lower, upper) in zip(visibleMajorTicks, visibleMajorTicks.dropFirst()) {
        let step = (upper - lower) / Double(subdivisions)
        guard step.isFinite, step > 0 else { continue }
        for index in 1..<subdivisions {
            let tick = lower + Double(index) * step
            guard range.contains(tick) else { continue }
            ticks.append(tick)
        }
    }
    return plotCappedMinorTicks(ticks)
}

fileprivate func plotLogMinorTicks(from minValue: Double, to maxValue: Double, majorTicks: [Double]) -> [Double] {
    guard minValue.isFinite, maxValue.isFinite, minValue > 0, minValue < maxValue else {
        return []
    }
    let lowerPower = Int(floor(log10(minValue)))
    let upperPower = Int(ceil(log10(maxValue)))
    var ticks: [Double] = []
    for power in lowerPower...upperPower {
        let decade = pow(10.0, Double(power))
        for multiplier in 2...9 {
            let tick = Double(multiplier) * decade
            guard tick >= minValue, tick <= maxValue else { continue }
            guard !plotIsMajorTick(tick, in: majorTicks, useLog: true, range: minValue...maxValue) else { continue }
            ticks.append(tick)
        }
    }
    return plotCappedMinorTicks(ticks)
}

fileprivate func plotIsMajorTick(_ value: Double, in majorTicks: [Double], useLog: Bool, range: ClosedRange<Double>) -> Bool {
    let mappedValue = plotAxisValue(value, useLog: useLog)
    let mappedSpan = abs(plotAxisValue(range.upperBound, useLog: useLog) - plotAxisValue(range.lowerBound, useLog: useLog))
    let tolerance = max(mappedSpan * 1e-9, 1e-12)
    return majorTicks.contains { tick in
        abs(plotAxisValue(tick, useLog: useLog) - mappedValue) <= tolerance
    }
}

fileprivate func plotCappedMinorTicks(_ ticks: [Double], maxCount: Int = 90) -> [Double] {
    guard ticks.count > maxCount else { return ticks }
    let stride = Int(ceil(Double(ticks.count) / Double(maxCount)))
    return ticks.enumerated()
        .filter { index, _ in index.isMultiple(of: stride) }
        .map(\.element)
}

fileprivate func plotFormatTick(_ value: Double) -> String {
    let absValue = abs(value)
    if NumericDisplayPolicy.usesScientificNotation(value) {
        return String(format: "%.2e", value)
    }
    if absValue >= 100 {
        return NumericDisplayPolicy.fixed(value, fractionDigits: 0)
    }
    if absValue >= 10 {
        return NumericDisplayPolicy.fixed(value, fractionDigits: 1)
    }
    if absValue >= 1 {
        return NumericDisplayPolicy.fixed(value, fractionDigits: 2)
    }
    if absValue > 0 && absValue < 0.001 {
        return NumericDisplayPolicy.fixed(
            value,
            fractionDigits: NumericDisplayPolicy.scientificDecimalDistance
        )
    }
    return NumericDisplayPolicy.fixed(value, fractionDigits: 3)
}

fileprivate func plotFormatIndependentAxisValue(_ value: Double, units: String) -> String {
    let formatted = plotFormatTick(value)
    guard !units.isEmpty else { return formatted }
    return "\(formatted) \(units)"
}

fileprivate func plotPaddedYRange(minY: Double, maxY: Double, useLogY: Bool) -> ClosedRange<Double> {
    if useLogY, minY > 0, maxY > 0 {
        let lower = log10(minY)
        let upper = log10(maxY)
        let pad = max((upper - lower) * 0.08, 0.05)
        return pow(10, lower - pad)...pow(10, upper + pad)
    }
    let yPad = max((maxY - minY) * 0.08, 1e-12)
    return (minY - yPad)...(maxY + yPad)
}

struct PlotCanvas: View {
    let paneID: Int
    let series: [PlotSeries]
    let mode: PlotMode
    let verticalAxisMode: VerticalAxisMode
    var showsIndependentAxisLabels = false
    let windowSeconds: Double
    let viewportEnd: Double?
    let plotRevision: UInt64
    let recordingStartSeconds: Double?
    let fftLogX: Bool
    let fftLogY: Bool
    /// Log vertical axis in timeseries mode. Kept apart from `fftLogY` so a
    /// pane toggling between modes remembers each axis choice.
    var logY: Bool = false
    let showKey: Bool
    var showsXAxisLabels = true
    var topPlotInset: CGFloat = 0
    var rightAxisReservationCount = 0
    var legendSafeAreaInsets = EdgeInsets()
    var onPlotWidthChange: (Double) -> Void = { _ in }
    var onCursorSelectionChange: (CursorSelection?) -> Void = { _ in }
    var onCopyViewData: () -> Void = {}
    var onTimeseriesPan: (Double) -> Void = { _ in }
    var onTimeseriesZoom: (Double, Double) -> Void = { _, _ in }
    var onPlotColumnsDropped: (PlotColumnDragPayload) -> Void = { _ in }
    /// Context-menu content for one legend entry. Supplied by the host so the
    /// canvas stays free of bridge and menu-building concerns.
    var legendMenu: (PlotSeries) -> AnyView = { _ in AnyView(EmptyView()) }
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ViewPreferenceKeys.traceColorPaletteLight) private var traceColorPaletteLightRaw = PlotTracePalette.defaultLightRawValue
    @AppStorage(ViewPreferenceKeys.traceColorPaletteDark) private var traceColorPaletteDarkRaw = PlotTracePalette.defaultDarkRawValue
    @AppStorage(ViewPreferenceKeys.yAxisHysteresis) private var yAxisHysteresis = PlotAxisHysteresis.defaultFraction
    @AppStorage(ViewPreferenceKeys.fftAxisHysteresis) private var fftAxisHysteresis = PlotAxisHysteresis.defaultFraction
    @State private var cursorLocation: CGPoint?
    @State private var isPlotDropTargeted = false
    @State private var snappedAxisRangeMemory = SnappedAxisRangeMemory()
    @State private var timeseriesAxisRangeMemory = LinearAxisRangeMemory()
    @State private var axisRangeScanCache = PlotAxisRangeScanCache()
    // Class-backed cache held in @State so cursor-driven body re-evals don't
    // rescan every PlotPoint when the underlying data hasn't changed. Mutating
    // properties of the class instance does not trigger SwiftUI invalidation,
    // which is exactly what we want for an internal memoization layer.
    @State private var planCache = PlotPlanCache()

    private var colors: [Color] {
        if colorScheme == .dark {
            return PlotTracePalette.colors(
                from: traceColorPaletteDarkRaw,
                defaults: PlotTracePalette.defaultDarkHexColors
            )
        }
        return PlotTracePalette.colors(
            from: traceColorPaletteLightRaw,
            defaults: PlotTracePalette.defaultLightHexColors
        )
    }

    private var plotBackgroundColor: Color {
        TwinleafSurfaceColors.canvasBackgroundColor(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                // Compute layout + data plan once per body eval. The trace
                // layer below is Equatable on (revision + layout config), so
                // SwiftUI skips its body — and the heavy Canvas redraw — when
                // only the cursor moved.
                let plan = computePlan()
                let rect = plotRect(size: geometry.size)
                let plotWidth = rect.width
                let activeCursorSelection = cursorLocation.flatMap {
                    self.cursorSelection(size: geometry.size, location: $0, plan: plan)
                }
                let activeCursorSignature = cursorSelectionSignature(activeCursorSelection)

                let axisDescriptor = axisDescriptor(for: plan)

                plotLayers(size: geometry.size, rect: rect, plan: plan, axisDescriptor: axisDescriptor)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay {
                    // Cursor draws in its own light Canvas. Its body re-runs
                    // on hover, but it only renders a few line+circle paths
                    // — it never iterates the trace points.
                    if let activeCursorSelection {
                        PlotCursorOverlay(selection: activeCursorSelection, plotRect: rect)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                // The plot's own drag has to be attached below the legend: an
                // .onDrag layered over the legend swallows every drag that
                // starts inside it, including the legend's per-series drags.
                .onDrag {
                    plotPDFItemProvider(size: geometry.size, plan: plan, rect: rect)
                }
                .overlay(alignment: .topLeading) {
                    if (showKey || activeCursorSelection != nil) && (!series.isEmpty || isPlotDropTargeted) {
                        legend(selection: activeCursorSelection)
                            .padding(.leading, legendSafeAreaInsets.leading + Self.legendSafeAreaMargin)
                            .padding(.top, legendSafeAreaInsets.top + Self.legendTopSafeAreaMargin)
                            // The legend sizes to its contents; this only bounds
                            // how far right it may grow before labels truncate.
                            .frame(maxWidth: legendMaxWidth(rect: rect), alignment: .topLeading)
                    }
                }
                .contextMenu {
                    Button {
                        onCopyViewData()
                    } label: {
                        Label("Copy View Data", systemImage: "doc.on.doc")
                    }
                    .disabled(series.isEmpty)
                }
                .onDrop(
                    of: [PlotColumnDragPayload.contentType],
                    isTargeted: $isPlotDropTargeted
                ) { providers in
                    PlotColumnDragPayload.loadFirst(from: providers) { payload in
                        guard let payload else { return }
                        onPlotColumnsDropped(payload)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        cursorLocation = location
                    case .ended:
                        cursorLocation = nil
                        onCursorSelectionChange(nil)
                    }
                }
                .onAppear {
                    onPlotWidthChange(Double(plotWidth))
                }
                .onChange(of: plotWidth) { _, width in
                    onPlotWidthChange(Double(width))
                }
                .onChange(of: activeCursorSignature) { _, _ in
                    // Notify listeners only when the actual nearest data
                    // point changed — not on every pixel of cursor movement.
                    onCursorSelectionChange(activeCursorSelection)
                }
                .overlay {
                    PlotInteractionEventMonitor(
                        isEnabled: mode == .timeseries,
                        plotRect: rect,
                        windowSeconds: windowSeconds,
                        onPan: onTimeseriesPan,
                        onZoom: onTimeseriesZoom
                    )
                }
            }
        }
    }

    private func traceLayer(size: CGSize, rect: CGRect, plan: PlotDataPlan?) -> PlotTraceLayer {
        PlotTraceLayer(
            revision: plotRevision,
            canvasSize: size,
            plotRect: rect,
            traceColors: colors,
            traceColorSignature: traceColorSignature,
            plan: plan,
            series: series,
            mode: mode,
            effectiveAxisMode: effectiveVerticalAxisMode
        )
    }

    private func plotLayers(
        size: CGSize,
        rect: CGRect,
        plan: PlotDataPlan?,
        axisDescriptor: PlotAxisDescriptor
    ) -> some View {
        ZStack {
            PlotAxesLayer(
                canvasSize: size,
                plotRect: rect,
                descriptor: axisDescriptor,
                traceColors: colors,
                traceColorSignature: traceColorSignature
            )
            .equatable()

            traceLayer(size: size, rect: rect, plan: plan)
                .equatable()

            PlotRecordingOffsetLayer(
                canvasSize: size,
                plotRect: rect,
                offsetText: recordingOffsetText(for: plan)
            )
            .equatable()
        }
        .background(plotBackgroundColor)
    }

    private var traceColorSignature: String {
        if colorScheme == .dark {
            return "dark:\(traceColorPaletteDarkRaw)"
        }
        return "light:\(traceColorPaletteLightRaw)"
    }

    private func axisDescriptor(for plan: PlotDataPlan?) -> PlotAxisDescriptor {
        guard let plan, plan.hasData else {
            return PlotAxisDescriptor(
                hasData: false,
                mode: mode,
                xRange: 0...1,
                yRange: 0...1,
                useLogX: plan?.useLogX ?? false,
                useLogY: false,
                xTicks: [],
                yTicks: [],
                xSubticks: [],
                ySubticks: [],
                independentAxes: [],
                verticalAxisTitle: verticalAxisTitle,
                showsXAxisLabels: showsXAxisLabels,
                reservesRecordingOffset: reservesRecordingOffset
            )
        }

        let axisYRange = axisYRange(for: plan)
        let xRange = axisDisplayXRange(for: plan.xRange)
        let xTicks = axisXTicks(for: xRange, useLogX: plan.useLogX)
        let yTicks = plan.useLogY
            ? plotLogTicks(from: axisYRange.lowerBound, to: axisYRange.upperBound)
            : plotNiceTicks(from: axisYRange.lowerBound, to: axisYRange.upperBound, targetCount: 6)

        return PlotAxisDescriptor(
            hasData: true,
            mode: mode,
            xRange: xRange,
            yRange: axisYRange,
            useLogX: plan.useLogX,
            useLogY: plan.useLogY,
            xTicks: xTicks,
            yTicks: yTicks,
            xSubticks: plotMinorTicks(in: xRange, majorTicks: xTicks, useLog: plan.useLogX),
            ySubticks: plotMinorTicks(in: axisYRange, majorTicks: yTicks, useLog: plan.useLogY),
            independentAxes: independentAxisDescriptors(for: plan),
            verticalAxisTitle: verticalAxisTitle,
            showsXAxisLabels: showsXAxisLabels,
            reservesRecordingOffset: reservesRecordingOffset
        )
    }

    private func axisYRange(for plan: PlotDataPlan) -> ClosedRange<Double> {
        effectiveVerticalAxisMode == .independent
            ? series.compactMap { plan.seriesYRanges[$0.id] }.first ?? plan.sharedYRange
            : plan.sharedYRange
    }

    private func axisDisplayXRange(for dataXRange: ClosedRange<Double>) -> ClosedRange<Double> {
        guard mode == .timeseries else { return dataXRange }
        let window = max(windowSeconds, 1e-6)
        return (-window)...0
    }

    private func axisXTicks(for xRange: ClosedRange<Double>, useLogX: Bool) -> [Double] {
        if mode == .timeseries {
            return plotNiceTicks(from: xRange.lowerBound, to: xRange.upperBound, targetCount: 6)
        }
        if useLogX {
            return plotLogTicks(from: xRange.lowerBound, to: xRange.upperBound)
        }
        return plotNiceTicks(from: xRange.lowerBound, to: xRange.upperBound, targetCount: 6)
    }

    private func independentAxisDescriptors(for plan: PlotDataPlan) -> [PlotIndependentAxisDescriptor] {
        guard showsIndependentAxisLabels, effectiveVerticalAxisMode == .independent, series.count > 1 else {
            return []
        }

        return series.enumerated().compactMap { index, item in
            guard let range = plan.seriesYRanges[item.id] else { return nil }
            return PlotIndependentAxisDescriptor(
                id: item.id,
                index: index,
                label: item.label,
                units: item.units,
                range: range
            )
        }
    }

    private var verticalAxisTitle: String {
        let units = Set(series.map(\.units).filter { !$0.isEmpty })
        let unit = units.count == 1 ? units.first : nil
        let independentAxes = effectiveVerticalAxisMode == .independent && series.count > 1
        let streamName = verticalAxisStreamName

        switch mode {
        case .timeseries:
            if let streamName {
                guard let unit else { return streamName }
                return "\(streamName) (\(unit))"
            }
            if let unit {
                return independentAxes ? "value (\(unit), independent axes)" : "value (\(unit))"
            }
            if units.isEmpty {
                return independentAxes ? "value (independent axes)" : "value"
            }
            return independentAxes ? "value (mixed units, independent axes)" : "value (mixed units)"
        case .fft:
            if let streamName {
                guard let unit else { return "\(streamName) ASD" }
                return "\(streamName) ASD (\(unit)/sqrt(Hz))"
            }
            if let unit {
                let title = "\(unit)/sqrt(Hz)"
                return independentAxes ? "\(title) (independent axes)" : title
            }
            if units.isEmpty {
                return independentAxes ? "ASD (independent axes)" : "ASD"
            }
            return independentAxes ? "ASD (mixed units, independent axes)" : "ASD (mixed units)"
        }
    }

    private var verticalAxisStreamName: String? {
        guard series.count == 1,
              let name = series.first?.label.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name
    }

    private var reservesRecordingOffset: Bool {
        showsXAxisLabels
            && mode == .timeseries
            && recordingStartSeconds?.isFinite == true
    }

    private func recordingOffsetText(for plan: PlotDataPlan?) -> String? {
        guard reservesRecordingOffset,
              let time = plan?.xRange.upperBound,
              let offset = recordingOffset(at: time) else {
            return nil
        }
        return "+ \(NumericDisplayPolicy.fixed(offset, fractionDigits: 2)) s"
    }

    private func recordingOffset(at time: Double) -> Double? {
        guard let recordingStartSeconds,
              recordingStartSeconds.isFinite,
              time.isFinite else {
            return nil
        }
        return max(0, time - recordingStartSeconds)
    }

    private func plotPDFItemProvider(size: CGSize, plan: PlotDataPlan?, rect: CGRect) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = plotPDFSuggestedName

        guard let pdfData = plotPDFData(size: size, plan: plan, rect: rect), !pdfData.isEmpty else {
            return provider
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.pdf.identifier,
            visibility: .all
        ) { completion in
            completion(pdfData, nil)
            return nil
        }
        return provider
    }

    private func plotPDFData(size: CGSize, plan: PlotDataPlan?, rect: CGRect) -> Data? {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 1,
              size.height > 1 else {
            return nil
        }

        let exportView = traceLayer(size: size, rect: rect, plan: plan)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: exportView)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)

        let data = NSMutableData()
        renderer.render { renderedSize, renderInContext in
            var mediaBox = CGRect(origin: .zero, size: renderedSize)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                return
            }

            context.beginPDFPage(nil)
            renderInContext(context)
            context.endPDFPage()
            context.closePDF()
        }

        return data as Data
    }

    private var plotPDFSuggestedName: String {
        let baseName = series.first?.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = baseName?.isEmpty == false ? baseName! : "Twinleaf Plot \(paneID + 1)"
        return "\(Self.sanitizedFilenameStem(title)) \(mode.title).pdf"
    }

    private static func sanitizedFilenameStem(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let parts = value.components(separatedBy: invalidCharacters)
        let sanitized = parts
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Twinleaf Plot" : sanitized
    }

    private func legend(selection: CursorSelection?) -> some View {
        let valuesByID = Dictionary(uniqueKeysWithValues: selection?.values.map { ($0.id, $0) } ?? [])
        let showsNoiseFloors = selection == nil && mode == .fft
        let showsValues = selection != nil || (showsNoiseFloors && series.contains { $0.noiseFloor != nil })

        return VStack(alignment: .leading, spacing: 6) {
            legendRows(
                valuesByID: valuesByID,
                showsNoiseFloors: showsNoiseFloors,
                showsValues: showsValues
            )

            if let selection {
                HStack(spacing: 6) {
                    CursorTimeIndicatorIcon()
                        .frame(width: 18, height: 18)
                    Text(selection.xText)
                        .font(.body.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Cursor time \(selection.xText)")
            }
        }
        .padding(8)
        .background {
            PlotSidebarMaterialBackground(cornerRadius: Self.legendCornerRadius)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.legendCornerRadius, style: .continuous))
        .overlay {
            if isPlotDropTargeted {
                RoundedRectangle(cornerRadius: Self.legendCornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isPlotDropTargeted)
    }

    private static let legendSafeAreaMargin: CGFloat = 8
    private static let legendTopSafeAreaMargin: CGFloat = 3
    private static let legendCornerRadius: CGFloat = 6
    private static let legendMinimumContentWidth: CGFloat = 120

    private func noiseFloorText(_ value: Double, units: String) -> String {
        let formatted = String(format: "%.3g", value)
        guard !units.isEmpty else { return "Floor \(formatted) ASD" }
        return "Floor \(formatted) \(units)/√Hz"
    }

    @ViewBuilder
    private func legendRows(
        valuesByID: [ColumnKey: CursorValue],
        showsNoiseFloors: Bool,
        showsValues: Bool
    ) -> some View {
        if series.isEmpty {
            Image(systemName: "plus")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        } else {
            // A Grid keeps the value column aligned across rows while every
            // row stays only as wide as its own contents need. The gap between
            // the two columns is padding inside the value cell rather than grid
            // spacing, so the cell's drag hit area reaches the label beside it.
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 6) {
                ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                    GridRow {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(colors[index % colors.count])
                                .frame(width: 18, height: 4)
                                .opacity(item.isDimmedInLegend ? 0.35 : 1)
                            Text(item.label)
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(item.isDimmedInLegend ? .secondary : .primary)
                            if item.isOutsideTimeWindow {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                                    .help("This stream's time reference doesn't match the graph's first stream, so it can't be shown on the same time axis.")
                            } else if item.isWarmingUp {
                                // Nothing is wrong: a derived channel needs a
                                // full source window before its first estimate.
                                Text("warming up")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .help("Collecting enough data for the first estimate.")
                            }
                        }
                        .contentShape(Rectangle())
                        .onDrag {
                            PlotColumnDragPayload(keys: [item.key], sourcePaneID: paneID).itemProvider
                        }
                        .contextMenu { legendMenu(item) }

                        if showsValues {
                            legendValue(
                                for: item,
                                hoverValue: valuesByID[item.id],
                                showsNoiseFloors: showsNoiseFloors
                            )
                            .padding(.leading, 12)
                            .gridColumnAlignment(.trailing)
                            .contentShape(Rectangle())
                            .onDrag {
                                PlotColumnDragPayload(keys: [item.key], sourcePaneID: paneID).itemProvider
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func legendValue(
        for item: PlotSeries,
        hoverValue: CursorValue?,
        showsNoiseFloors: Bool
    ) -> some View {
        if let hoverValue {
            Text(hoverValue.yText)
                .font(.body.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        } else if showsNoiseFloors, let floor = item.noiseFloor {
            Text(noiseFloorText(floor, units: item.units))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    // The legend hangs off the plot frame's leading edge, so it may run right
    // up to the frame's trailing edge before its labels have to truncate.
    private func legendMaxWidth(rect: CGRect) -> CGFloat {
        let leading = legendSafeAreaInsets.leading + Self.legendSafeAreaMargin
        return max(leading + Self.legendMinimumContentWidth, rect.maxX)
    }

    private var totalPointCount: Int {
        series.reduce(0) { $0 + $1.points.count }
    }

    private func cursorSelectionSignature(_ selection: CursorSelection?) -> CursorSelectionSignature? {
        selection.map(CursorSelectionSignature.init)
    }

    private var effectiveVerticalAxisMode: VerticalAxisMode {
        verticalAxisMode
    }

    private func plotRect(size: CGSize) -> CGRect {
        let leftInset = PlotAxisLayout.plotFrameEdgeInset
        let rightInset = rightPlotInset(for: size)
        let topInset = max(0, topPlotInset)
        let bottomInset = bottomPlotInset
        return CGRect(
            x: leftInset,
            y: topInset,
            width: max(20, size.width - leftInset - rightInset),
            height: max(20, size.height - topInset - bottomInset)
        )
    }

    private var bottomPlotInset: CGFloat {
        Self.bottomAxisInset(
            showsXAxisLabels: showsXAxisLabels,
            mode: mode,
            recordingStartSeconds: recordingStartSeconds
        )
    }

    static func bottomAxisInset(
        showsXAxisLabels: Bool,
        mode: PlotMode,
        recordingStartSeconds: Double?
    ) -> CGFloat {
        guard showsXAxisLabels else { return 0 }
        let hasOffset = mode == .timeseries && recordingStartSeconds?.isFinite == true
        return hasOffset ? 62 : 50
    }

    private func rightPlotInset(for size: CGSize) -> CGFloat {
        Self.rightAxisInset(
            size: size,
            verticalAxisMode: effectiveVerticalAxisMode,
            seriesCount: series.count,
            rightAxisReservationCount: rightAxisReservationCount,
            showsIndependentAxisLabels: showsIndependentAxisLabels
        )
    }

    static func rightAxisInset(
        size: CGSize,
        verticalAxisMode: VerticalAxisMode,
        seriesCount: Int,
        rightAxisReservationCount: Int,
        showsIndependentAxisLabels: Bool
    ) -> CGFloat {
        let baseInset = PlotAxisLayout.sharedVerticalAxisInset
        let ownAxisCount = showsIndependentAxisLabels && verticalAxisMode == .independent && seriesCount > 1
            ? seriesCount
            : 0
        let axisCount = max(rightAxisReservationCount, ownAxisCount)
        guard axisCount > 1 else {
            return baseInset
        }

        let desiredInset = PlotAxisLayout.rightTickLabelLaneWidth
            + PlotAxisLayout.independentAxisGutterGap
            + CGFloat(axisCount) * PlotAxisLayout.independentAxisSlotWidth
        let maximumInset = max(PlotAxisLayout.sharedVerticalAxisInset, size.width * 0.28)
        return min(max(desiredInset, PlotAxisLayout.sharedVerticalAxisInset), maximumInset)
    }

    private func map(
        _ point: PlotPoint,
        rect: CGRect,
        xRange: ClosedRange<Double>,
        yRange: ClosedRange<Double>,
        useLogX: Bool,
        useLogY: Bool
    ) -> CGPoint {
        let xFraction = plotAxisFraction(point.x, in: xRange, useLog: useLogX)
        let yFraction = plotAxisFraction(point.y, in: yRange, useLog: useLogY)
        return CGPoint(
            x: rect.minX + rect.width * CGFloat(xFraction),
            y: rect.maxY - rect.height * CGFloat(yFraction)
        )
    }

    private func cursorSelection(size: CGSize, location: CGPoint, plan: PlotDataPlan?) -> CursorSelection? {
        let profileStart = PlotProfiler.start()
        var checkedPoints = 0
        defer {
            PlotProfiler.finish(
                "plot.cursor",
                start: profileStart,
                details: "mode=\(mode.rawValue) series=\(series.count) points=\(totalPointCount) checked=\(checkedPoints)"
            )
        }

        let rect = plotRect(size: size)
        guard rect.contains(location), let plan, plan.hasData else { return nil }

        let useLogX = plan.useLogX
        let useLogY = plan.useLogY
        let xRange = plan.xRange
        let sharedYRange = plan.sharedYRange
        let seriesYRanges = plan.seriesYRanges

        let xFraction = Double((location.x - rect.minX) / max(rect.width, 1))
        let cursorX = plotAxisCoordinate(fraction: xFraction, in: xRange, useLog: useLogX)
        let screenX = rect.minX + rect.width * CGFloat(plotAxisFraction(cursorX, in: xRange, useLog: useLogX))
        let relativeX = mode == .timeseries ? cursorX - xRange.upperBound : cursorX

        var values: [CursorValue] = []
        let cursorXMapped = plotAxisValue(cursorX, useLog: useLogX)

        for (index, item) in series.enumerated() {
            let yRange = effectiveVerticalAxisMode == .independent
                ? seriesYRanges[item.id] ?? sharedYRange
                : sharedYRange

            var nearestPoint: PlotPoint?
            var nearestDistance = Double.infinity
            for pointIndex in cursorCandidateRange(in: item.points, near: cursorX) {
                checkedPoints += 1
                let point = item.points[pointIndex]
                if !point.x.isFinite || !point.y.isFinite { continue }
                if useLogX && point.x <= 0 { continue }
                if useLogY && point.y <= 0 { continue }
                if point.x < xRange.lowerBound || point.x > xRange.upperBound { continue }

                let distance = abs(plotAxisValue(point.x, useLog: useLogX) - cursorXMapped)
                guard distance < nearestDistance else { continue }

                nearestDistance = distance
                nearestPoint = point
            }

            guard let point = nearestPoint else { continue }
            values.append(
                CursorValue(
                    id: item.id,
                    label: item.label,
                    color: colors[index % colors.count],
                    screenPoint: map(
                        point,
                        rect: rect,
                        xRange: xRange,
                        yRange: yRange,
                        useLogX: useLogX,
                        useLogY: useLogY
                    ),
                    yText: formatCursorY(point.y, units: item.units)
                )
            )
        }

        guard !values.isEmpty else { return nil }
        return CursorSelection(
            screenX: screenX,
            xText: formatCursorX(relativeX),
            values: values
        )
    }

    // MARK: - Plan computation (single combined pass over all points)

    private func computePlan() -> PlotDataPlan? {
        let useLogX = mode == .fft && fftLogX
        let useLogY = mode == .fft ? fftLogY : logY
        let key = PlotPlanKey(
            plotRevision: plotRevision,
            mode: mode,
            axisMode: effectiveVerticalAxisMode,
            windowSeconds: windowSeconds,
            viewportEnd: viewportEnd,
            useLogX: useLogX,
            useLogY: useLogY,
            seriesCount: series.count
        )
        if let cached = planCache.lookup(for: key) {
            return cached
        }
        let plan = makePlan(useLogX: useLogX, useLogY: useLogY)
        planCache.store(key: key, plan: plan)
        return plan
    }

    private func makePlan(useLogX: Bool, useLogY: Bool) -> PlotDataPlan? {
        guard !series.isEmpty else { return nil }

        // Resolve x range. In timeseries mode we know the window from
        // configuration, so we only scan all points for x bounds when we
        // truly need to (FFT, or timeseries with no upstream viewport hint).
        var xMin = Double.infinity
        var xMax = -Double.infinity
        let needsXScan = mode == .fft || viewportEnd == nil
        if needsXScan {
            for item in series {
                for point in item.points {
                    if !point.x.isFinite || !point.y.isFinite { continue }
                    if useLogX && point.x <= 0 { continue }
                    if useLogY && point.y <= 0 { continue }
                    if point.x < xMin { xMin = point.x }
                    if point.x > xMax { xMax = point.x }
                }
            }
            guard xMin.isFinite, xMax.isFinite, xMin < xMax else { return nil }
        }

        let xRange: ClosedRange<Double>
        switch mode {
        case .timeseries:
            let window = max(windowSeconds, 1e-6)
            let end: Double
            if let v = viewportEnd, v.isFinite {
                end = v
            } else if xMax.isFinite {
                end = xMax
            } else {
                return nil
            }
            xRange = (end - window)...end
        case .fft:
            xRange = snappedAxisRange(axis: .x, rawLower: xMin, rawUpper: xMax, useLog: useLogX)
        }

        let ySnapshot = yAxisRangeSnapshot(
            xRange: xRange,
            useLogX: useLogX,
            useLogY: useLogY
        )
        return PlotDataPlan(
            xRange: xRange,
            sharedYRange: ySnapshot.sharedYRange,
            seriesYRanges: ySnapshot.seriesYRanges,
            useLogX: useLogX,
            useLogY: useLogY,
            hasData: ySnapshot.hasData
        )
    }

    private func yAxisRangeSnapshot(
        xRange: ClosedRange<Double>,
        useLogX: Bool,
        useLogY: Bool
    ) -> PlotAxisRangeSnapshot {
        let key = PlotAxisRangeScanKey(
            mode: mode,
            axisMode: effectiveVerticalAxisMode,
            windowSeconds: mode == .timeseries ? windowSeconds : nil,
            useLogX: useLogX,
            useLogY: useLogY,
            seriesIDs: series.map(\.id)
        )
        let minimumInterval = mode == .timeseries
            ? PlotAxisRangeUpdateCadence.timeseriesMinimumInterval
            : 0

        return axisRangeScanCache.snapshot(
            for: key,
            now: ProcessInfo.processInfo.systemUptime,
            minimumInterval: minimumInterval
        ) {
            scanYRanges(xRange: xRange, useLogX: useLogX, useLogY: useLogY)
        }
    }

    private func scanYRanges(
        xRange: ClosedRange<Double>,
        useLogX: Bool,
        useLogY: Bool
    ) -> PlotAxisRangeSnapshot {
        // Single Y pass: compute shared min/max and per-series min/max in
        // one walk, gated by the resolved xRange.
        let needsIndependent = effectiveVerticalAxisMode == .independent && series.count > 1
        var sharedYMin = Double.infinity
        var sharedYMax = -Double.infinity
        var perSeries: [ColumnKey: ClosedRange<Double>] = [:]
        if needsIndependent {
            perSeries.reserveCapacity(series.count)
        }

        for item in series {
            var yMin = Double.infinity
            var yMax = -Double.infinity
            for point in item.points {
                if !point.x.isFinite || !point.y.isFinite { continue }
                if useLogX && point.x <= 0 { continue }
                if useLogY && point.y <= 0 { continue }
                if point.x < xRange.lowerBound || point.x > xRange.upperBound { continue }
                if point.y < yMin { yMin = point.y }
                if point.y > yMax { yMax = point.y }
            }
            guard yMin.isFinite, yMax.isFinite else { continue }
            if yMin < sharedYMin { sharedYMin = yMin }
            if yMax > sharedYMax { sharedYMax = yMax }
            if needsIndependent {
                perSeries[item.id] = resolvedYRange(
                    minY: yMin,
                    maxY: yMax,
                    useLogY: useLogY,
                    seriesID: item.id
                )
            }
        }

        guard sharedYMin.isFinite, sharedYMax.isFinite else {
            return PlotAxisRangeSnapshot(
                sharedYRange: 0...1,
                seriesYRanges: [:],
                hasData: false
            )
        }

        let sharedYRange = resolvedYRange(minY: sharedYMin, maxY: sharedYMax, useLogY: useLogY)
        return PlotAxisRangeSnapshot(
            sharedYRange: sharedYRange,
            seriesYRanges: perSeries,
            hasData: true
        )
    }

    private func cursorCandidateRange(in points: [PlotPoint], near x: Double) -> Range<Int> {
        let radius = 12
        guard points.count > radius * 2 + 1,
              let first = points.first,
              let last = points.last,
              first.x <= last.x else {
            return points.startIndex..<points.endIndex
        }

        var low = points.startIndex
        var high = points.endIndex
        while low < high {
            let mid = low + (high - low) / 2
            if points[mid].x < x {
                low = mid + 1
            } else {
                high = mid
            }
        }

        return max(points.startIndex, low - radius)..<min(points.endIndex, low + radius + 1)
    }

    private func resolvedYRange(
        minY: Double,
        maxY: Double,
        useLogY: Bool,
        seriesID: ColumnKey? = nil
    ) -> ClosedRange<Double> {
        // A linear axis keeps its linear-span hysteresis; a log axis — in
        // either mode — snaps to decades and measures hysteresis in orders of
        // magnitude, because a linear margin over a range spanning decades is
        // set entirely by the topmost one.
        guard mode == .fft || useLogY else {
            let ideal = plotPaddedYRange(minY: minY, maxY: maxY, useLogY: useLogY)
            return timeseriesAxisRangeMemory.hystereticRange(
                mode: mode,
                axis: .y,
                seriesID: seriesID,
                ideal: ideal,
                rawLower: minY,
                rawUpper: maxY,
                hysteresisFraction: PlotAxisHysteresis.clamped(yAxisHysteresis)
            )
        }
        return snappedAxisRange(
            axis: .y,
            seriesID: seriesID,
            rawLower: minY,
            rawUpper: maxY,
            useLog: useLogY
        )
    }

    private func snappedAxisRange(
        axis: PlotAxisKind,
        seriesID: ColumnKey? = nil,
        rawLower: Double,
        rawUpper: Double,
        useLog: Bool
    ) -> ClosedRange<Double> {
        snappedAxisRangeMemory.snappedRange(
            mode: mode,
            axis: axis,
            seriesID: seriesID,
            scale: useLog ? .log : .linear,
            rawLower: rawLower,
            rawUpper: rawUpper,
            hysteresisFraction: PlotAxisHysteresis.clamped(fftAxisHysteresis)
        )
    }

    private func formatCursorX(_ value: Double) -> String {
        switch mode {
        case .timeseries:
            return "\(String(format: "%.3f", value)) s"
        case .fft:
            return "\(plotFormatTick(value)) Hz"
        }
    }

    private func formatCursorY(_ value: Double, units: String) -> String {
        let formatted: String
        let absValue = abs(value)
        if NumericDisplayPolicy.usesScientificNotation(value) {
            formatted = String(format: "%.4e", value)
        } else if absValue > 0 && absValue < 0.001 {
            formatted = NumericDisplayPolicy.fixed(
                value,
                fractionDigits: NumericDisplayPolicy.scientificDecimalDistance
            )
        } else {
            formatted = NumericDisplayPolicy.significant(value, maximumDigits: 6)
        }

        guard !units.isEmpty else { return formatted }
        return "\(formatted) \(units)"
    }
}

// MARK: - PlotAxesLayer

private struct PlotAxesLayer: View, Equatable {
    let canvasSize: CGSize
    let plotRect: CGRect
    let descriptor: PlotAxisDescriptor
    let traceColors: [Color]
    let traceColorSignature: String

    nonisolated static func == (lhs: PlotAxesLayer, rhs: PlotAxesLayer) -> Bool {
        lhs.canvasSize == rhs.canvasSize
            && lhs.plotRect == rhs.plotRect
            && lhs.descriptor == rhs.descriptor
            && lhs.traceColorSignature == rhs.traceColorSignature
    }

    var body: some View {
        Canvas { context, size in
            let profileStart = PlotProfiler.start()
            drawAll(context: &context, size: size)
            PlotProfiler.finish(
                "plot.axes.draw",
                start: profileStart,
                details: "mode=\(descriptor.mode.rawValue) hasData=\(descriptor.hasData) size=\(Int(size.width))x\(Int(size.height))"
            )
        }
    }

    private func drawAll(context: inout GraphicsContext, size: CGSize) {
        drawGrid(context: &context)

        guard descriptor.hasData else {
            drawEmpty(context: &context)
            return
        }

        drawAxisLabels(context: &context, size: size)
        drawIndependentAxes(context: &context, size: size)
    }

    private func drawGrid(context: inout GraphicsContext) {
        let rect = plotRect
        let xRange = descriptor.xRange
        let yRange = descriptor.yRange
        let useLogX = descriptor.useLogX
        let useLogY = descriptor.useLogY

        var minorGrid = Path()
        for tick in descriptor.xSubticks {
            let xFraction = plotAxisFraction(tick, in: xRange, useLog: useLogX)
            let x = rect.minX + rect.width * CGFloat(xFraction)
            minorGrid.move(to: CGPoint(x: x, y: rect.minY))
            minorGrid.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for tick in descriptor.ySubticks {
            let yFraction = plotAxisFraction(tick, in: yRange, useLog: useLogY)
            let y = rect.maxY - rect.height * CGFloat(yFraction)
            minorGrid.move(to: CGPoint(x: rect.minX, y: y))
            minorGrid.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.stroke(minorGrid, with: .color(.secondary.opacity(0.08)), lineWidth: 0.7)

        var grid = Path()
        for tick in descriptor.xTicks {
            let xFraction = plotAxisFraction(tick, in: xRange, useLog: useLogX)
            let x = rect.minX + rect.width * CGFloat(xFraction)
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for tick in descriptor.yTicks {
            let yFraction = plotAxisFraction(tick, in: yRange, useLog: useLogY)
            let y = rect.maxY - rect.height * CGFloat(yFraction)
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.22)), lineWidth: 1)

        var frame = Path()
        frame.addRect(rect)
        context.stroke(frame, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
    }

    private func drawAxisLabels(context: inout GraphicsContext, size: CGSize) {
        let rect = plotRect
        let xRange = descriptor.xRange
        let yRange = descriptor.yRange
        let useLogX = descriptor.useLogX
        let useLogY = descriptor.useLogY

        for tick in descriptor.xTicks where descriptor.showsXAxisLabels {
            let xFraction = plotAxisFraction(tick, in: xRange, useLog: useLogX)
            let x = rect.minX + rect.width * CGFloat(xFraction)
            let label = Text(plotFormatTick(tick))
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

        let usesIndependentAxisGutter = !descriptor.independentAxes.isEmpty
        let yLabelX = rect.maxX + PlotAxisLayout.rightTickLabelPadding
        let hasRightLabelLane = yLabelX < size.width - 8
        let yLabelAnchor: UnitPoint = hasRightLabelLane ? .leading : .trailing
        let yLabelDrawX = hasRightLabelLane ? yLabelX : size.width - 4

        for tick in descriptor.yTicks {
            let yFraction = plotAxisFraction(tick, in: yRange, useLog: useLogY)
            let y = rect.maxY - rect.height * CGFloat(yFraction)
            let label = Text(plotFormatTick(tick))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: yLabelDrawX, y: y), anchor: yLabelAnchor)
        }

        if descriptor.showsXAxisLabels {
            let xTitle = Text(descriptor.mode == .fft ? "frequency (Hz)" : "Time (s)")
                .font(.body)
                .foregroundStyle(.secondary)
            let titleY = rect.maxY + (descriptor.reservesRecordingOffset
                ? PlotAxisLayout.xAxisTitleWithOffsetYOffset
                : PlotAxisLayout.xAxisTitleYOffset)
            context.draw(xTitle, at: CGPoint(x: rect.midX, y: titleY), anchor: .center)
        }

        var labelContext = context
        let titleOffset = usesIndependentAxisGutter
            ? PlotAxisLayout.rightTickLabelLaneWidth - 8
            : 70
        labelContext.translateBy(x: min(rect.maxX + titleOffset, size.width - 12), y: rect.midY)
        labelContext.rotate(by: .degrees(90))
        let yTitle = Text(descriptor.verticalAxisTitle)
            .font(.body)
            .foregroundStyle(.secondary)
        labelContext.draw(yTitle, at: .zero, anchor: .center)
    }

    private func drawIndependentAxes(context: inout GraphicsContext, size: CGSize) {
        let axisItems = descriptor.independentAxes
        guard axisItems.count > 1 else { return }

        let rect = plotRect
        let gutterWidth = max(0, size.width - rect.maxX)
        let firstX = rect.maxX
            + PlotAxisLayout.rightTickLabelLaneWidth
            + PlotAxisLayout.independentAxisGutterGap
        guard gutterWidth >= PlotAxisLayout.rightTickLabelLaneWidth + 34 else { return }

        let availableWidth = max(
            1,
            gutterWidth
                - PlotAxisLayout.rightTickLabelLaneWidth
                - PlotAxisLayout.independentAxisGutterGap
                - 16
        )
        let axisSpacing = axisItems.count > 1
            ? min(34, max(18, availableWidth / CGFloat(axisItems.count - 1)))
            : 0

        for (axisIndex, axisItem) in axisItems.enumerated() {
            let x = min(firstX + CGFloat(axisIndex) * axisSpacing, size.width - 36)
            let color = traceColors[axisItem.index % traceColors.count]

            var axis = Path()
            axis.move(to: CGPoint(x: x, y: rect.minY))
            axis.addLine(to: CGPoint(x: x, y: rect.maxY))
            axis.move(to: CGPoint(x: x - 4, y: rect.minY))
            axis.addLine(to: CGPoint(x: x + 4, y: rect.minY))
            axis.move(to: CGPoint(x: x - 4, y: rect.maxY))
            axis.addLine(to: CGPoint(x: x + 4, y: rect.maxY))
            axis.move(to: CGPoint(x: x - 3, y: rect.midY))
            axis.addLine(to: CGPoint(x: x + 3, y: rect.midY))
            context.stroke(axis, with: .color(color.opacity(0.86)), lineWidth: 1.2)

            let laneOffset = CGFloat(axisIndex % 3) * 10
            let centerLaneOffset = CGFloat((axisIndex % 3) - 1) * 9
            let labelX = x + 4
            let upperLabel = Text(plotFormatIndependentAxisValue(axisItem.range.upperBound, units: axisItem.units))
                .font(.body.monospacedDigit())
                .foregroundStyle(color)
            let centerValue = axisItem.range.lowerBound
                + (axisItem.range.upperBound - axisItem.range.lowerBound) * 0.5
            let centerLabel = Text(plotFormatIndependentAxisValue(centerValue, units: axisItem.units))
                .font(.body.monospacedDigit())
                .foregroundStyle(color.opacity(0.9))
            let lowerLabel = Text(plotFormatIndependentAxisValue(axisItem.range.lowerBound, units: axisItem.units))
                .font(.body.monospacedDigit())
                .foregroundStyle(color)
            context.draw(
                upperLabel,
                at: CGPoint(x: labelX, y: rect.minY + 8 + laneOffset),
                anchor: .leading
            )
            context.draw(
                centerLabel,
                at: CGPoint(x: labelX, y: rect.midY + centerLaneOffset),
                anchor: .leading
            )
            context.draw(
                lowerLabel,
                at: CGPoint(x: labelX, y: rect.maxY - 8 - laneOffset),
                anchor: .leading
            )
        }
    }

    private func drawEmpty(context: inout GraphicsContext) {
        let rect = plotRect
        let text = Text("Select one or more streams")
            .font(.title3)
            .foregroundStyle(.secondary)
        context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }
}

private struct PlotRecordingOffsetLayer: View, Equatable {
    let canvasSize: CGSize
    let plotRect: CGRect
    let offsetText: String?

    nonisolated static func == (lhs: PlotRecordingOffsetLayer, rhs: PlotRecordingOffsetLayer) -> Bool {
        lhs.canvasSize == rhs.canvasSize
            && lhs.plotRect == rhs.plotRect
            && lhs.offsetText == rhs.offsetText
    }

    var body: some View {
        Canvas { context, _ in
            guard let offsetText else { return }
            let label = Text(offsetText)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            context.draw(
                label,
                at: CGPoint(
                    x: plotRect.maxX,
                    y: plotRect.maxY + PlotAxisLayout.xAxisTitleWithOffsetYOffset
                ),
                anchor: .trailing
            )
        }
    }
}

// MARK: - PlotTraceLayer
//
// The trace layer renders only dynamic series paths. Axes and labels live in
// a separate Equatable layer keyed on the effective axis descriptor, so plot
// frames can update traces without rebuilding text and grid display lists.
private struct PlotTraceLayer: View, Equatable {
    let revision: UInt64
    let canvasSize: CGSize
    let plotRect: CGRect
    let traceColors: [Color]
    let traceColorSignature: String
    let plan: PlotDataPlan?
    let series: [PlotSeries]
    let mode: PlotMode
    let effectiveAxisMode: VerticalAxisMode

    // `nonisolated` so the conformance can be referenced off the main actor.
    // SwiftUI's View protocol pulls types onto the main actor, but the
    // Equatable protocol witness is nonisolated; without this annotation
    // the compiler flags it as a strict-concurrency violation.
    nonisolated static func == (lhs: PlotTraceLayer, rhs: PlotTraceLayer) -> Bool {
        // Skip series/plan: revision gates real data changes.
        lhs.revision == rhs.revision
            && lhs.canvasSize == rhs.canvasSize
            && lhs.plotRect == rhs.plotRect
            && lhs.traceColorSignature == rhs.traceColorSignature
            && lhs.mode == rhs.mode
            && lhs.effectiveAxisMode == rhs.effectiveAxisMode
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let profileStart = PlotProfiler.start()
            drawAll(context: &context, size: size)
            PlotProfiler.finish(
                "plot.trace.draw",
                start: profileStart,
                details: "mode=\(mode.rawValue) axis=\(effectiveAxisMode.rawValue) series=\(series.count) size=\(Int(size.width))x\(Int(size.height))"
            )
        }
    }

    private func drawAll(context: inout GraphicsContext, size: CGSize) {
        let rect = plotRect

        guard let plan, plan.hasData else { return }

        let useLogX = plan.useLogX
        let useLogY = plan.useLogY
        let xRange = plan.xRange
        let sharedYRange = plan.sharedYRange
        let seriesYRanges = plan.seriesYRanges

        // Precompute axis transforms once per axis. The inner loop then
        // does at most one log10 per point instead of six.
        let xMap = AxisMapping(range: xRange, useLog: useLogX)
        let xLower = xRange.lowerBound
        let xUpper = xRange.upperBound
        var pixelBuffer: [CGPoint] = []

        for (index, item) in series.enumerated() {
            let yRange = effectiveAxisMode == .independent
                ? seriesYRanges[item.id] ?? sharedYRange
                : sharedYRange
            let yMap = AxisMapping(range: yRange, useLog: useLogY)

            pixelBuffer.removeAll(keepingCapacity: true)
            pixelBuffer.reserveCapacity(item.points.count)

            for point in item.points {
                if !point.x.isFinite || !point.y.isFinite { continue }
                if useLogX && point.x <= 0 { continue }
                if useLogY && point.y <= 0 { continue }
                if point.x < xLower || point.x > xUpper { continue }
                let xFrac = xMap.fraction(point.x)
                let yFrac = yMap.fraction(point.y)
                pixelBuffer.append(CGPoint(
                    x: rect.minX + rect.width * CGFloat(xFrac),
                    y: rect.maxY - rect.height * CGFloat(yFrac)
                ))
            }
            guard pixelBuffer.count >= 2 else { continue }

            var path = Path()
            path.addLines(pixelBuffer)
            context.stroke(
                path,
                with: .color(traceColors[index % traceColors.count]),
                lineWidth: 1.6
            )
        }
    }
}

// MARK: - PlotCursorOverlay
//
// Lightweight cursor renderer. Re-renders on every hover tick (since
// `selection` changes), but does only a handful of line + ellipse strokes
// — never iterates the trace point arrays.
private struct PlotCursorOverlay: View {
    let selection: CursorSelection
    let plotRect: CGRect

    var body: some View {
        Canvas { context, _ in
            drawCursor(context: &context)
        }
    }

    private func drawCursor(context: inout GraphicsContext) {
        var vertical = Path()
        vertical.move(to: CGPoint(x: selection.screenX, y: plotRect.minY))
        vertical.addLine(to: CGPoint(x: selection.screenX, y: plotRect.maxY))
        context.stroke(
            vertical,
            with: .color(.secondary.opacity(0.72)),
            style: StrokeStyle(lineWidth: 1, dash: [5, 5])
        )

        for value in selection.values {
            var horizontal = Path()
            horizontal.move(to: CGPoint(x: plotRect.minX, y: value.screenPoint.y))
            horizontal.addLine(to: CGPoint(x: plotRect.maxX, y: value.screenPoint.y))
            context.stroke(
                horizontal,
                with: .color(value.color.opacity(0.58)),
                style: StrokeStyle(lineWidth: 1, dash: [5, 5])
            )

            let markerRect = CGRect(
                x: value.screenPoint.x - 4.5,
                y: value.screenPoint.y - 4.5,
                width: 9,
                height: 9
            )
            let marker = Path(ellipseIn: markerRect)
            context.fill(marker, with: .color(value.color))
            context.stroke(marker, with: .color(.white.opacity(0.92)), lineWidth: 2)
        }
    }
}

// Materialized per-frame plan derived from the series + view configuration.
// Trace and cursor rendering derive from one instance of this struct; the
// y-axis ranges inside it may be reused for a short cadence while traces keep
// scrolling against the current x range.
private struct PlotDataPlan {
    let xRange: ClosedRange<Double>
    let sharedYRange: ClosedRange<Double>
    let seriesYRanges: [ColumnKey: ClosedRange<Double>]
    let useLogX: Bool
    let useLogY: Bool
    let hasData: Bool
}

private enum PlotAxisRangeUpdateCadence {
    static let timeseriesMinimumInterval = 0.2
}

private struct PlotAxisRangeSnapshot {
    let sharedYRange: ClosedRange<Double>
    let seriesYRanges: [ColumnKey: ClosedRange<Double>]
    let hasData: Bool
}

private struct PlotAxisRangeScanKey: Equatable {
    let mode: PlotMode
    let axisMode: VerticalAxisMode
    let windowSeconds: Double?
    let useLogX: Bool
    let useLogY: Bool
    let seriesIDs: [ColumnKey]
}

private final class PlotAxisRangeScanCache {
    private var key: PlotAxisRangeScanKey?
    private var snapshot: PlotAxisRangeSnapshot?
    private var lastUpdateTime: TimeInterval = -.infinity

    func snapshot(
        for key: PlotAxisRangeScanKey,
        now: TimeInterval,
        minimumInterval: TimeInterval,
        scan: () -> PlotAxisRangeSnapshot
    ) -> PlotAxisRangeSnapshot {
        if let storedKey = self.key,
           storedKey == key,
           let snapshot,
           minimumInterval > 0,
           now - lastUpdateTime < minimumInterval {
            return snapshot
        }

        let next = scan()
        self.key = key
        self.snapshot = next
        lastUpdateTime = now
        return next
    }
}

private struct PlotIndependentAxisDescriptor: Equatable, Identifiable {
    let id: ColumnKey
    let index: Int
    let label: String
    let units: String
    let range: ClosedRange<Double>
}

private struct PlotAxisDescriptor: Equatable {
    let hasData: Bool
    let mode: PlotMode
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>
    let useLogX: Bool
    let useLogY: Bool
    let xTicks: [Double]
    let yTicks: [Double]
    let xSubticks: [Double]
    let ySubticks: [Double]
    let independentAxes: [PlotIndependentAxisDescriptor]
    let verticalAxisTitle: String
    let showsXAxisLabels: Bool
    let reservesRecordingOffset: Bool
}

private struct PlotPlanKey: Equatable {
    let plotRevision: UInt64
    let mode: PlotMode
    let axisMode: VerticalAxisMode
    let windowSeconds: Double
    let viewportEnd: Double?
    let useLogX: Bool
    let useLogY: Bool
    let seriesCount: Int
}

private final class PlotPlanCache {
    private var key: PlotPlanKey?
    private var plan: PlotDataPlan?

    func lookup(for key: PlotPlanKey) -> PlotDataPlan? {
        guard let stored = self.key, stored == key else { return nil }
        return plan
    }

    func store(key: PlotPlanKey, plan: PlotDataPlan?) {
        self.key = key
        self.plan = plan
    }
}

// Precomputed axis transform: avoids per-point log10 + division in the hot
// trace loop. fraction(value) maps a data value to [0, 1] in screen space.
private struct AxisMapping {
    let lower: Double
    let invSpan: Double
    let useLog: Bool

    init(range: ClosedRange<Double>, useLog: Bool) {
        self.useLog = useLog
        if useLog {
            let lo = log10(max(range.lowerBound, .leastNonzeroMagnitude))
            let hi = log10(max(range.upperBound, .leastNonzeroMagnitude))
            lower = lo
            invSpan = 1 / max(hi - lo, .leastNonzeroMagnitude)
        } else {
            lower = range.lowerBound
            invSpan = 1 / max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)
        }
    }

    @inline(__always)
    func fraction(_ value: Double) -> Double {
        let v = useLog ? log10(max(value, .leastNonzeroMagnitude)) : value
        return (v - lower) * invSpan
    }
}

private enum PlotAxisKind: Hashable {
    case x
    case y
}

private enum PlotAxisScale: Hashable {
    case linear
    case log
}

private struct SnappedAxisRangeKey: Hashable {
    /// Included so a pane switching between modes does not inherit the other
    /// mode's remembered range — a frequency axis and a time axis share
    /// nothing but their orientation.
    let mode: PlotMode
    let axis: PlotAxisKind
    let seriesID: ColumnKey?
    let scale: PlotAxisScale
}

private final class SnappedAxisRangeMemory {
    private var ranges: [SnappedAxisRangeKey: ClosedRange<Double>] = [:]

    func snappedRange(
        mode: PlotMode,
        axis: PlotAxisKind,
        seriesID: ColumnKey? = nil,
        scale: PlotAxisScale,
        rawLower: Double,
        rawUpper: Double,
        hysteresisFraction: Double
    ) -> ClosedRange<Double> {
        let key = SnappedAxisRangeKey(mode: mode, axis: axis, seriesID: seriesID, scale: scale)
        let ideal = idealRange(scale: scale, rawLower: rawLower, rawUpper: rawUpper)
        let hysteresis = PlotAxisHysteresis.clamped(hysteresisFraction)

        guard let current = ranges[key],
              current.lowerBound.isFinite,
              current.upperBound.isFinite,
              current.lowerBound < current.upperBound else {
            ranges[key] = ideal
            return ideal
        }

        var lower = current.lowerBound
        var upper = current.upperBound

        if ideal.upperBound > current.upperBound {
            upper = ideal.upperBound
        } else if ideal.upperBound < current.upperBound,
                  shouldContractUpper(
                    scale: scale,
                    rawUpper: rawUpper,
                    idealUpper: ideal.upperBound,
                    hysteresisFraction: hysteresis
                  ) {
            upper = ideal.upperBound
        }

        if ideal.lowerBound < current.lowerBound {
            lower = ideal.lowerBound
        } else if ideal.lowerBound > current.lowerBound,
                  shouldContractLower(
                    scale: scale,
                    rawLower: rawLower,
                    idealLower: ideal.lowerBound,
                    hysteresisFraction: hysteresis
                  ) {
            lower = ideal.lowerBound
        }

        guard lower.isFinite, upper.isFinite, lower < upper else {
            ranges[key] = ideal
            return ideal
        }

        let resolved = lower...upper
        ranges[key] = resolved
        return resolved
    }

    private func idealRange(
        scale: PlotAxisScale,
        rawLower: Double,
        rawUpper: Double
    ) -> ClosedRange<Double> {
        let lower = min(rawLower, rawUpper)
        let upper = max(rawLower, rawUpper)

        switch scale {
        case .log:
            let positiveLower = max(lower, .leastNonzeroMagnitude)
            let positiveUpper = max(upper, positiveLower)
            let snappedLower = powerOfTenFloor(positiveLower)
            var snappedUpper = powerOfTenCeiling(positiveUpper)

            if snappedLower >= snappedUpper {
                snappedUpper = powerOfTenCeiling(positiveUpper * 10)
            }
            return snappedLower...snappedUpper

        case .linear:
            return linearlyPaddedRange(lower: lower, upper: upper)
        }
    }

    private func linearlyPaddedRange(lower: Double, upper: Double) -> ClosedRange<Double> {
        let magnitude = max(abs(lower), abs(upper), 1e-12)
        let pad = max((upper - lower) * 0.08, magnitude * 1e-12)

        if lower >= 0 {
            return 0...max(upper + pad, magnitude * 1e-12)
        }
        if upper <= 0 {
            return min(lower - pad, -magnitude * 1e-12)...0
        }

        return (lower - pad)...(upper + pad)
    }

    private func shouldContractUpper(
        scale: PlotAxisScale,
        rawUpper: Double,
        idealUpper: Double,
        hysteresisFraction: Double
    ) -> Bool {
        guard rawUpper.isFinite else { return false }

        switch scale {
        case .log:
            let multiplier = logarithmicHysteresisMultiplier(hysteresisFraction)
            return rawUpper <= idealUpper / multiplier
        case .linear:
            let contractionFactor = linearContractionFactor(hysteresisFraction)
            if idealUpper > 0 {
                return rawUpper <= idealUpper * contractionFactor
            }
            return rawUpper <= idealUpper / contractionFactor
        }
    }

    private func shouldContractLower(
        scale: PlotAxisScale,
        rawLower: Double,
        idealLower: Double,
        hysteresisFraction: Double
    ) -> Bool {
        guard rawLower.isFinite else { return false }

        switch scale {
        case .log:
            let multiplier = logarithmicHysteresisMultiplier(hysteresisFraction)
            return rawLower >= idealLower * multiplier
        case .linear:
            let contractionFactor = linearContractionFactor(hysteresisFraction)
            if idealLower < 0 {
                return rawLower >= idealLower * contractionFactor
            }
            return rawLower >= idealLower
        }
    }

    private func linearContractionFactor(_ hysteresisFraction: Double) -> Double {
        max(0.05, 1 - PlotAxisHysteresis.clamped(hysteresisFraction))
    }

    private func logarithmicHysteresisMultiplier(_ hysteresisFraction: Double) -> Double {
        pow(10, PlotAxisHysteresis.clamped(hysteresisFraction))
    }

    private func powerOfTenFloor(_ value: Double) -> Double {
        pow(10, floor(log10(max(value, .leastNonzeroMagnitude))))
    }

    private func powerOfTenCeiling(_ value: Double) -> Double {
        pow(10, ceil(log10(max(value, .leastNonzeroMagnitude))))
    }
}

private struct LinearAxisRangeKey: Hashable {
    let mode: PlotMode
    let axis: PlotAxisKind
    let seriesID: ColumnKey?
}

private final class LinearAxisRangeMemory {
    private var ranges: [LinearAxisRangeKey: ClosedRange<Double>] = [:]

    func hystereticRange(
        mode: PlotMode,
        axis: PlotAxisKind,
        seriesID: ColumnKey? = nil,
        ideal: ClosedRange<Double>,
        rawLower: Double,
        rawUpper: Double,
        hysteresisFraction: Double
    ) -> ClosedRange<Double> {
        let key = LinearAxisRangeKey(mode: mode, axis: axis, seriesID: seriesID)
        let hysteresis = PlotAxisHysteresis.clamped(hysteresisFraction)

        guard ideal.lowerBound.isFinite,
              ideal.upperBound.isFinite,
              ideal.lowerBound < ideal.upperBound else {
            return ideal
        }

        guard let current = ranges[key],
              current.lowerBound.isFinite,
              current.upperBound.isFinite,
              current.lowerBound < current.upperBound else {
            ranges[key] = ideal
            return ideal
        }

        let span = max(current.upperBound - current.lowerBound, .leastNonzeroMagnitude)
        let margin = max(span * hysteresis, span * 1e-9)
        var lower = current.lowerBound
        var upper = current.upperBound

        if ideal.upperBound > current.upperBound {
            upper = ideal.upperBound
        } else if ideal.upperBound < current.upperBound,
                  rawUpper.isFinite,
                  rawUpper <= current.upperBound - margin {
            upper = ideal.upperBound
        }

        if ideal.lowerBound < current.lowerBound {
            lower = ideal.lowerBound
        } else if ideal.lowerBound > current.lowerBound,
                  rawLower.isFinite,
                  rawLower >= current.lowerBound + margin {
            lower = ideal.lowerBound
        }

        guard lower.isFinite, upper.isFinite, lower < upper else {
            ranges[key] = ideal
            return ideal
        }

        let resolved = lower...upper
        ranges[key] = resolved
        return resolved
    }
}

private struct PlotInteractionEventMonitor: View {
    var isEnabled: Bool
    var plotRect: CGRect
    var windowSeconds: Double
    var onPan: (Double) -> Void
    var onZoom: (Double, Double) -> Void

    var body: some View {
#if os(macOS)
        PlotMacInteractionEventMonitor(
            isEnabled: isEnabled,
            plotRect: plotRect,
            windowSeconds: windowSeconds,
            onPan: onPan,
            onZoom: onZoom
        )
#else
        PlotTouchInteractionView(
            isEnabled: isEnabled,
            plotRect: plotRect,
            windowSeconds: windowSeconds,
            onPan: onPan,
            onZoom: onZoom
        )
#endif
    }
}

#if os(macOS)
private struct PlotMacInteractionEventMonitor: NSViewRepresentable {
    var isEnabled: Bool
    var plotRect: CGRect
    var windowSeconds: Double
    var onPan: (Double) -> Void
    var onZoom: (Double, Double) -> Void

    func makeNSView(context: Context) -> PlotInteractionEventView {
        let view = PlotInteractionEventView()
        view.update(
            isEnabled: isEnabled,
            plotRect: plotRect,
            windowSeconds: windowSeconds,
            onPan: onPan,
            onZoom: onZoom
        )
        return view
    }

    func updateNSView(_ view: PlotInteractionEventView, context: Context) {
        view.update(
            isEnabled: isEnabled,
            plotRect: plotRect,
            windowSeconds: windowSeconds,
            onPan: onPan,
            onZoom: onZoom
        )
    }
}
#else
private struct PlotTouchInteractionView: View {
    var isEnabled: Bool
    var plotRect: CGRect
    var windowSeconds: Double
    var onPan: (Double) -> Void
    var onZoom: (Double, Double) -> Void

    @State private var previousDragTranslation: CGFloat = 0
    @State private var previousMagnification = 1.0

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard isEnabled, plotRect.width > 1 else { return }
                        let delta = value.translation.width - previousDragTranslation
                        previousDragTranslation = value.translation.width
                        guard abs(delta) >= 0.1 else { return }
                        onPan(Double(-2 * delta / plotRect.width) * windowSeconds)
                    }
                    .onEnded { _ in
                        previousDragTranslation = 0
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        guard isEnabled, plotRect.width > 1 else { return }
                        let magnification = max(0.05, value.magnification)
                        let scale = max(0.05, magnification / max(previousMagnification, 0.05))
                        previousMagnification = magnification
                        guard abs(scale - 1) >= 0.001 else { return }
                        onZoom(scale, 0.5)
                    }
                    .onEnded { _ in
                        previousMagnification = 1
                    }
            )
    }
}
#endif

#if os(macOS)
private final class PlotInteractionEventView: NSView {
    private var isInteractionEnabled = false
    private var plotRect: CGRect = .zero
    private var windowSeconds = 10.0
    private var onPan: (Double) -> Void = { _ in }
    private var onZoom: (Double, Double) -> Void = { _, _ in }
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installEventMonitorIfNeeded()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installEventMonitorIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            removeEventMonitor()
        } else {
            installEventMonitorIfNeeded()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(
        isEnabled: Bool,
        plotRect: CGRect,
        windowSeconds: Double,
        onPan: @escaping (Double) -> Void,
        onZoom: @escaping (Double, Double) -> Void
    ) {
        isInteractionEnabled = isEnabled
        self.plotRect = plotRect
        self.windowSeconds = windowSeconds
        self.onPan = onPan
        self.onZoom = onZoom
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isInteractionEnabled,
              let window,
              event.window === window else {
            return event
        }

        let location = convert(event.locationInWindow, from: nil)
        guard plotRect.contains(location) else {
            return event
        }

        switch event.type {
        case .scrollWheel:
            let horizontalDelta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaX
                : event.scrollingDeltaX * 16
            guard abs(horizontalDelta) > abs(event.scrollingDeltaY),
                  abs(horizontalDelta) >= 0.1,
                  plotRect.width > 1 else {
                return event
            }
            onPan(Double(-2 * horizontalDelta / plotRect.width) * windowSeconds)
            return nil
        case .magnify:
            let scale = max(0.05, 1 + event.magnification)
            guard abs(scale - 1) >= 0.001,
                  plotRect.width > 1 else {
                return nil
            }
            let anchor = Double((location.x - plotRect.minX) / plotRect.width)
            onZoom(Double(scale), min(max(anchor, 0), 1))
            return nil
        default:
            return event
        }
    }
}
#endif

struct CursorSelection {
    let screenX: CGFloat
    let xText: String
    let values: [CursorValue]
}

struct CursorValue: Identifiable {
    let id: ColumnKey
    let label: String
    let color: Color
    let screenPoint: CGPoint
    let yText: String
}

// Signature for change detection on the published cursor selection.
//
// Deliberately excludes screenX and xText — those track pixel-level cursor
// motion and would force parent views to re-render on every hover tick.
// Including only the per-series (id, screenPoint, yText) means the change
// fires when the nearest *data point* changes, not on sub-point sweeps.
// PlotCanvas's local activeCursorSelection still has live screenX/xText
// for the cursor overlay and legend; this only gates outbound notifications.
private struct CursorSelectionSignature: Equatable {
    let values: [CursorValueSignature]

    init(selection: CursorSelection) {
        values = selection.values.map(CursorValueSignature.init)
    }
}

private struct CursorValueSignature: Equatable {
    let id: ColumnKey
    let screenPoint: CGPoint
    let yText: String

    init(value: CursorValue) {
        id = value.id
        screenPoint = value.screenPoint
        yText = value.yText
    }
}

extension PlotTracePalette {
    // Cache one slot keyed on the raw @AppStorage string so per-frame body
    // evaluations don't re-split, re-validate, and rebuild SwiftUI colors
    // when the user hasn't changed the palette.
    private struct PaletteCache {
        var rawValue: String
        var defaults: [String]
        var colors: [Color]
    }
    nonisolated(unsafe) private static var paletteCache: PaletteCache?
    private static let paletteCacheLock = NSLock()

    static func colors(from rawValue: String, defaults: [String] = PlotTracePalette.defaultHexColors) -> [Color] {
        paletteCacheLock.lock()
        defer { paletteCacheLock.unlock() }
        if let cache = paletteCache,
           cache.rawValue == rawValue,
           cache.defaults == defaults {
            return cache.colors
        }
        let resolved = hexColors(from: rawValue, defaults: defaults).map { Color(plotTraceHex: $0) }
        paletteCache = PaletteCache(rawValue: rawValue, defaults: defaults, colors: resolved)
        return resolved
    }

    static func hexString(from color: Color, in environment: EnvironmentValues) -> String {
        let resolved = color.resolve(in: environment)
        let red = Int((Double(resolved.red) * 255).rounded())
        let green = Int((Double(resolved.green) * 255).rounded())
        let blue = Int((Double(resolved.blue) * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

private extension Color {
    init(plotTraceHex hex: String) {
        let normalized = PlotTracePalette.normalizedHex(hex) ?? PlotTracePalette.defaultHexColors[0]
        let value = String(normalized.dropFirst())
        let red = Double(Int(value.prefix(2), radix: 16) ?? 0) / 255
        let green = Double(Int(value.dropFirst(2).prefix(2), radix: 16) ?? 0) / 255
        let blue = Double(Int(value.dropFirst(4).prefix(2), radix: 16) ?? 0) / 255
        self.init(red: red, green: green, blue: blue)
    }
}

private struct CursorTimeIndicatorIcon: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
            let top = CGPoint(x: center.x, y: size.height * 0.18)
            let bottom = CGPoint(x: center.x, y: size.height * 0.82)
            var bar = Path()
            bar.move(to: top)
            bar.addLine(to: bottom)

            context.stroke(
                bar,
                with: .color(.secondary),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
            )
            context.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - 3,
                    y: center.y - 3,
                    width: 6,
                    height: 6
                )),
                with: .color(.secondary)
            )
        }
        .accessibilityHidden(true)
    }
}

private enum PlotProfiler {
    private static let logIntervalNanos: UInt64 = 500_000_000
    private static let slowThresholdMs: Double = 4
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastLogByName: [String: UInt64] = [:]

    static let enabled: Bool = {
        let value = ProcessInfo.processInfo.environment["TWINLEAF_PLOT_PROFILE"]?.lowercased()
        return value == "1"
            || value == "true"
            || value == "yes"
            || UserDefaults.standard.bool(forKey: "PlotProfilingEnabled")
    }()

    static func start() -> UInt64 {
        guard enabled else { return 0 }
        return DispatchTime.now().uptimeNanoseconds
    }

    static func finish(_ name: String, start: UInt64, details: @autoclosure () -> String) {
        guard enabled, start > 0 else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Double(now - start) / 1_000_000

        lock.lock()
        let lastLog = lastLogByName[name] ?? 0
        let shouldLog = elapsedMs >= slowThresholdMs || now - lastLog >= logIntervalNanos
        if shouldLog {
            lastLogByName[name] = now
        }
        lock.unlock()

        guard shouldLog else { return }
        fputs(
            "[Twinleaf] profile \(name): \(String(format: "%.2f", elapsedMs)) ms \(details())\n",
            stderr
        )
    }
}
