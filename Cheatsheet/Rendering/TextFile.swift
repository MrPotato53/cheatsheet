import Foundation

nonisolated enum TextFile {
    /// Tolerant read: a strict UTF-8 decode silently blanks the page for
    /// files saved in other encodings; fall back to Foundation's encoding
    /// detection, then to lossy UTF-8 rather than showing nothing.
    /// Nil only when the file can't be read at all.
    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        var converted: NSString?
        if NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil) != 0,
           let converted {
            return converted as String
        }
        return String(decoding: data, as: UTF8.self)
    }
}
