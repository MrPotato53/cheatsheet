import XCTest

/// Core overlay behavior: opening a cheatsheet, paging, dismissal, pinning,
/// hold-to-show activation, and the transient-session rule.
final class OverlayUITests: CheatsheetUITestCase {
    private func threePageSheet(name: String = "Alpha") -> SeedSheet {
        SeedSheet(name: name, pages: [
            .image("one.png", width: 1200, height: 800),
            .image("two.png", width: 1200, height: 800),
            .image("three.png", width: 1200, height: 800),
        ])
    }

    @MainActor
    func testRawToggleSyncsBetweenOverlayAndSettingsPreview() throws {
        launchApp(sheets: [SeedSheet(name: "Notes", pages: [.text("notes.md", "# Heading\n\nSome *text*.")])])
        openOverlay("Notes")

        revealOverlayPin()
        let overlayToggle = app.buttons["overlay.rawToggle"]
        XCTAssertTrue(overlayToggle.waitForExistence(timeout: 5), "raw toggle should sit beside the pin on markdown pages")
        XCTAssertEqual(overlayToggle.value as? String, "formatted")
        overlayToggle.click()
        waitForState("raw mode persisted from overlay") { $0.sheet(named: "Notes")?.rawFiles == ["notes.md"] }
        // Closed so the centered overlay doesn't cover the settings sidebar.
        hideAllOverlays()

        openCheatsheetsTab()
        selectSheetInSidebar("Notes")
        let previewToggle = settingsWindow.buttons["preview.rawToggle"]
        XCTAssertTrue(previewToggle.waitForExistence(timeout: 5), "settings preview should offer the raw toggle")
        XCTAssertEqual(previewToggle.value as? String, "raw", "settings preview follows the overlay's choice")

        previewToggle.click()
        waitForState("formatted mode persisted from settings") { $0.sheet(named: "Notes")?.rawFiles.isEmpty == true }

        openOverlay("Notes")
        revealOverlayPin()
        XCTAssertTrue(overlayToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(overlayToggle.value as? String, "formatted", "overlay follows the settings choice")
    }

    @MainActor
    func testSearchFindsMatchesAcrossPagesAndEscapeClosesSearchFirst() throws {
        launchApp(sheets: [SeedSheet(name: "Notes", pages: [
            .text("one.txt", "alpha beta"),
            .text("two.txt", "gamma"),
            .text("three.md", "# Beta\n\nbeta again"),
        ])])
        openOverlay("Notes")

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["overlay.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘F should open the search field")
        waitForState("search field focused") { $0.session(named: "Notes")?.isEditingSearch == true }
        // typeText demands an active app; the overlay is non-activating, so
        // send keystrokes to the key panel the way real typing arrives.
        for character in "beta" {
            app.typeKey(String(character), modifierFlags: [])
        }
        let status = app.staticTexts["overlay.search.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        waitForText(status, "1 of 3")
        XCTAssertEqual(requestState()?.session(named: "Notes")?.pageIndex, 0, "stays on the first page holding a match")

        app.typeKey(.return, modifierFlags: [])
        waitForState("return jumps over the match-less page") { $0.session(named: "Notes")?.pageIndex == 2 }
        waitForText(status, "2 of 3")
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        waitForState("wraps back to the first match") { $0.session(named: "Notes")?.pageIndex == 0 }
        app.typeKey(.return, modifierFlags: .shift)
        waitForState("shift-return goes backwards, wrapping") { $0.session(named: "Notes")?.pageIndex == 2 }

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "escape closes the search first")
        XCTAssertEqual(requestState()?.sessions.count, 1, "overlay stays open")
    }

    /// SwiftUI Text exposes its string as the element's value.
    private func waitForText(
        _ element: XCUIElement,
        _ text: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "value == %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "expected '\(text)', got '\(element.value ?? "nil")'", file: file, line: line)
    }

    @MainActor
    func testSearchHighlightsInPDFAndHTMLPages() throws {
        launchApp(sheets: [SeedSheet(name: "Mixed", pages: [
            .text("doc.pdf", "Keyboard shortcuts\n\nPress the magic key to find magic."),
            .text("page.html", "<h1 style=\"color: tomato\">Styled</h1><p>Some magic words.</p>"),
        ])])
        openOverlay("Mixed")
        search("magic", in: "Mixed")
        let status = app.staticTexts["overlay.search.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        waitForText(status, "1 of 3")
        app.buttons["overlay.search.previous"].click()
        waitForState("wraps back to the HTML page") { $0.session(named: "Mixed")?.pageIndex == 1 }
        waitForText(status, "3 of 3")
    }

    @MainActor
    func testSearchFindsTextInsideImages() throws {
        launchApp(sheets: [SeedSheet(name: "Shots", pages: [
            .text("notes.txt", "nothing to see"),
            .text("keys.png", "Copy with Command C\nPaste with Command V"),
        ])])
        openOverlay("Shots")
        search("command", in: "Shots")
        let status = app.staticTexts["overlay.search.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        // First recognition loads Vision's model; allow it some time.
        waitForText(status, "1 of 2", timeout: 20)
        waitForState("jumped to the image page") { $0.session(named: "Shots")?.pageIndex == 1 }
    }

    @MainActor
    func testTopRightButtonsShowPointingHandCursor() throws {
        launchApp(sheets: [SeedSheet(name: "Notes", pages: [
            .image("pic.png", width: 800, height: 600),
            .text("notes.md", "# Hi\n\nSome text under the buttons."),
        ])])
        openOverlay("Notes")

        func assertPointingHand(over identifier: String, line: UInt = #line) {
            revealOverlayPin()
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(identifier) missing")
            button.hover()
            waitForState("pointing hand over \(identifier)", line: line) { $0.cursor == "pointingHand" }
        }

        // Image page: nothing but SwiftUI under the buttons.
        assertPointingHand(over: "overlay.search")
        assertPointingHand(over: "overlay.pin")

        // Markdown page: a web view sits under the buttons and sets its own
        // cursor on every mouse move.
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForState("on the markdown page") { $0.session(named: "Notes")?.pageIndex == 1 }
        for identifier in ["overlay.search", "overlay.rawToggle", "overlay.pin"] {
            assertPointingHand(over: identifier)
        }

        overlayContent().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).hover()
        waitForState("page content keeps its own cursor") { $0.cursor != "pointingHand" }
        overlayContent().coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.01)).hover()
        waitForState("open hand over the drag strip") { $0.cursor == "openHand" }
    }

