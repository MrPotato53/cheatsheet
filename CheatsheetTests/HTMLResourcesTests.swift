import Foundation
import Testing

@testable import Cheatsheet

struct HTMLResourcesTests {
    @Test func collectsTopLevelRootsOfRelativeReferences() {
        let html = """
        <link rel="stylesheet" href="./Vim Cheat Sheet_files/style.css">
        <link rel="icon" href="https://example.com/icon.png">
        <img src='images/a%20b.png'><img src="images/c.png?v=2">
        <script src="app.js#x"></script>
        <a href="#top">top</a><a href="mailto:a@b.c">mail</a>
        <img src="data:image/png;base64,AAAA"><img src="//cdn.example.com/x.png">
        <img src="/abs/x.png"><img src="../outside.png">
        """
        #expect(HTMLResources.referencedRoots(inHTML: html) == ["Vim Cheat Sheet_files", "images", "app.js"])
    }

    @Test func noLocalReferencesYieldsNoRoots() {
        #expect(HTMLResources.referencedRoots(inHTML: "<p>Hello</p>").isEmpty)
    }
}

@MainActor
struct HTMLImportTests {
    private func makeSavedPage(in dir: URL, name: String) throws -> URL {
        let assets = dir.appendingPathComponent("\(name)_files", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try "body { color: red }".write(to: assets.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        let page = dir.appendingPathComponent("\(name).html")
        try "<link rel=\"stylesheet\" href=\"./\(name)_files/style.css\"><p>Hi</p>"
            .write(to: page, atomically: true, encoding: .utf8)
        return page
    }

    @Test func importCopiesReferencedResourcesAndRemovalCleansThemUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        let page = try makeSavedPage(in: source, name: "Page")
        let store = CheatsheetStore(rootDirectory: root)
        let sheet = try #require(store.addSheet(files: [page], assignDefaultShortcut: false))

        let copiedCSS = store.fileURL(for: sheet, file: "Page_files").appendingPathComponent("style.css")
        #expect(FileManager.default.fileExists(atPath: copiedCSS.path))
        #expect(store.sheets.first { $0.id == sheet.id }?.files == ["Page.html"])

        store.removeFile("Page.html", from: sheet.id)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: sheet, file: "Page_files").path))
    }

    @Test func sharedResourcesSurviveWhileAnotherPageStillUsesThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        let page = try makeSavedPage(in: source, name: "Page")
        let twin = source.appendingPathComponent("Twin.html")
        try "<link rel=\"stylesheet\" href=\"Page_files/style.css\">".write(to: twin, atomically: true, encoding: .utf8)
        let store = CheatsheetStore(rootDirectory: root)
        let sheet = try #require(store.addSheet(files: [page, twin], assignDefaultShortcut: false))

        store.removeFile("Page.html", from: sheet.id)
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: sheet, file: "Page_files").path))
    }
}
