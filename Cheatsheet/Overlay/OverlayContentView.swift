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

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
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

    var body: some View {
        ZStack {
            if let page = session.currentPage {
                MediaPageView(page: page)
                    .pageTransform(page)
                    .id(page)
            } else {
                ContentUnavailableView("Nothing to show", systemImage: "doc")
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
            pinButton
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
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
        }
        .frame(height: Self.dragStripHeight)
        .frame(maxWidth: .infinity)
        .help("Drag to move")
    }

    private var pinButton: some View {
        Button {
            controller.togglePin(session)
        } label: {
            Image(systemName: session.isPinned ? "pin.fill" : "pin")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .padding(5)
        .background(.thinMaterial, in: Circle())
        .padding(8)
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

            Text("\(session.pageIndex + 1) / \(session.pages.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                controller.goToNextPage(in: session)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(session.pageIndex >= session.pages.count - 1)
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
