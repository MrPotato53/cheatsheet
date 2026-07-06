import AppKit
import PDFKit
import SwiftUI

nonisolated struct SheetPage: Hashable {
    let url: URL
    /// Non-nil when this page is a single page inside a multi-page PDF.
    let pdfPageIndex: Int?
    /// Effective transform (per-page override or the sheet default), resolved
    /// by CheatsheetStore when building pages.
    let rotation: Rotation
    let flipHorizontal: Bool
    let flipVertical: Bool
    var isHidden = false
}

/// One visible overlay: its panel, content state, and pin status. Multiple
/// sessions can be on screen at once (pinned ones plus one transient).
@Observable
@MainActor
final class OverlaySession: Identifiable {
    private(set) var sheet: Cheatsheet
    var pages: [SheetPage] = []
    var pageIndex = 0
    var isPinned = false
    var isLoadingPages = false

    @ObservationIgnored let panel = OverlayPanel()
    @ObservationIgnored var screen: NSScreen?
    @ObservationIgnored var moveDelegate: PanelMoveDelegate?
    @ObservationIgnored var moveCommitTask: Task<Void, Never>?
    /// Session-local geometry for "return to configured" modes: user drags and
    /// resizes stick while the overlay stays open, and revert on reopen
    /// because sessions are recreated per show.
    @ObservationIgnored var sessionPosition: RelativePosition?
    @ObservationIgnored var sessionScale: Double?

    var currentPage: SheetPage? {
        pages.indices.contains(pageIndex) ? pages[pageIndex] : nil
    }

    init(sheet: Cheatsheet) {
        self.sheet = sheet
    }

    func update(sheet: Cheatsheet) {
        self.sheet = sheet
    }
}

@MainActor
final class PanelMoveDelegate: NSObject, NSWindowDelegate {
    var onMove: (() -> Void)?
    var onWillStartLiveResize: (() -> Void)?
    var onEndLiveResize: (() -> Void)?

    func windowDidMove(_ notification: Notification) {
        onMove?()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        onWillStartLiveResize?()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        onEndLiveResize?()
    }
}

@Observable
@MainActor
final class OverlayController {
    private let store: CheatsheetStore
    private(set) var sessions: [OverlaySession] = []
    private var lastPageIndex: [Cheatsheet.ID: Int] = [:]

    // Pre-built pages and pre-decoded start-page images for sheets with
    // "keep start page loaded" — their opens skip the loading state entirely.
    private struct WarmInputs: Hashable {
        let files: [String]
        let pageOrder: [PageRef]
        let startPage: StartPage
        let previewScale: Double
        let target: DisplayTarget
        let lastViewedIndex: Int
    }

    private struct WarmEntry {
        let pages: [SheetPage]
        let startIndex: Int
        let inputs: WarmInputs
        let imageKey: String?
    }

    private var warmedStartPages: [Cheatsheet.ID: WarmEntry] = [:]

    init(store: CheatsheetStore) {
        self.store = store
    }

    private func startIndex(for sheet: Cheatsheet, pageCount: Int) -> Int {
        let lastIndex = max(pageCount - 1, 0)
        switch sheet.startPage {
        case .first:
            return 0
        case .lastViewed:
            return min(lastPageIndex[sheet.id] ?? 0, lastIndex)
        case .fixed(let index):
            return min(max(index, 0), lastIndex)
        }
    }

    private var transientSession: OverlaySession? {
        sessions.first { !$0.isPinned }
    }

    private func session(for sheetID: Cheatsheet.ID) -> OverlaySession? {
        sessions.first { $0.sheet.id == sheetID }
    }

    // MARK: - Show / hide

    func toggle(_ sheet: Cheatsheet) {
        if let existing = session(for: sheet.id) {
            if existing.isPinned {
                bringToFront(existing)
            } else {
                hide(existing)
            }
        } else {
            show(sheet)
        }
    }

