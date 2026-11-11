// SPDX-License-Identifier: Apache-2.0

import Foundation

#if os(iOS)
import ActivityKit
import BackgroundTasks
import UIKit
#endif

/// Tracks which document windows are recording a log right now, and keeps the
/// system from quietly starving them while any is.
///
/// A log is the document's data, so the recording must not depend on the
/// window staying frontmost or the user touching the machine:
/// - On the Mac it holds a process activity that turns off App Nap (which
///   throttles a background app's threads and timers, the Rust reader's
///   included) and idle system sleep. The display may still sleep, and closing
///   a laptop's lid still sleeps the Mac.
/// - On iOS it keeps the screen from auto-locking, asks the system for a
///   continued-processing task so the recording carries on when the app is
///   backgrounded or the device locked, and runs the Live Activity.
@MainActor
final class LoggingSessionMonitor {
    static let shared = LoggingSessionMonitor()

    /// Recording sessions and what each is recording.
    private var liveSessions: [UUID: String] = [:]
    #if os(macOS)
    private var activity: NSObjectProtocol?
    #endif

    private init() {
        #if os(iOS)
        LoggingLiveActivityController.shared.endLeftoverActivities()
        #endif
    }

    func setLogging(_ isLogging: Bool, sessionID: UUID, deviceName: String) {
        if isLogging {
            guard liveSessions.updateValue(deviceName, forKey: sessionID) == nil else { return }
            #if os(iOS)
            LoggingLiveActivityController.shared.start(sessionID: sessionID, deviceName: deviceName)
            #endif
        } else {
            guard liveSessions.removeValue(forKey: sessionID) != nil else { return }
            #if os(iOS)
            LoggingLiveActivityController.shared.end(sessionID: sessionID)
            #endif
        }
        updateKeepAwake()
        #if os(iOS)
        LoggingBackgroundTask.shared.update(deviceNames: liveSessions.values.sorted())
        #endif
    }

    /// For a bridge's `deinit`, which may run off the main actor.
    nonisolated static func sessionClosed(_ sessionID: UUID) {
        Task { @MainActor in
            LoggingSessionMonitor.shared.setLogging(false, sessionID: sessionID, deviceName: "")
        }
    }

    private func updateKeepAwake() {
        let shouldStayAwake = !liveSessions.isEmpty
        #if os(macOS)
        if shouldStayAwake, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Recording a Twinleaf sensor log"
            )
        } else if !shouldStayAwake, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #elseif os(iOS)
        UIApplication.shared.isIdleTimerDisabled = shouldStayAwake
        #endif
    }
}

/// How often live plots may redraw, given how hard the device is being pushed.
///
/// Only drawing is held back. Reading the sensor and writing the log happen in
/// the Rust core and never pass through here, so a hot or power-saving device
/// still records every packet; the graphs just refresh less often.
@MainActor
final class PlotRefreshGovernor: ObservableObject {
    static let shared = PlotRefreshGovernor()

    /// The least time between redraws of one live graph; zero means every
    /// frame the core sends is drawn.
    @Published private(set) var minimumPlotInterval: TimeInterval = 0
    /// Why redraws are being held back, for the status bar; nil when they
    /// are not.
    @Published private(set) var reason: String?

    private init() {
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    PlotRefreshGovernor.shared.refresh()
                }
            }
        }
        refresh()
    }

    private func refresh() {
        let processInfo = ProcessInfo.processInfo
        let interval: TimeInterval
        let reason: String?
        // The core sends about 30 frames a second.
        switch processInfo.thermalState {
        case .critical:
            (interval, reason) = (0.5, "Graphs slowed: device is very hot")
        case .serious:
            (interval, reason) = (0.1, "Graphs slowed: device is hot")
        default:
            if processInfo.isLowPowerModeEnabled {
                (interval, reason) = (1.0 / 15.0, "Graphs slowed: Low Power Mode")
            } else {
                (interval, reason) = (0, nil)
            }
        }
        if minimumPlotInterval != interval { minimumPlotInterval = interval }
        if self.reason != reason { self.reason = reason }
    }
}

#if os(iOS)
/// Runs one Live Activity per recording document.
@MainActor
final class LoggingLiveActivityController {
    static let shared = LoggingLiveActivityController()

    /// `Activity` is not marked Sendable, but its update and end calls are
    /// its own asynchronous API and safe to make from any task; the box lets
    /// them run off the main actor.
    private struct ActivityBox: @unchecked Sendable {
        let activity: Activity<LoggingActivityAttributes>

        func end() {
            Task.detached {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private var activities: [UUID: ActivityBox] = [:]

    private init() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // With a background task running the recording carries on.
                if !LoggingBackgroundTask.shared.isRunning {
                    LoggingLiveActivityController.shared.setPhase(.suspended)
                }
            }
        }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                LoggingLiveActivityController.shared.setPhase(.logging)
                LoggingBackgroundTask.shared.resubmitIfNeeded()
            }
        }
    }

    func start(sessionID: UUID, deviceName: String) {
        guard activities[sessionID] == nil,
              ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }
        let attributes = LoggingActivityAttributes(
            deviceName: deviceName.isEmpty ? "Twinleaf" : deviceName,
            startedAt: Date()
        )
        guard let activity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: .init(phase: .logging), staleDate: nil)
        ) else {
            return
        }
        activities[sessionID] = ActivityBox(activity: activity)
    }

    func end(sessionID: UUID) {
        activities.removeValue(forKey: sessionID)?.end()
    }

    /// An activity outlives the app if it is killed mid-recording. Nothing is
    /// recording at launch, so anything still showing is left over.
    func endLeftoverActivities() {
        for activity in Activity<LoggingActivityAttributes>.activities {
            ActivityBox(activity: activity).end()
        }
    }

    /// Without background time the app is suspended shortly after it leaves
    /// the foreground and stops recording until it returns, so the activity
    /// has to say so rather than keep claiming to log.
    func setPhase(_ phase: LoggingActivityAttributes.Phase) {
        guard !activities.isEmpty else { return }
        let application = UIApplication.shared
        // Hold off suspension until the updates have gone out.
        let backgroundTask = application.beginBackgroundTask(withName: "Update logging activity")
        let boxes = Array(activities.values)
        Task.detached {
            for box in boxes {
                await box.activity.update(ActivityContent(state: .init(phase: phase), staleDate: nil))
            }
            await MainActor.run {
                if backgroundTask != .invalid {
                    application.endBackgroundTask(backgroundTask)
                }
            }
        }
    }
}

