import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Dock icon clicked with no visible windows: surface the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            AppModel.shared.openSettings()
        }
        return true
    }
}

@main
struct CheatsheetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            menuContent
        } label: {
            Label("Cheatsheet", systemImage: "rectangle.stack")
                .task {
                    // The label exists for the app's lifetime, so its
                    // environment is a safe place to capture openWindow for
                    // non-view callers (Dock reopen, debug driver).
                    AppModel.shared.openSettingsWindowAction = {
                        openWindow(id: WindowID.settings)
                    }
                }
        }

        // Single Window scene: reopening focuses the existing window instead
        // of spawning tabs. Post-close memory retention is handled inside
        // SettingsRootView, which empties its content when the window closes.
        Window("Cheatsheet Settings", id: WindowID.settings) {
            SettingsRootView()
                .environment(model.store)
                .environment(model.overlay)
        }
        .defaultSize(width: 760, height: 520)
    }

    @ViewBuilder
    private var menuContent: some View {
        ForEach(model.store.sheets) { sheet in
            Button(sheet.name) {
                model.overlay.toggle(sheet)
            }
        }
        if !model.store.sheets.isEmpty {
            Divider()
        }
        Button("Settings…") {
            openWindow(id: WindowID.settings)
            // Activation from a menu bar extra races window creation; retry
            // until the window exists and is key.
            AppModel.shared.focusSettingsSoon()
        }
        Divider()
        Button("Quit Cheatsheet") {
            NSApp.terminate(nil)
        }
    }
}

enum WindowID {
    static let settings = "settings"
}
