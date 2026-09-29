import XCTest

/// Each setting drives its promised outcome: Dock icon policy, Escape
/// dismissal, name, activation mode, start page, size, position, geometry
/// behaviors, keep-start-page-loaded, and deletion.
final class SettingsBehaviorUITests: CheatsheetUITestCase {
    private func threePageSheet(name: String = "Alpha") -> SeedSheet {
        SeedSheet(name: name, pages: [
            .image("one.png", width: 1200, height: 800),
            .image("two.png", width: 1200, height: 800),
            .image("three.png", width: 1200, height: 800),
        ])
    }

    // MARK: - General tab

    @MainActor
    func testDockIconPolicyAlwaysAndNever() throws {
        launchApp()
        openSettings()
        waitForState("regular while settings open (default policy)") { $0.activationPolicy == "regular" }

        let picker = settingsWindow.popUpButtons["general.dockIconPolicy"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "dock icon policy picker not found")

        picker.click()
        app.menuItems["Never"].click()
        waitForState("accessory even with settings open under Never") { state in
            state.activationPolicy == "accessory" && state.settingsVisible
        }

        picker.click()
        app.menuItems["Always"].click()
        waitForState("regular under Always") { $0.activationPolicy == "regular" }

        postDebug("closeSettings")
        waitForState("dock icon persists after closing settings under Always") { state in
            !state.settingsVisible && state.activationPolicy == "regular"
        }
    }

    @MainActor
    func testDockIconPolicyWhenSettingsOpenTracksWindow() throws {
        launchApp() // default policy: whenSettingsOpen
        waitForState("accessory before settings opens") { $0.activationPolicy == "accessory" }

        openSettings()
        waitForState("regular while settings open") { $0.activationPolicy == "regular" }

        postDebug("closeSettings")
        waitForState("accessory again after settings closes") { $0.activationPolicy == "accessory" }
    }

