import Foundation

/// Keeps previews and open cheatsheets current with their files. FSEvents
/// watches the library's copies (edits and deletions made outside the app)
/// and, with sync on, the linked originals (edits made in other apps, pulled
/// into the copies by the usual sync check). A change refreshes only the
/// sheets it touches; the Pages section's reload button runs the same pass.
@MainActor
final class FileChangeMonitor {
    private let store: CheatsheetStore
    private let overlay: OverlayController
    private var copiesStream: FileEventStream?
    private var originalsStream: FileEventStream?
    /// Original path → the sheet linking it, as of the last rebuild.
    private var originals: [String: Cheatsheet.ID] = [:]
    /// Originals kept accessible while watched (sandbox).
    private var accessedOriginals: [URL] = []
    /// What the originals stream was built from; rebuilt only when it changes.
    private var originalsSignature: Int?
    private var pendingRefreshes: [Cheatsheet.ID: Task<Void, Never>] = [:]
    /// Coalesces a burst of events (an editor's save is several) and lets a
    /// save that replaces the file finish before deletions are judged.
    private static let settleDelay: Duration = .milliseconds(400)

    init(store: CheatsheetStore, overlay: OverlayController) {
        self.store = store
        self.overlay = overlay
    }

    func start() {
        let mediaPath = store.mediaRoot.resolvingSymlinksInPath().path
        copiesStream = FileEventStream(paths: [mediaPath]) { [weak self] paths in
            self?.handle(paths)
        }
        libraryDidChange()
    }

    /// Store changed: links may have been added or removed, or sync toggled.
    func libraryDidChange() {
        let links = store.syncsWithOriginals
            ? store.sheets.flatMap { sheet in sheet.links.map { (sheet.id, $0.value.bookmark) } }
            : []
        var hasher = Hasher()
        links.forEach { hasher.combine($0.0); hasher.combine($0.1) }
        let signature = hasher.finalize()
        guard signature != originalsSignature else { return }
        originalsSignature = signature
        rebuildOriginalsStream()
    }

    /// Refreshes one sheet now: imports files dropped into its folder, pulls
    /// in changed originals, then reloads its previews and open cheatsheets.
    /// A deleted copy stays listed (its page shows a placeholder and keeps
    /// its settings), so undoing the delete in Finder restores it fully.
    func refresh(_ sheetID: Cheatsheet.ID) async {
        pendingRefreshes[sheetID]?.cancel()
        pendingRefreshes[sheetID] = nil
        store.discoverNewFiles(in: sheetID)
        await store.checkLinks(for: sheetID)
        store.noteFilesChanged(in: sheetID)
        overlay.reloadPages(forSheet: sheetID)
    }

    // MARK: - Events

    private func handle(_ paths: [String]) {
        let mediaRoot = store.mediaRoot.resolvingSymlinksInPath()
        for sheetID in Self.affectedSheets(by: paths, mediaRoot: mediaRoot, originals: originals) {
            pendingRefreshes[sheetID]?.cancel()
            pendingRefreshes[sheetID] = Task { [weak self] in
                try? await Task.sleep(for: Self.settleDelay)
                guard !Task.isCancelled, let self else { return }
                await self.refresh(sheetID)
            }
        }
    }

    /// Sheets touched by changed paths: anything inside a sheet's copy folder
    /// (Media/<sheet id>/…), or a linked original. Pure, for tests.
    nonisolated static func affectedSheets(
        by paths: [String],
        mediaRoot: URL,
        originals: [String: Cheatsheet.ID]
    ) -> Set<Cheatsheet.ID> {
        let mediaPrefix = mediaRoot.path.hasSuffix("/") ? mediaRoot.path : mediaRoot.path + "/"
        var affected = Set<Cheatsheet.ID>()
        // Hidden files (Finder metadata, a staged review preview) never
        // affect what a sheet shows.
        for path in paths where !(path as NSString).lastPathComponent.hasPrefix(".") {
            if let sheetID = originals[path] {
                affected.insert(sheetID)
            } else if path.hasPrefix(mediaPrefix),
                      let folder = path.dropFirst(mediaPrefix.count).split(separator: "/").first,
                      let sheetID = UUID(uuidString: String(folder)) {
                affected.insert(sheetID)
            }
        }
        return affected
    }

    // MARK: - Originals

    private func rebuildOriginalsStream() {
        originalsStream?.stop()
        originalsStream = nil
        accessedOriginals.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedOriginals = []
        originals = [:]
        guard store.syncsWithOriginals else { return }
        for sheet in store.sheets {
            for file in sheet.links.keys {
                guard let url = store.originalURL(ofFile: file, in: sheet) else { continue }
                if url.startAccessingSecurityScopedResource() {
                    accessedOriginals.append(url)
                }
                originals[url.resolvingSymlinksInPath().path] = sheet.id
            }
        }
        // Watching each original's path (not its folder) needs access only to
        // the file itself; a save that replaces the file keeps the same path.
        originalsStream = FileEventStream(paths: Array(originals.keys)) { [weak self] paths in
            self?.handle(paths)
        }
    }
}
