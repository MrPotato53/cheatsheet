import AppKit
import SwiftUI

@main
struct CheatsheetApp: App {
    private let model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("Cheatsheet", systemImage: "rectangle.stack") {
            menuContent
        }

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
            NSApp.activate()
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
