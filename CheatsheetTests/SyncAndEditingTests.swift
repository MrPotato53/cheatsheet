import AppKit
import Foundation
import Testing

@testable import Cheatsheet

/// Sync with originals: the original may refresh Cheatsheet's copy on its
/// own, but the copy never overwrites the original without the user
/// choosing so — except edits made through Cheatsheet while in sync.
@MainActor
struct OriginalSyncTests {
    /// A library with sync on (or off), a scratch folder for "originals",
    /// and one text sheet linked to `todo.md` there.
    @MainActor
    private struct Fixture {
        let store: CheatsheetStore
        let defaults: UserDefaults
        let suiteName: String
        let originals: URL
        let original: URL
        let sheetID: Cheatsheet.ID

        var sheet: Cheatsheet { store.sheets.first { $0.id == sheetID }! }
        var copy: URL { store.fileURL(for: sheet, file: "todo.md") }
        var state: FileSyncState { store.syncState(of: "todo.md", in: sheet) }

        func tearDown() {
            try? FileManager.default.removeItem(at: store.rootURL)
            try? FileManager.default.removeItem(at: originals)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private var clock = Date().addingTimeInterval(60)

    private func makeFixture(syncOn: Bool = true, contents: String = "- [ ] milk") throws -> Fixture {
        let suiteName = "sync-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(syncOn, forKey: CheatsheetStore.syncDefaultsKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-root-\(UUID().uuidString)")
        let originals = FileManager.default.temporaryDirectory.appendingPathComponent("sync-originals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let original = originals.appendingPathComponent("todo.md")
        try contents.write(to: original, atomically: true, encoding: .utf8)
        let store = CheatsheetStore(rootDirectory: root, defaults: defaults)
        let sheet = try #require(store.addSheet(files: [original], assignDefaultShortcut: false))
        return Fixture(store: store, defaults: defaults, suiteName: suiteName, originals: originals, original: original, sheetID: sheet.id)
    }

    /// Writes and moves the modification time forward, as a later save would.
    private mutating func edit(_ url: URL, to text: String) throws {
        try text.write(to: url, atomically: false, encoding: .utf8)
        clock = clock.addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: clock], ofItemAtPath: url.path)
    }

    private func read(_ url: URL) -> String? {
        TextFile.read(url)
    }

    // MARK: - Linking

