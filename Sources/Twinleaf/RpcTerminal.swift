// SPDX-License-Identifier: Apache-2.0

import Combine
import SwiftUI

#if os(macOS)
import AppKit
#endif

// The RPC terminal follows the console on the Ethel status page: a command is
// `name` to read or `name value` to write, each command first asks the device
// for the RPC's metadata (`rpc.info`) so the argument and reply are typed
// lazily rather than from a preloaded registry, Tab completes names through
// `rpc.match`, and ↑/↓ recall history. Working from the device's own answers
// means hidden RPCs and RPCs the registry has not learned yet still work.

// MARK: - Transcript

struct RpcTerminalLine: Identifiable, Hashable {
    enum Kind: Hashable {
        case command
        case reply
        case error
    }

    let id: Int
    let kind: Kind
    let text: String
}

// MARK: - Metadata and codec

/// The metadata word `rpc.info` returns: bits 0-3 value type, 4-7 size in
/// bytes, 0x800 bool; zero means untyped, and its bytes pass through as-is.
struct RpcTerminalMeta: Equatable {
    static let typeUInt: UInt8 = 0
    static let typeInt: UInt8 = 1
    static let typeFloat: UInt8 = 2
    static let typeString: UInt8 = 3

    static let untyped = RpcTerminalMeta(bits: 0)

    let bits: UInt16

    init(bits: UInt16) {
        self.bits = bits
    }

    /// Reads the word out of an `rpc.info` reply; a reply shorter than the
    /// two-byte word counts as untyped.
    init(infoReply: Data) {
        let bytes = Array(infoReply.prefix(2))
        bits = bytes.count >= 2 ? UInt16(bytes[0]) | UInt16(bytes[1]) << 8 : 0
    }

    var isUntyped: Bool { bits == 0 }
    var type: UInt8 { UInt8(bits & 0xf) }
    var size: Int { Int((bits >> 4) & 0xf) }
    var isBool: Bool { bits & 0x800 != 0 }
}

enum RpcTerminalCodec {
    enum EncodeError: LocalizedError, Equatable {
        case invalidBool(String)
        case invalidNumber(String, expected: String)
        case outOfRange(String, expected: String)

        var errorDescription: String? {
            switch self {
            case .invalidBool(let text):
                "\"\(text)\" is not a boolean (use on/off, true/false, 1/0)"
            case .invalidNumber(let text, let expected):
                "\"\(text)\" is not a valid \(expected)"
            case .outOfRange(let text, let expected):
                "\(text) is out of range for \(expected)"
            }
        }
    }

    /// Formats the user's text into the RPC's argument bytes per its metadata.
    static func encodeArgument(_ text: String, meta: RpcTerminalMeta) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if meta.isBool {
            switch trimmed.lowercased() {
            case "1", "true", "on", "yes", "y":
                return Data([1])
            case "0", "false", "off", "no", "n":
                return Data([0])
            default:
                throw EncodeError.invalidBool(trimmed)
            }
        }
        if meta.isUntyped || meta.type == RpcTerminalMeta.typeString {
            return Data(text.utf8)
        }

