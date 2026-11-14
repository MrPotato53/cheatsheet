import Foundation

/// What a top-level item in a sheet's folder is: one of its pages, a file a
/// page depends on, an item never looked at, or something new — dropped in
/// from Finder, which the folder scan imports.
nonisolated enum SheetFolder {
    /// Finder metadata, hidden files, and the temporary files editors and
    /// atomic saves leave behind while writing.
    static func isIgnored(_ name: String, isDirectory: Bool) -> Bool {
        if isDirectory { return true }
        if name.hasPrefix(".") || name.hasPrefix("~$") || name.hasSuffix("~") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["tmp", "swp", "swx", "crdownload", "download", "part"].contains(ext) || name.contains(".sb-")
    }

    /// Items in the folder that are neither pages, recorded dependencies,
    /// nor ignored, in name order.
    static func newItems(
        entries: [(name: String, isDirectory: Bool)],
        pages: Set<String>,
        dependencies: Set<String>
    ) -> [String] {
        entries
            .filter { !pages.contains($0.name) && !dependencies.contains($0.name) }
            .filter { !isIgnored($0.name, isDirectory: $0.isDirectory) }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

extension CheatsheetStore {
    /// The top-level items an HTML page references that exist beside it.
    nonisolated static func presentDependencies(ofPageAt page: URL, in directory: URL) -> [String] {
        HTMLResources.referencedRoots(ofFileAt: page).filter {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Imports files dropped straight into the sheet's folder. A file an HTML
    /// page references is recorded as that page's dependency (it already
    /// styles the page); anything else becomes a page, kept even when its
    /// type can't be shown so the Files list can say so. Returns the names
    /// added as pages.
    @discardableResult
    func discoverNewFiles(in sheetID: Cheatsheet.ID) -> [String] {
        guard let sheet = sheets.first(where: { $0.id == sheetID }) else { return [] }
        var updated = sheet
        let directory = mediaRoot.appendingPathComponent(sheet.id.uuidString, isDirectory: true)
        let new = SheetFolder.newItems(
            entries: Self.folderEntries(of: directory),
            pages: Set(sheet.files),
            dependencies: Set(sheet.dependencies.values.joined())
        )
        guard !new.isEmpty else { return [] }
        var added: [String] = []
        for name in new {
            let referencing = sheet.files.filter { file in
                MediaKind.of(fileURL(for: sheet, file: file)) == .html
                    && HTMLResources.referencedRoots(ofFileAt: fileURL(for: sheet, file: file)).contains(name)
            }
            if referencing.isEmpty {
                added.append(name)
            } else {
                for page in referencing {
                    updated.dependencies[page, default: []].append(name)
                }
            }
        }
        // Unlinked: there's no original to follow.
        updated.files.append(contentsOf: added)
        for name in added where MediaKind.of(fileURL(for: sheet, file: name)) == .html {
            updated.dependencies[name] = Self.presentDependencies(ofPageAt: fileURL(for: sheet, file: name), in: directory)
        }
        if !updated.pageOrder.isEmpty {
            updated.pageOrder += Self.expandRefs(files: added, for: updated, mediaRoot: mediaRoot)
        }
        update(updated)
        return added
    }

    /// Libraries from before dependencies were recorded: derive them once
    /// from each HTML page, as cleanup used to on every removal. Saves only
    /// sheets that gained an entry.
    func recordMissingDependencies() {
        for sheet in sheets {
            var updated = sheet
            let directory = mediaRoot.appendingPathComponent(sheet.id.uuidString, isDirectory: true)
            for file in sheet.files where sheet.dependencies[file] == nil {
                let url = fileURL(for: sheet, file: file)
                guard MediaKind.of(url) == .html, FileManager.default.fileExists(atPath: url.path) else { continue }
                updated.dependencies[file] = Self.presentDependencies(ofPageAt: url, in: directory)
            }
            update(updated)
        }
    }

    private static func folderEntries(of directory: URL) -> [(name: String, isDirectory: Bool)] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []
        return contents.map { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return (url.lastPathComponent, isDirectory == true)
        }
    }
}