    @Test func addingAFileLinksItsOriginal() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let link = try #require(fixture.sheet.links["todo.md"])
        #expect(OriginalFiles.resolve(link)?.url.standardizedFileURL.path == fixture.original.standardizedFileURL.path)
        await fixture.store.checkLinks(for: fixture.sheetID)
        #expect(fixture.state == .linked)
    }

    // Stamps are stored as JSON doubles; unrounded nanosecond mtimes would
    // make every file look changed after a relaunch.
    @Test func linksSurviveARelaunchWithoutLookingChanged() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let reloaded = CheatsheetStore(rootDirectory: fixture.store.rootURL, defaults: fixture.defaults)
        #expect(reloaded.sheets.first?.links == fixture.sheet.links)
        let refreshed = await reloaded.checkLinks(for: fixture.sheetID)

        #expect(!refreshed)
        #expect(reloaded.syncState(of: "todo.md", in: reloaded.sheets[0]) == .linked)
    }

    // MARK: - Checking

    @Test mutating func newerOriginalRefreshesTheCopyAutomatically() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try edit(fixture.original, to: "- [ ] milk\n- [ ] eggs")

        let refreshed = await fixture.store.checkLinks(for: fixture.sheetID)

        #expect(refreshed)
        #expect(read(fixture.copy) == "- [ ] milk\n- [ ] eggs")
        #expect(fixture.state == .linked)
    }

    // The user's rule: even when only the copy changed (and so is newer),
    // the original is never overwritten without asking.
    @Test mutating func copyChangesAskEvenWhenTheOriginalIsUnchanged() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try edit(fixture.copy, to: "- [x] milk")

        await fixture.store.checkLinks(for: fixture.sheetID)

        #expect(fixture.state == .needsReview(originalChanged: false))
        #expect(read(fixture.original) == "- [ ] milk")
        #expect(read(fixture.copy) == "- [x] milk")
    }

    @Test mutating func changesOnBothSidesAsk() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try edit(fixture.copy, to: "copy version")
        try edit(fixture.original, to: "original version")

        await fixture.store.checkLinks(for: fixture.sheetID)

        #expect(fixture.state == .needsReview(originalChanged: true))
        #expect(read(fixture.original) == "original version")
        #expect(read(fixture.copy) == "copy version")
    }

    @Test mutating func touchedButIdenticalFilesDontAsk() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try edit(fixture.copy, to: "- [ ] milk")

        await fixture.store.checkLinks(for: fixture.sheetID)

        #expect(fixture.state == .linked)
    }

    // MARK: - Editing

    @Test func editsWhileInSyncGoToTheOriginal() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        await fixture.store.checkLinks(for: fixture.sheetID)

        let outcome = fixture.store.writeContents(Data("- [x] milk".utf8), toFile: "todo.md", in: fixture.sheetID)

        #expect(outcome == .savedToOriginal)
        #expect(read(fixture.original) == "- [x] milk")
        #expect(read(fixture.copy) == "- [x] milk")
        #expect(await !fixture.store.checkLinks(for: fixture.sheetID))
        #expect(fixture.state == .linked)
    }

    // An edit before anything checked the link this launch still goes to
    // the original: the write checks first.
    @Test func firstEditOfALaunchChecksBeforeWriting() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let outcome = fixture.store.writeContents(Data("new".utf8), toFile: "todo.md", in: fixture.sheetID)

        #expect(outcome == .savedToOriginal)
        #expect(read(fixture.original) == "new")
    }

    @Test func withSyncOffEditsStayInTheCopyAndAskOnceSyncIsOn() async throws {
        let fixture = try makeFixture(syncOn: false)
        defer { fixture.tearDown() }

        let outcome = fixture.store.writeContents(Data("- [x] milk".utf8), toFile: "todo.md", in: fixture.sheetID)
        #expect(outcome == .savedToCopy)
        #expect(read(fixture.original) == "- [ ] milk")
        #expect(fixture.state == .copyOnly)

        await fixture.store.setSyncsWithOriginals(true)

        #expect(fixture.state == .needsReview(originalChanged: false))
        #expect(read(fixture.original) == "- [ ] milk")
    }

    @Test func missingOriginalKeepsEditsInTheCopy() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try FileManager.default.removeItem(at: fixture.original)

        await fixture.store.checkLinks(for: fixture.sheetID)
        #expect(fixture.state == .originalMissing)

        let outcome = fixture.store.writeContents(Data("offline edit".utf8), toFile: "todo.md", in: fixture.sheetID)
        #expect(outcome == .keptInCopy(.originalMissing))
        #expect(read(fixture.copy) == "offline edit")
        #expect(!FileManager.default.fileExists(atPath: fixture.original.path))
    }

    @Test func trashedOriginalsCountAsMissing() {
        #expect(OriginalFiles.isTrashed(URL(filePath: "/Users/me/.Trash/todo.md")))
        #expect(OriginalFiles.isTrashed(URL(filePath: "/Volumes/USB/.Trashes/501/todo.md")))
        #expect(!OriginalFiles.isTrashed(URL(filePath: "/Users/me/Notes/todo.md")))
    }

    // MARK: - Review

    @Test mutating func reviewChoicesDoWhatTheySay() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try edit(fixture.copy, to: "cheatsheet edit")
        await fixture.store.checkLinks(for: fixture.sheetID)
        #expect(fixture.store.resolveSync(.useCheatsheetCopy, forFile: "todo.md", in: fixture.sheetID))
        #expect(read(fixture.original) == "cheatsheet edit")
        #expect(fixture.state == .linked)

        try edit(fixture.copy, to: "discard me")
        await fixture.store.checkLinks(for: fixture.sheetID)
        #expect(fixture.store.resolveSync(.useOriginal, forFile: "todo.md", in: fixture.sheetID))
        #expect(read(fixture.copy) == "cheatsheet edit")
        #expect(read(fixture.original) == "cheatsheet edit")
    }

    @Test mutating func keepBothAddsCheatsheetsVersionAsItsOwnFile() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try edit(fixture.copy, to: "mine")
        try edit(fixture.original, to: "theirs")
        await fixture.store.checkLinks(for: fixture.sheetID)

        #expect(fixture.store.resolveSync(.keepBoth, forFile: "todo.md", in: fixture.sheetID))

        let kept = "todo (Cheatsheet version).md"
        #expect(fixture.sheet.files == ["todo.md", kept])
        #expect(read(fixture.store.fileURL(for: fixture.sheet, file: kept)) == "mine")
        #expect(fixture.sheet.links[kept] == nil)
        #expect(read(fixture.copy) == "theirs")
        #expect(read(fixture.original) == "theirs")
    }

    @Test func linkingAnOriginalComparesContentsFirst() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let same = fixture.originals.appendingPathComponent("same.md")
        let different = fixture.originals.appendingPathComponent("different.md")
        try "- [ ] milk".write(to: same, atomically: true, encoding: .utf8)
        try "something else".write(to: different, atomically: true, encoding: .utf8)

        // The copy takes each original's name as it's linked.
        #expect(await fixture.store.linkOriginal(same, toFile: "todo.md", in: fixture.sheetID) == .linked(as: "same.md"))
        #expect(fixture.store.syncState(of: "same.md", in: fixture.sheet) == .linked)

        fixture.store.unlinkOriginal(ofFile: "same.md", in: fixture.sheetID)
        #expect(await fixture.store.linkOriginal(different, toFile: "same.md", in: fixture.sheetID) == .needsReview(as: "different.md"))
        #expect(fixture.store.syncState(of: "different.md", in: fixture.sheet) == .needsReview(originalChanged: true))
        #expect(read(different) == "something else")
        #expect(read(fixture.store.fileURL(for: fixture.sheet, file: "different.md")) == "- [ ] milk")
    }

    // Linking never renames the copy onto another file of the sheet.
    @Test func linkingKeepsTheNameWhenTheOriginalsNameIsTaken() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let other = fixture.originals.appendingPathComponent("notes.md")
        try "- [ ] milk".write(to: other, atomically: true, encoding: .utf8)
        fixture.store.addFiles([other], to: fixture.sheetID, linksOriginals: false)
        fixture.store.unlinkOriginal(ofFile: "todo.md", in: fixture.sheetID)

        #expect(await fixture.store.linkOriginal(other, toFile: "todo.md", in: fixture.sheetID) == .linked(as: "todo.md"))
        #expect(fixture.sheet.files == ["todo.md", "notes.md"])
    }

    // Renaming moves the copy and every reference to it; the original stays.
    @Test func renamingMovesTheCopyAndItsReferences() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.store.setShowsRaw(true, forFile: "todo.md", in: fixture.sheetID)
        fixture.store.setPageOrder([PageRef(file: "todo.md")], for: fixture.sheetID)

        #expect(fixture.store.renameFile("todo.md", to: "Groceries.md", in: fixture.sheetID) == nil)

        let sheet = fixture.sheet
        #expect(sheet.files == ["Groceries.md"])
        #expect(sheet.pageOrder.map(\.file) == ["Groceries.md"])
        #expect(sheet.rawFiles == ["Groceries.md"])
        #expect(sheet.links["Groceries.md"] != nil && sheet.links["todo.md"] == nil)
        #expect(read(fixture.store.fileURL(for: sheet, file: "Groceries.md")) == "- [ ] milk")
        #expect(FileManager.default.fileExists(atPath: fixture.original.path), "the original is never renamed")
        #expect(fixture.store.syncState(of: "Groceries.md", in: sheet) == .linked)
    }

    @Test func renamingOnlyTheCaseWorks() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        #expect(fixture.store.renameFile("todo.md", to: "TODO.md", in: fixture.sheetID) == nil)
        #expect(fixture.sheet.files == ["TODO.md"])
        #expect(read(fixture.store.fileURL(for: fixture.sheet, file: "TODO.md")) == "- [ ] milk")
    }

    @Test func renamingRejectsUnusableNames() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let other = fixture.originals.appendingPathComponent("notes.md")
        try "x".write(to: other, atomically: true, encoding: .utf8)
        fixture.store.addFiles([other], to: fixture.sheetID, linksOriginals: false)

        #expect(fixture.store.renameFile("todo.md", to: "Notes.md", in: fixture.sheetID) == .taken)
        #expect(fixture.store.renameFile("todo.md", to: " .md", in: fixture.sheetID) == .empty)
        #expect(fixture.store.renameFile("todo.md", to: "a/b.md", in: fixture.sheetID) == .invalidCharacters)
        #expect(fixture.store.renameFile("todo.md", to: "todo.pdf", in: fixture.sheetID) == .differentKind)
        #expect(fixture.sheet.files == ["todo.md", "notes.md"])
    }

    // Linking a PDF as the original of a markdown page would leave "Use
    // Original" producing an undisplayable page: refused up front.
    @Test func linkingADifferentKindOfFileIsRefused() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let pdf = fixture.originals.appendingPathComponent("scan.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        let before = fixture.sheet.links["todo.md"]

        let result = await fixture.store.linkOriginal(pdf, toFile: "todo.md", in: fixture.sheetID)

        #expect(result == .differentKind(expected: .markdown, chosen: .pdf))
        #expect(fixture.sheet.links["todo.md"] == before)
    }

    // Settings reads the setting from the store; flipping it must update
    // file status immediately (it used to wait for an unrelated redraw).
    @Test func togglingSyncUpdatesStatusRightAway() async throws {
        let fixture = try makeFixture(syncOn: false)
        defer { fixture.tearDown() }
        #expect(fixture.state == .copyOnly)

        await fixture.store.setSyncsWithOriginals(true)
        #expect(fixture.store.syncsWithOriginals)
        #expect(fixture.store.syncStates[fixture.sheetID]?["todo.md"] == .linked)
        #expect(fixture.defaults.bool(forKey: CheatsheetStore.syncDefaultsKey))

        await fixture.store.setSyncsWithOriginals(false)
        #expect(fixture.state == .copyOnly)
        #expect(fixture.store.syncStates.isEmpty)
    }

    @Test func removingAFileDropsItsLink() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.store.removeFile("todo.md", from: fixture.sheetID)

        #expect(fixture.sheet.links.isEmpty)
    }

    @Test func exportsCarryNoLinks() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let item = try #require(fixture.store.exportItems(for: [fixture.sheetID]).first)

        #expect(item.sheet.links.isEmpty)
        #expect(!fixture.sheet.links.isEmpty)
    }

    @Test func comparisonMatrix() {
        let old = FileFingerprint(modified: Date(timeIntervalSinceReferenceDate: 1), size: 1)
        let new = FileFingerprint(modified: Date(timeIntervalSinceReferenceDate: 2), size: 1)
        let link = FileLink(bookmark: Data(), originalStamp: old, copyStamp: old)

        #expect(SyncComparison.between(original: old, copy: old, link: link) == .inSync)
        #expect(SyncComparison.between(original: new, copy: old, link: link) == .originalChanged)
        #expect(SyncComparison.between(original: old, copy: new, link: link) == .copyChanged(originalChanged: false))
        #expect(SyncComparison.between(original: new, copy: new, link: link) == .copyChanged(originalChanged: true))
        #expect(SyncComparison.between(original: old, copy: nil, link: link) == .copyChanged(originalChanged: false))
    }
}

