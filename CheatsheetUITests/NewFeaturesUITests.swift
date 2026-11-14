import XCTest

/// Open in Settings, opening files from outside, New Cheatsheet entry points,
/// appearance, double-clicking pages in settings, and ⌃⌘-drag. Each test
/// drives the real input it's about; setup goes through debug hooks.
final class NewFeaturesUITests: CheatsheetUITestCase {
    private let notes = SeedSheet(name: "Notes", pages: [.text("notes.txt", "Line one\nLine two\nLine three")])
    private let pictures = SeedSheet(name: "Pictures", pages: [
        .image("a.png", width: 400, height: 300),
        .image("b.png", width: 400, height: 300),
        .image("c.png", width: 400, height: 300),
    ])

    // MARK: Helpers

    /// Settings is up on the Cheatsheets tab with `name` selected.
    private func assertSettingsSelects(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        waitForState(timeout: 10, "settings open on the Cheatsheets tab", file: file, line: line) {
            $0.settingsVisible && $0.settingsTab == "cheatsheets"
        }
        app.activate()
        let nameField = settingsWindow.textFields["detail.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "detail pane not shown", file: file, line: line)
        let selected = NSPredicate(format: "value == %@", name)
        let result = XCTWaiter.wait(for: [expectation(for: selected, evaluatedWith: nameField)], timeout: 5)
        XCTAssertEqual(result, .completed, "expected “\(name)” selected, got \(String(describing: nameField.value))", file: file, line: line)
    }

    private func assertNewCheatsheetDialogShown(file: StaticString = #filePath, line: UInt = #line) {
        waitForState(timeout: 10, "settings open on the Cheatsheets tab", file: file, line: line) {
            $0.settingsVisible && $0.settingsTab == "cheatsheets"
        }
        app.activate()
        let choose = app.descendants(matching: .any).matching(identifier: "newSheet.files").firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 5), "New Cheatsheet dialog not shown", file: file, line: line)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: Open in Settings

    @MainActor
    func testGearButtonOpensSheetInSettingsAndClosesOverlay() throws {
        launchApp(sheets: [notes, pictures])
        openOverlay("Pictures")
        revealOverlayPin()
        let gear = app.buttons["overlay.openInSettings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "Open in Settings button not shown")

        gear.click()

        waitForState(timeout: 10, "transient overlay closed") { $0.sessions.isEmpty }
        // Not the first sheet, so this proves the selection followed.
        assertSettingsSelects("Pictures")
    }

    @MainActor
    func testCommandCommaOpensSettingsAndKeepsPinnedOverlay() throws {
        launchApp(sheets: [notes, pictures])
        openOverlay("Pictures")
        revealOverlayPin().click()
        waitForState("overlay pinned and key") { state in
            guard let session = state.session(named: "Pictures") else { return false }
            return session.isPinned && session.isKey
        }

        app.typeKey(",", modifierFlags: .command)

        assertSettingsSelects("Pictures")
        assertStateHolds("pinned overlay stays open") { $0.session(named: "Pictures")?.isVisible == true }
    }

    // MARK: Open With / Dock

    @MainActor
    func testOpenedFilesBecomeOneSheetShownInSettings() throws {
        launchApp(sheets: [notes])

        // Through the installed app delegate, as Finder and the Dock deliver
        // them; the .zip isn't something Cheatsheet shows.
        postDebug("openFiles:Recipe.md|extra.txt|archive.zip")

        waitForState(timeout: 10, "one new sheet from the two supported files") { state in
            state.sheets.count == 2 && state.sheet(named: "Recipe")?.fileCount == 2
        }
        assertSettingsSelects("Recipe")
    }

    // MARK: New Cheatsheet

    @MainActor
    func testMenuBarNewCheatsheetOpensDialogEvenFromGeneralTab() throws {
        launchApp(sheets: [notes])
        openSettings()
        waitForState("settings on General") { $0.settingsTab == "general" }

        clickStatusMenuItem("New Cheatsheet…")

        assertNewCheatsheetDialogShown()
    }

    @MainActor
    func testSearchBarNewCheatsheetOpensDialog() throws {
        launchApp(sheets: [notes], defaults: ["sheetOpenMethod": "both"])
        postDebug("toggleLauncher")
        postDebug("launcherQuery:new chea")
        waitForState("search bar lists New Cheatsheet first") { state in
            state.launcherVisible && state.launcherResults.first == "New Cheatsheet"
        }
        let result = element("launcher.result")
        XCTAssertTrue(result.waitForExistence(timeout: 5), "search bar result not found")

        result.click()

        waitForState("search bar closed") { !$0.launcherVisible }
        assertNewCheatsheetDialogShown()
    }

    // MARK: Appearance

    @MainActor
    func testAppearancePickerSwitchesTheWholeApp() throws {
        launchApp()
        openSettings()
        waitForState("starts following the system") { $0.appearance == "system" }
        let picker = element("general.appearance")
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "appearance picker not found")

        for (segment, stored, drawn) in [
            ("Dark", "dark", "NSAppearanceNameDarkAqua"),
            ("Light", "light", "NSAppearanceNameAqua"),
        ] {
            let button = picker.radioButtons[segment].exists ? picker.radioButtons[segment] : picker.buttons[segment]
            XCTAssertTrue(button.waitForExistence(timeout: 3), "\(segment) segment not found")
            button.click()
            waitForState("app drawn \(stored)") { $0.appearance == stored && $0.effectiveAppearance == drawn }
        }
        let system = picker.radioButtons["System"].exists ? picker.radioButtons["System"] : picker.buttons["System"]
        system.click()
        waitForState("back to following the system") { $0.appearance == "system" }
    }

