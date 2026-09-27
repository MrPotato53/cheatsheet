import AppleArchive
import Foundation
import KeyboardShortcuts
import System

/// A portable, self-contained backup of cheatsheets: every per-sheet setting
/// (shortcut included) plus the app's copies of their files, HTML resources
/// too, in one compressed Apple Archive.
///
/// Size and position are already stored as fractions of the screen, so they
/// carry over to any display size unchanged; a specific-display target is
/// re-matched against the displays connected at import.
///
/// Layout:
///   manifest.json
///   sheets/<n>/…   one sheet's media folder, verbatim
nonisolated enum LibraryArchive {
    static let fileExtension = "cheatsheets"
    static let formatVersion = 1
    private static let manifestName = "manifest.json"
    private static let sheetsFolderName = "sheets"

    struct Manifest: Codable {
        var formatVersion: Int
        var exportedAt: Date
        var entries: [Entry]
    }

    struct Entry: Codable {
        /// Folder under sheets/ holding this sheet's files.
        var folder: String
        var sheet: Cheatsheet
        var shortcut: KeyboardShortcuts.Shortcut?
    }

    /// What export needs from the library, captured on the main actor.
    struct ExportItem {
        let sheet: Cheatsheet
        let shortcut: KeyboardShortcuts.Shortcut?
        let mediaFolder: URL
    }

    /// An archive entry unpacked and validated, ready to join the library.
    struct UnpackedSheet {
        let sheet: Cheatsheet
        let shortcut: KeyboardShortcuts.Shortcut?
        let folder: URL
        /// Files the manifest listed but the archive didn't contain.
        let missingFiles: [String]
    }

    struct Unpacked {
        let sheets: [UnpackedSheet]
        /// Entries that couldn't be read (e.g. written by a newer build).
        let skippedEntries: Int
        /// Temp directory holding the extracted files; remove when done.
        let workDirectory: URL
    }

    enum TransferError: LocalizedError, Equatable {
        case notAnArchive
        case newerFormat
        case nothingToImport
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAnArchive:
                "This file isn't a Cheatsheet export, or it's damaged."
            case .newerFormat:
                "This export was made by a newer version of Cheatsheet. Update the app to import it."
            case .nothingToImport:
                "This export doesn't contain any cheatsheets that could be read."
            case .writeFailed(let reason):
                "The export couldn't be saved. \(reason)"
            }
        }
    }

    // MARK: - Export

    static func write(_ items: [ExportItem], to destination: URL, now: Date = Date()) throws {
        let staging = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try stage(items, in: staging, now: now)
            try archive(directory: staging, to: destination)
        } catch {
            // Never leave a truncated archive that looks like a valid backup.
            try? FileManager.default.removeItem(at: destination)
            throw TransferError.writeFailed(error.localizedDescription)
        }
    }

    private static func stage(_ items: [ExportItem], in staging: URL, now: Date) throws {
        let fileManager = FileManager.default
        let sheetsRoot = staging.appendingPathComponent(sheetsFolderName, isDirectory: true)
        try fileManager.createDirectory(at: sheetsRoot, withIntermediateDirectories: true)
        var entries: [Entry] = []
        for (index, item) in items.enumerated() {
            let folder = String(index)
            let target = sheetsRoot.appendingPathComponent(folder, isDirectory: true)
            if fileManager.fileExists(atPath: item.mediaFolder.path) {
                // APFS clones: staging costs no extra disk or copy time.
                try fileManager.copyItem(at: item.mediaFolder, to: target)
            } else {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            }
            entries.append(Entry(folder: folder, sheet: item.sheet, shortcut: item.shortcut))
        }
        let manifest = Manifest(formatVersion: formatVersion, exportedAt: now, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appendingPathComponent(manifestName))
    }

    /// Plain files and folders only: type, path, contents, mode, mtime.
    static let archivedFields = "TYP,PAT,DAT,MOD,MTM"

    /// Internal (not private) so tests can build hand-crafted archives.
    static func archive(directory: URL, to destination: URL, fields: String = archivedFields) throws {
        guard let keys = ArchiveHeader.FieldKeySet(fields) else {
            throw TransferError.writeFailed("Archive keys unavailable.")
        }
        try ArchiveByteStream.withFileStream(
            path: FilePath(destination.path),
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: FilePermissions(rawValue: 0o644)
        ) { file in
            try ArchiveByteStream.withCompressionStream(using: .lzfse, writingTo: file) { compressed in
                try ArchiveStream.withEncodeStream(writingTo: compressed) { encoder in
                    try encoder.writeDirectoryContents(archiveFrom: FilePath(directory.path), keySet: keys)
                }
            }
        }
    }

    // MARK: - Import

    /// Extracts and validates an export. The archive is untrusted input:
    /// only plain files and folders inside the work directory are written,
    /// and every name the manifest refers to must be a single path component.
    static func unpack(_ source: URL) throws -> Unpacked {
        let work = try makeWorkDirectory()
        do {
            try extract(source, into: work)
            let manifest = try readManifest(in: work)
            let sheetsRoot = work.appendingPathComponent(sheetsFolderName, isDirectory: true)
            let sheets = manifest.entries.compactMap(\.entry).compactMap {
                validated($0, sheetsRoot: sheetsRoot)
            }
            guard !sheets.isEmpty else { throw TransferError.nothingToImport }
            return Unpacked(
                sheets: sheets,
                skippedEntries: manifest.entries.count - sheets.count,
                workDirectory: work
            )
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    private static func extract(_ source: URL, into directory: URL) throws {
        let isSafeEntry: ArchiveHeader.EntryFilter = { message, path, data in
            guard message == .extractBegin else { return .ok }
            guard isSafeRelativePath(path.string) else { return .skip }
            if case .header(let header) = data,
               let type = header.entryType,
               type != .regularFile, type != .directory {
                return .skip
            }
            return .ok
        }
        do {
            try ArchiveByteStream.withFileStream(
                path: FilePath(source.path),
                mode: .readOnly,
                options: [],
                permissions: FilePermissions(rawValue: 0o644)
            ) { file in
                try ArchiveByteStream.withDecompressionStream(readingFrom: file) { decompressed in
                    try ArchiveStream.withDecodeStream(readingFrom: decompressed) { decoder in
                        try ArchiveStream.withExtractStream(
                            extractingTo: FilePath(directory.path),
                            selectUsing: isSafeEntry
                        ) { extractor in
                            _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
                        }
                    }
                }
            }
        } catch {
            throw TransferError.notAnArchive
        }
        try rejectSymbolicLinks(in: directory)
    }

    /// Belt and braces behind the extraction filter: a link could point a
    /// later file write outside the library.
    private static func rejectSymbolicLinks(in directory: URL) throws {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw TransferError.notAnArchive
            }
        }
    }

    private static func readManifest(in directory: URL) throws -> LossyManifest {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)) else {
            throw TransferError.notAnArchive
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(LossyManifest.self, from: data) else {
            throw TransferError.notAnArchive
        }
        guard manifest.formatVersion <= formatVersion else { throw TransferError.newerFormat }
        return manifest
    }

    /// Entries decode independently, like the library itself: one unreadable
    /// sheet costs only itself.
    private struct LossyManifest: Decodable {
        let formatVersion: Int
        let entries: [LossyEntry]
    }

    private struct LossyEntry: Decodable {
        let entry: Entry?

        init(from decoder: Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    private static func validated(_ entry: Entry, sheetsRoot: URL) -> UnpackedSheet? {
        guard isSafeFileName(entry.folder) else { return nil }
        let folder = sheetsRoot.appendingPathComponent(entry.folder, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        var sheet = entry.sheet
        let present = sheet.files.filter {
            isSafeFileName($0) && FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        let missing = sheet.files.filter { !present.contains($0) }
        sheet.files = present
        sheet.pageOrder = sheet.pageOrder.filter { present.contains($0.file) }
        sheet.rawFiles = sheet.rawFiles.intersection(present)
        // Imported files are Cheatsheet's own copies; links (never exported
        // by this app) would point at another Mac's files anyway.
        sheet.links = [:]
        sheet.previewScale = Cheatsheet.clampedScale(sheet.previewScale)
        sheet.position = RelativePosition(
            x: min(max(sheet.position.x, 0), 1),
            y: min(max(sheet.position.y, 0), 1)
        )
        let trimmedName = sheet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        sheet.name = trimmedName.isEmpty ? "Imported Cheatsheet" : trimmedName
        return UnpackedSheet(sheet: sheet, shortcut: entry.shortcut, folder: folder, missingFiles: missing)
    }

    // MARK: - Helpers

    /// A display chosen by identity on the exporting Mac: kept when that
    /// display is connected here, else re-matched by name (the same monitor
    /// model), else kept as-is — it then falls back to the cursor's screen
    /// and settings show it as disconnected, exactly like an unplugged one.
    static func matchedTarget(_ target: DisplayTarget, connected: [(uuid: String, name: String)]) -> DisplayTarget {
        guard case .specific(let uuid, let name) = target else { return target }
        if connected.contains(where: { $0.uuid == uuid }) { return target }
        if let sameName = connected.first(where: { $0.name == name }) {
            return .specific(uuid: sameName.uuid, name: sameName.name)
        }
        return target
    }

    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/").contains("..")
    }

    private static func makeWorkDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheatsheetTransfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
