import AppKit
import KeyboardShortcuts
import SwiftUI

struct CheatsheetDetailView: View {
    @Binding var sheet: Cheatsheet
    let requestAddFiles: () -> Void
    let requestAddWebPage: () -> Void
    let requestExport: () -> Void
    @Environment(CheatsheetStore.self) private var store
    @Environment(OverlayController.self) private var overlay
    @State private var previousShortcut: KeyboardShortcuts.Shortcut?
    @State private var conflictMessage: String?
    @State private var systemConflictWarning: String?
    @State private var isDeleteConfirmationPresented = false
    @State private var reviewingFile: ReviewTarget?
    @State private var linkProblem: String?
    @State private var pagesRefreshToken = 0
    /// Search-only mode grays out the shortcut and activation mode (the
    /// shortcut is kept, just not registered).
    @AppStorage(SheetOpenMethod.defaultsKey, store: AppDefaults.store) private var openMethod = SheetOpenMethod.shortcuts

    private struct ReviewTarget: Identifiable {
        let file: String
        var id: String { file }
    }

    var body: some View {
        Form {
            // What it is and how it opens, as the sidebar lists it.
            Section {
                TextField("Name", text: $sheet.name)
                    .accessibilityIdentifier("detail.name")
                shortcutRows
            }

            // Page reordering lives solely in the Pages gallery below; this
            // section manages what the pages come from.
            Section("Files and Web Pages") {
                if sheet.files.isEmpty {
                    Text("No files or web pages").foregroundStyle(.secondary)
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
                HStack {
                    Button("Add Files…", action: requestAddFiles)
                    Button("Add Web Page…", action: requestAddWebPage)
                        .accessibilityIdentifier("detail.addWebPage")
                }
            }

            Section {
                SheetInlinePreview(sheet: sheet, refreshToken: pagesRefreshToken)
            } header: {
                HStack {
                    Text("Pages")
                    Spacer()
                    Button {
                        Task {
                            // Pull edited originals into their copies first.
                            await store.checkLinks(for: sheet.id)
                            pagesRefreshToken += 1
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reload pages from their files")
                    .accessibilityIdentifier("detail.refreshPages")
                }
            }

            Section("When Opened") {
                Picker("Start on", selection: startPageChoice) {
                    Text("First page").tag(StartPageChoice.first)
                    Text("Last viewed page").tag(StartPageChoice.lastViewed)
                    Text("Specific page").tag(StartPageChoice.fixed)
                }
                .accessibilityIdentifier("detail.startPage")
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
                    .accessibilityIdentifier("detail.fixedPage")
                }
                displayPicker
                Toggle("Preload start page", isOn: $sheet.keepsStartPageLoaded)
                    .accessibilityIdentifier("detail.keepStartPageLoaded")
                    .help("Uses about as much memory as that page's content")
                Text("Keeps the start page in memory so it opens instantly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Size and Position") {
                LabeledContent("Size") {
                    HStack(spacing: 10) {
                        Slider(value: $sheet.previewScale, in: Cheatsheet.previewScaleRange, step: 0.05) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("25%")
                        } maximumValueLabel: {
                            Text("100%")
                        }
                        .frame(maxWidth: 260)
                        .accessibilityIdentifier("detail.sizeSlider")
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
                        HStack(spacing: 12) {
                            Button("Center") {
                                sheet.position = .center
                            }
                            .disabled(sheet.position == .center)
                            .accessibilityIdentifier("detail.center")
                            // Opens it as it will appear: where and how big.
                            Button("Preview on Screen") {
                                overlay.show(sheet)
                            }
                            .help("Open the cheatsheet to check its size and position")
                            .accessibilityIdentifier("detail.previewOnScreen")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                geometryBehaviorPicker(
                    "Drag to move",
                    remembered: "position",
                    selection: $sheet.dragBehavior,
                    identifier: "detail.dragBehavior"
                )
                geometryBehaviorPicker(
                    "Drag to resize",
                    remembered: "size",
                    selection: $sheet.resizeBehavior,
                    identifier: "detail.resizeBehavior"
                )
            }

            Section {
                HStack(spacing: 20) {
                    Button("Export Cheatsheet…", action: requestExport)
                        .help("Save this cheatsheet's files and settings to a file you can import on any Mac")
                        .accessibilityIdentifier("detail.export")
                    Button("Delete Cheatsheet…", role: .destructive) {
                        isDeleteConfirmationPresented = true
                    }
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("detail.delete")
                }
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
            Text(CheatsheetsSettingsView.deletionMessage)
        }
        .sheet(item: $reviewingFile) { target in
            SyncReviewSheet(file: target.file, sheetID: sheet.id) {
                reviewingFile = nil
            }
        }
        .alert("Couldn't Link Original", isPresented: Binding(
            get: { linkProblem != nil },
            set: { if !$0 { linkProblem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(linkProblem ?? "")
        }
        .task(id: sheet.id) {
            await store.checkLinks(for: sheet.id)
        }
        .onAppear {
            previousShortcut = KeyboardShortcuts.getShortcut(for: sheet.shortcutName)
            systemConflictWarning = SystemShortcuts.conflictWarning(for: previousShortcut)
        }
    }

    private func handleLinkResult(_ result: CheatsheetStore.LinkResult, file: String) {
        switch result {
        case .linked:
            break
        case .needsReview(let name):
            reviewingFile = ReviewTarget(file: name)
        case .differentKind(let expected, let chosen):
            linkProblem = "“\(file)” is \(expected.descriptionWithArticle), but the file you chose is \(chosen.descriptionWithArticle). Choose the same kind of file."
        case .failed:
            linkProblem = "The file you chose couldn't be opened."
        }
    }

    private func reveal(_ url: URL) {
        OriginalFiles.withAccess(to: url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Shortcut

    @ViewBuilder
    private var shortcutRows: some View {
        LabeledContent("Shortcut") {
            KeyboardShortcuts.Recorder("", name: sheet.shortcutName, onChange: handleShortcutChange)
        }
        .disabled(!openMethod.usesSheetShortcuts)
        .accessibilityIdentifier("detail.shortcut")
        Picker("Shortcut behavior", selection: $sheet.activation) {
            ForEach(ActivationMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .disabled(!openMethod.usesSheetShortcuts)
        .accessibilityIdentifier("detail.activation")
        if !openMethod.usesSheetShortcuts {
            Text("Keyboard shortcuts are off: cheatsheets open from the search bar. To use them too, set General → Open cheatsheets with to “\(SheetOpenMethod.both.label)”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("detail.shortcutInactive")
        }
        if let conflictMessage {
            Text(conflictMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }
        if let systemConflictWarning {
            Text(systemConflictWarning)
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("detail.systemShortcutWarning")
        }
    }

    // MARK: - Shortcut conflicts

    private func handleShortcutChange(_ shortcut: KeyboardShortcuts.Shortcut?) {
        defer { store.touch() }
        guard let shortcut else {
            previousShortcut = nil
            conflictMessage = nil
            systemConflictWarning = nil
            return
        }
        if let other = store.conflictingSheet(with: shortcut, excluding: sheet.id) {
            KeyboardShortcuts.setShortcut(previousShortcut, for: sheet.shortcutName)
            conflictMessage = "\(shortcut) is already used by “\(other.name)”. Kept the previous shortcut."
        } else if openMethod.usesSearch, shortcut == KeyboardShortcuts.getShortcut(for: .openSearch) {
            KeyboardShortcuts.setShortcut(previousShortcut, for: sheet.shortcutName)
            conflictMessage = "\(shortcut) opens the search bar. Kept the previous shortcut."
        } else {
            previousShortcut = shortcut
            conflictMessage = nil
        }
        systemConflictWarning = SystemShortcuts.conflictWarning(
            for: KeyboardShortcuts.getShortcut(for: sheet.shortcutName)
        )
    }

    private func webAddress(of file: String) -> URL? {
        guard MediaKind.of(URL(filePath: file)) == .webpage else { return nil }
        return WebLocation.url(fromFileAt: store.fileURL(for: sheet, file: file))
    }

    /// A linked file's original, when its name isn't the copy's: shown
    /// beside the copy's name so the two are never confused.
    private func differentlyNamedOriginal(of file: String) -> URL? {
        guard store.syncsWithOriginals, sheet.links[file] != nil,
              let original = store.originalURL(ofFile: file, in: sheet),
              original.lastPathComponent != file else { return nil }
        return original
    }

    private func documentRow(_ file: String) -> some View {
        let exists = store.fileExists(for: sheet, file: file)
        let state = store.syncState(of: file, in: sheet)
        return HStack {
            RenamableFileName(file: file) { newName in
                store.renameFile(file, to: newName, in: sheet.id)
            }
            if let original = differentlyNamedOriginal(of: file) {
                Text("→ \(original.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Original: \((original.path as NSString).abbreviatingWithTildeInPath)")
                    .accessibilityIdentifier("detail.originalName")
            }
            if let address = webAddress(of: file) {
                Text(address.host() ?? address.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(address.absoluteString)
            }
            if !exists {
                Label("Missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .labelStyle(.titleAndIcon)
                    .help("The app's copy of this file was deleted. Remove the entry or re-add the file.")
            }
            Spacer()
            // Before the folder, so turning sync on or off doesn't move it.
            // Web pages have no file of their own to link.
            if store.syncsWithOriginals, exists, webAddress(of: file) == nil {
                FileLinkMenu(
                    file: file,
                    sheet: sheet,
                    state: state,
                    onReview: { reviewingFile = ReviewTarget(file: file) },
                    onLinked: { handleLinkResult($0, file: file) }
                )
            }
            Button {
                // The file edits go to: the original while in sync.
                reveal(store.activeURL(ofFile: file, in: sheet))
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(!exists)
            .help(revealHelp(for: state))
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

    /// The folder shows the file the page comes from: the original while
    /// in sync; otherwise the cheatsheet's copy, the only up-to-date file.
    private func revealHelp(for state: FileSyncState) -> String {
        guard store.syncsWithOriginals else { return "Show in Finder" }
        return state == .linked ? "Show original in Finder" : "Show the cheatsheet's copy in Finder"
    }

    private func geometryBehaviorPicker(
        _ title: String,
        remembered: String,
        selection: Binding<GeometryBehavior>,
        identifier: String
    ) -> some View {
        LabeledContent(title) {
            BehaviorPopUpButton(selection: selection, remembered: remembered, identifier: identifier)
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

    // An AppKit pop-up: it looks like the other dropdowns, and its menu
    // reports the highlighted option, which outlines that display.
    private var displayPicker: some View {
        LabeledContent("Display") {
            DisplayPopUpButton(
                options: displayOptions,
                selectedID: Self.optionID(for: displayChoice.wrappedValue)
            ) { id in
                if let choice = displayOptionChoices[id] {
                    displayChoice.wrappedValue = choice
                }
            }
            .fixedSize()
        }
    }

    private static func optionID(for choice: DisplayChoice) -> String {
        switch choice {
        case .cursor: "cursor"
        case .focused: "focused"
        case .specific(let uuid): "screen:\(uuid)"
        }
    }

    /// Both preset options, each connected display, and the saved display
    /// when it isn't connected (the sheet uses the cursor's screen then).
    private var displayOptions: [DisplayPopUpButton.Option] {
        let screens = NSScreen.screens.compactMap { screen in
            screen.displayUUID.map { (uuid: $0, name: screen.localizedName) }
        }
        var options: [DisplayPopUpButton.Option] = [
            .init(id: Self.optionID(for: .cursor), title: "Screen with mouse cursor"),
            .init(id: Self.optionID(for: .focused), title: "Screen with focused window"),
        ]
        for (index, screen) in screens.enumerated() {
            options.append(.init(
                id: Self.optionID(for: .specific(screen.uuid)),
                title: screen.name,
                highlightUUID: screen.uuid,
                startsGroup: index == 0
            ))
        }
        if case .specific(let uuid, let name) = sheet.target, !screens.contains(where: { $0.uuid == uuid }) {
            options.append(.init(
                id: Self.optionID(for: .specific(uuid)),
                title: "\(name) (disconnected — uses cursor screen)",
                startsGroup: screens.isEmpty
            ))
        }
        return options
    }

    private var displayOptionChoices: [String: DisplayChoice] {
        var choices: [String: DisplayChoice] = [
            Self.optionID(for: .cursor): .cursor,
            Self.optionID(for: .focused): .focused,
        ]
        for screen in NSScreen.screens {
            if let uuid = screen.displayUUID {
                choices[Self.optionID(for: .specific(uuid))] = .specific(uuid)
            }
        }
        if case .specific(let uuid, _) = sheet.target {
            choices[Self.optionID(for: .specific(uuid))] = .specific(uuid)
        }
        return choices
    }
}

/// AppKit pop-up with a hard width constraint: SwiftUI's menu picker sizes
/// itself to the *selected* option's text, so two pickers drift to different
/// widths as soon as different values are chosen. NSPopUpButton stretches to
/// any constrained width.
private struct BehaviorPopUpButton: NSViewRepresentable {
    @Binding var selection: GeometryBehavior
    /// "position" or "size": what the remembering option keeps.
    let remembered: String
    let identifier: String

    fileprivate static let behaviors: [GeometryBehavior] = [.locked, .resets, .remembers]
    private static let rememberedKinds = ["position", "size"]

    /// Fits the widest option of either dropdown, so both are the same
    /// width whatever is selected, with no room to spare.
    private static let width: CGFloat = {
        let sizer = NSPopUpButton(frame: .zero, pullsDown: false)
        sizer.addItems(withTitles: rememberedKinds.flatMap { remembered in
            behaviors.map { title(for: $0, remembered: remembered) }
        })
        return sizer.intrinsicContentSize.width
    }()

    private static func title(for behavior: GeometryBehavior, remembered: String) -> String {
        switch behavior {
        case .locked: "Off"
        case .resets: "On, reset on next open"
        case .remembers: "On, remember \(remembered)"
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: Self.behaviors.map { Self.title(for: $0, remembered: remembered) })
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        let index = Self.behaviors.firstIndex(of: selection) ?? 0
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
            guard BehaviorPopUpButton.behaviors.indices.contains(sender.indexOfSelectedItem) else { return }
            selection.wrappedValue = BehaviorPopUpButton.behaviors[sender.indexOfSelectedItem]
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