    func show(_ sheet: Cheatsheet) {
        // Repeated key-downs while holding the hotkey land here too.
        if let existing = session(for: sheet.id) {
            bringToFront(existing)
            return
        }
        if let transient = transientSession {
            hide(transient)
        }

        let session = OverlaySession(sheet: sheet)
        session.isLoadingPages = true
        guard let screen = resolveScreen(for: sheet.target) else { return }
        session.screen = screen

        let panel = session.panel
        panel.keyHandler = { [weak self, weak session] event in
            guard let self, let session else { return false }
            return self.handleKeyEvent(event, in: session)
        }
        applyGeometryBehaviors(to: session)
        panel.minSize = NSSize(width: 160, height: 120)
        panel.contentView = NSHostingView(rootView: OverlayContentView(session: session, controller: self))

        let moveDelegate = PanelMoveDelegate()
        moveDelegate.onMove = { [weak self, weak session] in
            guard let self, let session else { return }
            self.panelDidMove(session)
        }
        moveDelegate.onWillStartLiveResize = { [weak session] in
            guard let session else { return }
            session.panel.liveResizeStartedWithButtonDown = NSEvent.pressedMouseButtons & 1 == 1
        }
        moveDelegate.onEndLiveResize = { [weak self, weak session] in
            guard let self, let session else { return }
            self.panelDidEndLiveResize(session)
        }
        panel.delegate = moveDelegate
        session.moveDelegate = moveDelegate

        sessions.append(session)
        updateFrame(for: session, animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        if sheet.keepsStartPageLoaded, let warm = warmedStartPages[sheet.id] {
            // Warm path: pages and the start page's decoded image are ready.
            session.pages = warm.pages
            session.pageIndex = startIndex(for: sheet, pageCount: warm.pages.count)
            session.isLoadingPages = false
            updateFrame(for: session, animated: false)
            return
        }

        // The panel is already on screen with a spinner; building the page
        // list (which parses PDFs) happens off the main thread.
        let mediaRoot = store.mediaRoot
        Task { @MainActor [weak self, weak session] in
            let pages = await Task.detached(priority: .userInitiated) {
                CheatsheetStore.buildPages(for: sheet, mediaRoot: mediaRoot)
            }.value
            guard
                let self,
                let session,
                self.sessions.contains(where: { $0 === session })
            else { return }
            session.pages = pages
            session.pageIndex = self.startIndex(for: sheet, pageCount: pages.count)
            session.isLoadingPages = false
            self.updateFrame(for: session, animated: true)
        }
    }

    // MARK: - Start page warming

    func warmStartPages() {
        let flagged = store.sheets.filter(\.keepsStartPageLoaded)
        let flaggedIDs = Set(flagged.map(\.id))
        warmedStartPages = warmedStartPages.filter { flaggedIDs.contains($0.key) }
        WarmPageImages.retain(only: Set(warmedStartPages.values.compactMap(\.imageKey)))
        for sheet in flagged {
            warmStartPage(for: sheet)
        }
    }

    private func warmInputs(for sheet: Cheatsheet) -> WarmInputs {
        let lastViewedIndex: Int
        if case .lastViewed = sheet.startPage {
            lastViewedIndex = lastPageIndex[sheet.id] ?? 0
        } else {
            lastViewedIndex = -1
        }
        return WarmInputs(
            files: sheet.files,
            pageOrder: sheet.pageOrder,
            startPage: sheet.startPage,
            previewScale: sheet.previewScale,
            target: sheet.target,
            lastViewedIndex: lastViewedIndex
        )
    }

    private func warmStartPage(for sheet: Cheatsheet) {
        let inputs = warmInputs(for: sheet)
        if let existing = warmedStartPages[sheet.id], existing.inputs == inputs {
            return
        }
        let mediaRoot = store.mediaRoot
        let lastViewed = lastPageIndex[sheet.id] ?? 0
        let maxPixels = ImageFileView.displayMaxPixels()
        let screen = resolveScreen(for: sheet.target)
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let scale = min(max(sheet.previewScale, 0.2), 1.0)
        let renderSize = CGSize(width: visible.width * scale, height: visible.height * scale)

        Task { @MainActor [weak self] in
            let result: ([SheetPage], Int, NSImage?)? = await Task.detached(priority: .utility) {
                let pages = CheatsheetStore.buildPages(for: sheet, mediaRoot: mediaRoot)
                guard !pages.isEmpty else { return nil }
                let lastIndex = max(pages.count - 1, 0)
                let index: Int
                switch sheet.startPage {
                case .first: index = 0
                case .lastViewed: index = min(lastViewed, lastIndex)
                case .fixed(let fixed): index = min(max(fixed, 0), lastIndex)
                }
                let page = pages[index]
                let image: NSImage?
                switch MediaKind.of(page.url) {
                case .image:
                    image = ImageFileView.displaySizedImage(at: page.url, maxPixels: maxPixels)
                case .pdf:
                    image = PDFPageView.render(url: page.url, pageIndex: page.pdfPageIndex ?? 0, size: renderSize)
                default:
                    image = nil
                }
                return (pages, index, image)
            }.value
            guard let self, let (pages, index, image) = result else { return }
            // The sheet may have changed or lost the flag while decoding.
            guard
                let current = self.store.sheets.first(where: { $0.id == sheet.id }),
                current.keepsStartPageLoaded
            else { return }
            let page = pages[index]
            var imageKey: String?
            if let image {
                imageKey = WarmPageImages.key(url: page.url, pdfPageIndex: page.pdfPageIndex)
                WarmPageImages.set(image, url: page.url, pdfPageIndex: page.pdfPageIndex)
            }
            self.warmedStartPages[sheet.id] = WarmEntry(
                pages: pages,
                startIndex: index,
                inputs: inputs,
                imageKey: imageKey
            )
        }
    }

    func hide(_ session: OverlaySession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        lastPageIndex[session.sheet.id] = session.pageIndex
        sessions.removeAll { $0 === session }
        // Re-warm "last viewed" start pages to the page just left.
        warmStartPages()
        session.moveCommitTask?.cancel()
        let panel = session.panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            panel.orderOut(nil)
            // Drop rendered bitmaps / web content; rebuilt cheaply on next show.
            panel.contentView = nil
            panel.delegate = nil
        }
    }

