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

    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            rootURL = rootDirectory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            rootURL = base.appendingPathComponent("Cheatsheet", isDirectory: true)
        }
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
        sheets = (try? JSONDecoder().decode([Cheatsheet].self, from: data)) ?? []
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

    // MARK: - Mutations

    @discardableResult
    func addSheet(files urls: [URL], assignDefaultShortcut: Bool = true) -> Cheatsheet? {
        guard !urls.isEmpty else { return nil }
        var sheet = Cheatsheet(name: urls[0].deletingPathExtension().lastPathComponent)
        sheet.files = copyFiles(urls, into: sheet)
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

    func addFiles(_ urls: [URL], to sheetID: Cheatsheet.ID) {
        guard let index = sheets.firstIndex(where: { $0.id == sheetID }) else { return }
        let copied = copyFiles(urls, into: sheets[index])
        guard !copied.isEmpty else { return }
        sheets[index].files.append(contentsOf: copied)
        if !sheets[index].pageOrder.isEmpty {
            sheets[index].pageOrder += expandRefs(files: copied, for: sheets[index])
        }
        persist()
    }

    func removeFile(_ file: String, from sheetID: Cheatsheet.ID) {
        guard let index = sheets.firstIndex(where: { $0.id == sheetID }) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: sheets[index], file: file))
        sheets[index].files.removeAll { $0 == file }
        sheets[index].pageOrder.removeAll { $0.file == file }
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
        persist()
    }

    private func copyFiles(_ urls: [URL], into sheet: Cheatsheet) -> [String] {
        let directory = mediaRoot.appendingPathComponent(sheet.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var names: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            var name = url.lastPathComponent
            var counter = 1
            while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                name = "\(url.deletingPathExtension().lastPathComponent)-\(counter).\(url.pathExtension)"
                counter += 1
            }
            do {
                try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
                names.append(name)
            } catch {
                continue
            }
        }
        return names
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
