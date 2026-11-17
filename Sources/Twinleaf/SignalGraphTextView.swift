// SPDX-License-Identifier: Apache-2.0

import SwiftUI

#if os(macOS)
import AppKit

private typealias PlatformTextView = NSTextView
private typealias PlatformColor = NSColor
private typealias PlatformFont = NSFont
#else
import UIKit

private typealias PlatformTextView = UITextView
private typealias PlatformColor = UIColor
private typealias PlatformFont = UIFont
#endif

/// How a signal graph's text is drawn. The colours are the system's own, so
/// they follow the appearance without the text being styled again.
private enum SignalGraphTextStyle {
    static let fontSize: CGFloat = 13

    static var font: PlatformFont {
        .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static var strongFont: PlatformFont {
        .monospacedSystemFont(ofSize: fontSize, weight: .semibold)
    }

    static var plain: PlatformColor {
        #if os(macOS)
        .labelColor
        #else
        .label
        #endif
    }

    private static var quiet: PlatformColor {
        #if os(macOS)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }

    /// The colour of a class of token, as the outline names them.
    static func color(for tokenClass: String) -> PlatformColor {
        switch tokenClass {
        case "keyword": .systemPink
        case "function": .systemBlue
        case "param": .systemOrange
        case "argument": .systemTeal
        case "channel": .systemIndigo
        case "number": .systemPurple
        case "unit": .systemGreen
        case "path": .systemBrown
        case "attribute", "operator", "punctuation": quiet
        case "comment": .systemGray
        case "invalid": .systemRed
        default: plain
        }
    }

    static var selectedNode: PlatformColor {
        #if os(macOS)
        NSColor.controlAccentColor.withAlphaComponent(0.16)
        #else
        UIColor.tintColor.withAlphaComponent(0.16)
        #endif
    }

    /// Styles all of `storage` from an outline of the same text.
    static func apply(
        _ outline: SignalGraphOutline,
        selected: SignalGraphOutline.Node?,
        to storage: NSTextStorage
    ) {
        let length = storage.length
        let whole = NSRange(location: 0, length: length)
        // An outline of a text other than this one says nothing about it.
        func clamped(_ span: SignalGraphOutline.Span, atLeastOne: Bool = false) -> NSRange? {
            guard span.start <= length else { return nil }
            var range = NSRange(location: span.start, length: min(span.end, length) - span.start)
            if range.length <= 0 {
                guard atLeastOne, length > 0 else { return nil }
                // A place rather than a stretch: mark the character there,
                // or the last one when it is the end of the text.
                range = NSRange(location: min(span.start, length - 1), length: 1)
            }
            return range
        }

        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: plain], range: whole)
        for mark in outline.marks {
            guard let range = clamped(mark.range) else { continue }
            storage.addAttribute(.foregroundColor, value: color(for: mark.class), range: range)
            if mark.class == "definition" {
                storage.addAttribute(.font, value: strongFont, range: range)
            }
        }
        if let selected, let range = clamped(selected.focus) {
            storage.addAttribute(.backgroundColor, value: selectedNode, range: range)
        }
        for problem in outline.problems {
            guard let range = clamped(problem.range, atLeastOne: true) else { continue }
            let color: PlatformColor = problem.isError ? .systemRed : .systemYellow
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: range)
            storage.addAttribute(.underlineColor, value: color, range: range)
        }
        storage.endEditing()
    }
}

/// Stands between the editor's model and the platform's text view: tells
/// the model what was typed and where the caret is, and makes the edits the
/// model asks for through the view, so that they can be undone there.
@MainActor
final class SignalGraphTextCoordinator: NSObject, SignalGraphTextPort {
    let model: SignalGraphEditorModel
    fileprivate weak var textView: PlatformTextView?

    init(model: SignalGraphEditorModel) {
        self.model = model
    }

