import AppKit
import Observation
import WebKit

/// One web page cheatsheet page and the web view showing it. In overlays
/// it outlives the overlay (see LiveWebPages), so reopening shows the page
/// as it was left instead of loading it again.
///
/// Cookies live in WebKit's default store (the app's own, separate from
/// Safari's), so a site signed into here usually stays signed in. That's a
/// bonus, not a promise: some sites block sign-in inside apps.
@Observable
@MainActor
final class LiveWebPage {
    let address: URL
    private(set) var canGoBack = false
    /// The first page has started showing; until then a spinner covers it.
    private(set) var hasContent = false
    /// Why the last load failed; nil once a load succeeds.
    private(set) var failure: String?
    /// Bumped each time a page finishes loading, so an open search can
    /// recount the new page.
    private(set) var loadCount = 0

    /// Search marks: wanted by the overlay, and what the current document
    /// carries (a newly loaded document carries none).
    @ObservationIgnored private var wantedHighlight: SearchHighlight?
    @ObservationIgnored private var appliedHighlight: SearchHighlight?
    @ObservationIgnored private var isLoadFinished = false

    @ObservationIgnored private var storedWebView: MarkdownWebView.OverlayAwareWebView?
    @ObservationIgnored private var navigator: Navigator?
    @ObservationIgnored private var backObservation: NSKeyValueObservation?
    /// What a Retry should load: the page that failed, not the start page.
    @ObservationIgnored private var failedURL: URL?

    init(address: URL) {
        self.address = address
    }

