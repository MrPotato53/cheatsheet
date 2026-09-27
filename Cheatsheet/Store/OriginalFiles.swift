import Foundation

/// File-system side of "keep in sync with original files": bookmarks to the
/// user's originals, comparing them with Cheatsheet's copies, and moving
/// content between the two. Nonisolated: checks run off the main thread
/// (an original may sit on a slow or sleeping drive).
///
/// Rule of thumb: the original may refresh the copy automatically, but the
/// copy never overwrites the original without the user choosing so (or the
/// user editing through Cheatsheet while the two are in sync).
nonisolated enum OriginalFiles {
    struct CheckResult: Equatable {
        let state: FileSyncState
        /// The link with refreshed stamps/bookmark; equal to the input when
        /// nothing changed.
        let link: FileLink
        /// The copy was replaced with the original's newer content.
        let refreshedCopy: Bool
    }

    // MARK: - Bookmarks

    static func makeLink(original: URL, copy: URL) -> FileLink? {
        guard let bookmark = bookmark(for: original) else { return nil }
        return FileLink(
            bookmark: bookmark,
            originalStamp: FileFingerprint.of(original),
            copyStamp: FileFingerprint.of(copy)
        )
    }

    /// A link to an original chosen after the fact ("Link to Original…"):
    /// no shared history, so the first check compares contents.
    static func makeUnverifiedLink(original: URL) -> FileLink? {
        bookmark(for: original).map { FileLink(bookmark: $0, originalStamp: nil, copyStamp: nil) }
    }

    /// Security-scoped so the sandboxed app can reopen the file in later
    /// launches; plain as a fallback for files the app can always reach.
    private static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// The original's current location, or nil when it's gone. A file moved
    /// to the Trash still resolves, but the user deleted it: missing.
    static func resolve(_ link: FileLink) -> (url: URL, isStale: Bool)? {
        for options: URL.BookmarkResolutionOptions in [[.withSecurityScope, .withoutUI], [.withoutUI]] {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: link.bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                guard !isTrashed(url), FileManager.default.fileExists(atPath: url.path) else { return nil }
                return (url, isStale)
            }
        }
        return nil
    }

    static func isTrashed(_ url: URL) -> Bool {
        url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes")
    }

    static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return try body()
    }

    // MARK: - Checking

    static func check(_ link: FileLink, copy: URL) -> CheckResult {
        let missing = CheckResult(state: .originalMissing, link: link, refreshedCopy: false)
        guard let (original, isStale) = resolve(link) else { return missing }
        var link = link
        // Moved/renamed: keep following it next launch too.
        if isStale, let fresh = withAccess(to: original, { bookmark(for: original) }) {
            link.bookmark = fresh
        }
        return withAccess(to: original) {
            guard let originalStamp = FileFingerprint.of(original) else { return missing }
            switch SyncComparison.between(original: originalStamp, copy: FileFingerprint.of(copy), link: link) {
            case .inSync:
                return CheckResult(state: .linked, link: link, refreshedCopy: false)
            case .originalChanged:
                guard let data = try? Data(contentsOf: original), (try? data.write(to: copy, options: .atomic)) != nil else {
                    return missing
                }
                return CheckResult(state: .linked, link: matched(link, original: original, copy: copy), refreshedCopy: true)
            case .copyChanged(let originalChanged):
                // Touched but identical (or a fresh link to the same
                // content): nothing to ask about.
                if contentsEqual(original, copy) {
                    return CheckResult(state: .linked, link: matched(link, original: original, copy: copy), refreshedCopy: false)
                }
                return CheckResult(state: .needsReview(originalChanged: originalChanged), link: link, refreshedCopy: false)
            }
        }
    }

    /// Records both sides as matching right now.
    static func matched(_ link: FileLink, original: URL, copy: URL) -> FileLink {
        var updated = link
        updated.originalStamp = FileFingerprint.of(original)
        updated.copyStamp = FileFingerprint.of(copy)
        return updated
    }

    static func contentsEqual(_ a: URL, _ b: URL) -> Bool {
        guard let first = try? Data(contentsOf: a), let second = try? Data(contentsOf: b) else { return false }
        return first == second
    }

    // MARK: - Moving content

    /// Writes new content to the original, then mirrors it into the copy.
    /// Nil when the original can't be written (gone, locked, no access):
    /// the caller keeps the content in the copy instead.
    static func write(_ data: Data, toOriginalOf link: FileLink, copy: URL) -> FileLink? {
        guard let (original, _) = resolve(link) else { return nil }
        return withAccess(to: original) {
            guard writeInPlace(data, to: original), (try? data.write(to: copy, options: .atomic)) != nil else {
                return nil
            }
            return matched(link, original: original, copy: copy)
        }
    }

    /// Replaces the copy with the original's content.
    static func adoptOriginal(_ link: FileLink, copy: URL) -> FileLink? {
        guard let (original, _) = resolve(link) else { return nil }
        return withAccess(to: original) {
            guard let data = try? Data(contentsOf: original), (try? data.write(to: copy, options: .atomic)) != nil else {
                return nil
            }
            return matched(link, original: original, copy: copy)
        }
    }

    /// In place, not atomic: an atomic save writes a temp file beside the
    /// original, and the sandbox grants access to the file, not its folder.
    /// Coordinated, so apps that have the file open (editors, iCloud) see it.
    private static func writeInPlace(_ data: Data, to url: URL) -> Bool {
        var coordinationError: NSError?
        var succeeded = false
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            succeeded = (try? data.write(to: target)) != nil
        }
        return coordinationError == nil && succeeded
    }
}
