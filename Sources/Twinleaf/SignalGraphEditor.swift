// SPDX-License-Identifier: Apache-2.0

import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Outline

/// What the Rust front end makes of a signal graph's text: how to colour it,
/// what is wrong with it, the graph it describes, and where in the text each
/// part of that graph is written. Mirrors `tio_dsp::lang::outline::Outline`.
///
/// Offsets count UTF-16 code units, as `NSRange` does.
struct SignalGraphOutline: Decodable, Equatable {
    struct Span: Decodable, Hashable {
        var start: Int
        var end: Int

        var length: Int { max(0, end - start) }
        var nsRange: NSRange { NSRange(location: start, length: length) }

        func contains(_ other: NSRange) -> Bool {
            start <= other.location && other.location + other.length <= end
        }

        func touches(_ other: Span) -> Bool {
            start < max(other.end, other.start + 1) && other.start < max(end, start + 1)
        }
    }

    struct Mark: Decodable, Equatable {
        var range: Span
        var `class`: String
    }

    struct Related: Decodable, Equatable {
        var range: Span
        var label: String
    }

    struct Note: Decodable, Equatable {
        var kind: String
        var text: String
    }

    struct Problem: Decodable, Equatable, Identifiable {
        var severity: String
        var code: String?
        var message: String
        var label: String
        var range: Span
        var line: Int
        var column: Int
        var related: [Related]
        var notes: [Note]
        var rendered: String

        var id: String { "\(line):\(column):\(code ?? ""):\(message)" }
        var isError: Bool { severity == "error" }
    }

    /// A stage that may be piped on after a node, written out.
    struct Stage: Decodable, Equatable, Identifiable {
        var function: String
        var text: String

        var id: String { function }
    }

    struct Node: Decodable, Equatable, Identifiable {
        var id: String
        /// `source`, `function`, `operator`, `select` or `output`.
        var kind: String
        var title: String
        var detail: String
        var name: String?
        var inputs: [String]
        var signal: String
        var rate: Double
        var channels: [String]
        var runs: Bool
        /// All of the text that makes the node, inputs included.
        var range: Span
        /// The text that is this node and no other.
        var focus: Span
        /// The text to delete to take a piped stage out.
        var remove: Span?
        /// Where a stage may be piped on after it.
        var append: Int?
        var stages: [Stage]
    }

    struct Param: Decodable, Equatable, Identifiable {
        var name: String
        var unit: String
        var value: Double
        var low: Double?
        var high: Double?
        var range: Span
        /// The digits of the value: what to replace to set it.
        var digits: Span

        var id: String { name }
    }

    var ok: Bool
    var marks: [Mark]
    var problems: [Problem]
    var nodes: [Node]
    var params: [Param]

    static let empty = SignalGraphOutline(ok: true, marks: [], problems: [], nodes: [], params: [])

    /// Reads `text`. Empty where the Rust core is not there to read it.
    static func read(_ text: String) -> SignalGraphOutline {
        guard let json = RustRuntime.specOutlineJSON(text),
              let outline = try? JSONDecoder().decode(SignalGraphOutline.self, from: json) else {
            return .empty
        }
        return outline
    }

    /// The node a caret or a selection is in: the smallest whose own text
    /// holds it, or failing that the smallest it is part of.
    func node(at selection: NSRange) -> Node? {
        let own = nodes
            .filter { $0.focus.contains(selection) }
            .min { $0.focus.length < $1.focus.length }
        if let own {
            return own
        }
        return nodes
            .filter { $0.range.contains(selection) }
            .min { $0.range.length < $1.range.length }
    }

    func node(id: String?) -> Node? {
        guard let id else { return nil }
        return nodes.first { $0.id == id }
    }

    /// The nodes the text has something to say about: for each problem,
    /// the one node its place is in, and not the nodes built on that one.
    var flagged: Set<String> {
        Set(problems.compactMap { node(at: $0.range.nsRange)?.id })
    }
}

// MARK: - Model

/// What the editor asks of its text view. Edits go through the view so that
/// they land in its undo history: a canvas gesture and a keystroke are then
/// undone the same way, in the order they were made.
@MainActor
protocol SignalGraphTextPort: AnyObject {
    func replace(_ range: NSRange, with text: String, selecting: NSRange?)
    func setText(_ text: String)
    func reveal(_ range: NSRange)
    func restyle()
}

