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
        DockIconPolicy(rawValue: AppDefaults.store.string(forKey: "dockIconPolicy") ?? "") ?? .whenSettingsOpen
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

    /// Window creation is asynchronous; retry focusing until it exists. The
    /// budget is generous (≈3s) because the very first settings open on a cold
    /// launch can take well over half a second to materialize the scene, and
    /// giving up early leaves the window open but unfocused.
    func focusSettingsSoon() {
        Task { @MainActor in
            for _ in 0..<60 {
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
        // makeKeyAndOrderFront does not restore a minimized window, so a Dock
        // click or menu "Settings…" would otherwise leave it stuck in the Dock.
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
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
    ///
    /// Under UI tests the runner appends "@@<runID>" so only the app it
    /// launched acts on a command — a foreign DEBUG instance (a developer's
    /// app, or another test's app) sharing this broadcast channel ignores it.
    private func setUpDebugDriver() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("potatodev.cheatsheet.debug"),
            object: nil,
            queue: .main
        ) { notification in
            let raw = (notification.object as? String) ?? ""
            Task { @MainActor in
                AppModel.shared.handleDebugAction(raw)
            }
        }
    }

    private func handleDebugAction(_ raw: String) {
        let action: String
        if UITestMode.isActive {
            // Test posts are run-scoped ("command@@runID"); accept only ours.
            let parts = raw.components(separatedBy: "@@")
            guard parts.count == 2, parts[1] == UITestMode.runID else { return }
            action = parts[0]
        } else {
            // Memory-study scripts drive a normally-launched app with bare
            // commands; run-scoped test posts don't match and are ignored.
            action = raw
        }
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
        } else if action == "minimizeSettings" {
            NSApp.windows.first {
                $0.identifier?.rawValue.contains(WindowID.settings) == true
            }?.miniaturize(nil)
        } else if action == "dockReopen" {
            // Exercises the Dock-click delegate path without LaunchServices.
            // Mirrors AppKit's notion of "visible windows": ordinary windows
            // only — panels (overlays) and the status item's window excluded.
            let hasVisibleWindows = NSApp.windows.contains {
                $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain
            }
            // Invoke the *installed* delegate, not our concrete AppDelegate:
            // under the SwiftUI lifecycle NSApp.delegate is SwiftUI's own
            // delegate (which forwards to AppDelegate), so `as? AppDelegate`
            // is nil. Calling through it reproduces a real reopen faithfully.
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: hasVisibleWindows)
        } else if action.hasPrefix("keyDown:"), let index = Int(action.dropFirst(8)), store.sheets.indices.contains(index) {
            // Global hotkeys (Carbon) can't be synthesized reliably from
            // XCUITest; drive the layer just below them.
            hotkeys.handleKeyDown(sheetID: store.sheets[index].id)
        } else if action.hasPrefix("keyUp:"), let index = Int(action.dropFirst(6)), store.sheets.indices.contains(index) {
            hotkeys.handleKeyUp(sheetID: store.sheets[index].id)
        } else if action.hasPrefix("state:") {
            postDebugState(nonce: String(action.dropFirst(6)))
        }
    }

    /// Replies to a "state:<nonce>" debug request with a JSON snapshot of app
    /// state the UI test runner can't observe through accessibility alone:
    /// activation policy, window key status, overlay panel frames in AppKit
    /// screen coordinates, and the persisted per-sheet configuration.
    private func postDebugState(nonce: String) {
        func rect(_ r: NSRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }

        let settingsWindows = NSApp.windows.filter {
            $0.identifier?.rawValue.contains(WindowID.settings) == true
        }
        var payload: [String: Any] = [
            "nonce": nonce,
            // Scopes the reply to the launch that requested it. Another DEBUG
            // instance on the machine (e.g. an app run straight from Xcode)
            // also answers this distributed channel; without a run tag its
            // empty snapshot races and clobbers the real one. The runner
            // filters on this, so foreign replies are ignored.
            "runID": UITestMode.runID ?? "",
            "activationPolicy": NSApp.activationPolicy() == .regular ? "regular" : "accessory",
            "appIsActive": NSApp.isActive,
            "settingsWindowCount": settingsWindows.count,
            "settingsVisible": settingsWindows.contains { $0.isVisible },
            "settingsMiniaturized": settingsWindows.contains { $0.isMiniaturized },
            "settingsIsKey": settingsWindows.contains { $0.isKeyWindow },
            "dismissWithEsc": AppDefaults.store.object(forKey: "dismissWithEsc") as? Bool ?? true,
            "dockIconPolicy": Self.dockIconPolicy.rawValue,
        ]
        payload["sessions"] = overlay.sessions.map { session -> [String: Any] in
            var info: [String: Any] = [
                "name": session.sheet.name,
                "pageIndex": session.pageIndex,
                "pageCount": session.pages.count,
                "isPinned": session.isPinned,
                "isLoading": session.isLoadingPages,
                "isVisible": session.panel.isVisible,
                "isKey": session.panel.isKeyWindow,
                "isMovable": session.panel.isMovableByWindowBackground,
                "isResizable": session.panel.styleMask.contains(.resizable),
                "frame": rect(session.panel.frame),
            ]
            if let visible = (session.panel.screen ?? session.screen)?.visibleFrame {
                info["screenVisibleFrame"] = rect(visible)
            }
            return info
        }
        payload["sheets"] = store.sheets.map { sheet -> [String: Any] in
            let startPage: String
            switch sheet.startPage {
            case .first: startPage = "first"
            case .lastViewed: startPage = "lastViewed"
            case .fixed(let index): startPage = "fixed:\(index)"
            }
            return [
                "name": sheet.name,
                "previewScale": sheet.previewScale,
                "position": [sheet.position.x, sheet.position.y],
                "dragBehavior": sheet.dragBehavior.rawValue,
                "resizeBehavior": sheet.resizeBehavior.rawValue,
                "activation": sheet.activation.rawValue,
                "startPage": startPage,
                "keepsStartPageLoaded": sheet.keepsStartPageLoaded,
                "fileCount": sheet.files.count,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("potatodev.cheatsheet.debug.state"),
            object: String(data: data, encoding: .utf8),
            userInfo: nil,
            deliverImmediately: true
        )
    }
    #endif
}
