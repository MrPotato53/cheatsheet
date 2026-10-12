import AppKit
import SwiftUI

/// Plain-text editor for a page in edit mode. AppKit (like the read-only
/// text page) so it takes focus and scrolls inside the non-activating panel.
/// Code-friendly: no smart quotes/dashes or autocorrect.
struct OverlayTextEditor: NSViewRepresentable {
    let initialText: String
    /// Search matches to mark in the text, if a search is active.
    var highlight: SearchHighlight?
    /// Bumped to put the caret back in the editor.
    var focusRequest = 0
    let onChange: (String) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        var appliedHighlight: SearchHighlight?
        var highlightedText: String?
        var appliedFocusRequest = 0

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onChange(textView.string)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.font = .pageText(zoom: context.environment.pageZoom)
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = initialText
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("overlay.editor")
        // Deferred: not in a window until after this returns.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // The text view owns the text while editing; only the callback
        // follows SwiftUI updates.
        let coordinator = context.coordinator
        coordinator.onChange = onChange
        guard let textView = scrollView.documentView as? NSTextView else { return }
        NSFont.applyPageText(zoom: context.environment.pageZoom, to: textView)
        if coordinator.appliedFocusRequest != focusRequest {
            coordinator.appliedFocusRequest = focusRequest
            textView.window?.makeFirstResponder(textView)
        }
        // Typing moves matches: re-mark on new text, but only scroll to the
        // active match when it changes (not on every keystroke).
        let highlightChanged = coordinator.appliedHighlight != highlight
        guard highlightChanged || coordinator.highlightedText != textView.string else { return }
        coordinator.appliedHighlight = highlight
        coordinator.highlightedText = textView.string
        Self.mark(highlight, in: textView, scrollToActive: highlightChanged)
    }

    /// Temporary attributes: drawn only, never part of the text or undo.
    private static func mark(_ highlight: SearchHighlight?, in textView: NSTextView, scrollToActive: Bool) {
        guard let layoutManager = textView.layoutManager else { return }
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        guard let highlight else { return }
        let ranges = PageSearch.ranges(of: highlight.query, in: textView.string)
        for (index, range) in ranges.enumerated() {
            layoutManager.addTemporaryAttributes([
                .backgroundColor: index == highlight.activeIndex ? SearchHighlightColors.active : SearchHighlightColors.match,
                .foregroundColor: NSColor.black,
            ], forCharacterRange: range)
        }
        if scrollToActive, let active = highlight.activeIndex, ranges.indices.contains(active) {
            textView.scrollRangeToVisible(ranges[active])
        }
    }
}

/// Standard editing shortcuts for text in the overlay. The app is never
/// active while an overlay is key (non-activating panel), so its menu bar's
/// Edit items can't handle ⌘C/⌘V/⌘Z; the panel sends the actions itself.
nonisolated enum EditingShortcut {
    static func action(forKey key: String, modifiers: NSEvent.ModifierFlags) -> Selector? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        switch (key.lowercased(), flags) {
        case ("x", .command): return #selector(NSText.cut(_:))
        case ("c", .command): return #selector(NSText.copy(_:))
        case ("v", .command): return #selector(NSText.paste(_:))
        case ("a", .command): return #selector(NSText.selectAll(_:))
        case ("z", .command): return Selector(("undo:"))
        case ("z", [.command, .shift]): return Selector(("redo:"))
        default: return nil
        }
    }
}