    // MARK: Double-click pages in settings

    @MainActor
    func testDoubleClickingAShownPageOpensItInTheCheatsheet() throws {
        launchApp(sheets: [pictures])
        openCheatsheetsTab()
        let thumb = element("page.thumb.b.png")
        XCTAssertTrue(thumb.waitForExistence(timeout: 5), "page thumbnail not found")

        thumb.doubleClick()

        waitForState(timeout: 10, "overlay open on page 2 of 3") { state in
            guard let session = state.session(named: "Pictures") else { return false }
            return session.isVisible && !session.isLoading && session.pageIndex == 1 && session.pageCount == 3
        }
    }

    @MainActor
    func testDoubleClickingAHiddenPageShowsItAlone() throws {
        launchApp(sheets: [pictures])
        openCheatsheetsTab()
        let thumb = element("page.thumb.c.png")
        XCTAssertTrue(thumb.waitForExistence(timeout: 5), "page thumbnail not found")
        thumb.rightClick()
        let hide = app.menuItems["Hide Page"]
        XCTAssertTrue(hide.waitForExistence(timeout: 3), "Hide Page menu item not found")
        hide.click()
        // The hidden strip sits further down the form, and a collection view
        // only creates thumbnails it can show: scroll it into view first.
        let hiddenSection = settingsWindow.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Hidden pages'")).firstMatch
        XCTAssertTrue(hiddenSection.waitForExistence(timeout: 5), "hidden pages section not shown")
        scrollIntoView(hiddenSection, in: settingsWindow)
        // Now in the hidden strip (the only thumbnail of c.png).
        let hiddenThumb = element("page.thumb.c.png")
        XCTAssertTrue(hiddenThumb.waitForExistence(timeout: 5), "hidden page thumbnail not found")

        hiddenThumb.doubleClick()

        waitForState(timeout: 10, "overlay shows only the hidden page") { state in
            guard let session = state.session(named: "Pictures") else { return false }
            return session.isVisible && !session.isLoading && session.pageCount == 1
        }
        hideAllOverlays()
        // Next ordinary open: the two shown pages, the hidden one still hidden.
        let reopened = openOverlay("Pictures")
        XCTAssertEqual(reopened?.session(named: "Pictures")?.pageCount, 2)
    }

    // MARK: Files changed on disk (FSEvents)

    @MainActor
    func testEditingACopyOnDiskReloadsTheOpenCheatsheet() throws {
        launchApp(sheets: [notes])
        let before = try XCTUnwrap(openOverlay("Notes")?.session(named: "Notes")?.contentRevision)

        // Written behind the store's back, as another app would.
        postDebug("externalWrite:Notes:notes.txt:Edited elsewhere")

        waitForState(timeout: 5, "open cheatsheet re-read its file") { state in
            (state.session(named: "Notes")?.contentRevision ?? before) > before
        }
    }

