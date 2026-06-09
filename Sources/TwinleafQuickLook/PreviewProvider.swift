// SPDX-License-Identifier: Apache-2.0

import Foundation
import Quartz
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let summary = TIOPreviewSummary(url: request.fileURL)
        let html = summary.htmlDocument()
        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 820, height: 620)
        ) { reply in
            reply.title = summary.title
            reply.stringEncoding = .utf8
            return Data(html.utf8)
        }
        return reply
    }
}

private struct TIOPreviewSummary {
    private static let previewByteLimit = 512 * 1_024
    private static let maxPrintableRuns = 14
    private static let minPrintableRunLength = 5
    private static let plotPreviewDuration = 100.0

    let url: URL
    let fileSize: UInt64
    let modifiedDate: Date?
    let previewBytes: Int
    let printableRuns: [String]
    let log: TIOLogPreview

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }

    init(url: URL) {
        self.url = url

        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modifiedDate = attributes[.modificationDate] as? Date

        let previewData = Self.readPreviewBytes(from: url)
        previewBytes = previewData.count
        printableRuns = Self.printableRuns(in: previewData)
        log = TIOLogPreviewParser(url: url, previewDuration: Self.plotPreviewDuration).parse()
    }

    func htmlDocument() -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root {
            color-scheme: light dark;
            --background: #f5f6f7;
            --foreground: #16191c;
            --secondary: #626a73;
            --line: rgba(0, 0, 0, 0.12);
            --panel: rgba(255, 255, 255, 0.76);
            --panel-strong: rgba(255, 255, 255, 0.92);
            --accent: #3f8f6c;
            --accent-soft: rgba(63, 143, 108, 0.18);
            --code: rgba(20, 24, 28, 0.08);
            --grid: rgba(34, 40, 46, 0.12);
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --background: #151718;
                --foreground: #eff1f2;
                --secondary: #a6adb5;
                --line: rgba(255, 255, 255, 0.14);
                --panel: rgba(255, 255, 255, 0.07);
                --panel-strong: rgba(255, 255, 255, 0.10);
                --accent: #80c99d;
                --accent-soft: rgba(128, 201, 157, 0.16);
                --code: rgba(255, 255, 255, 0.08);
                --grid: rgba(255, 255, 255, 0.12);
            }
        }
        * { box-sizing: border-box; }
        html {
            height: 100%;
            overflow: hidden;
        }
        body {
            margin: 0;
            padding: 26px;
            height: 100%;
            min-height: 0;
            display: flex;
            flex-direction: column;
            overflow: hidden;
            background: var(--background);
            color: var(--foreground);
            font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
        }
        header {
            display: flex;
            align-items: center;
            gap: 14px;
            margin-bottom: 18px;
            flex: none;
        }
        .icon {
            width: 44px;
            height: 44px;
            border-radius: 11px;
            display: grid;
            place-items: center;
            background: var(--accent-soft);
            border: 1px solid color-mix(in srgb, var(--accent) 34%, transparent);
            color: var(--accent);
            font-size: 18px;
            font-weight: 700;
            letter-spacing: 0;
        }
        h1 {
            margin: 0;
            font-size: 22px;
            line-height: 1.15;
            font-weight: 650;
        }
        h2 {
            margin: 22px 0 10px;
            font-size: 13px;
            color: var(--secondary);
            font-weight: 600;
            text-transform: uppercase;
        }
        .subtitle, .meta-line {
            margin-top: 5px;
            color: var(--secondary);
        }
        .tabs > input {
            position: absolute;
            opacity: 0;
            pointer-events: none;
        }
        .tabs {
            flex: 1;
            min-height: 0;
            display: flex;
            flex-direction: column;
        }
        .tab-labels {
            display: inline-flex;
            align-self: flex-start;
            flex: none;
            gap: 4px;
            padding: 3px;
            margin-bottom: 14px;
            border: 1px solid var(--line);
            border-radius: 9px;
            background: color-mix(in srgb, var(--panel) 78%, transparent);
        }
        .tab-labels label {
            display: block;
            min-width: 88px;
            padding: 6px 14px;
            border-radius: 7px;
            color: var(--secondary);
            text-align: center;
            font-weight: 550;
        }
        #tab-plot:checked ~ .tab-labels label[for="tab-plot"],
        #tab-metadata:checked ~ .tab-labels label[for="tab-metadata"] {
            background: var(--panel-strong);
            color: var(--foreground);
            box-shadow: 0 1px 6px rgba(0, 0, 0, 0.10);
        }
        .panels {
            flex: 1;
            min-height: 0;
            overflow: hidden;
        }
        .tab-panel {
            display: none;
            height: 100%;
            overflow: auto;
        }
        #tab-plot:checked ~ .panels .plot-panel,
        #tab-metadata:checked ~ .panels .metadata-panel {
            display: block;
        }
        .panel {
            border: 1px solid var(--line);
            border-radius: 10px;
            background: var(--panel);
            overflow: hidden;
        }
        .plot-card {
            padding: 14px;
            min-width: 680px;
        }
        .plot-title {
            display: flex;
            justify-content: space-between;
            gap: 12px;
            margin-bottom: 10px;
            color: var(--secondary);
            font-size: 12px;
        }
        svg {
            display: block;
            width: 100%;
            height: auto;
        }
        .preview-note {
            margin: 0 0 12px;
            color: var(--secondary);
            font-size: 12px;
        }
        .axis-label, .tick-label {
            fill: var(--secondary);
            font: 12px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
        }
        .grid-line {
            stroke: var(--grid);
            stroke-width: 1;
        }
        .axis-line {
            stroke: var(--line);
            stroke-width: 1.2;
        }
        .trace {
            fill: none;
            stroke: var(--accent);
            stroke-width: 2.1;
            stroke-linecap: round;
            stroke-linejoin: round;
        }
        dl {
            display: grid;
            grid-template-columns: max-content 1fr;
            margin: 0;
        }
        dt, dd {
            margin: 0;
            padding: 10px 12px;
            border-bottom: 1px solid var(--line);
        }
        dt {
            color: var(--secondary);
            font-weight: 500;
        }
        dd {
            min-width: 0;
            overflow-wrap: anywhere;
        }
        dt:last-of-type, dd:last-of-type {
            border-bottom: 0;
        }
        table {
            width: 100%;
            border-collapse: collapse;
        }
        th, td {
            padding: 9px 11px;
            border-bottom: 1px solid var(--line);
            text-align: left;
            vertical-align: top;
        }
        th {
            color: var(--secondary);
            font-weight: 600;
            background: color-mix(in srgb, var(--panel) 55%, transparent);
        }
        tr:last-child td {
            border-bottom: 0;
        }
        code {
            white-space: pre-wrap;
            overflow-wrap: anywhere;
            font: 12px "SF Mono", Menlo, monospace;
        }
        .empty {
            margin: 0;
            padding: 18px;
            color: var(--secondary);
        }
        </style>
        </head>
        <body>
        <header>
            <div class="icon">TIO</div>
            <div>
                <h1>\(Self.escapeHTML(title))</h1>
                <div class="subtitle">Twinleaf TIO Log</div>
            </div>
        </header>
        <div class="tabs">
            <input id="tab-plot" type="radio" name="tabs" checked>
            <input id="tab-metadata" type="radio" name="tabs">
            <div class="tab-labels">
                <label for="tab-plot">Plot</label>
                <label for="tab-metadata">Metadata</label>
            </div>
            <div class="panels">
                <section class="tab-panel plot-panel">
                    \(plotHTML())
                </section>
                <section class="tab-panel metadata-panel">
                    \(metadataHTML())
                </section>
            </div>
        </div>
        </body>
        </html>
        """
    }

    private func plotHTML() -> String {
        guard let plot = log.plot, plot.points.count >= 2 else {
            let message = log.plot?.points.isEmpty == false
                ? "Not enough samples to draw a plot."
                : "No parseable stream samples were found for the default stream column."
            return """
            <section class="panel">
                <p class="empty">\(Self.escapeHTML(message))</p>
            </section>
            """
        }

        return """
        <section class="panel plot-card">
            <div class="plot-title">
                <div>\(Self.escapeHTML(plot.title))</div>
                <div>\(Self.escapeHTML(plot.sampleSummary))</div>
            </div>
            <p class="preview-note">Showing the first \(Self.escapeHTML(Self.formatDuration(plot.previewDuration))) of the default stream column.</p>
            \(Self.svg(for: plot))
        </section>
        """
    }

    private func metadataHTML() -> String {
        let modifiedText = modifiedDate.map(Self.dateFormatter.string(from:)) ?? "Unknown"
        let selected = log.plot?.title ?? log.selectedKeyDescription ?? "None"
        let parseMessage = log.parseMessage.map {
            "<dt>Parser</dt><dd>\(Self.escapeHTML($0))</dd>"
        } ?? ""
        let snippets = printableRuns.isEmpty
            ? "<p class=\"empty\">No readable strings were found in the first \(Self.byteCount(previewBytes)).</p>"
            : printableRuns.map { "<tr><td><code>\(Self.escapeHTML($0))</code></td></tr>" }.joined(separator: "\n")

        return """
        <section class="panel">
            <dl>
                <dt>File</dt><dd>\(Self.escapeHTML(url.lastPathComponent))</dd>
                <dt>Size</dt><dd>\(Self.byteCount(fileSize))</dd>
                <dt>Modified</dt><dd>\(Self.escapeHTML(modifiedText))</dd>
                <dt>Packets Read</dt><dd>\(log.packetCount)</dd>
                <dt>Preview Samples</dt><dd>\(log.sampleCount)</dd>
                <dt>Preview Window</dt><dd>First \(Self.escapeHTML(Self.formatDuration(log.previewDuration)))</dd>
                <dt>Default Plot</dt><dd>\(Self.escapeHTML(selected))</dd>
                \(parseMessage)
            </dl>
        </section>
        <h2>Devices</h2>
        \(deviceTableHTML())
        <h2>Streams</h2>
        \(streamTableHTML())
        <h2>Columns</h2>
        \(columnTableHTML())
        <h2>Readable Strings</h2>
        <section class="panel">
            <table><tbody>\(snippets)</tbody></table>
        </section>
        """
    }

    private func deviceTableHTML() -> String {
        let rows = log.devices.sorted { $0.route < $1.route }.map { device in
            """
            <tr>
                <td><code>\(Self.escapeHTML(device.route))</code></td>
                <td>\(Self.escapeHTML(device.name))</td>
                <td>\(Self.escapeHTML(device.serialNumber))</td>
                <td>\(Self.escapeHTML(device.firmwareHash))</td>
                <td>\(device.nStreams)</td>
            </tr>
            """
        }.joined(separator: "\n")

        guard !rows.isEmpty else {
            return "<section class=\"panel\"><p class=\"empty\">No device metadata found.</p></section>"
        }
        return """
        <section class="panel">
            <table>
                <thead><tr><th>Route</th><th>Name</th><th>Serial</th><th>Firmware</th><th>Streams</th></tr></thead>
                <tbody>\(rows)</tbody>
            </table>
        </section>
        """
    }

    private func streamTableHTML() -> String {
        let rows = log.streams.map { stream in
            """
            <tr>
                <td><code>\(Self.escapeHTML(stream.route))</code></td>
                <td>\(stream.id)</td>
                <td>\(Self.escapeHTML(stream.name))</td>
                <td>\(stream.nColumns)</td>
                <td>\(stream.sampleSize)</td>
                <td>\(Self.escapeHTML(Self.formatNumber(stream.sampleRate))) Hz</td>
            </tr>
            """
        }.joined(separator: "\n")

        guard !rows.isEmpty else {
            return "<section class=\"panel\"><p class=\"empty\">No stream metadata found.</p></section>"
        }
        return """
        <section class="panel">
            <table>
                <thead><tr><th>Route</th><th>ID</th><th>Name</th><th>Columns</th><th>Sample Size</th><th>Rate</th></tr></thead>
                <tbody>\(rows)</tbody>
            </table>
        </section>
        """
    }

    private func columnTableHTML() -> String {
        let rows = log.columns.map { column in
            """
            <tr>
                <td><code>\(Self.escapeHTML(column.route))</code></td>
                <td>\(column.streamID)</td>
                <td>\(column.index)</td>
                <td>\(Self.escapeHTML(column.name))</td>
                <td>\(Self.escapeHTML(column.units))</td>
                <td>\(Self.escapeHTML(column.dataType.label))</td>
            </tr>
            """
        }.joined(separator: "\n")

        guard !rows.isEmpty else {
            return "<section class=\"panel\"><p class=\"empty\">No column metadata found.</p></section>"
        }
        return """
        <section class="panel">
            <table>
                <thead><tr><th>Route</th><th>Stream</th><th>Index</th><th>Name</th><th>Units</th><th>Type</th></tr></thead>
                <tbody>\(rows)</tbody>
            </table>
        </section>
        """
    }

    private static func svg(for plot: TIOPlotPreview) -> String {
        let points = downsample(plot.points, maxCount: 1_000)
        let width = 760.0
        let height = 360.0
        let left = 58.0
        let right = 18.0
        let top = 20.0
        let bottom = 42.0
        let graphWidth = width - left - right
        let graphHeight = height - top - bottom

        let xMin = plot.xRange.lowerBound
        let xMax = plot.xRange.upperBound
        let yMin = plot.yRange.lowerBound
        let yMax = plot.yRange.upperBound

        func sx(_ x: Double) -> Double {
            left + ((x - xMin) / (xMax - xMin)) * graphWidth
        }
        func sy(_ y: Double) -> Double {
            top + (1.0 - ((y - yMin) / (yMax - yMin))) * graphHeight
        }

        let hGrid = (0...4).map { index -> String in
            let fraction = Double(index) / 4.0
            let y = top + fraction * graphHeight
            let value = yMax - fraction * (yMax - yMin)
            return """
            <line class="grid-line" x1="\(fmt(left))" y1="\(fmt(y))" x2="\(fmt(left + graphWidth))" y2="\(fmt(y))"/>
            <text class="tick-label" x="\(fmt(left - 8))" y="\(fmt(y + 4))" text-anchor="end">\(escapeHTML(formatNumber(value)))</text>
            """
        }.joined(separator: "\n")

        let vGrid = (0...4).map { index -> String in
            let fraction = Double(index) / 4.0
            let x = left + fraction * graphWidth
            let value = xMin + fraction * (xMax - xMin)
            return """
            <line class="grid-line" x1="\(fmt(x))" y1="\(fmt(top))" x2="\(fmt(x))" y2="\(fmt(top + graphHeight))"/>
            <text class="tick-label" x="\(fmt(x))" y="\(fmt(top + graphHeight + 24))" text-anchor="middle">\(escapeHTML(formatNumber(value - xMin)))</text>
            """
        }.joined(separator: "\n")

        let pointList = points
            .map { "\(fmt(sx($0.x))),\(fmt(sy($0.y)))" }
            .joined(separator: " ")

        let yTitle = plot.units.isEmpty ? plot.columnName : "\(plot.columnName) (\(plot.units))"

        return """
        <svg viewBox="0 0 \(fmt(width)) \(fmt(height))" role="img" aria-label="\(escapeHTML(plot.title))">
            <rect x="0" y="0" width="\(fmt(width))" height="\(fmt(height))" rx="8" fill="transparent"/>
            \(hGrid)
            \(vGrid)
            <line class="axis-line" x1="\(fmt(left))" y1="\(fmt(top + graphHeight))" x2="\(fmt(left + graphWidth))" y2="\(fmt(top + graphHeight))"/>
            <line class="axis-line" x1="\(fmt(left))" y1="\(fmt(top))" x2="\(fmt(left))" y2="\(fmt(top + graphHeight))"/>
            <polyline class="trace" points="\(pointList)"/>
            <text class="axis-label" x="\(fmt(left + graphWidth / 2))" y="\(fmt(height - 6))" text-anchor="middle">seconds</text>
            <text class="axis-label" transform="translate(14 \(fmt(top + graphHeight / 2))) rotate(-90)" text-anchor="middle">\(escapeHTML(yTitle))</text>
        </svg>
        """
    }

    private static func downsample(_ points: [TIOPlotPoint], maxCount: Int) -> [TIOPlotPoint] {
        guard points.count > maxCount, maxCount > 2 else { return points }
        let stride = Double(points.count - 1) / Double(maxCount - 1)
        return (0..<maxCount).map { index in
            points[min(points.count - 1, Int((Double(index) * stride).rounded()))]
        }
    }

    private static func readPreviewBytes(from url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Data()
        }
        defer {
            try? handle.close()
        }
        return (try? handle.read(upToCount: previewByteLimit)) ?? Data()
    }

    private static func printableRuns(in data: Data) -> [String] {
        var runs: [String] = []
        var current: [UInt8] = []

        func finishRun() {
            guard current.count >= minPrintableRunLength else {
                current.removeAll(keepingCapacity: true)
                return
            }
            if let text = String(bytes: current, encoding: .utf8) {
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    runs.append(normalized)
                }
            }
            current.removeAll(keepingCapacity: true)
        }

        for byte in data {
            if byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte < 127) {
                current.append(byte)
            } else {
                finishRun()
                if runs.count >= maxPrintableRuns {
                    break
                }
            }
        }
        finishRun()
        return Array(runs.prefix(maxPrintableRuns))
    }

    private static func byteCount(_ bytes: Int) -> String {
        byteCount(UInt64(bytes))
    }

    private static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return "?" }
        let magnitude = Swift.abs(value)
        if magnitude == 0 {
            return "0"
        } else if magnitude >= 10_000 || magnitude < 0.001 {
            return String(format: "%.3g", value)
        } else if magnitude < 1 {
            return String(format: "%.4f", value)
        } else if magnitude < 100 {
            return String(format: "%.3f", value)
        } else {
            return String(format: "%.1f", value)
        }
    }

    private static func formatDuration(_ value: Double) -> String {
        guard value.isFinite else { return "?" }
        if value.rounded() == value {
            return "\(Int(value)) seconds"
        }
        return "\(formatNumber(value)) seconds"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct TIOLogPreview {
    var packetCount: Int
    var sampleCount: Int
    var previewDuration: Double
    var parseMessage: String?
    var selectedKeyDescription: String?
    var devices: [TIODevicePreview]
    var streams: [TIOStreamPreview]
    var columns: [TIOColumnPreview]
    var plot: TIOPlotPreview?
}

private struct TIODevicePreview {
    let route: String
    let name: String
    let serialNumber: String
    let firmwareHash: String
    let nStreams: Int
}

private struct TIOStreamPreview {
    let route: String
    let id: UInt8
    let name: String
    let nColumns: Int
    let sampleSize: Int
    let sampleRate: Double
}

private struct TIOColumnPreview {
    let route: String
    let streamID: UInt8
    let index: UInt8
    let name: String
    let units: String
    let dataType: TIODataType
}

private struct TIOPlotPreview {
    let route: String
    let streamID: UInt8
    let streamName: String
    let columnIndex: UInt8
    let columnName: String
    let units: String
    let sampleRate: Double
    let totalSamples: Int
    let previewDuration: Double
    let reachedPreviewLimit: Bool
    let windowStart: Double?
    let points: [TIOPlotPoint]

    var title: String {
        "\(route) \(streamName).\(columnName)"
    }

    var sampleSummary: String {
        let suffix = reachedPreviewLimit ? "" : " available"
        return "\(totalSamples) sample\(totalSamples == 1 ? "" : "s")\(suffix)"
    }

    var xRange: ClosedRange<Double> {
        if let windowStart, previewDuration > 0 {
            return windowStart...(windowStart + previewDuration)
        }
        return paddedRange(points.map(\.x))
    }

    var yRange: ClosedRange<Double> {
        paddedRange(points.map(\.y))
    }

    private func paddedRange(_ values: [Double]) -> ClosedRange<Double> {
        let finiteValues = values.filter(\.isFinite)
        guard let minValue = finiteValues.min(), let maxValue = finiteValues.max() else {
            return 0...1
        }
        if minValue == maxValue {
            let pad = max(1.0, Swift.abs(minValue) * 0.05)
            return (minValue - pad)...(maxValue + pad)
        }
        let pad = (maxValue - minValue) * 0.06
        return (minValue - pad)...(maxValue + pad)
    }
}

private struct TIOPlotPoint {
    let x: Double
    let y: Double
}

private struct TIOColumnKey: Hashable {
    let route: String
    let streamID: UInt8
    let columnIndex: UInt8
}

private final class TIOLogPreviewParser {
    private static let maxStoredPlotPoints = 50_000
    private static let packetReadSize = 64 * 1_024

    private let url: URL
    private let previewDuration: Double
    private var devices: [String: TIODeviceMetadata] = [:]
    private var packetCount = 0
    private var sampleCount = 0
    private var parseMessage: String?

    init(url: URL, previewDuration: Double) {
        self.url = url
        self.previewDuration = previewDuration
    }

    func parse() -> TIOLogPreview {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return TIOLogPreview(
                packetCount: 0,
                sampleCount: 0,
                previewDuration: previewDuration,
                parseMessage: "Could not read file.",
                selectedKeyDescription: nil,
                devices: [],
                streams: [],
                columns: [],
                plot: nil
            )
        }

        packetCount = 0
        sampleCount = 0
        parseMessage = nil

        var defaultKey: TIOColumnKey?
        var accumulator = TIOPlotAccumulator(
            maxPoints: Self.maxStoredPlotPoints,
            previewDuration: previewDuration
        )

        scanFile { packet in
            packetCount += 1
            if packet.type == TIOPacketType.metadata {
                parseMetadata(packet.payload, route: packet.route)
                if defaultKey == nil {
                    defaultKey = defaultPlotKey()
                }
            }

            guard let key = defaultKey,
                  packet.type >= TIOPacketType.streamBase,
                  packet.type - TIOPacketType.streamBase == key.streamID else {
                return true
            }

            return parseStreamData(packet.payload, route: packet.route, key: key, into: &accumulator)
        }

        let selectedKey = defaultKey ?? defaultPlotKey()
        let plot = selectedKey.flatMap { makePlot(for: $0, accumulator: accumulator) }
        return TIOLogPreview(
            packetCount: packetCount,
            sampleCount: sampleCount,
            previewDuration: previewDuration,
            parseMessage: parseMessage,
            selectedKeyDescription: selectedKey.map(description(for:)),
            devices: devicePreviews(),
            streams: streamPreviews(),
            columns: columnPreviews(),
            plot: plot
        )
    }

    private func scanFile(visit: (TIOPacket) -> Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            parseMessage = "Could not read file."
            return
        }
        defer {
            try? handle.close()
        }

        var buffer = Data()
        var byteOffset = 0
        var shouldContinue = true

        while shouldContinue {
            while shouldContinue {
                switch TIOPacket.parsePrefix(buffer) {
                case .packet(let packet):
                    shouldContinue = visit(packet)
                    byteOffset += packet.length
                    buffer.removeSubrange(0..<packet.length)
                case .needMore:
                    shouldContinue = readMore(from: handle, into: &buffer)
                    if !shouldContinue, !buffer.isEmpty, parseMessage == nil {
                        parseMessage = "Stopped parsing with \(buffer.count) trailing byte\(buffer.count == 1 ? "" : "s")."
                    }
                case .invalid:
                    parseMessage = "Stopped parsing at byte \(byteOffset)."
                    return
                }
            }
        }
    }

    private func readMore(from handle: FileHandle, into buffer: inout Data) -> Bool {
        guard let chunk = try? handle.read(upToCount: Self.packetReadSize),
              !chunk.isEmpty else {
            return false
        }
        buffer.append(chunk)
        return true
    }

    private func parseMetadata(_ payload: Data, route: String) {
        guard payload.count >= 2 else { return }
        let metadataType = payload[0]
        let body = Data(payload.dropFirst(2))

        switch metadataType {
        case 1:
            guard let metadata = TIODeviceMetadata.parse(route: route, body: body) else { return }
            var existing = devices[route] ?? TIODeviceMetadata(route: route)
            existing.name = metadata.name
            existing.serialNumber = metadata.serialNumber
            existing.firmwareHash = metadata.firmwareHash
            existing.nStreams = metadata.nStreams
            devices[route] = existing
        case 2:
            guard let metadata = TIOStreamMetadata.parse(body: body) else { return }
            var device = devices[route] ?? TIODeviceMetadata(route: route)
            var stream = device.streams[metadata.id] ?? TIOStreamState(id: metadata.id)
            stream.metadata = metadata
            device.streams[metadata.id] = stream
            devices[route] = device
        case 3:
            guard let metadata = TIOSegmentMetadata.parse(body: body) else { return }
            var device = devices[route] ?? TIODeviceMetadata(route: route)
            var stream = device.streams[metadata.streamID] ?? TIOStreamState(id: metadata.streamID)
            stream.segments[metadata.id] = metadata
            if stream.currentSegmentID == nil {
                stream.currentSegmentID = metadata.id
            }
            device.streams[metadata.streamID] = stream
            devices[route] = device
        case 4:
            guard let metadata = TIOColumnMetadata.parse(body: body) else { return }
            var device = devices[route] ?? TIODeviceMetadata(route: route)
            var stream = device.streams[metadata.streamID] ?? TIOStreamState(id: metadata.streamID)
            stream.columns[metadata.index] = metadata
            device.streams[metadata.streamID] = stream
            devices[route] = device
        default:
            return
        }
    }

    private func parseStreamData(
        _ payload: Data,
        route: String,
        key: TIOColumnKey,
        into accumulator: inout TIOPlotAccumulator
    ) -> Bool {
        guard route == key.route,
              payload.count >= 4,
              let device = devices[route],
              let stream = device.streams[key.streamID],
              let streamMetadata = stream.metadata,
              let column = stream.columns[key.columnIndex],
              let columnOffset = stream.columnOffset(for: key.columnIndex),
              streamMetadata.sampleSize > 0 else {
            return true
        }

        let firstSample = TIOBinary.readUInt24(payload, at: 0) ?? 0
        let segmentID = payload[3]
        let segment = stream.segments[segmentID]
            ?? stream.currentSegmentID.flatMap { stream.segments[$0] }
        guard let segment,
              segment.samplingRate > 0,
              segment.decimation > 0,
              columnOffset + column.dataType.size <= streamMetadata.sampleSize else {
            return true
        }

        let dataBytes = Data(payload.dropFirst(4))
        guard dataBytes.count >= streamMetadata.sampleSize else { return true }
        let samplePayloadCount = dataBytes.count / streamMetadata.sampleSize
        let period = Double(segment.decimation) / Double(segment.samplingRate)

        for sampleIndex in 0..<samplePayloadCount {
            let sampleStart = sampleIndex * streamMetadata.sampleSize
            let valueOffset = sampleStart + columnOffset
            let sampleNumber = Double(firstSample) + Double(sampleIndex)
            let timestamp = Double(segment.startTime) + period * (sampleNumber + 1)
            guard let value = column.dataType.readValue(from: dataBytes, at: valueOffset),
                  value.isFinite else {
                continue
            }
            guard accumulator.append(TIOPlotPoint(x: timestamp, y: value)) else {
                return false
            }
            sampleCount += 1
        }
        return true
    }

    private func defaultPlotKey() -> TIOColumnKey? {
        for route in devices.keys.sorted() {
            guard let device = devices[route] else { continue }
            for streamID in device.streams.keys.sorted() {
                guard let stream = device.streams[streamID],
                      stream.metadata != nil else { continue }
                for columnIndex in stream.columns.keys.sorted() {
                    guard let column = stream.columns[columnIndex],
                          column.dataType.isNumeric,
                          stream.columnOffset(for: columnIndex) != nil else {
                        continue
                    }
                    return TIOColumnKey(route: route, streamID: streamID, columnIndex: columnIndex)
                }
            }
        }
        return nil
    }

    private func makePlot(for key: TIOColumnKey, accumulator: TIOPlotAccumulator) -> TIOPlotPreview? {
        guard let device = devices[key.route],
              let stream = device.streams[key.streamID],
              let streamMetadata = stream.metadata,
              let column = stream.columns[key.columnIndex] else {
            return nil
        }

        let sampleRate = stream.effectiveSampleRate ?? 0
        return TIOPlotPreview(
            route: key.route,
            streamID: key.streamID,
            streamName: streamMetadata.name,
            columnIndex: key.columnIndex,
            columnName: column.name,
            units: column.units,
            sampleRate: sampleRate,
            totalSamples: accumulator.totalSamples,
            previewDuration: previewDuration,
            reachedPreviewLimit: accumulator.reachedPreviewLimit,
            windowStart: accumulator.windowStart,
            points: accumulator.points
        )
    }

    private func description(for key: TIOColumnKey) -> String {
        guard let device = devices[key.route],
              let stream = device.streams[key.streamID],
              let streamMetadata = stream.metadata,
              let column = stream.columns[key.columnIndex] else {
            return "\(key.route) stream \(key.streamID) column \(key.columnIndex)"
        }
        return "\(key.route) \(streamMetadata.name).\(column.name)"
    }

    private func devicePreviews() -> [TIODevicePreview] {
        devices.values
            .sorted { $0.route < $1.route }
            .map {
                TIODevicePreview(
                    route: $0.route,
                    name: $0.name,
                    serialNumber: $0.serialNumber,
                    firmwareHash: $0.firmwareHash,
                    nStreams: $0.nStreams
                )
            }
    }

    private func streamPreviews() -> [TIOStreamPreview] {
        devices.values
            .sorted { $0.route < $1.route }
            .flatMap { device in
                device.streams.values
                    .compactMap { stream -> TIOStreamPreview? in
                        guard let metadata = stream.metadata else { return nil }
                        return TIOStreamPreview(
                            route: device.route,
                            id: metadata.id,
                            name: metadata.name,
                            nColumns: metadata.nColumns,
                            sampleSize: metadata.sampleSize,
                            sampleRate: stream.effectiveSampleRate ?? 0
                        )
                    }
                    .sorted { $0.id < $1.id }
            }
    }

    private func columnPreviews() -> [TIOColumnPreview] {
        devices.values
            .sorted { $0.route < $1.route }
            .flatMap { device in
                device.streams.values.sorted { $0.id < $1.id }.flatMap { stream in
                    stream.columns.values
                        .sorted { $0.index < $1.index }
                        .map {
                            TIOColumnPreview(
                                route: device.route,
                                streamID: $0.streamID,
                                index: $0.index,
                                name: $0.name,
                                units: $0.units,
                                dataType: $0.dataType
                            )
                        }
                }
            }
    }
}

private struct TIOPlotAccumulator {
    let maxPoints: Int
    let previewDuration: Double
    private(set) var points: [TIOPlotPoint] = []
    private(set) var totalSamples = 0
    private(set) var reachedPreviewLimit = false
    private(set) var windowStart: Double?

    mutating func append(_ point: TIOPlotPoint) -> Bool {
        if let windowStart {
            if point.x > windowStart + previewDuration {
                reachedPreviewLimit = true
                return false
            }
        } else {
            windowStart = point.x
        }

        totalSamples += 1
        points.append(point)
        if points.count > maxPoints {
            compact()
        }
        return true
    }

    private mutating func compact() {
        guard points.count > 2 else { return }
        var compacted: [TIOPlotPoint] = []
        compacted.reserveCapacity((points.count + 1) / 2)
        var index = 0
        while index < points.count {
            if index + 1 < points.count {
                let first = points[index]
                let second = points[index + 1]
                compacted.append(TIOPlotPoint(
                    x: (first.x + second.x) / 2,
                    y: (first.y + second.y) / 2
                ))
            } else {
                compacted.append(points[index])
            }
            index += 2
        }
        points = compacted
    }
}

private struct TIOPacketType {
    static let metadata: UInt8 = 11
    static let streamBase: UInt8 = 128
}

private struct TIOPacket {
    let type: UInt8
    let route: String
    let payload: Data
    let length: Int

    enum ParseResult {
        case packet(TIOPacket)
        case needMore
        case invalid
    }

    static func parsePrefix(_ data: Data) -> ParseResult {
        guard data.count >= 4 else { return .needMore }
        let type = data[0]
        guard isPacketTypeValid(type) else { return .invalid }
        let routingSizeAndTTL = data[1]
        let routingSize = Int(routingSizeAndTTL & 0x0f)
        guard routingSize <= 8,
              let payloadSize = TIOBinary.readUInt16(data, at: 2) else {
            return .invalid
        }

        let payloadStart = 4
        let payloadEnd = payloadStart + Int(payloadSize)
        let routeEnd = payloadEnd + routingSize
        guard routeEnd <= data.count else { return .needMore }

        let payload = Data(data[payloadStart..<payloadEnd])
        let routing = Data(data[payloadEnd..<routeEnd])
        return .packet(TIOPacket(
            type: type,
            route: routeString(from: routing),
            payload: payload,
            length: routeEnd
        ))
    }

    private static func isPacketTypeValid(_ type: UInt8) -> Bool {
        type != 0 && type != 9 && type != 10 && type != 13
    }

    private static func routeString(from routing: Data) -> String {
        let hops = routing.reversed()
        guard !hops.isEmpty else { return "/" }
        return hops.map { "/\($0)" }.joined()
    }
}

private struct TIODeviceMetadata {
    let route: String
    var name = ""
    var serialNumber = ""
    var firmwareHash = ""
    var nStreams = 0
    var streams: [UInt8: TIOStreamState] = [:]

    init(route: String) {
        self.route = route
    }

    static func parse(route: String, body: Data) -> TIODeviceMetadata? {
        guard let vararg = TIOVararg(body),
              vararg.fixed.count >= 9,
              let name = vararg.string(offset: 1, cursor: 0),
              let serial = vararg.string(offset: 6, cursor: Int(vararg.fixed[1])),
              let firmware = vararg.string(offset: 7, cursor: Int(vararg.fixed[1]) + Int(vararg.fixed[6])),
              let sessionID = TIOBinary.readUInt32(vararg.fixed, at: 2) else {
            return nil
        }

        var metadata = TIODeviceMetadata(route: route)
        metadata.name = name.isEmpty ? "Device \(sessionID)" : name
        metadata.serialNumber = serial
        metadata.firmwareHash = firmware
        metadata.nStreams = Int(vararg.fixed[8])
        return metadata
    }
}

private struct TIOStreamState {
    let id: UInt8
    var metadata: TIOStreamMetadata?
    var segments: [UInt8: TIOSegmentMetadata] = [:]
    var currentSegmentID: UInt8?
    var columns: [UInt8: TIOColumnMetadata] = [:]

    var effectiveSampleRate: Double? {
        guard let segment = currentSegmentID.flatMap({ segments[$0] }) ?? segments.values.first,
              segment.decimation > 0 else {
            return nil
        }
        return Double(segment.samplingRate) / Double(segment.decimation)
    }

    func columnOffset(for columnIndex: UInt8) -> Int? {
        var offset = 0
        for index in columns.keys.sorted() {
            guard let column = columns[index] else { continue }
            if index == columnIndex {
                return offset
            }
            offset += column.dataType.size
        }
        return nil
    }
}

private struct TIOStreamMetadata {
    let id: UInt8
    let name: String
    let nColumns: Int
    let nSegments: Int
    let sampleSize: Int

    static func parse(body: Data) -> TIOStreamMetadata? {
        guard let vararg = TIOVararg(body),
              vararg.fixed.count >= 9,
              let name = vararg.string(offset: 8, cursor: 0),
              let sampleSize = TIOBinary.readUInt16(vararg.fixed, at: 4) else {
            return nil
        }
        return TIOStreamMetadata(
            id: vararg.fixed[1],
            name: name,
            nColumns: Int(vararg.fixed[2]),
            nSegments: Int(vararg.fixed[3]),
            sampleSize: Int(sampleSize)
        )
    }
}

private struct TIOSegmentMetadata {
    let streamID: UInt8
    let id: UInt8
    let startTime: UInt32
    let samplingRate: UInt32
    let decimation: UInt32

    static func parse(body: Data) -> TIOSegmentMetadata? {
        guard let vararg = TIOVararg(body),
              vararg.fixed.count >= 27,
              let startTime = TIOBinary.readUInt32(vararg.fixed, at: 10),
              let samplingRate = TIOBinary.readUInt32(vararg.fixed, at: 14),
              let decimation = TIOBinary.readUInt32(vararg.fixed, at: 18) else {
            return nil
        }
        return TIOSegmentMetadata(
            streamID: vararg.fixed[1],
            id: vararg.fixed[2],
            startTime: startTime,
            samplingRate: samplingRate,
            decimation: decimation
        )
    }
}

private struct TIOColumnMetadata {
    let streamID: UInt8
    let index: UInt8
    let dataType: TIODataType
    let name: String
    let units: String
    let description: String

    static func parse(body: Data) -> TIOColumnMetadata? {
        guard let vararg = TIOVararg(body),
              vararg.fixed.count >= 7 else {
            return nil
        }
        let nameLength = Int(vararg.fixed[4])
        let unitsLength = Int(vararg.fixed[5])
        let name = vararg.string(offset: 4, cursor: 0) ?? ""
        let units = vararg.string(offset: 5, cursor: nameLength) ?? ""
        let description = vararg.string(offset: 6, cursor: nameLength + unitsLength) ?? ""
        return TIOColumnMetadata(
            streamID: vararg.fixed[1],
            index: vararg.fixed[2],
            dataType: TIODataType(rawValue: vararg.fixed[3]),
            name: name,
            units: units,
            description: description
        )
    }
}

private struct TIOVararg {
    let fixed: Data
    let varlen: Data

    init?(_ body: Data) {
        guard let fixedLength = body.first,
              fixedLength >= 2,
              Int(fixedLength) <= body.count else {
            return nil
        }
        fixed = Data(body.prefix(Int(fixedLength)))
        varlen = Data(body.dropFirst(Int(fixedLength)))
    }

    func string(offset: Int, cursor: Int) -> String? {
        guard offset < fixed.count else { return nil }
        let length = Int(fixed[offset])
        guard cursor >= 0, cursor + length <= varlen.count else { return nil }
        return String(decoding: varlen[cursor..<(cursor + length)], as: UTF8.self)
    }
}

private struct TIODataType {
    let rawValue: UInt8

    var size: Int {
        Int(rawValue >> 4)
    }

    var isNumeric: Bool {
        switch rawValue {
        case 0x10, 0x11, 0x20, 0x21, 0x30, 0x31, 0x40, 0x41, 0x80, 0x81, 0x42, 0x82:
            return size > 0
        default:
            return false
        }
    }

    var label: String {
        switch rawValue {
        case 0x10: return "UInt8"
        case 0x11: return "Int8"
        case 0x20: return "UInt16"
        case 0x21: return "Int16"
        case 0x30: return "UInt24"
        case 0x31: return "Int24"
        case 0x40: return "UInt32"
        case 0x41: return "Int32"
        case 0x80: return "UInt64"
        case 0x81: return "Int64"
        case 0x42: return "Float32"
        case 0x82: return "Float64"
        default: return "0x\(String(rawValue, radix: 16))"
        }
    }

    func readValue(from data: Data, at offset: Int) -> Double? {
        guard isNumeric, offset >= 0, offset + size <= data.count else { return nil }
        switch rawValue {
        case 0x10:
            return Double(data[offset])
        case 0x11:
            return Double(Int8(bitPattern: data[offset]))
        case 0x20:
            return TIOBinary.readUInt16(data, at: offset).map { Double($0) }
        case 0x21:
            return TIOBinary.readUInt16(data, at: offset).map { Double(Int16(bitPattern: $0)) }
        case 0x30:
            return TIOBinary.readUInt24(data, at: offset).map { Double($0) }
        case 0x31:
            return TIOBinary.readUInt24(data, at: offset).map { Double(Int32($0)) }
        case 0x40:
            return TIOBinary.readUInt32(data, at: offset).map { Double($0) }
        case 0x41:
            return TIOBinary.readUInt32(data, at: offset).map { Double(Int32(bitPattern: $0)) }
        case 0x80:
            return TIOBinary.readUInt64(data, at: offset).map { Double($0) }
        case 0x81:
            return TIOBinary.readUInt64(data, at: offset).map { Double(Int64(bitPattern: $0)) }
        case 0x42:
            return TIOBinary.readUInt32(data, at: offset).map { Double(Float(bitPattern: $0)) }
        case 0x82:
            return TIOBinary.readUInt64(data, at: offset).map { Double(bitPattern: $0) }
        default:
            return nil
        }
    }
}

private enum TIOBinary {
    static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset])
            | (UInt16(data[offset + 1]) << 8)
    }

    static func readUInt24(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 3 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return value
    }
}
