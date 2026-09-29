import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI

/// A copy and its original as two cards: thumbnail and facts together.
/// Clicking a card ticks it as a version to keep (both: keep both), and
/// the Keep button names the outcome. Nothing starts ticked, and nothing is
/// written until Keep is clicked; overwriting the original asks first.
struct SyncReviewSheet: View {
    let file: String
    let sheetID: Cheatsheet.ID
    let onDismiss: () -> Void
    @Environment(CheatsheetStore.self) private var store
    @State private var kept: Set<Version> = []
    @State private var hoveredVersion: Version?
    @State private var isConfirmingOverwrite = false
    @State private var quickLookURL: URL?
    /// The original is outside the sandbox: Quick Look reads it only while
    /// access is held.
    @State private var accessedURL: URL?

    enum Version: CaseIterable {
        case original, copy
    }

    private struct Side {
        let fingerprint: FileFingerprint?
        let url: URL?
    }

    private var resolution: SyncResolution? {
        switch (kept.contains(.original), kept.contains(.copy)) {
        case (true, true): .keepBoth
        case (true, false): .useOriginal
        case (false, true): .useCheatsheetCopy
        case (false, false): nil
        }
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
                Text((isFreshLink
                    ? "The file you linked has different contents from the copy."
                    : "The copy has changed since the two last matched\(originalChangedToo ? ", and so has the original" : ".")")
                    + " Choose which to keep. Nothing changes until you do.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 12) {
                card(.original, side: original, other: copy)
                card(.copy, side: copy, other: original)
            }
            Text(outcomeText)
                .font(.callout)
                .foregroundStyle(resolution == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("review.outcome")
            HStack {
                Button("Unlink Original") {
                    store.unlinkOriginal(ofFile: file, in: sheetID)
                    onDismiss()
                }
                .help("Keep the copy as it is and stop following this original")
                .accessibilityIdentifier("review.unlink")
                Spacer()
                Button("Decide Later", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("review.later")
                Button(keepTitle, action: keep)
                    .keyboardShortcut(.defaultAction)
                    .disabled(resolution == nil)
                    .accessibilityIdentifier("review.keep")
            }
        }
        .padding(20)
        .frame(width: 520)
        .background {
            // Space previews the hovered card (closes the preview if open),
            // as in Finder. A shortcut works without anything focused.
            Button("Preview", action: togglePreviewOfHovered)
                .keyboardShortcut(.space, modifiers: [])
                .hidden()
        }
        .opensUnfocused()
        .quickLookPreview($quickLookURL)
        .onChange(of: quickLookURL) { _, url in
            if url == nil { endAccess() }
        }
        .onDisappear(perform: endAccess)
        .confirmationDialog("Overwrite the original?", isPresented: $isConfirmingOverwrite) {
            Button("Overwrite Original", role: .destructive) {
                resolve(.useCheatsheetCopy)
            }
            .accessibilityIdentifier("review.confirmOverwrite")
        } message: {
            Text("The original “\(original.url?.lastPathComponent ?? file)” will be replaced with the cheatsheet's copy.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.sheet")
    }

    // MARK: - Choosing

    private var keepTitle: String {
        switch resolution {
        case .useOriginal: "Keep Original"
        case .useCheatsheetCopy: "Keep Copy"
        case .keepBoth: "Keep Both"
        case nil: "Choose a Version"
        }
    }

    private var outcomeText: String {
        switch resolution {
        case .useOriginal: "Replaces the copy with the original."
        case .useCheatsheetCopy: "Overwrites the original with the copy."
        case .keepBoth: "Saves the copy as a separate file in this cheatsheet; this page then follows the original."
        case nil: "Click a version to keep it, or both to keep both."
        }
    }

    private func toggle(_ version: Version) {
        withAnimation(.easeOut(duration: 0.12)) {
            if kept.contains(version) {
                kept.remove(version)
            } else {
                kept.insert(version)
            }
        }
    }

    private func keep() {
        guard let resolution else { return }
        if resolution == .useCheatsheetCopy {
            isConfirmingOverwrite = true
        } else {
            resolve(resolution)
        }
    }

    private func resolve(_ resolution: SyncResolution) {
        store.resolveSync(resolution, forFile: file, in: sheetID)
        onDismiss()
    }

    // MARK: - Cards

    private func card(_ version: Version, side: Side, other: Side) -> some View {
        let isNewer = side.fingerprint.map { mine in
            other.fingerprint.map { mine.modified > $0.modified } ?? false
        } ?? false
        return VersionCard(
            title: version == .original ? "Original" : "Copy",
            url: side.url,
            fingerprint: side.fingerprint,
            location: version == .original ? originalPath(of: side) ?? "Not found" : "In this cheatsheet",
            isNewer: isNewer,
            isKept: kept.contains(version),
            isReplaced: !kept.isEmpty && !kept.contains(version),
            onToggle: { toggle(version) },
            onPreview: { preview(side.url) },
            onHover: { hovering in
                if hovering {
                    hoveredVersion = version
                } else if hoveredVersion == version {
                    hoveredVersion = nil
                }
            }
        )
        .accessibilityIdentifier(version == .original ? "review.originalCard" : "review.copyCard")
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

    private func originalPath(of side: Side) -> String? {
        side.url.map { ($0.path as NSString).abbreviatingWithTildeInPath }
    }

    // MARK: - Quick Look

    private func togglePreviewOfHovered() {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        guard let hoveredVersion, let sheet = store.sheets.first(where: { $0.id == sheetID }) else { return }
        preview(hoveredVersion == .original
            ? store.originalURL(ofFile: file, in: sheet)
            : store.fileURL(for: sheet, file: file))
    }

    private func preview(_ url: URL?) {
        guard let url else { return }
        endAccess()
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }
        quickLookURL = url
    }

    private func endAccess() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }
}

/// One version: a tickable card with its thumbnail, date, size and place.
/// While hovered, a corner button opens it in Quick Look.
private struct VersionCard: View {
    let title: String
    let url: URL?
    let fingerprint: FileFingerprint?
    let location: String
    let isNewer: Bool
    let isKept: Bool
    /// The other version is kept and this one isn't: it'll be replaced.
    let isReplaced: Bool
    let onToggle: () -> Void
    let onPreview: () -> Void
    let onHover: (Bool) -> Void
    @State private var image: NSImage?
    @State private var isHovering = false