    @MainActor
    func testDeletedCopyShowsAPlaceholderUntilItIsPutBack() throws {
        launchApp(sheets: [notes])
        openOverlay("Notes")

        postDebug("externalDelete:Notes:notes.txt")

        let placeholder = element("page.missing")
        XCTAssertTrue(placeholder.waitForExistence(timeout: 5), "missing-file placeholder not shown")
        XCTAssertTrue(placeholder.label.contains("notes.txt"), "placeholder doesn't name the file: \(placeholder.label)")
        XCTAssertEqual(requestState()?.sheet(named: "Notes")?.fileCount, 1, "entry should be kept")

        // Undo the delete: the page comes back.
        postDebug("externalWrite:Notes:notes.txt:Back again")
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: placeholder)], timeout: 5), .completed)
    }

    @MainActor
    func testFilesDroppedIntoTheSheetFolderAreAdded() throws {
        launchApp(sheets: [notes])
        openOverlay("Notes")

        // As if dropped into the folder from Finder.
        postDebug("externalWrite:Notes:extra.md:# Extra")
        postDebug("externalWrite:Notes:data.zip:zip")

        waitForState(timeout: 5, "both listed, only the markdown as a page") { state in
            state.sheet(named: "Notes")?.fileCount == 3 && state.session(named: "Notes")?.pageCount == 2
        }
        hideAllOverlays()
        openCheatsheetsTab()
        XCTAssertTrue(element("detail.unsupported").waitForExistence(timeout: 5), "unsupported file has no error label")
    }

    // MARK: Sync review renders like the cheatsheet

    /// Average color of an element as drawn on screen.
    private func averageColor(of element: XCUIElement) -> (red: Double, green: Double, blue: Double)? {
        guard let image = element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    /// Red: the page's linked stylesheet applied (not unstyled white, not blank).
    private func assertStyled(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        var color = averageColor(of: element)
        let deadline = Date(timeIntervalSinceNow: 8)
        while let current = color, !(current.red > 0.55 && current.green < 0.4 && current.blue < 0.4), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            color = averageColor(of: element)
        }
        let shot = XCTAttachment(screenshot: element.screenshot())
        shot.name = what
        shot.lifetime = .keepAlways
        add(shot)
        guard let color else { return XCTFail("\(what): no screenshot", file: file, line: line) }
        XCTAssertTrue(
            color.red > 0.55 && color.green < 0.4 && color.blue < 0.4,
            "\(what) isn't rendered with the sheet's stylesheet (average color \(color))", file: file, line: line
        )
    }

    @MainActor
    func testSyncReviewRendersBothVersionsWithTheSheetsStylesheet() throws {
        let page = { (heading: String) in
            #"<html><head><link rel="stylesheet" href="style.css"></head><body><h1>"# + heading + "</h1></body></html>"
        }
        let guide = SeedSheet(name: "Guide", pages: [
            .text("guide.html", page("Copy")),
            .text("style.css", "body { background: #ff0000; margin: 0; height: 100vh; }"),
        ])
        launchApp(sheets: [guide], defaults: ["syncWithOriginals": true])
        openCheatsheetsTab()
        selectSheetInSidebar("Guide")
        let link = settingsWindow.descendants(matching: .any).matching(identifier: "detail.fileLink").firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))

        // The original differs; only the sheet's folder has style.css.
        postDebug("divergeOriginal:Guide:" + page("Original"))
        let needsReview = NSPredicate(format: "value == %@", "needsReview")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: needsReview, evaluatedWith: link)], timeout: 8), .completed)
        link.click()
        let review = app.menuItems["Review Differences…"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.click()

        let thumbnails = app.descendants(matching: .any).matching(identifier: "review.thumbnail")
        XCTAssertTrue(thumbnails.element(boundBy: 1).waitForExistence(timeout: 5), "both versions should render")
        assertStyled(thumbnails.element(boundBy: 0), "original thumbnail")
        assertStyled(thumbnails.element(boundBy: 1), "copy thumbnail")

        app.descendants(matching: .any).matching(identifier: "review.originalCard").firstMatch.hover()
        let preview = app.buttons["review.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        // A real click at the button: XCUITest's hittability check resolves
        // to the card (an accessibility button containing it), not the
        // button, though the click itself lands on the button.
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let full = element("review.fullPreview")
        XCTAssertTrue(full.waitForExistence(timeout: 5), "preview didn't open")
        assertStyled(full, "original full preview")
        app.buttons["review.preview.done"].click()
    }

    // The folder button's right-click menu isn't covered here: XCUITest
    // doesn't see SwiftUI context menus in this embedded list (verified by
    // hand instead).

    // MARK: ⌃⌘-drag

    @MainActor
    func testControlCommandDragMovesATextSheetFromItsBody() throws {
        launchApp(sheets: [notes])
        let before = try XCTUnwrap(openOverlay("Notes")?.session(named: "Notes")?.frameRect)
        let content = overlayContent()
        XCTAssertTrue(content.waitForExistence(timeout: 5))

        // The text view would otherwise take this drag as a selection.
        XCUIElement.perform(withKeyModifiers: [.control, .command]) {
            let start = content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 120, dy: 0)))
        }

        let after = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Notes")?.frameRect)
        XCTAssertGreaterThan(after.minX - before.minX, 60, "overlay didn't follow the ⌃⌘-drag")
    }
}