        // A typed RPC that declares no size still takes a 4-byte value, as
        // on the status page.
        let size = meta.size == 0 ? 4 : meta.size
        let bitWidth = size * 8
        switch meta.type {
        case RpcTerminalMeta.typeFloat:
            let expected = "f\(bitWidth)"
            guard let value = Double(trimmed) else {
                throw EncodeError.invalidNumber(trimmed, expected: expected)
            }
            return size == 8
                ? littleEndian(value.bitPattern, byteCount: 8)
                : littleEndian(UInt64(Float(value).bitPattern), byteCount: 4)
        case RpcTerminalMeta.typeInt:
            let expected = "i\(bitWidth)"
            guard let value = parseInteger(trimmed, Int64.self) else {
                throw EncodeError.invalidNumber(trimmed, expected: expected)
            }
            if size < 8 {
                let limit = Int64(1) << (bitWidth - 1)
                guard value >= -limit, value < limit else {
                    throw EncodeError.outOfRange(trimmed, expected: expected)
                }
            }
            return littleEndian(UInt64(bitPattern: value), byteCount: size)
        default:
            // Unsigned, and any type code the page does not know.
            let expected = "u\(bitWidth)"
            guard let value = parseInteger(trimmed, UInt64.self) else {
                throw EncodeError.invalidNumber(trimmed, expected: expected)
            }
            if size < 8, value >= UInt64(1) << bitWidth {
                throw EncodeError.outOfRange(trimmed, expected: expected)
            }
            return littleEndian(value, byteCount: size)
        }
    }

    /// Decodes a reply per the metadata into the text shown in the transcript.
    static func decodeReply(_ data: Data, meta: RpcTerminalMeta) -> String {
        let bytes = Array(data)
        guard let first = bytes.first else { return "(ok)" }
        if meta.isBool {
            return first != 0 ? "true" : "false"
        }
        if meta.type == RpcTerminalMeta.typeString {
            // Device strings are NUL-padded; show only the leading run.
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        if meta.isUntyped {
            if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
                return String(decoding: bytes, as: UTF8.self)
            }
            return hex(bytes)
        }

        switch (meta.type, bytes.count) {
        case (RpcTerminalMeta.typeFloat, 8):
            return "\(Double(bitPattern: unsignedValue(bytes)))"
        case (RpcTerminalMeta.typeFloat, 4):
            return "\(Float(bitPattern: UInt32(unsignedValue(bytes))))"
        case (RpcTerminalMeta.typeInt, 1), (RpcTerminalMeta.typeInt, 2),
             (RpcTerminalMeta.typeInt, 4), (RpcTerminalMeta.typeInt, 8):
            return "\(signedValue(bytes))"
        case (RpcTerminalMeta.typeUInt, 1), (RpcTerminalMeta.typeUInt, 2),
             (RpcTerminalMeta.typeUInt, 4), (RpcTerminalMeta.typeUInt, 8):
            return "\(unsignedValue(bytes))"
        default:
            return hex(bytes)
        }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        "0x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func parseInteger<T: FixedWidthInteger>(_ text: String, _: T.Type) -> T? {
        let lowered = text.lowercased()
        if lowered.hasPrefix("0x") {
            return T(lowered.dropFirst(2), radix: 16)
        }
        if lowered.hasPrefix("-0x") {
            return T(lowered.dropFirst(3), radix: 16).flatMap { value in
                T.isSigned ? 0 - value : nil
            }
        }
        return T(text)
    }

    private static func littleEndian(_ value: UInt64, byteCount: Int) -> Data {
        Data((0..<byteCount).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    private static func unsignedValue(_ bytes: [UInt8]) -> UInt64 {
        bytes.enumerated().reduce(UInt64(0)) { partial, entry in
            partial | UInt64(entry.element) << (8 * UInt64(entry.offset))
        }
    }

    private static func signedValue(_ bytes: [UInt8]) -> Int64 {
        let raw = unsignedValue(bytes)
        let width = bytes.count * 8
        guard width < 64 else { return Int64(bitPattern: raw) }
        let signBit = UInt64(1) << (width - 1)
        return raw & signBit != 0
            ? Int64(bitPattern: raw | ~((UInt64(1) << width) - 1))
            : Int64(raw)
    }
}

// MARK: - Model

@MainActor
final class RpcTerminal: ObservableObject {
    @Published private(set) var lines: [RpcTerminalLine] = []
    @Published var input = "" {
        didSet {
            if input != completionLast {
                completionHint = nil
            }
        }
    }
    /// The route of the sensor commands go to, as `DeviceInfo.route`.
    @Published var selectedRoute = "/"
    @Published private(set) var isBusy = false
    /// "2 of 5" while Tab cycles through several matches.
    @Published private(set) var completionHint: String?
    /// Bumped whenever the input field should take keyboard focus.
    @Published private(set) var focusRequest = 0

    private weak var bridge: BridgeClient?
    private var history: [String] = []
    private var historyIndex = 0
    private var nextLineID = 0
    private var queuedCommands: [String] = []
    private var isDrainingQueue = false

    // Tab-completion state, as on the status page: the name token being
    // completed, the rest of the line kept as typed, and the cycle position.
    private var completionPrefix = ""
    private var completionRest = ""
    private var completionCount = 0
    private var completionIndex = 0
    private var completionLast = ""
    private var completionTask: Task<Void, Never>?

    private static let maximumLineCount = 2000

    init(bridge: BridgeClient? = nil) {
        self.bridge = bridge
    }

    var transcript: String {
        lines.map(\.text).joined(separator: "\n")
    }

    func clear() {
        lines = []
    }

    func requestFocus() {
        focusRequest &+= 1
    }

    /// Keeps the target on a sensor that is actually connected.
    func reconcileRoute(with devices: [DeviceInfo]) {
        guard !devices.isEmpty,
              !devices.contains(where: { $0.route == selectedRoute }) else {
            return
        }
        selectedRoute = devices[0].route
    }

    /// Runs the current input as a command. Commands run one at a time so
    /// their replies land in the transcript in the order they were typed.
    func submit() {
        let line = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        completionLast = ""
        completionHint = nil
        guard !line.isEmpty else { return }
        if history.last != line {
            history.append(line)
        }
        historyIndex = history.count
        queuedCommands.append(line)
        drainQueue()
    }

    func recallPrevious() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        input = history[historyIndex]
    }

    func recallNext() {
        if historyIndex < history.count {
            historyIndex += 1
        }
        input = historyIndex < history.count ? history[historyIndex] : ""
    }

    /// Completes the name token through `rpc.match`; repeated Tabs cycle.
    func requestCompletion() {
        guard completionTask == nil else { return }
        completionTask = Task { [weak self] in
            await self?.complete()
            self?.completionTask = nil
        }
    }

    private func drainQueue() {
        guard !isDrainingQueue else { return }
        isDrainingQueue = true
        Task { [weak self] in
            while let terminal = self, !terminal.queuedCommands.isEmpty {
                let line = terminal.queuedCommands.removeFirst()
                await terminal.run(line)
            }
            self?.isDrainingQueue = false
        }
    }

    private func run(_ line: String) async {
        append(.command, "> " + line)
        let (name, value) = Self.splitCommand(line)
        guard let bridge else {
            append(.error, "! " + RawRpcError.notConnected.localizedDescription)
            return
        }
        let route = selectedRoute
        isBusy = true
        defer { isBusy = false }

        // Learn the type first. No metadata means an unknown or hidden RPC
        // (dev.priv, say): send the text as raw bytes and show whatever
        // comes back.
        var meta = RpcTerminalMeta.untyped
        if let info = try? await bridge.callRawRpc(route: route, name: "rpc.info", argument: Data(name.utf8)) {
            meta = RpcTerminalMeta(infoReply: info)
        }

        do {
            let argument = try value.map { try RpcTerminalCodec.encodeArgument($0, meta: meta) }
            let reply = try await bridge.callRawRpc(route: route, name: name, argument: argument)
            append(.reply, RpcTerminalCodec.decodeReply(reply, meta: meta))
        } catch {
            append(.error, "! " + error.localizedDescription)
        }
    }

    private func complete() async {
        let current = input
        let fresh = current != completionLast
        if fresh {
            let (name, rest) = Self.splitCompletion(current)
            completionPrefix = name
            completionRest = rest
            completionIndex = 0
        }
        guard !completionPrefix.isEmpty, let bridge else { return }
        let route = selectedRoute
        let prefix = completionPrefix

        do {
            let name: String
            if fresh {
                let reply = try await bridge.callRawRpc(route: route, name: "rpc.match", argument: Data(prefix.utf8))
                let text = String(decoding: reply, as: UTF8.self)
                if text.hasPrefix(prefix) {
                    completionCount = 1
                    name = text
                } else {
                    let bytes = Array(reply.prefix(2))
                    completionCount = bytes.count >= 2 ? Int(UInt16(bytes[0]) | UInt16(bytes[1]) << 8) : 0
                    guard completionCount > 0 else {
                        showNoMatches(for: current)
                        return
                    }
                    name = try await matchName(prefix: prefix, index: 0, route: route, bridge: bridge)
                }
            } else {
                guard completionCount > 1 else { return }
                completionIndex = (completionIndex + 1) % completionCount
                name = try await matchName(prefix: prefix, index: completionIndex, route: route, bridge: bridge)
            }
            applyCompletion(name, typedInput: current)
        } catch {
            // No rpc.match (older firmware) or the device is away: fall back
            // to the names the app already learned for this sensor.
            completeLocally(fresh: fresh, typedInput: current)
        }
    }

    private func completeLocally(fresh: Bool, typedInput: String) {
        let names = (bridge?.devices.first { $0.route == selectedRoute }?.rpcs ?? [])
            .map(\.name)
            .filter { $0.hasPrefix(completionPrefix) }
            .sorted()
        guard !names.isEmpty else {
            showNoMatches(for: typedInput)
            return
        }
        if fresh {
            completionCount = names.count
            completionIndex = 0
        } else {
            guard completionCount > 1 else { return }
            completionIndex = (completionIndex + 1) % names.count
        }
        applyCompletion(names[completionIndex], typedInput: typedInput)
    }

    private func matchName(prefix: String, index: Int, route: String, bridge: BridgeClient) async throws -> String {
        let reply = try await bridge.callRawRpc(
            route: route,
            name: "rpc.match",
            argument: Data("\(prefix)|\(index)".utf8)
        )
        return String(decoding: reply, as: UTF8.self)
    }

    private func applyCompletion(_ name: String, typedInput: String) {
        // Typing while the device was answering wins over a stale completion.
        guard input == typedInput else { return }
        let value = name + completionRest
        completionLast = value
        input = value
        completionHint = completionCount > 1 ? "\(completionIndex + 1) of \(completionCount)" : nil
    }

    private func showNoMatches(for typedInput: String) {
        guard input == typedInput else { return }
        completionLast = typedInput
        completionHint = "no matches"
    }

    private func append(_ kind: RpcTerminalLine.Kind, _ text: String) {
        lines.append(RpcTerminalLine(id: nextLineID, kind: kind, text: text))
        nextLineID &+= 1
        if lines.count > Self.maximumLineCount {
            lines.removeFirst(lines.count - Self.maximumLineCount)
        }
    }

    /// `name` reads; `name value` writes, and the value may contain spaces.
    static func splitCommand(_ line: String) -> (name: String, value: String?) {
        guard let space = line.firstIndex(of: " ") else { return (line, nil) }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }

    /// Only the name token is completed; the rest of the line is preserved.
    static func splitCompletion(_ line: String) -> (name: String, rest: String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[space...]))
    }
}