    private static let thumbnailSize = CGSize(width: 220, height: 120)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: isKept ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isKept ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                if let fingerprint {
                    HStack(spacing: 6) {
                        Text(fingerprint.modified.formatted(date: .abbreviated, time: .shortened))
                            .lineLimit(1)
                        if isNewer {
                            Text("Newer")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.2), in: Capsule())
                                .fixedSize()
                        }
                    }
                    Text(ByteCountFormatter.string(fromByteCount: fingerprint.size, countStyle: .file))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not found").foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(location)
                    Spacer(minLength: 0)
                    if let url {
                        Button {
                            OriginalFiles.withAccess(to: url) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                    }
                }
            }
            .font(.callout)
            Text(isReplaced ? "Will be replaced" : " ")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isKept ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .opacity(isReplaced ? 0.5 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: onToggle)
        .onHover { hovering in
            isHovering = hovering
            onHover(hovering)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isKept ? "kept" : "not kept")
        .accessibilityAction(named: "Toggle", onToggle)
        .task(id: url) {
            image = await Self.thumbnail(for: url)
        }
    }

    private var thumbnail: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else if url != nil {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.thumbnailSize.height)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            if isHovering, url != nil {
                Button(action: onPreview) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .padding(5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Preview (Space)")
                .accessibilityIdentifier("review.preview")
            }
        }
    }

    /// Quick Look renders any kind of file the system can (PDF, image,
    /// HTML, text…), falling back to its icon.
    private static func thumbnail(for url: URL?) async -> NSImage? {
        guard let url else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: thumbnailSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
