import AppKit
import SwiftUI

extension View {
    /// For every sheet or popover whose first control is a button (not a text
    /// field): it opens with nothing focused.
    ///
    /// With keyboard navigation on (System Settings → Keyboard), AppKit gives
    /// a new window's first control keyboard focus, drawn as a blue ring that
    /// reads as a preselected choice. This clears that focus once the window
    /// opens, so nothing is highlighted and Space picks nothing, while Tab
    /// still moves through the controls, with their rings, as usual. Return
    /// and Escape keep working through `.defaultAction` / `.cancelAction`.
    ///
    /// Use this rather than `.focusable(false)` (drops the control from
    /// keyboard navigation) or `.focusEffectDisabled()` (keeps it focused,
    /// just invisibly). Forms that start with a text field don't use it:
    /// there the cursor in the field is the point.
    func opensUnfocused() -> some View {
        background(UnfocusOnOpen())
    }
}

private struct UnfocusOnOpen: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe {
        Probe()
    }

    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        private var keyObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, keyObserver == nil else { return }
            clearFocus(in: window)
            // AppKit assigns the first key view when the window becomes key,
            // which for a sheet can come after this: clear it then too, once.
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clearFocus(in: window)
                    self.stopObserving()
                }
            }
        }

        override func removeFromSuperview() {
            stopObserving()
            super.removeFromSuperview()
        }

        private func clearFocus(in window: NSWindow) {
            DispatchQueue.main.async {
                window.makeFirstResponder(nil)
            }
        }

        private func stopObserving() {
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
            }
            keyObserver = nil
        }
    }
}
