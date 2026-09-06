// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
import AppKit
#endif
import SwiftUI

struct TwinleafCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Export...") {
                postCommand(.showExportPanel)
            }
            .keyboardShortcut("e", modifiers: [.command])
        }

#if os(macOS)
        // Replaces the stock Page Setup/Print pair: the print panel already
        // exposes paper size and orientation, and the document window picks
        // the initial orientation from the shape of its plot area.
        CommandGroup(replacing: .printItem) {
            Button("Print...") {
                postCommand(.printDocument)
            }
            .keyboardShortcut("p", modifiers: [.command])
        }
#endif

        CommandMenu("Device") {
            Button("Connect to Device...") {
                NotificationCenter.default.post(name: .showDevicePicker, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button("Refresh Device List") {
                NotificationCenter.default.post(name: .refreshDeviceList, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .option, .shift])

            Divider()

            Button("Toggle Log Data") {
                postCommand(.toggleDataLogging)
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
        }

        CommandGroup(after: .toolbar) {
            TwinleafDistractionFreeControl(usesMenuShortcut: true)

            Button("Find Setting") {
                NotificationCenter.default.post(name: .focusRPCSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command])

            Divider()

            TwinleafInterfaceVisibilityControls(
                includesToolbar: true,
                usesMenuShortcuts: true
            )

            Divider()

            TwinleafInterfaceDetailControls()
        }

        CommandMenu("Plot") {
            Button("Toggle Pause") {
                NotificationCenter.default.post(name: .togglePlotPause, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Button("Settings...") {
                NotificationCenter.default.post(name: .showPlotSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }

    private func postCommand(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: currentWindowID)
    }

    private var currentWindowID: ObjectIdentifier? {
#if os(macOS)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return ObjectIdentifier(window)
        }
#endif
        return nil
    }
}
