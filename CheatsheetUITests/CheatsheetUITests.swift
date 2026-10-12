import XCTest

/// Launch smoke tests: the app is a menu-bar-only accessory until settings
/// opens, and starts with no windows.
final class LaunchUITests: CheatsheetUITestCase {
    @MainActor
    func testLaunchesAsMenuBarOnlyAccessory() throws {
        launchApp(sheets: [SeedSheet(name: "Alpha", pages: [.image("one.png", width: 800, height: 600)])])

        waitForState(timeout: 5, "accessory policy and no windows at launch") { state in
            state.activationPolicy == "accessory" && !state.settingsVisible && state.sessions.isEmpty
        }
        XCTAssertFalse(settingsWindow.exists, "settings window should not open at launch")

        // The status menu lists the seeded sheet and the fixed items. On a
        // crowded menu bar macOS gives the item no clickable position, so the
        // menu-content check is only possible when it's actually clickable.
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "menu bar status item never appeared")
        guard statusItem.isHittable else { return }
        statusItem.click()
        XCTAssertTrue(app.menuItems["Alpha"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Settings…"].exists)
        XCTAssertTrue(app.menuItems["Quit Cheatsheet"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testLaunchPerformance() throws {
        // TODO: re-enable once XCTApplicationLaunchMetric is reliable here.
        // It intermittently records no metric for a launch iteration ("0 in
        // iteration with index N") for this windowless accessory app, on the
        // unchanged code too (seen 2026-10-11, macOS 26.5.1); waiting for the
        // previous instance to exit between iterations didn't help.
        try XCTSkipIf(true, "XCTApplicationLaunchMetric intermittently records no launch for this app")
        // Hermetic even for the perf launches: never read the real library.
        let application = XCUIApplication()
        application.launchEnvironment["CHEATSHEET_TEST_RUN"] = UUID().uuidString
        // Terminate inside each iteration: relaunching a still-running app
        // records no launch metric, failing every iteration after the first.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            application.launch()
            application.terminate()
        }
    }
}
