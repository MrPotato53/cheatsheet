import Foundation
import Markdown

/// Markdown → HTML for the overlay's web view.
///
/// swift-markdown's own `HTMLFormatter` is a debugging aid: it performs no
/// HTML escaping anywhere (text, inline code, code blocks), so any `<` in
/// content breaks the page and raw markup in code spans executes. This
/// renderer walks the parsed GFM tree and emits properly escaped HTML, and
/// turns ```mermaid fences into `<div class="mermaid">` blocks the page
/// script renders as diagrams.
nonisolated enum MarkdownRenderer {
    struct Rendered: Equatable {
        var body: String
        var usesMermaid: Bool
    }

    static func render(_ markdown: String) -> Rendered {
        var walker = HTMLWalker()
        walker.visit(Document(parsing: markdown))
        return Rendered(body: walker.html, usesMermaid: walker.usesMermaid)
    }

    /// Full HTML page: rendered body, stylesheet, and — only when the
    /// document actually contains a diagram — the bundled mermaid runtime.
    /// CSS/JS are injectable for tests; production callers use the defaults.
    static func page(
        markdown: String,
        css: String = bundledCSS,
        mermaidJS: @autoclosure () -> String = bundledMermaidJS
    ) -> String {
        let rendered = render(markdown)
        // Inline <script> content ends at the first "</script" regardless of
        // JS string context; guard against content that would truncate it.
        let mermaidBlock = rendered.usesMermaid
            ? "<script>\(mermaidJS().replacingOccurrences(of: "</script", with: "<\\/script"))</script>\n<script>\(mermaidBootJS)</script>"
            : ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style>
        </head>
        <body><article>\(rendered.body)</article>
        \(mermaidBlock)
        </body>
        </html>
        """
    }

    /// Links the user clicks should open in their browser/mail client, not
    /// navigate the overlay's web view. Anything else (in-page anchors,
    /// about:blank) stays internal.
    static func opensExternally(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto": true
        default: false
        }
    }

    // MARK: - Escaping

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escape(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Bundled resources

    static let bundledCSS: String = Bundle.main.url(forResource: "markdown", withExtension: "css")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    static var bundledMermaidJS: String {
        Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// Injected into markdown pages: code blocks get a Copy button, and task
    /// checkboxes become tickable where the host set
    /// `cheatsheetTasksEnabled` (the live overlay only). Both post
    /// to the "cheatsheet" message handler; the page never touches files.
    static let interactionJS = """
    (function () {
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cheatsheet;
      if (!handler) { return; }
      // Ticking only where the host opted in (the live overlay).
      if (window.cheatsheetTasksEnabled) document.querySelectorAll('input[type=checkbox][data-line]').forEach(function (box) {
        box.disabled = false;
        box.addEventListener('change', function () {
          handler.postMessage({ type: 'task', line: parseInt(box.dataset.line, 10), checked: box.checked });
        });
      });
      var style = document.createElement('style');
      style.textContent = 'pre{position:relative}' +
        '.cs-copy{position:absolute;top:6px;right:6px;font:11px -apple-system,sans-serif;padding:2px 8px;' +
        'border-radius:5px;border:1px solid rgba(128,128,128,.4);background:rgba(128,128,128,.15);color:inherit;' +
        'cursor:pointer;opacity:0;transition:opacity .15s}pre:hover .cs-copy{opacity:1}';
      document.head.appendChild(style);
      document.querySelectorAll('pre').forEach(function (pre) {
        var code = pre.querySelector('code');
        var fallback = pre.innerText;
        var button = document.createElement('button');
        button.className = 'cs-copy';
        button.textContent = 'Copy';
        button.addEventListener('click', function () {
          handler.postMessage({ type: 'copy', text: code ? code.innerText : fallback });
          button.textContent = 'Copied';
          setTimeout(function () { button.textContent = 'Copy'; }, 1200);
        });
        pre.appendChild(button);
      });
    })();
    """

    /// Renders each mermaid div via the explicit `mermaid.render(text)` API —
    /// reading `textContent` sidesteps entity-decoding ambiguity in mermaid's
    /// own DOM scanning. Render failures show the original source instead.
    static let mermaidBootJS = """
    (function () {
      var dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
      mermaid.initialize({ startOnLoad: false, theme: dark ? 'dark' : 'default', securityLevel: 'strict' });
      document.querySelectorAll('div.mermaid').forEach(function (el, i) {
        var src = el.textContent;
        mermaid.render('mermaid-svg-' + i, src).then(function (out) {
          el.innerHTML = out.svg;
          el.classList.add('mermaid-rendered');
        }).catch(function () {
          el.textContent = src;
          el.classList.add('mermaid-error');
        });
      });
    })();
    """
}

/// GFM tree → escaped HTML. Mirrors HTMLFormatter's structure (notably table
/// head/body/alignment and colspan/rowspan skipping) with escaping added.
private struct HTMLWalker: MarkupWalker {
    var html = ""
    var usesMermaid = false

    private var tableColumnAlignments: [Table.ColumnAlignment?] = []
    private var currentTableColumn = 0
    private var inTableHead = false

    // MARK: Blocks

    mutating func visitHeading(_ heading: Heading) {
        html += "<h\(heading.level)>"
        descendInto(heading)
        html += "</h\(heading.level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        html += "<p>"
        descendInto(paragraph)
        html += "</p>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        // The info string may carry extra tokens ("swift lineNumbers").
        let language = codeBlock.language?
            .split(separator: " ", maxSplits: 1)[0]
            .lowercased() ?? ""
        // Fences are parsed with a trailing newline; trim for tight markup.
        let code = codeBlock.code.hasSuffix("\n") ? String(codeBlock.code.dropLast()) : codeBlock.code
        if language == "mermaid" {
            usesMermaid = true
            html += "<div class=\"mermaid\">\(MarkdownRenderer.escape(code))</div>\n"
        } else if language.isEmpty {
            html += "<pre><code>\(MarkdownRenderer.escape(code))</code></pre>\n"
        } else {
            html += "<pre><code class=\"language-\(MarkdownRenderer.escapeAttribute(language))\">\(MarkdownRenderer.escape(code))</code></pre>\n"
        }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        html += "<blockquote>\n"
        descendInto(blockQuote)
        html += "</blockquote>\n"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) {
        html += "<ul>\n"
        descendInto(list)
        html += "</ul>\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) {
        if list.startIndex != 1 {
            html += "<ol start=\"\(list.startIndex)\">\n"
        } else {
            html += "<ol>\n"
        }
        descendInto(list)
        html += "</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        // Disabled until the live overlay's script enables ticking; the
        // source line lets a tick edit exactly that item.
        let line = listItem.range.map { " data-line=\"\($0.lowerBound.line)\"" } ?? ""
        switch listItem.checkbox {
        case .checked:
            html += "<li class=\"task\"><input type=\"checkbox\" checked disabled\(line)> "
        case .unchecked:
            html += "<li class=\"task\"><input type=\"checkbox\" disabled\(line)> "
        case nil:
            html += "<li>"
        }
        descendInto(listItem)
        html += "</li>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        html += "<hr />\n"
    }

    /// Raw HTML passes through, as in standard markdown. The overlay's web
    /// view is isolated (no script bridges, no base URL), and the content is
    /// the user's own local file.
    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        self.html += html.rawHTML
    }

    // MARK: Tables

    mutating func visitTable(_ table: Table) {
        html += "<table>\n"
        tableColumnAlignments = table.columnAlignments
        descendInto(table)
        tableColumnAlignments = []
        html += "</table>\n"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        html += "<thead>\n<tr>\n"
        inTableHead = true
        currentTableColumn = 0
        descendInto(tableHead)
        inTableHead = false
        html += "</tr>\n</thead>\n"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        guard !tableBody.isEmpty else { return }
        html += "<tbody>\n"
        descendInto(tableBody)
        html += "</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        html += "<tr>\n"
        currentTableColumn = 0
        descendInto(tableRow)
        html += "</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        guard currentTableColumn < tableColumnAlignments.count else { return }
        // Cells spanned over by a previous cell's colspan/rowspan.
        guard tableCell.colspan > 0, tableCell.rowspan > 0 else { return }

        let element = inTableHead ? "th" : "td"
        html += "<\(element)"
        if let alignment = tableColumnAlignments[currentTableColumn] {
            html += " align=\"\(alignment)\""
        }
        currentTableColumn += 1
        if tableCell.rowspan > 1 { html += " rowspan=\"\(tableCell.rowspan)\"" }
        if tableCell.colspan > 1 { html += " colspan=\"\(tableCell.colspan)\"" }
        html += ">"
        descendInto(tableCell)
        html += "</\(element)>\n"
    }

    // MARK: Inlines

    mutating func visitText(_ text: Text) {
        html += MarkdownRenderer.escape(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        html += "<em>"
        descendInto(emphasis)
        html += "</em>"
    }

    mutating func visitStrong(_ strong: Strong) {
        html += "<strong>"
        descendInto(strong)
        html += "</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        html += "<del>"
        descendInto(strikethrough)
        html += "</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        html += "<code>\(MarkdownRenderer.escape(inlineCode.code))</code>"
    }

    mutating func visitLink(_ link: Link) {
        if let destination = link.destination {
            html += "<a href=\"\(MarkdownRenderer.escapeAttribute(destination))\">"
        } else {
            html += "<a>"
        }
        descendInto(link)
        html += "</a>"
    }

    mutating func visitImage(_ image: Image) {
        guard let source = image.source else { return }
        let alt = image.plainText
        html += "<img src=\"\(MarkdownRenderer.escapeAttribute(source))\" alt=\"\(MarkdownRenderer.escapeAttribute(alt))\" />"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        html += inlineHTML.rawHTML
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        html += "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        html += "<br />\n"
    }
}
