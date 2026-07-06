import AppKit
import SwiftUI

struct SettingsRootView: View {
    @State private var isWindowContentActive = false

    var body: some View {
        Group {
            if isWindowContentActive {
                TabView {
                    GeneralSettingsView()
                        .tabItem { Label("General", systemImage: "gearshape") }
                    CheatsheetsSettingsView()
                        .tabItem { Label("Cheatsheets", systemImage: "rectangle.stack") }
                }
            } else {
                // SwiftUI keeps a window scene's content alive after close
                // (confirmed via heap dumps — including the preview's decoded
                // images and layer backing stores). Swapping in an empty view
                // on close releases all of it while the scene retains only
                // this stub.
                Color.clear
            }
        }
        .frame(minWidth: 700, minHeight: 440)
        .background(
            WindowVisibilityObserver { visible in
                isWindowContentActive = visible
                AppModel.shared.isSettingsWindowVisible = visible
            }
        )
    }
}

/// Tracks the hosting window's real visibility via AppKit notifications —
/// onAppear/onDisappear are unreliable here because the scene keeps the
/// content mounted after the window closes.
private struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
            tokens = []
            guard let window else { return }
            onChange?(true)
            let center = NotificationCenter.default
            tokens.append(center.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?(false) }
            })
            tokens.append(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?(true) }
            })
            // Covers the window being reshown without becoming key.
            tokens.append(center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    if window.isVisible {
                        self.onChange?(true)
                    }
                }
            })
        }
    }
}
