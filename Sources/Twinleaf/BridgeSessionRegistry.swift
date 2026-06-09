// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Process-wide map from `BridgeClient.sessionID` to the live bridge instance.
///
/// On iPad, "pop out a plot" launches a separate SwiftUI `WindowGroup` scene
/// — an independent `UIScene` with its own view hierarchy. Those scenes can
/// only carry `Hashable & Codable` payloads, so the popout descriptor stores
/// the parent document's `sessionID` and the popout view looks the bridge up
/// here.
///
/// Holds the bridge weakly: the parent `DocumentWindow` owns it via
/// `@StateObject`, and the popout's `@ObservedObject` keeps it alive while
/// the popout is open. When both go away the registry entry becomes nil
/// naturally.
///
/// Thread-safe via an internal lock so the bridge's `deinit` (which may run
/// off the main actor) can unregister without isolation hopping. Lookup is
/// gated to `@MainActor` since the bridge it returns is main-isolated.
final class BridgeSessionRegistry: @unchecked Sendable {
    static let shared = BridgeSessionRegistry()

    private let lock = NSLock()
    private var entries: [UUID: WeakBridge] = [:]

    private init() {}

    func register(_ bridge: BridgeClient) {
        let id = bridge.sessionID
        lock.lock(); defer { lock.unlock() }
        entries[id] = WeakBridge(bridge: bridge)
    }

    func unregister(sessionID: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: sessionID)
    }

    @MainActor
    func bridge(for sessionID: UUID) -> BridgeClient? {
        lock.lock(); defer { lock.unlock() }
        return entries[sessionID]?.bridge
    }
}

private final class WeakBridge {
    weak var bridge: BridgeClient?
    init(bridge: BridgeClient) { self.bridge = bridge }
}

/// Descriptor passed via `openWindow(value:)` to launch an iPad plot popout.
/// Must be Codable + Hashable so SwiftUI can serialize it into scene state.
struct PlotPopoutDescriptor: Hashable, Codable, Identifiable {
    var sessionID: UUID
    var paneID: Int

    var id: String { "\(sessionID.uuidString)#\(paneID)" }
}
