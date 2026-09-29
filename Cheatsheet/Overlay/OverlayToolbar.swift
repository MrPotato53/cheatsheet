import SwiftUI

/// How the overlay's buttons are shown (General settings).
nonisolated enum OverlayButtonsMode: String, CaseIterable, Identifiable {
    /// All buttons, fading in while the overlay is hovered.
    case expanded
    /// One ☰ button that toggles the rest.
    case expandOnClick
    /// One ☰ button that turns into the rest while hovered.
    case expandOnHover

    static let defaultsKey = "overlayButtonsMode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .expanded: "Show all"
        case .expandOnClick: "Collapse, expand on click"
        case .expandOnHover: "Collapse, expand on hover"
        }
    }

    var collapses: Bool { self != .expanded }
}

/// The overlay's top-right controls. Collapsed modes fold them behind one
/// ☰ button. On hover, the ☰ gives way to the buttons themselves, and the
/// group stays open while the cursor is anywhere over it (gaps included),
/// so moving to a button never collapses it midway.
struct OverlayToolbar: View {

    let session: OverlaySession
    let controller: OverlayController
    /// The cursor is over the overlay; controls fade in.
    let isOverlayHovered: Bool
    @AppStorage(OverlayButtonsMode.defaultsKey, store: AppDefaults.store) private var mode = OverlayButtonsMode.expanded
    @State private var isExpanded = false
    /// Glass shapes that turn into one another: ☰ into the buttons, the
    /// search button into the search bar.
    @Namespace private var glass

    private var collapses: Bool { mode.collapses }

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            controls
        }
        .animation(.smooth(duration: 0.25), value: session.search.isActive)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if session.search.isActive {
                searchBar
            }
            if collapses {
                if isExpanded {
                    actionButtons
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                // On hover the buttons replace ☰ (nothing to click); for
                // click-to-expand it stays as the toggle.
                if !isExpanded || mode == .expandOnClick {
                    menuButton
                        .transition(.opacity)
                }
            } else {
                actionButtons
            }
            // Last, so it sits in the corner: expanding the other controls
            // grows leftward and never moves it out from under the cursor.
            if session.editor != nil {
                doneButton
            }
        }
        .padding(8)
        // The hover region is the whole group (plus padding), not each
        // button: gaps between buttons don't count as leaving.
        .contentShape(Rectangle())
        .onHover { hovering in
            guard mode == .expandOnHover else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                isExpanded = hovering
            }
        }
    }

    private var currentPage: SheetPage? {
        guard !session.isLoadingPages else { return nil }
        return session.currentPage
    }

    private var hasSearchablePages: Bool {
        session.pages.contains { MediaKind.of($0.url).isSearchable }
    }

    /// Faded until the overlay is hovered, except where noted; always shown
    /// once the collapsed group is expanded.
    private func revealed(always: Bool = false) -> Double {
        collapses || always || isOverlayHovered ? 1 : 0
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            if !session.search.isActive, hasSearchablePages {
                searchButton
            }
            if let page = currentPage, session.editor == nil {
                if MediaKind.of(page.url).hasRawView {
                    rawToggleButton(for: page)
                }
                if OverlayController.isEditable(page) {
                    editButton
                }
            }
            pinButton
        }
    }

    // MARK: - Buttons

    private var menuButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: isExpanded ? "xmark" : "line.3.horizontal")
                .frame(width: 18, height: 18)
                .overlay(alignment: .topTrailing) {
                    if session.isPinned, !isExpanded {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.tint)
                            .offset(x: 5, y: -5)
                    }
                }
        }
        .overlayControl()
        .accessibilityIdentifier("overlay.moreButtons")
        .circleChrome()
        .glassEffectID("menu", in: glass)
        .opacity(session.isPinned || isOverlayHovered || isExpanded ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isOverlayHovered)
        .help(mode == .expandOnClick ? (isExpanded ? "Hide controls" : "Show controls") : "Cheatsheet buttons")
    }

    private var searchButton: some View {
        Button {
            controller.openSearch(in: session)
        } label: {
            Image(systemName: "magnifyingglass")
                .frame(width: 18, height: 18)
        }
        .overlayControl()
        .accessibilityIdentifier("overlay.search")
        .circleChrome()
        .glassEffectID("search", in: glass)
        .opacity(revealed())
        .animation(.easeInOut(duration: 0.15), value: isOverlayHovered)
        .help("Search pages (⌘F)")
    }

    private func rawToggleButton(for page: SheetPage) -> some View {
        Button {
            controller.toggleRaw(session)
        } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .frame(width: 18, height: 18)
                .foregroundStyle(page.showsRaw ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .overlayControl()
        .accessibilityIdentifier("overlay.rawToggle")
        .accessibilityValue(page.showsRaw ? "raw" : "formatted")
        .circleChrome()
        .glassEffectID("raw", in: glass)
        .opacity(revealed())
        .animation(.easeInOut(duration: 0.15), value: isOverlayHovered)
        .help(page.showsRaw ? "Show formatted" : "Show raw source")
    }

    private var editButton: some View {
        Button {
            controller.beginEditing(in: session)
        } label: {
            Image(systemName: "pencil")
                .frame(width: 18, height: 18)
        }
        .overlayControl()
        .accessibilityIdentifier("overlay.edit")
        .circleChrome()
        .glassEffectID("edit", in: glass)
        .opacity(revealed())
        .animation(.easeInOut(duration: 0.15), value: isOverlayHovered)
        .help("Edit this page (⌘E)")
    }

    private var doneButton: some View {
        Button {
            controller.endEditing(in: session)
        } label: {
            Label("Done", systemImage: "checkmark")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 28)
        }
        .overlayControl()
        .accessibilityIdentifier("overlay.doneEditing")
        // The one prominent action while editing, as in a toolbar.
        .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
        .glassEffectID("done", in: glass)
        .help("Finish editing (esc)")
    }

    private var pinButton: some View {
        Button {
            controller.togglePin(session)
        } label: {
            Image(systemName: session.isPinned ? "pin.fill" : "pin")
                .frame(width: 18, height: 18)
        }
        .overlayControl()
        .accessibilityIdentifier("overlay.pin")
        .circleChrome()
        .glassEffectID("pin", in: glass)
        .opacity(revealed(always: session.isPinned))
        .animation(.easeInOut(duration: 0.15), value: isOverlayHovered)
        .help(session.isPinned ? "Unpin: closes normally again" : "Pin: stays open until unpinned")
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
        .overlayControl()
        .padding(.horizontal, 10)
        .frame(height: 28)
        .glassEffect(in: .capsule)
        // Grows out of the search button.
        .glassEffectID("search", in: glass)
    }
}

