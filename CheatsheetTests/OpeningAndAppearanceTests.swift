import AppKit
import Carbon.HIToolbox
import Foundation
import KeyboardShortcuts
import Testing

@testable import Cheatsheet

// MARK: - Appearance

struct AppAppearanceTests {
    @Test func storedValuesMapToTheirAppearance() {
        #expect(AppAppearance(storedValue: "light").appearanceName == .aqua)
        #expect(AppAppearance(storedValue: "dark").appearanceName == .darkAqua)
        #expect(AppAppearance(storedValue: "system").appearanceName == nil)
    }

    @Test func missingOrUnknownValueFollowsTheSystem() {
        #expect(AppAppearance(storedValue: nil) == .system)
        #expect(AppAppearance(storedValue: "sepia") == .system)
    }

    @Test func pickerOrderIsLightDarkSystem() {
        #expect(AppAppearance.allCases == [.light, .dark, .system])
    }
}

// MARK: - ⌃⌘-drag

struct GestureDragTests {
    @Test func controlCommandDragsAMovablePanel() {
        #expect(OverlayPanel.startsGestureDrag(modifiers: [.control, .command], isMovable: true))
        // Extra modifiers (e.g. caps lock, a held shift) don't stop it.
        #expect(OverlayPanel.startsGestureDrag(modifiers: [.control, .command, .capsLock], isMovable: true))
    }

    @Test func otherModifiersOrLockedPanelDoNotDrag() {
        #expect(!OverlayPanel.startsGestureDrag(modifiers: [.command], isMovable: true))
        #expect(!OverlayPanel.startsGestureDrag(modifiers: [.control], isMovable: true))
        #expect(!OverlayPanel.startsGestureDrag(modifiers: [.option, .command], isMovable: true))
        #expect(!OverlayPanel.startsGestureDrag(modifiers: [], isMovable: true))
        #expect(!OverlayPanel.startsGestureDrag(modifiers: [.control, .command], isMovable: false))
    }
}

// MARK: - Open in Settings shortcut

@MainActor
struct OpenInSettingsKeyTests {
    private func keyDown(_ characters: String, keyCode: Int, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
        )!
    }

    private let commandComma = KeyboardShortcuts.Shortcut(.comma, modifiers: [.command])

    @Test func defaultIsCommandComma() {
        #expect(KeyboardShortcuts.Name.openInSettings.defaultShortcut == commandComma)
    }

    @Test func matchesOnlyTheRecordedCombination() {
        let event = keyDown(",", keyCode: kVK_ANSI_Comma, modifiers: [.command])
        #expect(OverlayController.isOpenInSettingsKey(event, shortcut: commandComma))
        #expect(!OverlayController.isOpenInSettingsKey(
            keyDown(".", keyCode: kVK_ANSI_Period, modifiers: [.command]), shortcut: commandComma
        ))
        #expect(!OverlayController.isOpenInSettingsKey(
            keyDown(",", keyCode: kVK_ANSI_Comma, modifiers: [.command, .shift]), shortcut: commandComma
        ))
    }

    @Test func customShortcutMatchesAndClearedShortcutNeverDoes() {
        let custom = KeyboardShortcuts.Shortcut(.s, modifiers: [.command, .option])
        #expect(OverlayController.isOpenInSettingsKey(
            keyDown("s", keyCode: kVK_ANSI_S, modifiers: [.command, .option]), shortcut: custom
        ))
        #expect(!OverlayController.isOpenInSettingsKey(
            keyDown(",", keyCode: kVK_ANSI_Comma, modifiers: [.command]), shortcut: nil
        ))
    }
}

// MARK: - Opening files (Open With, Dock)

struct OpenedFilesTests {
    @Test func keepsOnlyFilesCheatsheetCanShow() {
        let names = ["a.pdf", "b.png", "c.md", "d.html", "e.txt", "f.webloc", "g.zip", "h.app", "i.mp3"]
        let urls = names.map { URL(fileURLWithPath: "/tmp/\($0)") }
        let kept = OpenedFiles.supported(urls).map(\.lastPathComponent)
        #expect(kept == ["a.pdf", "b.png", "c.md", "d.html", "e.txt", "f.webloc"])
    }
}

// MARK: - Settings navigation

@MainActor
struct SettingsNavigationTests {
    @Test func requestingASheetShowsTheCheatsheetsTab() {
        let navigation = SettingsNavigation()
        let id = UUID()
        navigation.requestSheet(id)
        #expect(navigation.tab == .cheatsheets)
        #expect(navigation.sheetRequest?.sheetID == id)
    }