    private var storage: NSTextStorage? {
        #if os(macOS)
        textView?.textStorage
        #else
        textView?.textStorage
        #endif
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let length = storage?.length ?? 0
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    fileprivate func textChanged() {
        guard let textView else { return }
        #if os(macOS)
        model.textDidChange(textView.string)
        #else
        model.textDidChange(textView.text ?? "")
        #endif
    }

    fileprivate func selectionChanged() {
        guard let textView else { return }
        #if os(macOS)
        model.selectionDidChange(textView.selectedRange())
        #else
        model.selectionDidChange(textView.selectedRange)
        #endif
    }

    // MARK: SignalGraphTextPort

    func replace(_ range: NSRange, with text: String, selecting: NSRange?) {
        guard let textView, let storage else { return }
        let range = clamped(range)
        #if os(macOS)
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        storage.replaceCharacters(in: range, with: text)
        // Tells the delegate, and so the model, and closes the undo group.
        textView.didChangeText()
        if let selecting {
            textView.setSelectedRange(clamped(selecting))
        }
        #else
        if let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
           let end = textView.position(from: start, offset: range.length),
           let target = textView.textRange(from: start, to: end) {
            // Through the input system, which is what registers the undo.
            textView.replace(target, withText: text)
        } else {
            storage.replaceCharacters(in: range, with: text)
        }
        if let selecting {
            textView.selectedRange = clamped(selecting)
        }
        // A change made in code is not always reported. Reporting one twice
        // does nothing.
        textChanged()
        #endif
    }

    func setText(_ text: String) {
        guard let textView else { return }
        #if os(macOS)
        guard textView.string != text else { return }
        textView.string = text
        #else
        guard textView.text != text else { return }
        textView.text = text
        #endif
        // What came before was another text's history.
        textView.undoManager?.removeAllActions()
    }

    func reveal(_ range: NSRange) {
        guard let textView else { return }
        let range = clamped(range)
        #if os(macOS)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        // The selection is faint in a view that is not being typed in.
        textView.showFindIndicator(for: range)
        #else
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
        #endif
    }

    func restyle() {
        guard let textView, let storage else { return }
        // Text still being composed belongs to the input method.
        #if os(macOS)
        guard !textView.hasMarkedText() else { return }
        #else
        guard textView.markedTextRange == nil else { return }
        #endif
        SignalGraphTextStyle.apply(model.outline, selected: model.selectedNode, to: storage)
        #if os(macOS)
        textView.typingAttributes = [
            .font: SignalGraphTextStyle.font,
            .foregroundColor: SignalGraphTextStyle.plain,
        ]
        #else
        textView.typingAttributes = [
            .font: SignalGraphTextStyle.font,
            .foregroundColor: SignalGraphTextStyle.plain,
        ]
        #endif
    }
}

#if os(macOS)
extension SignalGraphTextCoordinator: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        textChanged()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        selectionChanged()
    }
}

/// The text of a signal graph, coloured as the outline says.
struct SignalGraphTextView: NSViewRepresentable {
    @ObservedObject var model: SignalGraphEditorModel

    func makeCoordinator() -> SignalGraphTextCoordinator {
        SignalGraphTextCoordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // A spec is not prose: nothing is to be corrected or prettified.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = SignalGraphTextStyle.font
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.drawsBackground = false
        scrollView.drawsBackground = false
        textView.string = model.text
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        model.port = context.coordinator
        context.coordinator.restyle()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}
#else
extension SignalGraphTextCoordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        textChanged()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        selectionChanged()
    }
}

/// The text of a signal graph, coloured as the outline says.
struct SignalGraphTextView: UIViewRepresentable {
    @ObservedObject var model: SignalGraphEditorModel

    func makeCoordinator() -> SignalGraphTextCoordinator {
        SignalGraphTextCoordinator(model: model)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        // A spec is not prose: nothing is to be corrected or prettified.
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.font = SignalGraphTextStyle.font
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        textView.text = model.text
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        model.port = context.coordinator
        context.coordinator.restyle()
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {}
}
#endif
