import Foundation

/// What the search bar lists before anything is typed (General settings).
nonisolated enum LauncherEmptyState: String, CaseIterable, Identifiable {
    case nothing
    case all
    case recent

    static let defaultsKey = "launcherEmptyState"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nothing: "None"
        case .all: "All cheatsheets"
        case .recent: "Recently opened cheatsheets"
        }
    }

    @MainActor static var current: LauncherEmptyState {
        AppDefaults.store.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .nothing
    }

    /// Sheets to list for an empty query: all in library order, or the
    /// recently opened ones that still exist, most recent first.
    static func sheets(for state: LauncherEmptyState, library: [Cheatsheet], recentIDs: [Cheatsheet.ID]) -> [Cheatsheet] {
        switch state {
        case .nothing:
            return []
        case .all:
            return library
        case .recent:
            let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return recentIDs.compactMap { byID[$0] }
        }
    }
}

/// Cheatsheets in the order they were last opened, however they were opened
/// (search bar, shortcut, or menu). Starts empty.
@MainActor
enum RecentSheets {
    static let defaultsKey = "recentSheetIDs"
    static let limit = 20

    static var ids: [Cheatsheet.ID] {
        (AppDefaults.store.stringArray(forKey: defaultsKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    static func record(_ id: Cheatsheet.ID) {
        let current = ids
        // Holding a hold-to-show hotkey repeats opens; skip redundant writes.
        guard current.first != id else { return }
        save(recording(id, in: current, limit: limit))
    }

    /// Drops sheets no longer in the library (deleted, or replaced by an
    /// import) so they don't take up slots in the list.
    static func prune(keeping library: [Cheatsheet]) {
        let current = ids
        let kept = pruned(current, keeping: Set(library.map(\.id)))
        guard kept != current else { return }
        save(kept)
    }

    private static func save(_ ids: [Cheatsheet.ID]) {
        AppDefaults.store.set(ids.map(\.uuidString), forKey: defaultsKey)
    }

    nonisolated static func pruned(_ ids: [Cheatsheet.ID], keeping existing: Set<Cheatsheet.ID>) -> [Cheatsheet.ID] {
        ids.filter(existing.contains)
    }

    /// Moves `id` to the front, dropping duplicates and anything past `limit`.
    nonisolated static func recording(_ id: Cheatsheet.ID, in ids: [Cheatsheet.ID], limit: Int) -> [Cheatsheet.ID] {
        Array(([id] + ids.filter { $0 != id }).prefix(limit))
    }
}
