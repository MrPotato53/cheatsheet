import Foundation
import Testing

@testable import Cheatsheet

// MARK: - Which sheets an FSEvents batch touches

struct AffectedSheetsTests {
    private let mediaRoot = URL(fileURLWithPath: "/Library/Root/Media", isDirectory: true)
    private let first = UUID()
    private let second = UUID()

    @Test func copiesMapToTheirSheetFolder() {
        let paths = [
            "/Library/Root/Media/\(first.uuidString)/notes.md",
            "/Library/Root/Media/\(second.uuidString)",
        ]
        let affected = FileChangeMonitor.affectedSheets(by: paths, mediaRoot: mediaRoot, originals: [:])
        #expect(affected == [first, second])
    }

    @Test func originalsMapToTheSheetsThatLinkThem() {
        let originals = ["/Users/me/Docs/vim.md": first]
        let affected = FileChangeMonitor.affectedSheets(
            by: ["/Users/me/Docs/vim.md", "/Users/me/Docs/other.md"], mediaRoot: mediaRoot, originals: originals
        )
        #expect(affected == [first])
    }

    @Test func unrelatedPathsAndTheLibraryFileAreIgnored() {
        let paths = ["/Library/Root/library.json", "/Library/Root/Media", "/Library/Root/Media/\(first.uuidString)/.review-x-a.html", "/Library/Root/MediaX/\(first.uuidString)/a.png", "/Library/Root/Media/not-a-uuid/a.png"]
        #expect(FileChangeMonitor.affectedSheets(by: paths, mediaRoot: mediaRoot, originals: [:]).isEmpty)
    }
}

// MARK: - The sheet folder: deletions, drops, dependencies

