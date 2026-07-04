import AppKit
import SwiftUI

/// Draws a translucent blue border around a physical display, used while
/// hovering monitor options in the display picker so the user can see which
/// screen each entry refers to.
@MainActor
final class ScreenHighlighter {
    static let shared = ScreenHighlighter()
    private var panel: NSPanel?

    func highlight(displayUUID: String) {
        guard let screen = NSScreen.screens.first(where: { $0.displayUUID == displayUUID }) else {
            hide()
            return
        }
        let panel = ensurePanel()
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: HighlightBorderView())
        self.panel = panel
        return panel
    }
}

private struct HighlightBorderView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color(nsColor: .systemYellow).opacity(0.85), lineWidth: 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
    }
}
