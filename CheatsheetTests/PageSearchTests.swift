import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing

@testable import Cheatsheet

struct SearchMatchesTests {
    // Pages: 0 → 2 matches, 1 → none, 2 → 1 match (occurrences 0, 1 | 2).
    private let matches = SearchMatches(counts: [2, 0, 1])

    @Test func locatesOccurrencesAcrossPagesSkippingEmptyOnes() {
        #expect(matches.total == 3)
        #expect(matches.location(of: 0)! == (0, 0))
        #expect(matches.location(of: 1)! == (0, 1))
        #expect(matches.location(of: 2)! == (2, 0))
        #expect(matches.location(of: 3) == nil)
        #expect(matches.location(of: -1) == nil)
    }

    @Test func steppingWrapsAtBothEnds() {
        #expect(matches.step(from: 2, pageIndex: 2, forward: true) == 0)
        #expect(matches.step(from: 0, pageIndex: 0, forward: false) == 2)
        #expect(matches.step(from: 0, pageIndex: 0, forward: true) == 1)
    }

    @Test func steppingResumesFromManuallyVisitedPage() {
        // Current match is on page 0 but the user paged to 1 by hand.
        #expect(matches.step(from: 0, pageIndex: 1, forward: true) == 2)
        #expect(matches.step(from: 2, pageIndex: 1, forward: false) == 1)
    }

    @Test func firstMatchStartsAtCurrentPageAndWraps() {
        #expect(matches.first(fromPage: 0) == 0)
        #expect(matches.first(fromPage: 1) == 2)
        #expect(SearchMatches(counts: [1, 0, 0]).first(fromPage: 2) == 0)
        #expect(SearchMatches.empty.first(fromPage: 0) == nil)
    }

    @Test func localIndexOnlyForTheMatchesOwnPage() {
        #expect(matches.localIndex(of: 1, onPage: 0) == 1)
        #expect(matches.localIndex(of: 1, onPage: 2) == nil)
        #expect(matches.localIndex(of: nil, onPage: 0) == nil)
    }
}

struct PageSearchTests {
    @Test func rangesAreCaseInsensitiveAndNonOverlapping() {
        #expect(PageSearch.ranges(of: "ab", in: "Ab ab aB").count == 3)
        #expect(PageSearch.ranges(of: "aa", in: "aaaa").count == 2)
        #expect(PageSearch.ranges(of: "", in: "abc").isEmpty)
    }

    @Test func visibleTextDropsMarkupAndHiddenContent() {
        let html = """
        <html><head><title>Secret title</title><style>.x{}</style></head>
        <body><!-- note --><p>Fish &amp; chips &#x2014; <b>yes</b></p><script>var hidden = 1</script></body></html>
        """
        let text = PageSearch.visibleText(ofHTML: html)
        #expect(text.contains("Fish & chips — yes"))
        #expect(!text.contains("Secret"))
        #expect(!text.contains("hidden"))
        #expect(!text.contains("note"))
    }

    @Test func formattedAndRawPagesSearchWhatTheReaderSees() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let markdown = dir.appendingPathComponent("a.md")
        try "Some **bold** text".write(to: markdown, atomically: true, encoding: .utf8)

        func page(_ url: URL, raw: Bool = false) -> SheetPage {
            SheetPage(url: url, pdfPageIndex: nil, rotation: .deg0, flipHorizontal: false, flipVertical: false, showsRaw: raw)
        }
        // Rendered, the asterisks are gone; raw, they're part of the text.
        #expect(await PageSearch.matchCounts(query: "**bold**", pages: [page(markdown)]) == [0])
        #expect(await PageSearch.matchCounts(query: "bold text", pages: [page(markdown)]) == [1])
        #expect(await PageSearch.matchCounts(query: "**bold**", pages: [page(markdown, raw: true)]) == [1])
    }

    @Test @MainActor func imageTextIsRecognizedAndBoxedOnDevice() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("shot.png")
        let image = NSImage(size: NSSize(width: 1000, height: 400), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSAttributedString(string: "Undo with Command Z", attributes: [
                .font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black,
            ]).draw(at: NSPoint(x: 40, y: 250))
            return true
        }
        let png = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
            .representation(using: .png, properties: [:]))
        try png.write(to: url)

        let rects = await PageSearch.imageMatchRects(query: "command", url: url)
        #expect(rects.count == 1)
        let box = try #require(rects.first)
        // Text sits in the upper part of the image (top-left origin).
        #expect(box.minY < 0.5)
        #expect(box.minX > 0 && box.maxX < 1)
        #expect(await PageSearch.imageMatchRects(query: "redo", url: url).isEmpty)

        // A partial match covers only its characters, not the whole word:
        // "mand" is the right half of "Command".
        let partial = try #require(await PageSearch.imageMatchRects(query: "mand", url: url).first)
        #expect(partial.width < box.width * 0.75)
        #expect(partial.minX > box.minX + box.width * 0.3)
        #expect(abs(partial.maxX - box.maxX) < box.width * 0.1)
    }
}

