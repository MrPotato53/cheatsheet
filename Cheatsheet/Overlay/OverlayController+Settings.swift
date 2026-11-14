import AppKit
import KeyboardShortcuts

extension OverlayController {
    /// Opens (or focuses) settings on this sheet. A transient overlay closes
    /// — it floats above every window and would cover settings; a pinned one
    /// stays so edits can be watched as they apply.
    func openInSettings(_ session: OverlaySession) {
        let sheetID = session.sheet.id
        if !session.isPinned {
            hide(session)
        }
        AppModel.shared.openSettings(selecting: sheetID)
    }

    /// A hidden page opened from settings' hidden strip is shown on its own,
    /// for this viewing only (no neighbors to page to); it stays hidden.
    static func pages(_ shown: [SheetPage], revealing page: SheetPage) -> [SheetPage] {
        let isShown = shown.contains { $0.url == page.url && $0.pdfPageIndex == page.pdfPageIndex }
        guard page.isHidden, !isShown else { return shown }
        return [page]
    }

    func pagesRevealing(_ page: SheetPage, in shown: [SheetPage], of sheet: Cheatsheet) -> [SheetPage] {
        Self.pages(shown, revealing: page)
    }

    /// The overlay's Open in Settings key (⌘, by default). Matched locally,
    /// only while the overlay has keyboard focus — it's never a global
    /// hotkey, so ⌘, keeps opening every other app's settings.
    static func isOpenInSettingsKey(_ event: NSEvent, shortcut: KeyboardShortcuts.Shortcut?) -> Bool {
        guard let shortcut, let pressed = KeyboardShortcuts.Shortcut(event: event) else { return false }
        return pressed == shortcut
    }

    func handleOpenInSettingsKeyEvent(_ event: NSEvent, in session: OverlaySession) -> Bool {
        guard Self.isOpenInSettingsKey(event, shortcut: KeyboardShortcuts.getShortcut(for: .openInSettings)) else {
            return false
        }
        openInSettings(session)
        return true
    }
}
