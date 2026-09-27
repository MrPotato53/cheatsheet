import AppKit
import Foundation
import KeyboardShortcuts
import SwiftUI

@Observable
@MainActor
final class CheatsheetStore {
    private(set) var sheets: [Cheatsheet] = []
    /// Bumped on any change, including shortcut edits that live in KeyboardShortcuts'
    /// own storage, so views showing shortcut labels re-render.
    private(set) var revision = 0
    var onChange: (@MainActor () -> Void)?

    let rootURL: URL
    /// App settings (sync with originals); injectable so tests control it.
    let defaults: UserDefaults
    /// Each linked file's relationship to its original, from the latest
    /// check. Missing entries haven't been checked yet this launch.
    var syncStates: [Cheatsheet.ID: [String: FileSyncState]] = [:]
    /// "Keep cheatsheets in sync with original files". Held here (not read
    /// from defaults on demand) so views showing file status observe it.
    private(set) var syncsWithOriginals: Bool

    init(rootDirectory: URL? = nil, defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        syncsWithOriginals = defaults.bool(forKey: Self.syncDefaultsKey)
        if let rootDirectory {
            rootURL = rootDirectory
        } else if let testRoot = UITestMode.storeRoot {
            // UI test runs get a clean, run-scoped library so they never touch
            // (or depend on) the developer's real cheatsheets.
            rootURL = testRoot
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            rootURL = base.appendingPathComponent("Cheatsheet", isDirectory: true)
        }
        #if DEBUG
        if rootDirectory == nil, UITestMode.isActive {
            UITestSeeder.seed(
                rootURL: rootURL,
                mediaRoot: rootURL.appendingPathComponent("Media", isDirectory: true),
                libraryURL: rootURL.appendingPathComponent("library.json")
            )
        }
        #endif
        try? FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        load()
    }

    var mediaRoot: URL { rootURL.appendingPathComponent("Media", isDirectory: true) }
    private var libraryURL: URL { rootURL.appendingPathComponent("library.json") }

    func fileURL(for sheet: Cheatsheet, file: String) -> URL {
        mediaRoot
            .appendingPathComponent(sheet.id.uuidString, isDirectory: true)
            .appendingPathComponent(file)
    }

