import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// In-place preview with a Finder-gallery-style thumbnail strip: click to
/// preview, shift/⌘-click for multi-selection, drag (individually or as a
/// group) to reorder or to move pages between the shown strip and the hidden
/// section. Transform actions apply to the whole selection.
struct SheetInlinePreview: View {
    let sheet: Cheatsheet
    @Environment(CheatsheetStore.self) private var store
    @State private var shownPages: [SheetPage] = []
    @State private var hiddenPages: [SheetPage] = []
    @State private var selectedShown: Set<SheetPage> = []
    @State private var selectedHidden: Set<SheetPage> = []
    @State private var previewPage: SheetPage?
    @State private var isHiddenSectionExpanded = false
    @State private var isDragActive = false
    @State private var isHiddenDropTargeted = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if let previewPage {
                    MediaPageView(page: previewPage)
                        .pageTransform(previewPage)
                        .id(previewPage)
                } else {
                    ContentUnavailableView("No pages", systemImage: "doc")
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if previewPage != nil {
                    transformButtons
                }
            }

            if shownPages.count > 1 || !hiddenPages.isEmpty {
                shownGallery
                    .frame(height: 112)
                Text("Click to preview, shift-click to select a range, ⌘-click to toggle. Drag thumbnails (or a selection) to reorder or to move them in and out of the hidden section. Right-click to rotate, flip, or hide (⌫ hides too).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !hiddenPages.isEmpty || isDragActive {
                hiddenSection
            }
        }
        .padding(.vertical, 4)
        .task(id: sheet) {
            reload()
        }
    }

    // MARK: - Galleries

    private var shownGallery: some View {
        PageGalleryView(
            pages: shownPages,
            selection: $selectedShown,
            accent: accentColor(for:),
            onPrimarySelection: { page in
                previewPage = page
                selectedHidden = []
            },
            onReorder: { newOrder in
                shownPages = newOrder
                commitOrder()
            },
            onTransform: { pages, action in
                apply(action, to: pages)
            },
            toggleHiddenLabel: "Hide Page",
            onToggleHidden: { pages in
                hidePages(pages)
            },
            onDeleteKey: { pages in
                hidePages(pages)
            },
            onIncomingDrop: { keys, index in
                unhidePages(withKeys: keys, at: index)
            },
            resolveIncoming: { key in
                hiddenPages.first { $0.key == key }?.withHidden(false)
            },
            onDragActive: { active in
                isDragActive = active
                if active {
                    isHiddenSectionExpanded = true
                } else {
                    isHiddenDropTargeted = false
                }
            }
        )
    }

    private var hiddenGallery: some View {
        PageGalleryView(
            pages: hiddenPages,
            selection: $selectedHidden,
            accent: accentColor(for:),
            onPrimarySelection: { page in
                previewPage = page
                selectedShown = []
            },
            onReorder: { newOrder in
                hiddenPages = newOrder
                commitOrder()
            },
            onTransform: { pages, action in
                apply(action, to: pages)
            },
            toggleHiddenLabel: "Show Page",
            onToggleHidden: { pages in
                showPages(pages, at: shownPages.count)
            },
            onDeleteKey: nil,
            onIncomingDrop: { keys, index in
                hidePages(withKeys: keys, at: index)
            },
            resolveIncoming: { key in
                shownPages.first { $0.key == key }?.withHidden(true)
            },
            onDragActive: { active in
                isDragActive = active
                if !active {
                    isHiddenDropTargeted = false
                }
            },
            onDropTargeted: { targeted in
                isHiddenDropTargeted = targeted
            }
        )
    }

    private var hiddenSection: some View {
        Group {
            if hiddenPages.isEmpty {
                // Drop zone shown mid-drag even before anything is hidden.
                ZStack {
                    hiddenGallery
                        .frame(height: 72)
                    Label("Drop here to hide", systemImage: "eye.slash")
                        .font(.callout)
                        .foregroundStyle(isHiddenDropTargeted ? .primary : .secondary)
                        .allowsHitTesting(false)
                }
            } else {
                DisclosureGroup(isExpanded: $isHiddenSectionExpanded) {
                    hiddenGallery
                        .frame(height: 112)
                        .opacity(0.7)
                } label: {
                    Label(
                        isDragActive ? "Hidden pages (\(hiddenPages.count)) — drop here to hide" : "Hidden pages (\(hiddenPages.count))",
                        systemImage: "eye.slash"
                    )
                    .font(.callout)
                    .foregroundStyle(isHiddenDropTargeted ? .primary : .secondary)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHiddenDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isHiddenDropTargeted ? Color.accentColor : (isDragActive ? Color.secondary.opacity(0.5) : Color.clear),
                    style: StrokeStyle(lineWidth: 1.5, dash: isHiddenDropTargeted ? [] : [5, 4])
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isHiddenDropTargeted)
        .animation(.easeInOut(duration: 0.15), value: isDragActive)
    }

    private var transformButtons: some View {
        VStack(spacing: 12) {
            Button {
                applyToActiveSelection(.rotateClockwise)
            } label: {
                Image(systemName: "rotate.right")
            }
            .help("Rotate clockwise")
            Button {
                applyToActiveSelection(.flipHorizontal)
            } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .help("Flip horizontally")
            Button {
                applyToActiveSelection(.flipVertical)
            } label: {
                Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
            }
            .help("Flip vertically")
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .padding(.horizontal, 7)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 8)
        // Clears text pages' vertical scroll bar at the trailing edge.
        .padding(.trailing, 24)
    }

    // MARK: - State

    private func reload() {
        let allPages = store.pages(for: sheet, includeHidden: true)
        shownPages = allPages.filter { !$0.isHidden }
        hiddenPages = allPages.filter(\.isHidden)
        selectedShown = Set(shownPages.filter { page in selectedShown.contains { $0.key == page.key } })
        selectedHidden = Set(hiddenPages.filter { page in selectedHidden.contains { $0.key == page.key } })
        if let previewPage, let match = allPages.first(where: { $0.key == previewPage.key }) {
            self.previewPage = match
            return
        }
        previewPage = shownPages.first
    }

    /// Transform buttons act on whichever strip currently holds a selection,
    /// falling back to the previewed page.
    private func applyToActiveSelection(_ action: PageTransformAction) {
        let targets: [SheetPage]
        if !selectedShown.isEmpty {
            targets = shownPages.filter { selectedShown.contains($0) }
        } else if !selectedHidden.isEmpty {
            targets = hiddenPages.filter { selectedHidden.contains($0) }
        } else if let previewPage {
            targets = [previewPage]
        } else {
            return
        }
        apply(action, to: targets)
    }

    private func apply(_ action: PageTransformAction, to pages: [SheetPage]) {
        let keys = Set(pages.map(\.key))
        let sheetRotation = sheet.rotation
        store.updatePages(withKeys: keys, in: sheet.id) { ref in
            switch action {
            case .rotateClockwise:
                ref.rotation = (ref.rotation ?? sheetRotation).rotatedRight
            case .flipHorizontal:
                ref.flipHorizontal = (ref.flipHorizontal ?? false) ? nil : true
            case .flipVertical:
                ref.flipVertical = (ref.flipVertical ?? false) ? nil : true
            case .reset:
                ref.rotation = nil
                ref.flipHorizontal = nil
                ref.flipVertical = nil
            }
        }
    }

    // MARK: - Hiding

    private func hidePages(_ pages: [SheetPage], at hiddenIndex: Int? = nil) {
        let moving = shownPages.filter { pages.contains($0) }
        guard !moving.isEmpty else { return }
        shownPages.removeAll { moving.contains($0) }
        let insertion = min(max(hiddenIndex ?? hiddenPages.count, 0), hiddenPages.count)
        hiddenPages.insert(contentsOf: moving.map { $0.withHidden(true) }, at: insertion)
        selectedShown.subtract(moving)
        if let previewPage, moving.contains(where: { $0.key == previewPage.key }) {
            self.previewPage = shownPages.first
        }
        isHiddenSectionExpanded = true
        commitOrder()
    }

    private func hidePages(withKeys keys: [PageKey], at index: Int) -> Bool {
        let pages = keys.compactMap { key in shownPages.first { $0.key == key } }
        guard !pages.isEmpty else { return false }
        hidePages(pages, at: index)
        selectedHidden = Set(hiddenPages.filter { page in keys.contains(page.key) })
        return true
    }

    private func showPages(_ pages: [SheetPage], at index: Int) {
        let moving = hiddenPages.filter { pages.contains($0) }
        guard !moving.isEmpty else { return }
        hiddenPages.removeAll { moving.contains($0) }
        let restored = moving.map { $0.withHidden(false) }
        let insertion = min(max(index, 0), shownPages.count)
        shownPages.insert(contentsOf: restored, at: insertion)
        selectedHidden.subtract(moving)
        selectedShown = Set(restored)
        previewPage = restored.first
        commitOrder()
    }

    private func unhidePages(withKeys keys: [PageKey], at index: Int) -> Bool {
        let pages = keys.compactMap { key in hiddenPages.first { $0.key == key } }
        guard !pages.isEmpty else { return false }
        showPages(pages, at: index)
        return true
    }

    private func commitOrder() {
        let refs = shownPages.map { $0.withHidden(false).pageRef }
            + hiddenPages.map { $0.withHidden(true).pageRef }
        store.setPageOrder(refs, for: sheet.id)
    }

    private func accentColor(for page: SheetPage) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .yellow]
        let index = sheet.files.firstIndex(of: page.url.lastPathComponent) ?? 0
        return palette[index % palette.count]
    }
}

