import AppKit
import SwiftUI

/// Plain-text editor for a page in edit mode. AppKit (like the read-only
/// text page) so it takes focus and scrolls inside the non-activating panel.
/// Code-friendly: no smart quotes/dashes or autocorrect.
struct OverlayTextEditor: NSViewRepresentable {
    let initialText: String
    let onChange: (String) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void

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
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
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
        context.coordinator.onChange = onChange
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
