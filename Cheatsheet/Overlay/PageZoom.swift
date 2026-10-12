import SwiftUI

extension EnvironmentValues {
    /// The overlay's zoom (1 = 100%); settings previews stay at 100%.
    @Entry var pageZoom: Double = PageZoom.actualSize
}

/// Overlay zoom levels: ⌘= / ⌘- step by 10%, ⌘0 returns to 100%.
nonisolated enum PageZoom {
    static let actualSize = 1.0
    static let step = 0.1
    static let minimum = 0.5
    static let maximum = 3.0

    /// Steps snap to whole tens, so a stray value (an old default, a
    /// rounding error) still lands on 110%, 120%…
    static func zoomedIn(from zoom: Double) -> Double {
        clamped(snapped(zoom) + step)
    }

    static func zoomedOut(from zoom: Double) -> Double {
        clamped(snapped(zoom) - step)
    }

    static func clamped(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return actualSize }
        return snapped(min(max(zoom, minimum), maximum))
    }

    /// "110%"
    static func label(for zoom: Double) -> String {
        "\(Int((zoom * 100).rounded()))%"
    }

    private static func snapped(_ zoom: Double) -> Double {
        (zoom / step).rounded() * step
    }
}

extension NSFont {
    /// Text pages' and the editor's font, at the overlay's zoom.
    static func pageText(zoom: Double) -> NSFont {
        .monospacedSystemFont(ofSize: NSFont.systemFontSize * zoom, weight: .regular)
    }

    /// Applies the zoomed font only when it changed (setting it relays out).
    static func applyPageText(zoom: Double, to textView: NSTextView) {
        let font = pageText(zoom: zoom)
        if textView.font != font {
            textView.font = font
        }
    }
}

/// Each cheatsheet's last zoom, kept across opens when "Remember zoom
/// level" is on (General settings); otherwise every open starts at 100%.
@MainActor
enum ZoomMemory {
    static let enabledKey = "remembersZoom"
    private static let levelsKey = "zoomLevels"

    static var isEnabled: Bool {
        AppDefaults.store.bool(forKey: enabledKey)
    }

    static func zoom(for sheetID: Cheatsheet.ID) -> Double {
        guard isEnabled, let stored = levels[sheetID.uuidString] else { return PageZoom.actualSize }
        return PageZoom.clamped(stored)
    }

    /// Recorded only while remembering is on; 100% removes the entry.
    static func record(_ zoom: Double, for sheetID: Cheatsheet.ID) {
        guard isEnabled else { return }
        var updated = levels
        updated[sheetID.uuidString] = zoom == PageZoom.actualSize ? nil : zoom
        AppDefaults.store.set(updated, forKey: levelsKey)
    }

    static func forgetAll() {
        AppDefaults.store.removeObject(forKey: levelsKey)
    }

    private static var levels: [String: Double] {
        AppDefaults.store.dictionary(forKey: levelsKey) as? [String: Double] ?? [:]
    }
}
