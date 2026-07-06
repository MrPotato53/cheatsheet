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

/// Decoded start pages for cheatsheets with "keep start page loaded" —
/// renderers consult this first, making those opens spinner-free.
@MainActor
enum WarmPageImages {
    private(set) static var images: [String: NSImage] = [:]

    static func key(url: URL, pdfPageIndex: Int?) -> String {
        "\(url.path)#\(pdfPageIndex ?? -1)"
    }

    static func image(url: URL, pdfPageIndex: Int?) -> NSImage? {
        images[key(url: url, pdfPageIndex: pdfPageIndex)]
    }

    static func set(_ image: NSImage, url: URL, pdfPageIndex: Int?) {
        images[key(url: url, pdfPageIndex: pdfPageIndex)] = image
    }

    static func retain(only keys: Set<String>) {
        images = images.filter { keys.contains($0.key) }
    }
}

struct ImageFileView: View {
    let url: URL
    @State private var image: NSImage?
    @State private var didAttemptLoad: Bool

    init(url: URL) {
        self.url = url
        let warm = WarmPageImages.image(url: url, pdfPageIndex: nil)
        _image = State(initialValue: warm)
        _didAttemptLoad = State(initialValue: warm != nil)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else if didAttemptLoad {
                ContentUnavailableView("Couldn't load image", systemImage: "photo")
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            guard image == nil else { return }
            // Decode off the main actor: a main-thread decode stalls the
            // spinner, sometimes before the panel's first frame even paints.
            let maxPixels = Self.displayMaxPixels()
            let target = url
            image = await Task.detached(priority: .userInitiated) {
                Self.displaySizedImage(at: target, maxPixels: maxPixels)
            }.value
            didAttemptLoad = true
        }
    }

    static func displayMaxPixels() -> CGFloat {
        let maxScreenPixels = NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
            .max() ?? 4096
        return min(maxScreenPixels, 4096)
    }

    /// Decodes at most display resolution via ImageIO instead of NSImage's
    /// full-resolution decode: a 48 MP photo would otherwise pin ~180 MB while
    /// (or after — see the retained settings preview) it's shown.
    /// ShouldCache false: ImageIO otherwise retains a duplicate ~20 MB decoded
    /// buffer per image in its internal cache after we're done.
    nonisolated static func displaySizedImage(at url: URL, maxPixels: CGFloat) -> NSImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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
    @State private var didAttemptRender: Bool

    init(url: URL, pageIndex: Int) {
        self.url = url
        self.pageIndex = pageIndex
        let warm = WarmPageImages.image(url: url, pdfPageIndex: pageIndex)
        _image = State(initialValue: warm)
        _didAttemptRender = State(initialValue: warm != nil)
    }

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
                // Render off the main actor: a main-thread render stalls the
                // spinner, sometimes before the panel's first frame paints.
                let (target, index, size) = (url, pageIndex, geometry.size)
                let rendered = await Task.detached(priority: .userInitiated) {
                    Self.render(url: target, pageIndex: index, size: size)
                }.value
                if rendered != nil || image == nil {
                    image = rendered ?? image
                }
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

    nonisolated static func render(url: URL, pageIndex: Int, size: CGSize) -> NSImage? {
        guard size.width > 10, size.height > 10 else { return nil }
        guard let document = PDFCache.document(at: url) else { return nil }
        guard let page = document.page(at: pageIndex) else { return nil }
        // 2x for Retina sharpness; thumbnail(of:) fits within the size preserving aspect.
        return page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
    }
}
