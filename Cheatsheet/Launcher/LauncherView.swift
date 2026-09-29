import KeyboardShortcuts
import SwiftUI

/// Search bar plus the matching cheatsheets, Spotlight-style: the top match
/// selected, matched letters in bold, a fixed number of rows then scrolling.
/// Before typing it lists nothing, all, or recent sheets (LauncherEmptyState).
struct LauncherView: View {
    let controller: LauncherController
    private let cornerRadius: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !controller.results.isEmpty {
                Divider()
                resultList
            }
        }
        .frame(
            width: LauncherLayout.width,
            height: LauncherLayout.height(resultCount: controller.results.count),
            alignment: .top
        )
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("launcher.root")
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            OverlaySearchField(
                text: controller.query,
                focusRequest: controller.focusRequest,
                placeholder: "Search Cheatsheets",
                fontSize: 22,
                accessibilityID: "launcher.field"
            ) { controller.setQuery($0) }
        }
        .padding(.horizontal, 18)
        .frame(height: LauncherLayout.barHeight)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(controller.results.enumerated()), id: \.element.id) { index, result in
                        row(result, isSelected: index == controller.selectedIndex)
                            .id(result.id)
                            .contentShape(Rectangle())
                            .onTapGesture { controller.open(result) }
                    }
                }
                .padding(LauncherLayout.listPadding)
            }
            .scrollIndicators(.never)
            .onChange(of: controller.selectedIndex) { _, index in
                guard controller.results.indices.contains(index) else { return }
                proxy.scrollTo(controller.results[index].id)
            }
        }
    }

    private func row(_ result: LauncherResult, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.sheet == nil ? "gearshape" : "doc.text")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 20)
            Text(highlightedName(result))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let sheet = result.sheet, let shortcut = shortcutLabel(for: sheet) {
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .frame(height: LauncherLayout.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("launcher.result")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func highlightedName(_ result: LauncherResult) -> AttributedString {
        let matched = Set(result.match?.matchedOffsets ?? [])
        var text = AttributedString()
        for (offset, character) in result.title.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) {
                piece.font = .system(size: 14, weight: .bold)
            }
            text.append(piece)
        }
        return text
    }

    /// With both methods on, the list also teaches each sheet's shortcut.
    private func shortcutLabel(for sheet: Cheatsheet) -> String? {
        guard SheetOpenMethod.current == .both else { return nil }
        return KeyboardShortcuts.getShortcut(for: sheet.shortcutName)?.description
    }
}
