import Foundation
import ImageIO
import Vision

/// One recognized line of text in an image, kept so match boxes can be
/// resolved for any substring later.
nonisolated struct RecognizedLine: Sendable {
    /// Alternative readings, most confident first. A misread in the top
    /// reading is often right in the next one.
    let candidates: [RecognizedText]
    /// Line bounds in unit coordinates of the upright image, top-left origin.
    let unitBox: CGRect
}

/// On-device text recognition (Apple Vision — no model download, nothing
/// leaves the Mac) for image pages. Runs lazily the first time a search needs
/// an image, then stays cached in memory for that version of the file.
actor ImageTextIndex {
    static let shared = ImageTextIndex()

    private struct Key: Hashable {
        let path: String
        let modified: Date?
    }

    /// Recognition resolution: plenty for screenshot-sized text while keeping
    /// the decode bounded for huge photos. Boxes are resolution-independent.
    private nonisolated static let maxPixels: CGFloat = 3072
    private static let maxEntries = 256
    private nonisolated static let candidatesPerLine = 3

    private var cache: [Key: [RecognizedLine]] = [:]
    private var inFlight: [Key: Task<[RecognizedLine], Never>] = [:]

    func lines(for url: URL) async -> [RecognizedLine] {
        let key = Key(path: url.path, modified: FileStamp.modificationDate(of: url))
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value }
        let task = Task.detached(priority: .utility) { await Self.recognize(url) }
        inFlight[key] = task
        let lines = await task.value
        inFlight[key] = nil
        if cache.count >= Self.maxEntries {
            cache.removeAll()
        }
        cache[key] = lines
        return lines
    }

    /// Recognizes the same upright (EXIF-applied) image the page displays, so
    /// unit boxes map straight onto it. Reading order: top to bottom, then
    /// left to right.
    private nonisolated static func recognize(_ url: URL) async -> [RecognizedLine] {
        guard let image = ImageFileView.displaySizedCGImage(at: url, maxPixels: maxPixels) else { return [] }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Cheatsheets are full of shortcuts and code; "correcting" those to
        // dictionary words would make literal searches miss.
        request.usesLanguageCorrection = false
        guard let observations = try? await request.perform(on: image) else { return [] }
        return observations
            .compactMap { observation -> RecognizedLine? in
                let candidates = observation.topCandidates(candidatesPerLine)
                guard !candidates.isEmpty else { return nil }
                return RecognizedLine(candidates: candidates, unitBox: unitRect(observation.boundingBox))
            }
            .sorted { ($0.unitBox.minY, $0.unitBox.minX) < ($1.unitBox.minY, $1.unitBox.minX) }
    }

    nonisolated static func unitRect(_ rect: NormalizedRect) -> CGRect {
        rect.toImageCoordinates(CGSize(width: 1, height: 1), origin: .upperLeft)
    }
}