struct PageThumbnailView: View {
    let page: SheetPage
    let isSelected: Bool
    let accent: Color
    var onTransform: ((PageTransformAction) -> Void)?
    var toggleHiddenLabel: String = ""
    var onToggleHidden: (() -> Void)?
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(2)
                        .rotationEffect(.degrees(page.rotation.degrees))
                        .scaleEffect(
                            x: page.flipHorizontal ? -1 : 1,
                            y: page.flipVertical ? -1 : 1
                        )
                } else {
                    Image(systemName: MediaKind.of(page.url).systemImage)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )

            Capsule()
                .fill(accent)
                .frame(width: 32, height: 3)

            Text(page.caption)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 72)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let onTransform {
                Button("Rotate Clockwise") { onTransform(.rotateClockwise) }
                Button("Flip Horizontal") { onTransform(.flipHorizontal) }
                Button("Flip Vertical") { onTransform(.flipVertical) }
                if page.hasTransform {
                    Divider()
                    Button("Reset") { onTransform(.reset) }
                }
            }
            if let onToggleHidden {
                if onTransform != nil {
                    Divider()
                }
                Button(toggleHiddenLabel) { onToggleHidden() }
            }
        }
        .task(id: page) {
            thumbnail = PageThumbnailRenderer.thumbnail(for: page)
        }
    }
}

enum PageThumbnailRenderer {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func thumbnail(for page: SheetPage) -> NSImage? {
        let key = "\(page.url.path)#\(page.pdfPageIndex ?? -1)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let rendered: NSImage?
        switch MediaKind.of(page.url) {
        case .pdf:
            rendered = PDFCache.document(at: page.url)?
                .page(at: page.pdfPageIndex ?? 0)?
                .thumbnail(of: CGSize(width: 112, height: 112), for: .mediaBox)
        case .image:
            rendered = imageThumbnail(at: page.url, maxPixels: 112)
        case .markdown, .text, .unsupported:
            rendered = nil
        }
        if let rendered {
            cache.setObject(rendered, forKey: key)
        }
        return rendered
    }

    /// Downsamples via ImageIO so thumbnails never decode the full image.
    private static func imageThumbnail(at url: URL, maxPixels: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels * 2,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
