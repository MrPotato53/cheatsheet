import AppKit
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let togglePin = Self("togglePinCheatsheet", default: .init(.p, modifiers: [.command, .shift]))
}

@MainActor
final class HotkeyManager {
    private let store: CheatsheetStore
    private let overlay: OverlayController
    private var registeredNames: [String: KeyboardShortcuts.Name] = [:]

    init(store: CheatsheetStore, overlay: OverlayController) {
        self.store = store
        self.overlay = overlay
        KeyboardShortcuts.onKeyDown(for: .togglePin) { @Sendable in
            Task { @MainActor in
                AppModel.shared.overlay.togglePinFrontmost()
            }
        }
    }

    /// Registers handlers for new sheets and removes handlers for deleted ones.
    /// Handlers look the sheet up at fire time so settings edits apply immediately.
    func sync() {
        let activeNames = Set(store.sheets.map { $0.shortcutName.rawValue })
        for (rawValue, name) in registeredNames where !activeNames.contains(rawValue) {
            KeyboardShortcuts.removeHandler(for: name)
            registeredNames[rawValue] = nil
        }
        for sheet in store.sheets {
            let name = sheet.shortcutName
            guard registeredNames[name.rawValue] == nil else { continue }
            registeredNames[name.rawValue] = name
            let sheetID = sheet.id
            KeyboardShortcuts.onKeyDown(for: name) { @Sendable in
                Task { @MainActor in
                    AppModel.shared.hotkeys.handleKeyDown(sheetID: sheetID)
                }
            }
            KeyboardShortcuts.onKeyUp(for: name) { @Sendable in
                Task { @MainActor in
                    AppModel.shared.hotkeys.handleKeyUp(sheetID: sheetID)
                }
            }
        }
    }

    func handleKeyDown(sheetID: Cheatsheet.ID) {
        guard let sheet = store.sheets.first(where: { $0.id == sheetID }) else { return }
        switch sheet.activation {
        case .toggle: overlay.toggle(sheet)
        case .hold: overlay.show(sheet)
        }
    }

    func handleKeyUp(sheetID: Cheatsheet.ID) {
        guard
            let sheet = store.sheets.first(where: { $0.id == sheetID }),
            sheet.activation == .hold
        else { return }
        overlay.handleHoldKeyUp(sheetID: sheetID)
    }
}
