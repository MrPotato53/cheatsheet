import AppKit

/// Light, dark, or the system's appearance (General settings). Applied app
/// wide through `NSApp.appearance`, so settings, the overlays' material and
/// glass, and web pages' `prefers-color-scheme` all follow it.
nonisolated enum AppAppearance: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    static let defaultsKey = "appearance"

    var id: String { rawValue }

    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .system
    }

    /// Nil follows the system.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        case .system: nil
        }
    }

    var label: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }

    @MainActor static var current: AppAppearance {
        AppAppearance(storedValue: AppDefaults.store.string(forKey: defaultsKey))
    }

    @MainActor static func applyCurrent() {
        NSApp.appearance = current.appearanceName.flatMap(NSAppearance.init(named:))
    }
}
