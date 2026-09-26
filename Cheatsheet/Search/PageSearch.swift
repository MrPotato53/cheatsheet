import Foundation
import PDFKit
import Vision

/// What a page view should highlight: every occurrence of `query`, with the
/// occurrence at `activeIndex` (if any) emphasized and scrolled into view.
nonisolated struct SearchHighlight: Equatable {
    let query: String
    let activeIndex: Int?
}

/// Per-page match counts plus navigation over the flattened occurrence list
/// (occurrence k = the k-th match counting across pages in order).
nonisolated struct SearchMatches: Equatable {
    let counts: [Int]
    private let offsets: [Int]

    init(counts: [Int]) {
        self.counts = counts
        var running = 0
        offsets = counts.map { count in
            defer { running += count }
            return running
        }
    }

    static let empty = SearchMatches(counts: [])

    var total: Int { counts.reduce(0, +) }

    func location(of match: Int) -> (page: Int, local: Int)? {
        guard match >= 0 else { return nil }
        // Pages before the holder all end at or before `match`.
        for page in counts.indices where match < offsets[page] + counts[page] {
            return (page, match - offsets[page])
        }
        return nil
    }

    /// Active occurrence on `page`, when `match` falls on it.
    func localIndex(of match: Int?, onPage page: Int) -> Int? {
        guard let match, let location = location(of: match), location.page == page else { return nil }
        return location.local
    }

    /// Next/previous occurrence. Continues from `current` while the user is
    /// still on its page; after paging elsewhere by hand, resumes from that
    /// page instead. Wraps around at either end.
    func step(from current: Int?, pageIndex: Int, forward: Bool) -> Int? {
        let total = total
        guard total > 0 else { return nil }
        if let current, location(of: current)?.page == pageIndex {
            return forward ? (current + 1) % total : (current - 1 + total) % total
        }
        if forward {
            let page = counts.indices.first { $0 >= pageIndex && counts[$0] > 0 }
            return page.map { offsets[$0] } ?? 0
        }
        let page = counts.indices.last { $0 <= pageIndex && counts[$0] > 0 }
        return page.map { offsets[$0] + counts[$0] - 1 } ?? total - 1
    }

    /// First occurrence on or after `pageIndex` (wrapping), for a new query.
    func first(fromPage pageIndex: Int) -> Int? {
        step(from: nil, pageIndex: pageIndex, forward: true)
    }
}

