import AppKit
import XCTest

// MARK: - Seed fixtures
// Mirrors UITestSeeder's spec in the app target. The app is sandboxed, so the
// runner describes fixtures as JSON and the app generates the actual media
// files inside its container at launch.

struct SeedPage {
    var file: String
    var width: Int?
    var height: Int?
    var text: String?

    static func image(_ file: String, width: Int, height: Int) -> SeedPage {
        SeedPage(file: file, width: width, height: height, text: nil)
    }

    static func text(_ file: String, _ content: String) -> SeedPage {
        SeedPage(file: file, width: nil, height: nil, text: content)
    }

    var json: [String: Any] {
        var dict: [String: Any] = ["file": file]
        if let width { dict["width"] = width }
        if let height { dict["height"] = height }
        if let text { dict["text"] = text }
        return dict
    }
}

struct SeedSheet {
    var name: String
    var pages: [SeedPage]
    var previewScale: Double = 0.6
    var activation = "toggle"
    var dragBehavior = "remembers"
    var resizeBehavior = "remembers"
    /// "first" | "lastViewed" | "fixed:<index>"
    var startPage = "lastViewed"
    var keepsStartPageLoaded = false
    var position: (x: Double, y: Double) = (0.5, 0.5)

    var json: [String: Any] {
        [
            "name": name,
            "pages": pages.map(\.json),
            "previewScale": previewScale,
            "activation": activation,
            "dragBehavior": dragBehavior,
            "resizeBehavior": resizeBehavior,
            "startPage": startPage,
            "keepsStartPageLoaded": keepsStartPageLoaded,
            "position": ["x": position.x, "y": position.y],
        ]
    }
}

// MARK: - App state snapshot
// Decoded from the JSON the app posts on the debug state channel. Frames are
// AppKit screen coordinates (origin bottom-left, +y up) — unlike the
// accessibility coordinates XCUITest uses for hit-testing.

struct AppState: Decodable {
    struct Session: Decodable {
        let name: String
        let pageIndex: Int
        let pageCount: Int
        let isPinned: Bool
        let isLoading: Bool
        let isVisible: Bool
        let isKey: Bool
        let isMovable: Bool
        let isResizable: Bool
        let frame: [Double]
        let screenVisibleFrame: [Double]?

        var frameRect: CGRect { Self.rect(frame) }
        var visibleRect: CGRect? { screenVisibleFrame.map(Self.rect) }

        private static func rect(_ values: [Double]) -> CGRect {
            guard values.count == 4 else { return .zero }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
    }

    struct Sheet: Decodable {
        let name: String
        let previewScale: Double
        let position: [Double]
        let dragBehavior: String
        let resizeBehavior: String
        let activation: String
        let startPage: String
        let keepsStartPageLoaded: Bool
        let fileCount: Int
    }

    let nonce: String
    /// The CHEATSHEET_TEST_RUN the responding app was launched with. Empty for
    /// a foreign DEBUG instance (e.g. one run from Xcode); the runner drops any
    /// reply whose runID isn't the one it launched.
    let runID: String
    let activationPolicy: String
    let appIsActive: Bool
    let settingsWindowCount: Int
    let settingsVisible: Bool
    let settingsMiniaturized: Bool
    let settingsIsKey: Bool
    let dismissWithEsc: Bool
    let dockIconPolicy: String
    let sessions: [Session]
    let sheets: [Sheet]

    func session(named name: String) -> Session? { sessions.first { $0.name == name } }
    func sheet(named name: String) -> Sheet? { sheets.first { $0.name == name } }
}

// MARK: - Base test case

class CheatsheetUITestCase: XCTestCase {
    static let bundleID = "potatodev.Cheatsheet"

    private(set) var app: XCUIApplication!
    /// The run identifier passed to the app under test. State replies are
    /// filtered to this so a foreign DEBUG instance on the machine can't
    /// pollute the snapshot (its replies carry a different, or empty, runID).
    private var runID: String?
    private let debugChannel = Notification.Name("potatodev.cheatsheet.debug")
    private let stateChannel = Notification.Name("potatodev.cheatsheet.debug.state")

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning {
            app.terminate()
        }
        app = nil
    }

    // MARK: Launch

