import Foundation

extension CheatsheetStore {
    /// A new cheatsheet of web pages, named after the first. The pages are
    /// Cheatsheet's own `.webloc` files, so there's no original to follow.
    @discardableResult
    func addSheet(webPages entries: [WebLocation.Entry], assignDefaultShortcut: Bool = true) -> Cheatsheet? {
        guard let first = entries.first else { return nil }
        let added = WebLocation.withTemporaryFiles(for: entries) { files in
            addSheet(files: files, assignDefaultShortcut: assignDefaultShortcut, linksOriginals: false)
        }
        guard var sheet = added.flatMap({ $0 }) else { return nil }
        // The file name had characters like "/" replaced; the sheet keeps
        // the name as typed.
        sheet.name = first.name
        update(sheet)
        return sheet
    }

    @discardableResult
    func addWebPages(_ entries: [WebLocation.Entry], to sheetID: Cheatsheet.ID) -> [String] {
        WebLocation.withTemporaryFiles(for: entries) { files in
            addFiles(files, to: sheetID, linksOriginals: false)
        } ?? []
    }
}
