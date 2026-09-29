import AppKit
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let togglePin = Self("togglePinCheatsheet", default: .init(.p, modifiers: [.command, .shift]))
    /// Opens the cheatsheet search bar; registered only while the open method
    /// includes search (see updateOpenMethodAvailability).
    static let openSearch = Self("openCheatsheetSearch", default: .init(.space, modifiers: [.command, .shift]))
}

@MainActor
final class HotkeyManager {
    private let store: CheatsheetStore
    private let overlay: OverlayController
    private let launcher: LauncherController
    private var registeredNames: [String: KeyboardShortcuts.Name] = [:]

    init(store: CheatsheetStore, overlay: OverlayController, launcher: LauncherController) {
        self.store = store
        self.overlay = overlay
        self.launcher = launcher
        restoreShortcutsClearedByRemovedMigration()
        KeyboardShortcuts.onKeyDown(for: .togglePin) { @Sendable in
            Task { @MainActor in
                AppModel.shared.overlay.togglePinFrontmost()
            }
        }
        // The pin shortcut starts inert: it's only registered while an
        // overlay is open (see updatePinShortcutAvailability), so ⌘⇧P
        // reaches other apps whenever there's nothing on screen to pin.
        updatePinShortcutAvailability()
        KeyboardShortcuts.onKeyDown(for: .openSearch) { @Sendable in
            Task { @MainActor in
                AppModel.shared.launcher.toggle()
            }
        }
    }

    /// A since-removed build shipped a one-time migration that stripped the
    /// baked-in per-sheet ⌘⇧digit shortcuts (its flag is the only trace).
    /// Installs that ran it get their default digits re-assigned once; the
    /// pin shortcut heals by itself because its default re-persists when the
    /// stored entry is missing.
    private func restoreShortcutsClearedByRemovedMigration() {
        // KeyboardShortcuts stores in UserDefaults.standard even under UI
        // tests, and unit tests run hosted in this app; never mutate the
        // developer's real shortcuts from any kind of test run.
        guard
            !UITestMode.isActive,
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            AppDefaults.store.bool(forKey: "didClearImplicitShortcuts")
        else { return }
        AppDefaults.store.removeObject(forKey: "didClearImplicitShortcuts")
        for sheet in store.sheets where KeyboardShortcuts.getShortcut(for: sheet.shortcutName) == nil {
            guard let digit = CheatsheetStore.firstFreeDigit(taken: store.takenDigits()) else { break }
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(CheatsheetStore.key(forDigit: digit), modifiers: [.command, .shift]),
                for: sheet.shortcutName
            )
        }
    }

    /// The pin shortcut only makes sense with an overlay on screen to act on.
    /// While no overlay session is open, the system-wide registration is
    /// dropped entirely so the key combination passes through to whatever
    /// else on the machine uses it; it re-registers the moment an overlay
    /// opens. Called from the overlay controller on every session change.
    func updatePinShortcutAvailability() {
        if Self.pinShortcutShouldIntercept(openSessionCount: overlay.sessions.count) {
            KeyboardShortcuts.enable(.togglePin)
        } else {
            KeyboardShortcuts.disable(.togglePin)
        }
    }

    /// Pure decision: intercept ⌘⇧P only while at least one overlay is open —
    /// `togglePinFrontmost` always has a selected target then (the key
    /// overlay, else the transient one, else the most recent).
    nonisolated static func pinShortcutShouldIntercept(openSessionCount: Int) -> Bool {
        openSessionCount > 0
    }

    /// Registers handlers for new sheets and removes handlers for deleted ones.
    /// Handlers look the sheet up at fire time so settings edits apply immediately.
    /// Only sheets with a shortcut actually recorded occupy a key combination;
    /// everything else stays with the system.
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
        // Registering a handler or assigning a shortcut (new sheets, imports)
        // registers the key combination; re-apply the open method on top.
        updateOpenMethodAvailability()
    }

    /// Registers only the global shortcuts the open method uses. Unused ones
    /// are unregistered, never cleared, so they come back unchanged when the
    /// method changes. Disables go first: if the search shortcut equals a
    /// sheet's, unregistering the sheet must not undo the search shortcut.
    func updateOpenMethodAvailability() {
        let method = SheetOpenMethod.current
        let sheetNames = store.sheets.map(\.shortcutName)
        if !method.usesSheetShortcuts {
            KeyboardShortcuts.disable(sheetNames)
        }
        if !method.usesSearch {
            KeyboardShortcuts.disable(.openSearch)
            launcher.hide()
        }
        if method.usesSheetShortcuts {
            KeyboardShortcuts.enable(sheetNames)
        }
        if method.usesSearch {
            KeyboardShortcuts.enable(.openSearch)
        }
    }

    func handleKeyDown(sheetID: Cheatsheet.ID) {
        guard
            SheetOpenMethod.current.usesSheetShortcuts,
            let sheet = store.sheets.first(where: { $0.id == sheetID })
        else { return }
        switch sheet.activation {
        case .toggle: overlay.toggle(sheet)
        case .hold: overlay.show(sheet)
        }
    }

    func handleKeyUp(sheetID: Cheatsheet.ID) {
        guard
            SheetOpenMethod.current.usesSheetShortcuts,
            let sheet = store.sheets.first(where: { $0.id == sheetID }),
            sheet.activation == .hold
        else { return }
        overlay.handleHoldKeyUp(sheetID: sheetID)
    }
}
