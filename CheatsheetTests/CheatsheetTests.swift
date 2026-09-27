import AppKit
import Foundation
import KeyboardShortcuts
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

    /// The pin shortcut ships with a ⌘⇧P default, but it must never reach the
    /// system while there's no overlay to act on: with zero open sessions the
    /// registration is dropped and other apps' ⌘⇧P works normally.
    @Test func pinShortcutHasDefaultButOnlyInterceptsWithAnOpenOverlay() {
        #expect(KeyboardShortcuts.Name.togglePin.defaultShortcut == .init(.p, modifiers: [.command, .shift]))
        #expect(!HotkeyManager.pinShortcutShouldIntercept(openSessionCount: 0))
        #expect(HotkeyManager.pinShortcutShouldIntercept(openSessionCount: 1))
        #expect(HotkeyManager.pinShortcutShouldIntercept(openSessionCount: 3))
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

        var raw = base; raw.rawFiles = ["a.md"]
        #expect(OverlayController.pageInputsDiffer(base, raw))
    }

    @Test func rawModeIsPerFilePersistedAndReflectedInPages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        for name in ["a.md", "b.html"] {
            try name.write(to: sourceDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let store = CheatsheetStore(rootDirectory: root)
        let sources = ["a.md", "b.html"].map { sourceDir.appendingPathComponent($0) }
        let sheet = try #require(store.addSheet(files: sources, assignDefaultShortcut: false))
        #expect(store.pages(for: sheet).allSatisfy { !$0.showsRaw })

        store.setShowsRaw(true, forFile: "a.md", in: sheet.id)
        let reloaded = CheatsheetStore(rootDirectory: root)
        let persisted = try #require(reloaded.sheets.first { $0.id == sheet.id })
        #expect(persisted.rawFiles == ["a.md"])
        let pages = reloaded.pages(for: persisted)
        #expect(pages.first { $0.url.lastPathComponent == "a.md" }?.showsRaw == true)
        #expect(pages.first { $0.url.lastPathComponent == "b.html" }?.showsRaw == false)

        store.setShowsRaw(false, forFile: "a.md", in: sheet.id)
        #expect(store.sheets.first { $0.id == sheet.id }?.rawFiles.isEmpty == true)

        store.setShowsRaw(true, forFile: "b.html", in: sheet.id)
        store.removeFile("b.html", from: sheet.id)
        #expect(store.sheets.first { $0.id == sheet.id }?.rawFiles.isEmpty == true)
    }

    @Test func rawFilesDecodeWithDefault() throws {
        let json = #"[{"id": "6F1B5DE1-9C2E-4B6E-BB59-3E9E9B8B0003", "name": "Old"}]"#
        let sheets = try JSONDecoder().decode([Cheatsheet].self, from: Data(json.utf8))
        #expect(sheets.first?.rawFiles.isEmpty == true)
    }
}

@MainActor
struct LibraryResilienceTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func backups(in root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library.backup-") }
    }

    // One unreadable entry (here: an activation mode this build doesn't
    // know, as a newer build might write) must not take the others with it.
    @Test func unreadableEntryIsSkippedAndOthersLoad() throws {
        let json = """
        [
          {"id": "6F1B5DE1-9C2E-4B6E-BB59-3E9E9B8B0010", "name": "Good"},
          {"id": "6F1B5DE1-9C2E-4B6E-BB59-3E9E9B8B0011", "name": "Future", "activation": "doubleTap"}
        ]
        """
        let decoded = CheatsheetStore.decodeLibrary(Data(json.utf8))
        #expect(decoded.sheets.map(\.name) == ["Good"])
        #expect(decoded.isLossy)
        #expect(!CheatsheetStore.decodeLibrary(Data("[]".utf8)).isLossy)
    }

    // Before the fix, a corrupt library decoded as empty and the next save
    // overwrote it — every sheet gone. The original must survive.
    @Test func corruptLibraryIsBackedUpBeforeBeingOverwritten() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("{ not json".utf8)
        try original.write(to: root.appendingPathComponent("library.json"))

        let store = CheatsheetStore(rootDirectory: root)
        #expect(store.sheets.isEmpty)
        let backup = try #require(try backups(in: root).first)
        #expect(try Data(contentsOf: backup) == original)

        // A later save replaces library.json but leaves the backup alone.
        store.moveSheets(fromOffsets: [], toOffset: 0)
        #expect(try Data(contentsOf: root.appendingPathComponent("library.json")) != original)
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func readableLibraryMakesNoBackup() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = #"[{"id": "6F1B5DE1-9C2E-4B6E-BB59-3E9E9B8B0012", "name": "Fine"}]"#
        try Data(json.utf8).write(to: root.appendingPathComponent("library.json"))

        let store = CheatsheetStore(rootDirectory: root)
        #expect(store.sheets.map(\.name) == ["Fine"])
        #expect(try backups(in: root).isEmpty)
    }

    @Test func duplicateNamesWithoutExtensionGetNoTrailingDot() {
        #expect(CheatsheetStore.uniquedName(for: URL(filePath: "/tmp/notes"), counter: 1) == "notes-1")
        #expect(CheatsheetStore.uniquedName(for: URL(filePath: "/tmp/page.pdf"), counter: 2) == "page-2.pdf")
    }

    // Drag-resizes used to clamp at 20% while the slider starts at 25%,
    // leaving a stored size the slider couldn't show.
    @Test func scaleClampMatchesTheSliderRange() {
        #expect(Cheatsheet.clampedScale(0.1) == Cheatsheet.previewScaleRange.lowerBound)
        #expect(Cheatsheet.clampedScale(0.2) == 0.25)
        #expect(Cheatsheet.clampedScale(0.6) == 0.6)
        #expect(Cheatsheet.clampedScale(1.4) == 1.0)
    }

    // Warmed start pages must be rebuilt (and not reused) when the sheet's
    // rotation or raw/formatted choice changes, or a file is edited in place
    // — all of these change the pages.
    @Test func warmedPagesGoStaleOnRotationRawAndFileEdits() {
        var sheet = Cheatsheet(name: "S")
        sheet.files = ["a.md"]
        func inputs(_ sheet: Cheatsheet, versions: [String] = ["a.md@1"]) -> OverlayController.WarmInputs {
            OverlayController.WarmInputs(sheet: sheet, lastViewedIndex: 0, fileVersions: versions)
        }
        let warmed = inputs(sheet)
        #expect(warmed.hasSamePages(as: inputs(sheet)))

        var raw = sheet; raw.rawFiles = ["a.md"]
        var rotated = sheet; rotated.rotation = .deg90
        var resized = sheet; resized.previewScale = 0.9
        #expect(!warmed.hasSamePages(as: inputs(raw)))
        #expect(!warmed.hasSamePages(as: inputs(rotated)))
        #expect(!warmed.hasSamePages(as: inputs(sheet, versions: ["a.md@2"])))
        #expect(warmed.hasSamePages(as: inputs(resized)))
        #expect(warmed != inputs(raw))
        #expect(warmed != inputs(rotated))
    }
}
