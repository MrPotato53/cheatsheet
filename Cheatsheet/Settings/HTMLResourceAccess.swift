import AppKit

/// A sandboxed import only reaches the files the user picked. When an HTML
/// page's stylesheets/images sit beside it (e.g. a browser's "<name>_files"
/// folder), ask once per folder for access so they're imported with it.
/// Declining still imports the page, just unstyled.
@MainActor
enum HTMLResourceAccess {
    static func withResourceAccess<T>(for urls: [URL], _ body: () -> T) -> T {
        let granted = foldersNeedingAccess(urls).compactMap(requestAccess)
        let accessing = granted.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessing.forEach { $0.stopAccessingSecurityScopedResource() } }
        return body()
    }

    private struct Request {
        let folder: URL
        let pageName: String
    }

    private static func foldersNeedingAccess(_ urls: [URL]) -> [Request] {
        var requests: [Request] = []
        for url in urls where MediaKind.of(url) == .html {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            let folder = url.deletingLastPathComponent()
            guard
                !HTMLResources.unreadableRoots(besidePageAt: url).isEmpty,
                !requests.contains(where: { $0.folder == folder })
            else { continue }
            requests.append(Request(folder: folder, pageName: url.lastPathComponent))
        }
        return requests
    }

    private static func requestAccess(_ request: Request) -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = request.folder
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow"
        panel.message = "“\(request.pageName)” uses styles or images stored next to it. Allow access to this folder so they're imported too."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