@MainActor
struct SheetFolderTests {
    private func makeStore() throws -> (CheatsheetStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "watch-test-\(UUID().uuidString)")!
        return (CheatsheetStore(rootDirectory: root.appendingPathComponent("Library"), defaults: defaults), root)
    }

    @discardableResult
    private func write(_ name: String, _ text: String = "text", in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func folder(of sheet: Cheatsheet, in store: CheatsheetStore) -> URL {
        store.mediaRoot.appendingPathComponent(sheet.id.uuidString, isDirectory: true)
    }

    @Test func classifierSkipsPagesDependenciesAndJunk() {
        let entries: [(name: String, isDirectory: Bool)] = [
            ("a.png", false), ("style.css", false), ("new.md", false), (".DS_Store", false),
            ("draft.tmp", false), ("page_files", true), ("~$doc.docx", false), ("b.zip", false),
        ]
        let new = SheetFolder.newItems(entries: entries, pages: ["a.png"], dependencies: ["style.css"])
        #expect(new == ["b.zip", "new.md"])
    }

    @Test func deletedCopyStaysListedWithAPlaceholderPage() async throws {
        let (store, root) = try makeStore()
        let sheet = try #require(store.addSheet(
            files: [try write("one.txt", in: root), try write("two.txt", in: root)], assignDefaultShortcut: false
        ))
        try FileManager.default.removeItem(at: store.fileURL(for: sheet, file: "one.txt"))

        store.discoverNewFiles(in: sheet.id)

        let current = try #require(store.sheets.first { $0.id == sheet.id })
        #expect(current.files == ["one.txt", "two.txt"])
        #expect(store.pages(for: current).map(\.url.lastPathComponent) == ["one.txt", "two.txt"])
    }

    @Test func droppedFilesBecomePagesUnsupportedOnesStayOffThePages() throws {
        let (store, root) = try makeStore()
        let sheet = try #require(store.addSheet(files: [try write("one.txt", in: root)], assignDefaultShortcut: false))
        let directory = folder(of: sheet, in: store)
        try write("notes.md", in: directory)
        try write("archive.zip", in: directory)
        try write(".DS_Store", in: directory)

        let added = store.discoverNewFiles(in: sheet.id)

        #expect(added == ["archive.zip", "notes.md"])
        let current = try #require(store.sheets.first { $0.id == sheet.id })
        // Unlinked media: nothing to follow.
        #expect(current.links["notes.md"] == nil && current.links["archive.zip"] == nil)
        #expect(store.pages(for: current).map(\.url.lastPathComponent) == ["one.txt", "notes.md"])
    }

    @Test func importRecordsWhatAnHTMLPageUses() throws {
        let (store, root) = try makeStore()
        let page = try write("guide.html", #"<link href="style.css"><img src="guide_files/a.png">"#, in: root)
        try write("style.css", "body {}", in: root)
        try write("guide_files/a.png", "png", in: root)

        let sheet = try #require(store.addSheet(files: [page], assignDefaultShortcut: false))

        #expect(sheet.dependencies["guide.html"] == ["style.css", "guide_files"])
        #expect(store.discoverNewFiles(in: sheet.id).isEmpty)
    }

    @Test func aDroppedFileAPageReferencesIsRecordedNotAPage() throws {
        let (store, root) = try makeStore()
        let page = try write("guide.html", #"<link href="theme.css">"#, in: root)
        let sheet = try #require(store.addSheet(files: [page], assignDefaultShortcut: false))
        try write("theme.css", "body {}", in: folder(of: sheet, in: store))

        let added = store.discoverNewFiles(in: sheet.id)

        #expect(added.isEmpty)
        #expect(store.sheets.first { $0.id == sheet.id }?.dependencies["guide.html"] == ["theme.css"])
    }

    @Test func removingAPageDeletesOnlyDependenciesNoOtherPageUses() throws {
        let (store, root) = try makeStore()
        let first = try write("one.html", #"<link href="shared.css"><link href="only-one.css">"#, in: root)
        let second = try write("two.html", #"<link href="shared.css">"#, in: root)
        try write("shared.css", in: root)
        try write("only-one.css", in: root)
        let sheet = try #require(store.addSheet(files: [first, second], assignDefaultShortcut: false))
        let directory = folder(of: sheet, in: store)

        store.removeFile("one.html", from: sheet.id)

        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("shared.css").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("only-one.css").path))
    }

    @Test func olderLibrariesGetDependenciesOnLoad() throws {
        let (store, root) = try makeStore()
        let page = try write("guide.html", #"<link href="style.css">"#, in: root)
        try write("style.css", in: root)
        var sheet = try #require(store.addSheet(files: [page], assignDefaultShortcut: false))
        sheet.dependencies = [:]
        store.update(sheet)

        store.recordMissingDependencies()

        #expect(store.sheets.first { $0.id == sheet.id }?.dependencies["guide.html"] == ["style.css"])
    }

    /// A library written before this version (no "dependencies"), opened by
    /// the current build: as after reinstalling over an older install.
    @Test func libraryFromBeforeDependenciesMigratesOnLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migrate-\(UUID().uuidString)")
        let id = UUID()
        let folder = root.appendingPathComponent("Media/\(id.uuidString)", isDirectory: true)
        try write("guide.html", #"<link href="style.css"><p>Hi</p>"#, in: folder)
        try write("style.css", "body {}", in: folder)
        try write("notes.txt", "text", in: folder)
        let oldLibrary = """
        [{"id": "\(id.uuidString)", "name": "Old", "files": ["guide.html", "notes.txt"],
          "pageOrder": [], "rawFiles": [], "previewScale": 0.6}]
        """
        try oldLibrary.write(to: root.appendingPathComponent("library.json"), atomically: true, encoding: .utf8)
        let defaults = UserDefaults(suiteName: "migrate-\(UUID().uuidString)")!

        let store = CheatsheetStore(rootDirectory: root, defaults: defaults)

        let sheet = try #require(store.sheets.first)
        #expect(sheet.name == "Old")
        #expect(sheet.files == ["guide.html", "notes.txt"])
        #expect(sheet.dependencies == ["guide.html": ["style.css"]])
        // Saved, so the next launch doesn't derive it again.
        let saved = try String(contentsOf: root.appendingPathComponent("library.json"), encoding: .utf8)
        #expect(saved.contains("\"dependencies\""))
        // The stylesheet is the page's, not a file waiting to be imported.
        #expect(store.discoverNewFiles(in: id).isEmpty)
        #expect(store.pages(for: sheet).map(\.url.lastPathComponent) == ["guide.html", "notes.txt"])
    }

    @Test func noteFilesChangedBumpsOnlyThatSheet() throws {
        let (store, root) = try makeStore()
        let a = try #require(store.addSheet(files: [try write("a.txt", in: root)], assignDefaultShortcut: false))
        let b = try #require(store.addSheet(files: [try write("b.txt", in: root)], assignDefaultShortcut: false))

        store.noteFilesChanged(in: a.id)

        #expect(store.fileRevision(for: a.id) == 1)
        #expect(store.fileRevision(for: b.id) == 0)
    }
}

// MARK: - The FSEvents stream itself

@MainActor
struct FileEventStreamTests {
    @Test func reportsAFileWrittenInAWatchedFolder() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsevents-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var reported: [String] = []
        let stream = try #require(FileEventStream(paths: [folder.path], latency: 0.05) { reported += $0 })
        defer { stream.stop() }
        try await Task.sleep(for: .milliseconds(300))

        try "hello".write(to: folder.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)

        let deadline = Date(timeIntervalSinceNow: 5)
        while !reported.contains(where: { $0.hasSuffix("/page.md") }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(reported.contains { $0.hasSuffix("/page.md") })
    }
}
