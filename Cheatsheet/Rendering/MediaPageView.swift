import PDFKit
import SwiftUI

struct MediaPageView: View {
    let page: SheetPage
    /// Search matches to mark on this page, if a search is active.
    var highlight: SearchHighlight?
    /// False for preloaded neighbor pages kept mounted but invisible; their
    /// AppKit views must not claim the cursor over the visible page.
    var isInteractive = true

    var body: some View {
        switch MediaKind.of(page.url) {
        case .pdf:
            PDFPageView(url: page.url, pageIndex: page.pdfPageIndex ?? 0, highlight: highlight)
        case .image:
            ImageFileView(url: page.url, highlight: highlight)
        case .markdown where page.showsRaw, .html where page.showsRaw:
            TextFileView(url: page.url, highlight: highlight, isInteractive: isInteractive)
        case .markdown:
            MarkdownWebView(url: page.url, highlight: highlight, isInteractive: isInteractive)
        case .html:
            MarkdownWebView(url: page.url, format: .html, highlight: highlight, isInteractive: isInteractive)
        case .text:
            TextFileView(url: page.url, highlight: highlight, isInteractive: isInteractive)
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

    /// Includes the file's modification time: after an in-place edit the
    /// warmed decode of the old version simply misses.
    static func key(url: URL, pdfPageIndex: Int?) -> String {
        "\(FileStamp.versionedKey(for: url))#\(pdfPageIndex ?? -1)"
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
    var highlight: SearchHighlight?
    @State private var image: NSImage?
    @State private var didAttemptLoad: Bool
    /// Recognized-text match boxes, unit coordinates (top-left origin).
    @State private var matchRects: [CGRect] = []

    init(url: URL, highlight: SearchHighlight? = nil) {
        self.url = url
        self.highlight = highlight
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
                    .overlay {
                        MatchBoxesOverlay(
                            unitRects: matchRects,
                            activeIndex: highlight?.activeIndex,
                            contentSize: image.size
                        )
                    }
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
        .task(id: highlight?.query) {
            matchRects = await PageSearch.imageMatchRects(query: highlight?.query ?? "", url: url)
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
        guard let cgImage = displaySizedCGImage(at: url, maxPixels: maxPixels) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Upright (EXIF orientation applied) decode capped at `maxPixels`.
    nonisolated static func displaySizedCGImage(at url: URL, maxPixels: CGFloat) -> CGImage? {
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
        return cgImage
    }
}

/// AppKit text view instead of SwiftUI ScrollView: scroll-wheel events reach
/// NSScrollView in a non-activating panel even while the app is inactive.
struct TextFileView: NSViewRepresentable {
    let url: URL
    var highlight: SearchHighlight?
    /// Hidden (not just transparent) when false: NSTextView's I-beam cursor
    /// rect would otherwise apply over whatever page is actually visible.
    var isInteractive = true

    final class Coordinator {
        var loadedVersion: String?
        var appliedHighlight: SearchHighlight?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

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
        scrollView.isHidden = !isInteractive
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Re-read only for a new file or a new version of it (edited in
        // place), not on every SwiftUI update (hover, paging, search…).
        let version = FileStamp.versionedKey(for: url)
        let contentChanged = context.coordinator.loadedVersion != version
        if contentChanged {
            context.coordinator.loadedVersion = version
            textView.string = Self.contents(of: url)
            textView.scrollToBeginningOfDocument(nil)
        }
        if contentChanged || context.coordinator.appliedHighlight != highlight {
            context.coordinator.appliedHighlight = highlight
            Self.apply(highlight, to: textView)
        }
    }

    private static func apply(_ highlight: SearchHighlight?, to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
        guard let highlight else { return }
        let ranges = PageSearch.ranges(of: highlight.query, in: textView.string)
        for (index, range) in ranges.enumerated() {
            let isActive = index == highlight.activeIndex
            storage.addAttributes([
                .backgroundColor: isActive ? SearchHighlightColors.active : SearchHighlightColors.match,
                .foregroundColor: NSColor.black,
            ], range: range)
        }
        if let active = highlight.activeIndex, ranges.indices.contains(active) {
            textView.scrollRangeToVisible(ranges[active])
        }
    }

    private static func contents(of url: URL) -> String {
        TextFile.read(url) ?? "Couldn't read \(url.lastPathComponent)."
    }
}

/// Renders one PDF page as a bitmap sized to the container, which keeps the
/// overlay's non-activating panel free of PDFView's own event handling.
struct PDFPageView: View {
    let url: URL
    let pageIndex: Int
    var highlight: SearchHighlight?
    @State private var image: NSImage?
    @State private var didAttemptRender: Bool
    /// Match boxes in unit coordinates of the displayed page (top-left origin).
    @State private var matchRects: [CGRect] = []

    init(url: URL, pageIndex: Int, highlight: SearchHighlight? = nil) {
        self.url = url
        self.pageIndex = pageIndex
        self.highlight = highlight
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
                    MatchBoxesOverlay(
                        unitRects: matchRects,
                        activeIndex: highlight?.activeIndex,
                        contentSize: image.size
                    )
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
            .task(id: highlight?.query) {
                let (target, index, query) = (url, pageIndex, highlight?.query ?? "")
                matchRects = await Task.detached(priority: .userInitiated) {
                    PDFMatchGeometry.unitRects(query: query, url: target, pageIndex: index)
                }.value
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