struct ImageConfusableMatchingTests {
    @Test func capitalIAndLowercaseLMatchEachOther() {
        // The recognizer read "list" as "Iist".
        #expect(PageSearch.imageRanges(of: "list", in: "Iist items") == [NSRange(location: 0, length: 4)])
        #expect(PageSearch.imageRanges(of: "If", in: "lf needed") == [NSRange(location: 0, length: 2)])
    }

    @Test func digitsMatchTheirLookAlikeLetters() {
        #expect(PageSearch.imageRanges(of: "F10", in: "Press FIO") == [NSRange(location: 6, length: 3)])
    }

    @Test func foldingKeepsLengthsSoRangesMapBack() {
        let text = "Ctrl ⌘ Il1| O0 é"
        #expect((PageSearch.foldingConfusables(text) as NSString).length == (text as NSString).length)
    }

    @Test func unrelatedLettersStillDiffer() {
        #expect(PageSearch.imageRanges(of: "copy", in: "paste").isEmpty)
    }
}

struct ImageMatchGeometryTests {
    private let wordBox = CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.05)

    @Test func enclosingWordExpandsToWhitespace() {
        let text = "Undo with Command Z"
        #expect(ImageMatchGeometry.enclosingWordRange(of: NSRange(location: 13, length: 4), in: text)
            == NSRange(location: 10, length: 7))
        // A match spanning a space covers both words.
        #expect(ImageMatchGeometry.enclosingWordRange(of: NSRange(location: 8, length: 4), in: text)
            == NSRange(location: 5, length: 12))
    }

    @Test func wholeWordMatchKeepsTheWordBox() {
        let word = NSRange(location: 0, length: 4)
        #expect(ImageMatchGeometry.matchRect(word, word: word, in: "Undo", wordBox: wordBox) == wordBox)
    }

    @Test func suffixMatchIsRightAlignedAndNarrower() {
        let rect = ImageMatchGeometry.matchRect(
            NSRange(location: 3, length: 4), word: NSRange(location: 0, length: 7),
            in: "Command", wordBox: wordBox)
        #expect(rect.width < wordBox.width)
        #expect(rect.minX > wordBox.minX)
        #expect(abs(rect.maxX - wordBox.maxX) < 1e-9)
        #expect(rect.minY == wordBox.minY && rect.height == wordBox.height)
    }

    @Test func prefixMatchIsLeftAligned() {
        let rect = ImageMatchGeometry.matchRect(
            NSRange(location: 0, length: 3), word: NSRange(location: 0, length: 7),
            in: "Command", wordBox: wordBox)
        #expect(rect.minX == wordBox.minX)
        #expect(rect.maxX < wordBox.maxX)
    }
}

struct PDFMatchGeometryTests {
    // 200×100 landscape media box; a 20×10 box at the page's bottom-left.
    private let box = CGRect(x: 0, y: 0, width: 200, height: 100)
    private let bottomLeft = CGRect(x: 0, y: 0, width: 20, height: 10)

    @Test func unrotatedFlipsToTopLeftOrigin() {
        let rect = PDFMatchGeometry.unitRect(for: bottomLeft, mediaBox: box, rotation: 0)
        #expect(rect == CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1))
    }

    @Test func clockwiseRotationMovesBottomLeftToTopLeft() {
        // Displayed 100 wide × 200 tall; the box becomes 10×20 at top-left.
        let rect = PDFMatchGeometry.unitRect(for: bottomLeft, mediaBox: box, rotation: 90)
        #expect(rect == CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
    }

    @Test func halfTurnMovesBottomLeftToTopRight() {
        let rect = PDFMatchGeometry.unitRect(for: bottomLeft, mediaBox: box, rotation: 180)
        #expect(rect == CGRect(x: 0.9, y: 0, width: 0.1, height: 0.1))
    }

