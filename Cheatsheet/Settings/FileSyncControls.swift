import AppKit
import SwiftUI

/// A document row's link to its original, shown while sync is on: a chain
/// whose look is the state, and a menu with that state's actions (the one
/// that fixes it first). Showing files in Finder is the row's folder button.
struct FileLinkMenu: View {
    let file: String
    let sheet: Cheatsheet
    let state: FileSyncState
    let onReview: () -> Void
    /// Linking finished: the detail view reports problems or opens review.
    let onLinked: (CheatsheetStore.LinkResult) -> Void
    @Environment(CheatsheetStore.self) private var store

    private var isLinked: Bool { sheet.links[file] != nil }

    var body: some View {
        Menu {
            Section(title) {
                if let path = originalPath {
                    Text(path)
                }
            }
            if case .needsReview = state {
                Button("Review Differences…", action: onReview)
                Divider()
            }
            if isLinked {
                // A linked file's original is its original: pointing it at
                // another file is unlink, then link. Only a missing one is
                // looked for again.
                if state == .originalMissing {
                    Button("Locate Original…") {
                        chooseOriginal()
                    }
                }
                Button("Unlink Original") {
                    store.unlinkOriginal(ofFile: file, in: sheet.id)
                }
            } else {
                Button("Link to Original…") {
                    chooseOriginal()
                }
            }
        } label: {
            FileLinkIcon(state: state, isLinked: isLinked)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
        .accessibilityIdentifier("detail.fileLink")
        .accessibilityValue(FileLinkIcon.kind(state: state, isLinked: isLinked).rawValue)
    }

    private var title: String {
        switch FileLinkIcon.kind(state: state, isLinked: isLinked) {
        case .linked: "Linked to its original"
        case .needsReview: "The copy and its original differ"
        case .broken: "Original missing (deleted, moved, or on a disconnected drive)"
        case .notLinked: "Not linked to an original"
        }
    }

    private var originalPath: String? {
        store.originalURL(ofFile: file, in: sheet).map { ($0.path as NSString).abbreviatingWithTildeInPath }
    }

    private func chooseOriginal() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Link"
        panel.message = "Choose the original of “\(file)”. If the two differ, you'll choose which to keep; neither is changed until then."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            onLinked(await store.linkOriginal(url, toFile: file, in: sheet.id))
        }
    }
}

/// The chain: gray when linked, orange with a badge when it needs review,
/// red and struck through when the original is gone, faint with a plus when
/// there's nothing linked yet.
struct FileLinkIcon: View {
    enum Kind: String {
        case linked, needsReview, broken, notLinked
    }

    let state: FileSyncState
    let isLinked: Bool

    static func kind(state: FileSyncState, isLinked: Bool) -> Kind {
        switch state {
        case .linked: .linked
        case .needsReview: .needsReview
        case .originalMissing: .broken
        case .copyOnly: isLinked ? .linked : .notLinked
        }
    }

    var body: some View {
        switch Self.kind(state: state, isLinked: isLinked) {
        case .linked:
            chain.foregroundStyle(.secondary)
        case .needsReview:
            chain
                .foregroundStyle(.orange)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white, .orange)
                        .offset(x: 4, y: -3)
                }
        case .broken:
            chain
                .foregroundStyle(.red)
                .overlay {
                    // SF Symbols has no broken chain: strike it through.
                    Capsule()
                        .fill(.red)
                        .frame(width: 2, height: 20)
                        .rotationEffect(.degrees(-45))
                }
        case .notLinked:
            Image(systemName: "link.badge.plus")
                .frame(width: 18, height: 18)
                .foregroundStyle(.tertiary)
        }
    }

    private var chain: some View {
        Image(systemName: "link")
            .fontWeight(.semibold)
            .frame(width: 18, height: 18)
    }
}
