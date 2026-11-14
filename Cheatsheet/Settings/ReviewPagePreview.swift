import SwiftUI

/// Shows a file the way the cheatsheet would, with Cheatsheet's own page
/// renderer — not Quick Look, which skips an HTML page's stylesheets and, in
/// the sandbox, can't read an original's neighboring files at all.
enum ReviewRendering {
    /// The original's bytes, staged as a hidden file beside the copy: it then
    /// renders against the sheet's own files (stylesheets, images) — exactly
    /// what "Use Original" would show, since that replaces only the page.
    /// Hidden, so the folder scan never imports it. Nil if it can't be read.
    static func stage(original: URL, besideCopy copy: URL) -> URL? {
        let staged = copy.deletingLastPathComponent()
            .appendingPathComponent(".review-\(UUID().uuidString)-\(copy.lastPathComponent)")
        let copied: Bool = OriginalFiles.withAccess(to: original) {
            guard let data = try? Data(contentsOf: original) else { return false }
            return (try? data.write(to: staged, options: .atomic)) != nil
        }
        return copied ? staged : nil
    }

    static func remove(_ staged: URL?) {
        guard let staged else { return }
        try? FileManager.default.removeItem(at: staged)
    }

    static func page(for url: URL) -> SheetPage {
        SheetPage(url: url, pdfPageIndex: nil, rotation: .deg0, flipHorizontal: false, flipVertical: false)
    }
}

/// A live render laid out at overlay-like size, then scaled down to fit, so
/// a web page's layout matches the real thing instead of reflowing narrow.
struct LivePageThumbnail: View {
    let url: URL
    private static let layoutSize = CGSize(width: 880, height: 480)

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / Self.layoutSize.width, geometry.size.height / Self.layoutSize.height)
            // Interactive (the default): non-interactive web pages are hidden,
            // being the overlay's invisible preloaded neighbors. Clicks are
            // kept off by allowsHitTesting below.
            PassThroughHost(content: MediaPageView(page: ReviewRendering.page(for: url)))
                .frame(width: Self.layoutSize.width, height: Self.layoutSize.height)
                .scaleEffect(scale, anchor: .center)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
        .clipped()
        // One image-like element: a non-interactive web view alone isn't
        // exposed, so VoiceOver (and UI tests) would skip the preview.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel("Preview of \(url.lastPathComponent)")
        .accessibilityIdentifier("review.thumbnail")
    }
}

/// Hosts a page that's only looked at: its AppKit views (a web view) would
/// otherwise sit above SwiftUI controls drawn over it — the card's preview
/// button — and take their clicks. Clicks and accessibility hits pass through.
private struct PassThroughHost<Content: View>: NSViewRepresentable {
    let content: Content

    final class HostingView: NSHostingView<Content> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityChildren() -> [Any]? { [] }
    }

    func makeNSView(context: Context) -> HostingView {
        HostingView(rootView: content)
    }

    func updateNSView(_ nsView: HostingView, context: Context) {
        nsView.rootView = content
    }
}

/// The expanded view of one version: the page at full size, scrollable,
/// rendered as in the cheatsheet. Space or Escape closes it, as Quick Look did.
struct ReviewFullPreview: View {
    struct Target: Identifiable {
        let id = UUID()
        let title: String
        let url: URL
    }

    let target: Target
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.title)
                    .font(.headline)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("review.preview.done")
            }
            .padding(12)
            Divider()
            MediaPageView(page: ReviewRendering.page(for: target.url))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                // The page area itself (a web view alone isn't exposed).
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Preview of \(target.url.lastPathComponent)")
                .accessibilityIdentifier("review.fullPreview")
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 540, idealHeight: 680)
        .background {
            Button("Close Preview", action: onClose)
                .keyboardShortcut(.space, modifiers: [])
                .hidden()
        }
        .opensUnfocused()
    }
}
