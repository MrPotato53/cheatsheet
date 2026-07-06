import AppKit
import Foundation

nonisolated enum DockIconPolicy: String, CaseIterable, Identifiable {
    case never
    case whenSettingsOpen
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: "No Dock icon"
        case .whenSettingsOpen: "Only while settings is open"
        case .always: "Always"
        }
    }
}

@MainActor
final class AppModel {
    static let shared = AppModel()

    let store: CheatsheetStore
    let overlay: OverlayController
    let hotkeys: HotkeyManager

    /// Tracked by SettingsRootView via window notifications.
    var isSettingsWindowVisible = false {
        didSet { applyDockIconPolicy() }
    }

    static var dockIconPolicy: DockIconPolicy {
        DockIconPolicy(rawValue: UserDefaults.standard.string(forKey: "dockIconPolicy") ?? "") ?? .whenSettingsOpen
    }

    func applyDockIconPolicy() {
        let showDock: Bool
        switch Self.dockIconPolicy {
        case .never: showDock = false
        case .always: showDock = true
        case .whenSettingsOpen: showDock = isSettingsWindowVisible
        }
        let target: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        // Policy switches can deactivate the app; keep settings focused.
        if isSettingsWindowVisible {
            NSApp.activate()
        }
    }

    /// Captured from the menu bar label's environment so non-view code (Dock
    /// reopen, debug driver) can open the settings scene.
    var openSettingsWindowAction: (() -> Void)?

    func openSettings() {
        if !showSettingsWindow() {
            openSettingsWindowAction?()
        }
        focusSettingsSoon()
    }

    /// Window creation is asynchronous; retry focusing until it exists.
    func focusSettingsSoon() {
        Task { @MainActor in
            for _ in 0..<10 {
                if self.showSettingsWindow() { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    @discardableResult
    func showSettingsWindow() -> Bool {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains(WindowID.settings) == true
        }) else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return true
    }

    private init() {
        let store = CheatsheetStore()
        let overlay = OverlayController(store: store)
        let hotkeys = HotkeyManager(store: store, overlay: overlay)
        self.store = store
        self.overlay = overlay
        self.hotkeys = hotkeys
        store.onChange = { [weak hotkeys, weak overlay] in
            hotkeys?.sync()
            overlay?.refreshFromStore()
        }
        hotkeys.sync()
        // Deferred: NSApp isn't fully set up during App init.
        Task { @MainActor in
            self.applyDockIconPolicy()
            self.overlay.warmStartPages()
        }
        #if DEBUG
        setUpDebugDriver()
        #endif
    }

    #if DEBUG
    /// Test hook: lets scripts drive the app for memory studies, e.g.
    ///   action "show:0", "hide", "openSettings", "closeSettings"
    /// posted as distributed notifications named potatodev.cheatsheet.debug.
    private func setUpDebugDriver() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("potatodev.cheatsheet.debug"),
            object: nil,
            queue: .main
        ) { notification in
            let action = (notification.object as? String) ?? ""
            Task { @MainActor in
                AppModel.shared.handleDebugAction(action)
            }
        }
    }

    private func handleDebugAction(_ action: String) {
        if action.hasPrefix("show:"), let index = Int(action.dropFirst(5)), store.sheets.indices.contains(index) {
            overlay.show(store.sheets[index])
        } else if action == "hide" {
            for session in overlay.sessions {
                overlay.hide(session)
            }
        } else if action == "openSettings" {
            openSettings()
        } else if action == "closeSettings" {
            NSApp.windows.first {
                $0.identifier?.rawValue.contains(WindowID.settings) == true
            }?.performClose(nil)
        }
    }
    #endif
}
