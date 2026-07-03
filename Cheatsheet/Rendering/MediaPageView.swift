import PDFKit
import SwiftUI

struct MediaPageView: View {
    let page: SheetPage

    var body: some View {
        switch MediaKind.of(page.url) {
        case .pdf:
            PDFPageView(url: page.url, pageIndex: page.pdfPageIndex ?? 0)
        case .image:
            ImageFileView(url: page.url)
        case .markdown:
            MarkdownWebView(url: page.url)
        case .text:
            TextFileView(url: page.url)
        case .unsupported:
            ContentUnavailableView(
                "Can't display \(page.url.lastPathComponent)",
                systemImage: "questionmark.square.dashed"
            )
        }
    }
}

struct ImageFileView: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(8)
        } else {
            ContentUnavailableView("Couldn't load image", systemImage: "photo")
        }
    }
}

struct TextFileView: View {
    let url: URL

    var body: some View {
        ScrollView {
            Text(Self.contents(of: url))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    private static func contents(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            ?? "Couldn't read \(url.lastPathComponent)."
    }
}

/// Renders one PDF page as a bitmap sized to the container, which keeps the
/// overlay's non-activating panel free of PDFView's own event handling.
struct PDFPageView: View {
    let url: URL
    let pageIndex: Int
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: RenderKey(url: url, pageIndex: pageIndex, size: geometry.size)) {
                image = Self.render(url: url, pageIndex: pageIndex, size: geometry.size)
            }
        }
        .padding(8)
    }

    private struct RenderKey: Equatable {
        let url: URL
        let pageIndex: Int
        let size: CGSize
    }

    private static let documentCache = NSCache<NSURL, PDFDocument>()

    private static func render(url: URL, pageIndex: Int, size: CGSize) -> NSImage? {
        guard size.width > 10, size.height > 10 else { return nil }
        let document: PDFDocument
        if let cached = documentCache.object(forKey: url as NSURL) {
            document = cached
        } else if let loaded = PDFDocument(url: url) {
            documentCache.setObject(loaded, forKey: url as NSURL)
            document = loaded
        } else {
            return nil
        }
        guard let page = document.page(at: pageIndex) else { return nil }
        // 2x for Retina sharpness; thumbnail(of:) fits within the size preserving aspect.
        return page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
    }
}
