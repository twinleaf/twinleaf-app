// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
import AppKit
import SwiftUI

/// One print request. The page is built lazily for the final page size, so a
/// paper or orientation change made in the print panel lays the graphs out
/// again for the new page rather than scaling a fixed snapshot of the window.
struct PlotPrintJob {
    /// Shown in the print queue and used as the default name for "Save as PDF".
    let jobTitle: String
    /// Initial orientation. The user can still flip it in the print panel.
    let prefersLandscape: Bool
    /// Builds the SwiftUI page content for the printable area of one page.
    let makeContent: @MainActor (CGSize) -> AnyView
}

@MainActor
enum PlotPrinter {
    /// Page margin in points. Graphs want the paper, not a one-inch frame.
    static let pageMargin: CGFloat = 36

    static func run(_ job: PlotPrintJob, attachedTo window: NSWindow?) {
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.orientation = job.prefersLandscape ? .landscape : .portrait
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true
        applyMargins(to: printInfo)

        let view = PlotPrintView(job: job)
        view.layOut(for: printInfo)

        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.jobTitle = job.jobTitle
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([
            .showsPaperSize,
            .showsOrientation,
            .showsScaling,
            .showsPreview,
        ])

        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// Uniform margins, widened only where the printer cannot image the paper.
    private static func applyMargins(to printInfo: NSPrintInfo) {
        let paper = printInfo.paperSize
        let imageable = printInfo.imageablePageBounds
        printInfo.leftMargin = max(pageMargin, imageable.minX)
        printInfo.bottomMargin = max(pageMargin, imageable.minY)
        printInfo.rightMargin = max(pageMargin, paper.width - imageable.maxX)
        printInfo.topMargin = max(pageMargin, paper.height - imageable.maxY)
    }
}

/// The printed view: a single page whose content is a SwiftUI page rendered
/// to a PDF with `ImageRenderer`, then drawn into the print context. Going
/// through PDF keeps the traces and text as vectors and lets the print
/// panel's preview redraw cheaply without re-running SwiftUI layout.
private final class PlotPrintView: NSView {
    private let job: PlotPrintJob
    private var renderedPage: CGPDFPage?
    private var renderedSize: CGSize = .zero

    init(job: PlotPrintJob) {
        self.job = job
        super.init(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Sizes the view to the printable area of one page.
    func layOut(for printInfo: NSPrintInfo) {
        let paper = printInfo.paperSize
        let size = CGSize(
            width: max(1, paper.width - printInfo.leftMargin - printInfo.rightMargin),
            height: max(1, paper.height - printInfo.topMargin - printInfo.bottomMargin)
        )
        guard size != frame.size else { return }
        frame = NSRect(origin: .zero, size: size)
    }

    // MARK: Pagination

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        // Runs after the print panel closes, so this sees the paper size and
        // orientation the user actually picked.
        if let printInfo = NSPrintOperation.current?.printInfo {
            layOut(for: printInfo)
        }
        renderIfNeeded()
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        bounds
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        renderIfNeeded()
        guard let page = renderedPage else { return }

        context.saveGState()
        // Not flipped, so the view's origin is bottom-left like the PDF's.
        let transform = page.getDrawingTransform(
            .mediaBox,
            rect: bounds,
            rotate: 0,
            preserveAspectRatio: true
        )
        context.concatenate(transform)
        context.drawPDFPage(page)
        context.restoreGState()
    }

    private func renderIfNeeded() {
        let size = bounds.size
        guard renderedPage == nil || renderedSize != size else { return }
        renderedSize = size
        renderedPage = Self.renderPDFPage(job.makeContent(size), size: size)
    }

    private static func renderPDFPage(_ content: AnyView, size: CGSize) -> CGPDFPage? {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.proposedSize = ProposedViewSize(size)

        let data = NSMutableData()
        // Vector where SwiftUI can manage it; anything it has to rasterize
        // gets roughly print resolution instead of screen resolution.
        renderer.render(rasterizationScale: 4) { renderedSize, renderInContext in
            var mediaBox = CGRect(origin: .zero, size: renderedSize)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                return
            }
            context.beginPDFPage(nil)
            renderInContext(context)
            context.endPDFPage()
            context.closePDF()
        }

        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else {
            return nil
        }
        return document.page(at: 1)
    }
}
#endif
