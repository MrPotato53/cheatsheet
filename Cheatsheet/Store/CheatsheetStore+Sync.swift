import AppKit
import Foundation

/// Where a saved edit ended up, for the editor's status line.
enum EditSaveOutcome: Equatable {
    /// Written to the user's original (and mirrored into the copy).
    case savedToOriginal
    /// The copy is the file (not linked, or sync is off).
    case savedToCopy
    /// Meant for the original but it couldn't be written (missing, locked,
    /// or awaiting review): kept in the copy, which now needs review.
    case keptInCopy(FileSyncState)
    case failed
}

extension CheatsheetStore {
    static let syncDefaultsKey = "syncWithOriginals"

    /// For display. A linked file not yet checked this launch shows as
    /// linked; writes check first (see `writeContents`).
    func syncState(of file: String, in sheet: Cheatsheet) -> FileSyncState {
        guard syncsWithOriginals, sheet.links[file] != nil else { return .copyOnly }
        return syncStates[sheet.id]?[file] ?? .linked
    }

    // MARK: - Checking

    /// Compares every linked file of the sheet with its original: newer
    /// originals refresh their copies; anything else only updates states.
    /// Returns whether any copy was refreshed (displayed pages are stale).
    @discardableResult
    func checkLinks(for sheetID: Cheatsheet.ID) async -> Bool {
        guard let sheet = sheets.first(where: { $0.id == sheetID }) else { return false }
        guard syncsWithOriginals else {
            syncStates[sheetID] = nil
            return false
        }
        let jobs = sheet.files.compactMap { file in
            sheet.links[file].map { (file: file, link: $0, copy: fileURL(for: sheet, file: file)) }
        }
        let results = await Task.detached(priority: .userInitiated) {
            jobs.map { (file: $0.file, before: $0.link, result: OriginalFiles.check($0.link, copy: $0.copy)) }
        }.value
        return apply(results, to: sheetID)
    }

    func checkAllLinks() async {
        for sheetID in sheets.map(\.id) {
            await checkLinks(for: sheetID)
        }
    }

    /// Synchronous single-file check, for writes that must know right now.
    @discardableResult
    private func checkLinkNow(_ file: String, in sheetID: Cheatsheet.ID) -> FileSyncState {
        guard
            syncsWithOriginals,
            let sheet = sheets.first(where: { $0.id == sheetID }),
            let link = sheet.links[file]
        else { return .copyOnly }
        let result = OriginalFiles.check(link, copy: fileURL(for: sheet, file: file))
        apply([(file: file, before: link, result: result)], to: sheetID)
        return result.state
    }

    @discardableResult
    private func apply(
        _ results: [(file: String, before: FileLink, result: OriginalFiles.CheckResult)],
        to sheetID: Cheatsheet.ID
    ) -> Bool {
        guard var sheet = sheets.first(where: { $0.id == sheetID }) else { return false }
        var states = syncStates[sheetID] ?? [:]
        var refreshed = false
        // Skip files re-linked or removed while the check ran.
        for (file, before, result) in results where sheet.links[file] == before {
            states[file] = result.state
            sheet.links[file] = result.link
            refreshed = refreshed || result.refreshedCopy
        }
        syncStates[sheetID] = states
        update(sheet)
        touch()
        return refreshed
    }

    // MARK: - Editing

    /// Saves edited content: to the original when it's linked and in sync,
    /// otherwise to Cheatsheet's copy (which then waits for review if an
    /// original exists — it's never overwritten without asking).
    @discardableResult
    func writeContents(_ data: Data, toFile file: String, in sheetID: Cheatsheet.ID) -> EditSaveOutcome {
        guard let sheet = sheets.first(where: { $0.id == sheetID }) else { return .failed }
        let copy = fileURL(for: sheet, file: file)
        let isLinked = syncsWithOriginals && sheet.links[file] != nil
        let state = isLinked ? (syncStates[sheetID]?[file] ?? checkLinkNow(file, in: sheetID)) : .copyOnly
        if state == .linked,
           var current = sheets.first(where: { $0.id == sheetID }),
           let link = current.links[file],
           let updated = OriginalFiles.write(data, toOriginalOf: link, copy: copy) {
            current.links[file] = updated
            syncStates[sheetID, default: [:]][file] = .linked
            update(current)
            return .savedToOriginal
        }
        guard (try? data.write(to: copy, options: .atomic)) != nil else { return .failed }
        guard isLinked else { return .savedToCopy }
        return .keptInCopy(checkLinkNow(file, in: sheetID))
    }