struct MarkdownTaskTests {
    @Test func ticksAndUnticksTheItemOnThatLine() {
        let source = "# List\n- [ ] milk\n- [x] eggs\n"

        #expect(MarkdownTasks.settingTask(atLine: 2, checked: true, in: source) == "# List\n- [x] milk\n- [x] eggs\n")
        #expect(MarkdownTasks.settingTask(atLine: 3, checked: false, in: source) == "# List\n- [ ] milk\n- [ ] eggs\n")
    }

    @Test func handlesOtherMarkersIndentationQuotesAndLineEndings() {
        #expect(MarkdownTasks.settingTask(atLine: 1, checked: true, in: "  * [ ] a") == "  * [x] a")
        #expect(MarkdownTasks.settingTask(atLine: 1, checked: true, in: "3. [ ] a") == "3. [x] a")
        #expect(MarkdownTasks.settingTask(atLine: 1, checked: false, in: "> - [X] a") == "> - [ ] a")
        #expect(MarkdownTasks.settingTask(atLine: 2, checked: true, in: "a\r\n- [ ] b\r\n") == "a\r\n- [x] b\r\n")
    }

    // A tick against a stale render must not edit some other line.
    @Test func linesThatAreNotTasksAreLeftAlone() {
        #expect(MarkdownTasks.settingTask(atLine: 1, checked: true, in: "- plain item") == nil)
        #expect(MarkdownTasks.settingTask(atLine: 1, checked: true, in: "text [ ] here") == nil)
        #expect(MarkdownTasks.settingTask(atLine: 5, checked: true, in: "- [ ] a") == nil)
    }