    @discardableResult
    func launchApp(sheets: [SeedSheet] = [], defaults: [String: Any] = [:]) -> XCUIApplication {
        clearSavedWindowState()
        let application = XCUIApplication()
        let runID = UUID().uuidString
        self.runID = runID
        application.launchEnvironment["CHEATSHEET_TEST_RUN"] = runID
        if !sheets.isEmpty {
            application.launchEnvironment["CHEATSHEET_TEST_SEED"] = Self.jsonString(sheets.map(\.json))
        }
        if !defaults.isEmpty {
            application.launchEnvironment["CHEATSHEET_TEST_DEFAULTS"] = Self.jsonString(defaults)
        }
        application.launch()
        app = application
        // Readiness probe: the app answering on the debug state channel means
        // launch (and seeding) completed — more reliable than waiting on the
        // status item's accessibility exposure.
        let deadline = Date(timeIntervalSinceNow: 15)
        var ready = false
        while !ready, Date() < deadline {
            ready = requestState(timeout: 1) != nil
        }
        XCTAssertTrue(ready, "app never responded on the debug state channel")
        return application
    }

    /// Window restoration would reopen last session's settings window and
    /// contaminate the next test's "no windows at launch" state.
    private func clearSavedWindowState() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in [
            "Library/Saved Application State/\(Self.bundleID).savedState",
            "Library/Containers/\(Self.bundleID)/Data/Library/Saved Application State/\(Self.bundleID).savedState",
        ] {
            try? FileManager.default.removeItem(at: home.appendingPathComponent(path))
        }
    }

    static func jsonString(_ object: Any) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object),
            let string = String(data: data, encoding: .utf8)
        else {
            fatalError("unencodable seed fixture")
        }
        return string
    }

    // MARK: Menu bar

    var statusItem: XCUIElement { app.statusItems.firstMatch }

    func clickStatusMenuItem(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "menu bar status item not found", file: file, line: line)
        statusItem.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "menu item '\(title)' not found", file: file, line: line)
        item.click()
    }

    func statusMenuItemExists(_ title: String) -> Bool {
        statusItem.click()
        let exists = app.menuItems[title].waitForExistence(timeout: 2)
        // Dismiss menu tracking without triggering anything.
        app.typeKey(.escape, modifierFlags: [])
        return exists
    }

    // MARK: Settings window

    var settingsWindow: XCUIElement { app.windows["Cheatsheet Settings"] }

    func openSettingsFromMenuBar(file: StaticString = #filePath, line: UInt = #line) {
        clickStatusMenuItem("Settings…", file: file, line: line)
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5), "settings window did not open", file: file, line: line)
    }

    /// A plain SwiftUI TabView exposes its tabs as radio buttons on macOS;
    /// fall back to plain buttons in case the representation changes.
    func openSettingsTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let radio = settingsWindow.radioButtons[name]
        if radio.waitForExistence(timeout: 2) {
            radio.click()
            return
        }
        let button = settingsWindow.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 2), "settings tab '\(name)' not found", file: file, line: line)
        button.click()
    }

    func openCheatsheetsTab(file: StaticString = #filePath, line: UInt = #line) {
        openSettingsFromMenuBar(file: file, line: line)
        openSettingsTab("Cheatsheets", file: file, line: line)
    }

    func selectSheetInSidebar(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = settingsWindow.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "sidebar row '\(name)' not found", file: file, line: line)
        row.click()
    }

    /// Scrolls the settings form until the element is hittable. The detail
    /// form is taller than the window, so most controls below "Documents"
    /// need this before interacting.
    func scrollIntoView(
        _ element: XCUIElement,
        in container: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // The grouped Form is backed by an inner NSScrollView; a scroll gesture
        // on the window itself doesn't move it (verified — the wheel has to
        // land on the scroll view). Target the tallest scroll view in the
        // container, which is the detail form's own scroller.
        let scroller = container.scrollViews.allElementsBoundByIndex
            .max { $0.frame.height < $1.frame.height } ?? container
        scroller.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        // Require the element to be *fully* within the viewport, not merely
        // center-hittable: a control clipped at the bottom edge (e.g. the drag
        // preview) is hittable at its center yet a drag off it exits the
        // scroll view. Fall back to plain hittability for elements taller than
        // the viewport, which can never be fully contained.
        let margin: CGFloat = 12
        func settled() -> Bool {
            guard element.exists, element.isHittable else { return false }
            let e = element.frame, s = scroller.frame
            if e.height >= s.height - margin * 2 { return true }
            return e.minY >= s.minY + margin && e.maxY <= s.maxY - margin
        }
        for _ in 0..<25 where !settled() {
            scroller.scroll(byDeltaX: 0, deltaY: -80)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        // Overshot or the element started above the viewport: try the other way.
        for _ in 0..<25 where !settled() {
            scroller.scroll(byDeltaX: 0, deltaY: 80)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertTrue(
            element.exists && element.isHittable,
            "could not scroll element into view: \(element)",
            file: file,
            line: line
        )
    }

    // MARK: Debug channel

    /// Addresses a debug command to the launched app only (see the app-side
    /// driver): "command@@runID". Foreign DEBUG instances ignore it.
    private func scoped(_ action: String) -> String {
        runID.map { "\(action)@@\($0)" } ?? action
    }

    func postDebug(_ action: String) {
        DistributedNotificationCenter.default().postNotificationName(
            debugChannel,
            object: scoped(action),
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// One state round-trip: post "state:<nonce>", wait for the matching reply.
    func requestState(timeout: TimeInterval = 5) -> AppState? {
        let nonce = UUID().uuidString
        var result: AppState?
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: stateChannel, object: nil, queue: .main) { note in
            guard
                let json = note.object as? String,
                let state = try? JSONDecoder().decode(AppState.self, from: Data(json.utf8)),
                state.nonce == nonce,
                // Ignore replies from any other app instance (foreign DEBUG
                // builds answer this channel too); accept only the launch we
                // started. Before launch (nil runID) accept any to probe.
                self.runID == nil || state.runID == self.runID
            else { return }
            result = state
        }
        defer { center.removeObserver(token) }
        center.postNotificationName(debugChannel, object: scoped("state:\(nonce)"), userInfo: nil, deliverImmediately: true)
        let deadline = Date(timeIntervalSinceNow: timeout)
        while result == nil, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return result
    }

    /// Polls app state until the condition holds; fails the test on timeout
    /// with the last snapshot for diagnosis.
    @discardableResult
    func waitForState(
        timeout: TimeInterval = 8,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        until condition: (AppState) -> Bool
    ) -> AppState? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var last: AppState?
        repeat {
            if let state = requestState(timeout: 2) {
                last = state
                if condition(state) { return state }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        } while Date() < deadline
        XCTFail(
            "timed out waiting for: \(description)\nlast state: \(String(describing: last))",
            file: file,
            line: line
        )
        return last
    }

    /// Confirms a condition KEEPS holding (e.g. "overlay did NOT dismiss")
    /// by sampling for the whole interval instead of returning early.
    func assertStateHolds(
        for interval: TimeInterval = 1.5,
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        while condition: (AppState) -> Bool
    ) {
        let deadline = Date(timeIntervalSinceNow: interval)
        while Date() < deadline {
            guard let state = requestState(timeout: 2) else { continue }
            if !condition(state) {
                XCTFail("state stopped holding: \(description)\nstate: \(state)", file: file, line: line)
                return
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        }
    }

    /// Waits until a session's panel frame stops changing (drag debounce,
    /// snap animation, page-change resize all settle within ~1s).
    @discardableResult
    func waitForSettledFrame(
        sessionNamed name: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> AppState.Session? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var previous: CGRect?
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
            guard let session = requestState()?.session(named: name) else { continue }
            if let previous, previous.approximatelyEqual(to: session.frameRect) {
                return session
            }
            previous = session.frameRect
        }
        XCTFail("overlay '\(name)' frame never settled", file: file, line: line)
        return nil
    }

    // MARK: Dock reopen

    /// Simulates clicking the Dock icon: asking LaunchServices to open an
    /// already-running app activates it and delivers the same reopen Apple
    /// event a Dock click does.
    func reopenFromDock(file: StaticString = #filePath, line: UInt = #line) {
        guard let url = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleID)
            .first?.bundleURL
        else {
            XCTFail("app is not running; cannot send reopen", file: file, line: line)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            XCTFail("failed to run /usr/bin/open: \(error)", file: file, line: line)
        }
    }

    func deactivateApp(file: StaticString = #filePath, line: UInt = #line) {
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        waitForState(timeout: 5, "app deactivated", file: file, line: line) { !$0.appIsActive }
    }

    // MARK: Overlay

    /// The overlay panel's content view (works even if the borderless panel
    /// itself isn't exposed as an accessibility window).
    func overlayContent() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "overlay.root").firstMatch
    }

    /// The pin button (and drag grip) only render while the overlay is hovered
    /// — at zero opacity SwiftUI drops the pin from the accessibility tree.
    /// Move the pointer onto the overlay so those controls become reachable.
    @discardableResult
    func revealOverlayPin(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let content = overlayContent()
        XCTAssertTrue(content.waitForExistence(timeout: 5), "overlay content not found", file: file, line: line)
        let pin = app.buttons["overlay.pin"]
        // Hover can be missed if the pointer was already at that point; retry.
        for _ in 0..<5 where !pin.waitForExistence(timeout: 1) {
            content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        }
        return pin
    }

    @discardableResult
    func openOverlayFromMenu(_ sheetName: String, file: StaticString = #filePath, line: UInt = #line) -> AppState? {
        clickStatusMenuItem(sheetName, file: file, line: line)
        return waitForState(timeout: 10, "overlay '\(sheetName)' visible and loaded", file: file, line: line) { state in
            guard let session = state.session(named: sheetName) else { return false }
            return session.isVisible && !session.isLoading
        }
    }

    func hideAllOverlays(file: StaticString = #filePath, line: UInt = #line) {
        postDebug("hide")
        waitForState(timeout: 8, "all overlays hidden", file: file, line: line) { $0.sessions.isEmpty }
    }

    /// Drags the overlay by its top drag strip. The vector is in points in
    /// accessibility coordinates (+x right, +y DOWN — the opposite of the
    /// AppKit frames reported on the state channel).
    func dragOverlay(by vector: CGVector, file: StaticString = #filePath, line: UInt = #line) {
        let content = overlayContent()
        XCTAssertTrue(content.waitForExistence(timeout: 5), "overlay content not found for dragging", file: file, line: line)
        let start = content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        let end = start.withOffset(vector)
        start.press(forDuration: 0.3, thenDragTo: end)
        // Drag commits are debounced 250ms after release; give the settle
        // task and snap animation a beat before the caller polls.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.7))
    }

    /// Drags the overlay so it would land `overshoot` points PAST the given
    /// edge(s) of its screen's visible frame — the cursor stops at the screen
    /// edge, leaving the panel partially offscreen so the app's snap-back
    /// clamp has real work to do.
    func dragOverlayTowards(
        _ edges: Set<ScreenEdge>,
        sessionNamed name: String,
        overshoot: CGFloat = 250,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard
            let session = requestState()?.session(named: name),
            let visible = session.visibleRect
        else {
            XCTFail("no session '\(name)' with screen info to drag", file: file, line: line)
            return
        }
        let frame = session.frameRect
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        // State frames are AppKit (+y up); drag vectors are AX (+y down).
        if edges.contains(.right) { dx = (visible.maxX - frame.maxX) + overshoot }
        if edges.contains(.left) { dx = (visible.minX - frame.minX) - overshoot }
        if edges.contains(.top) { dy = -((visible.maxY - frame.maxY) + overshoot) }
        if edges.contains(.bottom) { dy = (frame.minY - visible.minY) + overshoot }
        dragOverlay(by: CGVector(dx: dx, dy: dy), file: file, line: line)
    }

    // MARK: Geometry assertions (AppKit coordinates)

    enum ScreenEdge: String {
        case top, right, left, bottom
    }

    func assertTouchesEdge(
        _ edge: ScreenEdge,
        _ session: AppState.Session,
        tolerance: CGFloat = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let visible = session.visibleRect else {
            XCTFail("session has no screen visible frame", file: file, line: line)
            return
        }
        let frame = session.frameRect
        let (actual, expected): (CGFloat, CGFloat)
        switch edge {
        case .top: (actual, expected) = (frame.maxY, visible.maxY)
        case .bottom: (actual, expected) = (frame.minY, visible.minY)
        case .right: (actual, expected) = (frame.maxX, visible.maxX)
        case .left: (actual, expected) = (frame.minX, visible.minX)
        }
        XCTAssertEqual(
            actual,
            expected,
            accuracy: tolerance,
            "overlay should touch the \(edge.rawValue) edge of the visible frame; frame=\(frame) visible=\(visible)",
            file: file,
            line: line
        )
    }

    func assertFullyOnScreen(
        _ session: AppState.Session,
        tolerance: CGFloat = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let visible = session.visibleRect else {
            XCTFail("session has no screen visible frame", file: file, line: line)
            return
        }
        XCTAssertTrue(
            visible.insetBy(dx: -tolerance, dy: -tolerance).contains(session.frameRect),
            "overlay frame \(session.frameRect) extends beyond visible frame \(visible)",
            file: file,
            line: line
        )
    }
}

extension CGRect {
    /// Frame equality with sub-pixel tolerance (animated setFrame can land on
    /// fractional coordinates that differ per sample).
    func approximatelyEqual(to other: CGRect, tolerance: CGFloat = 1.0) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