    func handleHoldKeyUp(sheetID: Cheatsheet.ID) {
        guard let session = session(for: sheetID), !session.isPinned else { return }
        hide(session)
    }

    private func bringToFront(_ session: OverlaySession) {
        session.panel.orderFrontRegardless()
        session.panel.makeKey()
    }

    // MARK: - Pinning

    func togglePin(_ session: OverlaySession) {
        if session.isPinned {
            session.isPinned = false
            // Only one transient at a time.
            if let other = transientSession, other !== session {
                hide(other)
            }
        } else {
            session.isPinned = true
        }
    }

    /// Global shortcut target: the key overlay if any, else the transient one,
    /// else the most recent session.
    func togglePinFrontmost() {
        guard let target = sessions.first(where: { $0.panel.isKeyWindow })
            ?? transientSession
            ?? sessions.last
        else { return }
        togglePin(target)
    }

    // MARK: - Paging

    func goToNextPage(in session: OverlaySession) {
        guard session.pageIndex < session.pages.count - 1 else { return }
        session.pageIndex += 1
        updateFrame(for: session, animated: true)
    }

    func goToPreviousPage(in session: OverlaySession) {
        guard session.pageIndex > 0 else { return }
        session.pageIndex -= 1
        updateFrame(for: session, animated: true)
    }

    // MARK: - Live settings sync

    func refreshFromStore() {
        for session in sessions {
            guard let updated = store.sheets.first(where: { $0.id == session.sheet.id }) else {
                hide(session)
                continue
            }
            // Editing the configured geometry in settings takes precedence
            // over a session-local override on that axis.
            if updated.position != session.sheet.position {
                session.sessionPosition = nil
            }
            if updated.previewScale != session.sheet.previewScale {
                session.sessionScale = nil
            }
            session.update(sheet: updated)
            session.pages = store.pages(for: updated)
            session.pageIndex = min(session.pageIndex, max(session.pages.count - 1, 0))
            // Keep the panel on whichever screen it currently occupies (the
            // user may have dragged it to another monitor); re-resolving the
            // configured target here would teleport it back mid-session.
            session.screen = session.panel.screen ?? session.screen ?? resolveScreen(for: updated.target)
            applyGeometryBehaviors(to: session)
            // Not animated: this fires on every slider tick.
            updateFrame(for: session, animated: false)
        }
        warmStartPages()
    }

    private func applyGeometryBehaviors(to session: OverlaySession) {
        let panel = session.panel
        panel.isMovableByWindowBackground = session.sheet.dragBehavior.allowsAdjustment
        if session.sheet.resizeBehavior.allowsAdjustment {
            panel.styleMask.insert(.resizable)
        } else {
            panel.styleMask.remove(.resizable)
        }
    }

    // MARK: - Geometry

