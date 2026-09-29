import Foundation

/// Renaming one of a sheet's files: the name is its key everywhere (page
/// order, raw view, links), so a rename rewrites them all together. Only
/// the sheet's own copy is renamed; an original never is.
extension Cheatsheet {
    enum RenameProblem: Equatable {
        case empty
        case invalidCharacters
        case differentKind
        case taken

        var message: String {
            switch self {
            case .empty: "Enter a name."
            case .invalidCharacters: "Names can't contain “/” or “:” or start with a period."
            case .differentKind: "Keep the same extension: it decides how the page is shown."
            case .taken: "This cheatsheet already has a file with that name."
            }
        }
    }

    /// Why `file` can't be renamed to `newName`, or nil when it can.
    /// Names differing only in case count as taken (macOS disks usually
    /// ignore case), except for the file itself.
    func renameProblem(for file: String, to newName: String) -> RenameProblem? {
        let base = URL(filePath: newName).deletingPathExtension().lastPathComponent
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty,
              !base.trimmingCharacters(in: .whitespaces).isEmpty else { return .empty }
        guard !newName.contains("/"), !newName.contains(":"), !newName.hasPrefix(".") else {
            return .invalidCharacters
        }
        guard MediaKind.of(URL(filePath: newName)) == MediaKind.of(URL(filePath: file)) else {
            return .differentKind
        }
        let isTaken = files.contains { other in
            other != file && other.compare(newName, options: .caseInsensitive) == .orderedSame
        }
        return isTaken ? .taken : nil
    }

    /// This sheet with `file` known as `newName` (the caller moves the file).
    func renamingFile(_ file: String, to newName: String) -> Cheatsheet {
        var renamed = self
        renamed.files = files.map { $0 == file ? newName : $0 }
        renamed.pageOrder = pageOrder.map { ref in
            guard ref.file == file else { return ref }
            var moved = ref
            moved.file = newName
            return moved
        }
        if rawFiles.contains(file) {
            renamed.rawFiles.remove(file)
            renamed.rawFiles.insert(newName)
        }
        if let link = links[file] {
            renamed.links[file] = nil
            renamed.links[newName] = link
        }
        return renamed
    }
}