    // MARK: - Review

    /// Applies the user's choice for a file whose copy and original differ.
    @discardableResult
    func resolveSync(_ resolution: SyncResolution, forFile file: String, in sheetID: Cheatsheet.ID) -> Bool {
        guard let sheet = sheets.first(where: { $0.id == sheetID }), let link = sheet.links[file] else { return false }
        let copy = fileURL(for: sheet, file: file)
        let updated: FileLink?
        switch resolution {
        case .useOriginal:
            updated = OriginalFiles.adoptOriginal(link, copy: copy)
        case .useCheatsheetCopy:
            updated = (try? Data(contentsOf: copy)).flatMap {
                OriginalFiles.write($0, toOriginalOf: link, copy: copy)
            }
        case .keepBoth:
            guard keepCheatsheetVersion(of: file, in: sheet) else { return false }
            updated = OriginalFiles.adoptOriginal(link, copy: copy)
        }
        guard let updated, var current = sheets.first(where: { $0.id == sheetID }) else { return false }
        current.links[file] = updated
        syncStates[sheetID, default: [:]][file] = .linked
        update(current)
        touch()
        return true
    }

    /// "Keep both": Cheatsheet's version joins the sheet as its own file.
    private func keepCheatsheetVersion(of file: String, in sheet: Cheatsheet) -> Bool {
        let source = URL(filePath: file)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let name = ext.isEmpty ? "\(base) (Cheatsheet version)" : "\(base) (Cheatsheet version).\(ext)"
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: fileURL(for: sheet, file: file),
                to: staging.appendingPathComponent(name)
            )
        } catch {
            return false
        }
        return !addFiles([staging.appendingPathComponent(name)], to: sheet.id, linksOriginals: false).isEmpty
    }

    // MARK: - Linking

    enum LinkResult: Equatable {
        /// Same contents: linked and in sync.
        case linked
        /// Contents differ: the user picks which version to keep.
        case needsReview
        /// A different kind of file (a PDF for a markdown page): refused,
        /// since either choice would leave a page that can't display.
        case differentKind(expected: MediaKind, chosen: MediaKind)
        case failed
    }

    /// Links (or re-links) a file to an original the user picked. Contents
    /// are compared right away; a difference asks, and nothing is written.
    @discardableResult
    func linkOriginal(_ original: URL, toFile file: String, in sheetID: Cheatsheet.ID) async -> LinkResult {
        let expected = MediaKind.of(URL(filePath: file))
        let chosen = MediaKind.of(original)
        guard expected == chosen else { return .differentKind(expected: expected, chosen: chosen) }
        guard
            var sheet = sheets.first(where: { $0.id == sheetID }),
            let link = OriginalFiles.withAccess(to: original, { OriginalFiles.makeUnverifiedLink(original: original) })
        else { return .failed }
        sheet.links[file] = link
        syncStates[sheetID]?[file] = nil
        update(sheet)
        await checkLinks(for: sheetID)
        guard let current = sheets.first(where: { $0.id == sheetID }) else { return .failed }
        switch syncState(of: file, in: current) {
        case .linked: return .linked
        case .needsReview: return .needsReview
        case .copyOnly, .originalMissing: return .failed
        }
    }

    func unlinkOriginal(ofFile file: String, in sheetID: Cheatsheet.ID) {
        guard var sheet = sheets.first(where: { $0.id == sheetID }) else { return }
        sheet.links[file] = nil
        syncStates[sheetID]?[file] = nil
        update(sheet)
    }

    /// The original's current location, when it can be found.
    func originalURL(ofFile file: String, in sheet: Cheatsheet) -> URL? {
        sheet.links[file].flatMap(OriginalFiles.resolve)?.url
    }

    /// The file edits go to: the original while linked and in sync,
    /// otherwise Cheatsheet's copy. Reveal in Finder shows this one.
    func activeURL(ofFile file: String, in sheet: Cheatsheet) -> URL {
        if syncState(of: file, in: sheet) == .linked, let original = originalURL(ofFile: file, in: sheet) {
            return original
        }
        return fileURL(for: sheet, file: file)
    }
}
