import AppKit
import SwiftUI
import WebKit

extension EnvironmentValues {
    /// True inside an overlay, false in settings previews: overlay web
    /// pages stay loaded between opens (their navigation buttons are in
    /// OverlayToolbar).
    @Entry var isLiveOverlay = false
    /// Called when a shown web page finishes loading (a new document), so
    /// an open search can recount it.
    @Entry var webPageDidLoad: (@MainActor () -> Void)?
    /// Called for ←/→ a clicked-into web page didn't use (WebArrowKeys):
    /// true for the next cheatsheet page.
    @Entry var webPageUnusedArrowKey: (@MainActor (_ forward: Bool) -> Void)?
}

/// A `.webloc` page: the live web page it points at.
struct WebPageView: View {
    let fileURL: URL
    var isInteractive = true
    /// Overlay pages come from LiveWebPages and survive closing; preview
    /// pages are private to this view.
    var keepsLoaded = false
    /// Search matches to mark in the page, if a search is active.
    var highlight: SearchHighlight?
    @State private var page: LiveWebPage?
    @Environment(\.webPageDidLoad) private var webPageDidLoad
    @Environment(\.webPageUnusedArrowKey) private var webPageUnusedArrowKey

    init(fileURL: URL, isInteractive: Bool = true, keepsLoaded: Bool = false, highlight: SearchHighlight? = nil) {
        self.fileURL = fileURL
        self.isInteractive = isInteractive
        self.keepsLoaded = keepsLoaded
        self.highlight = highlight
        // Cheap: the page's web view is only made once it's displayed.
        let address = WebLocation.url(fromFileAt: fileURL)
        _page = State(initialValue: address.map { address in
            keepsLoaded
                ? LiveWebPages.page(forFile: fileURL, address: address)
                : LiveWebPage(address: address)
        })
    }

    var body: some View {
        if let page {
            ZStack {
                WebPageRepresentable(page: page, isInteractive: isInteractive)
                if let failure = page.failure {
                    failureView(failure, page: page)
                } else if !page.hasContent {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .onChange(of: highlight, initial: true) { page.setHighlight(highlight) }
            .onChange(of: page.loadCount) { webPageDidLoad?() }
            .onAppear {
                if keepsLoaded { page.onUnusedArrowKey = webPageUnusedArrowKey }
            }
        } else {
            ContentUnavailableView(
                "Can't read this web page's address",
                systemImage: "safari",
                description: Text("Remove it and add the page again.")
            )
        }
    }

    private func failureView(_ failure: String, page: LiveWebPage) -> some View {
        ContentUnavailableView {
            Label("Couldn't load \(page.address.host() ?? "the page")", systemImage: "wifi.exclamationmark")
        } description: {
            Text(failure)
        } actions: {
            HStack {
                Button("Try Again", action: page.reload)
                    .accessibilityIdentifier("overlay.web.retry")
                Button("Open in Browser", action: page.openInBrowser)
            }
        }
        .background(.regularMaterial)
        .accessibilityIdentifier("overlay.web.failure")
    }
}

/// Hosts the page's own web view, which can move between overlays.
private struct WebPageRepresentable: NSViewRepresentable {
    let page: LiveWebPage
    let isInteractive: Bool

    func makeNSView(context: Context) -> MarkdownWebView.OverlayAwareWebView {
        page.webView
    }

    func updateNSView(_ webView: MarkdownWebView.OverlayAwareWebView, context: Context) {
        // Preloaded neighbor pages are hidden outright (as with markdown):
        // their tracking areas must not set the visible page's cursor.
        webView.isHidden = !isInteractive
        webView.applyZoom(context.environment.pageZoom)
        if !isInteractive {
            page.pauseMedia()
        }
    }

    static func dismantleNSView(_ webView: MarkdownWebView.OverlayAwareWebView, coordinator: ()) {
        webView.pauseAllMediaPlayback(completionHandler: nil)
    }
}