    @Test func threeQuarterTurnMovesBottomLeftToBottomRight() {
        let rect = PDFMatchGeometry.unitRect(for: bottomLeft, mediaBox: box, rotation: 270)
        #expect(rect == CGRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1))
    }
}

@MainActor
struct PDFSearchTests {
    /// A PDF with a real text layer, one page per string.
    private func makePDF(pages: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 20)])
                .draw(at: NSPoint(x: 20, y: 100))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func page(_ url: URL, _ index: Int) -> SheetPage {
        SheetPage(url: url, pdfPageIndex: index, rotation: .deg0, flipHorizontal: false, flipVertical: false)
    }

    // Counts and per-page highlight boxes come from one shared search, so
    // they must agree page by page — and repeated lookups stay consistent.
    @Test func countsAndPerPageSelectionsAgree() async throws {
        let url = try makePDF(pages: ["copy then paste copy", "nothing here", "Copy"])
        defer { try? FileManager.default.removeItem(at: url) }
        let pages = (0..<3).map { page(url, $0) }

        #expect(await PageSearch.matchCounts(query: "copy", pages: pages) == [2, 0, 1])
        #expect(PageSearch.pdfSelections(query: "copy", url: url, pageIndex: 0).count == 2)
        #expect(PageSearch.pdfSelections(query: "copy", url: url, pageIndex: 1).isEmpty)
        #expect(PageSearch.pdfSelections(query: "copy", url: url, pageIndex: 2).count == 1)
        #expect(await PageSearch.matchCounts(query: "copy", pages: pages) == [2, 0, 1])
        #expect(await PageSearch.matchCounts(query: "paste", pages: pages) == [1, 0, 0])
        #expect(PageSearch.pdfSelections(query: "", url: url, pageIndex: 0).isEmpty)
    }

    /// Overwrites `url` in place with a new PDF, stamped a minute later so
    /// the edit is distinguishable regardless of timestamp resolution.
    private func editInPlace(_ url: URL, pages: [String]) throws {
        let replacement = try makePDF(pages: pages)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
    }

    // Requirement: editing an imported file in place (same path) shows the
    // new content the next time the cheatsheet opens — pages, rendering,
    // search and warmed start pages must not serve the old version.
    @Test func editedFileIsReflectedEverywhereOnNextUse() async throws {
        let url = try makePDF(pages: ["alpha"])
        defer { try? FileManager.default.removeItem(at: url) }
        var sheet = Cheatsheet(name: "S")
        sheet.files = [url.lastPathComponent]
        let mediaRoot = url.deletingLastPathComponent()
        // buildPages resolves <mediaRoot>/<sheet id>/<file>; mirror that.
        let sheetDir = mediaRoot.appendingPathComponent(sheet.id.uuidString)
        try FileManager.default.createDirectory(at: sheetDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sheetDir) }
        let copy = sheetDir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)

        #expect(CheatsheetStore.buildPages(for: sheet, mediaRoot: mediaRoot).count == 1)
        #expect(await PageSearch.matchCounts(query: "alpha", pages: [page(copy, 0)]) == [1])
        let warmKey = WarmPageImages.key(url: copy, pdfPageIndex: 0)

        try editInPlace(copy, pages: ["beta", "beta alpha"])

        #expect(PDFCache.document(at: copy)?.pageCount == 2)
        #expect(CheatsheetStore.buildPages(for: sheet, mediaRoot: mediaRoot).count == 2)
        let pages = [page(copy, 0), page(copy, 1)]
        #expect(await PageSearch.matchCounts(query: "alpha", pages: pages) == [0, 1])
        #expect(PageSearch.pdfSelections(query: "beta", url: copy, pageIndex: 1).count == 1)
        #expect(WarmPageImages.key(url: copy, pdfPageIndex: 0) != warmKey)
    }

    @Test func resultsAreKeptPerFile() async throws {
        let first = try makePDF(pages: ["alpha"])
        let second = try makePDF(pages: ["alpha alpha"])
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        #expect(await PageSearch.matchCounts(query: "alpha", pages: [page(first, 0)]) == [1])
        #expect(await PageSearch.matchCounts(query: "alpha", pages: [page(second, 0)]) == [2])
    }
}