/// A signal graph being edited: its text, what the text describes, and the
/// running graph it is put to.
///
/// The text is the only state. The canvas draws what the text says, and
/// every gesture on it is a splice of the text between offsets the outline
/// hands out. Nothing is ever written back from the graph.
@MainActor
final class SignalGraphEditorModel: ObservableObject {
    /// How things stand between the text here and the graph that is running.
    enum Link: Equatable {
        /// No graph is running in this session.
        case offline
        /// The graph is running this text.
        case running
        /// The text here has changes the graph has not been given.
        case edited
        case applying
        /// The graph was given the text and would not take it.
        case refused
        case failed(String)
    }

    @Published private(set) var text: String
    @Published private(set) var outline: SignalGraphOutline
    /// The outline of the last text that checked. The canvas draws this
    /// one, so that the graph does not fall apart at every keystroke that
    /// leaves a call half written.
    @Published private(set) var drawn: SignalGraphOutline
    @Published private(set) var selectedNodeID: String?
    @Published private(set) var link: Link = .offline
    /// The text the graph is running, as last read from it or put to it.
    @Published private(set) var runningText: String?
    /// Whether a text that checks is put to the graph as it is typed.
    @Published var appliesAsYouType = true {
        didSet {
            if appliesAsYouType {
                scheduleApply(after: .milliseconds(50))
            }
        }
    }

    let bridge: BridgeClient
    weak var port: SignalGraphTextPort?

    private var applyTask: Task<Void, Never>?
    private var logObservation: AnyCancellable?
    private var isApplying = false
    /// The device's log messages already seen when the last text was put to
    /// it, so that what it says about that text can be told from the rest.
    private var logSeen: Set<UUID> = []
    /// Set while the text view's selection is being moved to a node, or
    /// moves because of a splice, so that the move does not pick a node of
    /// its own.
    private var isRevealing = false

    init(bridge: BridgeClient) {
        self.bridge = bridge
        let text = bridge.signalGraph?.text ?? Self.starterText(for: bridge.devices)
        self.text = text
        let outline = SignalGraphOutline.read(text)
        self.outline = outline
        drawn = outline
        // What the graph says arrives when it will, after the text that
        // provoked it was taken. Whoever shows it must look again then.
        logObservation = bridge.$logMessages.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Whether the graph drawn is of an earlier text, the one here having
    /// errors.
    var drawnIsStale: Bool {
        !outline.ok
    }

    var selectedNode: SignalGraphOutline.Node? {
        drawnIsStale ? nil : outline.node(id: selectedNodeID)
    }

    /// The route of the running graph, if there is one.
    var route: String? {
        bridge.signalGraphRoute
    }

    var hasChanges: Bool {
        runningText.map { $0 != text } ?? true
    }

    /// What the running graph has said since the last text was put to it:
    /// why it refused one, or what it found the sensors to be.
    var deviceMessages: [LogMessage] {
        guard let route else { return [] }
        // It also notes every text it takes and every param set. Those are
        // not news here.
        return bridge.logMessages.filter {
            $0.route == route && $0.isProblem && !logSeen.contains($0.id)
        }
    }

    // MARK: Text

    /// The text view's text changed, by typing or by a splice made through it.
    func textDidChange(_ newText: String) {
        guard newText != text else { return }
        text = newText
        outline = SignalGraphOutline.read(newText)
        if outline.ok {
            drawn = outline
        }
        if outline.node(id: selectedNodeID) == nil {
            selectedNodeID = nil
        }
        port?.restyle()
        noteEdited()
        scheduleApply(after: .milliseconds(350))
    }

    func selectionDidChange(_ selection: NSRange) {
        guard !isRevealing else { return }
        let id = outline.node(at: selection)?.id
        guard id != selectedNodeID else { return }
        selectedNodeID = id
        port?.restyle()
    }

    /// Replaces a stretch of the text, through the text view when there is
    /// one, so that the change can be undone there.
    private func splice(_ range: NSRange, with replacement: String, selecting: NSRange? = nil) {
        if let port {
            // The caret moves with the edit. That is not the user going
            // to look at another node.
            isRevealing = true
            port.replace(range, with: replacement, selecting: selecting)
            isRevealing = false
            return
        }
        let edited = NSMutableString(string: text)
        let location = min(range.location, edited.length)
        let length = min(range.length, edited.length - location)
        edited.replaceCharacters(in: NSRange(location: location, length: length), with: replacement)
        textDidChange(edited as String)
    }

    /// Replaces the whole text with one that came from elsewhere: the
    /// running graph, or a file. Not an edit, so not undoable.
    private func load(_ newText: String) {
        guard newText != text else { return }
        text = newText
        outline = SignalGraphOutline.read(newText)
        drawn = outline
        selectedNodeID = nil
        port?.setText(newText)
        port?.restyle()
    }

    // MARK: Canvas gestures

    func select(_ node: SignalGraphOutline.Node?) {
        selectedNodeID = node?.id
        port?.restyle()
        guard let node else { return }
        isRevealing = true
        port?.reveal(node.focus.nsRange)
        isRevealing = false
    }

    func reveal(_ range: SignalGraphOutline.Span) {
        port?.reveal(range.nsRange)
    }

    /// Selects the place a line and column name, as the device's log does.
    func reveal(line: Int, column: Int) {
        let lines = text.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return }
        let before = lines[..<(line - 1)].reduce(0) { $0 + ($1 as NSString).length + 1 }
        let text = lines[line - 1]
        let index = text.index(text.startIndex, offsetBy: max(0, column - 1), limitedBy: text.endIndex)
            ?? text.endIndex
        let offset = before + text[..<index].utf16.count
        port?.reveal(NSRange(location: offset, length: 0))
    }

