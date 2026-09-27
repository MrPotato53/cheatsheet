import AppKit

/// The page open for editing in an overlay. Edits autosave shortly after
/// typing stops, and always when editing ends (Done, Escape, paging,
/// closing the overlay).
struct OverlayEditorState: Equatable {
    let file: String
    let url: URL
    var text: String
    var isDirty = false
    /// Where the last save went; nil until something has been saved.
    var lastSave: EditSaveOutcome?
}

extension OverlayController {
    private static let autosaveDelay: Duration = .milliseconds(600)

    /// Text-based pages, edited as source (HTML included: its markup is
    /// shown as-is while editing). Settings never offers editing.
    static func isEditable(_ page: SheetPage) -> Bool {
        switch MediaKind.of(page.url) {
        case .text, .markdown, .html: FileManager.default.fileExists(atPath: page.url.path)
        case .pdf, .image, .unsupported: false
        }
    }

    func beginEditing(in session: OverlaySession) {
        guard session.editor == nil, let page = session.currentPage, Self.isEditable(page) else { return }
        if session.search.isActive {
            closeSearch(in: session)
        }
        session.editor = OverlayEditorState(
            file: page.url.lastPathComponent,
            url: page.url,
            text: TextFile.read(page.url) ?? ""
        )
        session.panel.makeKey()
    }

    func toggleEditing(in session: OverlaySession) {
        if session.editor == nil {
            beginEditing(in: session)
        } else {
            endEditing(in: session)
        }
    }

    func editorTextChanged(_ text: String, in session: OverlaySession) {
        guard session.editor != nil, session.editor?.text != text else { return }
        session.editor?.text = text
        session.editor?.isDirty = true
        session.editorSaveTask?.cancel()
        session.editorSaveTask = Task { [weak self, weak session] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled, let self, let session else { return }
            self.saveEditor(in: session)
        }
    }

    func saveEditor(in session: OverlaySession) {
        session.editorSaveTask?.cancel()
        guard let editor = session.editor, editor.isDirty else { return }
        let outcome = store.writeContents(Data(editor.text.utf8), toFile: editor.file, in: session.sheet.id)
        session.editor?.isDirty = outcome == .failed
        session.editor?.lastSave = outcome
    }

    /// Saves and returns the page to its normal (rendered) view.
    func endEditing(in session: OverlaySession) {
        guard session.editor != nil else { return }
        saveEditor(in: session)
        session.editor = nil
        session.contentRevision += 1
        session.panel.makeFirstResponder(nil)
    }

    /// Keys while editing go to the text (arrows move the caret). Escape
    /// finishes editing instead of closing the overlay; ⌘S saves now; ⌘E
    /// toggles editing. Nil: not an editor key, use the normal handling.
    func handleEditorKeyEvent(_ event: NSEvent, in session: OverlaySession) -> Bool? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "e" {
            toggleEditing(in: session)
            return true
        }
        guard session.editor != nil else { return nil }
        if flags == .command, key == "s" {
            saveEditor(in: session)
            return true
        }
        switch event.keyCode {
        case 53: // escape
            endEditing(in: session)
            return true
        case 123, 124, 125, 126: // arrows edit, not page
            return false
        default:
            return nil
        }
    }

    // MARK: - Rendered-page interactions

    /// Ticks a markdown task checkbox by editing its source line.
    func setTask(atLine line: Int, checked: Bool, url: URL, in session: OverlaySession) -> Bool {
        guard
            let source = TextFile.read(url),
            let updated = MarkdownTasks.settingTask(atLine: line, checked: checked, in: source)
        else { return false }
        let outcome = store.writeContents(Data(updated.utf8), toFile: url.lastPathComponent, in: session.sheet.id)
        return outcome != .failed
    }

    // MARK: - Originals

    /// Brings copies up to date with newer originals when an overlay opens;
    /// pages already on screen reload only if something actually changed.
    func checkOriginals(for session: OverlaySession) {
        guard store.syncsWithOriginals else { return }
        let sheetID = session.sheet.id
        Task { [weak self, weak session] in
            guard let self, await self.store.checkLinks(for: sheetID), let session else { return }
            self.reloadPages(session)
        }
    }

    func syncState(of page: SheetPage, in session: OverlaySession) -> FileSyncState {
        store.syncState(of: page.url.lastPathComponent, in: session.sheet)
    }

    func resolveSync(_ resolution: SyncResolution, for page: SheetPage, in session: OverlaySession) {
        guard store.resolveSync(resolution, forFile: page.url.lastPathComponent, in: session.sheet.id) else { return }
        reloadPages(session)
    }

    private func reloadPages(_ session: OverlaySession) {
        guard sessions.contains(where: { $0 === session }), session.editor == nil, !session.isLoadingPages else { return }
        session.pages = store.pages(for: session.sheet)
        session.pageIndex = min(session.pageIndex, max(session.pages.count - 1, 0))
        session.contentRevision += 1
        updateFrame(for: session, animated: false)
    }
}
