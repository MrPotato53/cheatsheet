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

        // The status menu lists the seeded sheet and the fixed items.
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "menu bar status item never appeared")
        statusItem.click()
        XCTAssertTrue(app.menuItems["Alpha"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Settings…"].exists)
        XCTAssertTrue(app.menuItems["Quit Cheatsheet"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testLaunchPerformance() throws {
        // Hermetic even for the perf launches: never read the real library.
        let application = XCUIApplication()
        application.launchEnvironment["CHEATSHEET_TEST_RUN"] = UUID().uuidString
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            application.launch()
        }
        application.terminate()
    }
}
