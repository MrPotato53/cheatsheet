import AppKit
import SwiftUI

nonisolated struct LauncherResult: Identifiable {
    enum Item {
        case sheet(Cheatsheet)
        /// Opens settings, so it's reachable without the menu bar icon.
        case settings
    }

    static let settingsTitle = "Settings"

    let item: Item
    /// Nil for sheets listed before anything is typed.
    let match: SheetNameMatcher.Match?

    var id: String {
        switch item {
        case .sheet(let sheet): sheet.id.uuidString
        case .settings: "settings"
        }
    }

    var title: String {
        switch item {
        case .sheet(let sheet): sheet.name
        case .settings: Self.settingsTitle
        }
    }

    var sheet: Cheatsheet? {
        if case .sheet(let sheet) = item { return sheet }
        return nil
    }

    /// Typed-query results: sheets and the Settings item ranked together
    /// by name. Settings goes last into the ranking, so on an equal match
    /// (a sheet named "Settings") the sheet comes first.
    static func ranked(sheets: [Cheatsheet], query: String) -> [LauncherResult] {
        let names = sheets.map(\.name) + [settingsTitle]
        return SheetNameMatcher.rank(names: names, query: query).map { ranked in
            let item: Item = sheets.indices.contains(ranked.index) ? .sheet(sheets[ranked.index]) : .settings
            return LauncherResult(item: item, match: ranked.match)
        }
    }
}

/// The Spotlight-style cheatsheet search bar: type to filter sheets by name,
/// ↑/↓ to move, Return to open, Escape to clear then close. Closes when it
/// loses focus or on a click anywhere else.
@Observable
@MainActor
final class LauncherController {
    private let store: CheatsheetStore
    private let overlay: OverlayController

    private(set) var query = ""
    private(set) var results: [LauncherResult] = []
    var selectedIndex = 0
    /// Bumped on every show so the field takes focus again.
    private(set) var focusRequest = 0
    /// Set by AppModel: opening settings is app-level, not the launcher's.
    @ObservationIgnored var openSettings: () -> Void = {}

    @ObservationIgnored private let panel = LauncherPanel()
    /// Top edge on screen; the panel grows and shrinks downward from it.
    @ObservationIgnored private var anchorTop: CGFloat = 0
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var resignKeyObserver: NSObjectProtocol?

    var isVisible: Bool { panel.isVisible }

    init(store: CheatsheetStore, overlay: OverlayController) {
        self.store = store
        self.overlay = overlay
        panel.keyHandler = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        panel.contentView = NSHostingView(rootView: LauncherView(controller: self))
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard !isVisible else { return }
        setQuery("")
        position()
        panel.orderFrontRegardless()
        panel.makeKey()
        focusRequest += 1
        startWatchingForDismissal()
    }

    func hide() {
        guard isVisible else { return }
        stopWatchingForDismissal()
        panel.orderOut(nil)
        setQuery("")
    }

    func setQuery(_ newQuery: String) {
        query = newQuery
        results = currentResults()
        selectedIndex = 0
        resize()
    }

    /// The library changed while the bar is open (a sheet deleted, renamed,
    /// imported): re-run the query, keeping the selected sheet selected.
    func refresh() {
        guard isVisible else { return }
        let selectedID = results.indices.contains(selectedIndex) ? results[selectedIndex].id : nil
        results = currentResults()
        selectedIndex = results.firstIndex { $0.id == selectedID } ?? 0
        resize()
    }

    func open(_ result: LauncherResult) {
        switch result.item {
        case .sheet(let sheet):
            open(sheet)
        case .settings:
            hide()
            openSettings()
        }
    }

    /// Opens the library's current version of the sheet; one deleted since
    /// the list was built isn't opened.
    func open(_ sheet: Cheatsheet) {
        guard let current = store.sheets.first(where: { $0.id == sheet.id }) else {
            refresh()
            return
        }
        hide()
        overlay.show(current)
    }

    private func currentResults() -> [LauncherResult] {
        let sheets = store.sheets
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return LauncherEmptyState.sheets(for: .current, library: sheets, recentIDs: RecentSheets.ids)
                .map { LauncherResult(item: .sheet($0), match: nil) }
        }
        return LauncherResult.ranked(sheets: sheets, query: query)
    }

    // MARK: - Keys

    private enum KeyCode {
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let escape: UInt16 = 53
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyCode.downArrow:
            moveSelection(by: 1)
            return true
        case KeyCode.upArrow:
            moveSelection(by: -1)
            return true
        case KeyCode.returnKey, KeyCode.keypadEnter:
            if results.indices.contains(selectedIndex) {
                open(results[selectedIndex])
            }
            return true
        case KeyCode.escape:
            // Like Spotlight: the first Escape clears the query.
            if query.isEmpty {
                hide()
            } else {
                setQuery("")
            }
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    // MARK: - Geometry

    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        anchorTop = visible.maxY - visible.height * LauncherLayout.topFraction
        let height = LauncherLayout.height(resultCount: results.count)
        panel.setFrame(
            NSRect(x: visible.midX - LauncherLayout.width / 2, y: anchorTop - height, width: LauncherLayout.width, height: height),
            display: false
        )
    }

    private func resize() {
        guard isVisible else { return }
        let height = LauncherLayout.height(resultCount: results.count)
        var frame = panel.frame
        frame.origin.y = anchorTop - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    // MARK: - Dismissal

    /// Losing focus closes it, and so does a click in another app or on the
    /// desktop (which doesn't always take focus from a non-activating panel).
    private func startWatchingForDismissal() {
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
    }

    private func stopWatchingForDismissal() {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        resignKeyObserver = nil
        clickMonitor = nil
    }
}
