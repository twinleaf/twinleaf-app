// SPDX-License-Identifier: Apache-2.0

import Foundation

// Sharing a live session over Labcast, and viewing a shared one.
//
// The Mac that owns the devices publishes, per live session:
//
//   session              JSON `SharedSessionInfo`, retained: status and what
//                        the devices, streams and columns are.
//   tio/metadata         The session's metadata as TIO UPDATE packets, retained:
//                        what a `.tio` log starts with.
//   tio/samples/<route>/<stream>
//                        Sample packets of one stream, a few tens of
//                        milliseconds per frame.
//   tio/packets          Every other packet the session receives (heartbeats,
//                        device log lines, settings), one per frame.
//
// Everything under `tio/` is whole TIO packets in wire form and is never
// dropped, so a viewer receives exactly the packet stream the publisher would
// log. The viewer's Rust core decodes it as it decodes a log.
//
// This file depends on Foundation and the Labcast sources only, so the
// loopback test builds it without the app.

enum TwinleafLabcast {
    static let appID = "twinleaf"
    /// `AvailableDevice.kind` of a shared session in the device picker.
    static let deviceKind = "labcast"
    static let urlScheme = "labcast"

    static let sessionTopic = "session"
    static let metadataTopic = "tio/metadata"
    static let packetsTopic = "tio/packets"
    static let packetPattern = "tio/*"

    static func samplesTopic(route: String, stream: UInt8) -> String {
        let hops = route.split(separator: "/").joined(separator: ".")
        return "tio/samples/\(hops.isEmpty ? "root" : hops)/\(stream)"
    }

    /// `UserDefaults` keys of the sharing settings.
    static let publishEnabledKey = "labcast.publishEnabled"
    static let passcodeKey = "labcast.passcode"

    static var storedPasscode: String? {
        let passcode = UserDefaults.standard.string(forKey: passcodeKey) ?? ""
        return passcode.isEmpty ? nil : passcode
    }
}

/// What a viewer is told about a shared session besides its packets.
struct SharedSessionInfo: Codable, Equatable, Sendable {
    struct Column: Codable, Equatable, Sendable {
        var name: String
        var units: String
        var description: String
        var dataType: String
    }

    struct Stream: Codable, Equatable, Sendable {
        var id: UInt8
        var name: String
        var sampleRate: Double
        var columns: [Column]
    }

    struct Device: Codable, Equatable, Sendable {
        var route: String
        var name: String
        var serialNumber: String
        var firmware: String
        var streams: [Stream]
    }

    /// The publisher's session state, as its status bar shows it
    /// (`streaming`, `logging`, `error`, ...).
    var state: String
    var message: String
    var devices: [Device]
}

/// One frame of a shared session as the Rust core hands it over: what it
/// holds, and for samples the stream they belong to, then whole TIO packets.
struct SharedSessionFrame: Equatable, Sendable {
    enum Kind: UInt8, Sendable {
        case metadata = 1
        case samples = 2
        case packets = 3
    }

    var kind: Kind
    var route: String
    var stream: UInt8
    var packets: Data

    /// Decodes `kind, stream, route length (UInt16 LE), route, packets`.
    init?(_ data: Data) {
        let bytes = [UInt8](data.prefix(4))
        guard bytes.count == 4, let kind = Kind(rawValue: bytes[0]) else { return nil }
        let routeLength = Int(bytes[2]) | Int(bytes[3]) << 8
        guard data.count >= 4 + routeLength else { return nil }
        let body = data.dropFirst(4)
        self.kind = kind
        self.stream = bytes[1]
        self.route = String(decoding: body.prefix(routeLength), as: UTF8.self)
        self.packets = Data(body.dropFirst(routeLength))
    }

    init(kind: Kind, route: String = "", stream: UInt8 = 0, packets: Data) {
        self.kind = kind
        self.route = route
        self.stream = stream
        self.packets = packets
    }

    var topic: String {
        switch kind {
        case .metadata: TwinleafLabcast.metadataTopic
        case .samples: TwinleafLabcast.samplesTopic(route: route, stream: stream)
        case .packets: TwinleafLabcast.packetsTopic
        }
    }
}

/// Publishes one live session to viewers on the local network.
final class SharedSessionPublisher: Sendable {
    struct Configuration: Equatable, Sendable {
        var name: String
        var passcode: String?
        /// The session's device names, shown beside the publisher's name
        /// where a viewer picks a session.
        var deviceSummary: String = ""
        /// Fixed TCP port, or nil to let the system choose.
        var port: UInt16?
    }

    let configuration: Configuration
    private let publisher: LabcastPublisher

    init(configuration: Configuration) {
        self.configuration = configuration
        publisher = LabcastPublisher(configuration: .init(
            name: configuration.name,
            appID: TwinleafLabcast.appID,
            passcode: configuration.passcode,
            info: ["device": String(configuration.deviceSummary.prefix(80))],
            port: configuration.port
        ))
    }

    /// Starts listening and advertising. Values published before this are
    /// kept if they are retained, so the order of the two does not matter.
    @discardableResult
    func start() async throws -> UInt16 {
        try await publisher.start()
    }

    func stop() {
        publisher.stop()
    }

    /// Packets are logged by viewers, so no frame is ever skipped for a slow
    /// one. Only the metadata is kept for viewers that join later.
    func publish(_ frame: SharedSessionFrame) {
        publisher.publish(
            frame.topic,
            payload: frame.packets,
            retain: frame.kind == .metadata,
            droppable: false
        )
    }

    func publish(_ info: SharedSessionInfo) {
        publisher.publish(TwinleafLabcast.sessionTopic, json: info, retain: true, droppable: false)
    }
}

/// A shared session being viewed: the remote counterpart of a device. It
/// yields the publisher's packets in the order they were published, and
/// reconnects by itself after a drop.
final class RemoteSessionSource: Sendable {
    enum Event: Sendable {
        case state(LabcastSubscriber.State)
        case info(SharedSessionInfo)
        /// Whole TIO packets, to hand to the Rust core as they are.
        case packets(Data)
    }


    private let subscriber: LabcastSubscriber

    init(peer: LabcastPeer, passcode: String?) {
        subscriber = LabcastSubscriber(peer: peer, passcode: passcode)
    }

    /// Connects by address, for tests and publishers Bonjour cannot reach.
    init(host: String, port: UInt16, passcode: String? = nil) {
        subscriber = LabcastSubscriber(host: host, port: port, passcode: passcode)
    }

    /// Everything the session sends, as one stream. Connecting starts with the
    /// first call; ending the iteration or calling `stop()` disconnects.
    func events() -> AsyncStream<Event> {
        let subscriber = subscriber
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let packets = subscriber.subscribe(TwinleafLabcast.packetPattern, buffer: nil)
            let info = subscriber.subscribe(TwinleafLabcast.sessionTopic)
            let states = subscriber.states()
            let tasks = [
                Task {
                    for await message in packets {
                        continuation.yield(.packets(message.payload))
                    }
                },
                Task {
                    for await message in info {
                        if let info = try? message.decode(SharedSessionInfo.self) {
                            continuation.yield(.info(info))
                        }
                    }
                },
                Task {
                    for await state in states {
                        continuation.yield(.state(state))
                    }
                },
            ]
            continuation.onTermination = { _ in
                tasks.forEach { $0.cancel() }
                subscriber.disconnect()
            }
            subscriber.connect()
        }
    }

    func stop() {
        subscriber.disconnect()
    }
}
