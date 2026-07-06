import AppKit
import ImageIO
import PDFKit
import SwiftUI

/// Shared cache so the overlay, thumbnails, and settings preview open each PDF once.
/// Nonisolated: page building runs off the main thread at overlay open;
/// NSCache and PDFDocument creation are thread-safe.
nonisolated enum PDFCache {
    static let documents: NSCache<NSURL, PDFDocument> = {
        let cache = NSCache<NSURL, PDFDocument>()
        cache.countLimit = 4
        return cache
    }()


    static func document(at url: URL) -> PDFDocument? {
        if let cached = documents.object(forKey: url as NSURL) {
            return cached
        }
        guard let loaded = PDFDocument(url: url) else { return nil }
        documents.setObject(loaded, forKey: url as NSURL)
        return loaded
    }
}

extension CheatsheetStore {
    /// Flattens a sheet's files into overlay pages. A custom pageOrder wins;
    /// it is reconciled against the actual files so stale refs drop out and
    /// pages of newly added files append at the end.
    func pages(for sheet: Cheatsheet, includeHidden: Bool = false) -> [SheetPage] {
        Self.buildPages(for: sheet, mediaRoot: mediaRoot, includeHidden: includeHidden)
    }

    /// Nonisolated so the overlay can build pages (which parses PDFs) off the
    /// main thread while the panel is already on screen with a spinner.
    nonisolated static func buildPages(
        for sheet: Cheatsheet,
        mediaRoot: URL,
        includeHidden: Bool = false
    ) -> [SheetPage] {
        orderedRefs(for: sheet, mediaRoot: mediaRoot).compactMap { ref in
            let isHidden = ref.hidden ?? false
            guard includeHidden || !isHidden else { return nil }
            return SheetPage(
                url: Self.fileURL(mediaRoot: mediaRoot, sheetID: sheet.id, file: ref.file),
                pdfPageIndex: ref.pdfPageIndex,
                rotation: ref.rotation ?? sheet.rotation,
                flipHorizontal: ref.flipHorizontal ?? false,
                flipVertical: ref.flipVertical ?? false,
                isHidden: isHidden
            )
        }
    }

    nonisolated static func fileURL(mediaRoot: URL, sheetID: Cheatsheet.ID, file: String) -> URL {
        mediaRoot
            .appendingPathComponent(sheetID.uuidString, isDirectory: true)
            .appendingPathComponent(file)
    }

    /// Reconciliation matches by page identity (file + PDF page), ignoring
    /// per-page settings like rotation stored alongside.
    func orderedRefs(for sheet: Cheatsheet) -> [PageRef] {
        Self.orderedRefs(for: sheet, mediaRoot: mediaRoot)
    }

    nonisolated static func orderedRefs(for sheet: Cheatsheet, mediaRoot: URL) -> [PageRef] {
        let derived = expandRefs(files: sheet.files, for: sheet, mediaRoot: mediaRoot)
        guard !sheet.pageOrder.isEmpty else { return derived }
        let derivedKeys = Set(derived.map(\.key))
        var ordered = sheet.pageOrder.filter { derivedKeys.contains($0.key) }
        let presentKeys = Set(ordered.map(\.key))
        ordered += derived.filter { !presentKeys.contains($0.key) }
        return ordered
    }

    nonisolated static func expandRefs(files: [String], for sheet: Cheatsheet, mediaRoot: URL) -> [PageRef] {
        var refs: [PageRef] = []
        for file in files {
            let url = Self.fileURL(mediaRoot: mediaRoot, sheetID: sheet.id, file: file)
            if MediaKind.of(url) == .pdf, let document = PDFCache.document(at: url), document.pageCount > 0 {
                refs += (0..<document.pageCount).map { PageRef(file: file, pdfPageIndex: $0) }
            } else {
                refs.append(PageRef(file: file, pdfPageIndex: nil))
            }
        }
        return refs
    }

    func fileExists(for sheet: Cheatsheet, file: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: sheet, file: file).path)
    }

    /// Intrinsic size of a page's content, used to fit the overlay panel to the
    /// media instead of always showing a full-size rectangle. Nil for content
    /// without a natural aspect ratio (text, markdown).
    func naturalSize(for page: SheetPage) -> CGSize? {
        switch MediaKind.of(page.url) {
        case .pdf:
            guard
                let document = PDFCache.document(at: page.url),
                let pdfPage = document.page(at: page.pdfPageIndex ?? 0)
            else { return nil }
            var size = pdfPage.bounds(for: .mediaBox).size
            if pdfPage.rotation % 180 != 0 {
                size = CGSize(width: size.height, height: size.width)
            }
            return size
        case .image:
            guard
                let source = CGImageSourceCreateWithURL(page.url as CFURL, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
            else { return nil }
            // EXIF orientations 5-8 are rotated 90°/270°.
            if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
                return CGSize(width: height, height: width)
            }
            return CGSize(width: width, height: height)
        case .markdown, .text, .unsupported:
            return nil
        }
    }
}

extension SheetPage {
    /// "report.pdf · p3" for PDF pages, plain filename otherwise.
    var caption: String {
        let name = url.lastPathComponent
        if let pdfPageIndex {
            return "\(name) · p\(pdfPageIndex + 1)"
        }
        return name
    }

    /// Baking the effective transform into the ref preserves appearance exactly
    /// once a custom page order is materialized.
    var pageRef: PageRef {
        PageRef(
            file: url.lastPathComponent,
            pdfPageIndex: pdfPageIndex,
            rotation: rotation,
            flipHorizontal: flipHorizontal ? true : nil,
            flipVertical: flipVertical ? true : nil,
            hidden: isHidden ? true : nil
        )
    }

    func withHidden(_ hidden: Bool) -> SheetPage {
        var page = self
        page.isHidden = hidden
        return page
    }

    var key: PageKey {
        PageKey(file: url.lastPathComponent, pdfPageIndex: pdfPageIndex)
    }

    var hasTransform: Bool {
        rotation != .deg0 || flipHorizontal || flipVertical
    }
}

nonisolated enum PageTransformAction {
    case rotateClockwise
    case flipHorizontal
    case flipVertical
    case reset
}

extension View {
    /// Full page transform: rotation first, then screen-space mirroring so
    /// "flip horizontally" always mirrors what the user currently sees.
    func pageTransform(_ page: SheetPage) -> some View {
        rotated(page.rotation)
            .scaleEffect(
                x: page.flipHorizontal ? -1 : 1,
                y: page.flipVertical ? -1 : 1
            )
    }

    /// Rotates content while keeping it laid out within the original bounds
    /// (plain rotationEffect doesn't adjust layout for 90°/270°).
    @ViewBuilder
    func rotated(_ rotation: Rotation) -> some View {
        switch rotation {
        case .deg0:
            self
        case .deg180:
            rotationEffect(.degrees(180))
        case .deg90, .deg270:
            GeometryReader { geometry in
                self
                    .frame(width: geometry.size.height, height: geometry.size.width)
                    .rotationEffect(.degrees(rotation.degrees))
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
    }
}
