import Foundation
import KeyboardShortcuts

nonisolated enum ActivationMode: String, Codable, CaseIterable, Identifiable {
    case toggle
    case hold

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toggle: "Toggle"
        case .hold: "Hold to show"
        }
    }
}

nonisolated enum DisplayTarget: Codable, Hashable {
    case cursorScreen
    case focusedScreen
    case specific(uuid: String, name: String)
}

nonisolated struct Cheatsheet: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var files: [String] = []
    var activation: ActivationMode = .toggle
    var previewScale: Double = 0.6
    var target: DisplayTarget = .cursorScreen

    var shortcutName: KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("cheatsheet-\(id.uuidString)")
    }
}
