import Foundation

/// Which pages a cheatsheet search counts and steps through (General settings).
nonisolated enum SearchScope: String, CaseIterable, Identifiable {
    case allPages
    case currentPage

    static let defaultsKey = "searchScope"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allPages: "All pages"
        case .currentPage: "Current page"
        }
    }

    @MainActor static var current: SearchScope {
        AppDefaults.store.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .allPages
    }
}
