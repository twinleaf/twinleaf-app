// SPDX-License-Identifier: Apache-2.0

import Foundation

extension Notification.Name {
    static let showDevicePicker = Notification.Name("TwinleafShowDevicePicker")
    static let showExportPanel = Notification.Name("TwinleafShowExportPanel")
    static let showPlotSettings = Notification.Name("TwinleafShowPlotSettings")
    static let togglePlotPause = Notification.Name("TwinleafTogglePlotPause")
    static let toggleDataLogging = Notification.Name("TwinleafToggleDataLogging")
    static let refreshDeviceList = Notification.Name("TwinleafRefreshDeviceList")
    static let focusRPCSearch = Notification.Name("TwinleafFocusRPCSearch")
}
