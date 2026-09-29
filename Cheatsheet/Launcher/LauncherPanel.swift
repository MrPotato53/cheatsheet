import AppKit

/// Borderless non-activating panel for the cheatsheet search bar: takes
/// typing like Spotlight without activating the app, and floats above
/// overlays.
final class LauncherPanel: NSPanel {
    var keyHandler: (@MainActor (NSEvent) -> Bool)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: LauncherLayout.width, height: LauncherLayout.barHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        title = "Search Cheatsheets"
    }

    override var canBecomeKey: Bool { true }

    // Arrows, Return and Escape are handled before the text field sees them.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, performEditingShortcut(event) { return }
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    /// ⌘X/C/V/A/Z in the field: there's no main menu to route them while the
    /// app isn't active (see EditingShortcut).
    private func performEditingShortcut(_ event: NSEvent) -> Bool {
        guard
            firstResponder is NSText,
            let key = event.charactersIgnoringModifiers,
            let action = EditingShortcut.action(forKey: key, modifiers: event.modifierFlags)
        else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

nonisolated enum LauncherLayout {
    static let width: CGFloat = 640
    static let barHeight: CGFloat = 56
    static let rowHeight: CGFloat = 36
    static let maxVisibleRows = 7
    static let listPadding: CGFloat = 6
    /// Spotlight's bar sits about a quarter of the way down the screen.
    static let topFraction: CGFloat = 0.22

    static func height(resultCount: Int) -> CGFloat {
        guard resultCount > 0 else { return barHeight }
        let rows = CGFloat(min(resultCount, maxVisibleRows))
        return barHeight + 1 + rows * rowHeight + listPadding * 2
    }
}
