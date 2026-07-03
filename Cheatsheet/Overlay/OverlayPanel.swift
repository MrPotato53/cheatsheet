import AppKit

/// Borderless non-activating panel: becomes key to receive arrow/Escape keys
/// without activating the app or stealing focus from the frontmost app
/// (same pattern Spotlight uses).
final class OverlayPanel: NSPanel {
    var keyHandler: (@MainActor (NSEvent) -> Bool)?

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

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}
