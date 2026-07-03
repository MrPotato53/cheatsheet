import SwiftUI

struct OverlayContentView: View {
    let controller: OverlayController
    @State private var isHovering = false

    var body: some View {
        ZStack {
            if let page = controller.currentPage {
                MediaPageView(page: page)
                    .id(page)
            } else {
                ContentUnavailableView("Nothing to show", systemImage: "doc")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            if controller.pages.count > 1 {
                pageControls
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }

    private var pageControls: some View {
        HStack(spacing: 12) {
            Button {
                controller.goToPreviousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(controller.pageIndex == 0)

            Text("\(controller.pageIndex + 1) / \(controller.pages.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                controller.goToNextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(controller.pageIndex >= controller.pages.count - 1)
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