    /// The user's size setting defines a maximum box placed at the sheet's
    /// stored position; the panel shrinks to the current page's aspect ratio
    /// within that box, so the position stays stable across different pages.
    private func updateFrame(for session: OverlaySession, animated: Bool) {
        guard let screen = session.screen else { return }
        let visible = screen.visibleFrame
        let sheet = session.sheet
        let scale = min(max(session.sessionScale ?? sheet.previewScale, 0.2), 1.0)
        let maxSize = CGSize(width: visible.width * scale, height: visible.height * scale)
        let size = fittedPanelSize(maxSize: maxSize, session: session)

        // Clamp by the fitted panel, not the max box: narrow media can then
        // hug a screen edge; a wider page just slides inward enough to stay
        // visible, and returns when the narrow page is shown again.
        let position = session.sessionPosition ?? sheet.position
        let centerX = Self.clampedCenter(position.x, extent: visible.width, half: size.width / 2)
        let centerY = Self.clampedCenter(position.y, extent: visible.height, half: size.height / 2)
        let frame = NSRect(
            x: visible.minX + centerX - size.width / 2,
            y: visible.minY + centerY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let panel = session.panel
        // Lock user resizing to the current page's aspect ratio; freeform
        // resizes would make the reconstructed size fraction inconsistent
        // across differently-shaped pages.
        panel.contentAspectRatio = size
        guard panel.frame != frame else { return }
        panel.lastProgrammaticFrame = frame
        panel.isProgrammaticMove = true
        panel.programmaticMoveGeneration += 1
        let generation = panel.programmaticMoveGeneration
        let animationTime = animated ? panel.animationResizeTime(frame) : 0
        panel.setFrame(frame, display: true, animate: animated)
        if animated {
            // Animated setFrame returns before the animation finishes; keep
            // the flag up until then, or the trailing didMove notifications
            // get committed as if the user dragged the panel there.
            Task { @MainActor [weak panel] in
                try? await Task.sleep(for: .seconds(animationTime + 0.1))
                if let panel, panel.programmaticMoveGeneration == generation {
                    panel.isProgrammaticMove = false
                }
            }
        } else {
            panel.isProgrammaticMove = false
        }
    }

    private static func approximatelyEqual(_ a: NSRect, _ b: NSRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    static func clampedCenter(_ fraction: Double, extent: CGFloat, half: CGFloat) -> CGFloat {
        guard extent > half * 2 else { return extent / 2 }
        return min(max(fraction * extent, half), extent - half)
    }

    private func fittedPanelSize(maxSize: CGSize, session: OverlaySession) -> CGSize {
        // MediaPageView pads its content by 8pt per side, and the top drag
        // strip reserves additional chrome height.
        let contentPadding: CGFloat = 16
        let stripHeight = session.sheet.dragBehavior.allowsAdjustment ? OverlayContentView.dragStripHeight : 0
        guard let page = session.currentPage, var natural = store.naturalSize(for: page) else {
            return maxSize
        }
        if page.rotation.swapsAxes {
            natural = CGSize(width: natural.height, height: natural.width)
        }
        let available = CGSize(
            width: maxSize.width - contentPadding,
            height: maxSize.height - contentPadding - stripHeight
        )
        guard natural.width > 0, natural.height > 0, available.width > 0, available.height > 0 else {
            return maxSize
        }
        let ratio = min(available.width / natural.width, available.height / natural.height)
        return CGSize(
            width: natural.width * ratio + contentPadding,
            height: natural.height * ratio + contentPadding + stripHeight
        )
    }

    /// User dragged the panel: persist the new center (debounced — didMove
    /// fires continuously during the drag) if this sheet remembers positions.
    private func panelDidMove(_ session: OverlaySession) {
        guard !session.panel.inLiveResize, session.panel.isVisible else { return }
        // A user window-drag has the left button down with the cursor on the
        // panel; programmatic repositioning (page changes, refresh, snaps)
        // never does.
        let isUserDrag = NSEvent.pressedMouseButtons & 1 == 1
            && session.panel.frame.contains(NSEvent.mouseLocation)
        guard isUserDrag else { return }
        // A user grab overrides any in-flight programmatic animation state —
        // otherwise re-grabbing during a snap animation swallowed the drag.
        session.panel.programmaticMoveGeneration += 1
        session.panel.isProgrammaticMove = false

        session.moveCommitTask?.cancel()
        session.moveCommitTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(for: .milliseconds(250))
            // Wait out re-grabs: the snap always applies after the final
            // release (a re-grab that also moves cancels and reschedules).
            while NSEvent.pressedMouseButtons & 1 == 1 {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, let self, let session else { return }
            // Computed at settle time so it reflects the final drop point and
            // the monitor the panel actually landed on.
            if session.sheet.dragBehavior == .remembers, let position = self.normalizedCenter(of: session) {
                self.store.setPosition(position, for: session.sheet.id)
            } else {
                // "Return to configured": the drop sticks for this session
                // (reverting happens on reopen), stored as a local override.
                session.sessionPosition = self.normalizedCenter(of: session)
            }
            // Snap into the clamped frame (covers partially-offscreen drops).
            self.updateFrame(for: session, animated: true)
        }
    }

    /// User drag-resized the panel: reconstruct the size fraction (and center,
    /// which corner-resizes shift) and persist per the sheet's modes. With
    /// both modes set to "configured", nothing is written and the overlay
    /// reverts on its next layout.
    private func panelDidEndLiveResize(_ session: OverlaySession) {
        // Animated programmatic frame changes (page transitions and snaps
        // resize the panel) can end a "live resize" too — only user resizes
        // commit. Three independent guards: user resizes start with the mouse
        // button down (snaps provably don't — the settle task waits for
        // release); the flag covers the animation window; and a resize ending
        // at (within pixel-rounding of) the recorded programmatic target is
        // our own animation.
        let startedWithButtonDown = session.panel.liveResizeStartedWithButtonDown
        session.panel.liveResizeStartedWithButtonDown = false
        guard startedWithButtonDown else { return }
        guard !session.panel.isProgrammaticMove else { return }
        if let target = session.panel.lastProgrammaticFrame,
           Self.approximatelyEqual(session.panel.frame, target) {
            return
        }
        guard session.panel.isVisible else { return }
        // Adopt the panel's current monitor and read the final center.
        let position = normalizedCenter(of: session)
        guard let screen = session.screen else { return }
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return }
        let frame = session.panel.frame
        let rawScale = max(frame.width / visible.width, frame.height / visible.height)
        let scale = min(max(Double(rawScale), 0.2), 1.0)

        session.moveCommitTask?.cancel()
        var committedScale: Double?
        if session.sheet.resizeBehavior == .remembers {
            committedScale = scale
        } else {
            session.sessionScale = scale
        }
        var committedPosition: RelativePosition?
        if session.sheet.dragBehavior == .remembers {
            committedPosition = position
        } else {
            session.sessionPosition = position
        }
        if committedScale != nil || committedPosition != nil {
            store.applyGeometry(scale: committedScale, position: committedPosition, for: session.sheet.id)
        }
        // Re-fit to the page aspect within the (possibly session-local) size.
        updateFrame(for: session, animated: true)
    }

    private func normalizedCenter(of session: OverlaySession) -> RelativePosition? {
        // The user may have dragged the panel to a different monitor; adopt
        // whichever screen it sits on now so the position is normalized (and
        // later re-applied) relative to that screen, not the original one.
        if let panelScreen = session.panel.screen {
            session.screen = panelScreen
        }
        guard let screen = session.screen else { return nil }
        let visible = screen.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return nil }
        let frame = session.panel.frame
        return RelativePosition(
            x: (frame.midX - visible.minX) / visible.width,
            y: (frame.midY - visible.minY) / visible.height
        )
    }

