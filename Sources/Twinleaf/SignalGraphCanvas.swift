// SPDX-License-Identifier: Apache-2.0

import SwiftUI

// MARK: - Layout

/// Where each node of a graph goes: signal flows left to right, a column
/// for each step from the sources, and each node level with what feeds it
/// where there is room. These graphs are ten nodes, not a thousand, so this
/// is a few passes and no more.
struct SignalGraphLayout: Equatable {
    struct Placed: Identifiable, Equatable {
        let node: SignalGraphOutline.Node
        var center: CGPoint

        var id: String { node.id }
    }

    struct Wire: Identifiable, Equatable {
        let from: String
        let to: String
        var start: CGPoint
        var end: CGPoint

        var id: String { "\(from)>\(to)" }
    }

    static let nodeSize = CGSize(width: 172, height: 62)
    static let columnGap: CGFloat = 54
    static let rowGap: CGFloat = 20
    static let margin: CGFloat = 28

    private(set) var placed: [Placed] = []
    private(set) var wires: [Wire] = []
    private(set) var size = CGSize.zero

    init(nodes: [SignalGraphOutline.Node]) {
        guard !nodes.isEmpty else { return }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        let inputs = nodes.map { node in node.inputs.compactMap { index[$0] } }
        var outputs = [[Int]](repeating: [], count: nodes.count)
        for (node, feeds) in inputs.enumerated() {
            for feed in feeds {
                outputs[feed].append(node)
            }
        }

        // A node's column is one past the furthest of what feeds it. The
        // outline lists each node after its inputs, so one pass settles it.
        var column = [Int](repeating: 0, count: nodes.count)
        for node in nodes.indices {
            column[node] = (inputs[node].map { column[$0] }.max() ?? -1) + 1
        }
        // A source sits just ahead of the first thing it feeds, rather than
        // at the far left with a wire across the whole graph.
        for node in nodes.indices where inputs[node].isEmpty {
            if let first = outputs[node].map({ column[$0] }).min() {
                column[node] = max(0, first - 1)
            }
        }

        let columns = (column.max() ?? 0) + 1
        var members = [[Int]](repeating: [], count: columns)
        for node in nodes.indices {
            members[column[node]].append(node)
        }

        let pitch = Self.nodeSize.height + Self.rowGap
        var y = [CGFloat](repeating: 0, count: nodes.count)
        // Spreads a column's nodes to where they want to be, in order, no
        // two closer than a row apart.
        func settle(_ column: [Int], wanting: (Int) -> CGFloat?) {
            let wants = column.enumerated().map { place, node in
                (node, wanting(node) ?? CGFloat(place) * pitch)
            }
            let ordered = wants.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
            var last: CGFloat?
            var placedAt: [(Int, CGFloat)] = []
            for (node, want) in ordered {
                let at = last.map { max(want, $0 + pitch) } ?? want
                placedAt.append((node, at))
                last = at
            }
            // Pushing down moved the column's middle; put it back.
            let wanted = ordered.map(\.1).reduce(0, +) / CGFloat(ordered.count)
            let got = placedAt.map(\.1).reduce(0, +) / CGFloat(placedAt.count)
            for (node, at) in placedAt {
                y[node] = at - (got - wanted)
            }
        }
        func mean(_ nodes: [Int]) -> CGFloat? {
            nodes.isEmpty ? nil : nodes.map { y[$0] }.reduce(0, +) / CGFloat(nodes.count)
        }
        // Left to right, each node level with its inputs; then the sources,
        // which have none, level with what they feed.
        for members in members {
            settle(members) { mean(inputs[$0]) }
        }
        for members in members.reversed() where members.contains(where: { inputs[$0].isEmpty }) {
            settle(members) { inputs[$0].isEmpty ? mean(outputs[$0]) : y[$0] }
        }

        let top = y.min() ?? 0
        let pitchX = Self.nodeSize.width + Self.columnGap
        placed = nodes.indices.map { node in
            Placed(
                node: nodes[node],
                center: CGPoint(
                    x: Self.margin + Self.nodeSize.width / 2 + CGFloat(column[node]) * pitchX,
                    y: Self.margin + Self.nodeSize.height / 2 + y[node] - top
                )
            )
        }
        for (node, feeds) in inputs.enumerated() {
            for feed in feeds {
                wires.append(Wire(
                    from: nodes[feed].id,
                    to: nodes[node].id,
                    start: CGPoint(
                        x: placed[feed].center.x + Self.nodeSize.width / 2,
                        y: placed[feed].center.y
                    ),
                    end: CGPoint(
                        x: placed[node].center.x - Self.nodeSize.width / 2,
                        y: placed[node].center.y
                    )
                ))
            }
        }
        size = CGSize(
            width: Self.margin * 2 + CGFloat(columns) * pitchX - Self.columnGap,
            height: Self.margin * 2 + Self.nodeSize.height + (y.max() ?? 0) - top
        )
    }
}

