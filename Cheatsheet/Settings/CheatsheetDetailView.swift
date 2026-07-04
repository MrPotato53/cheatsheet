import AppKit
import KeyboardShortcuts
import SwiftUI

struct CheatsheetDetailView: View {
    @Binding var sheet: Cheatsheet
    let requestAddFiles: () -> Void
    @Environment(CheatsheetStore.self) private var store
    @Environment(OverlayController.self) private var overlay
    @State private var previousShortcut: KeyboardShortcuts.Shortcut?
    @State private var conflictMessage: String?
    @State private var isDisplayPopoverPresented = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $sheet.name)
                    .labelsHidden()
            }

            // Page reordering lives solely in the preview gallery below;
            // this section manages source documents.
            Section("Documents") {
                if sheet.files.isEmpty {
                    Text("No files").foregroundStyle(.secondary)
                }
                // AppKit-backed scrolling: a SwiftUI List nested in a Form
                // never receives wheel/scroll-bar events on macOS.
                EmbeddedVerticalScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sheet.files, id: \.self) { file in
                            documentRow(file)
                            if file != sheet.files.last {
                                Divider()
                            }
                        }
                    }
                }
                // Fixed height sized to the row count: collapses to a single
                // row and scrolls internally once the cap is hit.
                .frame(height: min(max(CGFloat(sheet.files.count), 1) * 30, 150))
                Button("Add Files…", action: requestAddFiles)
            }

            Section("Preview") {
                SheetInlinePreview(sheet: sheet)
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
            }

            Section("Behavior") {
                Picker("Activation Mode", selection: $sheet.activation) {
                    ForEach(ActivationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("Open Cheatsheet to", selection: startPageChoice) {
                    Text("First page").tag(StartPageChoice.first)
                    Text("Last viewed page").tag(StartPageChoice.lastViewed)
                    Text("Specific page").tag(StartPageChoice.fixed)
                }
                if case .fixed = sheet.startPage {
                    let pages = store.pages(for: sheet)
                    Picker("Page", selection: fixedPageIndex) {
                        ForEach(0..<max(pages.count, 1), id: \.self) { index in
                            if pages.indices.contains(index) {
                                Text("Page \(index + 1) — \(pages[index].caption)").tag(index)
                            } else {
                                Text("Page \(index + 1)").tag(index)
                            }
                        }
                    }
                }
                displayPicker
            }

            Section("Size & Position") {
                LabeledContent("Size") {
                    HStack(spacing: 10) {
                        Slider(value: $sheet.previewScale, in: 0.25...1.0, step: 0.05) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("25%")
                        } maximumValueLabel: {
                            Text("100%")
                        }
                        .frame(maxWidth: 260)
                        Text(sheet.previewScale.formatted(.percent.precision(.fractionLength(0))))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Position")
                    VStack(spacing: 10) {
                        PositionPreviewView(sheet: $sheet)
                        Button("Center") {
                            sheet.position = .center
                        }
                        .disabled(sheet.position == .center)
                    }
                    .frame(maxWidth: .infinity)
                }
                geometryBehaviorPicker("Cheatsheet Dragging", selection: $sheet.dragBehavior)
                geometryBehaviorPicker("Cheatsheet Resizing", selection: $sheet.resizeBehavior)
                Button("Preview on Screen") {
                    overlay.show(sheet)
                }
            }

            Section {
                Button("Delete Cheatsheet…", role: .destructive) {
                    isDeleteConfirmationPresented = true
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete “\(sheet.name)”?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.delete(sheet)
            }
        } message: {
            Text("“\(sheet.name)” and its imported files will be removed.")
        }
        .onAppear {
            previousShortcut = KeyboardShortcuts.getShortcut(for: sheet.shortcutName)
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

    private func documentRow(_ file: String) -> some View {
        let exists = store.fileExists(for: sheet, file: file)
        return HStack {
            Label(file, systemImage: MediaKind.of(URL(filePath: file)).systemImage)
            if !exists {
                Label("Missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .labelStyle(.titleAndIcon)
                    .help("The app's copy of this file was deleted. Remove the entry or re-add the file.")
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [store.fileURL(for: sheet, file: file)]
                )
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(!exists)
            .help("Reveal the app's copy in Finder")
            Button {
                store.removeFile(file, from: sheet.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .frame(height: 29)
    }

    private func geometryBehaviorPicker(_ title: String, selection: Binding<GeometryBehavior>) -> some View {
        LabeledContent(title) {
            BehaviorPopUpButton(selection: selection)
        }
    }

    // MARK: - Start page

    private enum StartPageChoice: Hashable {
        case first
        case lastViewed
        case fixed
    }

    private var startPageChoice: Binding<StartPageChoice> {
        Binding(
            get: {
                switch sheet.startPage {
                case .first: .first
                case .lastViewed: .lastViewed
                case .fixed: .fixed
                }
            },
            set: { choice in
                switch choice {
                case .first: sheet.startPage = .first
                case .lastViewed: sheet.startPage = .lastViewed
                case .fixed: sheet.startPage = .fixed(index: currentFixedIndex)
                }
            }
        )
    }

    private var currentFixedIndex: Int {
        if case .fixed(let index) = sheet.startPage {
            return index
        }
        return 0
    }

    private var fixedPageIndex: Binding<Int> {
        Binding(
            get: { currentFixedIndex },
            set: { sheet.startPage = .fixed(index: $0) }
        )
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

    // Custom popover instead of Picker: NSMenu-backed picker items can't
    // report hover, and hovering a display option highlights that screen.
    private var displayPicker: some View {
        LabeledContent("Show on Display") {
            Button {
                isDisplayPopoverPresented = true
            } label: {
                HStack(spacing: 5) {
                    Text(currentDisplayLabel)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .popover(isPresented: $isDisplayPopoverPresented, arrowEdge: .bottom) {
                displayOptions
                    .padding(8)
                    .frame(width: 280)
            }
        }
    }

    private var currentDisplayLabel: String {
        switch sheet.target {
        case .cursorScreen:
            return "Screen with mouse cursor"
        case .focusedScreen:
            return "Screen with focused window"
        case .specific(let uuid, let name):
            let connected = NSScreen.screens.contains { $0.displayUUID == uuid }
            return connected ? name : "\(name) (disconnected)"
        }
    }

    private var displayOptions: some View {
        let screens = NSScreen.screens.filter { $0.displayUUID != nil }
        let disconnected: (uuid: String, name: String)? = {
            if case .specific(let uuid, let name) = sheet.target,
               !screens.contains(where: { $0.displayUUID == uuid }) {
                return (uuid, name)
            }
            return nil
        }()
        return VStack(alignment: .leading, spacing: 2) {
            displayOptionRow("Screen with mouse cursor", choice: .cursor, highlightUUID: nil)
            displayOptionRow("Screen with focused window", choice: .focused, highlightUUID: nil)
            Divider()
            ForEach(screens, id: \.displayUUID) { screen in
                displayOptionRow(
                    screen.localizedName,
                    choice: .specific(screen.displayUUID!),
                    highlightUUID: screen.displayUUID
                )
            }
            if let disconnected {
                displayOptionRow(
                    "\(disconnected.name) (disconnected — uses cursor screen)",
                    choice: .specific(disconnected.uuid),
                    highlightUUID: nil
                )
            }
        }
        .onDisappear {
            ScreenHighlighter.shared.hide()
        }
    }

    private func displayOptionRow(_ label: String, choice: DisplayChoice, highlightUUID: String?) -> some View {
        DisplayOptionRow(
            label: label,
            isSelected: displayChoice.wrappedValue == choice
        ) { hovering in
            if hovering, let highlightUUID {
                ScreenHighlighter.shared.highlight(displayUUID: highlightUUID)
            } else {
                ScreenHighlighter.shared.hide()
            }
        } action: {
            displayChoice.wrappedValue = choice
            ScreenHighlighter.shared.hide()
            isDisplayPopoverPresented = false
        }
    }
}

/// AppKit pop-up with a hard width constraint: SwiftUI's menu picker sizes
/// itself to the *selected* option's text, so two pickers drift to different
/// widths as soon as different values are chosen. NSPopUpButton stretches to
/// any constrained width.
private struct BehaviorPopUpButton: NSViewRepresentable {
    @Binding var selection: GeometryBehavior

    private static let options: [(behavior: GeometryBehavior, title: String)] = [
        (.locked, "Don't allow"),
        (.resets, "Allow — return to configured"),
        (.remembers, "Allow — remember last"),
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: Self.options.map(\.title))
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        let index = Self.options.firstIndex { $0.behavior == selection } ?? 0
        if button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<GeometryBehavior>

        init(selection: Binding<GeometryBehavior>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            guard BehaviorPopUpButton.options.indices.contains(sender.indexOfSelectedItem) else { return }
            selection.wrappedValue = BehaviorPopUpButton.options[sender.indexOfSelectedItem].behavior
        }
    }
}

/// NSScrollView-backed vertical scroller for embedding inside a Form: nested
/// SwiftUI scroll containers don't receive wheel events on macOS, but AppKit
/// routes the wheel to the deepest scrollable view under the cursor.
private struct EmbeddedVerticalScrollView<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .legacy
        scrollView.horizontalScrollElasticity = .none
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView.documentView as? NSHostingView<AnyView>)?.rootView = AnyView(content)
    }
}

private struct DisplayOptionRow: View {
    let label: String
    let isSelected: Bool
    let onHoverChanged: (Bool) -> Void
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .opacity(isSelected ? 1 : 0)
                Text(label)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The popover gives the first row keyboard focus, which drew a focus
        // ring (blue border) and altered its metrics — keep rows uniform.
        .focusEffectDisabled()
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isHovering ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .onHover { hovering in
            isHovering = hovering
            onHoverChanged(hovering)
        }
    }
}
