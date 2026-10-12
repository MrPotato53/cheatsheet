import AppKit
import SwiftUI

/// Shows a fitted page (PDF page, image) at the overlay's zoom, scrollable
/// once it outgrows the overlay. AppKit scrolling rather than SwiftUI's
/// ScrollView: wheel events reach NSScrollView in the non-activating panel
/// even while the app is inactive (see TextFileView).
struct ZoomScrollView<Content: View>: NSViewRepresentable {
    let zoom: Double
    /// The overlay's page area. Passed in (from a GeometryReader) rather
    /// than read off the scroll view, so resizing the overlay updates it.
    let viewport: CGSize
    /// False for preloaded neighbor pages: hidden, so they never take the
    /// wheel or cursor from the visible page.
    let isInteractive: Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        // Sized here (to the zoomed page), never by its content.
        hosting.sizingOptions = []
        scrollView.documentView = hosting
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        scrollView.isHidden = !isInteractive
        guard let hosting = scrollView.documentView as? NSHostingView<AnyView> else { return }
        let zoomed = CGSize(width: viewport.width * zoom, height: viewport.height * zoom)
        // Zoomed out, the page sits centered in the overlay.
        let document = CGSize(width: max(viewport.width, zoomed.width), height: max(viewport.height, zoomed.height))
        hosting.rootView = AnyView(
            content()
                .frame(width: zoomed.width, height: zoomed.height)
                .frame(width: document.width, height: document.height)
        )
        resize(hosting, to: document, in: scrollView)
    }

    /// Keeps the spot at the center of the overlay centered while zooming.
    private func resize(_ documentView: NSView, to size: CGSize, in scrollView: NSScrollView) {
        let old = documentView.frame.size
        guard old != size else { return }
        let clip = scrollView.contentView
        let visible = clip.bounds
        let center = old.width > 0 && old.height > 0
            ? CGPoint(x: visible.midX / old.width, y: visible.midY / old.height)
            : CGPoint(x: 0.5, y: 0.5)
        documentView.setFrameSize(size)
        let origin = CGPoint(
            x: min(max(center.x * size.width - visible.width / 2, 0), max(size.width - visible.width, 0)),
            y: min(max(center.y * size.height - visible.height / 2, 0), max(size.height - visible.height, 0))
        )
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
