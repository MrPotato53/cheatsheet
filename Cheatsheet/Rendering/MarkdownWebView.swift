import Markdown
import SwiftUI
import WebKit

struct MarkdownWebView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.allowsMagnification = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        let markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let body = HTMLFormatter.format(Document(parsing: markdown))
        webView.loadHTMLString(Self.htmlPage(body: body), baseURL: nil)
    }

    private static func htmlPage(body: String) -> String {
        let css = Bundle.main.url(forResource: "markdown", withExtension: "css")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style>
        </head>
        <body><article>\(body)</article></body>
        </html>
        """
    }
}
