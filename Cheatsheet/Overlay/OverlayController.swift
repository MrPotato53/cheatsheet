import AppKit
import PDFKit
import SwiftUI

nonisolated struct SheetPage: Hashable {
    let url: URL
    /// Non-nil when this page is a single page inside a multi-page PDF.
    let pdfPageIndex: Int?
}

@Observable
@MainActor
final class OverlayController {
    private let store: CheatsheetStore
    private var panel: OverlayPanel?
    private(set) var currentSheet: Cheatsheet?
    private(set) var pages: [SheetPage] = []
    private(set) var pageIndex = 0
    private var isShown = false
    private var lastPageIndex: [Cheatsheet.ID: Int] = [:]

    init(store: CheatsheetStore) {
        self.store = store
    }

    var currentPage: SheetPage? {
        pages.indices.contains(pageIndex) ? pages[pageIndex] : nil
    }

    func toggle(_ sheet: Cheatsheet) {
        if isShown, currentSheet?.id == sheet.id {
            hide()
        } else {
            show(sheet)
        }
    }

    func show(_ sheet: Cheatsheet) {
        // Hold mode delivers repeated key-down events while the key is held.
        if isShown, currentSheet?.id == sheet.id { return }
        if let previousID = currentSheet?.id, isShown {
            lastPageIndex[previousID] = pageIndex
        }
        pages = buildPages(for: sheet)
        pageIndex = min(lastPageIndex[sheet.id] ?? 0, max(pages.count - 1, 0))
        currentSheet = sheet

        guard let screen = resolveScreen(for: sheet.target) else { return }
        let panel = ensurePanel()
        let visible = screen.visibleFrame
        let scale = min(max(sheet.previewScale, 0.2), 1.0)
        let size = NSSize(width: visible.width * scale, height: visible.height * scale)
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        if !isShown {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        isShown = true
    }

    func hide() {
        guard isShown, let panel else { return }
        if let id = currentSheet?.id {
            lastPageIndex[id] = pageIndex
        }
        isShown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !self.isShown else { return }
            self.panel?.orderOut(nil)
        }
    }

    func goToNextPage() {
        guard pageIndex < pages.count - 1 else { return }
        pageIndex += 1
    }

    func goToPreviousPage() {
        guard pageIndex > 0 else { return }
        pageIndex -= 1
    }

    // MARK: - Pages

    private func buildPages(for sheet: Cheatsheet) -> [SheetPage] {
        var result: [SheetPage] = []
        for file in sheet.files {
            let url = store.fileURL(for: sheet, file: file)
            if MediaKind.of(url) == .pdf, let document = PDFDocument(url: url), document.pageCount > 0 {
                for index in 0..<document.pageCount {
                    result.append(SheetPage(url: url, pdfPageIndex: index))
                }
            } else {
                result.append(SheetPage(url: url, pdfPageIndex: nil))
            }
        }
        return result
    }

    // MARK: - Screen + panel

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

    private func ensurePanel() -> OverlayPanel {
        if let panel { return panel }
        let panel = OverlayPanel()
        panel.keyHandler = { [weak self] event in
            self?.handleKeyEvent(event) ?? false
        }
        panel.contentView = NSHostingView(rootView: OverlayContentView(controller: self))
        self.panel = panel
        return panel
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: // left arrow
            goToPreviousPage()
            return true
        case 124: // right arrow
            goToNextPage()
            return true
        case 53: // escape
            let escapeEnabled = UserDefaults.standard.object(forKey: "dismissWithEsc") as? Bool ?? true
            guard escapeEnabled else { return false }
            hide()
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
