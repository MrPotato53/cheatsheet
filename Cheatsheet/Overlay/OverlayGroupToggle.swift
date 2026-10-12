import SwiftUI

/// The button a group of overlay buttons folds behind in the collapsed
/// Buttons modes (☰ for the cheatsheet's buttons, a globe for a web page's).
/// Shows ✕ while its group is open.
struct OverlayGroupToggle<Badge: View>: View {
    let systemImage: String
    @Binding var isExpanded: Bool
    /// Shown even while the overlay isn't hovered (e.g. ☰ on a pinned sheet).
    var isShown = false
    let isOverlayHovered: Bool
    let help: String
    let id: String
    let glass: Namespace.ID
    /// A marker on the folded button, hidden while open.
    @ViewBuilder let badge: () -> Badge

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: isExpanded ? "xmark" : systemImage)
                .frame(width: 18, height: 18)
                .overlay(alignment: .topTrailing) {
                    if !isExpanded {
                        badge()
                    }
                }
        }
        .overlayControl()
        .accessibilityIdentifier(id)
        .circleChrome()
        .glassEffectID(id, in: glass)
        .opacity(isShown || isOverlayHovered || isExpanded ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isOverlayHovered)
        .help(help)
    }
}

extension OverlayGroupToggle where Badge == EmptyView {
    init(
        systemImage: String,
        isExpanded: Binding<Bool>,
        isOverlayHovered: Bool,
        help: String,
        id: String,
        glass: Namespace.ID
    ) {
        self.init(
            systemImage: systemImage,
            isExpanded: isExpanded,
            isOverlayHovered: isOverlayHovered,
            help: help,
            id: id,
            glass: glass,
            badge: { EmptyView() }
        )
    }
}
