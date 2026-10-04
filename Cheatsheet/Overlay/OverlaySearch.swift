import AppKit

/// Find-in-sheet state for one overlay session.
nonisolated struct OverlaySearchState: Equatable {
    var isActive = false
    var query = ""
    var matches = SearchMatches.empty
    /// The query `matches` were computed for. Lags `query` while a search is
    /// debounced/running, so highlights don't flicker off mid-typing.
    var resultsQuery = ""
    /// Active occurrence, indexed across all pages.
    var current: Int?
    /// Bumped to (re)focus the search field, e.g. ⌘F while it's already open.
    var focusRequest = 0
    /// A search has been running long enough to be worth mentioning.
    var isSearching = false
    /// `matches` cover only the current page (SearchScope.currentPage).
    var isScopedToPage = false

    func highlight(forPage index: Int) -> SearchHighlight? {
        guard isActive, !resultsQuery.isEmpty else { return nil }
        return SearchHighlight(query: resultsQuery, activeIndex: matches.localIndex(of: current, onPage: index))
    }

    /// "3 of 12", "No matches", or nil before there's anything to report.
    var statusText: String? {
        guard !query.isEmpty else { return nil }
        if isSearching, resultsQuery != query { return "Searching…" }
        guard !resultsQuery.isEmpty else { return nil }
        let total = matches.total
        guard total > 0 else { return isScopedToPage ? "No matches on this page" : "No matches" }
        return current.map { "\($0 + 1) of \(total)" } ?? "\(total)"
    }
}

extension OverlayController {
    private static let searchDebounce: Duration = .milliseconds(120)

    func openSearch(in session: OverlaySession) {
        endEditing(in: session)
        session.search.isActive = true
        session.search.focusRequest += 1
        session.panel.makeKey()
        PageSearch.prepare(session.pages)
    }

    func closeSearch(in session: OverlaySession) {
        session.searchTask?.cancel()
        session.search = OverlaySearchState()
    }

    func setSearchQuery(_ query: String, in session: OverlaySession) {
        guard session.search.query != query else { return }
        session.search.query = query
        runSearch(in: session, jumpToFirst: true)
    }

    func stepSearch(in session: OverlaySession, forward: Bool) {
        let search = session.search
        guard
            let next = search.matches.step(from: search.current, pageIndex: session.pageIndex, forward: forward),
            let location = search.matches.location(of: next)
        else { return }
        session.search.current = next
        goToPage(location.page, in: session)
    }

    /// Searching only the current page: paging away searches the new page.
    func searchPageChanged(in session: OverlaySession) {
        guard session.search.isActive, SearchScope.current == .currentPage else { return }
        runSearch(in: session, jumpToFirst: true)
    }

    /// A web page finished loading while shown: its text is new.
    func webPageDidLoad(in session: OverlaySession) {
        guard session.search.isActive else { return }
        runSearch(in: session, jumpToFirst: false)
    }

    /// Counts matches off the main thread (PDF text search can take a
    /// moment), then in loaded web pages. A new query jumps to its first
    /// match from the current page; a page-list rebuild (e.g. raw toggle)
    /// just refreshes the counts.
    func runSearch(in session: OverlaySession, jumpToFirst: Bool) {
        session.searchTask?.cancel()
        let query = session.search.query
        guard !query.isEmpty else {
            session.search.matches = .empty
            session.search.resultsQuery = ""
            session.search.current = nil
            return
        }
        let pages = session.pages
        let onlyPage = SearchScope.current == .currentPage ? session.pageIndex : nil
        session.searchTask = Task { [weak self, weak session] in
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            // Text recognition on a sheet's images can take a moment the
            // first time; only then does the bar say so (no per-keystroke flicker).
            let indicator = Task { @MainActor [weak session] in
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { session?.search.isSearching = true }
            }
            var counts = await Task.detached(priority: .userInitiated) {
                await PageSearch.matchCounts(query: query, pages: pages, onlyPage: onlyPage)
            }.value
            counts = await Self.addingWebPageCounts(to: counts, query: query, pages: pages, onlyPage: onlyPage)
            indicator.cancel()
            session?.search.isSearching = false
            guard !Task.isCancelled, let self, let session, session.search.query == query else { return }
            session.search.isScopedToPage = onlyPage != nil
            let matches = SearchMatches(counts: counts)
            let previous = session.search.current
            session.search.matches = matches
            session.search.resultsQuery = query
            if !jumpToFirst, let previous, previous < matches.total {
                return
            }
            session.search.current = matches.first(fromPage: session.pageIndex)
            if jumpToFirst, let current = session.search.current, let location = matches.location(of: current) {
                self.goToPage(location.page, in: session)
            }
        }
    }

    /// Web pages are searched only once loaded (a page never shown isn't
    /// loaded just to search it), in the text the page shows right now.
    private static func addingWebPageCounts(
        to counts: [Int],
        query: String,
        pages: [SheetPage],
        onlyPage: Int?
    ) async -> [Int] {
        var counts = counts
        for (index, page) in pages.enumerated() where MediaKind.of(page.url) == .webpage {
            guard onlyPage == nil || onlyPage == index,
                  let livePage = LiveWebPages.existingPage(forFile: page.url)
            else { continue }
            counts[index] = await livePage.matchCount(for: query)
        }
        return counts
    }

    /// Search keys, checked before the overlay's own paging/Escape handling.
    /// Nil means "not a search key": fall through to the normal handling.
    func handleSearchKeyEvent(_ event: NSEvent, in session: OverlaySession) -> Bool? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags.contains(.command), key == "f",
           session.pages.contains(where: { MediaKind.of($0.url).isSearchable }) {
            openSearch(in: session)
            return true
        }
        guard session.search.isActive else { return nil }
        if flags.contains(.command), key == "g" {
            stepSearch(in: session, forward: !flags.contains(.shift))
            return true
        }
        switch event.keyCode {
        case 53: // escape closes the search before it would close the overlay
            closeSearch(in: session)
            return true
        case 36, 76: // return / enter
            stepSearch(in: session, forward: !flags.contains(.shift))
            return true
        case 123, 124: // arrows move the caret while typing a query
            return isEditingSearchField(in: session) ? false : nil
        default:
            return nil
        }
    }

    func isEditingSearchField(in session: OverlaySession) -> Bool {
        (session.panel.firstResponder as? NSTextView)?.isFieldEditor == true
    }
}
