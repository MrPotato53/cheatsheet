import SwiftUI

/// A file's name in the Files list, renamed in place as in Finder:
/// double-click (or Rename… in its menu), type, Return. Only the part
/// before the extension is edited; the extension decides how the page is
/// shown. Escape cancels; clicking away commits.
struct RenamableFileName: View {
    let file: String
    /// Renames; returns why it couldn't, or nil once done.
    let onRename: (String) -> Cheatsheet.RenameProblem?
    @State private var isEditing = false
    @State private var text = ""
    @State private var problem: Cheatsheet.RenameProblem?
    @FocusState private var isFocused: Bool

    private var fileURL: URL { URL(filePath: file) }
    private var baseName: String { fileURL.deletingPathExtension().lastPathComponent }
    private var fileExtension: String { fileURL.pathExtension }

    var body: some View {
        Group {
            if isEditing {
                HStack(spacing: 2) {
                    Image(systemName: MediaKind.of(fileURL).systemImage)
                        .foregroundStyle(.secondary)
                    TextField("Name", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .focused($isFocused)
                        .onSubmit(commit)
                        .onExitCommand { isEditing = false }
                        .accessibilityIdentifier("detail.renameField")
                    if !fileExtension.isEmpty {
                        Text(".\(fileExtension)")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused, isEditing { commit() }
                }
            } else {
                Label(file, systemImage: MediaKind.of(fileURL).systemImage)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: beginEditing)
                    .contextMenu {
                        Button("Rename…", action: beginEditing)
                    }
                    .help("Double-click to rename")
            }
        }
        .alert("Couldn't Rename “\(file)”", isPresented: Binding(
            get: { problem != nil },
            set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem?.message ?? "")
        }
    }

    private func beginEditing() {
        text = baseName
        isEditing = true
        isFocused = true
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let newName = fileExtension.isEmpty ? trimmed : "\(trimmed).\(fileExtension)"
        guard newName != file else { return }
        problem = onRename(newName)
    }
}