    @Test func renderedCheckboxesCarryTheirSourceLine() {
        let body = MarkdownRenderer.render("intro\n\n- [ ] a\n- [x] b").body
        #expect(body.contains("<input type=\"checkbox\" disabled data-line=\"3\">"))
        #expect(body.contains("<input type=\"checkbox\" checked disabled data-line=\"4\">"))
    }
}

@MainActor
struct OverlayEditingTests {
    @Test func textBasedPagesAreEditable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("editable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func page(_ name: String) throws -> SheetPage {
            let url = directory.appendingPathComponent(name)
            try "x".write(to: url, atomically: true, encoding: .utf8)
            return SheetPage(url: url, pdfPageIndex: nil, rotation: .deg0, flipHorizontal: false, flipVertical: false)
        }

        #expect(OverlayController.isEditable(try page("notes.txt")))
        #expect(OverlayController.isEditable(try page("todo.md")))
        #expect(OverlayController.isEditable(try page("page.html")))
        #expect(!OverlayController.isEditable(try page("scan.png")))
        let missing = SheetPage(url: directory.appendingPathComponent("gone.md"), pdfPageIndex: nil, rotation: .deg0, flipHorizontal: false, flipVertical: false)
        #expect(!OverlayController.isEditable(missing))
    }

    @Test func standardEditingShortcutsMapToTextActions() {
        #expect(EditingShortcut.action(forKey: "v", modifiers: .command) == #selector(NSText.paste(_:)))
        #expect(EditingShortcut.action(forKey: "C", modifiers: .command) == #selector(NSText.copy(_:)))
        #expect(EditingShortcut.action(forKey: "z", modifiers: .command) == Selector(("undo:")))
        #expect(EditingShortcut.action(forKey: "z", modifiers: [.command, .shift]) == Selector(("redo:")))
        #expect(EditingShortcut.action(forKey: "v", modifiers: []) == nil)
        #expect(EditingShortcut.action(forKey: "v", modifiers: [.command, .option]) == nil)
    }

    @Test func saveMessagesFlagProblems() {
        #expect(!EditSaveOutcome.savedToOriginal.isWarning)
        #expect(!EditSaveOutcome.savedToCopy.isWarning)
        #expect(EditSaveOutcome.keptInCopy(.originalMissing).isWarning)
        #expect(EditSaveOutcome.keptInCopy(.originalMissing).statusText == "Saved in Cheatsheet — original missing")
        #expect(EditSaveOutcome.failed.isWarning)
    }
}
