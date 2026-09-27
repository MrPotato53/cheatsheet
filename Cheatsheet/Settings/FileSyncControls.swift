import AppKit
import SwiftUI

/// A document row's link status, shown while sync is on. "Review" is a
/// button: it opens the review sheet with both versions and the choices.
struct FileSyncBadge: View {
    let state: FileSyncState
    let isLinked: Bool
    let onReview: () -> Void

    var body: some View {
        switch state {
        case .linked:
            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Linked to its original: updates from it, and overlay edits are saved to it.")
        case .originalMissing:
            Label("Original missing", systemImage: "questionmark.folder")
                .font(.caption)
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .help("The original was deleted or its drive isn't connected. Cheatsheet shows its own copy and saves edits there; you'll be asked before the original is changed once it's back.")
        case .needsReview:
            Button(action: onReview) {
                Label("Review…", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.orange)
            .help("Cheatsheet's copy and the original differ. Click to choose which version to keep.")
            .accessibilityIdentifier("detail.reviewSync")
        case .copyOnly:
            if !isLinked {
                Text("Copy only")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Not linked to an original (e.g. imported). Link one from the ⋯ menu.")
                    .accessibilityIdentifier("detail.copyOnly")
            }
        }
    }
}

/// Per-file link actions.
struct FileSyncMenu: View {
    let file: String
    let sheet: Cheatsheet
    let state: FileSyncState
    let onReveal: (URL) -> Void
    let onReview: () -> Void
    /// Linking finished: the detail view reports problems or opens review.
    let onLinked: (CheatsheetStore.LinkResult) -> Void
    @Environment(CheatsheetStore.self) private var store

    var body: some View {
        Menu {
            if case .needsReview = state {
                Button("Review Differences…", action: onReview)
            }
            if sheet.links[file] != nil {
                if state == .linked {
                    Button("Show Cheatsheet's Copy in Finder") {
                        onReveal(store.fileURL(for: sheet, file: file))
                    }
                }
                Button(state == .originalMissing ? "Locate Original…" : "Link to a Different Original…") {
                    chooseOriginal()
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
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Original file options")
        .accessibilityIdentifier("detail.fileSyncMenu")
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

/// Side-by-side facts about a copy and its original, and the three ways to
/// reconcile them (or unlink, when the wrong file was linked). Nothing is
/// written until a choice is clicked.
struct SyncReviewSheet: View {
    let file: String
    let sheetID: Cheatsheet.ID
    let onDismiss: () -> Void
    @Environment(CheatsheetStore.self) private var store

    private struct Side {
        let fingerprint: FileFingerprint?
        let url: URL?
    }

    var body: some View {
        let sheet = store.sheets.first { $0.id == sheetID }
        let isFreshLink = sheet?.links[file]?.originalStamp == nil
        let original = sheet.map(originalSide) ?? Side(fingerprint: nil, url: nil)
        let copyURL = sheet.map { store.fileURL(for: $0, file: file) }
        let copy = Side(fingerprint: copyURL.flatMap(FileFingerprint.of), url: copyURL)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("“\(file)” doesn't match its original", systemImage: "exclamationmark.circle.fill")
                    .font(.headline)
                    .symbolRenderingMode(.multicolor)
                Text(isFreshLink
                    ? "The file you linked has different contents from Cheatsheet's copy. If it's the wrong file, unlink it."
                    : "Cheatsheet's copy has changed since the two last matched\(originalChangedToo ? ", and so has the original" : ""). Neither file is changed until you choose.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                sideRow("Original", side: original, other: copy, showsPath: true)
                sideRow("Cheatsheet's copy", side: copy, other: original, showsPath: false)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            VStack(spacing: 8) {
                choice("Use Original", detail: "Replace Cheatsheet's copy with the original.", .useOriginal)
                    .accessibilityIdentifier("review.useOriginal")
                choice("Use Cheatsheet's Version", detail: "Overwrite the original with Cheatsheet's copy.", .useCheatsheetCopy)
                    .accessibilityIdentifier("review.useCopy")
                choice("Keep Both", detail: "Add Cheatsheet's copy to this cheatsheet as a separate file, then follow the original.", .keepBoth)
                    .accessibilityIdentifier("review.keepBoth")
            }
            HStack {
                Button("Unlink Original") {
                    store.unlinkOriginal(ofFile: file, in: sheetID)
                    onDismiss()
                }
                .help("Keep Cheatsheet's copy as it is and stop following this original")
                .accessibilityIdentifier("review.unlink")
                Spacer()
                Button("Decide Later", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("review.later")
            }
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.sheet")
    }

    private var originalChangedToo: Bool {
        guard let sheet = store.sheets.first(where: { $0.id == sheetID }) else { return false }
        if case .needsReview(let originalChanged) = store.syncState(of: file, in: sheet) {
            return originalChanged
        }
        return false
    }

    private func originalSide(_ sheet: Cheatsheet) -> Side {
        guard let url = store.originalURL(ofFile: file, in: sheet) else { return Side(fingerprint: nil, url: nil) }
        return Side(fingerprint: OriginalFiles.withAccess(to: url) { FileFingerprint.of(url) }, url: url)
    }

    @ViewBuilder
    private func sideRow(_ title: String, side: Side, other: Side, showsPath: Bool) -> some View {
        GridRow {
            Text(title)
                .fontWeight(.medium)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 2) {
                if let fingerprint = side.fingerprint {
                    HStack(spacing: 6) {
                        Text("\(fingerprint.modified.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: fingerprint.size, countStyle: .file))")
                            .fixedSize()
                        if let otherDate = other.fingerprint?.modified, fingerprint.modified > otherDate {
                            Text("Newer")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 5)
                                .background(.tint.opacity(0.2), in: Capsule())
                        }
                    }
                } else {
                    Text("Not found").foregroundStyle(.secondary)
                }
                if showsPath, let url = side.url {
                    Text((url.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let url = side.url {
                Button {
                    OriginalFiles.withAccess(to: url) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                // The sheet would otherwise focus (and highlight) it on open.
                .focusable(false)
                .help("Show in Finder")
            }
        }
    }

    private func choice(_ title: String, detail: String, _ resolution: SyncResolution) -> some View {
        Button {
            store.resolveSync(resolution, forFile: file, in: sheetID)
            onDismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        // No choice is pre-selected: Space/Return must never pick one.
        .focusable(false)
    }
}
