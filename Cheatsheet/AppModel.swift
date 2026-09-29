import AppKit
import Foundation

nonisolated enum DockIconPolicy: String, CaseIterable, Identifiable {
    case never
    case whenSettingsOpen
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: "Never"
        case .whenSettingsOpen: "While settings are open"
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
    let launcher: LauncherController

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

    /// Opens settings the standard way for a menu bar app: show the Dock
    /// icon (per the Dock setting) before the window appears, bring the app
    /// forward, then open or focus the window. Runs after the current event,
    /// so a menu that triggered it has closed first.
    func openSettings() {
        DispatchQueue.main.async {
            self.openSettingsNow(attemptsLeft: 20)
        }
    }

    private func openSettingsNow(attemptsLeft: Int) {
        isSettingsWindowVisible = true
        NSApp.activate()
        if showSettingsWindow() { return }
        if let openSettingsWindowAction {
            openSettingsWindowAction()
        } else if attemptsLeft > 0 {
            // Very early in launch (a Dock click, a test command) the menu
            // bar hasn't handed over the open-window action yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.openSettingsNow(attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    /// Focuses the settings window if it exists (closed windows are kept).
    @discardableResult
    func showSettingsWindow() -> Bool {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains(WindowID.settings) == true
        }) else { return false }
        // Open on the Space the user is on, not the one it was last shown on.
        window.collectionBehavior.insert(.moveToActiveSpace)
        // makeKeyAndOrderFront doesn't restore a minimized window.
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        #if DEBUG
        if UITestMode.isActive {
            fitSettingsWindowToScreenHeight(window)
        }
        #endif
        window.makeKeyAndOrderFront(nil)
        return true
    }

    #if DEBUG
    /// UI tests: show the whole settings form without scrolling. Synthesized
    /// scroll-until-visible loops were the slowest part of the suite.
    private func fitSettingsWindowToScreenHeight(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        guard frame.height < visible.height else { return }
        frame.origin.y = visible.minY
        frame.size.height = visible.height
        window.setFrame(frame, display: true)
    }
    #endif

    private init() {
        let store = CheatsheetStore()
        let overlay = OverlayController(store: store)
        let launcher = LauncherController(store: store, overlay: overlay)
        let hotkeys = HotkeyManager(store: store, overlay: overlay, launcher: launcher)
        self.store = store
        self.overlay = overlay
        self.hotkeys = hotkeys
        self.launcher = launcher
        launcher.openSettings = { [weak self] in self?.openSettings() }
        store.onChange = { [weak hotkeys, weak overlay, weak launcher, weak store] in
            hotkeys?.sync()
            overlay?.refreshFromStore()
            if let store {
                RecentSheets.prune(keeping: store.sheets)
            }
            launcher?.refresh()
        }
        overlay.onSessionsChanged = { [weak hotkeys] in
            hotkeys?.updatePinShortcutAvailability()
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
        } else if action.hasPrefix("toggleSheet:") {
            // Same call the status-menu button makes; lets UI tests drive the
            // menu action when the status item is crowded out of the menu bar.
            let name = String(action.dropFirst("toggleSheet:".count))
            if let sheet = store.sheets.first(where: { $0.name == name }) {
                overlay.toggle(sheet)
            }
        } else if action.hasPrefix("keyDown:"), let index = Int(action.dropFirst(8)), store.sheets.indices.contains(index) {
            // Global hotkeys (Carbon) can't be synthesized reliably from
            // XCUITest; drive the layer just below them.
            hotkeys.handleKeyDown(sheetID: store.sheets[index].id)
        } else if action.hasPrefix("keyUp:"), let index = Int(action.dropFirst(6)), store.sheets.indices.contains(index) {
            hotkeys.handleKeyUp(sheetID: store.sheets[index].id)
        } else if action.hasPrefix("userResize:") {
            // "userResize:<sheet name>:<dw>:<dh>" in points.
            let parts = action.dropFirst("userResize:".count).split(separator: ":").map(String.init)
            if parts.count == 3, let dw = Double(parts[1]), let dh = Double(parts[2]),
               let session = overlay.sessions.first(where: { $0.sheet.name == parts[0] }) {
                overlay.simulateUserResize(session, by: CGSize(width: dw, height: dh))
            }
        } else if action.hasPrefix("userMove:") {
            // "userMove:<sheet name>:<dx>:<dy>" in AppKit points (+y up).
            let parts = action.dropFirst("userMove:".count).split(separator: ":").map(String.init)
            if parts.count == 3, let dx = Double(parts[1]), let dy = Double(parts[2]),
               let session = overlay.sessions.first(where: { $0.sheet.name == parts[0] }) {
                overlay.simulateUserMove(session, by: CGSize(width: dx, height: dy))
            }
        } else if action.hasPrefix("goToPage:") {
            // "goToPage:<sheet name>:<index>" — what the page buttons call.
            let parts = action.dropFirst("goToPage:".count).split(separator: ":").map(String.init)
            if parts.count == 2, let index = Int(parts[1]),
               let session = overlay.sessions.first(where: { $0.sheet.name == parts[0] }) {
                overlay.goToPage(index, in: session)
            }
        } else if action.hasPrefix("search:") {
            // "search:<sheet name>:<query>" — opens search and sets the query
            // as typing into the field does (the query may contain colons).
            let rest = action.dropFirst("search:".count)
            if let separator = rest.firstIndex(of: ":"),
               let session = overlay.sessions.first(where: { $0.sheet.name == String(rest[..<separator]) }) {
                overlay.openSearch(in: session)
                overlay.setSearchQuery(String(rest[rest.index(after: separator)...]), in: session)
            }
        } else if action.hasPrefix("divergeOriginal:"), UITestMode.isActive {
            // "divergeOriginal:<sheet name>" — links the sheet's first file to
            // a new original with different contents, as if the user picked
            // the wrong file (the open panel can't be driven reliably).
            let name = String(action.dropFirst("divergeOriginal:".count))
            if let sheet = store.sheets.first(where: { $0.name == name }), let file = sheet.files.first {
                let folder = store.rootURL.appendingPathComponent("Originals", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let original = folder.appendingPathComponent(file)
                try? Data("Different contents from Cheatsheet's copy.\n".utf8).write(to: original)
                Task { await store.linkOriginal(original, toFile: file, in: sheet.id) }
            }
        } else if action == "toggleLauncher" {
            // What the search-bar shortcut does (Carbon hotkeys can't be
            // synthesized from XCUITest).
            launcher.toggle()
        } else if action.hasPrefix("deleteSheet:"), UITestMode.isActive {
            // "deleteSheet:<sheet name>" — as the settings Delete button does.
            let name = String(action.dropFirst("deleteSheet:".count))
            if let sheet = store.sheets.first(where: { $0.name == name }) {
                store.delete(sheet)
            }
        } else if action.hasPrefix("addWebPage:"), UITestMode.isActive {
            // "addWebPage:<address>" — a new sheet, as the settings form does.
            let address = String(action.dropFirst("addWebPage:".count))
            if let url = WebLocation.normalizedURL(from: address) {
                store.addSheet(webPages: [WebLocation.Entry(url: url, name: WebLocation.defaultName(for: url))])
            }
        } else if action.hasPrefix("webClick:"), UITestMode.isActive {
            // "webClick:<css selector>" — clicks it in the web page on screen.
            LiveWebPages.clickOnScreen(selector: String(action.dropFirst("webClick:".count)))
        } else if action.hasPrefix("launcherQuery:") {
            // As typing into the search bar does.
            launcher.setQuery(String(action.dropFirst("launcherQuery:".count)))
        } else if action.hasPrefix("state:") {
            postDebugState(nonce: String(action.dropFirst(6)))
        }
    }

    /// Replies to a "state:<nonce>" debug request with a JSON snapshot of app
    /// state the UI test runner can't observe through accessibility alone:
    /// activation policy, window key status, overlay panel frames in AppKit
    /// screen coordinates, and the persisted per-sheet configuration.
    /// Names the cursor on screen, for UI tests (cursors aren't in the
    /// accessibility tree).
    private static func currentCursorName() -> String {
        // Matched by hotspot + size: system cursor images aren't comparable
        // by data (both hands encode to identical-looking TIFFs).
        guard let current = NSCursor.currentSystem else { return "other" }
        let known: [(String, NSCursor)] = [
            ("pointingHand", .pointingHand), ("openHand", .openHand), ("arrow", .arrow), ("iBeam", .iBeam),
        ]
        return known.first { $0.1.hotSpot == current.hotSpot && $0.1.image.size == current.image.size }?.0 ?? "other"
    }

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
            "sheetOpenMethod": SheetOpenMethod.current.rawValue,
            "launcherVisible": launcher.isVisible,
            "launcherResults": launcher.results.map(\.title),
            "launcherSelectedIndex": launcher.selectedIndex,
            "dockIconPolicy": Self.dockIconPolicy.rawValue,
            // Diagnoses "openSettings did nothing": the action is captured by
            // the menu bar label's .task, which may not have run yet.
            "openActionSet": openSettingsWindowAction != nil,
            "windowCount": NSApp.windows.count,
            "cursor": Self.currentCursorName(),
            // Pre-rendered markdown/HTML start pages not currently on screen.
            "warmWebViews": WarmWebViews.cachedCount,
            "liveWebPages": LiveWebPages.debugSummary,
            "webBrowserOpens": LiveWebPages.debugBrowserOpens,
            "warmWebViewsReady": WarmWebViews.readyCount,
            "webRevealMs": WebRevealTiming.lastDelayMs ?? -1,
        ]
        payload["sessions"] = overlay.sessions.map { session -> [String: Any] in
            var info: [String: Any] = [
                "name": session.sheet.name,
                "pageIndex": session.pageIndex,
                "pageCount": session.pages.count,
                "isPinned": session.isPinned,
                "isLoading": session.isLoadingPages,
                "isEditingSearch": overlay.isEditingSearchField(in: session),
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
                "rawFiles": sheet.rawFiles.sorted(),
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
