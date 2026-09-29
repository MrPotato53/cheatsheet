import Foundation

extension CheatsheetStore {
    /// Renames a sheet's own copy of a file (never an original) and every
    /// reference to it. Returns why it couldn't, or nil once renamed.
    @discardableResult
    func renameFile(_ file: String, to newName: String, in sheetID: Cheatsheet.ID) -> Cheatsheet.RenameProblem? {
        guard let sheet = sheets.first(where: { $0.id == sheetID }), newName != file else { return nil }
        if let problem = sheet.renameProblem(for: file, to: newName) {
            return problem
        }
        let source = fileURL(for: sheet, file: file)
        let destination = fileURL(for: sheet, file: newName)
        do {
            if file.compare(newName, options: .caseInsensitive) == .orderedSame {
                // Only the case changes: disks that ignore case see the
                // destination as taken, so go by way of a temporary name.
                let interim = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                try FileManager.default.moveItem(at: source, to: interim)
                try FileManager.default.moveItem(at: interim, to: destination)
            } else {
                try FileManager.default.moveItem(at: source, to: destination)
            }
        } catch {
            return .taken
        }
        if let state = syncStates[sheetID]?[file] {
            syncStates[sheetID]?[file] = nil
            syncStates[sheetID]?[newName] = state
        }
        update(sheet.renamingFile(file, to: newName))
        touch()
        return nil
    }

    /// A linked copy takes its original's name, so the two don't drift;
    /// kept as is when that name is taken in the sheet. Returns the name
    /// the file ends up with.
    func adoptOriginalName(_ original: URL, forFile file: String, in sheetID: Cheatsheet.ID) -> String {
        let name = original.lastPathComponent
        guard name != file, renameFile(file, to: name, in: sheetID) == nil else { return file }
        return name
    }
}
