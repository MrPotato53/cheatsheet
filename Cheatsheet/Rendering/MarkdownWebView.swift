import AppKit
import SwiftUI
import WebKit

/// Renders markdown (converted to HTML) or an HTML file as-is.
struct MarkdownWebView: NSViewRepresentable {
    enum Format {
        case markdown
        case html
    }

    let url: URL
    var format: Format = .markdown
    var highlight: SearchHighlight?
    /// False for preloaded neighbor pages kept mounted but invisible.
    var isInteractive = true

    /// WebKit sets the page's cursor (asynchronously, from the web process)
    /// for every mouse move its tracking areas see — even under overlay
    /// controls drawn above it. Its tracking is filtered to skip those.
    final class OverlayAwareWebView: WKWebView {
        private var trackingFilters: [OverlayMouseTrackingFilter] = []

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingFilters += filterMouseTrackingForOverlayCursorRegions()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            trackingFilters += filterMouseTrackingForOverlayCursorRegions()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var isLoaded = false
        var wantedHighlight: SearchHighlight?
        var appliedHighlight: SearchHighlight?

        /// Marks run only once the document exists; a highlight requested
        /// mid-load is applied from didFinish.
        func applyHighlightIfReady(_ webView: WKWebView) {
            guard isLoaded, appliedHighlight != wantedHighlight else { return }
            appliedHighlight = wantedHighlight
            webView.evaluateJavaScript(WebSearchHighlighter.script(for: wantedHighlight), completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            applyHighlightIfReady(webView)
        }

        /// Clicked links open in the user's browser/mail client instead of
        /// navigating the overlay's web view; in-page anchors stay internal.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               MarkdownRenderer.opensExternally(url) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> OverlayAwareWebView {
        let webView = OverlayAwareWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.allowsMagnification = true
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: OverlayAwareWebView, context: Context) {
        // Invisible preloaded neighbors are hidden outright: a hidden view's
        // tracking areas are inactive, so WebKit can't apply the neighbor
        // page's cursor over the page actually on screen.
        webView.isHidden = !isInteractive
        let coordinator = context.coordinator
        coordinator.wantedHighlight = highlight
        guard coordinator.loadedURL != url else {
            coordinator.applyHighlightIfReady(webView)
            return
        }
        coordinator.loadedURL = url
        coordinator.isLoaded = false
        coordinator.appliedHighlight = nil
        switch format {
        case .markdown:
            webView.loadHTMLString(MarkdownRenderer.page(markdown: Self.readMarkdown(at: url)), baseURL: nil)
        case .html:
            // File load (not a string) so relative images/stylesheets that
            // were imported alongside the page resolve.
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    static func readMarkdown(at url: URL) -> String {
        TextFile.read(url) ?? ""
    }
}