    // MARK: - Screen resolution

    /// A configured-but-disconnected display falls back to the cursor's screen,
    /// so the overlay always appears somewhere visible.
    func resolveScreen(for target: DisplayTarget) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        func screenUnderCursor() -> NSScreen {
            let location = NSEvent.mouseLocation
            return screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main ?? screens[0]
        }

        switch target {
        case .cursorScreen:
            return screenUnderCursor()
        case .focusedScreen:
            return NSScreen.main ?? screenUnderCursor()
        case .specific(let uuid, _):
            return screens.first { $0.displayUUID == uuid } ?? screenUnderCursor()
        }
    }

    // MARK: - Keys

    private func handleKeyEvent(_ event: NSEvent, in session: OverlaySession) -> Bool {
        switch event.keyCode {
        case 123: // left arrow
            goToPreviousPage(in: session)
            return true
        case 124: // right arrow
            goToNextPage(in: session)
            return true
        case 53: // escape
            let escapeEnabled = UserDefaults.standard.object(forKey: "dismissWithEsc") as? Bool ?? true
            guard escapeEnabled else { return false }
            // Pinned overlays ignore Escape (swallow it to avoid the beep).
            if !session.isPinned {
                hide(session)
            }
            return true
        default:
            return false
        }
    }
}

extension NSScreen {
    /// Stable identity across reconnects/reboots, unlike CGDirectDisplayID.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
