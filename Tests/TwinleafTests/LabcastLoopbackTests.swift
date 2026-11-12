// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

/// A publisher on 127.0.0.1 fed with synthetic sample packets, and a viewer
/// connected to it through `RemoteSessionSource`, the type the app's remote
/// session reads from.
final class LabcastLoopbackTests: XCTestCase {
    private static let samplesPerPacket = 4
    private static let packetsPerFrame = 8
    private static let samplesPerStream = 20_000
    private static let streams: [UInt8] = [1, 2]

    /// One TIO sample packet at the root route: type `128 + stream`, no
    /// routing, the payload length, a 24-bit first sample number, the segment,
    /// then `Float32` samples. Each sample's value is `stream * 1e6 + number`.
    private static func samplePacket(stream: UInt8, first: Int, count: Int) -> Data {
        var packet = Data()
        let payloadLength = UInt16(4 + count * 4)
        packet.append(128 + stream)
        packet.append(0)
        packet.append(UInt8(payloadLength & 0xff))
        packet.append(UInt8(payloadLength >> 8))
        packet.append(UInt8(first & 0xff))
        packet.append(UInt8((first >> 8) & 0xff))
        packet.append(UInt8((first >> 16) & 0xff))
        packet.append(0)
        for number in first..<(first + count) {
            let value = Float32(Int(stream) * 1_000_000 + number)
            withUnsafeBytes(of: value.bitPattern.littleEndian) { packet.append(contentsOf: $0) }
        }
        return packet
    }

    private struct Sample: Equatable {
        var stream: UInt8
        var number: Int
        var value: Float32
    }

    /// Splits received bytes back into sample packets and their samples.
    private static func samples(in data: Data) -> [Sample] {
        let bytes = [UInt8](data)
        var samples: [Sample] = []
        var offset = 0
        while offset + 8 <= bytes.count, bytes[offset] > 128 {
            let stream = bytes[offset] - 128
            let payloadLength = Int(bytes[offset + 2]) | Int(bytes[offset + 3]) << 8
            let first = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6]) << 16
            let count = (payloadLength - 4) / 4
            for index in 0..<count {
                let at = offset + 8 + index * 4
                let bits = UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
                    | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
                samples.append(Sample(stream: stream, number: first + index, value: Float32(bitPattern: bits)))
            }
            offset += 4 + payloadLength
        }
        return samples
    }

    private struct TimedOut: Error {}

    /// Fails instead of hanging if frames stop arriving: cancelling the body
    /// ends its wait on the event stream.
    func testEverySampleArrivesInOrder() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await Self.runLoopback() }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw TimedOut()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private static func runLoopback() async throws {
        let info = SharedSessionInfo(
            state: "streaming",
            message: "Streaming from serial://test",
            devices: [.init(
                route: "/",
                name: "VMR",
                serialNumber: "SN123",
                firmware: "fw",
                streams: Self.streams.map { stream in
                    .init(
                        id: stream,
                        name: "field\(stream)",
                        sampleRate: 1000,
                        columns: [.init(name: "x", units: "nT", description: "field along x", dataType: "f32")]
                    )
                }
            )]
        )
        // Stands in for the metadata packets; the transport does not read them.
        let metadata = Data("metadata".utf8)

        let publisher = SharedSessionPublisher(configuration: .init(name: "loopback-test", passcode: nil))
        publisher.publish(info)
        publisher.publish(SharedSessionFrame(kind: .metadata, packets: metadata))
        let port = try await publisher.start()
        defer { publisher.stop() }

        let source = RemoteSessionSource(host: "127.0.0.1", port: port)
        defer { source.stop() }
        var events = source.events().makeAsyncIterator()

        // A viewer that joins late is first told what it is looking at. The
        // retained frames arrive once its subscriptions are registered, so
        // nothing published after this point can be missed.
        var receivedInfo: SharedSessionInfo?
        var receivedMetadata: Data?
        while receivedInfo == nil || receivedMetadata == nil, let event = await events.next() {
            switch event {
            case .info(let value): receivedInfo = value
            case .packets(let data): receivedMetadata = data
            case .state: break
            }
        }
        XCTAssertEqual(receivedInfo, info)
        XCTAssertEqual(receivedMetadata, metadata)

        // Publish as the Rust core does: sample packets gathered per stream
        // into frames, the streams interleaved, in the core's own framing.
        var expected: [UInt8: [Sample]] = [:]
        let packetCount = Self.samplesPerStream / Self.samplesPerPacket
        var frameCount = 0
        for frameStart in stride(from: 0, to: packetCount, by: Self.packetsPerFrame) {
            for stream in Self.streams {
                var packets = Data()
                for packet in frameStart..<min(frameStart + Self.packetsPerFrame, packetCount) {
                    let first = packet * Self.samplesPerPacket
                    packets.append(Self.samplePacket(stream: stream, first: first, count: Self.samplesPerPacket))
                    for number in first..<(first + Self.samplesPerPacket) {
                        expected[stream, default: []].append(Sample(
                            stream: stream,
                            number: number,
                            value: Float32(Int(stream) * 1_000_000 + number)
                        ))
                    }
                }
                var wire = Data([SharedSessionFrame.Kind.samples.rawValue, stream, 1, 0])
                wire.append(contentsOf: "/".utf8)
                wire.append(packets)
                let frame = try XCTUnwrap(SharedSessionFrame(wire))
                XCTAssertEqual(frame.topic, "tio/samples/root/\(stream)")
                publisher.publish(frame)
                frameCount += 1
            }
        }

        var received: [UInt8: [Sample]] = [:]
        var receivedFrames = 0
        let total = Self.samplesPerStream * Self.streams.count
        var receivedTotal = 0
        while receivedTotal < total, let event = await events.next() {
            guard case .packets(let data) = event else { continue }
            let batch = Self.samples(in: data)
            receivedFrames += 1
            receivedTotal += batch.count
            for sample in batch {
                received[sample.stream, default: []].append(sample)
            }
        }

        XCTAssertEqual(receivedFrames, frameCount)
        for stream in Self.streams {
            XCTAssertEqual(received[stream]?.count, Self.samplesPerStream)
            XCTAssertEqual(received[stream], expected[stream], "stream \(stream) differs or is out of order")
        }
    }

    func testFramingOfTheCoreIsDecoded() {
        var wire = Data([2, 3, 4, 0])
        wire.append(contentsOf: "/0/1".utf8)
        wire.append(contentsOf: [9, 8, 7])
        let frame = SharedSessionFrame(wire)
        XCTAssertEqual(frame, SharedSessionFrame(kind: .samples, route: "/0/1", stream: 3, packets: Data([9, 8, 7])))
        XCTAssertEqual(frame?.topic, "tio/samples/0.1/3")
        XCTAssertEqual(SharedSessionFrame(Data([1, 0, 0, 0]))?.topic, "tio/metadata")
        XCTAssertEqual(SharedSessionFrame(Data([3, 0, 0, 0, 5]))?.topic, "tio/packets")
        XCTAssertNil(SharedSessionFrame(Data([9, 0, 0, 0])))
        XCTAssertNil(SharedSessionFrame(Data([2, 1, 9, 0, 47])))
    }
}
