import AppKit
import UniformTypeIdentifiers

/// Save/open panels for exporting and importing cheatsheets.
@MainActor
enum LibraryTransferPanels {
    static let archiveType = UTType(filenameExtension: LibraryArchive.fileExtension, conformingTo: .data) ?? .data

    static func chooseExportDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [archiveType]
        panel.nameFieldStringValue = "\(fileSafe(suggestedName)).\(LibraryArchive.fileExtension)"
        panel.canCreateDirectories = true
        panel.message = "The export includes the cheatsheet files and all their settings."
        panel.prompt = "Export"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseArchivesToImport() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [archiveType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func exportAllName(now: Date = Date()) -> String {
        "Cheatsheets \(now.formatted(.iso8601.year().month().day()))"
    }

    /// "/" and ":" are path separators to Finder and the file system.
    private static func fileSafe(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Cheatsheet" : cleaned
    }
}

/// What was dropped on the cheatsheet list, sorted by how it's added:
/// exports are imported, files become pages, links become web pages.
/// Anything else (other URL schemes) is ignored.
nonisolated struct DroppedItems: Equatable {
    let archives: [URL]
    let files: [URL]
    let webPages: [WebLocation.Entry]

    init(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        let isArchive = { (url: URL) in url.pathExtension.lowercased() == LibraryArchive.fileExtension }
        archives = fileURLs.filter(isArchive)
        files = fileURLs.filter { !isArchive($0) }
        webPages = urls.filter(WebLocation.isWebScheme).map { url in
            WebLocation.Entry(url: url, name: WebLocation.defaultName(for: url))
        }
    }

    var isEmpty: Bool {
        archives.isEmpty && files.isEmpty && webPages.isEmpty
    }
}
