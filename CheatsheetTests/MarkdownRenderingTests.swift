import Foundation
import Testing
import WebKit

@testable import Cheatsheet

/// Pure markdown → HTML conversion (no web view involved).
struct MarkdownRendererTests {
    // MARK: Structure

    @Test func headingsRenderAtEachLevel() {
        let body = MarkdownRenderer.render("# Title\n\n## Section\n\n### Sub").body
        #expect(body.contains("<h1>Title</h1>"))
        #expect(body.contains("<h2>Section</h2>"))
        #expect(body.contains("<h3>Sub</h3>"))
    }

    @Test func gfmTableRendersHeadBodyAndAlignment() {
        let markdown = """
        | Name | Score |
        |:-----|------:|
        | Ana  | 10    |
        | Bo   | 7     |
        """
        let body = MarkdownRenderer.render(markdown).body
        #expect(body.contains("<table>"))
        #expect(body.contains("<thead>"))
        #expect(body.contains("<th align=\"left\">Name</th>"))
        #expect(body.contains("<th align=\"right\">Score</th>"))
        #expect(body.contains("<tbody>"))
        #expect(body.contains("<td align=\"left\">Ana</td>"))
        #expect(body.contains("<td align=\"right\">10</td>"))
    }

    @Test func linksKeepDestinationAndAutolinksWork() {
        let body = MarkdownRenderer.render("[docs](https://example.com/a?b=1) and <https://swift.org>").body
        #expect(body.contains("<a href=\"https://example.com/a?b=1\">docs</a>"))
        #expect(body.contains("<a href=\"https://swift.org\">https://swift.org</a>"))
    }

    @Test func listsOrderedUnorderedAndTasks() {
        let markdown = """
        - plain
        - [x] done
        - [ ] todo

        3. third
        4. fourth
        """
        let body = MarkdownRenderer.render(markdown).body
        #expect(body.contains("<ul>"))
        #expect(body.contains("<li class=\"task\"><input type=\"checkbox\" checked disabled data-line="))
        #expect(body.contains("<li class=\"task\"><input type=\"checkbox\" disabled data-line="))
        #expect(body.contains("<ol start=\"3\">"))
    }

    @Test func inlineStylesAndBlocksRender() {
        let markdown = "**bold** *em* ~~gone~~ `code`\n\n> quote\n\n---"
        let body = MarkdownRenderer.render(markdown).body
        #expect(body.contains("<strong>bold</strong>"))
        #expect(body.contains("<em>em</em>"))
        #expect(body.contains("<del>gone</del>"))
        #expect(body.contains("<code>code</code>"))
        #expect(body.contains("<blockquote>"))
        #expect(body.contains("<hr />"))
    }

    // MARK: Escaping (swift-markdown's HTMLFormatter does none — regression guard)

    @Test func textAndCodeAreHTMLEscaped() {
        let markdown = """
        1 < 2 & `a < b`

        ```
        if x < 3 && y > 4 { <script>alert(1)</script> }
        ```
        """
        let body = MarkdownRenderer.render(markdown).body
        #expect(body.contains("1 &lt; 2 &amp;"))
        #expect(body.contains("<code>a &lt; b</code>"))
        #expect(body.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!body.contains("<script>alert(1)</script>"))
    }

