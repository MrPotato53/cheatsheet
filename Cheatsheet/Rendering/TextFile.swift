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

/// A file's last-modified time, for keying caches: an imported copy edited
/// in place keeps its path, so path-only keys would keep serving the old
/// content. Read fresh from the file system each time (URL resource values
/// are cached per URL instance and can go stale).
nonisolated enum FileStamp {
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// "<path>@<mtime>", distinct for every version of the file.
    static func versionedKey(for url: URL) -> String {
        "\(url.path)@\(modificationDate(of: url)?.timeIntervalSinceReferenceDate ?? 0)"
    }
}
