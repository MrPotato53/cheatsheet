import SwiftUI

/// Flashes the zoom level under the overlay's buttons after ⌘= / ⌘- / ⌘0,
/// then fades out.
struct ZoomLevelBadge: View {
    private static let visibleDuration: Duration = .seconds(1.5)

    let zoom: Double
    /// Bumped per zoom key press, even at a limit, so the level still shows.
    let flash: Int
    @State private var isVisible = false

    var body: some View {
        Text(PageZoom.label(for: zoom))
            .font(.callout.monospacedDigit().weight(.medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .glassEffect(in: .capsule)
            .padding(.horizontal, 8)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityIdentifier("overlay.zoomLevel")
            .task(id: flash) {
                guard flash > 0 else { return }
                withAnimation(.easeOut(duration: 0.1)) { isVisible = true }
                try? await Task.sleep(for: Self.visibleDuration)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.4)) { isVisible = false }
            }
    }
}
