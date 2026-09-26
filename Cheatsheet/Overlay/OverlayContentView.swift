import AppKit
import SwiftUI

/// Starts a native window drag on mouse-down: text and web pages consume
/// mouse events for selection/scrolling, so background-dragging can't work
/// there — this strip is the reliable grab area.
private struct WindowDragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

    }

    func makeNSView(context: Context) -> HandleView {
        HandleView()
    }

    func updateNSView(_ nsView: HandleView, context: Context) {}
}

struct OverlayContentView: View {
    /// Height of the reserved drag strip at the top; the panel fitting math
    /// accounts for it so it never overlaps page content.
    static let dragStripHeight: CGFloat = 20

    let session: OverlaySession
    let controller: OverlayController
    @State private var isHovering = false

    private var hasDragStrip: Bool {
        session.sheet.dragBehavior.allowsAdjustment
    }

    /// The current page plus its neighbors stay mounted (hidden), so their
    /// content is already decoded when the user pages — switching is instant.
    private var preloadedIndices: [Int] {
        guard !session.pages.isEmpty else { return [] }
        let lower = max(session.pageIndex - 2, 0)
        let upper = min(session.pageIndex + 2, session.pages.count - 1)
        return Array(lower...upper)
    }

    var body: some View {
        ZStack {
            if session.isLoadingPages {
                ProgressView()
                    .controlSize(.large)
            } else if session.pages.isEmpty {
                ContentUnavailableView("Nothing to show", systemImage: "doc")
            } else {
                ForEach(preloadedIndices, id: \.self) { index in
                    let page = session.pages[index]
                    MediaPageView(
                        page: page,
                        highlight: session.search.highlight(forPage: index),
                        isInteractive: index == session.pageIndex
                    )
                        .pageTransform(page)
                        .opacity(index == session.pageIndex ? 1 : 0)
                        .allowsHitTesting(index == session.pageIndex)
                        .id(page)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, hasDragStrip ? Self.dragStripHeight : 0)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            if session.pages.count > 1 {
                pageControls
            }
        }
        .overlay(alignment: .top) {
            if hasDragStrip {
                dragHandle
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                if session.search.isActive {
                    searchBar
                } else if hasSearchablePages {
                    searchButton
                }
                if let currentPage, MediaKind.of(currentPage.url).hasRawView {
                    rawToggleButton(for: currentPage)
                }
                pinButton
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overlay.root")
    }

    private var dragHandle: some View {
        ZStack {
            // The band itself is reserved space in the layout; only the grip
            // affordance fades with hover. The hit area is always active.
            Capsule()
                .fill(.secondary)
                .frame(width: 36, height: 5)
                .opacity(isHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHovering)
                .allowsHitTesting(false)
            WindowDragHandle()
                .overlayCursor(.openHand)
        }
        .frame(height: Self.dragStripHeight)
        .frame(maxWidth: .infinity)
        .help("Drag to move")
    }

    private var hasSearchablePages: Bool {
        session.pages.contains { MediaKind.of($0.url) != .unsupported }
    }

    private var searchButton: some View {
        Button {
            controller.openSearch(in: session)
        } label: {
            Image(systemName: "magnifyingglass")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .pointingHandCursor()
        .accessibilityIdentifier("overlay.search")
        .padding(5)
        .background(.thinMaterial, in: Circle())
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .help("Search pages (⌘F)")
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            OverlaySearchField(
                text: session.search.query,
                focusRequest: session.search.focusRequest
            ) { controller.setSearchQuery($0, in: session) }
            .frame(width: 140)
            if let status = session.search.statusText {
                Text(status)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityIdentifier("overlay.search.status")
            }
            Group {
                Button {
                    controller.stepSearch(in: session, forward: false)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Previous match (⇧↩)")
                .accessibilityIdentifier("overlay.search.previous")
                Button {
                    controller.stepSearch(in: session, forward: true)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Next match (↩)")
                .accessibilityIdentifier("overlay.search.next")
            }
            .disabled(session.search.matches.total == 0)
            Button {
                controller.closeSearch(in: session)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .help("Close search (esc)")
            .accessibilityIdentifier("overlay.search.close")
        }
        .buttonStyle(.borderless)
        .pointingHandCursor()
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.thinMaterial, in: Capsule())
    }

    private var currentPage: SheetPage? {
        guard !session.isLoadingPages, session.pages.indices.contains(session.pageIndex) else { return nil }
        return session.pages[session.pageIndex]
    }

    private func rawToggleButton(for page: SheetPage) -> some View {
        Button {
            controller.toggleRaw(session)
        } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .frame(width: 18, height: 18)
                .foregroundStyle(page.showsRaw ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.borderless)
        .pointingHandCursor()
        .accessibilityIdentifier("overlay.rawToggle")
        .accessibilityValue(page.showsRaw ? "raw" : "formatted")
        .padding(5)
        .background(.thinMaterial, in: Circle())
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .help(page.showsRaw ? "Show formatted" : "Show raw source")
    }

    private var pinButton: some View {
        Button {
            controller.togglePin(session)
        } label: {
            Image(systemName: session.isPinned ? "pin.fill" : "pin")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .pointingHandCursor()
        .accessibilityIdentifier("overlay.pin")
        .padding(5)
        .background(.thinMaterial, in: Circle())
        .opacity(session.isPinned || isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .help(session.isPinned ? "Unpin — overlay dismisses normally again" : "Pin — overlay stays open until unpinned")
    }

    private var pageControls: some View {
        HStack(spacing: 12) {
            Button {
                controller.goToPreviousPage(in: session)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(session.pageIndex == 0)
            .accessibilityIdentifier("overlay.previousPage")

            Text("\(session.pageIndex + 1) / \(session.pages.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("overlay.pageLabel")

            Button {
                controller.goToNextPage(in: session)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(session.pageIndex >= session.pages.count - 1)
            .accessibilityIdentifier("overlay.nextPage")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .padding(.bottom, 12)
        .opacity(isHovering ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }
}
