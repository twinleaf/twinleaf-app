// SPDX-License-Identifier: Apache-2.0

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TwinleafLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        LoggingLiveActivity()
    }
}

/// Shows that a Twinleaf log is being recorded: on the Lock Screen, in the
/// Dynamic Island, and — through iPhone Mirroring — in the Mac's menu bar.
struct LoggingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LoggingActivityAttributes.self) { context in
            HStack(spacing: 12) {
                LoggingPhaseIcon(phase: context.state.phase)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.deviceName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.phase.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                LoggingElapsedTime(
                    phase: context.state.phase,
                    startedAt: context.attributes.startedAt
                )
                .font(.title3.monospacedDigit())
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LoggingPhaseIcon(phase: context.state.phase)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.deviceName)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LoggingElapsedTime(
                        phase: context.state.phase,
                        startedAt: context.attributes.startedAt
                    )
                    .font(.body.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.phase.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                LoggingPhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                LoggingElapsedTime(
                    phase: context.state.phase,
                    startedAt: context.attributes.startedAt
                )
                .font(.caption.monospacedDigit())
                .frame(maxWidth: 52)
            } minimal: {
                LoggingPhaseIcon(phase: context.state.phase)
            }
        }
    }
}

private extension LoggingActivityAttributes.Phase {
    var caption: String {
        switch self {
        case .logging: "Logging"
        case .suspended: "Paused — open Twinleaf to resume"
        }
    }
}

private struct LoggingPhaseIcon: View {
    let phase: LoggingActivityAttributes.Phase

    var body: some View {
        switch phase {
        case .logging:
            Image(systemName: "record.circle")
                .foregroundStyle(.red)
        case .suspended:
            Image(systemName: "pause.circle")
                .foregroundStyle(.orange)
        }
    }
}

/// Time since logging started. It only runs while logging: a suspended app
/// is not recording, so a ticking clock there would claim data that isn't.
private struct LoggingElapsedTime: View {
    let phase: LoggingActivityAttributes.Phase
    let startedAt: Date

    var body: some View {
        switch phase {
        case .logging:
            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        case .suspended:
            Image(systemName: "pause.fill")
                .foregroundStyle(.secondary)
        }
    }
}
