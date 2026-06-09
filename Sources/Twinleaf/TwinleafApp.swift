// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#endif

@main
struct TwinleafApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(TwinleafAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        DocumentGroup(newDocument: TioLogDocument()) { configuration in
            DocumentWindow(
                document: configuration.$document,
                fileURL: configuration.fileURL
            )
        }
        .commands {
            TwinleafCommands()
        }
        .defaultLaunchBehavior(.suppressed)
        #else
        DocumentGroup(newDocument: TioLogDocument()) { configuration in
            DocumentWindow(
                document: configuration.$document,
                fileURL: configuration.fileURL
            )
        }
        .commands {
            TwinleafCommands()
        }
        DocumentGroupLaunchScene("Twinleaf") {
            NewDocumentButton("Connect")
        }
        WindowGroup(for: PlotPopoutDescriptor.self) { $descriptor in
            if let descriptor {
                IPadPlotPopoutScene(descriptor: descriptor)
            }
        }
        #endif
    }
}

#if os(macOS)
@MainActor
final class TwinleafAppDelegate: NSObject, NSApplicationDelegate {
    private var didScheduleStartupDocument = false
    private var didRequestStartupDocument = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduleUntitledDocumentFallback()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        scheduleUntitledDocumentFallback()
        return true
    }

    private func scheduleUntitledDocumentFallback() {
        guard !didScheduleStartupDocument else { return }
        didScheduleStartupDocument = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600)) { [weak self] in
            self?.openUntitledDocumentIfNeeded()
        }
    }

    private func openUntitledDocumentIfNeeded() {
        guard !didRequestStartupDocument else { return }
        guard NSDocumentController.shared.documents.isEmpty else { return }
        didRequestStartupDocument = true
        NSDocumentController.shared.newDocument(nil)
    }
}
#endif
