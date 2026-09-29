import Foundation

/// A web page added to a cheatsheet, stored as a standard `.webloc` file
/// (the plist Safari writes when a link is dragged to Finder). Keeping it a
/// file lets web pages reuse everything files get: page order, export and
/// import, removal.
nonisolated enum WebLocation {
    static let fileExtension = "webloc"

    struct Entry: Equatable {
        var url: URL
        var name: String
    }

    /// Where a clicked link goes: pages of the same site stay in the
    /// overlay, everything else opens in the user's browser.
    enum LinkRoute: Equatable {
        case stayInOverlay
        case openInBrowser
    }

    // MARK: - Typed addresses

    /// Accepts what people type into an address bar: "example.com",
    /// "localhost:3000", "192.168.1.5:8080/docs" or a full http(s) URL.
    /// Local addresses default to http (dev servers rarely have TLS),
    /// everything else to https. Nil for anything that isn't a web page.
    static func normalizedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate: String
        if trimmed.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) != nil {
            candidate = trimmed
        } else {
            let scheme = isLocalHost(hostPart(of: trimmed)) ? "http" : "https"
            candidate = "\(scheme)://\(trimmed)"
        }
        guard
            let url = URL(string: candidate),
            isWebScheme(url),
            let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// A readable default name: the host without "www.".
    static func defaultName(for url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func isWebScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    private static func hostPart(of address: String) -> String {
        let beforePath = address.split(separator: "/", maxSplits: 1).first.map(String.init) ?? address
        return beforePath.split(separator: ":").first.map(String.init)?.lowercased() ?? beforePath
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") {
            return true
        }
        // IPv4 literals: LAN devices and dev servers.
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    // MARK: - Files

    /// A file name for the page, without characters Finder can't show.
    static func fileName(for name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty || cleaned.hasPrefix(".") ? "Web page" : cleaned
        return "\(base).\(fileExtension)"
    }

    static func fileData(for url: URL) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["URL": url.absoluteString],
            format: .xml,
            options: 0
        )
    }

    /// The page's address, or nil when the file is unreadable or doesn't
    /// point at an http(s) page (a `.webloc` can hold any URL).
    static func url(fromFileAt fileURL: URL) -> URL? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let string = (plist as? [String: Any])?["URL"] as? String,
            let url = URL(string: string),
            isWebScheme(url)
        else { return nil }
        return url
    }

    /// Writes each entry to a temporary `.webloc`, hands the files to
    /// `body` (which copies them into the library), then cleans up. Nil
    /// when the files couldn't be written.
    static func withTemporaryFiles<T>(for entries: [Entry], _ body: ([URL]) -> T) -> T? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebPages-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var files: [URL] = []
            for (offset, entry) in entries.enumerated() {
                // A subfolder each, so two pages with the same name don't collide.
                let folder = directory.appendingPathComponent("\(offset)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent(fileName(for: entry.name))
                try fileData(for: entry.url).write(to: file)
                files.append(file)
            }
            return body(files)
        } catch {
            return nil
        }
    }

    // MARK: - Links

    /// Only clicked links are routed; redirects and form posts always stay,
    /// so sign-in flows that bounce between sites keep working.
    static func route(for target: URL, from current: URL?, commandPressed: Bool) -> LinkRoute {
        guard isWebScheme(target), !commandPressed else { return .openInBrowser }
        guard let current, let targetHost = target.host(), let currentHost = current.host() else {
            return .openInBrowser
        }
        return isSameSite(targetHost, currentHost) ? .stayInOverlay : .openInBrowser
    }

    /// Same host ignoring "www.", or one a subdomain of the other
    /// (docs.example.com and example.com).
    static func isSameSite(_ first: String, _ second: String) -> Bool {
        let a = strippingWWW(first.lowercased())
        let b = strippingWWW(second.lowercased())
        return a == b || a.hasSuffix(".\(b)") || b.hasSuffix(".\(a)")
    }

    private static func strippingWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