    func touch() {
        revision += 1
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: libraryURL) else { return }
        let decoded = Self.decodeLibrary(data)
        sheets = decoded.sheets
        // The next persist rewrites the library from what loaded; keep the
        // original so entries that couldn't be read (corruption, or a library
        // written by a newer build) aren't silently lost.
        if decoded.isLossy {
            backUpLibrary()
        }
    }

    /// Decodes each sheet independently, so one unreadable entry costs only
    /// itself rather than the whole library.
    nonisolated static func decodeLibrary(_ data: Data) -> (sheets: [Cheatsheet], isLossy: Bool) {
        guard let entries = try? JSONDecoder().decode([LossySheet].self, from: data) else {
            return ([], true)
        }
        let sheets = entries.compactMap(\.sheet)
        return (sheets, sheets.count != entries.count)
    }

    private nonisolated struct LossySheet: Decodable {
        let sheet: Cheatsheet?

        init(from decoder: Decoder) throws {
            sheet = try? Cheatsheet(from: decoder)
        }
    }

    private func backUpLibrary() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = rootURL.appendingPathComponent("library.backup-\(formatter.string(from: Date())).json")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: libraryURL, to: backup)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(sheets) {
            try? data.write(to: libraryURL, options: .atomic)
        }
        revision += 1
        onChange?()
    }

    /// Turning sync on checks every link right away, so file status in
    /// settings is current by the time the user looks; off clears it.
    func setSyncsWithOriginals(_ isOn: Bool) async {
        guard isOn != syncsWithOriginals else { return }
        syncsWithOriginals = isOn
        defaults.set(isOn, forKey: Self.syncDefaultsKey)
        syncStates = [:]
        touch()
        if isOn {
            await checkAllLinks()
        }
    }

    // MARK: - Mutations

    @discardableResult
    func addSheet(files urls: [URL], assignDefaultShortcut: Bool = true) -> Cheatsheet? {
        guard !urls.isEmpty else { return nil }
        var sheet = Cheatsheet(name: urls[0].deletingPathExtension().lastPathComponent)
        let copied = copyFiles(urls, into: sheet)
        sheet.files = copied.map(\.name)
        sheet.links = Self.links(of: copied)
        guard !sheet.files.isEmpty else { return nil }
        sheets.append(sheet)
        if assignDefaultShortcut, let digit = Self.firstFreeDigit(taken: takenDigits()) {
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(Self.key(forDigit: digit), modifiers: [.command, .shift]),
                for: sheet.shortcutName
            )
        }
        persist()
        return sheet
    }

    /// `linksOriginals` false for files that are Cheatsheet's own (e.g. the
    /// kept version from resolving a sync conflict), not a user's original.
    @discardableResult
    func addFiles(_ urls: [URL], to sheetID: Cheatsheet.ID, linksOriginals: Bool = true) -> [String] {
        guard let index = sheets.firstIndex(where: { $0.id == sheetID }) else { return [] }
        let copied = copyFiles(urls, into: sheets[index], linksOriginals: linksOriginals)
        guard !copied.isEmpty else { return [] }
        let names = copied.map(\.name)
        sheets[index].files.append(contentsOf: names)
        sheets[index].links.merge(Self.links(of: copied)) { _, new in new }
        if !sheets[index].pageOrder.isEmpty {
            sheets[index].pageOrder += Self.expandRefs(files: names, for: sheets[index], mediaRoot: mediaRoot)
        }
        persist()
        return names
    }

    private static func links(of copied: [CopiedFile]) -> [String: FileLink] {
        Dictionary(uniqueKeysWithValues: copied.compactMap { file in file.link.map { (file.name, $0) } })
    }

    func removeFile(_ file: String, from sheetID: Cheatsheet.ID) {
        guard let index = sheets.firstIndex(where: { $0.id == sheetID }) else { return }
        let removedURL = fileURL(for: sheets[index], file: file)
        let removedRoots = MediaKind.of(removedURL) == .html ? HTMLResources.referencedRoots(ofFileAt: removedURL) : []
        try? FileManager.default.removeItem(at: removedURL)
        sheets[index].files.removeAll { $0 == file }
        removeOrphanedResources(removedRoots, in: sheets[index])
        sheets[index].pageOrder.removeAll { $0.file == file }
        sheets[index].rawFiles.remove(file)
        sheets[index].links[file] = nil
        syncStates[sheetID]?[file] = nil
        persist()
    }

    func setShowsRaw(_ showsRaw: Bool, forFile file: String, in sheetID: Cheatsheet.ID) {
        guard let index = sheets.firstIndex(where: { $0.id == sheetID }) else { return }
        guard sheets[index].rawFiles.contains(file) != showsRaw else { return }
        if showsRaw {
            sheets[index].rawFiles.insert(file)
        } else {
            sheets[index].rawFiles.remove(file)
        }
        persist()
    }

    func setPageOrder(_ order: [PageRef], for sheetID: Cheatsheet.ID) {
        guard let index = sheets.firstIndex(where: { $0.id == sheetID }) else { return }
        guard sheets[index].pageOrder != order else { return }
        sheets[index].pageOrder = order
        persist()
    }

    /// Materializes the page order (if still derived) and edits one page's ref.
    func updatePage(withKey key: PageKey, in sheetID: Cheatsheet.ID, mutate: (inout PageRef) -> Void) {
        updatePages(withKeys: [key], in: sheetID, mutate: mutate)
    }

    /// Batch variant: applies the mutation to every matching page in a single
    /// persist, so multi-selection edits don't write the library repeatedly.
    func updatePages(withKeys keys: Set<PageKey>, in sheetID: Cheatsheet.ID, mutate: (inout PageRef) -> Void) {
        guard !keys.isEmpty, let index = sheets.firstIndex(where: { $0.id == sheetID }) else { return }
        var refs = orderedRefs(for: sheets[index])
        var changed = false
        for refIndex in refs.indices where keys.contains(refs[refIndex].key) {
            mutate(&refs[refIndex])
            changed = true
        }
        guard changed else { return }
        sheets[index].pageOrder = refs
        persist()
    }

    func setRotation(_ rotation: Rotation, forPageWithKey key: PageKey, in sheetID: Cheatsheet.ID) {
        updatePage(withKey: key, in: sheetID) { $0.rotation = rotation }
    }

    func setPosition(_ position: RelativePosition, for sheetID: Cheatsheet.ID) {
        applyGeometry(scale: nil, position: position, for: sheetID)
    }

    /// Commits runtime drags/resizes of the overlay in a single persist.
    func applyGeometry(scale: Double?, position: RelativePosition?, for sheetID: Cheatsheet.ID) {
        guard let index = sheets.firstIndex(where: { $0.id == sheetID }) else { return }
        var changed = false
        if let scale, sheets[index].previewScale != scale {
            sheets[index].previewScale = scale
            changed = true
        }
        if let position, sheets[index].position != position {
            sheets[index].position = position
            changed = true
        }
        if changed {
            persist()
        }
    }

    /// Sheet-wide rotation clears per-page overrides so the result is uniform.
    func setSheetRotation(_ rotation: Rotation, for sheetID: Cheatsheet.ID) {
        guard let index = sheets.firstIndex(where: { $0.id == sheetID }) else { return }
        sheets[index].rotation = rotation
        for refIndex in sheets[index].pageOrder.indices {
            sheets[index].pageOrder[refIndex].rotation = nil
        }
        persist()
    }

    func update(_ sheet: Cheatsheet) {
        guard let index = sheets.firstIndex(where: { $0.id == sheet.id }) else { return }
        guard sheets[index] != sheet else { return }
        sheets[index] = sheet
        persist()
    }

    /// Adds unpacked export entries as new sheets (fresh IDs, so importing
    /// the same export twice never collides), moving their files into the
    /// library. One persist for the whole batch.
    func adoptImported(
        _ unpacked: LibraryArchive.Unpacked,
        connectedScreens: [(uuid: String, name: String)]
    ) -> ImportSummary {
        var summary = ImportSummary(skippedEntries: unpacked.skippedEntries)
        for item in unpacked.sheets {
            var sheet = item.sheet
            sheet.id = UUID()
            sheet.target = LibraryArchive.matchedTarget(sheet.target, connected: connectedScreens)
            let destination = mediaRoot.appendingPathComponent(sheet.id.uuidString, isDirectory: true)
            do {
                try FileManager.default.moveItem(at: item.folder, to: destination)
            } catch {
                summary.skippedEntries += 1
                continue
            }
            sheets.append(sheet)
            if !assignImportedShortcut(item.shortcut, to: sheet) {
                summary.reassignedShortcuts.append(sheet.name)
            }
            summary.importedIDs.append(sheet.id)
            summary.missingFileCount += item.missingFiles.count
        }
        if !summary.importedIDs.isEmpty {
            persist()
        }
        return summary
    }

    /// Keeps the exported shortcut when it's free here. A taken one is
    /// replaced by the next free ⌘⇧digit, as for a new sheet. Returns false
    /// when the sheet didn't get the shortcut it was exported with.
    private func assignImportedShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, to sheet: Cheatsheet) -> Bool {
        guard let shortcut else { return true }
        let isTaken = conflictingSheet(with: shortcut, excluding: sheet.id) != nil
            || shortcut == KeyboardShortcuts.getShortcut(for: .togglePin)
        if !isTaken {
            KeyboardShortcuts.setShortcut(shortcut, for: sheet.shortcutName)
            return true
        }
        if let digit = Self.firstFreeDigit(taken: takenDigits()) {
            KeyboardShortcuts.setShortcut(
                KeyboardShortcuts.Shortcut(Self.key(forDigit: digit), modifiers: [.command, .shift]),
                for: sheet.shortcutName
            )
        }
        return false
    }

    func moveSheets(fromOffsets: IndexSet, toOffset: Int) {
        sheets.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    func delete(_ sheet: Cheatsheet) {
        guard let index = sheets.firstIndex(where: { $0.id == sheet.id }) else { return }
        KeyboardShortcuts.reset([sheet.shortcutName])
        try? FileManager.default.removeItem(
            at: mediaRoot.appendingPathComponent(sheet.id.uuidString, isDirectory: true)
        )
        sheets.remove(at: index)
        syncStates[sheet.id] = nil
        persist()
    }

    /// Deletes resource roots no remaining HTML page of the sheet references.
    private func removeOrphanedResources(_ roots: [String], in sheet: Cheatsheet) {
        guard !roots.isEmpty else { return }
        let stillUsed = Set(sheet.files.flatMap { file -> [String] in
            let url = fileURL(for: sheet, file: file)
            return MediaKind.of(url) == .html ? HTMLResources.referencedRoots(ofFileAt: url) : []
        })
        for root in roots where !stillUsed.contains(root) && !sheet.files.contains(root) {
            try? FileManager.default.removeItem(at: fileURL(for: sheet, file: root))
        }
    }

    private struct CopiedFile {
        let name: String
        let link: FileLink?
    }

    /// Copies are always made; a link to each original is recorded too, so
    /// turning on sync later can follow files added before it was on.
    private func copyFiles(_ urls: [URL], into sheet: Cheatsheet, linksOriginals: Bool = true) -> [CopiedFile] {
        let directory = mediaRoot.appendingPathComponent(sheet.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var copied: [CopiedFile] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            var name = url.lastPathComponent
            var counter = 1
            while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                name = Self.uniquedName(for: url, counter: counter)
                counter += 1
            }
            do {
                let copy = directory.appendingPathComponent(name)
                try FileManager.default.copyItem(at: url, to: copy)
                let link = linksOriginals ? OriginalFiles.makeLink(original: url, copy: copy) : nil
                copied.append(CopiedFile(name: name, link: link))
                if MediaKind.of(url) == .html {
                    HTMLResources.copyResources(ofPageAt: url, into: directory)
                }
            } catch {
                continue
            }
        }
        return copied
    }

    /// "page-1.pdf" for the second "page.pdf"; extensionless names get no
    /// trailing dot ("notes-1").
    nonisolated static func uniquedName(for url: URL, counter: Int) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
    }

    // MARK: - Shortcuts

    func conflictingSheet(with shortcut: KeyboardShortcuts.Shortcut, excluding sheetID: Cheatsheet.ID) -> Cheatsheet? {
        sheets.first { sheet in
            sheet.id != sheetID && KeyboardShortcuts.getShortcut(for: sheet.shortcutName) == shortcut
        }
    }

    func takenDigits() -> Set<Int> {
        var taken: Set<Int> = []
        for sheet in sheets {
            guard
                let shortcut = KeyboardShortcuts.getShortcut(for: sheet.shortcutName),
                shortcut.modifiers == [.command, .shift],
                let key = shortcut.key,
                let digit = Self.digit(forKey: key)
            else { continue }
            taken.insert(digit)
        }
        return taken
    }

    private static let digitKeys: [(digit: Int, key: KeyboardShortcuts.Key)] = [
        (1, .one), (2, .two), (3, .three), (4, .four), (5, .five),
        (6, .six), (7, .seven), (8, .eight), (9, .nine), (0, .zero),
    ]

    static func key(forDigit digit: Int) -> KeyboardShortcuts.Key {
        digitKeys.first { $0.digit == digit }!.key
    }

    static func digit(forKey key: KeyboardShortcuts.Key) -> Int? {
        digitKeys.first { $0.key == key }?.digit
    }

    /// Digits are assigned in keyboard order: 1 through 9, then 0.
    static func firstFreeDigit(taken: Set<Int>) -> Int? {
        for digit in [1, 2, 3, 4, 5, 6, 7, 8, 9, 0] where !taken.contains(digit) {
            return digit
        }
        return nil
    }
}
