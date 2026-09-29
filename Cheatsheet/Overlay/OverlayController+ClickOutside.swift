import AppKit

/// "Close when clicking outside": a click in another app's window or on the
/// desktop closes the unpinned overlay. Watched with a global mouse monitor,
/// so it works whether or not the overlay ever had keyboard focus, and needs
/// no Accessibility permission (global monitors only require it for keys).
extension OverlayController {
    static let dismissOnClickOutsideKey = "dismissOnClickOutside"

    static var isDismissOnClickOutsideEnabled: Bool {
        AppDefaults.store.object(forKey: dismissOnClickOutsideKey) as? Bool ?? false
    }

    /// Mirrors escapeShouldDismiss: pinned overlays stay put, and clicks that
    /// land on one of our own windows (another overlay, settings, a file
    /// picker opened from the overlay) aren't "outside".
    static func clickOutsideShouldDismiss(enabled: Bool, isPinned: Bool, clickedOwnWindow: Bool) -> Bool {
        enabled && !isPinned && !clickedOwnWindow
    }

    /// Watches clicks only while an unpinned overlay is on screen. Called
    /// whenever sessions open, close, or change pin state.
    func updateClickOutsideMonitor() {
        let needsMonitor = sessions.contains { !$0.isPinned }
        if needsMonitor, clickOutsideMonitor == nil {
            clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                // Global monitor handlers run on the main thread.
                MainActor.assumeIsolated {
                    self?.handleClickOutside()
                }
            }
        } else if !needsMonitor, let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    private func handleClickOutside() {
        let clickedOwnWindow = Self.isOwnWindow(at: NSEvent.mouseLocation)
        for session in sessions where Self.clickOutsideShouldDismiss(
            enabled: Self.isDismissOnClickOutsideEnabled,
            isPinned: session.isPinned,
            clickedOwnWindow: clickedOwnWindow
        ) {
            hide(session)
        }
    }

    /// The topmost window under the click belongs to this app. Global
    /// monitors mostly see clicks elsewhere, but some of our windows (the
    /// sandboxed open panel) are drawn by another process.
    private static func isOwnWindow(at point: NSPoint) -> Bool {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        return NSApp.windows.contains { $0.windowNumber == number }
    }
}
