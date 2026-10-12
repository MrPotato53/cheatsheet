import SwiftUI

/// Back, reload and open-in-browser for a web page, in the overlay's top
/// left (browser-style, apart from the cheatsheet's own buttons at the top
/// right). Follows the Buttons setting like those: shown all at once and
/// faded until hovered, or folded behind a globe button.
struct WebNavigationControls: View {
    let page: LiveWebPage
    let isOverlayHovered: Bool
    @AppStorage(OverlayButtonsMode.defaultsKey, store: AppDefaults.store) private var mode = OverlayButtonsMode.expanded
    @State private var isExpanded = false
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                if mode.collapses {
                    // First, so it sits in the corner and the buttons grow
                    // rightward without moving it out from under the cursor.
                    if !isExpanded || mode == .expandOnClick {
                        OverlayGroupToggle(
                            systemImage: "globe",
                            isExpanded: $isExpanded,
                            isOverlayHovered: isOverlayHovered,
                            help: mode == .expandOnClick ? (isExpanded ? "Hide web controls" : "Show web controls") : "Web controls",
                            id: "overlay.web.moreButtons",
                            glass: glass
                        )
                        .transition(.opacity)
                    }
                    if isExpanded {
                        buttons
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                } else {
                    buttons
                }
            }
            .padding(8)
            // As with the top-right group: gaps between buttons don't count
            // as leaving.
            .contentShape(Rectangle())
            .onHover { hovering in
                guard mode == .expandOnHover else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    isExpanded = hovering
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            button("chevron.backward", help: "Back", id: "overlay.web.back", action: page.goBack)
                .disabled(!page.canGoBack)
            button("arrow.clockwise", help: "Reload", id: "overlay.web.reload", action: page.reload)
            button("safari", help: "Open in browser", id: "overlay.web.openInBrowser", action: page.openInBrowser)
        }
    }

    private func button(_ systemImage: String, help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .overlayControl()
        .accessibilityIdentifier(id)
        .circleChrome()
        .glassEffectID(id, in: glass)
        // Faded until hovered; always shown once the folded group is open.
        .opacity(mode.collapses || isOverlayHovered ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isOverlayHovered)
        .help(help)
    }
}