    /// Sets a param by replacing its digits.
    func setParam(named name: String, to value: Double) {
        guard let param = outline.params.first(where: { $0.name == name }),
              param.value != value else {
            return
        }
        splice(param.digits.nsRange, with: Self.written(value))
        scheduleApply(after: .milliseconds(40))
    }

    /// Takes a piped stage out by deleting its text.
    func remove(_ node: SignalGraphOutline.Node) {
        guard let remove = node.remove else { return }
        splice(remove.nsRange, with: "", selecting: NSRange(location: remove.start, length: 0))
        // The nodes after it have moved up; what was selected is gone.
        selectedNodeID = nil
        port?.restyle()
        scheduleApply(after: .milliseconds(40))
    }

    /// Pipes a stage on after a node by inserting its text there.
    func append(_ stage: SignalGraphOutline.Stage, after node: SignalGraphOutline.Node) {
        guard let at = node.append else { return }
        // The stage's text opens with its pipe. Select the call after it,
        // which is what there is to edit next.
        let lead = (stage.text as NSString).range(of: stage.function).location
        let call = NSRange(
            location: at + (lead == NSNotFound ? 0 : lead),
            length: (stage.text as NSString).length - (lead == NSNotFound ? 0 : lead)
        )
        splice(NSRange(location: at, length: 0), with: stage.text, selecting: call)
        selectedNodeID = outline.node(at: call)?.id
        port?.restyle()
        scheduleApply(after: .milliseconds(40))
    }

    // MARK: The running graph

    /// Takes up with the session as it is now: reads the running graph's
    /// text if one is running, and takes it when there are no edits here to
    /// lose.
    func refresh() async {
        guard let route else {
            runningText = nil
            link = .offline
            return
        }
        guard !isApplying else { return }
        do {
            let running = try await bridge.readSignalGraphText(route: route)
            let wasClean = runningText == nil || runningText == text
            runningText = running
            if wasClean {
                load(running)
            }
            if link != .refused {
                link = running == text ? .running : .edited
            }
        } catch {
            link = .failed(error.localizedDescription)
        }
    }

    /// Discards the edits here for the text the graph is running.
    func revert() {
        guard let runningText else { return }
        applyTask?.cancel()
        load(runningText)
        link = .running
    }

    /// Replaces the text with a file's.
    func open(_ newText: String) {
        load(newText)
        noteEdited()
        scheduleApply(after: .milliseconds(50))
    }

