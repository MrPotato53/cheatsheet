import AppKit
import SwiftUI

/// The Display setting as a standard pop-up button, so it looks like every
/// other dropdown. While its menu is open, the display under the highlighted
/// option is outlined on screen: AppKit's menu delegate reports highlights,
/// which SwiftUI's Picker can't.
struct DisplayPopUpButton: NSViewRepresentable {
    struct Option: Equatable {
        let id: String
        let title: String
        /// The screen outlined while this option is highlighted.
        var highlightUUID: String?
        /// Drawn after a separator (the specific displays).
        var startsGroup = false
    }

    let options: [Option]
    let selectedID: String
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.menu?.delegate = context.coordinator
        button.setAccessibilityIdentifier("detail.display")
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        if context.coordinator.options != options {
            context.coordinator.options = options
            rebuildMenu(of: button)
        }
        if let item = button.menu?.items.first(where: { ($0.representedObject as? String) == selectedID }),
           button.selectedItem !== item {
            button.select(item)
        }
    }

    private func rebuildMenu(of button: NSPopUpButton) {
        guard let menu = button.menu else { return }
        menu.removeAllItems()
        for option in options {
            if option.startsGroup {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.id
            menu.addItem(item)
        }
    }

    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        ScreenHighlighter.shared.hide()
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var onSelect: (String) -> Void
        var options: [Option] = []

        init(onSelect: @escaping (String) -> Void) {
            self.onSelect = onSelect
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String else { return }
            onSelect(id)
        }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            let id = item?.representedObject as? String
            if let uuid = options.first(where: { $0.id == id })?.highlightUUID {
                ScreenHighlighter.shared.highlight(displayUUID: uuid)
            } else {
                ScreenHighlighter.shared.hide()
            }
        }

        func menuDidClose(_ menu: NSMenu) {
            ScreenHighlighter.shared.hide()
        }
    }
}
