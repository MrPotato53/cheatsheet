import Foundation
import Testing

@testable import Cheatsheet

@MainActor
struct CheatsheetStoreTests {
    @Test func firstFreeDigitFollowsKeyboardOrder() {
        #expect(CheatsheetStore.firstFreeDigit(taken: []) == 1)
        #expect(CheatsheetStore.firstFreeDigit(taken: [1, 2]) == 3)
        #expect(CheatsheetStore.firstFreeDigit(taken: [1, 3]) == 2)
        #expect(CheatsheetStore.firstFreeDigit(taken: [1, 2, 3, 4, 5, 6, 7, 8, 9]) == 0)
        #expect(CheatsheetStore.firstFreeDigit(taken: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]) == nil)
    }

    @Test func persistenceRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-\(UUID().uuidString).txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        let store = CheatsheetStore(rootDirectory: root)
        let sheet = store.addSheet(files: [source], assignDefaultShortcut: false)
        #expect(sheet != nil)
        #expect(sheet?.files.count == 1)

        let reloaded = CheatsheetStore(rootDirectory: root)
        #expect(reloaded.sheets == store.sheets)
        if let reloadedSheet = reloaded.sheets.first, let file = reloadedSheet.files.first {
            let copied = reloaded.fileURL(for: reloadedSheet, file: file)
            #expect(FileManager.default.fileExists(atPath: copied.path))
            #expect(try String(contentsOf: copied, encoding: .utf8) == "hello")
        }
    }

    @Test func duplicateFileNamesAreUniqued() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("dupe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let file = source.appendingPathComponent("page.txt")
        try "one".write(to: file, atomically: true, encoding: .utf8)

        let store = CheatsheetStore(rootDirectory: root)
        guard let sheet = store.addSheet(files: [file], assignDefaultShortcut: false) else {
            Issue.record("addSheet returned nil")
            return
        }
        store.addFiles([file], to: sheet.id)

        let updated = store.sheets.first { $0.id == sheet.id }
        #expect(updated?.files.count == 2)
        #expect(Set(updated?.files ?? []).count == 2)
    }

    @Test func displayTargetCodableRoundTrip() throws {
        let targets: [DisplayTarget] = [
            .cursorScreen,
            .focusedScreen,
            .specific(uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230", name: "Studio Display"),
        ]
        let data = try JSONEncoder().encode(targets)
        let decoded = try JSONDecoder().decode([DisplayTarget].self, from: data)
        #expect(decoded == targets)
    }
}
