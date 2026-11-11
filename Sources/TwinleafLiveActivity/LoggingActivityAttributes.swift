// SPDX-License-Identifier: Apache-2.0

// Shared between the app, which starts and updates the activity, and the
// widget extension, which draws it. ActivityKit is unavailable to native Mac
// apps, so all of this is iOS-only.
#if os(iOS)
import ActivityKit
import Foundation

struct LoggingActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable, Sendable {
        /// Packets are being written to the log.
        case logging
        /// iOS has moved the app to the background, where it is suspended and
        /// nothing is being logged until it is opened again.
        case suspended
    }

    struct ContentState: Codable, Hashable, Sendable {
        var phase: Phase
    }

    /// What is being logged, e.g. "VMR" or "VMR + 2 more".
    var deviceName: String
    var startedAt: Date
}
#endif
