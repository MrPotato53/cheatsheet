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
    @State private var isTransferring = false
    @State private var transferAlert: TransferAlert?

    struct TransferAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

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
        .onAppear {
            if selection == nil {
                selection = store.sheets.first?.id
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: Self.importableTypes,
            allowsMultipleSelection: true
        ) { result in
            guard let urls = try? result.get() else { return }
            HTMLResourceAccess.withResourceAccess(for: urls) {
                switch importTarget {
                case .newSheet:
                    if let sheet = store.addSheet(files: urls) {
                        selection = sheet.id
                    }
                case .existingSheet(let sheetID):
                    store.addFiles(urls, to: sheetID)
                }
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
        .alert(item: $transferAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
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
                .accessibilityIdentifier("sheets.add")
                Button {
                    pendingDeletion = selectedSheet
                    isDeleteConfirmationPresented = true
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 20, height: 20)
                }
                .disabled(selectedSheet == nil)
                .accessibilityIdentifier("sheets.remove")
                Spacer()
                if isTransferring {
                    ProgressView()
                        .controlSize(.small)
                }
                transferMenu
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            // Dropped exports are imported, not added as unreadable pages.
            let archives = urls.filter(LibraryTransferPanels.isArchive)
            if !archives.isEmpty {
                importArchives(archives)
                return true
            }
            if let sheet = HTMLResourceAccess.withResourceAccess(for: urls, { store.addSheet(files: urls) }) {
                selection = sheet.id
                return true
            }
            return false
        }
    }

    private var detail: some View {
        Group {
            if let selectedSheet {
                CheatsheetDetailView(
                    sheet: binding(for: selectedSheet),
                    requestAddFiles: {
                        importTarget = .existingSheet(selectedSheet.id)
                        isImporterPresented = true
                    },
                    requestExport: {
                        export([selectedSheet.id], suggestedName: selectedSheet.name)
                    }
                )
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

    // MARK: - Export & import

    /// One quiet menu instead of more bar buttons: import/export are
    /// occasional actions.
    private var transferMenu: some View {
        Menu {
            Button("Import Cheatsheets…") {
                importArchives(LibraryTransferPanels.chooseArchivesToImport())
            }
            .accessibilityIdentifier("sheets.import")
            Button("Export All Cheatsheets…") {
                export(Set(store.sheets.map(\.id)), suggestedName: LibraryTransferPanels.exportAllName())
            }
            .disabled(store.sheets.isEmpty)
            .accessibilityIdentifier("sheets.exportAll")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isTransferring)
        .help("Import or export cheatsheets")
        .accessibilityIdentifier("sheets.transferMenu")
    }

    private func export(_ ids: Set<Cheatsheet.ID>, suggestedName: String) {
        guard !isTransferring,
              let destination = LibraryTransferPanels.chooseExportDestination(suggestedName: suggestedName)
        else { return }
        isTransferring = true
        Task {
            defer { isTransferring = false }
            do {
                try await store.export(sheetIDs: ids, to: destination)
            } catch {
                transferAlert = TransferAlert(title: "Export Failed", message: error.localizedDescription)
            }
        }
    }

    private func importArchives(_ urls: [URL]) {
        guard !isTransferring, !urls.isEmpty else { return }
        isTransferring = true
        Task {
            defer { isTransferring = false }
            var imported: [Cheatsheet.ID] = []
            var messages: [String] = []
            for url in urls {
                do {
                    let summary = try await store.importArchive(at: url)
                    imported += summary.importedIDs
                    messages += summary.notes
                } catch {
                    messages.append("“\(url.lastPathComponent)”: \(error.localizedDescription)")
                }
            }
            if let first = imported.first {
                selection = first
            }
            guard !messages.isEmpty else { return }
            let count = imported.count
            transferAlert = TransferAlert(
                title: count == 0
                    ? "Import Failed"
                    : "Imported \(count) Cheatsheet\(count == 1 ? "" : "s")",
                message: messages.joined(separator: "\n\n")
            )
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
