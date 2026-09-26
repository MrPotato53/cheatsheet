import Foundation

/// Local files an HTML page pulls in by relative path — stylesheets, images,
/// scripts, typically the "<name>_files" folder a browser writes when saving
/// a complete web page. Importing only the .html would drop its styling, so
/// these are copied alongside it (the page keeps its original relative URLs).
nonisolated enum HTMLResources {
    private static let attributePattern = try! NSRegularExpression(
        pattern: #"\b(?:href|src)\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
        options: [.caseInsensitive]
    )
    private static let schemePattern = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#)

    /// First path component of each relative href/src, in document order.
    /// Only these top-level entries are copied, which carries along anything
    /// the referenced stylesheets load in turn (fonts, background images).
    static func referencedRoots(inHTML html: String) -> [String] {
        let range = NSRange(html.startIndex..., in: html)
        var roots: [String] = []
        for match in attributePattern.matches(in: html, range: range) {
            let captured = [1, 2].lazy
                .map { match.range(at: $0) }
                .first { $0.location != NSNotFound }
            guard let captured, let valueRange = Range(captured, in: html) else { continue }
            guard let root = localRoot(of: String(html[valueRange])), !roots.contains(root) else { continue }
            roots.append(root)
        }
        return roots
    }

    static func referencedRoots(ofFileAt url: URL) -> [String] {
        TextFile.read(url).map(referencedRoots(inHTML:)) ?? []
    }

    /// Roots next to the source page that this process can't read — in the
    /// sandbox, siblings of a user-picked file stay off limits until the user
    /// grants access to the folder.
    static func unreadableRoots(besidePageAt url: URL) -> [String] {
        let folder = url.deletingLastPathComponent()
        return referencedRoots(ofFileAt: url).filter {
            !FileManager.default.isReadableFile(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Copies the page's resources from beside the source into the sheet's
    /// media folder. Existing entries are kept (another page may own them).
    static func copyResources(ofPageAt source: URL, into directory: URL) {
        let folder = source.deletingLastPathComponent()
        for root in referencedRoots(ofFileAt: source) {
            let destination = directory.appendingPathComponent(root)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try? FileManager.default.copyItem(at: folder.appendingPathComponent(root), to: destination)
        }
    }

    private static func localRoot(of rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("#"), !value.hasPrefix("/") else { return nil }
        let valueRange = NSRange(value.startIndex..., in: value)
        guard schemePattern.firstMatch(in: value, range: valueRange) == nil else { return nil }
        if let cut = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            value = String(value[..<cut])
        }
        value = value.removingPercentEncoding ?? value
        let root = value.split(separator: "/").first { $0 != "." }.map(String.init)
        guard let root, root != ".." else { return nil }
        return root
    }
}
