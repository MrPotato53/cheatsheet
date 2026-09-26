import AppKit
import SwiftUI
import WebKit

// Custom cursors over overlay regions (pointing hand on controls, open hand
// on the drag strip).
//
// Neither SwiftUI's pointerStyle nor window cursor rects stick in the overlay
// panel: two things keep resetting the arrow on every mouse move —
//  1. NSHostingView.cursorUpdate (SwiftUI's own cursor handling), and
//  2. WebKit, whose web process answers each mouse move over a web view with
//     a cursor, asynchronously — even where overlay controls sit above it.
// So regions register with the panel; the hosting view applies their cursor,
// and web views don't forward mouse moves from inside them.

/// Marks a region with a cursor. Click-through: the control above gets clicks.
private struct CursorRegion: NSViewRepresentable {
    let cursor: NSCursor

    final class RegionView: NSView {
        var cursor: NSCursor = .arrow

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? OverlayPanel)?.registerCursorRegion(self)
        }

        // Moving onto the region from elsewhere in the hosting view triggers
        // no cursor update of its own; entering this area applies the cursor.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            (window as? OverlayPanel)?.applyRegionCursor()
        }

        override func mouseExited(with event: NSEvent) {
            guard let panel = window as? OverlayPanel, !panel.applyRegionCursor() else { return }
            NSCursor.arrow.set()
        }
    }

    func makeNSView(context: Context) -> RegionView {
        let view = RegionView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: RegionView, context: Context) {
        nsView.cursor = cursor
    }
}

extension View {
    func pointingHandCursor() -> some View {
        background(CursorRegion(cursor: .pointingHand))
    }

    func overlayCursor(_ cursor: NSCursor) -> some View {
        background(CursorRegion(cursor: cursor))
    }
}

extension OverlayPanel {
    func registerCursorRegion(_ view: NSView) {
        cursorRegions.add(view)
    }

    /// The registered cursor at a point (window coordinates), if any.
    func regionCursor(at windowPoint: NSPoint) -> NSCursor? {
        let region = cursorRegions.allObjects.first { view in
            view.window === self && !view.isHiddenOrHasHiddenAncestor
                && view.convert(view.bounds, to: nil).contains(windowPoint)
        }
        return (region as? CursorRegion.RegionView)?.cursor
    }

    /// Re-applies the region cursor under the pointer, if any.
    @discardableResult
    func applyRegionCursor() -> Bool {
        guard let cursor = regionCursor(at: mouseLocationOutsideOfEventStream) else { return false }
        cursor.set()
        return true
    }
}

/// The overlay's root hosting view: SwiftUI's cursor handling, except inside
/// registered cursor regions. Uses the live pointer location — a cursor
/// update's own event location can be stale.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func cursorUpdate(with event: NSEvent) {
        if (window as? OverlayPanel)?.applyRegionCursor() == true { return }
        super.cursorUpdate(with: event)
    }
}

/// Stands in as owner of a web view's mouse-tracking areas, forwarding
/// everything except moves inside cursor regions — so WebKit never computes
/// (and asynchronously applies) a page cursor there. WebKit's own owner is a
/// plain NSObject, so events are forwarded by selector.
final class OverlayMouseTrackingFilter: NSResponder {
    private weak var original: NSObject?
    private weak var hostView: NSView?

    init(forwardingTo original: NSObject, in view: NSView) {
        self.original = original
        self.hostView = view
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    private func forward(_ selector: Selector, _ event: NSEvent) {
        guard let original, original.responds(to: selector) else { return }
        original.perform(selector, with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if (hostView?.window as? OverlayPanel)?.applyRegionCursor() == true { return }
        forward(#selector(NSResponder.mouseMoved(with:)), event)
    }

    override func mouseEntered(with event: NSEvent) { forward(#selector(NSResponder.mouseEntered(with:)), event) }
    override func mouseExited(with event: NSEvent) { forward(#selector(NSResponder.mouseExited(with:)), event) }
    override func cursorUpdate(with event: NSEvent) { forward(#selector(NSResponder.cursorUpdate(with:)), event) }
}

extension NSView {
    /// Re-owns this view's (and its subviews') mouse-moved tracking areas
    /// through OverlayMouseTrackingFilter. Returns the filters, which the
    /// caller must keep alive (tracking areas don't retain their owner).
    func filterMouseTrackingForOverlayCursorRegions(host: NSView? = nil) -> [OverlayMouseTrackingFilter] {
        let host = host ?? self
        var filters: [OverlayMouseTrackingFilter] = []
        for area in trackingAreas {
            guard
                area.options.contains(.mouseMoved),
                let owner = area.owner as? NSObject,
                !(owner is OverlayMouseTrackingFilter)
            else { continue }
            let filter = OverlayMouseTrackingFilter(forwardingTo: owner, in: host)
            removeTrackingArea(area)
            addTrackingArea(NSTrackingArea(rect: area.rect, options: area.options, owner: filter, userInfo: area.userInfo))
            filters.append(filter)
        }
        for subview in subviews {
            filters += subview.filterMouseTrackingForOverlayCursorRegions(host: host)
        }
        return filters
    }
}