    @MainActor
    func testDismissWithEscapeToggleTakesEffectImmediately() throws {
        launchApp(sheets: [threePageSheet()])
        openSettings()

        let toggle = settingsWindow.switches["general.dismissWithEsc"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click() // off
        waitForState("dismissWithEsc off") { !$0.dismissWithEsc }

        // With Escape disabled the setting is read live, so an already-open
        // overlay survives Escape.
        openOverlay("Alpha")
        overlayContent().click() // make the overlay panel key again
        app.typeKey(.escape, modifierFlags: [])
        assertStateHolds(for: 1.5, "overlay survives Escape while disabled") { state in
            state.session(named: "Alpha")?.isVisible == true
        }

        // Flip it back on. The overlay is a floating status-bar panel; while
        // it exists, XCUITest can't hit-test settings controls beneath the app
        // — so dismiss it first, then a freshly opened overlay honors Escape,
        // proving the toggle took effect without a relaunch.
        hideAllOverlays()
        postDebug("openSettings")
        waitForState("settings refocused before re-toggling") { $0.settingsIsKey }
        // A plain .click() reports the switch as "not hittable" here (an
        // XCUITest quirk after the overlay/key-window churn); a coordinate
        // click lands on the same on-screen point regardless.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() // back on
        waitForState("dismissWithEsc on") { $0.dismissWithEsc }

        openOverlay("Alpha")
        overlayContent().click()
        app.typeKey(.escape, modifierFlags: [])
        waitForState("overlay dismissed once re-enabled") { $0.sessions.isEmpty }
    }

    @MainActor
    func testLaunchAtLoginToggleFlips() throws {
        // Registration itself is stubbed in UI test mode (it would install a
        // real login item); this covers the control and error-free flip.
        launchApp()
        openSettings()

        let toggle = settingsWindow.switches["general.launchAtLogin"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? Int, 0, "launch at login should start off in test mode")
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 1, "toggle should flip on")
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 0, "toggle should flip back off")
    }

    // MARK: - Per-sheet settings

    @MainActor
    func testRenamingSheetUpdatesSidebarAndStatusMenu() throws {
        launchApp(sheets: [threePageSheet(name: "Alpha")])
        openCheatsheetsTab()

        let field = settingsWindow.textFields["detail.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Renamed Sheet")

        waitForState("rename persisted to the store") { $0.sheet(named: "Renamed Sheet") != nil }
        XCTAssertTrue(
            settingsWindow.staticTexts["Renamed Sheet"].waitForExistence(timeout: 5),
            "sidebar should show the new name"
        )
        XCTAssertTrue(statusMenuItemExists("Renamed Sheet"), "status menu should show the new name")
    }

    @MainActor
    func testActivationModeHoldViaSettingsUI() throws {
        launchApp(sheets: [threePageSheet()])
        openCheatsheetsTab()

        let holdRadio = settingsWindow.radioButtons["Hold to show"]
        scrollIntoView(holdRadio, in: settingsWindow)
        holdRadio.click()
        waitForState("activation mode persisted") { $0.sheet(named: "Alpha")?.activation == "hold" }

        // The changed mode is honored: shows on key down, hides on key up.
        postDebug("keyDown:0")
        waitForState("shown while held") { $0.session(named: "Alpha")?.isVisible == true }
        postDebug("keyUp:0")
        waitForState("hidden on release") { $0.sessions.isEmpty }
    }

    @MainActor
    func testStartPageLastViewedReopensWhereLeft() throws {
        launchApp(sheets: [threePageSheet()]) // lastViewed is the default
        openOverlay("Alpha")

        app.buttons["overlay.nextPage"].click()
        waitForState("moved to page 2") { $0.session(named: "Alpha")?.pageIndex == 1 }

        hideAllOverlays()
        openOverlay("Alpha")
        waitForState("reopened on the last viewed page") { $0.session(named: "Alpha")?.pageIndex == 1 }
    }

    @MainActor
    func testStartPageFirstAlwaysReopensAtFirstPage() throws {
        var sheet = threePageSheet()
        sheet.startPage = "first"
        launchApp(sheets: [sheet])

        openOverlay("Alpha")
        app.buttons["overlay.nextPage"].click()
        waitForState("moved to page 2") { $0.session(named: "Alpha")?.pageIndex == 1 }

        hideAllOverlays()
        openOverlay("Alpha")
        waitForState("reopened on the first page") { $0.session(named: "Alpha")?.pageIndex == 0 }
    }

    @MainActor
    func testStartPageFixedChosenInSettingsUI() throws {
        launchApp(sheets: [threePageSheet()])
        openCheatsheetsTab()

        let startPicker = settingsWindow.popUpButtons["detail.startPage"]
        scrollIntoView(startPicker, in: settingsWindow)
        startPicker.click()
        app.menuItems["Specific page"].click()

        let pagePicker = settingsWindow.popUpButtons["detail.fixedPage"]
        XCTAssertTrue(pagePicker.waitForExistence(timeout: 5), "fixed page picker should appear")
        scrollIntoView(pagePicker, in: settingsWindow)
        pagePicker.click()
        let pageThree = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Page 3")).firstMatch
        XCTAssertTrue(pageThree.waitForExistence(timeout: 5))
        pageThree.click()

        waitForState("fixed start page persisted") { $0.sheet(named: "Alpha")?.startPage == "fixed:2" }

        openOverlay("Alpha")
        waitForState("overlay opens on the fixed page") { $0.session(named: "Alpha")?.pageIndex == 2 }
    }

    @MainActor
    func testSizeSliderResizesOverlayLiveAndPersists() throws {
        var sheet = threePageSheet()
        sheet.previewScale = 0.4
        launchApp(sheets: [sheet])

        openOverlay("Alpha")
        let before = try XCTUnwrap(requestState()?.session(named: "Alpha")).frameRect

        openCheatsheetsTab()
        let slider = settingsWindow.sliders["detail.sizeSlider"]
        scrollIntoView(slider, in: settingsWindow)
        slider.adjust(toNormalizedSliderPosition: 1.0)

        waitForState("previewScale persisted near 100%") { state in
            (state.sheet(named: "Alpha")?.previewScale ?? 0) > 0.9
        }
        // The open overlay tracks the slider live (no reopen needed).
        waitForState("overlay grew live with the slider") { state in
            guard let session = state.session(named: "Alpha") else { return false }
            return session.frameRect.width > before.width * 1.5
        }
    }

    @MainActor
    func testPositionPreviewDragMovesSpawnPointAndCenterResets() throws {
        var sheet = threePageSheet()
        sheet.previewScale = 0.3
        launchApp(sheets: [sheet])
        openCheatsheetsTab()

        let preview = settingsWindow.descendants(matching: .any)
            .matching(identifier: "detail.positionPreview").firstMatch
        scrollIntoView(preview, in: settingsWindow)

        // Drag the red box (starts centered) toward the bottom-left. The
        // preview clamps so the box stays inside: at scale 0.3 the center
        // clamps to 0.15 per axis.
        let start = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = preview.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.95))
        start.press(forDuration: 0.2, thenDragTo: end)

        waitForState("clamped bottom-left position persisted") { state in
            guard let stored = state.sheet(named: "Alpha")?.position, stored.count == 2 else { return false }
            return abs(stored[0] - 0.15) < 0.03 && abs(stored[1] - 0.15) < 0.03
        }

        // The overlay spawns at the configured relative position.
        openOverlay("Alpha")
        let session = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha"))
        let visible = try XCTUnwrap(session.visibleRect)
        let relativeX = (session.frameRect.midX - visible.minX) / visible.width
        let relativeY = (session.frameRect.midY - visible.minY) / visible.height
        XCTAssertEqual(relativeX, 0.15, accuracy: 0.05, "overlay should spawn at the configured x")
        XCTAssertEqual(relativeY, 0.15, accuracy: 0.05, "overlay should spawn at the configured y")

        // Center button resets and then disables itself.
        let center = settingsWindow.buttons["detail.center"]
        scrollIntoView(center, in: settingsWindow)
        center.click()
        waitForState("position reset to center") { state in
            guard let stored = state.sheet(named: "Alpha")?.position, stored.count == 2 else { return false }
            return stored[0] == 0.5 && stored[1] == 0.5
        }
        XCTAssertFalse(center.isEnabled, "Center should disable once centered")
    }

    @MainActor
    func testKeepStartPageLoadedPersistsAndOverlayStillOpens() throws {
        launchApp(sheets: [threePageSheet()])
        openCheatsheetsTab()

        let toggle = settingsWindow.switches["detail.keepStartPageLoaded"]
        scrollIntoView(toggle, in: settingsWindow)
        toggle.click()
        waitForState("keep-start-page-loaded persisted") { state in
            state.sheet(named: "Alpha")?.keepsStartPageLoaded == true
        }

        // Give the warm task a moment, then verify the warm path opens fine.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        let state = openOverlay("Alpha")
        XCTAssertEqual(state?.session(named: "Alpha")?.pageCount, 3)
    }

    // MARK: - Geometry behaviors

    @MainActor
    func testDragBehaviorLockedPreventsMoving() throws {
        var sheet = threePageSheet()
        sheet.dragBehavior = "locked"
        launchApp(sheets: [sheet])

        let state = openOverlay("Alpha")
        let session = try XCTUnwrap(state?.session(named: "Alpha"))
        // Locked sheets also get no drag strip (same flag), so with background
        // dragging off there is nothing to grab. No synthesized drag attempt:
        // a grab that misses would move whatever window lies underneath.
        XCTAssertFalse(session.isMovable, "locked sheets must not be background-movable")
    }

    @MainActor
    func testDragBehaviorResetsRevertsOnReopen() throws {
        var sheet = threePageSheet()
        sheet.dragBehavior = "resets"
        launchApp(sheets: [sheet])

        openOverlay("Alpha")
        let original = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect

        dragOverlay("Alpha", by: CGVector(dx: 250, dy: 120))
        let dragged = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect
        XCTAssertFalse(dragged.approximatelyEqual(to: original, tolerance: 20), "drag should move the overlay for this session")

        // The configured position is NOT rewritten…
        waitForState("configured position untouched by the drag") { state in
            guard let stored = state.sheet(named: "Alpha")?.position, stored.count == 2 else { return false }
            return abs(stored[0] - 0.5) < 0.01 && abs(stored[1] - 0.5) < 0.01
        }

        // …so reopening returns to the configured spot.
        hideAllOverlays()
        openOverlay("Alpha")
        let reopened = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect
        XCTAssertTrue(
            reopened.approximatelyEqual(to: original, tolerance: 5),
            "overlay should revert to configured position on reopen: \(original) → \(reopened)"
        )
    }

    @MainActor
    func testDragBehaviorRemembersPersistsAcrossReopen() throws {
        launchApp(sheets: [threePageSheet()]) // remembers is the default

        openOverlay("Alpha")
        _ = waitForSettledFrame(sessionNamed: "Alpha")

        // The one real mouse drag in the suite: grabs the drag strip, which
        // is always inside the panel. Everything else moves via the hook.
        dragOverlayWithMouse(by: CGVector(dx: 250, dy: 120))
        let dragged = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect

        waitForState("dragged position written to the store") { state in
            guard let stored = state.sheet(named: "Alpha")?.position, stored.count == 2 else { return false }
            return abs(stored[0] - 0.5) > 0.05 || abs(stored[1] - 0.5) > 0.05
        }

        hideAllOverlays()
        openOverlay("Alpha")
        let reopened = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect
        XCTAssertTrue(
            reopened.approximatelyEqual(to: dragged, tolerance: 5),
            "overlay should reopen where it was dropped: \(dragged) → \(reopened)"
        )
    }

    @MainActor
    func testResizeBehaviorLockedRemovesResizability() throws {
        var sheet = threePageSheet()
        sheet.resizeBehavior = "locked"
        launchApp(sheets: [sheet])

        let state = openOverlay("Alpha")
        let session = try XCTUnwrap(state?.session(named: "Alpha"))
        // Without .resizable AppKit offers no resize zone at all. No physical
        // corner drag here: a synthesized grab that misses the edge becomes a
        // background window drag and can land on other windows on screen.
        XCTAssertFalse(session.isResizable, "locked sheets must not have a resizable panel")
    }

    @MainActor
    func testResizeBehaviorRemembersPersistsScale() throws {
        launchApp(sheets: [threePageSheet()]) // remembers is the default

        openOverlay("Alpha")
        let before = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect

        // Resize via the app's test hook rather than a synthesized corner
        // drag: the borderless panel's resize zone is only a few points wide,
        // and a missed grab turns into a background window drag (or hits a
        // window underneath). The hook commits through the real resize path.
        postDebug("userResize:Alpha:250:150")
        let resized = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect
        XCTAssertGreaterThan(resized.width, before.width + 100, "overlay should have grown")

        waitForState("resized scale written to the store") { state in
            abs((state.sheet(named: "Alpha")?.previewScale ?? 0.6) - 0.6) > 0.03
        }

        hideAllOverlays()
        openOverlay("Alpha")
        let reopened = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect
        XCTAssertEqual(reopened.width, resized.width, accuracy: 8, "overlay should reopen at the remembered size")
    }

    // MARK: - Deletion

    @MainActor
    func testDeleteCheatsheetFromSidebarRemovesEverywhere() throws {
        launchApp(sheets: [threePageSheet(name: "Alpha"), threePageSheet(name: "Beta")])
        openCheatsheetsTab()
        selectSheetInSidebar("Alpha")

        settingsWindow.buttons["sheets.remove"].click()
        // Match the confirmation button by label as a query. The label
        // subscript (app.buttons["…"]) also pulls in a non-clickable Touch Bar
        // mirror; a predicate query resolves to just the on-screen button.
        let confirmMatches = app.buttons.matching(NSPredicate(format: "label == %@", "Delete “Alpha”"))
        XCTAssertTrue(confirmMatches.firstMatch.waitForExistence(timeout: 5), "delete confirmation button not found")
        let confirm = confirmMatches.allElementsBoundByIndex.first { $0.isHittable } ?? confirmMatches.firstMatch
        confirm.click()

        waitForState("sheet removed from the store") { $0.sheets.map(\.name) == ["Beta"] }
        XCTAssertFalse(settingsWindow.staticTexts["Alpha"].exists, "sidebar row should be gone")
        XCTAssertFalse(statusMenuItemExists("Alpha"), "status menu entry should be gone")
    }
}

