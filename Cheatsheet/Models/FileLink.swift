import Foundation

/// A file's identity for change detection: modification time plus size.
nonisolated struct FileFingerprint: Codable, Hashable {
    var modified: Date
    var size: Int64

    static func of(_ url: URL) -> FileFingerprint? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let modified = attributes[.modificationDate] as? Date,
            let size = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }
        // Millisecond precision: the library stores dates as doubles, which
        // can't hold APFS's nanoseconds, so an unrounded stamp would never
        // match itself again after a relaunch.
        let milliseconds = (modified.timeIntervalSinceReferenceDate * 1000).rounded() / 1000
        return FileFingerprint(modified: Date(timeIntervalSinceReferenceDate: milliseconds), size: size)
    }
}

/// Where one of a sheet's files came from. Cheatsheet always keeps its own
/// copy (what's displayed and exported); with sync on, the copy follows the
/// original and edits go to the original.
nonisolated struct FileLink: Codable, Hashable {
    /// Security-scoped bookmark: follows the original across moves/renames.
    var bookmark: Data
    /// Both sides as of the last time they matched. Nil means "never
    /// compared" (a freshly linked file), so the next check compares
    /// contents instead.
    var originalStamp: FileFingerprint?
    var copyStamp: FileFingerprint?
}

/// A file's relationship to its original, as shown in settings and used to
/// pick where edits land. Always `.copyOnly` while sync is off.
nonisolated enum FileSyncState: Equatable {
    /// No original to follow: never linked, imported, or sync is off.
    case copyOnly
    /// In sync; edits go to the original.
    case linked
    /// Deleted, or on a drive that isn't connected. Edits stay in the copy.
    case originalMissing
    /// The copy has changes the original doesn't (and maybe vice versa).
    /// Never resolved automatically: the user picks a side.
    case needsReview(originalChanged: Bool)

    var needsAttention: Bool {
        switch self {
        case .originalMissing, .needsReview: true
        case .copyOnly, .linked: false
        }
    }
}

/// How the two sides compare since they last matched.
nonisolated enum SyncComparison: Equatable {
    case inSync
    /// Only the original changed: the copy is refreshed from it.
    case originalChanged
    /// The copy changed (the original may have too): ask.
    case copyChanged(originalChanged: Bool)

    static func between(
        original: FileFingerprint,
        copy: FileFingerprint?,
        link: FileLink
    ) -> SyncComparison {
        let originalChanged = link.originalStamp != original
        let copyChanged = link.copyStamp != copy
        switch (originalChanged, copyChanged) {
        case (false, false): return .inSync
        case (true, false): return .originalChanged
        case (_, true): return .copyChanged(originalChanged: originalChanged)
        }
    }
}

/// A user's answer to "which version do you want?".
nonisolated enum SyncResolution: CaseIterable {
    /// Replace Cheatsheet's copy with the original.
    case useOriginal
    /// Write Cheatsheet's copy over the original.
    case useCheatsheetCopy
    /// Keep Cheatsheet's version as a separate file, then follow the original.
    case keepBoth
}
