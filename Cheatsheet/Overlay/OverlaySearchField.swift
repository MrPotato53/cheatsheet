import AppKit
import SwiftUI

/// Plain AppKit text field: SwiftUI's @FocusState doesn't take focus inside
/// the borderless non-activating overlay panel, so focus is driven directly
/// with makeFirstResponder. Return/Escape never reach it — the panel's key
/// handler turns them into next-match/close first.
struct OverlaySearchField: NSViewRepresentable {
    let text: String
    /// Each new value (re)focuses the field.
    let focusRequest: Int
    let onChange: (String) -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onChange: (String) -> Void
        var appliedFocusRequest: Int?

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Search"
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("overlay.search.field")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onChange = onChange
        if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
        }
        guard context.coordinator.appliedFocusRequest != focusRequest else { return }
        context.coordinator.appliedFocusRequest = focusRequest
        // Deferred: on first appearance the field isn't in a window yet.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
    }
}