    /// Created (and the page requested) on first use, so a page that's
    /// never shown never touches the network.
    var webView: MarkdownWebView.OverlayAwareWebView {
        if let storedWebView {
            return storedWebView
        }
        let webView = MarkdownWebView.OverlayAwareWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let navigator = Navigator(page: self)
        webView.navigationDelegate = navigator
        webView.uiDelegate = navigator
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = true
        backObservation = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
            let canGoBack = webView.canGoBack
            MainActor.assumeIsolated {
                self?.canGoBack = canGoBack
            }
        }
        self.navigator = navigator
        storedWebView = webView
        webView.load(URLRequest(url: address))
        return webView
    }

    /// Where the page is now (after links and redirects).
    var currentURL: URL? {
        storedWebView?.url
    }

    /// Whether the web view is showing in some window right now.
    var isOnScreen: Bool {
        storedWebView?.window != nil
    }

    func goBack() {
        storedWebView?.goBack()
    }

    func reload() {
        guard let webView = storedWebView else { return }
        if let failedURL {
            failure = nil
            webView.load(URLRequest(url: failedURL))
        } else if webView.url == nil {
            webView.load(URLRequest(url: address))
        } else {
            webView.reload()
        }
    }

    func openInBrowser() {
        LiveWebPages.openInBrowser(failedURL ?? storedWebView?.url ?? address)
    }

    /// Off screen (overlay closed or paging away): nothing keeps playing.
    func pauseMedia() {
        storedWebView?.pauseAllMediaPlayback(completionHandler: nil)
    }

    /// Marks search matches, now or once the page has loaded.
    func setHighlight(_ highlight: SearchHighlight?) {
        wantedHighlight = highlight
        applyHighlightIfReady()
    }

    /// How many matches for `query` the loaded page shows; 0 until it has
    /// loaded. Counting clears the marks, so they're re-applied after.
    func matchCount(for query: String) async -> Int {
        guard isLoadFinished, let webView = storedWebView else { return 0 }
        appliedHighlight = nil
        let result = try? await webView.evaluateJavaScript(WebSearchHighlighter.countScript(for: query))
        applyHighlightIfReady()
        return (result as? NSNumber)?.intValue ?? 0
    }

    private func applyHighlightIfReady() {
        guard isLoadFinished, let webView = storedWebView, appliedHighlight != wantedHighlight else { return }
        appliedHighlight = wantedHighlight
        webView.evaluateJavaScript(WebSearchHighlighter.script(for: wantedHighlight), completionHandler: nil)
    }

    fileprivate func didCommit() {
        hasContent = true
        failure = nil
        failedURL = nil
        isLoadFinished = false
        appliedHighlight = nil
    }

    fileprivate func didFinish() {
        isLoadFinished = true
        applyHighlightIfReady()
        loadCount += 1
    }

    fileprivate func didFail(_ error: Error) {
        let nsError = error as NSError
        // A newer load replaced this one, or a link was sent to the browser.
        let isInterruption = (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == WKError.errorDomain && nsError.code == 102)
        guard !isInterruption else { return }
        failedURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? storedWebView?.url ?? address
        failure = nsError.localizedDescription
    }

    /// Link routing: same-site pages stay here, other sites, new windows
    /// and downloads go to the user's browser. Only clicks are routed, so
    /// redirects (sign-in flows included) are left alone.
    private final class Navigator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var page: LiveWebPage?

        init(page: LiveWebPage) {
            self.page = page
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            let opensElsewhere: Bool
            if navigationAction.navigationType == .linkActivated, isMainFrame {
                let route = WebLocation.route(
                    for: url,
                    from: webView.url,
                    commandPressed: navigationAction.modifierFlags.contains(.command)
                )
                opensElsewhere = route == .openInBrowser
            } else {
                // Redirects to app links (mailto:, zoommtg:…) can't load here.
                opensElsewhere = isMainFrame && !Self.loadsInPage(url)
            }
            if opensElsewhere {
                LiveWebPages.openInBrowser(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            // Downloads (anything WebKit can't display) go to the browser.
            if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType,
               let url = navigationResponse.response.url {
                LiveWebPages.openInBrowser(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// target=_blank links and window.open: no tabs or pop-ups here.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, url.scheme != "about" {
                LiveWebPages.openInBrowser(url)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            page?.didCommit()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            page?.didFinish()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            page?.didFail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            page?.didFail(error)
        }

        /// The page's process crashed or was reclaimed: bring it back.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        private static func loadsInPage(_ url: URL) -> Bool {
            let scheme = url.scheme?.lowercased() ?? ""
            return WebLocation.isWebScheme(url) || ["about", "data", "blob"].contains(scheme)
        }
    }
}

/// Overlay web pages, kept loaded after their overlay closes so reopening
/// is instant and keeps the page where it was. Keyed by the page's file and
/// address, so a changed address loads fresh. Bounded: the least recently
/// shown page that isn't on screen is dropped first.
@MainActor
enum LiveWebPages {
    static let limit = 6
    private static var pages: [String: LiveWebPage] = [:]
    /// Keys, least recently used first.
    private static var recency: [String] = []

    static func page(forFile fileURL: URL, address: URL) -> LiveWebPage {
        let key = key(file: fileURL, address: address)
        recency.removeAll { $0 == key }
        recency.append(key)
        if let page = pages[key] {
            return page
        }
        let page = LiveWebPage(address: address)
        pages[key] = page
        evictIfNeeded()
        return page
    }

    /// The kept page for a `.webloc`, if one exists; unlike `page(forFile:)`
    /// it neither creates one nor counts as a use.
    static func existingPage(forFile fileURL: URL) -> LiveWebPage? {
        guard let address = WebLocation.url(fromFileAt: fileURL) else { return nil }
        return pages[key(file: fileURL, address: address)]
    }

    private static func key(file fileURL: URL, address: URL) -> String {
        "\(fileURL.path)#\(address.absoluteString)"
    }

    private static func evictIfNeeded() {
        while pages.count > limit,
              let victim = recency.first(where: { pages[$0]?.isOnScreen == false }) {
            pages[victim] = nil
            recency.removeAll { $0 == victim }
        }
    }

    /// Links leaving the overlay. UI tests record them instead of
    /// opening the tester's browser.
    static func openInBrowser(_ url: URL) {
        #if DEBUG
        if UITestMode.isActive {
            debugBrowserOpens.append(url.absoluteString)
            return
        }
        #endif
        NSWorkspace.shared.open(url)
    }

    #if DEBUG
    static var debugBrowserOpens: [String] = []

    /// For UI tests: a link click in the page on screen.
    static func clickOnScreen(selector: String) {
        guard let page = pages.values.first(where: \.isOnScreen) else { return }
        page.webView.callAsyncJavaScript(
            "document.querySelector(selector)?.click();",
            arguments: ["selector": selector],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    /// For UI tests: each kept page's load state.
    static var debugSummary: [[String: Any]] {
        recency.compactMap { pages[$0] }.map { page in
            [
                "address": page.address.absoluteString,
                "currentURL": page.currentURL?.absoluteString ?? "",
                "hasContent": page.hasContent,
                "failure": page.failure ?? "",
                "onScreen": page.isOnScreen,
            ]
        }
    }
    #endif
}
