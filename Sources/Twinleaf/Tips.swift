// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TipKit

/// Shown at the top of the stream list.
struct DragStreamsTip: Tip {
    var title: Text {
        Text("Drag streams to the graphs")
    }

    var message: Text? {
        Text("Drop a stream on a graph to add it there, or between two graphs to open a new one.")
    }

    var image: Image? {
        Image(systemName: "hand.draw")
    }
}

/// Shown at the top of the settings list.
struct DragSettingsTip: Tip {
    var title: Text {
        Text("Drag a setting out for a slider")
    }

    var message: Text? {
        Text("Drag a numeric setting's name onto the graphs to control it with a slider while you watch the data.")
    }

    var image: Image? {
        Image(systemName: "slider.horizontal.3")
    }
}

/// Shown once there are several graphs to arrange.
struct ReorderGraphsTip: Tip {
    var title: Text {
        Text("Drag a graph to move it")
    }

    var message: Text? {
        Text("Drop it on another graph to place it above or below.")
    }

    var image: Image? {
        Image(systemName: "arrow.up.arrow.down")
    }
}

/// Shown once there are several sliders to arrange.
struct ReorderSlidersTip: Tip {
    var title: Text {
        Text("Drag a slider by its name to reorder")
    }

    var image: Image? {
        Image(systemName: "arrow.up.arrow.down")
    }
}