    /// Puts the text to the graph now, or starts a graph with it when the
    /// session has none.
    func run() {
        applyTask?.cancel()
        guard route != nil else {
            guard outline.ok else { return }
            bridge.setSignalGraph(SignalGraph(name: bridge.signalGraph?.name ?? "Signal Graph", text: text))
            return
        }
        Task { await apply() }
    }

    private func noteEdited() {
        guard route != nil, !isApplying else { return }
        link = hasChanges ? .edited : .running
    }

    private func scheduleApply(after delay: Duration) {
        applyTask?.cancel()
        guard appliesAsYouType, route != nil else { return }
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.apply()
        }
    }

    private func apply() async {
        // A text that does not check is not sent: the graph would refuse it
        // for the reasons already shown here.
        guard let route, outline.ok, hasChanges, !isApplying else { return }
        isApplying = true
        link = .applying
        let sent = text
        logSeen = Set(bridge.logMessages.map(\.id))
        do {
            try await bridge.writeSignalGraphText(sent, route: route)
            runningText = sent
            link = .running
        } catch RawRpcError.failed(_, let code) where code != nil {
            // The device answered, and the answer was no. Why is in its log.
            link = .refused
        } catch {
            link = .failed(error.localizedDescription)
        }
        isApplying = false
        if text != sent {
            noteEdited()
            scheduleApply(after: .milliseconds(40))
        }
    }

    // MARK: Writing

    /// A number as a spec writes it: plain digits, a point for the decimal
    /// mark whatever the locale, and no more of them than a slider means.
    static func written(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let style = FloatingPointFormatStyle<Double>.number
            .precision(.significantDigits(1...6))
            .grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX"))
        return value.formatted(style)
    }

    /// A text to begin from when the session has no graph: its first stream
    /// as a source, and one output.
    static func starterText(for devices: [DeviceInfo]) -> String {
        let header = """
        # A signal graph computes new streams from this session's sensors.
        # Each `out` becomes a stream on one more device, and each `param`
        # a setting on it.

        """
        let plain = /[A-Za-z_][A-Za-z0-9_]*/
        for device in devices {
            for stream in device.streams {
                let names = stream.columns.map(\.name)
                guard !names.isEmpty,
                      names.allSatisfy({ $0.wholeMatch(of: plain) != nil }),
                      stream.name.wholeMatch(of: plain) != nil,
                      stream.effectiveSamplingRate > 0 else {
                    continue
                }
                let rate = written(stream.effectiveSamplingRate)
                var source = "source a = \(device.route)/\(stream.name) @rate(\(rate)) @channels(\(names.joined(separator: ", ")))"
                let units = Set(stream.columns.map(\.units))
                if units.count == 1, let unit = units.first, !unit.isEmpty {
                    source += " @unit(\(unit))"
                }
                let edge = written(max(stream.effectiveSamplingRate / 20, 0.001))
                return header + """

                \(source)

                param edge : Hz = \(edge) [\(written(stream.effectiveSamplingRate / 1000)) .. \(written(stream.effectiveSamplingRate / 2.5))]

                out smooth = a | lowpass(edge)

                """
            }
        }
        return header + """

        source a = /0/field @rate(1000) @channels(x, y, z) @unit(nT)

        param edge : Hz = 50 [1 .. 400]

        out smooth = a | lowpass(edge)

        """
    }
}

// MARK: - Window

/// What opens an editor window: the document whose signal graph it edits.
struct SignalGraphEditorDescriptor: Hashable, Codable {
    var sessionID: UUID
}

/// The editor's scene. It finds its document's bridge by session, as a
/// popped-out plot does.
struct SignalGraphEditorScene: View {
    let descriptor: SignalGraphEditorDescriptor
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let bridge = BridgeSessionRegistry.shared.bridge(for: descriptor.sessionID) {
            SignalGraphEditorView(bridge: bridge)
        } else {
            // A window the system brought back after its document closed.
            ContentUnavailableView {
                Label("Signal Graph Unavailable", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("The original document is no longer open.")
            } actions: {
                Button("Close") {
                    dismissWindow()
                }
            }
        }
    }
}

/// Opens a document's signal graph editor when its command is chosen: in a
/// window of its own where the platform has windows, so that the plots stay
/// in view while the graph is changed, and over the document where it has
/// not.
struct SignalGraphEditorOpener: View {
    @ObservedObject var bridge: BridgeClient
    /// Whether a command posted from a menu is meant for this document.
    let receives: (Notification) -> Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @State private var showingSheet = false