// MARK: - Pane

/// A command line: the prompt is the last line of the scrolling transcript,
/// each command's reply lands under it, and the next prompt follows.
struct RpcTerminalPane: View {
    @ObservedObject var bridge: BridgeClient
    @ObservedObject var terminal: RpcTerminal
    #if os(iOS)
    @FocusState private var isInputFocused: Bool
    #endif

    private static let promptID = "rpc-terminal-prompt"
    private static let font = Font.system(size: 12, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            console
        }
        .onAppear {
            terminal.reconcileRoute(with: bridge.devices)
            terminal.requestFocus()
        }
        .onChange(of: bridge.devices) { _, devices in
            terminal.reconcileRoute(with: devices)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Terminal", systemImage: "terminal")
                .font(.headline)

            Spacer()

            Picker("Target", selection: $terminal.selectedRoute) {
                if bridge.devices.isEmpty {
                    Text("No device").tag(terminal.selectedRoute)
                }
                ForEach(bridge.devices) { device in
                    Text(Self.routeTitle(for: device)).tag(device.route)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(bridge.devices.isEmpty)
            .help("Sensor the commands are sent to")

            Button {
                copyTranscript()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(terminal.lines.isEmpty)
            .help("Copy the transcript")

            Button {
                terminal.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(terminal.lines.isEmpty)
            .help("Clear the transcript")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .textCase(nil)
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    // The lines are lazy; the prompt is not, so scrolling a
                    // long transcript never rebuilds the field or drops its
                    // focus.
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(terminal.lines) { line in
                            Text(line.text)
                                .font(Self.font)
                                .foregroundStyle(Self.color(for: line.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    prompt
                        .id(Self.promptID)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                terminal.requestFocus()
            }
            .onAppear {
                proxy.scrollTo(Self.promptID, anchor: .bottom)
            }
            .onChange(of: terminal.lines.count) { _, _ in
                proxy.scrollTo(Self.promptID, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var prompt: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(">")
                .font(Self.font)
                .foregroundStyle(.secondary)

            inputField
                .frame(maxWidth: .infinity)

            if terminal.isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else if let hint = terminal.completionHint {
                Text(hint)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var inputField: some View {
        #if os(macOS)
        RpcTerminalInputField(terminal: terminal)
        #else
        TextField("name [value]", text: $terminal.input)
            .textFieldStyle(.plain)
            .font(Self.font)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isInputFocused)
            .onSubmit { terminal.submit() }
            .onKeyPress(.upArrow) {
                terminal.recallPrevious()
                return .handled
            }
            .onKeyPress(.downArrow) {
                terminal.recallNext()
                return .handled
            }
            .onKeyPress(.tab) {
                terminal.requestCompletion()
                return .handled
            }
            .onChange(of: terminal.focusRequest) { _, _ in
                isInputFocused = true
            }
            .onAppear { isInputFocused = true }
        #endif
    }

    private func copyTranscript() {
        let text = terminal.transcript
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private static func routeTitle(for device: DeviceInfo) -> String {
        let name = device.meta.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return device.route }
        return device.route == "/" ? name : "\(name) \(device.route)"
    }

    private static func color(for kind: RpcTerminalLine.Kind) -> Color {
        switch kind {
        case .command: .secondary
        case .reply: .primary
        case .error: .red
        }
    }
}

// MARK: - Input field

#if os(macOS)
/// The prompt's text field. AppKit rather than `TextField` so Tab completes
/// instead of moving focus, and ↑/↓ recall history instead of moving the
/// caret; the field editor's commands are intercepted through the delegate.
private struct RpcTerminalInputField: NSViewRepresentable {
    @ObservedObject var terminal: RpcTerminal

    func makeCoordinator() -> Coordinator {
        Coordinator(terminal: terminal)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = "name [value]"
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.stringValue = terminal.input
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.lastFocusRequest = terminal.focusRequest
        context.coordinator.focus(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.terminal = terminal
        // The delegate keeps `terminal.input` equal to what the user typed, so
        // a difference here is a programmatic change (completion, history):
        // apply it and park the caret at the end.
        if field.stringValue != terminal.input {
            field.stringValue = terminal.input
            if let editor = field.currentEditor() {
                let end = (terminal.input as NSString).length
                editor.selectedRange = NSRange(location: end, length: 0)
            }
        }
        if context.coordinator.lastFocusRequest != terminal.focusRequest {
            context.coordinator.lastFocusRequest = terminal.focusRequest
            context.coordinator.focus(field)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var terminal: RpcTerminal
        var lastFocusRequest = 0

        init(terminal: RpcTerminal) {
            self.terminal = terminal
        }

        func focus(_ field: NSTextField) {
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if terminal.input != field.stringValue {
                terminal.input = field.stringValue
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                terminal.submit()
                return true
            case #selector(NSResponder.moveUp(_:)):
                terminal.recallPrevious()
                return true
            case #selector(NSResponder.moveDown(_:)):
                terminal.recallNext()
                return true
            case #selector(NSResponder.insertTab(_:)):
                terminal.requestCompletion()
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                terminal.input = ""
                return true
            default:
                return false
            }
        }
    }
}
#endif
