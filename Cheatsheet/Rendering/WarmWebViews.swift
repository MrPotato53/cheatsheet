import AppKit
import WebKit

/// Pre-rendered web views for markdown/HTML start pages of sheets with
/// "keep start page loaded": the overlay adopts the finished view instead of
/// loading a fresh one, and hands it back when it closes. The web analogue
/// of WarmPageImages.
@MainActor
enum WarmWebViews {
    private static var views: [String: MarkdownWebView.OverlayAwareWebView] = [:]
    /// Keys the current warm set asks for; anything else is released.
    private static var wanted: Set<String> = []

    /// Keyed by file version, so an edited file never adopts a stale render.
    static func key(url: URL, format: MarkdownWebView.Format) -> String {
        "\(FileStamp.versionedKey(for: url))#\(format.rawValue)"
    }

    /// Starts rendering the page offscreen at roughly the overlay's size
    /// (layout then only adjusts, instead of reflowing from zero width).
    @discardableResult
    static func prepare(url: URL, format: MarkdownWebView.Format, size: CGSize) -> String {
        let key = key(url: url, format: format)
        wanted.insert(key)
        guard views[key] == nil else { return key }
        let webView = MarkdownWebView.makeWebView(format: format, tasksEnabled: true, messageTarget: nil)
        webView.frame = NSRect(origin: .zero, size: size)
        webView.navigationDelegate = loader
        park(webView)
        MarkdownWebView.load(url, format: format, into: webView)
        views[key] = webView
        return key
    }

    static func take(url: URL, format: MarkdownWebView.Format) -> MarkdownWebView.OverlayAwareWebView? {
        guard let webView = views.removeValue(forKey: key(url: url, format: format)) else { return nil }
        webView.removeFromSuperview()
        return webView
    }

    /// Back from a closing overlay: reset to how a fresh open looks (top of
    /// the page, no search marks) and keep it if that page is still wanted.
    static func giveBack(_ webView: MarkdownWebView.OverlayAwareWebView, url: URL, format: MarkdownWebView.Format) {
        let key = key(url: url, format: format)
        guard wanted.contains(key), views[key] == nil else { return }
        webView.evaluateJavaScript(WebSearchHighlighter.script(for: nil), completionHandler: nil)
        webView.evaluateJavaScript("window.scrollTo(0, 0);", completionHandler: nil)
        webView.navigationDelegate = loader
        views[key] = webView
        // After SwiftUI finishes tearing down the overlay it came from.
        DispatchQueue.main.async {
            if views[key] === webView {
                park(webView)
            }
        }
    }

    static func retain(only keys: Set<String>) {
        wanted = keys
        for (key, webView) in views where !keys.contains(key) {
            webView.removeFromSuperview()
        }
        views = views.filter { keys.contains($0.key) }
    }

    /// WebKit doesn't paint a web view that's in no window (or in an
    /// occluded one), so "pre-rendered" views wait in a transparent,
    /// click-through panel on screen: fully laid out and painted, invisible.
    private static let parking: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient, .fullScreenAuxiliary]
        panel.contentView = NSView()
        panel.setAccessibilityElement(false)
        return panel
    }()

    private static func park(_ webView: NSView) {
        let size = webView.frame.size
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let frame = NSRect(
                x: visible.minX,
                y: visible.minY,
                width: max(parking.frame.width, size.width),
                height: max(parking.frame.height, size.height)
            )
            parking.setFrame(frame, display: false)
        }
        webView.frame = NSRect(origin: .zero, size: size)
        parking.contentView?.addSubview(webView)
        parking.orderFrontRegardless()
    }

    static var cachedCount: Int { views.count }
    static var readyCount: Int { views.values.filter(\.isPageReady).count }

    /// Marks warm views ready once painted, like an overlay's coordinator.
    private static let loader = Loader()

    private final class Loader: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            (webView as? MarkdownWebView.OverlayAwareWebView)?.isLoadFinished = true
            MarkdownWebView.revealWhenPainted(webView)
        }
    }
}

#if DEBUG
/// UI-test measurement: time from an overlay opening to its web page
/// becoming visible. Pre-rendered pages should show at once.
@MainActor
enum WebRevealTiming {
    static var openedAt: Date?
    private(set) static var lastDelayMs: Double?

    static func overlayOpened() {
        openedAt = Date()
        lastDelayMs = nil
    }

    static func revealed(_ webView: NSView, inOverlay: Bool = false) {
        guard let openedAt, inOverlay || webView.window is OverlayPanel else { return }
        lastDelayMs = Date().timeIntervalSince(openedAt) * 1000
        self.openedAt = nil
    }
}
#endif
