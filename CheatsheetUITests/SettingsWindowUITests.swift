import XCTest

/// Settings window lifecycle: opening from the menu bar, refocusing an
/// already-open window from both the menu bar and the Dock icon, and opening
/// from a Dock click when no windows are visible.
final class SettingsWindowUITests: CheatsheetUITestCase {
    @MainActor
    func testSettingsOpensFromMenuBar() throws {
        launchApp()

        openSettingsFromMenuBar()

        waitForState("settings window visible and focused") { state in
            state.settingsVisible && state.settingsIsKey && state.appIsActive
        }
        // Default Dock policy ("only while settings is open") kicks in.
        waitForState("dock icon appears while settings is open") { $0.activationPolicy == "regular" }
    }

    @MainActor
    func testMenuBarRefocusesExistingSettingsWindow() throws {
        launchApp()
        openSettingsFromMenuBar()
        waitForState("settings focused after first open") { $0.settingsIsKey }

        deactivateApp()

        openSettingsFromMenuBar()
        waitForState("existing settings window refocused, no second window") { state in
            state.settingsIsKey && state.settingsVisible && state.settingsWindowCount == 1
        }
    }

    @MainActor
    func testDockReopenOpensSettingsWhenNoWindowsVisible() throws {
        // Dock icon always visible so there is a Dock icon to "click".
        launchApp(defaults: ["dockIconPolicy": "always"])
        waitForState("dock icon shown under Always policy") { $0.activationPolicy == "regular" }
        XCTAssertFalse(settingsWindow.exists, "settings must start closed for this test")

        reopenFromDock()

        waitForState(timeout: 10, "settings opened and focused by Dock reopen") { state in
            state.settingsVisible && state.settingsIsKey
        }
    }

    @MainActor
    func testDockReopenRefocusesOpenSettingsWindow() throws {
        launchApp(defaults: ["dockIconPolicy": "always"])
        openSettingsFromMenuBar()
        waitForState("settings open") { $0.settingsVisible }

        deactivateApp()

        reopenFromDock()

        waitForState(timeout: 10, "settings refocused by Dock reopen, no second window") { state in
            state.settingsIsKey && state.settingsWindowCount == 1
        }
    }

    @MainActor
    func testReopenDelegateOpensSettingsWithoutLaunchServices() throws {
        // Same delegate path as a Dock click, driven directly via the debug
        // channel — deterministic even where LaunchServices is flaky (CI).
        launchApp()

        postDebug("dockReopen")

        waitForState("settings opened via reopen delegate") { $0.settingsVisible }
    }

    @MainActor
    func testCloseSettingsDropsDockIconAndReopensCleanly() throws {
        launchApp() // default policy: dock icon only while settings is open
        openSettingsFromMenuBar()
        waitForState("regular policy while open") { $0.activationPolicy == "regular" }

        postDebug("closeSettings")
        waitForState("accessory policy after close") { state in
            !state.settingsVisible && state.activationPolicy == "accessory"
        }

        openSettingsFromMenuBar()
        waitForState("settings reopens after close, single window") { state in
            state.settingsVisible && state.settingsWindowCount == 1
        }
    }
}