// MARK: - Canvas pane

/// The graph the text describes, and under it the node that is selected and
/// the params.
struct SignalGraphCanvasPane: View {
    @ObservedObject var model: SignalGraphEditorModel

    var body: some View {
        VStack(spacing: 0) {
            SignalGraphCanvas(model: model)
            if let node = model.selectedNode {
                Divider()
                SignalGraphNodeInspector(model: model, node: node)
            }
            if !model.outline.params.isEmpty {
                Divider()
                SignalGraphParamList(model: model)
            }
        }
    }
}

private struct SignalGraphCanvas: View {
    @ObservedObject var model: SignalGraphEditorModel

    var body: some View {
        let layout = SignalGraphLayout(nodes: model.drawn.nodes)
        GeometryReader { geometry in
            // A graph a little too wide for the pane is drawn smaller
            // rather than cut off. One much too wide scrolls.
            let scale = min(1, max(0.62, geometry.size.width / max(layout.size.width, 1)))
            ScrollView([.horizontal, .vertical]) {
                SignalGraphDrawing(model: model, layout: layout)
                    .frame(width: layout.size.width, height: layout.size.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(
                        width: layout.size.width * scale,
                        height: layout.size.height * scale,
                        alignment: .topLeading
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            // A click on nothing selects nothing.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.select(nil) }
        }
        .overlay {
            if layout.placed.isEmpty {
                ContentUnavailableView(
                    "No Graph Yet",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("A source and an out make one.")
                )
            }
        }
    }
}

/// The nodes and wires of a graph, at the size the layout gives them.
private struct SignalGraphDrawing: View {
    @ObservedObject var model: SignalGraphEditorModel
    let layout: SignalGraphLayout

    var body: some View {
        // While the text has errors this is the graph of the last text
        // that had none: there to look at, and not to act on, because its
        // places in the text are no longer the text's.
        let stale = model.drawnIsStale
        let flagged = stale ? [] : model.outline.flagged
        ZStack(alignment: .topLeading) {
            SignalGraphWires(wires: layout.wires, selected: stale ? nil : model.selectedNodeID)
            ForEach(layout.placed) { placed in
                SignalGraphNodeView(
                    node: placed.node,
                    isSelected: !stale && placed.node.id == model.selectedNodeID,
                    isFlagged: flagged.contains(placed.node.id)
                )
                .frame(
                    width: SignalGraphLayout.nodeSize.width,
                    height: SignalGraphLayout.nodeSize.height
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    model.select(placed.node)
                }
                .contextMenu {
                    SignalGraphNodeActions(model: model, node: placed.node)
                }
                .position(placed.center)
            }
        }
        .opacity(stale ? 0.4 : 1)
        .allowsHitTesting(!stale)
    }
}

/// The wires, drawn under the nodes. Those of the selected node stand out.
private struct SignalGraphWires: View {
    let wires: [SignalGraphLayout.Wire]
    let selected: String?

    var body: some View {
        Canvas { context, _ in
            for wire in wires {
                let reach = max(18, (wire.end.x - wire.start.x) / 2)
                var path = Path()
                path.move(to: wire.start)
                path.addCurve(
                    to: wire.end,
                    control1: CGPoint(x: wire.start.x + reach, y: wire.start.y),
                    control2: CGPoint(x: wire.end.x - reach, y: wire.end.y)
                )
                let lit = selected != nil && (wire.from == selected || wire.to == selected)
                context.stroke(
                    path,
                    with: lit ? .color(.accentColor) : .color(.secondary.opacity(0.55)),
                    style: StrokeStyle(lineWidth: lit ? 2 : 1.3, lineCap: .round)
                )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SignalGraphNodeView: View {
    let node: SignalGraphOutline.Node
    let isSelected: Bool
    /// Whether the text has something to say about this node.
    let isFlagged: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(node.title)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let name = node.name, node.kind != "output" {
                    Text(name)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !node.detail.isEmpty {
                Text(node.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Text(node.runs ? node.signal : "not built yet")
                .font(.caption2)
                .foregroundStyle(node.runs ? .tertiary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill, in: shape)
        .overlay {
            shape.strokeBorder(
                stroke,
                style: StrokeStyle(lineWidth: isSelected || isFlagged ? 2 : 1, dash: node.runs ? [] : [4, 3])
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.title) \(node.detail), \(node.signal)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: node.kind == "source" || node.kind == "output" ? 16 : 8)
    }

    private var fill: Color {
        switch node.kind {
        case "source": Color.green.opacity(0.14)
        case "output": Color.accentColor.opacity(0.16)
        default: Color.secondary.opacity(0.10)
        }
    }

    private var stroke: Color {
        if isSelected {
            return .accentColor
        }
        return isFlagged ? .yellow : .secondary.opacity(0.45)
    }
}

/// What can be done to a node. Each is an edit of the text.
private struct SignalGraphNodeActions: View {
    @ObservedObject var model: SignalGraphEditorModel
    let node: SignalGraphOutline.Node

    var body: some View {
        if !node.stages.isEmpty {
            Menu("Add Stage After") {
                ForEach(node.stages) { stage in
                    Button(stage.text.trimmingCharacters(in: CharacterSet(charactersIn: " |"))) {
                        model.append(stage, after: node)
                    }
                }
            }
        }
        if node.remove != nil {
            Button("Remove Stage", role: .destructive) {
                model.remove(node)
            }
        }
        Button("Show in Text") {
            model.select(node)
        }
    }
}

/// The selected node, with what it carries and what can be done to it.
private struct SignalGraphNodeInspector: View {
    @ObservedObject var model: SignalGraphEditorModel
    let node: SignalGraphOutline.Node

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.detail.isEmpty ? node.title : "\(node.title)(\(node.detail))")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(node.signal): \(node.channels.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if !node.stages.isEmpty {
                Menu {
                    ForEach(node.stages) { stage in
                        Button(stage.text.trimmingCharacters(in: CharacterSet(charactersIn: " |"))) {
                            model.append(stage, after: node)
                        }
                    }
                } label: {
                    Label("Add Stage", systemImage: "plus")
                }
                .fixedSize()
            }
            if node.remove != nil {
                Button(role: .destructive) {
                    model.remove(node)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Params

/// The spec's params. Dragging one rewrites its number in the text, which
/// is all that setting it from anywhere else does either.
private struct SignalGraphParamList: View {
    @ObservedObject var model: SignalGraphEditorModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(model.outline.params) { param in
                SignalGraphParamRow(param: param) { value in
                    model.setParam(named: param.name, to: value)
                } reveal: {
                    model.reveal(param.digits)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct SignalGraphParamRow: View {
    let param: SignalGraphOutline.Param
    let set: (Double) -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: reveal) {
                Text(param.name)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .frame(width: 90, alignment: .leading)
            .help("Show where \(param.name) is written")

            if let low = param.low, let high = param.high, low < high {
                Slider(
                    value: Binding(
                        get: { min(max(param.value, low), high) },
                        set: { set(Self.rounded($0, low: low, high: high)) }
                    ),
                    in: low...high
                )
                .accessibilityLabel(param.name)
            } else {
                Spacer(minLength: 0)
            }

            Text("\(SignalGraphEditorModel.written(param.value)) \(param.unit)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
                .lineLimit(1)
        }
    }

    /// A slider's value to about a thousandth of its range, so that what it
    /// writes into the text is a short number.
    private static func rounded(_ value: Double, low: Double, high: Double) -> Double {
        let step = pow(10, (log10((high - low) / 1000)).rounded(.up))
        guard step.isFinite, step > 0 else { return value }
        return min(max((value / step).rounded() * step, low), high)
    }
}