    var body: some View {
        Color.clear
            .onReceive(NotificationCenter.default.publisher(for: .editSignalGraph)) { notification in
                // A recording being inspected has no sensors to compute from.
                guard receives(notification), !bridge.isInspectionMode else { return }
                if supportsMultipleWindows {
                    openWindow(value: SignalGraphEditorDescriptor(sessionID: bridge.sessionID))
                } else {
                    showingSheet = true
                }
            }
            .sheet(isPresented: $showingSheet) {
                SignalGraphEditorView(bridge: bridge) {
                    showingSheet = false
                }
            }
    }
}

/// Text on one side, the graph it describes on the other.
struct SignalGraphEditorView: View {
    @ObservedObject var bridge: BridgeClient
    /// Closes the editor, where it is shown over its document.
    var done: (() -> Void)?
    @StateObject private var model: SignalGraphEditorModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var compactPane = CompactPane.text
    @State private var showingOpenPanel = false
    @State private var showingSavePanel = false

    private enum CompactPane: String, CaseIterable, Identifiable {
        case text = "Text"
        case graph = "Graph"

        var id: String { rawValue }
    }

    init(bridge: BridgeClient, done: (() -> Void)? = nil) {
        self.bridge = bridge
        self.done = done
        _model = StateObject(wrappedValue: SignalGraphEditorModel(bridge: bridge))
    }

    var body: some View {
        NavigationStack {
            panes
                .navigationTitle(bridge.signalGraph?.name ?? "Signal Graph")
                #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    SignalGraphEditorToolbar(
                        model: model,
                        showingOpenPanel: $showingOpenPanel,
                        showingSavePanel: $showingSavePanel
                    )
                    if let done {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done", action: done)
                        }
                    }
                }
        }
        .fileImporter(
            isPresented: $showingOpenPanel,
            allowedContentTypes: SignalGraphFile.contentTypes
        ) { result in
            openFile(result)
        }
        .background {
            // On a view of its own: two file panels on one view do not both
            // present.
            Color.clear.fileExporter(
                isPresented: $showingSavePanel,
                document: SignalGraphTextFile(text: model.text),
                contentType: .plainText,
                defaultFilename: bridge.signalGraph?.name ?? "graph.tsl"
            ) { _ in }
        }
        // The graph appears, goes, or is changed from elsewhere: a slider
        // in the main window sets a param by rewriting the same text.
        .task(id: bridge.signalGraphRoute) {
            await model.refresh()
        }
        .onChange(of: bridge.rpcValueChangeToken) {
            Task { await model.refresh() }
        }
    }

    @ViewBuilder
    private var panes: some View {
        #if os(macOS)
        HSplitView {
            SignalGraphTextPane(model: model)
                .frame(minWidth: 320, idealWidth: 480)
            SignalGraphCanvasPane(model: model)
                .frame(minWidth: 360, idealWidth: 620)
        }
        .frame(minWidth: 760, minHeight: 420)
        #else
        if horizontalSizeClass == .compact {
            VStack(spacing: 0) {
                Picker("Pane", selection: $compactPane) {
                    ForEach(CompactPane.allCases) { pane in
                        Text(pane.rawValue).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                // Both stay alive, so that the text view keeps its undo
                // history while the graph is looked at.
                ZStack {
                    SignalGraphTextPane(model: model)
                        .opacity(compactPane == .text ? 1 : 0)
                        .allowsHitTesting(compactPane == .text)
                    SignalGraphCanvasPane(model: model)
                        .opacity(compactPane == .graph ? 1 : 0)
                        .allowsHitTesting(compactPane == .graph)
                }
            }
        } else {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    SignalGraphTextPane(model: model)
                        .frame(width: geometry.size.width * 0.44)
                    Divider()
                    SignalGraphCanvasPane(model: model)
                }
            }
        }
        #endif
    }

    private func openFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            model.open(text)
        }
    }
}

