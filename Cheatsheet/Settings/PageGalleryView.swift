import AppKit
import OSLog
import SwiftUI

/// Pasteboard payload identifying a page dragged between gallery strips
/// (shown ⇄ hidden). One payload per dragged item, so grouped drags carry
/// every selected page.
nonisolated enum PageDragPayload {
    static let prefix = "cheatsheet-page:"
    static let separator = "\u{1f}"

    static func encode(_ page: SheetPage) -> String {
        "\(prefix)\(page.url.lastPathComponent)\(separator)\(page.pdfPageIndex ?? -1)"
    }

    static func decode(_ payload: String) -> PageKey? {
        guard payload.hasPrefix(prefix) else { return nil }
        let parts = payload.dropFirst(prefix.count).components(separatedBy: separator)
        guard parts.count == 2, let index = Int(parts[1]) else { return nil }
        return PageKey(file: parts[0], pdfPageIndex: index == -1 ? nil : index)
    }
}

final class GalleryCollectionView: NSCollectionView {
    var onDeleteSelection: (() -> Void)?
    var onDragExited: (() -> Void)?
    var onDragTargeted: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // delete / forward delete
            onDeleteSelection?()
            return
        }
        super.keyDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragTargeted?(true)
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTargeted?(false)
        onDragExited?()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragTargeted?(false)
        onDragExited?()
        super.draggingEnded(sender)
    }
}

