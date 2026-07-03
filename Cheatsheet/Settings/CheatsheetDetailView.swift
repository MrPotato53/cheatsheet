import AppKit
import KeyboardShortcuts
import SwiftUI

struct CheatsheetDetailView: View {
    @Binding var sheet: Cheatsheet
    @Environment(CheatsheetStore.self) private var store
    @Environment(OverlayController.self) private var overlay
    @State private var previousShortcut: KeyboardShortcuts.Shortcut?
    @State private var conflictMessage: String?
    @State private var isFileImporterPresented = false

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $sheet.name)
                    .labelsHidden()
            }

            Section("Pages") {
                if sheet.files.isEmpty {
                    Text("No files").foregroundStyle(.secondary)
                }
                List {
                    ForEach(sheet.files, id: \.self) { file in
                        HStack {
                            Label(file, systemImage: MediaKind.of(URL(filePath: file)).systemImage)
                            Spacer()
                            Button {
                                store.removeFile(file, from: sheet.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .onMove { offsets, destination in
                        sheet.files.move(fromOffsets: offsets, toOffset: destination)
                    }
                }
                .frame(minHeight: 60, maxHeight: 160)
                Button("Add Files…") {
                    isFileImporterPresented = true
                }
            }

            Section("Shortcut") {
                LabeledContent("Keyboard shortcut") {
                    KeyboardShortcuts.Recorder("", name: sheet.shortcutName, onChange: handleShortcutChange)
                }
                if let conflictMessage {
                    Text(conflictMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Picker("Activation", selection: $sheet.activation) {
                    ForEach(ActivationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Appearance") {
                LabeledContent("Size") {
                    Slider(value: $sheet.previewScale, in: 0.25...1.0, step: 0.05) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("25%")
                    } maximumValueLabel: {
                        Text("100%")
                    }
                    .frame(maxWidth: 280)
                }
                displayPicker
                Button("Preview on Screen") {
                    overlay.show(sheet)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            previousShortcut = KeyboardShortcuts.getShortcut(for: sheet.shortcutName)
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: CheatsheetsSettingsView.importableTypes,
            allowsMultipleSelection: true
        ) { result in
            guard let urls = try? result.get() else { return }
            store.addFiles(urls, to: sheet.id)
        }
    }

    // MARK: - Shortcut conflicts

    private func handleShortcutChange(_ shortcut: KeyboardShortcuts.Shortcut?) {
        defer { store.touch() }
        guard let shortcut else {
            previousShortcut = nil
            conflictMessage = nil
            return
        }
        if let other = store.conflictingSheet(with: shortcut, excluding: sheet.id) {
            KeyboardShortcuts.setShortcut(previousShortcut, for: sheet.shortcutName)
            conflictMessage = "\(shortcut) is already used by “\(other.name)”. Kept the previous shortcut."
        } else {
            previousShortcut = shortcut
            conflictMessage = nil
        }
    }

    // MARK: - Display picker

    private enum DisplayChoice: Hashable {
        case cursor
        case focused
        case specific(String)
    }

    private var displayChoice: Binding<DisplayChoice> {
        Binding(
            get: {
                switch sheet.target {
                case .cursorScreen: .cursor
                case .focusedScreen: .focused
                case .specific(let uuid, _): .specific(uuid)
                }
            },
            set: { choice in
                switch choice {
                case .cursor:
                    sheet.target = .cursorScreen
                case .focused:
                    sheet.target = .focusedScreen
                case .specific(let uuid):
                    let name = NSScreen.screens.first { $0.displayUUID == uuid }?.localizedName
                        ?? savedDisplayName(for: uuid)
                        ?? "Display"
                    sheet.target = .specific(uuid: uuid, name: name)
                }
            }
        )
    }

    private func savedDisplayName(for uuid: String) -> String? {
        if case .specific(let savedUUID, let name) = sheet.target, savedUUID == uuid {
            return name
        }
        return nil
    }

    private var displayPicker: some View {
        let screens = NSScreen.screens.filter { $0.displayUUID != nil }
        let disconnected: (uuid: String, name: String)? = {
            if case .specific(let uuid, let name) = sheet.target,
               !screens.contains(where: { $0.displayUUID == uuid }) {
                return (uuid, name)
            }
            return nil
        }()
        return Picker("Show on", selection: displayChoice) {
            Text("Screen with mouse cursor").tag(DisplayChoice.cursor)
            Text("Screen with focused window").tag(DisplayChoice.focused)
            ForEach(screens, id: \.displayUUID) { screen in
                Text(screen.localizedName).tag(DisplayChoice.specific(screen.displayUUID!))
            }
            if let disconnected {
                Text("\(disconnected.name) (disconnected — uses cursor screen)")
                    .tag(DisplayChoice.specific(disconnected.uuid))
            }
        }
    }
}
