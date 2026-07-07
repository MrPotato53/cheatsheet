import AppKit
import SwiftUI

/// Miniature of the target screen (blue) with a draggable red box representing
/// the overlay's maximum bounds — position tuning without covering the
/// settings window with the real overlay. Tracks the size slider live.
struct PositionPreviewView: View {
    @Binding var sheet: Cheatsheet

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let scale = min(max(sheet.previewScale, 0.2), 1.0)
            let boxWidth = width * scale
            let boxHeight = height * scale
            let center = clampedCenter(sheet.position, scale: scale)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.18))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.blue.opacity(0.45), lineWidth: 1)

                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.red.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.red.opacity(0.8), lineWidth: 1.5)
                    )
                    .frame(width: boxWidth, height: boxHeight)
                    // AppKit y-fraction is bottom-up; SwiftUI is top-down.
                    .position(x: center.x * width, y: (1 - center.y) * height)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let raw = RelativePosition(
                                    x: Double(value.location.x / width),
                                    y: Double(1 - value.location.y / height)
                                )
                                sheet.position = clampedCenter(raw, scale: scale)
                            }
                    )
            }
        }
        .aspectRatio(screenAspect, contentMode: .fit)
        .frame(maxWidth: 320, maxHeight: 240)
        .help("Drag the red box to choose where this cheatsheet appears on screen")
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("detail.positionPreview")
    }

    /// Mirrors the configured target display's shape, so a portrait monitor
    /// shows a tall desktop. Dynamic targets (cursor/focused) and disconnected
    /// displays fall back to the main screen.
    private var screenAspect: CGFloat {
        let screen: NSScreen? = {
            if case .specific(let uuid, _) = sheet.target {
                return NSScreen.screens.first { $0.displayUUID == uuid } ?? NSScreen.main
            }
            return NSScreen.main
        }()
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 16, height: 10)
        let aspect = frame.width / max(frame.height, 1)
        return min(max(aspect, 0.4), 4)
    }

    /// Keeps the whole box inside the screen, matching the overlay's clamping.
    private func clampedCenter(_ position: RelativePosition, scale: Double) -> RelativePosition {
        let half = scale / 2
        guard half < 0.5 else { return .center }
        return RelativePosition(
            x: min(max(position.x, half), 1 - half),
            y: min(max(position.y, half), 1 - half)
        )
    }
}