private extension CGSize {
    func equalTo(_ other: CGSize, within tolerance: CGFloat) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

// MARK: - Sync with original files

final class OriginalSyncUITests: CheatsheetUITestCase {
    private func waitForValue(of element: XCUIElement, _ value: String) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5) == .completed
    }

    private func sheetAttachment(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.sheets.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: settingsWindow.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Flipping the General toggle must update file status in the
    /// Cheatsheets tab without any other interaction; a mismatched original
    /// offers a review sheet whose choices work.
    @MainActor
    func testSyncToggleUpdatesStatusAndReviewSheetResolves() throws {
        launchApp(sheets: [SeedSheet(name: "Notes", pages: [.text("todo.md", "- [ ] milk")])])
        openSettings()
        let toggle = settingsWindow.switches["general.syncWithOriginals"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click() // on

        openCheatsheetsTab()
        selectSheetInSidebar("Notes")
        // Seeded files have no original: a "not linked" chain, shown straight away.
        // The menu and its button both carry the identifier.
        let link = settingsWindow.descendants(matching: .any).matching(identifier: "detail.fileLink").firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5), "link status didn't appear after enabling sync")
        XCTAssertTrue(waitForValue(of: link, "notLinked"), "seeded file should be not linked")
        screenshot("1 not linked after enabling sync")

        postDebug("divergeOriginal:Notes")
        XCTAssertTrue(waitForValue(of: link, "needsReview"), "mismatched original should ask for review")
        screenshot("2 review needed")
        link.click()
        let review = app.menuItems["Review Differences…"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), "link menu should offer review")
        review.click()

        let unlink = app.buttons["review.unlink"]
        XCTAssertTrue(unlink.waitForExistence(timeout: 5), "review sheet didn't open")
        // Nothing starts ticked; ticking cards names the outcome.
        let keep = app.buttons["review.keep"]
        XCTAssertTrue(keep.exists)
        XCTAssertFalse(keep.isEnabled, "no version is chosen yet")
        sheetAttachment("3 review sheet")
        let originalCard = app.descendants(matching: .any).matching(identifier: "review.originalCard").firstMatch
        let copyCard = app.descendants(matching: .any).matching(identifier: "review.copyCard").firstMatch
        originalCard.click()
        XCTAssertEqual(keep.label, "Keep Original")
        sheetAttachment("3b original ticked")
        copyCard.click()
        XCTAssertEqual(keep.label, "Keep Both")
        originalCard.click()
        XCTAssertEqual(keep.label, "Keep Copy")

        // Overwriting the original asks first; cancelling keeps the review.
        keep.click()
        let confirm = app.buttons["review.confirmOverwrite"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "overwriting the original should ask first")
        sheetAttachment("3c overwrite confirmation")
        app.typeKey(.escape, modifierFlags: []) // the dialog's Cancel
        XCTAssertTrue(unlink.waitForExistence(timeout: 2), "cancelling should return to the review")

        // Hovering a card offers Quick Look.
        copyCard.hover()
        let preview = app.buttons["review.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 2), "hovering a card should offer a preview")
        preview.click()
        sleep(2)
        let quickLookShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        quickLookShot.name = "3d quick look"
        quickLookShot.lifetime = .keepAlways
        add(quickLookShot)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(unlink.waitForExistence(timeout: 2), "closing Quick Look shouldn't close the review")

        unlink.click()
        XCTAssertTrue(waitForValue(of: link, "notLinked"), "unlinked file should be not linked")

        // Off again: status disappears immediately, without other clicks.
        openSettingsTab("General")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() // off
        openSettingsTab("Cheatsheets")
        XCTAssertTrue(settingsWindow.staticTexts["todo.md"].waitForExistence(timeout: 5))
        XCTAssertFalse(link.exists, "link status should clear as soon as sync is off")
        screenshot("4 sync off")

        // Double-click renames the cheatsheet's copy in place.
        settingsWindow.staticTexts["todo.md"].doubleClick()
        let field = settingsWindow.textFields["detail.renameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "double-click should start renaming")
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Groceries\r")
        XCTAssertTrue(settingsWindow.staticTexts["Groceries.md"].waitForExistence(timeout: 5), "rename should show the new name")
        screenshot("5 renamed")
    }
}