/// AppKit-backed thumbnail strip with multi-selection (shift-click ranges,
/// ⌘-click toggles — native NSCollectionView behavior), grouped drag
/// reordering, and cross-strip drops for hiding/unhiding pages.
struct PageGalleryView: NSViewRepresentable {
    let pages: [SheetPage]
    @Binding var selection: Set<SheetPage>
    let accent: (SheetPage) -> Color
    /// The page the user actually clicked last — drives the big preview.
    let onPrimarySelection: (SheetPage) -> Void
    let onReorder: ([SheetPage]) -> Void
    /// Applies to the clicked page, or the whole selection when the clicked
    /// page is part of it.
    let onTransform: ([SheetPage], PageTransformAction) -> Void
    /// Context-menu action moving pages to the other strip ("Hide"/"Show").
    let toggleHiddenLabel: String
    let onToggleHidden: ([SheetPage]) -> Void
    /// Delete key. Nil disables (e.g. in the hidden strip).
    let onDeleteKey: (([SheetPage]) -> Void)?
    /// Pages dropped in from the other strip, at the given insertion index.
    let onIncomingDrop: ([PageKey], Int) -> Bool
    /// Resolves an incoming page so a single-item drag can show a live ghost.
    let resolveIncoming: (PageKey) -> SheetPage?
    let onDragActive: (Bool) -> Void
    var onDropTargeted: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 80, height: 90)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)

        let collectionView = GalleryCollectionView()
        collectionView.onDeleteSelection = { [weak coordinator = context.coordinator] in
            coordinator?.deleteKeyPressed()
        }
        collectionView.onDragExited = { [weak coordinator = context.coordinator] in
            coordinator?.removeGhost()
            coordinator?.stopAutoScroll()
        }
        collectionView.onDragTargeted = { [weak coordinator = context.coordinator] targeted in
            coordinator?.parent.onDropTargeted?(targeted)
        }
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(PageThumbItem.self, forItemWithIdentifier: PageThumbItem.identifier)
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.registerForDraggedTypes([.string])

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        // Legacy style keeps the scroll bar permanently visible and clickable;
        // the default overlay style only materializes mid-scroll.
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .none
        context.coordinator.collectionView = collectionView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.pages != pages {
            coordinator.pages = pages
            coordinator.clearGhostState()
            coordinator.collectionView?.reloadData()
        }
        coordinator.syncSelection(to: selection)
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        private static let logger = Logger(subsystem: "potatodev.Cheatsheet", category: "gallery-drag")
        var parent: PageGalleryView
        var pages: [SheetPage] = []
        weak var collectionView: NSCollectionView?
        private var draggingIndexes: [Int] = []
        private var didAcceptDrop = false
        // Live placeholder for a single page dragged in from the other strip.
        private var ghostIndex: Int?
        // Shift-click range selection (NSCollectionView doesn't implement it).
        private var anchorIndex: Int?
        private var pendingShiftRange: Set<IndexPath>?
        private var pendingShiftClicked: Int?
        // Timer-driven edge autoscroll during drags.
        private var autoScrollTimer: Timer?
        private var autoScrollStep: CGFloat = 0

        init(parent: PageGalleryView) {
            self.parent = parent
        }

        func clearGhostState() {
            ghostIndex = nil
        }

        private var selectedPagesInOrder: [SheetPage] {
            guard let collectionView else { return [] }
            return collectionView.selectionIndexPaths
                .map(\.item)
                .sorted()
                .compactMap { pages.indices.contains($0) ? pages[$0] : nil }
        }

        func deleteKeyPressed() {
            guard let onDeleteKey = parent.onDeleteKey else { return }
            let selected = selectedPagesInOrder
            guard !selected.isEmpty else { return }
            onDeleteKey(selected)
        }

        /// Resyncs to the SwiftUI source of truth. Used when a drag ends
        /// without an internal drop — the model may have legitimately changed
        /// meanwhile (e.g. pages dropped on the other strip), so restoring a
        /// snapshot from drag start would show stale items.
        private func resyncToParent() {
            guard pages != parent.pages else { return }
            pages = parent.pages
            ghostIndex = nil
            collectionView?.reloadData()
            syncSelection(to: parent.selection)
        }

        func syncSelection(to selection: Set<SheetPage>) {
            guard let collectionView else { return }
            let desired = Set(
                pages.enumerated()
                    .filter { selection.contains($0.element) }
                    .map { IndexPath(item: $0.offset, section: 0) }
            )
            if collectionView.selectionIndexPaths != desired {
                collectionView.selectionIndexPaths = desired
                if let first = desired.min(by: { $0.item < $1.item }) {
                    collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
                }
            }
        }

        private func publishSelection() {
            guard let collectionView else { return }
            parent.selection = Set(
                collectionView.selectionIndexPaths
                    .compactMap { pages.indices.contains($0.item) ? pages[$0.item] : nil }
            )
        }

        // MARK: Data source

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            pages.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: PageThumbItem.identifier, for: indexPath)
            if let thumbItem = item as? PageThumbItem, pages.indices.contains(indexPath.item) {
                let page = pages[indexPath.item]
                thumbItem.configure(
                    page: page,
                    accent: parent.accent(page),
                    toggleHiddenLabel: parent.toggleHiddenLabel,
                    onTransform: { [weak self] action in
                        guard let self else { return }
                        self.parent.onTransform(self.affectedPages(for: page), action)
                    },
                    onToggleHidden: { [weak self] in
                        guard let self else { return }
                        self.parent.onToggleHidden(self.affectedPages(for: page))
                    }
                )
            }
            return item
        }

        /// Menu actions apply to the whole selection when the clicked page is
        /// part of it, otherwise just to the clicked page.
        private func affectedPages(for page: SheetPage) -> [SheetPage] {
            let selected = selectedPagesInOrder
            return selected.contains(page) ? selected : [page]
        }

        // MARK: Selection (mouse clicks and arrow keys)

        /// NSCollectionView treats shift-click like ⌘-click (toggle single),
        /// so expand it to the standard anchor…clicked range ourselves.
        func collectionView(
            _ collectionView: NSCollectionView,
            shouldSelectItemsAt indexPaths: Set<IndexPath>
        ) -> Set<IndexPath> {
            guard
                NSEvent.modifierFlags.contains(.shift),
                let clicked = indexPaths.first?.item,
                let anchor = anchorIndex,
                pages.indices.contains(anchor),
                pages.indices.contains(clicked)
            else {
                return indexPaths
            }
            let range = Set(
                (min(anchor, clicked)...max(anchor, clicked)).map { IndexPath(item: $0, section: 0) }
            )
            pendingShiftRange = range
            pendingShiftClicked = clicked
            return range
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            var primaryIndex = indexPaths.first?.item
            if let range = pendingShiftRange {
                // Replace, don't extend: a shrinking shift-range should drop
                // previously selected items outside it.
                pendingShiftRange = nil
                if collectionView.selectionIndexPaths != range {
                    collectionView.selectionIndexPaths = range
                }
                primaryIndex = pendingShiftClicked
                pendingShiftClicked = nil
            } else if let clicked = indexPaths.first?.item {
                anchorIndex = clicked
            }
            publishSelection()
            if let primaryIndex, pages.indices.contains(primaryIndex) {
                parent.onPrimarySelection(pages[primaryIndex])
            }
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            publishSelection()
        }

        // MARK: Drag source

        func collectionView(
            _ collectionView: NSCollectionView,
            pasteboardWriterForItemAt indexPath: IndexPath
        ) -> NSPasteboardWriting? {
            guard pages.indices.contains(indexPath.item) else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(PageDragPayload.encode(pages[indexPath.item]), forType: .string)
            return pasteboardItem
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItemsAt indexPaths: Set<IndexPath>
        ) {
            draggingIndexes = indexPaths.map(\.item).sorted()
            didAcceptDrop = false
            parent.onDragActive(true)
            collapseDraggedGroup()
        }

        /// Non-contiguous selections collapse into one block at drag start so
        /// the strip layout matches what's being dragged. (Contiguous
        /// shift-range selections are a no-op here.)
        private func collapseDraggedGroup() {
            guard draggingIndexes.count > 1, let first = draggingIndexes.first else { return }
            let dragged = draggingIndexes.compactMap { pages.indices.contains($0) ? pages[$0] : nil }
            guard dragged.count == draggingIndexes.count else { return }
            var remaining = pages.filter { !dragged.contains($0) }
            let insertion = min(first, remaining.count)
            remaining.insert(contentsOf: dragged, at: insertion)
            if remaining != pages {
                applyArrangement(remaining, animated: true)
            }
            draggingIndexes = Array(insertion..<(insertion + dragged.count))
        }

        /// One composite drag image for the whole selection (stacked cards +
        /// count badge). This replaces AppKit's multi-image drag formation,
        /// whose gather-under-cursor animation is system-driven and freezes
        /// whenever the cursor moves — it was never our animation to fix.
        func collectionView(
            _ collectionView: NSCollectionView,
            draggingImageForItemsAt indexPaths: Set<IndexPath>,
            with event: NSEvent,
            offset dragImageOffset: NSPointPointer
        ) -> NSImage {
            let selectedPages = indexPaths.map(\.item).sorted()
                .compactMap { pages.indices.contains($0) ? pages[$0] : nil }
            return Self.dragImage(for: selectedPages)
        }

        private static func dragImage(for pages: [SheetPage]) -> NSImage {
            let cardSize = NSSize(width: 56, height: 56)
            let step: CGFloat = 5
            let cardCount = max(min(pages.count, 3), 1)
            let badgeRoom: CGFloat = 10
            let size = NSSize(
                width: cardSize.width + step * CGFloat(cardCount - 1) + badgeRoom,
                height: cardSize.height + step * CGFloat(cardCount - 1) + badgeRoom
            )
            let thumbnails: [NSImage?] = (0..<cardCount).map { index in
                pages.indices.contains(index) ? PageThumbnailRenderer.thumbnail(for: pages[index]) : nil
            }
            let totalCount = pages.count
            return NSImage(size: size, flipped: false) { _ in
                for cardIndex in stride(from: cardCount - 1, through: 0, by: -1) {
                    let cardRect = NSRect(
                        x: step * CGFloat(cardIndex),
                        y: step * CGFloat(cardCount - 1 - cardIndex),
                        width: cardSize.width,
                        height: cardSize.height
                    )
                    let path = NSBezierPath(roundedRect: cardRect, xRadius: 6, yRadius: 6)
                    NSColor.textBackgroundColor.setFill()
                    path.fill()
                    if let thumbnail = thumbnails[cardIndex] {
                        NSGraphicsContext.saveGraphicsState()
                        path.setClip()
                        thumbnail.draw(
                            in: cardRect.insetBy(dx: 2, dy: 2),
                            from: .zero,
                            operation: .sourceOver,
                            fraction: cardIndex == 0 ? 1 : 0.85
                        )
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    NSColor.separatorColor.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
                if totalCount > 1 {
                    let badgeRect = NSRect(x: size.width - 21, y: size.height - 21, width: 20, height: 20)
                    NSColor.controlAccentColor.setFill()
                    NSBezierPath(ovalIn: badgeRect).fill()
                    let text = NSAttributedString(
                        string: "\(totalCount)",
                        attributes: [
                            .font: NSFont.boldSystemFont(ofSize: 11),
                            .foregroundColor: NSColor.white,
                        ]
                    )
                    let textSize = text.size()
                    text.draw(at: NSPoint(
                        x: badgeRect.midX - textSize.width / 2,
                        y: badgeRect.midY - textSize.height / 2
                    ))
                }
                return true
            }
        }

        private func applyArrangement(_ newPages: [SheetPage], animated: Bool) {
            guard let collectionView else { return }
            let oldPages = pages
            pages = newPages
            var working = oldPages
            for targetIndex in newPages.indices {
                let page = newPages[targetIndex]
                guard let currentIndex = working.firstIndex(of: page), currentIndex != targetIndex else { continue }
                working.remove(at: currentIndex)
                working.insert(page, at: targetIndex)
                let from = IndexPath(item: currentIndex, section: 0)
                let to = IndexPath(item: targetIndex, section: 0)
                if animated {
                    collectionView.animator().moveItem(at: from, to: to)
                } else {
                    collectionView.moveItem(at: from, to: to)
                }
            }
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            dragOperation operation: NSDragOperation
        ) {
            parent.onDragActive(false)
            stopAutoScroll()
            if !didAcceptDrop {
                resyncToParent()
            }
            draggingIndexes = []
        }

        // MARK: Drop target

        private func isInternalDrag(_ draggingInfo: NSDraggingInfo) -> Bool {
            (draggingInfo.draggingSource as? NSCollectionView) === collectionView
        }

        private func incomingKeys(from draggingInfo: NSDraggingInfo) -> [PageKey] {
            (draggingInfo.draggingPasteboard.pasteboardItems ?? []).compactMap { item in
                item.string(forType: .string).flatMap(PageDragPayload.decode)
            }
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            validateDrop draggingInfo: NSDraggingInfo,
            proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
            dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
        ) -> NSDragOperation {
            dropOperation.pointee = .before
            updateAutoScroll(draggingInfo)
            if isInternalDrag(draggingInfo) {
                liveMove(to: proposedIndexPath.pointee.item)
            } else {
                let keys = incomingKeys(from: draggingInfo)
                if keys.count == 1, let key = keys.first {
                    updateGhost(for: key, proposed: proposedIndexPath.pointee.item)
                }
            }
            return .move
        }

        /// NSCollectionView doesn't autoscroll horizontal strips during drags;
        /// while the cursor sits in an edge zone, a timer scrolls continuously
        /// even with the cursor frozen.
        private func updateAutoScroll(_ draggingInfo: NSDraggingInfo) {
            guard let collectionView, let scrollView = collectionView.enclosingScrollView else { return }
            let point = collectionView.convert(draggingInfo.draggingLocation, from: nil)
            let visible = scrollView.contentView.bounds
            let margin: CGFloat = 44
            if point.x < visible.minX + margin {
                autoScrollStep = -10
            } else if point.x > visible.maxX - margin {
                autoScrollStep = 10
            } else {
                autoScrollStep = 0
            }
            if autoScrollStep == 0 {
                stopAutoScroll()
            } else if autoScrollTimer == nil {
                // .common includes the event-tracking mode drags run in.
                let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.autoScrollTick()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                autoScrollTimer = timer
            }
        }

        func stopAutoScroll() {
            autoScrollTimer?.invalidate()
            autoScrollTimer = nil
            autoScrollStep = 0
        }

        private func autoScrollTick() {
            guard
                autoScrollStep != 0,
                let collectionView,
                let scrollView = collectionView.enclosingScrollView
            else {
                stopAutoScroll()
                return
            }
            let visible = scrollView.contentView.bounds
            var origin = visible.origin
            origin.x = min(max(origin.x + autoScrollStep, 0), max(0, collectionView.bounds.width - visible.width))
            guard origin != visible.origin else { return }
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        /// Live make-room for internal drags of any size: the dragged block
        /// follows the cursor with AppKit's move animation, as before.
        private func liveMove(to proposed: Int) {
            guard !draggingIndexes.isEmpty else { return }
            let dragged = draggingIndexes.compactMap { pages.indices.contains($0) ? pages[$0] : nil }
            guard dragged.count == draggingIndexes.count else { return }
            let target = proposed - draggingIndexes.filter { $0 < proposed }.count
            var remaining = pages.filter { !dragged.contains($0) }
            let insertion = min(max(target, 0), remaining.count)
            remaining.insert(contentsOf: dragged, at: insertion)
            guard remaining != pages else { return }
            Self.logger.debug("liveMove rearrange: proposed=\(proposed) insertion=\(insertion) dragged=\(dragged.count)")
            applyArrangement(remaining, animated: true)
            draggingIndexes = Array(insertion..<(insertion + dragged.count))
        }

        private func updateGhost(for key: PageKey, proposed: Int) {
            guard let collectionView else { return }
            if let current = ghostIndex {
                var target = proposed
                if target > current { target -= 1 }
                target = min(max(target, 0), max(pages.count - 1, 0))
                guard target != current, pages.indices.contains(current) else { return }
                let page = pages.remove(at: current)
                pages.insert(page, at: target)
                collectionView.animator().moveItem(
                    at: IndexPath(item: current, section: 0),
                    to: IndexPath(item: target, section: 0)
                )
                ghostIndex = target
            } else {
                guard let page = parent.resolveIncoming(key) else { return }
                let index = min(max(proposed, 0), pages.count)
                pages.insert(page, at: index)
                collectionView.animator().insertItems(at: [IndexPath(item: index, section: 0)])
                ghostIndex = index
            }
        }

        func removeGhost() {
            guard let index = ghostIndex else { return }
            ghostIndex = nil
            guard pages.indices.contains(index), let collectionView else { return }
            pages.remove(at: index)
            collectionView.animator().deleteItems(at: [IndexPath(item: index, section: 0)])
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            acceptDrop draggingInfo: NSDraggingInfo,
            indexPath: IndexPath,
            dropOperation: NSCollectionView.DropOperation
        ) -> Bool {
            stopAutoScroll()
            if isInternalDrag(draggingInfo) {
                return acceptInternalDrop()
            }
            let keys = incomingKeys(from: draggingInfo)
            guard !keys.isEmpty else { return false }
            let insertion: Int
            if let ghost = ghostIndex {
                insertion = ghost
                ghostIndex = nil
            } else {
                insertion = min(max(indexPath.item, 0), pages.count)
            }
            return parent.onIncomingDrop(keys, insertion)
        }

        private func acceptInternalDrop() -> Bool {
            // Pages were already arranged live in validateDrop; just commit.
            didAcceptDrop = true
            let dragged = draggingIndexes.compactMap { pages.indices.contains($0) ? pages[$0] : nil }
            if !dragged.isEmpty {
                parent.selection = Set(dragged)
                if let first = dragged.first {
                    parent.onPrimarySelection(first)
                }
            }
            parent.onReorder(pages)
            return true
        }
    }
}

final class PageThumbItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PageThumbItem")

    private var hosting: NSHostingView<PageThumbnailView>?
    private var page: SheetPage?
    private var accent: Color = .blue
    private var toggleHiddenLabel = ""
    private var onTransform: ((PageTransformAction) -> Void)?
    private var onToggleHidden: (() -> Void)?

    override func loadView() {
        view = NSView()
    }

    func configure(
        page: SheetPage,
        accent: Color,
        toggleHiddenLabel: String,
        onTransform: @escaping (PageTransformAction) -> Void,
        onToggleHidden: @escaping () -> Void
    ) {
        self.page = page
        self.accent = accent
        self.toggleHiddenLabel = toggleHiddenLabel
        self.onTransform = onTransform
        self.onToggleHidden = onToggleHidden
        render()
    }

    override var isSelected: Bool {
        didSet { render() }
    }

    private func render() {
        guard let page else { return }
        let content = PageThumbnailView(
            page: page,
            isSelected: isSelected,
            accent: accent,
            onTransform: onTransform,
            toggleHiddenLabel: toggleHiddenLabel,
            onToggleHidden: onToggleHidden
        )
        if let hosting {
            hosting.rootView = content
        } else {
            let hostingView = NSHostingView(rootView: content)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: view.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            hosting = hostingView
        }
    }
}