    @MainActor
    func testMenuTogglesOverlayOpenAndClosed() throws {
        launchApp(sheets: [threePageSheet()])

        let state = openOverlayFromMenu("Alpha")
        let session = state?.session(named: "Alpha")
        XCTAssertEqual(session?.pageCount, 3)
        XCTAssertEqual(session?.pageIndex, 0)
        assertFullyOnScreen(try XCTUnwrap(session))
        XCTAssertTrue(overlayContent().exists, "overlay content should be on screen")

        // Same menu item toggles it back off.
        clickStatusMenuItem("Alpha")
        waitForState("overlay dismissed by second menu click") { $0.sessions.isEmpty }
    }

    @MainActor
    func testPagingWithButtonsAndArrowKeys() throws {
        launchApp(sheets: [threePageSheet()])
        openOverlay("Alpha")

        let next = app.buttons["overlay.nextPage"]
        let previous = app.buttons["overlay.previousPage"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))

        next.click()
        waitForState("page 2 via next button") { $0.session(named: "Alpha")?.pageIndex == 1 }
        next.click()
        waitForState("page 3 via next button") { $0.session(named: "Alpha")?.pageIndex == 2 }
        XCTAssertFalse(next.isEnabled, "next disabled on the last page")

        previous.click()
        waitForState("page 2 via previous button") { $0.session(named: "Alpha")?.pageIndex == 1 }

