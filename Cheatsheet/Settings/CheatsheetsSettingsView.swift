import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

struct CheatsheetsSettingsView: View {
    /// Both the sidebar's + and the detail's "Add Files…" share one fileImporter:
    /// SwiftUI only presents one fileImporter per hierarchy, so a second modifier
    /// on the detail view would silently stop the picker from opening.
    enum ImportTarget {
        case newSheet
        case existingSheet(Cheatsheet.ID)
    }

    @Environment(CheatsheetStore.self) private var store
    @State private var selection: Cheatsheet.ID?
    @State private var isImporterPresented = false
    @State private var importTarget: ImportTarget = .newSheet
    @State private var isDeleteConfirmationPresented = false
    @State private var pendingDeletion: Cheatsheet?

    static let importableTypes: [UTType] = {
        var types: [UTType] = [.pdf, .image, .plainText, .text, .sourceCode]
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        return types
    }()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: Self.importableTypes,
            allowsMultipleSelection: true
        ) { result in
            guard let urls = try? result.get() else { return }
            switch importTarget {
            case .newSheet:
                if let sheet = store.addSheet(files: urls) {
                    selection = sheet.id
                }
            case .existingSheet(let sheetID):
                store.addFiles(urls, to: sheetID)
            }
        }
        .confirmationDialog(
            "Delete cheatsheet?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { sheet in
            Button("Delete “\(sheet.name)”", role: .destructive) {
                if selection == sheet.id {
                    selection = nil
                }
                store.delete(sheet)
            }
        } message: { sheet in
            Text("“\(sheet.name)” and its imported files will be removed.")
        }
    }

    private var selectedSheet: Cheatsheet? {
        store.sheets.first { $0.id == selection }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.sheets) { sheet in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sheet.name)
                        Text(shortcutLabel(for: sheet))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(sheet.id)
                }
                .onMove { offsets, destination in
                    store.moveSheets(fromOffsets: offsets, toOffset: destination)
                }
            }
            .overlay {
                if store.sheets.isEmpty {
                    ContentUnavailableView {
                        Label("No cheatsheets", systemImage: "rectangle.stack")
                    } description: {
                        Text("Add one with + or drop files here.")
                    }
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button {
                    importTarget = .newSheet
                    isImporterPresented = true
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                }
                Button {
                    pendingDeletion = selectedSheet
                    isDeleteConfirmationPresented = true
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 20, height: 20)
                }
                .disabled(selectedSheet == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            if let sheet = store.addSheet(files: urls) {
                selection = sheet.id
                return true
            }
            return false
        }
    }

    private var detail: some View {
        Group {
            if let selectedSheet {
                CheatsheetDetailView(sheet: binding(for: selectedSheet)) {
                    importTarget = .existingSheet(selectedSheet.id)
                    isImporterPresented = true
                }
                .id(selectedSheet.id)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("No cheatsheet selected")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Button {
                        importTarget = .newSheet
                        isImporterPresented = true
                    } label: {
                        Label("Create Cheatsheet", systemImage: "plus")
                            .font(.title3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }

    private func binding(for sheet: Cheatsheet) -> Binding<Cheatsheet> {
        Binding(
            get: { store.sheets.first { $0.id == sheet.id } ?? sheet },
            set: { store.update($0) }
        )
    }

    private func shortcutLabel(for sheet: Cheatsheet) -> String {
        _ = store.revision
        if let shortcut = KeyboardShortcuts.getShortcut(for: sheet.shortcutName) {
            return String(describing: shortcut)
        }
        return "No shortcut"
    }
}
