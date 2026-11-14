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
    @Environment(SettingsNavigation.self) private var navigation
    @State private var selection: Cheatsheet.ID?
    /// The sidebar row a drag is over, and whether one is over the selected
    /// sheet's settings: both add to that sheet instead of creating one.
    @State private var dropTargetRow: Cheatsheet.ID?
    @State private var isDetailDropTargeted = false
    @State private var isImporterPresented = false
    @State private var importTarget: ImportTarget = .newSheet
    @State private var presentedForm: PresentedForm?
    /// Files was chosen in New Cheatsheet: the file picker opens once that
    /// pop-up has finished closing (two can't be up at once).
    @State private var opensFilePickerOnDismiss = false

    private enum PresentedForm: Identifiable {
        case newCheatsheet
        case addWebPage(Cheatsheet.ID)

        var id: String {
            switch self {
            case .newCheatsheet: "new"
            case .addWebPage(let sheetID): "web-\(sheetID)"
            }
        }
    }

    static let deletionMessage = "Its copies of your files are deleted with it. Your original files aren't affected."
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
        var types: [UTType] = [.pdf, .image, .plainText, .text, .sourceCode, .internetLocation]
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
            applyNavigationRequests()
            if selection == nil {
                selection = store.sheets.first?.id
            }
        }
        .onChange(of: navigation.sheetRequest) { _, _ in applyNavigationRequests() }
        .onChange(of: navigation.archiveRequest) { _, _ in applyNavigationRequests() }
        .onChange(of: navigation.newSheetFormRequest) { _, _ in applyNavigationRequests() }
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
        .sheet(item: $presentedForm, onDismiss: openFilePickerIfChosen) { form in
            switch form {
            case .newCheatsheet:
                NewCheatsheetForm(
                    onChooseFiles: { opensFilePickerOnDismiss = true },
                    onAddWebPage: { addWebPage($0, to: .newSheet) }
                )
            case .addWebPage(let sheetID):
                AddWebPageForm(title: "Add Web Page") { addWebPage($0, to: .existingSheet(sheetID)) }
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
            Text(Self.deletionMessage)
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
                    sidebarRow(sheet)
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
                        Text("Create one with +, or drop files or links here.")
                    }
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button {
                    presentedForm = .newCheatsheet
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                }
                .accessibilityIdentifier("sheets.add")
                .help("New cheatsheet")
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
    }

    /// Dropping files or links on a sheet adds them to it.
    private func sidebarRow(_ sheet: Cheatsheet) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sheet.name)
            Text(shortcutLabel(for: sheet))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            add(urls, to: sheet.id)
        } isTargeted: { targeted in
            if targeted {
                dropTargetRow = sheet.id
            } else if dropTargetRow == sheet.id {
                dropTargetRow = nil
            }
        }
        .background {
            if dropTargetRow == sheet.id {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .padding(-4)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: dropTargetRow)
        .accessibilityIdentifier("sheets.row.\(sheet.name)")
    }

    /// Adds dropped files and links to an existing sheet and selects it.
    private func add(_ urls: [URL], to sheetID: Cheatsheet.ID) -> Bool {
        let dropped = DroppedItems(urls)
        guard !dropped.files.isEmpty || !dropped.webPages.isEmpty else { return false }
        let added = HTMLResourceAccess.withResourceAccess(for: dropped.files) {
            store.add(dropped, to: sheetID)
        }
        if added {
            selection = sheetID
        }
        return added
    }

    /// A sheet to select or exports to import, requested from outside this
    /// view (an overlay, Finder, a drop on the General tab).
    private func applyNavigationRequests() {
        if let sheetID = navigation.consumeSheetRequest(), store.sheets.contains(where: { $0.id == sheetID }) {
            selection = sheetID
        }
        importArchives(navigation.consumeArchiveRequest())
        // Not over another pop-up or the file picker: one at a time.
        if navigation.consumeNewSheetFormRequest(), presentedForm == nil, !isImporterPresented {
            presentedForm = .newCheatsheet
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
                    requestAddWebPage: {
                        presentedForm = .addWebPage(selectedSheet.id)
                    },
                    requestExport: {
                        export([selectedSheet.id], suggestedName: selectedSheet.name)
                    }
                )
                .id(selectedSheet.id)
                .dropDestination(for: URL.self) { urls, _ in
                    add(urls, to: selectedSheet.id)
                } isTargeted: { isDetailDropTargeted = $0 }
                .dropHighlight(isDetailDropTargeted, label: "Add to “\(selectedSheet.name)”", systemImage: "doc.badge.plus")
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("No cheatsheet selected")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Button {
                        presentedForm = .newCheatsheet
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

    // MARK: - Web pages

    private func openFilePickerIfChosen() {
        guard opensFilePickerOnDismiss else { return }
        opensFilePickerOnDismiss = false
        importTarget = .newSheet
        isImporterPresented = true
    }

    private func addWebPage(_ entry: WebLocation.Entry, to target: ImportTarget) {
        switch target {
        case .newSheet:
            if let sheet = store.addSheet(webPages: [entry]) {
                selection = sheet.id
            }
        case .existingSheet(let sheetID):
            store.addWebPages([entry], to: sheetID)
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