/// Keeps a recording going while the app is in the background, using iOS's
/// continued-processing task: work the user started in the foreground that
/// the system lets run on, with its own progress banner and a stop button.
///
/// The system owns the task. It can end it when the device is under pressure,
/// and so can the user from the banner; iOS then suspends the app as it
/// always did, and the Live Activity says the recording is paused. The task is
/// requested again the next time the app comes to the foreground.
@MainActor
final class LoggingBackgroundTask {
    static let shared = LoggingBackgroundTask()

    /// `BGTask` is handed over on a background queue and is not Sendable.
    /// Completing it twice is an error, and both the app (recording stopped)
    /// and the system (expiry) can ask, so completion goes through one gate.
    private final class TaskBox: @unchecked Sendable {
        let task: BGTask
        private let lock = NSLock()
        private var isCompleted = false

        init(task: BGTask) {
            self.task = task
        }

        func complete(success: Bool) {
            lock.lock()
            let shouldComplete = !isCompleted
            isCompleted = true
            lock.unlock()
            if shouldComplete {
                task.setTaskCompleted(success: success)
            }
        }
    }

    private static let title = "Logging sensor data"
    /// A recording has no end to measure progress against, so progress is
    /// time recorded within the current hour; the bar refills each hour.
    private static let progressHorizonSeconds: Int64 = 3600

    private var deviceNames: [String] = []
    /// The request the scheduler currently holds, running or still queued.
    private var requestedIdentifier: String?
    private var running: TaskBox?
    private var startedAt = Date()
    private var ticker: Task<Void, Never>?

    private init() {}

    var isRunning: Bool { running != nil }

    func update(deviceNames: [String]) {
        self.deviceNames = deviceNames
        if deviceNames.isEmpty {
            finish()
        } else if requestedIdentifier == nil {
            submit()
        } else {
            refreshBanner()
        }
    }

    /// A task that expired while the app was in the background can only be
    /// requested again once the app is back in front.
    func resubmitIfNeeded() {
        if !deviceNames.isEmpty, requestedIdentifier == nil {
            submit()
        }
    }

    private var subtitle: String {
        let names = deviceNames.filter { !$0.isEmpty }
        return names.isEmpty ? "Twinleaf" : names.joined(separator: ", ")
    }

    private func submit() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        // Matches the `<bundle id>.logging.*` entry in the Info.plist. Each
        // request gets its own identifier and its own handler.
        let identifier = "\(bundleID).logging.\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            let box = TaskBox(task: task)
            task.expirationHandler = {
                box.complete(success: false)
                Task { @MainActor in
                    LoggingBackgroundTask.shared.expired(identifier: identifier)
                }
            }
            Task { @MainActor in
                LoggingBackgroundTask.shared.began(box, identifier: identifier)
            }
        }
        guard registered else { return }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: Self.title,
            subtitle: subtitle
        )
        do {
            try BGTaskScheduler.shared.submit(request)
            requestedIdentifier = identifier
        } catch {
            TwinleafConsole.debug("[Twinleaf] background logging task not granted: \(error)")
        }
    }

    private func began(_ box: TaskBox, identifier: String) {
        guard identifier == requestedIdentifier, !deviceNames.isEmpty else {
            // The recording stopped before the system got to the request.
            box.complete(success: true)
            return
        }
        running = box
        startedAt = Date()
        refreshBanner()
        LoggingLiveActivityController.shared.setPhase(.logging)

        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.reportProgress()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The system must see progress, or it treats the task as stalled.
    private func reportProgress() {
        guard let task = running?.task as? BGContinuedProcessingTask else { return }
        let elapsed = Int64(max(0, Date().timeIntervalSince(startedAt)))
        task.progress.totalUnitCount = Self.progressHorizonSeconds
        task.progress.completedUnitCount = elapsed % Self.progressHorizonSeconds
    }

    private func refreshBanner() {
        guard let task = running?.task as? BGContinuedProcessingTask else { return }
        task.updateTitle(Self.title, subtitle: subtitle)
    }

    private func finish() {
        ticker?.cancel()
        ticker = nil
        if let running {
            running.complete(success: true)
        } else if let requestedIdentifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestedIdentifier)
        }
        running = nil
        requestedIdentifier = nil
    }

    private func expired(identifier: String) {
        guard identifier == requestedIdentifier else { return }
        ticker?.cancel()
        ticker = nil
        running = nil
        requestedIdentifier = nil
        // Still recording as far as the app is concerned, but out of
        // background time: about to be suspended unless it is in front.
        if UIApplication.shared.applicationState == .background {
            LoggingLiveActivityController.shared.setPhase(.suspended)
        }
    }
}
#endif
