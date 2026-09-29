import AppKit
import SwiftUI
import WebKit

extension EnvironmentValues {
    /// True inside an overlay, false in settings previews: overlay web
    /// pages stay loaded between opens and get navigation controls.
    @Entry var isLiveOverlay = false
}

/// A `.webloc` page: the live web page it points at.
struct WebPageView: View {
    let fileURL: URL
    var isInteractive = true
    /// Overlay pages come from LiveWebPages and survive closing; preview
    /// pages are private to this view.
    var keepsLoaded = false
    @State private var page: LiveWebPage?
    @State private var isHovering = false

    init(fileURL: URL, isInteractive: Bool = true, keepsLoaded: Bool = false) {
        self.fileURL = fileURL
        self.isInteractive = isInteractive
        self.keepsLoaded = keepsLoaded
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
            .overlay(alignment: .topLeading) {
                if keepsLoaded, isInteractive {
                    navigationControls(page)
                }
            }
            .onHover { isHovering = $0 }
        } else {
            ContentUnavailableView(
                "Can't read this web page's address",
                systemImage: "safari",
                description: Text("Remove it and add the page again.")
            )
        }
    }

    /// Faded until hovered, like the overlay's other controls.
    private func navigationControls(_ page: LiveWebPage) -> some View {
        HStack(spacing: 6) {
            control("chevron.backward", help: "Back", id: "overlay.web.back", action: page.goBack)
                .disabled(!page.canGoBack)
            control("arrow.clockwise", help: "Reload", id: "overlay.web.reload", action: page.reload)
            control("safari", help: "Open in browser", id: "overlay.web.openInBrowser", action: page.openInBrowser)
        }
        .padding(8)
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    private func control(_ systemImage: String, help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .overlayControl()
        .accessibilityIdentifier(id)
        .circleChrome()
        .help(help)
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
        if !isInteractive {
            page.pauseMedia()
        }
    }

    static func dismantleNSView(_ webView: MarkdownWebView.OverlayAwareWebView, coordinator: ()) {
        webView.pauseAllMediaPlayback(completionHandler: nil)
    }
}