    @Test func linkDestinationsAreAttributeEscaped() {
        let body = MarkdownRenderer.render("[x](https://e.com/?a=\"1\"&b='2')").body
        #expect(body.contains("href=\"https://e.com/?a=%221%22&amp;b=&#39;2&#39;\"")
            || body.contains("href=\"https://e.com/?a=&quot;1&quot;&amp;b=&#39;2&#39;\""))
        #expect(!body.contains("href=\"https://e.com/?a=\"1\""))
    }

    // MARK: Code blocks and mermaid

    @Test func fencedCodeKeepsLanguageClass() {
        let rendered = MarkdownRenderer.render("```swift\nlet x = 1\n```")
        #expect(rendered.body.contains("<pre><code class=\"language-swift\">let x = 1</code></pre>"))
        #expect(!rendered.usesMermaid)
    }

    @Test func mermaidFenceBecomesDiagramDiv() {
        let rendered = MarkdownRenderer.render("```mermaid\ngraph TD; A-->B;\n```")
        #expect(rendered.usesMermaid)
        #expect(rendered.body.contains("<div class=\"mermaid\">graph TD; A--&gt;B;</div>"))
        #expect(!rendered.body.contains("<pre><code class=\"language-mermaid\">"))
    }

    // MARK: Page assembly

    @Test func pageInlinesMermaidRuntimeOnlyWhenNeeded() {
        let plain = MarkdownRenderer.page(markdown: "# Hi", css: "", mermaidJS: "MERMAID_RUNTIME")
        #expect(!plain.contains("MERMAID_RUNTIME"))

        let diagram = MarkdownRenderer.page(
            markdown: "```mermaid\ngraph TD; A-->B;\n```",
            css: "",
            mermaidJS: "MERMAID_RUNTIME"
        )
        #expect(diagram.contains("MERMAID_RUNTIME"))
        #expect(diagram.contains("mermaid.initialize"))
    }

    @Test func inlineScriptCannotBeTerminatedByRuntimeContent() {
        let page = MarkdownRenderer.page(
            markdown: "```mermaid\ngraph TD;\n```",
            css: "",
            mermaidJS: "var x = \"</script><script>alert(1)\";"
        )
        #expect(!page.contains("</script><script>alert(1)"))
    }

    @Test func bundledResourcesArePresent() {
        // The real app inlines these; empty means a packaging regression.
        #expect(!MarkdownRenderer.bundledCSS.isEmpty)
        #expect(!MarkdownRenderer.bundledMermaidJS.isEmpty)
    }

    // MARK: Link policy

    @Test func onlyWebAndMailLinksOpenExternally() throws {
        #expect(MarkdownRenderer.opensExternally(try #require(URL(string: "https://example.com"))))
        #expect(MarkdownRenderer.opensExternally(try #require(URL(string: "http://example.com"))))
        #expect(MarkdownRenderer.opensExternally(try #require(URL(string: "mailto:a@b.c"))))
        #expect(!MarkdownRenderer.opensExternally(try #require(URL(string: "about:blank"))))
        #expect(!MarkdownRenderer.opensExternally(try #require(URL(string: "about:blank#anchor"))))
        #expect(!MarkdownRenderer.opensExternally(try #require(URL(string: "file:///etc/hosts"))))
    }

    @Test func markdownExtensionsMapToMarkdownKind() {
        #expect(MediaKind.of(URL(fileURLWithPath: "/tmp/a.md")) == .markdown)
        #expect(MediaKind.of(URL(fileURLWithPath: "/tmp/a.markdown")) == .markdown)
    }

    @Test func htmlExtensionsMapToHTMLKind() {
        #expect(MediaKind.of(URL(fileURLWithPath: "/tmp/a.html")) == .html)
        #expect(MediaKind.of(URL(fileURLWithPath: "/tmp/a.HTM")) == .html)
    }

    @Test func onlyMarkupKindsHaveARawView() {
        #expect(MediaKind.markdown.hasRawView)
        #expect(MediaKind.html.hasRawView)
        #expect(!MediaKind.text.hasRawView)
        #expect(!MediaKind.pdf.hasRawView)
        #expect(!MediaKind.image.hasRawView)
    }

    @Test func nonUTF8FilesStillProduceContent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let utf16 = dir.appendingPathComponent("utf16.md")
        try "# Café UTF-16".data(using: .utf16)!.write(to: utf16)
        #expect(MarkdownWebView.readMarkdown(at: utf16).contains("Café UTF-16"))

        let latin1 = dir.appendingPathComponent("latin1.md")
        try "# Caf\u{E9} Latin".data(using: .isoLatin1)!.write(to: latin1)
        #expect(MarkdownWebView.readMarkdown(at: latin1).contains("Latin"))

        let missing = dir.appendingPathComponent("nope.md")
        #expect(MarkdownWebView.readMarkdown(at: missing).isEmpty)
    }
}

/// End-to-end markdown rendering. These run hosted inside the sandboxed app
/// (TEST_HOST), so a WKWebView here behaves exactly like the overlay's —
/// including sandbox-related failures that a plain string test can't see.
@MainActor
struct MarkdownWebRenderingTests {
    /// Loads HTML into a real WKWebView and polls until the rendered body
    /// text is non-empty (or times out). Returns the rendered text.
    private func renderedText(
        html: String,
        timeout: TimeInterval = 10,
        until ready: @escaping (String) -> Bool = { !$0.isEmpty }
    ) async -> String {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        let deadline = Date(timeIntervalSinceNow: timeout)
        var last = ""
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            let value = try? await webView.evaluateJavaScript("document.body ? document.body.innerText : ''")
            if let text = value as? String {
                last = text
                if ready(text) { return text }
            }
        }
        return last
    }

    @Test func webViewRendersPlainHTMLInSandbox() async {
        let text = await renderedText(html: "<html><body><p>hello sandbox</p></body></html>")
        #expect(text.contains("hello sandbox"), "WKWebView rendered nothing — web content process likely dying in the sandbox")
    }

    /// The full production path: markdown → MarkdownRenderer.page → WKWebView,
    /// asserting the *visible* text. Guards the "imported an .md and saw a
    /// blank page" failure a parse-only test can't catch.
    @Test func markdownPageShowsHeadingTableAndLinkText() async {
        let markdown = """
        # Shortcuts

        | Key | Action |
        |-----|--------|
        | ⌘S  | Save   |

        [Manual](https://example.com)
        """
        let text = await renderedText(html: MarkdownRenderer.page(markdown: markdown))
        #expect(text.contains("Shortcuts"), "heading text missing from rendered page")
        #expect(text.contains("⌘S") && text.contains("Save"), "table content missing from rendered page")
        #expect(text.contains("Manual"), "link text missing from rendered page")
    }

    @Test func mermaidDiagramRendersToSVG() async {
        let markdown = """
        ```mermaid
        graph TD; Start-->Finish;
        ```
        """
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        webView.loadHTMLString(MarkdownRenderer.page(markdown: markdown), baseURL: nil)
        // Mermaid evaluates a ~2.6 MB runtime and renders async; poll for the
        // terminal marker classes rather than a fixed sleep.
        let deadline = Date(timeIntervalSinceNow: 20)
        var state = ""
        while Date() < deadline, state != "rendered", state != "error" {
            try? await Task.sleep(for: .milliseconds(250))
            let value = try? await webView.evaluateJavaScript(
                "document.querySelector('.mermaid-rendered svg') ? 'rendered' : (document.querySelector('.mermaid-error') ? 'error' : '')"
            )
            state = (value as? String) ?? ""
        }
        #expect(state == "rendered", "mermaid did not produce an SVG (state: \(state.isEmpty ? "timeout" : state))")
    }
}
