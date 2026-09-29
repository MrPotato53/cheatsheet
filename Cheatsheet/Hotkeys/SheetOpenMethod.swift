import Foundation

/// How cheatsheets are opened from the keyboard (General settings). With
/// `.search` alone, per-sheet shortcuts stay stored but unregistered, so
/// switching back restores them.
nonisolated enum SheetOpenMethod: String, CaseIterable, Identifiable {
    case shortcuts
    case search
    case both

    static let defaultsKey = "sheetOpenMethod"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shortcuts: "Keyboard shortcuts"
        case .search: "Search bar"
        case .both: "Keyboard shortcuts and search bar"
        }
    }

    var usesSheetShortcuts: Bool { self != .search }
    var usesSearch: Bool { self != .shortcuts }

    @MainActor static var current: SheetOpenMethod {
        AppDefaults.store.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .shortcuts
    }
}
