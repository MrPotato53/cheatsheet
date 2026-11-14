import Foundation

/// Which settings tab is shown, and a pending request to select a sheet
/// (from an overlay's "Open in Settings", a file opened from Finder or the
/// Dock, or a drop outside the Cheatsheets list). Lives on AppModel so the
/// request survives the settings content being rebuilt when the window opens.
@Observable
@MainActor
final class SettingsNavigation {
    enum Tab: Hashable {
        case general
        case cheatsheets
    }

    /// The token makes a repeated request for the same sheet still register
    /// as a change.
    struct SheetRequest: Equatable {
        let sheetID: Cheatsheet.ID
        let token = UUID()
    }

    /// Exports dropped where the Cheatsheets tab can't see them (the
    /// General tab); its import flow picks them up.
    struct ArchiveRequest: Equatable {
        let urls: [URL]
        let token = UUID()
    }

    var tab: Tab = .general
    private(set) var sheetRequest: SheetRequest?
    private(set) var archiveRequest: ArchiveRequest?
    /// Present the New Cheatsheet dialog (search bar, menu bar menu). A
    /// token, so asking again while it's pending still counts as a change.
    private(set) var newSheetFormRequest: UUID?

    func requestNewSheetForm() {
        tab = .cheatsheets
        newSheetFormRequest = UUID()
    }

    /// True once per request.
    func consumeNewSheetFormRequest() -> Bool {
        defer { newSheetFormRequest = nil }
        return newSheetFormRequest != nil
    }

    func requestArchiveImport(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        tab = .cheatsheets
        archiveRequest = ArchiveRequest(urls: urls)
    }

    func consumeArchiveRequest() -> [URL] {
        defer { archiveRequest = nil }
        return archiveRequest?.urls ?? []
    }

    func requestSheet(_ sheetID: Cheatsheet.ID) {
        tab = .cheatsheets
        sheetRequest = SheetRequest(sheetID: sheetID)
    }

    /// The requested sheet, once: the request is cleared.
    func consumeSheetRequest() -> Cheatsheet.ID? {
        defer { sheetRequest = nil }
        return sheetRequest?.sheetID
    }
}
