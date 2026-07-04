import AppKit
import OSLog
import WebKit

/// Borderless non-activating panel: becomes key to receive arrow/Escape keys
/// without activating the app or stealing focus from the frontmost app
/// (same pattern Spotlight uses).
final class OverlayPanel: NSPanel {
    var keyHandler: (@MainActor (NSEvent) -> Bool)?
    /// Set around programmatic setFrame calls so user drags can be told apart
    /// from our own repositioning in windowDidMove. The generation counter
    /// lets delayed clears (animated frame changes) be superseded safely.
    var isProgrammaticMove = false
    var programmaticMoveGeneration = 0
    /// Target of the last programmatic setFrame: a live-resize that ends
    /// (approximately — pixel-grid rounding differs per screen) here is our
    /// own animation, not a user resize (timing-free check, unlike the flag).
    var lastProgrammaticFrame: NSRect?
    /// User resizes start with the mouse button down; programmatic snap
    /// animations start from a task that waits for button release first.
    var liveResizeStartedWithButtonDown = false

    private static let logger = Logger(subsystem: "potatodev.Cheatsheet", category: "overlay-scroll")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    // Intercept before the responder chain: the SwiftUI hosting view otherwise
    // swallows Escape and arrow keys before they reach the window's keyDown.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        // In hold-to-show mode the hotkey's modifiers stay pressed; shift turns
        // wheel scrolls horizontal and command triggers zoom behaviors, which
        // made scrolling appear broken. The overlay never needs modified
        // scrolling, so strip modifiers and scroll the view under the cursor
        // ourselves.
        if event.type == .scrollWheel,
           !event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
           deliverUnmodifiedScroll(event) {
            return
        }
        super.sendEvent(event)
    }

    private func deliverUnmodifiedScroll(_ event: NSEvent) -> Bool {
        guard let contentView else { return false }
        // hitTest takes superview coordinates (the frame view is flipped, so
        // raw locationInWindow lands on the wrong subview — convert properly).
        let point = contentView.superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        let hit = contentView.hitTest(point) ?? contentView

        let (dx, dy) = Self.correctedDeltas(for: event)

        // Redelivering a synthesized NSEvent doesn't drive modern AppKit
        // scrolling, so scroll the clip view directly with the real deltas.
        if let scrollView = (hit as? NSScrollView) ?? hit.enclosingScrollView {
            Self.logger.debug("modified scroll -> manual clip scroll via \(type(of: hit), privacy: .public), dx=\(dx) dy=\(dy)")
            scroll(scrollView, deltaX: dx, deltaY: dy, precise: event.hasPreciseScrollingDeltas)
            return true
        }

        // WKWebView (markdown pages) scrolls internally; drive it via JS.
        var view: NSView? = hit
        while let current = view {
            if let webView = current as? WKWebView {
                let lineFactor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 30
                Self.logger.debug("modified scroll -> WKWebView scrollBy(\(-dx * lineFactor), \(-dy * lineFactor))")
                webView.evaluateJavaScript(
                    "window.scrollBy(\(-dx * lineFactor), \(-dy * lineFactor));",
                    completionHandler: nil
                )
                return true
            }
            view = current.superview
        }
        return false
    }

    /// With shift held, macOS swaps wheel motion onto the horizontal axis
    /// before the event reaches the app (scrollingDeltaY arrives as 0).
    /// Swap it back so vertical scrolling keeps working in hold-to-show mode.
    private static func correctedDeltas(for event: NSEvent) -> (dx: CGFloat, dy: CGFloat) {
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if event.modifierFlags.contains(.shift), dy == 0, dx != 0 {
            dy = dx
            dx = 0
        }
        return (dx, dy)
    }

    private func scroll(_ scrollView: NSScrollView, deltaX: CGFloat, deltaY: CGFloat, precise: Bool) {
        guard let documentView = scrollView.documentView else { return }
        let factor: CGFloat = precise ? 1 : 20
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.x -= deltaX * factor
        if documentView.isFlipped {
            origin.y -= deltaY * factor
        } else {
            origin.y += deltaY * factor
        }
        origin.x = min(max(origin.x, 0), max(0, documentView.frame.width - clip.bounds.width))
        origin.y = min(max(origin.y, 0), max(0, documentView.frame.height - clip.bounds.height))
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
