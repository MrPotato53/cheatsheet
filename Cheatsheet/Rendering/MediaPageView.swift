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

/// AppKit text view instead of SwiftUI ScrollView: scroll-wheel events reach
/// NSScrollView in a non-activating panel even while the app is inactive.
struct TextFileView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textColor = .labelColor
            textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            textView.textContainerInset = NSSize(width: 16, height: 12)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let contents = Self.contents(of: url)
        if textView.string != contents {
            textView.string = contents
            textView.scrollToBeginningOfDocument(nil)
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
    @State private var didAttemptRender = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if didAttemptRender {
                    ContentUnavailableView(
                        "Couldn't load \(url.lastPathComponent)",
                        systemImage: "exclamationmark.triangle"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: RenderKey(url: url, pageIndex: pageIndex, size: geometry.size)) {
                image = Self.render(url: url, pageIndex: pageIndex, size: geometry.size)
                didAttemptRender = true
            }
        }
        .padding(8)
    }

    private struct RenderKey: Equatable {
        let url: URL
        let pageIndex: Int
        let size: CGSize
    }

    private static func render(url: URL, pageIndex: Int, size: CGSize) -> NSImage? {
        guard size.width > 10, size.height > 10 else { return nil }
        guard let document = PDFCache.document(at: url) else { return nil }
        guard let page = document.page(at: pageIndex) else { return nil }
        // 2x for Retina sharpness; thumbnail(of:) fits within the size preserving aspect.
        return page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
    }
}
