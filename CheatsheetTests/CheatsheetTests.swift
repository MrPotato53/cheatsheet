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

    @Test func decodingLibraryWithoutRotationDefaultsToZero() throws {
        let legacyJSON = """
        [{
            "id": "6F1B5DE1-9C2E-4B6E-BB59-3E9E9B8B0001",
            "name": "Old sheet",
            "files": ["page.pdf"],
            "activation": "toggle",
            "previewScale": 0.6,
            "target": {"cursorScreen": {}}
        }]
        """
        let sheets = try JSONDecoder().decode([Cheatsheet].self, from: Data(legacyJSON.utf8))
        #expect(sheets.first?.rotation == .deg0)
        #expect(sheets.first?.name == "Old sheet")
    }

    @Test func customPageOrderReconcilesAgainstFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("order-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        for name in ["a.txt", "b.txt", "c.txt"] {
            try name.write(to: sourceDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let store = CheatsheetStore(rootDirectory: root)
        let sources = ["a.txt", "b.txt", "c.txt"].map { sourceDir.appendingPathComponent($0) }
        guard let sheet = store.addSheet(files: sources, assignDefaultShortcut: false) else {
            Issue.record("addSheet returned nil")
            return
        }

        // Custom order: c before a, plus a stale ref, and b left out entirely.
        store.setPageOrder(
            [
                PageRef(file: "c.txt", pdfPageIndex: nil),
                PageRef(file: "ghost.txt", pdfPageIndex: nil),
                PageRef(file: "a.txt", pdfPageIndex: nil),
            ],
            for: sheet.id
        )

        guard let updated = store.sheets.first(where: { $0.id == sheet.id }) else {
            Issue.record("sheet disappeared")
            return
        }
        let names = store.pages(for: updated).map(\.url.lastPathComponent)
        // Stale ref dropped; unlisted b.txt appended at the end.
        #expect(names == ["c.txt", "a.txt", "b.txt"])

        // Removing a file also purges it from the custom order.
        store.removeFile("c.txt", from: sheet.id)
        let afterRemoval = store.sheets.first { $0.id == sheet.id }
        #expect(afterRemoval?.pageOrder.contains { $0.file == "c.txt" } == false)
    }

    @Test func perPageRotationOverridesSheetDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        for name in ["a.txt", "b.txt"] {
            try name.write(to: sourceDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let store = CheatsheetStore(rootDirectory: root)
        let sources = ["a.txt", "b.txt"].map { sourceDir.appendingPathComponent($0) }
        guard let sheet = store.addSheet(files: sources, assignDefaultShortcut: false) else {
            Issue.record("addSheet returned nil")
            return
        }

        store.setRotation(.deg90, forPageWithKey: PageKey(file: "b.txt", pdfPageIndex: nil), in: sheet.id)
        var updated = store.sheets.first { $0.id == sheet.id }!
        // Rotating materializes the page order and only affects that page.
        #expect(updated.pageOrder.count == 2)
        #expect(store.pages(for: updated).map(\.rotation) == [.deg0, .deg90])

        // Flips toggle independently of rotation.
        let key = PageKey(file: "a.txt", pdfPageIndex: nil)
        store.updatePage(withKey: key, in: sheet.id) { $0.flipHorizontal = true }
        updated = store.sheets.first { $0.id == sheet.id }!
        #expect(store.pages(for: updated).map(\.flipHorizontal) == [true, false])
        #expect(store.pages(for: updated).map(\.rotation) == [.deg0, .deg90])

        // Sheet-wide rotation clears per-page rotation overrides.
        store.setSheetRotation(.deg180, for: sheet.id)
        updated = store.sheets.first { $0.id == sheet.id }!
        #expect(store.pages(for: updated).map(\.rotation) == [.deg180, .deg180])
    }

    @Test func hiddenPagesAreExcludedFromOverlayButRecoverable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidden-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        for name in ["a.txt", "b.txt"] {
            try name.write(to: sourceDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let store = CheatsheetStore(rootDirectory: root)
        let sources = ["a.txt", "b.txt"].map { sourceDir.appendingPathComponent($0) }
        guard let sheet = store.addSheet(files: sources, assignDefaultShortcut: false) else {
            Issue.record("addSheet returned nil")
            return
        }

        store.updatePage(withKey: PageKey(file: "a.txt", pdfPageIndex: nil), in: sheet.id) {
            $0.hidden = true
        }
        let updated = store.sheets.first { $0.id == sheet.id }!
        // The overlay sees only visible pages; settings can still reach both.
        #expect(store.pages(for: updated).map(\.url.lastPathComponent) == ["b.txt"])
        let all = store.pages(for: updated, includeHidden: true)
        #expect(all.count == 2)
        #expect(all.first { $0.url.lastPathComponent == "a.txt" }?.isHidden == true)

        // Unhide restores it.
        store.updatePage(withKey: PageKey(file: "a.txt", pdfPageIndex: nil), in: sheet.id) {
            $0.hidden = nil
        }
        let restored = store.sheets.first { $0.id == sheet.id }!
        #expect(store.pages(for: restored).count == 2)
    }

    @Test func startPageAndPageOrderDecodeWithDefaults() throws {
        let legacyJSON = """
        [{
            "id": "6F1B5DE1-9C2E-4B6E-BB59-3E9E9B8B0002",
            "name": "Old sheet",
            "files": ["page.txt"]
        }]
        """
        let sheets = try JSONDecoder().decode([Cheatsheet].self, from: Data(legacyJSON.utf8))
        #expect(sheets.first?.startPage == .lastViewed)
        #expect(sheets.first?.keepsStartPageLoaded == false)
        #expect(sheets.first?.pageOrder.isEmpty == true)
        #expect(sheets.first?.position == .center)
        #expect(sheets.first?.dragBehavior == .remembers)
        #expect(sheets.first?.resizeBehavior == .remembers)
    }

    @Test func legacyGeometryModesMigrateToBehaviors() throws {
        let legacyJSON = """
        [{
            "id": "6F1B5DE1-9C2E-4B6E-BB59-3E9E9B8B0003",
            "name": "Old sheet",
            "files": [],
            "positionMode": "configured",
            "sizeMode": "lastUsed"
        }]
        """
        let sheets = try JSONDecoder().decode([Cheatsheet].self, from: Data(legacyJSON.utf8))
        #expect(sheets.first?.dragBehavior == .resets)
        #expect(sheets.first?.resizeBehavior == .remembers)
    }

    @Test func clampedCenterKeepsBoxOnScreen() {
        // Box fits: clamp to [half, extent - half].
        #expect(OverlayController.clampedCenter(0.5, extent: 1000, half: 100) == 500)
        #expect(OverlayController.clampedCenter(0.0, extent: 1000, half: 100) == 100)
        #expect(OverlayController.clampedCenter(1.0, extent: 1000, half: 100) == 900)
        // Box as large as the screen: always centered.
        #expect(OverlayController.clampedCenter(0.1, extent: 1000, half: 500) == 500)
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

    // Escape on an open overlay dismisses only when dismissal is enabled and
    // the overlay isn't pinned; the key handler swallows the event either way
    // (so a disabled/pinned overlay no longer beeps).
    @Test func escapeDismissesOnlyWhenEnabledAndUnpinned() {
        #expect(OverlayController.escapeShouldDismiss(dismissEnabled: true, isPinned: false))
        #expect(!OverlayController.escapeShouldDismiss(dismissEnabled: true, isPinned: true))
        #expect(!OverlayController.escapeShouldDismiss(dismissEnabled: false, isPinned: false))
        #expect(!OverlayController.escapeShouldDismiss(dismissEnabled: false, isPinned: true))
    }

    // The open overlay rebuilds its page list (parsing PDFs) only when a
    // page-affecting field changes — not on size/position/name edits, which
    // fire on every size-slider tick.
    @Test func pageInputsDifferOnlyForPageAffectingEdits() {
        var base = Cheatsheet(name: "S")
        base.files = ["a.png", "b.pdf"]

        var scaled = base; scaled.previewScale = 0.9
        var moved = base; moved.position = RelativePosition(x: 0.2, y: 0.8)
        var renamed = base; renamed.name = "T"
        #expect(!OverlayController.pageInputsDiffer(base, base))
        #expect(!OverlayController.pageInputsDiffer(base, scaled))
        #expect(!OverlayController.pageInputsDiffer(base, moved))
        #expect(!OverlayController.pageInputsDiffer(base, renamed))

        var added = base; added.files = ["a.png", "b.pdf", "c.png"]
        var rotated = base; rotated.rotation = .deg90
        var reordered = base; reordered.pageOrder = [PageRef(file: "b.pdf", pdfPageIndex: 0)]
        #expect(OverlayController.pageInputsDiffer(base, added))
        #expect(OverlayController.pageInputsDiffer(base, rotated))
        #expect(OverlayController.pageInputsDiffer(base, reordered))
    }
}
