import AppKit
import SwiftUI
import WebKit

/// Ticks a markdown task checkbox in the file (source line, new state).
/// Returns false when it couldn't be applied. Set by the live overlay only,
/// so settings previews stay read-only.
typealias MarkdownTaskHandler = @MainActor (_ url: URL, _ line: Int, _ checked: Bool) -> Bool

extension EnvironmentValues {
    @Entry var markdownTaskHandler: MarkdownTaskHandler?
}

/// Renders markdown (converted to HTML) or an HTML file as-is.
struct MarkdownWebView: NSViewRepresentable {
    enum Format: String {
        case markdown
        case html

        init(_ url: URL) {
            self = MediaKind.of(url) == .html ? .html : .markdown
        }
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
        /// Routes page messages to whichever view currently owns this web
        /// view (it can move between overlays when pre-rendered).
        fileprivate var messageProxy: WeakMessageHandler?
        /// The page finished loading (DOM ready for highlights/scripts).
        var isLoadFinished = false
        /// ...and has painted a frame, so it can be shown.
        var isPageReady = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingFilters += filterMouseTrackingForOverlayCursorRegions()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            trackingFilters += filterMouseTrackingForOverlayCursorRegions()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        /// Path + modification time of what's loaded: an in-place edit reloads.
        var loadedVersion: String?
        var url: URL?
        var taskHandler: MarkdownTaskHandler?
        weak var webView: WKWebView?
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
            (webView as? OverlayAwareWebView)?.isLoadFinished = true
            isLoaded = true
            applyHighlightIfReady(webView)
            MarkdownWebView.revealWhenPainted(webView)
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

        /// Messages from `MarkdownRenderer.interactionJS`. Page content is
        /// the user's own file, but messages are still shape-checked.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "copy":
                guard let text = body["text"] as? String else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case "task":
                guard
                    let line = (body["line"] as? NSNumber)?.intValue,
                    let checked = body["checked"] as? Bool,
                    let url, let webView
                else { return }
                if taskHandler?(url, line, checked) == true {
                    // The page already shows the tick: adopt the new file
                    // version instead of reloading (which loses the scroll).
                    loadedVersion = FileStamp.versionedKey(for: url)
                } else {
                    // Out of date: show what the file really says.
                    isLoaded = false
                    MarkdownWebView.load(url, format: .markdown, into: webView)
                    loadedVersion = FileStamp.versionedKey(for: url)
                }
            default:
                return
            }
        }
    }

    /// WKUserContentController retains its handlers; this breaks the cycle
    /// web view → controller → coordinator → web view.
    fileprivate final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?

        init(_ target: WKScriptMessageHandler?) {
            self.target = target
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> OverlayAwareWebView {
        let coordinator = context.coordinator
        let tasksEnabled = context.environment.markdownTaskHandler != nil
        // A pre-rendered start page ("keep start page loaded") is adopted
        // as is: no load, no blank frame. Overlay only (it's built with
        // ticking enabled, which settings previews must not get).
        if tasksEnabled, let warm = WarmWebViews.take(url: url, format: format) {
            warm.messageProxy?.target = coordinator
            warm.navigationDelegate = coordinator
            coordinator.webView = warm
            coordinator.loadedVersion = FileStamp.versionedKey(for: url)
            coordinator.isLoaded = warm.isLoadFinished
            warm.alphaValue = warm.isPageReady ? 1 : 0
            #if DEBUG
            if warm.isPageReady {
                // Shown the moment the panel is; its window isn't set yet.
                WebRevealTiming.revealed(warm, inOverlay: true)
            }
            #endif
            return warm
        }
        let webView = Self.makeWebView(format: format, tasksEnabled: tasksEnabled, messageTarget: coordinator)
        coordinator.webView = webView
        webView.navigationDelegate = coordinator
        return webView
    }

    /// Returns a pre-rendered view to the warm cache when its overlay
    /// closes, so the next open is instant too.
    static func dismantleNSView(_ webView: OverlayAwareWebView, coordinator: Coordinator) {
        guard let url = coordinator.url, let loadedVersion = coordinator.loadedVersion, webView.isPageReady else { return }
        // Only if the page still shows the current file (not edited since).
        guard loadedVersion == FileStamp.versionedKey(for: url) else { return }
        webView.navigationDelegate = nil
        webView.messageProxy?.target = nil
        WarmWebViews.giveBack(webView, url: url, format: .init(url))
    }

    static func makeWebView(format: Format, tasksEnabled: Bool, messageTarget: WKScriptMessageHandler?) -> OverlayAwareWebView {
        let configuration = WKWebViewConfiguration()
        var proxy: WeakMessageHandler?
        if format == .markdown {
            let content = configuration.userContentController
            let handler = WeakMessageHandler(messageTarget)
            content.add(handler, name: "cheatsheet")
            proxy = handler
            if tasksEnabled {
                content.addUserScript(WKUserScript(
                    source: "window.cheatsheetTasksEnabled = true;",
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                ))
            }
            content.addUserScript(WKUserScript(
                source: MarkdownRenderer.interactionJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        let webView = OverlayAwareWebView(frame: .zero, configuration: configuration)
        webView.messageProxy = proxy
        webView.allowsMagnification = true
        // Invisible until the page has painted: a fresh web view shows a
        // blank frame first, which flashed on every open.
        webView.alphaValue = 0
        return webView
    }

    static func load(_ url: URL, format: Format, into webView: WKWebView) {
        (webView as? OverlayAwareWebView)?.isLoadFinished = false
        (webView as? OverlayAwareWebView)?.isPageReady = false
        switch format {
        case .markdown:
            webView.loadHTMLString(MarkdownRenderer.page(markdown: readMarkdown(at: url)), baseURL: nil)
        case .html:
            // File load (not a string) so relative images/stylesheets that
            // were imported alongside the page resolve.
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    /// Shows the web view once the loaded page has actually painted (two
    /// animation frames after load), so it appears complete, never blank.
    static func revealWhenPainted(_ webView: WKWebView) {
        webView.callAsyncJavaScript(
            "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));",
            arguments: [:],
            in: nil,
            in: .page
        ) { _ in
            (webView as? OverlayAwareWebView)?.isPageReady = true
            webView.alphaValue = 1
            #if DEBUG
            WebRevealTiming.revealed(webView)
            #endif
        }
    }

    func updateNSView(_ webView: OverlayAwareWebView, context: Context) {
        // Invisible preloaded neighbors are hidden outright: a hidden view's
        // tracking areas are inactive, so WebKit can't apply the neighbor
        // page's cursor over the page actually on screen.
        webView.isHidden = !isInteractive
        let coordinator = context.coordinator
        coordinator.url = url
        coordinator.taskHandler = context.environment.markdownTaskHandler
        coordinator.wantedHighlight = highlight
        let version = FileStamp.versionedKey(for: url)
        guard coordinator.loadedVersion != version else {
            coordinator.applyHighlightIfReady(webView)
            return
        }
        coordinator.loadedVersion = version
        coordinator.isLoaded = false
        coordinator.appliedHighlight = nil
        Self.load(url, format: format, into: webView)
    }

    static func readMarkdown(at url: URL) -> String {
        TextFile.read(url) ?? ""
    }
}
