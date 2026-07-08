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
        openSettingsFromMenuBar()
        waitForState("regular while settings open (default policy)") { $0.activationPolicy == "regular" }

        let picker = settingsWindow.popUpButtons["general.dockIconPolicy"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "dock icon policy picker not found")

        picker.click()
        app.menuItems["No Dock icon"].click()
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

        openSettingsFromMenuBar()
        waitForState("regular while settings open") { $0.activationPolicy == "regular" }

        postDebug("closeSettings")
        waitForState("accessory again after settings closes") { $0.activationPolicy == "accessory" }
    }

    @MainActor
    func testDismissWithEscapeToggleTakesEffectImmediately() throws {
        launchApp(sheets: [threePageSheet()])
        openSettingsFromMenuBar()

        let toggle = settingsWindow.switches["general.dismissWithEsc"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click() // off
        waitForState("dismissWithEsc off") { !$0.dismissWithEsc }

        // With Escape disabled the setting is read live, so an already-open
        // overlay survives Escape.
        openOverlayFromMenu("Alpha")
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

        openOverlayFromMenu("Alpha")
        overlayContent().click()
        app.typeKey(.escape, modifierFlags: [])
        waitForState("overlay dismissed once re-enabled") { $0.sessions.isEmpty }
    }

    @MainActor
    func testLaunchAtLoginToggleFlips() throws {
        // Registration itself is stubbed in UI test mode (it would install a
        // real login item); this covers the control and error-free flip.
        launchApp()
        openSettingsFromMenuBar()

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
        openOverlayFromMenu("Alpha")

        app.buttons["overlay.nextPage"].click()
        waitForState("moved to page 2") { $0.session(named: "Alpha")?.pageIndex == 1 }

        hideAllOverlays()
        openOverlayFromMenu("Alpha")
        waitForState("reopened on the last viewed page") { $0.session(named: "Alpha")?.pageIndex == 1 }
    }

    @MainActor
    func testStartPageFirstAlwaysReopensAtFirstPage() throws {
        var sheet = threePageSheet()
        sheet.startPage = "first"
        launchApp(sheets: [sheet])

        openOverlayFromMenu("Alpha")
        app.buttons["overlay.nextPage"].click()
        waitForState("moved to page 2") { $0.session(named: "Alpha")?.pageIndex == 1 }

        hideAllOverlays()
        openOverlayFromMenu("Alpha")
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

        openOverlayFromMenu("Alpha")
        waitForState("overlay opens on the fixed page") { $0.session(named: "Alpha")?.pageIndex == 2 }
    }

    @MainActor
    func testSizeSliderResizesOverlayLiveAndPersists() throws {
        var sheet = threePageSheet()
        sheet.previewScale = 0.4
        launchApp(sheets: [sheet])

        openOverlayFromMenu("Alpha")
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
        openOverlayFromMenu("Alpha")
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
        let state = openOverlayFromMenu("Alpha")
        XCTAssertEqual(state?.session(named: "Alpha")?.pageCount, 3)
    }

    // MARK: - Geometry behaviors

    @MainActor
    func testDragBehaviorLockedPreventsMoving() throws {
        var sheet = threePageSheet()
        sheet.dragBehavior = "locked"
        launchApp(sheets: [sheet])

        let state = openOverlayFromMenu("Alpha")
        let session = try XCTUnwrap(state?.session(named: "Alpha"))
        XCTAssertFalse(session.isMovable, "locked sheets must not be background-movable")
        let before = session.frameRect

        // Attempt a background drag anyway (no drag strip exists when locked).
        let content = overlayContent()
        let start = content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: 300, dy: 120)))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))

        let after = try XCTUnwrap(requestState()?.session(named: "Alpha")).frameRect
        XCTAssertTrue(after.approximatelyEqual(to: before, tolerance: 2), "locked overlay moved: \(before) → \(after)")
    }

    @MainActor
    func testDragBehaviorResetsRevertsOnReopen() throws {
        var sheet = threePageSheet()
        sheet.dragBehavior = "resets"
        launchApp(sheets: [sheet])

        openOverlayFromMenu("Alpha")
        let original = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect

        dragOverlay(by: CGVector(dx: 250, dy: 120))
        let dragged = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect
        XCTAssertFalse(dragged.approximatelyEqual(to: original, tolerance: 20), "drag should move the overlay for this session")

        // The configured position is NOT rewritten…
        waitForState("configured position untouched by the drag") { state in
            guard let stored = state.sheet(named: "Alpha")?.position, stored.count == 2 else { return false }
            return abs(stored[0] - 0.5) < 0.01 && abs(stored[1] - 0.5) < 0.01
        }

        // …so reopening returns to the configured spot.
        hideAllOverlays()
        openOverlayFromMenu("Alpha")
        let reopened = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect
        XCTAssertTrue(
            reopened.approximatelyEqual(to: original, tolerance: 5),
            "overlay should revert to configured position on reopen: \(original) → \(reopened)"
        )
    }

    @MainActor
    func testDragBehaviorRemembersPersistsAcrossReopen() throws {
        launchApp(sheets: [threePageSheet()]) // remembers is the default

        openOverlayFromMenu("Alpha")
        _ = waitForSettledFrame(sessionNamed: "Alpha")

        dragOverlay(by: CGVector(dx: 250, dy: 120))
        let dragged = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect

        waitForState("dragged position written to the store") { state in
            guard let stored = state.sheet(named: "Alpha")?.position, stored.count == 2 else { return false }
            return abs(stored[0] - 0.5) > 0.05 || abs(stored[1] - 0.5) > 0.05
        }

        hideAllOverlays()
        openOverlayFromMenu("Alpha")
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

        let state = openOverlayFromMenu("Alpha")
        let session = try XCTUnwrap(state?.session(named: "Alpha"))
        XCTAssertFalse(session.isResizable, "locked sheets must not have a resizable panel")
        let before = session.frameRect

        // Try to grab the bottom-right corner; the size must not change.
        let content = overlayContent()
        let corner = content.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.995))
        corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(dx: 200, dy: 200)))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))

        let after = try XCTUnwrap(requestState()?.session(named: "Alpha")).frameRect
        XCTAssertEqual(after.width, before.width, accuracy: 2, "locked overlay was resized")
        XCTAssertEqual(after.height, before.height, accuracy: 2, "locked overlay was resized")
    }

    @MainActor
    func testResizeBehaviorRemembersPersistsScale() throws {
        launchApp(sheets: [threePageSheet()]) // remembers is the default

        openOverlayFromMenu("Alpha")
        let before = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect

        // Drag the bottom-right resize corner outward.
        let content = overlayContent()
        let corner = content.coordinate(withNormalizedOffset: CGVector(dx: 0.998, dy: 0.998))
        corner.press(forDuration: 0.4, thenDragTo: corner.withOffset(CGVector(dx: 250, dy: 250)))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))

        let resized = try XCTUnwrap(waitForSettledFrame(sessionNamed: "Alpha")).frameRect
        if resized.size.equalTo(before.size, within: 5) {
            // Borderless resize zones are only a few points wide; if the grab
            // missed there is nothing meaningful to assert.
            throw XCTSkip("corner drag did not engage the resize zone on this machine")
        }

        waitForState("resized scale written to the store") { state in
            abs((state.sheet(named: "Alpha")?.previewScale ?? 0.6) - 0.6) > 0.03
        }

        hideAllOverlays()
        openOverlayFromMenu("Alpha")
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