/// A signal graph's text as a file to save.
struct SignalGraphTextFile: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct SignalGraphEditorToolbar: ToolbarContent {
    @ObservedObject var model: SignalGraphEditorModel
    @Binding var showingOpenPanel: Bool
    @Binding var showingSavePanel: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            SignalGraphLinkBadge(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.appliesAsYouType) {
                Label("Apply as You Type", systemImage: "bolt")
            }
            .help("Put each text that checks to the running graph as it is typed")

            Button {
                model.run()
            } label: {
                Label(model.route == nil ? "Run" : "Apply", systemImage: "play.fill")
            }
            .disabled(!model.outline.ok || (model.route != nil && !model.hasChanges))
            .help(model.route == nil
                ? "Start the graph over this session's sensors"
                : "Put this text to the running graph")

            Button {
                model.revert()
            } label: {
                Label("Revert", systemImage: "arrow.uturn.backward")
            }
            .disabled(model.runningText == nil || !model.hasChanges)
            .help("Go back to the text the graph is running")

            Menu {
                Button("Open...") { showingOpenPanel = true }
                Button("Save As...") { showingSavePanel = true }
            } label: {
                Label("File", systemImage: "doc")
            }
        }
    }
}

/// How the text here stands with the running graph, in a word.
private struct SignalGraphLinkBadge: View {
    @ObservedObject var model: SignalGraphEditorModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var errors: Int {
        model.outline.problems.filter(\.isError).count
    }

    /// The graph took the text and then found fault with it: the sensors
    /// are not what the text says they are.
    private var graphObjects: Bool {
        model.link == .running && !model.deviceMessages.isEmpty
    }

    private var label: String {
        if errors > 0 {
            return errors == 1 ? "1 error" : "\(errors) errors"
        }
        if graphObjects {
            return "Problem reported by the graph"
        }
        switch model.link {
        case .offline: return "Not running"
        case .running: return "Running"
        case .edited: return "Edited"
        case .applying: return "Applying"
        case .refused: return "Refused by the graph"
        case .failed(let message): return message
        }
    }

    private var color: Color {
        if errors > 0 || graphObjects {
            return .red
        }
        switch model.link {
        case .offline: return .secondary
        case .running: return .green
        case .edited, .applying: return .orange
        case .refused, .failed: return .red
        }
    }
}

// MARK: - Text pane

/// The text, and under it what is wrong with it.
struct SignalGraphTextPane: View {
    @ObservedObject var model: SignalGraphEditorModel

    var body: some View {
        VStack(spacing: 0) {
            SignalGraphTextView(model: model)
            SignalGraphProblemList(model: model)
        }
    }
}

/// What is wrong with the text, as it reads here, and what the running
/// graph has had to say, which may know more: it has the sensors.
private struct SignalGraphProblemList: View {
    @ObservedObject var model: SignalGraphEditorModel

    var body: some View {
        let problems = model.outline.problems
        let messages = model.deviceMessages.suffix(4)
        if !problems.isEmpty || !messages.isEmpty {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(problems) { problem in
                        SignalGraphProblemRow(problem: problem) {
                            model.reveal(problem.range)
                        }
                    }
                    ForEach(Array(messages)) { message in
                        SignalGraphDeviceMessageRow(message: message.message) { line, column in
                            model.reveal(line: line, column: column)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 170)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SignalGraphProblemRow: View {
    let problem: SignalGraphOutline.Problem
    let reveal: () -> Void

    var body: some View {
        Button(action: reveal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: problem.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(problem.isError ? .red : .yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.message)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    ForEach(Array(problem.notes.enumerated()), id: \.offset) { _, note in
                        Text("\(note.kind): \(note.text)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text("\(problem.line):\(problem.column)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(problem.rendered)
    }
}

/// Something the running graph logged. Where it names a place in the text,
/// as a refusal does, a click goes there.
private struct SignalGraphDeviceMessageRow: View {
    let message: String
    let reveal: (Int, Int) -> Void

    var body: some View {
        Button {
            if let place {
                reveal(place.line, place.column)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(12)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The first `--> dsp.spec:line:column` in the message.
    private var place: (line: Int, column: Int)? {
        guard let match = message.firstMatch(of: /--> [^:\s]+:(\d+):(\d+)/),
              let line = Int(match.1), let column = Int(match.2) else {
            return nil
        }
        return (line, column)
    }
}
