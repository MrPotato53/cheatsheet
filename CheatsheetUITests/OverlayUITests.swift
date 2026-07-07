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
        openOverlayFromMenu("Alpha")

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
        openOverlayFromMenu("Alpha")

        app.activate()
        app.typeKey(.escape, modifierFlags: [])

        waitForState("overlay dismissed by Escape") { $0.sessions.isEmpty }
    }

    @MainActor
    func testEscapeDoesNothingWhenDisabledInDefaults() throws {
        launchApp(sheets: [threePageSheet()], defaults: ["dismissWithEsc": false])
        openOverlayFromMenu("Alpha")

        app.activate()
        app.typeKey(.escape, modifierFlags: [])

        assertStateHolds(for: 1.5, "overlay stays open with Escape disabled") { state in
            state.session(named: "Alpha")?.isVisible == true
        }
    }

    @MainActor
    func testPinnedOverlayIgnoresEscapeAndMenuBringsItToFront() throws {
        launchApp(sheets: [threePageSheet()])
        openOverlayFromMenu("Alpha")

        let pin = app.buttons["overlay.pin"]
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

        openOverlayFromMenu("Alpha")
        openOverlayFromMenu("Beta")
        waitForState("transient Alpha replaced by Beta") { $0.sessions.map(\.name) == ["Beta"] }

        // Pin Beta, then open Alpha: both stay on screen.
        let pin = app.buttons["overlay.pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.click()
        waitForState("Beta pinned") { $0.session(named: "Beta")?.isPinned == true }

        openOverlayFromMenu("Alpha")
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

        clickStatusMenuItem("Empty")
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

        let state = openOverlayFromMenu("Docs")
        XCTAssertEqual(state?.session(named: "Docs")?.pageCount, 2)

        app.buttons["overlay.nextPage"].click()
        waitForState("markdown page shown") { $0.session(named: "Docs")?.pageIndex == 1 }
    }
}
