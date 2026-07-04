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

nonisolated enum Rotation: Int, Codable, CaseIterable, Identifiable {
    case deg0 = 0
    case deg90 = 90
    case deg180 = 180
    case deg270 = 270

    var id: Int { rawValue }
    var degrees: Double { Double(rawValue) }
    var swapsAxes: Bool { self == .deg90 || self == .deg270 }
    var label: String { "\(rawValue)°" }
    var rotatedLeft: Rotation { Rotation(rawValue: (rawValue + 270) % 360) ?? .deg0 }
    var rotatedRight: Rotation { Rotation(rawValue: (rawValue + 90) % 360) ?? .deg0 }
}

/// One display page: a non-PDF file, or a single page of a PDF.
/// rotation nil means "inherit the sheet's default rotation";
/// flips nil means "not flipped" (kept optional so older libraries decode).
nonisolated struct PageRef: Codable, Hashable {
    var file: String
    var pdfPageIndex: Int?
    var rotation: Rotation?
    var flipHorizontal: Bool?
    var flipVertical: Bool?
    /// Hidden pages stay in the order (recoverable in settings) but are
    /// excluded from the overlay.
    var hidden: Bool?

    var key: PageKey { PageKey(file: file, pdfPageIndex: pdfPageIndex) }
}

/// Page identity independent of per-page settings like rotation.
nonisolated struct PageKey: Hashable {
    let file: String
    let pdfPageIndex: Int?
}

nonisolated enum StartPage: Codable, Hashable {
    case first
    case lastViewed
    case fixed(index: Int)
}

/// Center of the overlay as fractions of the target screen's visible frame,
/// measured from the bottom-left (AppKit coordinates). (0.5, 0.5) = centered.
nonisolated struct RelativePosition: Codable, Hashable {
    var x: Double
    var y: Double

    static let center = RelativePosition(x: 0.5, y: 0.5)
}

/// Per-axis overlay adjustment policy: forbidden entirely, allowed but
/// reverting to the configured value on next open, or allowed with the last
/// user adjustment persisting as the new spawn geometry.
nonisolated enum GeometryBehavior: String, Codable, CaseIterable, Identifiable {
    case locked
    case resets
    case remembers

    var id: String { rawValue }
    var allowsAdjustment: Bool { self != .locked }
}

nonisolated struct Cheatsheet: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var files: [String] = []
    /// Custom page order, allowing pages of different documents to interleave.
    /// Empty means "derived": files in order, PDFs expanded page by page.
    var pageOrder: [PageRef] = []
    var activation: ActivationMode = .toggle
    var startPage: StartPage = .lastViewed
    var previewScale: Double = 0.6
    var position: RelativePosition = .center
    var dragBehavior: GeometryBehavior = .remembers
    var resizeBehavior: GeometryBehavior = .remembers
    var target: DisplayTarget = .cursorScreen
    var rotation: Rotation = .deg0

    var shortcutName: KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("cheatsheet-\(id.uuidString)")
    }
}

// Custom decoding lives in an extension so the memberwise initializer is kept.
// Fields added after 1.0 decode with defaults so existing libraries keep loading.
extension Cheatsheet {
    private enum CodingKeys: String, CodingKey {
        case id, name, files, pageOrder, activation, startPage, previewScale
        case position, dragBehavior, resizeBehavior, target, rotation
    }

    /// Pre-1.x libraries stored two-state persistence modes under these keys.
    private enum LegacyKeys: String, CodingKey {
        case positionMode, sizeMode
    }

    private nonisolated static func migratedBehavior(_ legacy: String?) -> GeometryBehavior? {
        switch legacy {
        case "configured": .resets
        case "lastUsed": .remembers
        default: nil
        }
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
        pageOrder = try container.decodeIfPresent([PageRef].self, forKey: .pageOrder) ?? []
        activation = try container.decodeIfPresent(ActivationMode.self, forKey: .activation) ?? .toggle
        startPage = try container.decodeIfPresent(StartPage.self, forKey: .startPage) ?? .lastViewed
        previewScale = try container.decodeIfPresent(Double.self, forKey: .previewScale) ?? 0.6
        position = try container.decodeIfPresent(RelativePosition.self, forKey: .position) ?? .center
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        dragBehavior = try container.decodeIfPresent(GeometryBehavior.self, forKey: .dragBehavior)
            ?? Self.migratedBehavior(try legacy.decodeIfPresent(String.self, forKey: .positionMode))
            ?? .remembers
        resizeBehavior = try container.decodeIfPresent(GeometryBehavior.self, forKey: .resizeBehavior)
            ?? Self.migratedBehavior(try legacy.decodeIfPresent(String.self, forKey: .sizeMode))
            ?? .remembers
        target = try container.decodeIfPresent(DisplayTarget.self, forKey: .target) ?? .cursorScreen
        rotation = try container.decodeIfPresent(Rotation.self, forKey: .rotation) ?? .deg0
    }
}
