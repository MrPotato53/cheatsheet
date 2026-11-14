import AppKit
import SwiftUI

struct SettingsRootView: View {
    @State private var isWindowContentActive = false
    @State private var isDropTargeted = false
    @Environment(SettingsNavigation.self) private var navigation
    @Environment(CheatsheetStore.self) private var store

    var body: some View {
        Group {
            if isWindowContentActive {
                TabView(selection: Binding(get: { navigation.tab }, set: { navigation.tab = $0 })) {
                    GeneralSettingsView()
                        .tabItem { Label("General", systemImage: "gearshape") }
                        .tag(SettingsNavigation.Tab.general)
                    CheatsheetsSettingsView()
                        .tabItem { Label("Cheatsheets", systemImage: "rectangle.stack") }
                        .tag(SettingsNavigation.Tab.cheatsheets)
                }
                // Like System Settings: no control is focused on open.
                .opensUnfocused()
                // Dropped anywhere not claimed by a more specific target (a
                // sheet in the list, the selected sheet's settings): a new
                // cheatsheet, shown in the Cheatsheets tab.
                .dropDestination(for: URL.self) { urls, _ in
                    createSheet(fromDropped: urls)
                } isTargeted: { isDropTargeted = $0 }
                .dropHighlight(isDropTargeted, label: "Drop to create a cheatsheet", systemImage: "plus.rectangle.on.rectangle")
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

    private func createSheet(fromDropped urls: [URL]) -> Bool {
        let dropped = DroppedItems(urls)
        guard !dropped.isEmpty else { return false }
        // Exports are imported as the cheatsheets they contain.
        navigation.requestArchiveImport(dropped.archives)
        let sheet = HTMLResourceAccess.withResourceAccess(for: dropped.files) {
            store.addSheet(dropped: dropped)
        }
        if let sheet {
            navigation.requestSheet(sheet.id)
        }
        return true
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
            #if DEBUG
            // UI tests stretch this window to the screen's height. AppKit
            // saves window frames in the app's standard defaults, which a
            // test instance shares with the real app (same bundle ID), so
            // keep test runs from changing the size the real app reopens at.
            if UITestMode.isActive {
                window.setFrameAutosaveName("")
            }
            #endif
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
