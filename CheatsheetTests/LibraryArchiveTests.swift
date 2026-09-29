import AppKit
import Foundation
import KeyboardShortcuts
import Testing

@testable import Cheatsheet

@MainActor
struct LibraryArchiveTests {
    /// A shortcut nobody's real library uses, so tests never collide with it.
    private let unusualShortcut = KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option, .shift])

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Unpacks as the app does, with an explicit display list.
    private func importArchive(
        _ archive: URL,
        into store: CheatsheetStore,
        screens: [(uuid: String, name: String)] = []
    ) throws -> ImportSummary {
        let unpacked = try LibraryArchive.unpack(archive)
        defer { try? FileManager.default.removeItem(at: unpacked.workDirectory) }
        return store.adoptImported(unpacked, connectedScreens: screens)
    }

    private func cleanUp(_ stores: CheatsheetStore...) {
        for store in stores {
            for sheet in store.sheets {
                store.delete(sheet) // also clears its stored shortcut
            }
            try? FileManager.default.removeItem(at: store.rootURL)
        }
    }

    /// Builds an archive by hand: a manifest plus per-entry folders.
    private func craftArchive(
        formatVersion: Int = LibraryArchive.formatVersion,
        entries: [LibraryArchive.Entry],
        files: [String: String],
        fields: String = LibraryArchive.archivedFields,
        prepare: (URL) throws -> Void = { _ in }
    ) throws -> URL {
        let staging = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        for (path, contents) in files {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try prepare(staging)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifest = LibraryArchive.Manifest(formatVersion: formatVersion, exportedAt: Date(), entries: entries)
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        let archive = try makeDirectory().appendingPathComponent("crafted.cheatsheets")
        try LibraryArchive.archive(directory: staging, to: archive, fields: fields)
        return archive
    }

    // MARK: - Round trip

    @Test func exportThenImportKeepsEveryFileAndSetting() async throws {
        let inputs = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: inputs) }
        let source = CheatsheetStore(rootDirectory: try makeDirectory())
        let destination = CheatsheetStore(rootDirectory: try makeDirectory())
        defer { cleanUp(source, destination) }

        let text = try write("plain notes", named: "notes.txt", in: inputs)
        let markdown = try write("# Title", named: "guide.md", in: inputs)
        var sheet = try #require(source.addSheet(files: [text, markdown], assignDefaultShortcut: false))
        sheet.activation = .hold
        sheet.startPage = .fixed(index: 1)
        sheet.keepsStartPageLoaded = true
        sheet.previewScale = 0.4
        sheet.position = RelativePosition(x: 0.2, y: 0.8)
        sheet.dragBehavior = .locked
        sheet.resizeBehavior = .resets
        sheet.target = .specific(uuid: "EXPORTING-MAC-DISPLAY", name: "Studio Display")
        sheet.rotation = .deg90
        sheet.rawFiles = ["guide.md"]
        sheet.pageOrder = [
            PageRef(file: "guide.md", pdfPageIndex: nil, rotation: .deg180),
            PageRef(file: "notes.txt", pdfPageIndex: nil, flipHorizontal: true, hidden: true),
        ]
        source.update(sheet)
        KeyboardShortcuts.setShortcut(unusualShortcut, for: sheet.shortcutName)
        // Files beyond `files` (an HTML page's resource folder) travel too.
        let resources = source.mediaRoot
            .appendingPathComponent(sheet.id.uuidString)
            .appendingPathComponent("guide_files", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        _ = try write("body {}", named: "style.css", in: resources)

        let archive = try makeDirectory().appendingPathComponent("one.cheatsheets")
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        try await source.export(sheetIDs: [sheet.id], to: archive)
        // Sole owner of the shortcut on export: free it so the import can take it.
        KeyboardShortcuts.setShortcut(nil, for: sheet.shortcutName)

        let summary = try importArchive(archive, into: destination)

        #expect(summary.notes.isEmpty)
        let imported = try #require(destination.sheets.first)
        #expect(destination.sheets.count == 1)
        #expect(imported.id != sheet.id)
        var expected = sheet
        expected.id = imported.id
        // Links to this Mac's originals never travel.
        #expect(!sheet.links.isEmpty)
        expected.links = [:]
        #expect(imported == expected)
        #expect(KeyboardShortcuts.getShortcut(for: imported.shortcutName) == unusualShortcut)
        #expect(TextFile.read(destination.fileURL(for: imported, file: "notes.txt")) == "plain notes")
        #expect(TextFile.read(destination.fileURL(for: imported, file: "guide.md")) == "# Title")
        let importedCSS = destination.fileURL(for: imported, file: "guide_files/style.css")
        #expect(TextFile.read(importedCSS) == "body {}")
    }

    @Test func exportAllKeepsLibraryOrder() async throws {
        let inputs = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: inputs) }
        let source = CheatsheetStore(rootDirectory: try makeDirectory())
        let destination = CheatsheetStore(rootDirectory: try makeDirectory())
        defer { cleanUp(source, destination) }
        for name in ["alpha", "beta", "gamma"] {
            _ = source.addSheet(files: [try write(name, named: "\(name).txt", in: inputs)], assignDefaultShortcut: false)
        }
        let archive = try makeDirectory().appendingPathComponent("all.cheatsheets")
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        try await source.export(sheetIDs: Set(source.sheets.map(\.id)), to: archive)
        _ = try importArchive(archive, into: destination)

        #expect(destination.sheets.map(\.name) == ["alpha", "beta", "gamma"])
    }

    // Importing the same export twice makes two independent sheets.
    @Test func importingTwiceMakesIndependentCopies() async throws {
        let inputs = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: inputs) }
        let store = CheatsheetStore(rootDirectory: try makeDirectory())
        defer { cleanUp(store) }
        let original = try #require(store.addSheet(files: [try write("x", named: "a.txt", in: inputs)], assignDefaultShortcut: false))
        let archive = try makeDirectory().appendingPathComponent("a.cheatsheets")
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        try await store.export(sheetIDs: [original.id], to: archive)

        _ = try importArchive(archive, into: store)
        _ = try importArchive(archive, into: store)

        #expect(Set(store.sheets.map(\.id)).count == 3)
        store.delete(store.sheets[1])
        #expect(TextFile.read(store.fileURL(for: store.sheets[1], file: "a.txt")) == "x")
    }

    // MARK: - Settings that depend on this Mac

    @Test func takenShortcutIsReplacedAndReported() async throws {
        let inputs = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: inputs) }
        let store = CheatsheetStore(rootDirectory: try makeDirectory())
        defer { cleanUp(store) }
        let sheet = try #require(store.addSheet(files: [try write("x", named: "a.txt", in: inputs)], assignDefaultShortcut: false))
        KeyboardShortcuts.setShortcut(unusualShortcut, for: sheet.shortcutName)
        let archive = try makeDirectory().appendingPathComponent("a.cheatsheets")
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        try await store.export(sheetIDs: [sheet.id], to: archive)

        // The original still holds the shortcut here.
        let summary = try importArchive(archive, into: store)

        let imported = try #require(store.sheets.last)
        #expect(summary.reassignedShortcuts == [sheet.name])
        #expect(summary.notes.count == 1)
        let replacement = KeyboardShortcuts.getShortcut(for: imported.shortcutName)
        #expect(replacement != unusualShortcut)
        #expect(replacement?.modifiers == [.command, .shift])
        #expect(KeyboardShortcuts.getShortcut(for: sheet.shortcutName) == unusualShortcut)
    }

    @Test func specificDisplayIsRematchedByNameOrKept() {
        let exported = DisplayTarget.specific(uuid: "OLD-UUID", name: "DELL U2720Q")
        let here = [(uuid: "BUILTIN", name: "Built-in Retina Display"), (uuid: "NEW-UUID", name: "DELL U2720Q")]

        #expect(LibraryArchive.matchedTarget(exported, connected: here) == .specific(uuid: "NEW-UUID", name: "DELL U2720Q"))
        #expect(LibraryArchive.matchedTarget(exported, connected: [(uuid: "OLD-UUID", name: "Renamed")]) == exported)
        // Unknown here: kept, so it shows as disconnected and the overlay
        // uses the cursor's screen until that display is plugged in.
        #expect(LibraryArchive.matchedTarget(exported, connected: [here[0]]) == exported)
        #expect(LibraryArchive.matchedTarget(.cursorScreen, connected: here) == .cursorScreen)
    }

    // MARK: - Untrusted input

    @Test func nonArchiveIsRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bogus = try write("definitely not an archive", named: "bogus.cheatsheets", in: directory)

        #expect(throws: LibraryArchive.TransferError.notAnArchive) {
            try LibraryArchive.unpack(bogus)
        }
    }

    @Test func newerFormatAsksForAnUpdate() throws {
        let archive = try craftArchive(formatVersion: LibraryArchive.formatVersion + 1, entries: [], files: [:])
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        #expect(throws: LibraryArchive.TransferError.newerFormat) {
            try LibraryArchive.unpack(archive)
        }
    }

    @Test func unsafeNamesAndOutOfRangeValuesAreSanitized() throws {
        let store = CheatsheetStore(rootDirectory: try makeDirectory())
        defer { cleanUp(store) }
        var sheet = Cheatsheet(name: "  ")
        sheet.files = ["ok.txt", "../../escape.txt", "absent.txt"]
        sheet.rawFiles = ["../../escape.txt"]
        sheet.previewScale = 7
        sheet.position = RelativePosition(x: -3, y: 4)
        let archive = try craftArchive(
            entries: [
                LibraryArchive.Entry(folder: "0", sheet: sheet, shortcut: nil),
                LibraryArchive.Entry(folder: "../outside", sheet: sheet, shortcut: nil),
            ],
            files: ["sheets/0/ok.txt": "fine"]
        )
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        let summary = try importArchive(archive, into: store)

        let imported = try #require(store.sheets.first)
        #expect(store.sheets.count == 1)
        #expect(summary.skippedEntries == 1)
        #expect(summary.missingFileCount == 2)
        #expect(imported.files == ["ok.txt"])
        #expect(imported.rawFiles.isEmpty)
        #expect(imported.previewScale == Cheatsheet.previewScaleRange.upperBound)
        #expect(imported.position == RelativePosition(x: 0, y: 1))
        #expect(imported.name == "Imported Cheatsheet")
    }

    @Test func symbolicLinksAreNeverExtracted() throws {
        let archive = try craftArchive(
            entries: [LibraryArchive.Entry(folder: "0", sheet: Cheatsheet(name: "x", files: ["link.txt"]), shortcut: nil)],
            files: ["sheets/0/real.txt": "x"],
            fields: "TYP,PAT,LNK,DAT,MOD"
        ) { staging in
            try FileManager.default.createSymbolicLink(
                atPath: staging.appendingPathComponent("sheets/0/link.txt").path,
                withDestinationPath: "/etc/hosts"
            )
        }
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        let unpacked = try LibraryArchive.unpack(archive)
        defer { try? FileManager.default.removeItem(at: unpacked.workDirectory) }

        let entry = try #require(unpacked.sheets.first)
        #expect(entry.sheet.files.isEmpty)
        #expect(entry.missingFiles == ["link.txt"])
    }

    @Test func pathsEscapingTheArchiveAreUnsafe() {
        #expect(LibraryArchive.isSafeRelativePath("sheets/0/a.txt"))
        #expect(!LibraryArchive.isSafeRelativePath("../a.txt"))
        #expect(!LibraryArchive.isSafeRelativePath("sheets/../../a.txt"))
        #expect(!LibraryArchive.isSafeRelativePath("/etc/hosts"))
        #expect(LibraryArchive.isSafeFileName("notes-1.txt"))
        #expect(!LibraryArchive.isSafeFileName(".."))
        #expect(!LibraryArchive.isSafeFileName("a/b"))
        #expect(!LibraryArchive.isSafeFileName(""))
    }

    // Dropping on the cheatsheet list: exports import, files and links
    // make a new cheatsheet, even when dropped together.
    @Test func droppedItemsSortExportsFilesAndLinks() {
        let export = URL(filePath: "/tmp/Backup.CHEATSHEETS")
        let image = URL(filePath: "/tmp/keys.png")
        let link = URL(string: "https://www.example.com/docs")!
        let dropped = DroppedItems([export, image, link, URL(string: "mailto:a@b.c")!])
        #expect(dropped.archives == [export])
        #expect(dropped.files == [image])
        #expect(dropped.webPages == [WebLocation.Entry(url: link, name: "example.com")])
        #expect(DroppedItems([export]).files.isEmpty)
        #expect(DroppedItems([URL(string: "mailto:a@b.c")!]).isEmpty)
    }
}
