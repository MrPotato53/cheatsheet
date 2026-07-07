import AppKit
import Foundation

/// True when the app was launched by the UI test runner, which passes a
/// per-run identifier in CHEATSHEET_TEST_RUN. All test hooks key off this and
/// compile to "inactive" in release builds.
nonisolated enum UITestMode {
    static let runID: String? = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CHEATSHEET_TEST_RUN"]
        #else
        return nil
        #endif
    }()

    static var isActive: Bool { runID != nil }

    /// Library root for the test run. Lives in the sandbox container's temp
    /// directory so the sandboxed app can read and write it freely, and is
    /// unique per run so tests never see each other's state.
    static var storeRoot: URL? {
        runID.map {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("cheatsheet-uitest-\($0)", isDirectory: true)
        }
    }
}

/// The defaults store for user-facing settings (Escape dismissal, Dock icon
/// policy). Standard defaults normally; under UI tests an isolated suite that
/// is wiped at each launch and pre-populated from CHEATSHEET_TEST_DEFAULTS,
/// so tests are deterministic and never touch the developer's real settings.
@MainActor
enum AppDefaults {
    static let store: UserDefaults = {
        guard UITestMode.isActive, let suite = UserDefaults(suiteName: "potatodev.Cheatsheet.uitest") else {
            return .standard
        }
        suite.removePersistentDomain(forName: "potatodev.Cheatsheet.uitest")
        if let json = ProcessInfo.processInfo.environment["CHEATSHEET_TEST_DEFAULTS"],
           let values = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] {
            for (key, value) in values {
                suite.set(value, forKey: key)
            }
        }
        return suite
    }()
}

#if DEBUG
/// Builds a deterministic library from the CHEATSHEET_TEST_SEED JSON passed
/// by the UI test runner. The runner can't write fixtures itself — the app is
/// sandboxed — so the app generates them: solid-color PNGs at requested pixel
/// sizes (aspect-ratio-sensitive geometry tests depend on exact sizes) and
/// small text files.
///
/// Seed format (all sheet fields except name/pages optional):
/// [{"name": "Alpha", "previewScale": 0.5, "activation": "toggle",
///   "dragBehavior": "remembers", "resizeBehavior": "remembers",
///   "startPage": "first" | "lastViewed" | "fixed:2",
///   "keepsStartPageLoaded": false, "position": {"x": 0.5, "y": 0.5},
///   "pages": [{"file": "wide.png", "width": 1500, "height": 500},
///             {"file": "notes.txt", "text": "hello"}]}]
@MainActor
enum UITestSeeder {
    private nonisolated struct PageSpec: Decodable {
        let file: String
        let width: Int?
        let height: Int?
        let text: String?
    }

    private nonisolated struct SheetSpec: Decodable {
        let name: String
        let previewScale: Double?
        let activation: String?
        let dragBehavior: String?
        let resizeBehavior: String?
        let startPage: String?
        let keepsStartPageLoaded: Bool?
        let position: RelativePosition?
        let pages: [PageSpec]
    }

    private static let pageColors: [NSColor] = [
        .systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemTeal,
    ]

    static func seed(rootURL: URL, mediaRoot: URL, libraryURL: URL) {
        // Every test launch starts from a clean root, seeded or not.
        try? FileManager.default.removeItem(at: rootURL)
        guard
            let json = ProcessInfo.processInfo.environment["CHEATSHEET_TEST_SEED"],
            let specs = try? JSONDecoder().decode([SheetSpec].self, from: Data(json.utf8))
        else { return }
        try? FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)

        var sheets: [Cheatsheet] = []
        for spec in specs {
            var sheet = Cheatsheet(name: spec.name)
            if let scale = spec.previewScale { sheet.previewScale = scale }
            if let raw = spec.activation, let mode = ActivationMode(rawValue: raw) { sheet.activation = mode }
            if let raw = spec.dragBehavior, let behavior = GeometryBehavior(rawValue: raw) { sheet.dragBehavior = behavior }
            if let raw = spec.resizeBehavior, let behavior = GeometryBehavior(rawValue: raw) { sheet.resizeBehavior = behavior }
            if let keeps = spec.keepsStartPageLoaded { sheet.keepsStartPageLoaded = keeps }
            if let position = spec.position { sheet.position = position }
            sheet.startPage = startPage(from: spec.startPage)

            let directory = mediaRoot.appendingPathComponent(sheet.id.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, page) in spec.pages.enumerated() {
                let url = directory.appendingPathComponent(page.file)
                if let text = page.text {
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                } else {
                    writePNG(
                        width: page.width ?? 800,
                        height: page.height ?? 600,
                        color: pageColors[index % pageColors.count],
                        to: url
                    )
                }
                sheet.files.append(page.file)
            }
            sheets.append(sheet)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(sheets) {
            try? data.write(to: libraryURL, options: .atomic)
        }
    }

    private static func startPage(from raw: String?) -> StartPage {
        switch raw {
        case "first":
            return .first
        case nil, "lastViewed":
            return .lastViewed
        default:
            if let raw, raw.hasPrefix("fixed:"), let index = Int(raw.dropFirst("fixed:".count)) {
                return .fixed(index: index)
            }
            return .lastViewed
        }
    }

    private static func writePNG(width: Int, height: Int, color: NSColor, to url: URL) {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            color.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            // A contrasting corner swatch so pages are visually tellable apart
            // in screenshots and recordings.
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: min(width, 40), height: min(height, 40)).fill()
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