    @Test func repeatedRequestsForTheSameSheetAreDistinct() {
        let navigation = SettingsNavigation()
        let id = UUID()
        navigation.requestSheet(id)
        let first = navigation.sheetRequest
        navigation.requestSheet(id)
        #expect(navigation.sheetRequest != first)
    }

    @Test func consumingClearsTheRequest() {
        let navigation = SettingsNavigation()
        let id = UUID()
        navigation.requestSheet(id)
        #expect(navigation.consumeSheetRequest() == id)
        #expect(navigation.sheetRequest == nil)
        #expect(navigation.consumeSheetRequest() == nil)
    }
}

// MARK: - Dropped items → cheatsheet

@MainActor
struct AddDroppedItemsTests {
    private func makeStore() throws -> (CheatsheetStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "drop-test-\(UUID().uuidString)")!
        return (CheatsheetStore(rootDirectory: root.appendingPathComponent("Library"), defaults: defaults), root)
    }

    @Test func filesAndLinksBecomeOneSheet() throws {
        let (store, root) = try makeStore()
        let file = root.appendingPathComponent("Notes.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let dropped = DroppedItems([file, URL(string: "https://example.com/docs")!])

        let sheet = try #require(store.addSheet(dropped: dropped, assignDefaultShortcut: false))

        #expect(sheet.name == "Notes")
        let stored = try #require(store.sheets.first { $0.id == sheet.id })
        #expect(stored.files.count == 2)
        #expect(stored.files.contains("Notes.txt"))
    }

    @Test func onlyLinksBecomeAWebPageSheet() throws {
        let (store, _) = try makeStore()
        let dropped = DroppedItems([URL(string: "https://example.com/docs")!])

        let sheet = try #require(store.addSheet(dropped: dropped, assignDefaultShortcut: false))

        #expect(sheet.files.count == 1)
    }

    @Test func nothingUsableCreatesNothing() throws {
        let (store, _) = try makeStore()
        #expect(store.addSheet(dropped: DroppedItems([]), assignDefaultShortcut: false) == nil)
        #expect(store.sheets.isEmpty)
    }

    @Test func addingToAnExistingSheetAppendsFilesAndLinks() throws {
        let (store, root) = try makeStore()
        let first = root.appendingPathComponent("One.txt")
        let second = root.appendingPathComponent("Two.txt")
        try "1".write(to: first, atomically: true, encoding: .utf8)
        try "2".write(to: second, atomically: true, encoding: .utf8)
        let sheet = try #require(store.addSheet(files: [first], assignDefaultShortcut: false))

        let added = store.add(DroppedItems([second, URL(string: "https://example.com")!]), to: sheet.id)

        #expect(added)
        #expect(store.sheets.first { $0.id == sheet.id }?.files.count == 3)
    }
}

// MARK: - Previewing a hidden page from settings

@MainActor
struct RevealHiddenPageTests {
    private func page(_ name: String, hidden: Bool = false) -> SheetPage {
        SheetPage(
            url: URL(fileURLWithPath: "/tmp/\(name)"), pdfPageIndex: nil, rotation: .deg0,
            flipHorizontal: false, flipVertical: false, isHidden: hidden
        )
    }

    @Test func hiddenPageIsShownOnItsOwn() {
        let a = page("a.png"), b = page("b.png", hidden: true), c = page("c.png")
        let result = OverlayController.pages([a, c], revealing: b)
        #expect(result == [b])
    }

    @Test func shownPageLeavesPagesUnchanged() {
        let a = page("a.png"), c = page("c.png")
        let result = OverlayController.pages([a, c], revealing: c)
        #expect(result == [a, c])
    }
}

// MARK: - New Cheatsheet from the search bar and menu

@MainActor
struct NewCheatsheetEntryTests {
    @Test func searchBarOffersNewCheatsheet() {
        let results = LauncherResult.ranked(sheets: [Cheatsheet(name: "Vim")], query: "new")
        #expect(results.first?.title == "New Cheatsheet")
        #expect(results.first?.isNewCheatsheet == true)
        #expect(results.first?.sheet == nil)
    }

    @Test func aSheetWithTheSameNameComesFirst() {
        let named = Cheatsheet(name: "New Cheatsheet")
        let results = LauncherResult.ranked(sheets: [named], query: "new cheatsheet")
        #expect(results.first?.sheet?.id == named.id)
        #expect(results.contains { $0.isNewCheatsheet })
    }

    @Test func requestingTheFormShowsTheCheatsheetsTabOnce() {
        let navigation = SettingsNavigation()
        navigation.requestNewSheetForm()
        #expect(navigation.tab == .cheatsheets)
        #expect(navigation.consumeNewSheetFormRequest())
        #expect(!navigation.consumeNewSheetFormRequest())
    }
}