/// Shown over a page whose Cheatsheet copy and original differ. Nothing is
/// written to either side until the user picks.
struct SyncReviewBanner: View {
    let fileName: String
    let originalChanged: Bool
    let onResolve: (SyncResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "arrow.triangle.2.circlepath")
                .font(.callout.weight(.semibold))
            Text("Choose which version to keep. Neither file changes until you do.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Use Original") { onResolve(.useOriginal) }
                    .help("Replace the copy with the original")
                    .accessibilityIdentifier("overlay.review.useOriginal")
                Button("Use Copy") { onResolve(.useCheatsheetCopy) }
                    .help("Overwrite the original with the copy")
                    .accessibilityIdentifier("overlay.review.useCopy")
                Button("Keep Both") { onResolve(.keepBoth) }
                    .help("Keep the copy as a separate file, then follow the original")
                    .accessibilityIdentifier("overlay.review.keepBoth")
            }
            .controlSize(.small)
            .focusable(false)
            .pointingHandCursor()
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .glassEffect(in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overlay.review")
    }

    private var title: String {
        originalChanged
            ? "“\(fileName)” changed here and in the original"
            : "The copy of “\(fileName)” has changes the original doesn't"
    }
}

extension EditSaveOutcome {
    var statusText: String {
        switch self {
        case .savedToOriginal: "Saved to original"
        case .savedToCopy: "Saved"
        case .keptInCopy(.originalMissing): "Saved in Cheatsheet — original missing"
        case .keptInCopy(.needsReview): "Saved in Cheatsheet — review needed"
        case .keptInCopy: "Saved in Cheatsheet"
        case .failed: "Couldn't save"
        }
    }

    var isWarning: Bool {
        switch self {
        case .savedToOriginal, .savedToCopy: false
        case .keptInCopy, .failed: true
        }
    }
}

extension View {
    /// Overlay buttons never take keyboard focus: keys are handled by the
    /// panel, and a focused button draws a ring when the overlay opens.
    func overlayControl() -> some View {
        buttonStyle(.borderless)
            .focusable(false)
            .focusEffectDisabled()
            .pointingHandCursor()
    }

    /// A round Liquid Glass button that responds to the pointer.
    func circleChrome() -> some View {
        padding(5).glassEffect(.regular.interactive(), in: .circle)
    }
}
