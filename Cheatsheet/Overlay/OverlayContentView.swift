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
                    pageView(at: index)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, hasDragStrip ? Self.dragStripHeight : 0)
        .background(.regularMaterial)
        // Ticking a checkbox in rendered markdown edits the file; only the
        // live overlay offers it (settings previews stay read-only).
        .environment(\.markdownTaskHandler) { [controller, session] url, line, checked in
            controller.setTask(atLine: line, checked: checked, url: url, in: session)
        }
        .overlay(alignment: .bottom) {
            if session.pages.count > 1, session.editor == nil {
                pageControls
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let editor = session.editor {
                editorStatus(editor)
            }
        }
        .overlay(alignment: .top) {
            if hasDragStrip {
                dragHandle
            }
        }
        .overlay(alignment: .bottom) {
            reviewBanner
        }
        .overlay(alignment: .topTrailing) {
            OverlayToolbar(session: session, controller: controller, isOverlayHovered: isHovering)
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

    /// Remounts a page when its file changed underneath it.
    private struct PageMount: Hashable {
        let page: SheetPage
        let revision: Int
    }

    @ViewBuilder
    private func pageView(at index: Int) -> some View {
        let page = session.pages[index]
        if index == session.pageIndex, let editor = session.editor {
            // Edited untransformed: rotated or mirrored text isn't editable.
            OverlayTextEditor(initialText: editor.text) { text in
                controller.editorTextChanged(text, in: session)
            }
            .padding(8)
            .id(editor.url)
        } else {
            MediaPageView(
                page: page,
                highlight: session.search.highlight(forPage: index),
                isInteractive: index == session.pageIndex
            )
            .pageTransform(page)
            .opacity(index == session.pageIndex ? 1 : 0)
            .allowsHitTesting(index == session.pageIndex)
            .id(PageMount(page: page, revision: session.contentRevision))
        }
    }

    private func editorStatus(_ editor: OverlayEditorState) -> some View {
        let warning = editor.lastSave?.isWarning == true
        return HStack(spacing: 6) {
            if warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(editor.isDirty ? "Editing…" : editor.lastSave?.statusText ?? "Editing")
            Text("· esc to finish")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
        .padding(10)
        .accessibilityIdentifier("overlay.editorStatus")
    }

    @ViewBuilder
    private var reviewBanner: some View {
        if session.editor == nil,
           !session.isLoadingPages,
           let page = session.currentPage,
           case .needsReview(let originalChanged) = controller.syncState(of: page, in: session) {
            SyncReviewBanner(fileName: page.url.lastPathComponent, originalChanged: originalChanged) { resolution in
                controller.resolveSync(resolution, for: page, in: session)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, session.pages.count > 1 ? 52 : 12)
        }
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

    private var pageControls: some View {
        HStack(spacing: 12) {
            Button {
                controller.goToPreviousPage(in: session)
            } label: {
                Image(systemName: "chevron.left")
            }
            .focusable(false)
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
            .focusable(false)
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
