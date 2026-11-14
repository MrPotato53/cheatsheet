import SwiftUI

/// Marks where a drag would land in settings, in the style of the Pages
/// gallery's "Drop here to hide" zone: a light accent fill and an accent
/// border, plus a caption saying what the drop will do.
struct DropHighlight: View {
    let label: String
    let systemImage: String
    var cornerRadius: CGFloat = 10

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
            Label(label, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: .capsule)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityIdentifier("settings.dropHighlight")
    }
}

extension View {
    /// Shows `DropHighlight` over this view while `isTargeted`.
    func dropHighlight(_ isTargeted: Bool, label: String, systemImage: String, inset: CGFloat = 6) -> some View {
        overlay {
            if isTargeted {
                DropHighlight(label: label, systemImage: systemImage)
                    .padding(inset)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }
}
