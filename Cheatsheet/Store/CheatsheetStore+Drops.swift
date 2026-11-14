import Foundation

/// Files handed to the app from outside (Finder's Open With, the Dock icon):
/// only those Cheatsheet can show become pages.
nonisolated enum OpenedFiles {
    static func supported(_ urls: [URL]) -> [URL] {
        urls.filter { $0.isFileURL && MediaKind.of($0) != .unsupported }
    }
}

extension CheatsheetStore {
    /// One new cheatsheet from dropped or opened items: files as pages, links
    /// as web pages, named after the first file (or the first link alone).
    /// Archives aren't pages; callers import them separately.
    @discardableResult
    func addSheet(dropped: DroppedItems, assignDefaultShortcut: Bool = true) -> Cheatsheet? {
        guard !dropped.files.isEmpty else {
            return dropped.webPages.isEmpty
                ? nil
                : addSheet(webPages: dropped.webPages, assignDefaultShortcut: assignDefaultShortcut)
        }
        let sheet = addSheet(files: dropped.files, assignDefaultShortcut: assignDefaultShortcut)
        if let sheet, !dropped.webPages.isEmpty {
            addWebPages(dropped.webPages, to: sheet.id)
        }
        return sheet.flatMap { added in sheets.first { $0.id == added.id } }
    }

    /// Adds dropped files and links to an existing sheet. True if anything
    /// was added.
    @discardableResult
    func add(_ dropped: DroppedItems, to sheetID: Cheatsheet.ID) -> Bool {
        let files = addFiles(dropped.files, to: sheetID)
        let pages = addWebPages(dropped.webPages, to: sheetID)
        return !files.isEmpty || !pages.isEmpty
    }
}