        // Arrow keys reach the key overlay panel.
        app.activate()
        app.typeKey(.rightArrow, modifierFlags: [])
        waitForState("page 3 via right arrow") { $0.session(named: "Alpha")?.pageIndex == 2 }
        app.typeKey(.leftArrow, modifierFlags: [])
        waitForState("page 2 via left arrow") { $0.session(named: "Alpha")?.pageIndex == 1 }
    }

    @MainActor
    func testEscapeDismissesOverlay() throws {
        launchApp(sheets: [threePageSheet()])
        openOverlay("Alpha")

        app.activate()
        app.typeKey(.escape, modifierFlags: [])

        waitForState("overlay dismissed by Escape") { $0.sessions.isEmpty }
    }

    @MainActor
    func testEscapeDoesNothingWhenDisabledInDefaults() throws {
        launchApp(sheets: [threePageSheet()], defaults: ["dismissWithEsc": false])
        openOverlay("Alpha")

        app.activate()
        app.typeKey(.escape, modifierFlags: [])

        assertStateHolds(for: 1.5, "overlay stays open with Escape disabled") { state in
            state.session(named: "Alpha")?.isVisible == true
        }
    }

    @MainActor
    func testPinnedOverlayIgnoresEscapeAndMenuBringsItToFront() throws {
        launchApp(sheets: [threePageSheet()])
        openOverlay("Alpha")

        let pin = revealOverlayPin()
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.click()
        waitForState("session pinned") { $0.session(named: "Alpha")?.isPinned == true }

        app.activate()
        app.typeKey(.escape, modifierFlags: [])
        assertStateHolds(for: 1.5, "pinned overlay survives Escape") { state in
            state.session(named: "Alpha")?.isVisible == true
        }

        // Menu click brings a pinned overlay to front instead of toggling it off.
        clickStatusMenuItem("Alpha")
        assertStateHolds(for: 1.5, "pinned overlay survives menu toggle") { state in
            state.session(named: "Alpha")?.isVisible == true
        }

        pin.click()
        waitForState("session unpinned") { $0.session(named: "Alpha")?.isPinned == false }
        app.activate()
        app.typeKey(.escape, modifierFlags: [])
        waitForState("unpinned overlay dismissed by Escape") { $0.sessions.isEmpty }
    }

    @MainActor
    func testOpeningSecondSheetReplacesTransientButKeepsPinned() throws {
        launchApp(sheets: [threePageSheet(name: "Alpha"), threePageSheet(name: "Beta")])

        openOverlay("Alpha")
        openOverlay("Beta")
        waitForState("transient Alpha replaced by Beta") { $0.sessions.map(\.name) == ["Beta"] }

        // Pin Beta, then open Alpha: both stay on screen.
        let pin = revealOverlayPin()
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.click()
        waitForState("Beta pinned") { $0.session(named: "Beta")?.isPinned == true }

        openOverlay("Alpha")
        waitForState("pinned Beta coexists with transient Alpha") { state in
            Set(state.sessions.map(\.name)) == ["Alpha", "Beta"]
        }
    }

    @MainActor
    func testHoldToShowDisplaysOnlyWhileKeyIsHeld() throws {
        var sheet = threePageSheet()
        sheet.activation = "hold"
        launchApp(sheets: [sheet])

        // Global hotkeys can't be synthesized reliably; drive the handler
        // layer directly (everything below the Carbon hotkey is real).
        postDebug("keyDown:0")
        waitForState("overlay shown on hotkey down") { state in
            guard let session = state.session(named: "Alpha") else { return false }
            return session.isVisible && !session.isLoading
        }

        postDebug("keyUp:0")
        waitForState("overlay hidden on hotkey up") { $0.sessions.isEmpty }
    }

    @MainActor
    func testEmptyCheatsheetShowsPlaceholder() throws {
        launchApp(sheets: [SeedSheet(name: "Empty", pages: [])])

        postDebug("toggleSheet:Empty")
        waitForState("empty session finished loading") { state in
            guard let session = state.session(named: "Empty") else { return false }
            return !session.isLoading && session.pageCount == 0
        }
        XCTAssertTrue(
            app.staticTexts["Nothing to show"].waitForExistence(timeout: 5),
            "empty sheet should show its placeholder"
        )
    }

    @MainActor
    func testTextAndMarkdownPagesOpen() throws {
        launchApp(sheets: [SeedSheet(name: "Docs", pages: [
            .text("notes.txt", "remember the milk"),
            .text("guide.md", "# Heading\n\nSome **bold** text"),
        ])])

        let state = openOverlay("Docs")
        XCTAssertEqual(state?.session(named: "Docs")?.pageCount, 2)

        goToPage(1, of: "Docs")
    }
}