/// Case-insensitive text search over sheet pages. Text pages are matched on
/// what the reader sees (rendered text for formatted markdown/HTML, source for
/// raw), PDFs through PDFKit's text layer, images through on-device text
/// recognition (ImageTextIndex).
nonisolated enum PageSearch {
    static func matchCounts(query: String, pages: [SheetPage]) async -> [Int] {
        guard !query.isEmpty else { return pages.map { _ in 0 } }
        var pdfCounts: [URL: [Int: Int]] = [:]
        var counts: [Int] = []
        for page in pages {
            switch MediaKind.of(page.url) {
            case .pdf:
                if pdfCounts[page.url] == nil {
                    pdfCounts[page.url] = pdfMatchCountsByPage(query: query, url: page.url)
                }
                counts.append(pdfCounts[page.url]?[page.pdfPageIndex ?? 0] ?? 0)
            case .markdown, .html, .text:
                counts.append(searchableText(for: page).map { ranges(of: query, in: $0).count } ?? 0)
            case .image:
                counts.append(await imageMatchRects(query: query, url: page.url).count)
            case .unsupported:
                counts.append(0)
            }
        }
        return counts
    }

    /// Starts text recognition for a sheet's images in the background, so
    /// the first query doesn't wait on it.
    static func prepare(_ pages: [SheetPage]) {
        let images = Set(pages.map(\.url).filter { MediaKind.of($0) == .image })
        guard !images.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in images {
                _ = await ImageTextIndex.shared.lines(for: url)
            }
        }
    }

    /// Match boxes in an image, in unit coordinates (top-left origin), in
    /// reading order. Matches never span recognized lines.
    static func imageMatchRects(query: String, url: URL) async -> [CGRect] {
        guard !query.isEmpty else { return [] }
        var rects: [CGRect] = []
        for line in await ImageTextIndex.shared.lines(for: url) {
            // The most confident reading that contains the query; counting
            // matches from one reading only keeps them from doubling up.
            guard let (text, found) = line.candidates.lazy
                .map({ ($0, imageRanges(of: query, in: $0.string)) })
                .first(where: { !$0.1.isEmpty })
            else { continue }
            let string = text.string
            for range in found {
                let word = ImageMatchGeometry.enclosingWordRange(of: range, in: string)
                guard
                    let bounds = Range(word, in: string),
                    let box = text.boundingBox(for: bounds)
                else { continue }
                let wordBox = ImageTextIndex.unitRect(box.boundingBox)
                rects.append(ImageMatchGeometry.matchRect(range, word: word, in: string, wordBox: wordBox))
            }
        }
        return rects
    }

    /// Matches in recognized image text, where glyphs that look identical in
    /// common UI fonts can't be told apart reliably: I, l, 1, | (and, since
    /// search ignores case, i) all match each other, as do O and 0.
    static func imageRanges(of query: String, in text: String) -> [NSRange] {
        ranges(of: foldingConfusables(query), in: foldingConfusables(text))
    }

    private static let confusableClasses: [(members: String, canonical: unichar)] = [
        ("Il1|iL", unichar(UInt8(ascii: "l"))),
        ("Oo0", unichar(UInt8(ascii: "o"))),
    ]

    /// Maps each look-alike character to its class's canonical letter, one
    /// UTF-16 unit for one, so ranges in the result apply to the original.
    static func foldingConfusables(_ text: String) -> String {
        let units = text.utf16.map { unit -> unichar in
            confusableClasses.first { $0.members.utf16.contains(unit) }?.canonical ?? unit
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    static func ranges(of query: String, in text: String) -> [NSRange] {
        let string = text as NSString
        guard !query.isEmpty, string.length > 0 else { return [] }
        var found: [NSRange] = []
        var searchRange = NSRange(location: 0, length: string.length)
        while true {
            let match = string.range(of: query, options: [.caseInsensitive], range: searchRange)
            guard match.location != NSNotFound, match.length > 0 else { break }
            found.append(match)
            let next = match.location + match.length
            guard next < string.length else { break }
            searchRange = NSRange(location: next, length: string.length - next)
        }
        return found
    }

    static func searchableText(for page: SheetPage) -> String? {
        guard let source = TextFile.read(page.url) else { return nil }
        switch MediaKind.of(page.url) {
        case .markdown where !page.showsRaw:
            return visibleText(ofHTML: MarkdownRenderer.render(source).body)
        case .html where !page.showsRaw:
            return visibleText(ofHTML: source)
        default:
            return source
        }
    }

    /// Text content of an HTML document as a reader sees it: tags removed,
    /// entities decoded, and non-displayed content (head, scripts, styles,
    /// comments, mermaid diagram source) dropped.
    static func visibleText(ofHTML html: String) -> String {
        var text = html
        for pattern in hiddenBlockPatterns {
            text = pattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " "
            )
        }
        text = tagPattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        )
        return decodeEntities(text)
    }

    static func pdfSelections(query: String, url: URL, pageIndex: Int) -> [PDFSelection] {
        guard !query.isEmpty, let document = PDFCache.document(at: url) else { return [] }
        return document.findString(query, withOptions: [.caseInsensitive]).filter { selection in
            selection.pages.first.map { document.index(for: $0) } == pageIndex
        }
    }

    private static func pdfMatchCountsByPage(query: String, url: URL) -> [Int: Int] {
        guard let document = PDFCache.document(at: url) else { return [:] }
        var counts: [Int: Int] = [:]
        for selection in document.findString(query, withOptions: [.caseInsensitive]) {
            guard let page = selection.pages.first else { continue }
            counts[document.index(for: page), default: 0] += 1
        }
        return counts
    }

    private static let hiddenBlockPatterns: [NSRegularExpression] = [
        #"<!--.*?-->"#,
        #"<head\b[^>]*>.*?</head\s*>"#,
        #"<script\b[^>]*>.*?</script\s*>"#,
        #"<style\b[^>]*>.*?</style\s*>"#,
        #"<div class="mermaid">.*?</div>"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive, .dotMatchesLineSeparators]) }

    private static let tagPattern = try! NSRegularExpression(pattern: #"<[^>]*>"#)
    private static let entityPattern = try! NSRegularExpression(pattern: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);"#)
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    ]

    private static func decodeEntities(_ text: String) -> String {
        let string = text as NSString
        var result = ""
        var cursor = 0
        for match in entityPattern.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            result += string.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let name = string.substring(with: match.range(at: 1))
            result += decodedEntity(name) ?? string.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        result += string.substring(from: cursor)
        return result
    }

    private static func decodedEntity(_ name: String) -> String? {
        guard name.hasPrefix("#") else { return namedEntities[name] }
        let digits = name.dropFirst()
        let value = digits.first == "x" || digits.first == "X"
            ? UInt32(digits.dropFirst(), radix: 16)
            : UInt32(digits)
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
}
