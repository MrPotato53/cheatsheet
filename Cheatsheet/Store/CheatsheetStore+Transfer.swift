import AppKit
import Foundation
import KeyboardShortcuts

/// What an import did, for the note shown afterwards.
struct ImportSummary: Equatable {
    var importedIDs: [Cheatsheet.ID] = []
    /// Sheets whose exported shortcut was already in use here.
    var reassignedShortcuts: [String] = []
    /// Files the export listed but didn't contain.
    var missingFileCount = 0
    /// Entries that couldn't be read or added.
    var skippedEntries = 0

    /// Anything the user should know beyond "it worked"; empty when the
    /// import was complete and unsurprising.
    var notes: [String] {
        var notes: [String] = []
        if !reassignedShortcuts.isEmpty {
            let names = reassignedShortcuts.map { "“\($0)”" }.joined(separator: ", ")
            notes.append("Shortcuts already in use were replaced for \(names).")
        }
        if missingFileCount > 0 {
            notes.append("\(missingFileCount) file\(missingFileCount == 1 ? " was" : "s were") missing from the export.")
        }
        if skippedEntries > 0 {
            let noun = skippedEntries == 1 ? "cheatsheet was" : "cheatsheets were"
            notes.append("\(skippedEntries) \(noun) unreadable and skipped.")
        }
        return notes
    }
}

extension CheatsheetStore {
    /// Sheets in library order, whatever order the IDs are given in.
    func exportItems(for ids: Set<Cheatsheet.ID>) -> [LibraryArchive.ExportItem] {
        sheets.filter { ids.contains($0.id) }.map { sheet in
            // Links point at this Mac's files (and reveal its folder
            // paths): an export is self-contained copies only.
            var portable = sheet
            portable.links = [:]
            return LibraryArchive.ExportItem(
                sheet: portable,
                shortcut: KeyboardShortcuts.getShortcut(for: sheet.shortcutName),
                mediaFolder: mediaRoot.appendingPathComponent(sheet.id.uuidString, isDirectory: true)
            )
        }
    }

    /// Archiving runs off the main actor: large PDFs take a moment to compress.
    func export(sheetIDs ids: Set<Cheatsheet.ID>, to destination: URL) async throws {
        let items = exportItems(for: ids)
        try await Task.detached(priority: .userInitiated) {
            try LibraryArchive.write(items, to: destination)
        }.value
    }

    func importArchive(at source: URL) async throws -> ImportSummary {
        let unpacked = try await Task.detached(priority: .userInitiated) {
            try LibraryArchive.unpack(source)
        }.value
        defer { try? FileManager.default.removeItem(at: unpacked.workDirectory) }
        return adoptImported(unpacked, connectedScreens: NSScreen.connectedDisplays)
    }
}

extension NSScreen {
    static var connectedDisplays: [(uuid: String, name: String)] {
        screens.compactMap { screen in
            screen.displayUUID.map { ($0, screen.localizedName) }
        }
    }
}
