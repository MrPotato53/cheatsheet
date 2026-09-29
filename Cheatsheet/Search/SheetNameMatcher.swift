import Foundation

/// Matches a launcher query against cheatsheet names. A name matches when the
/// query's characters appear in it in order (not necessarily adjacent); case
/// and diacritics are ignored. Ranking: a continuous match beats a scattered
/// one, then the earlier the match starts, the tighter it is, the shorter the
/// name, and finally alphabetical.
nonisolated enum SheetNameMatcher {
    struct Match: Equatable {
        let isContinuous: Bool
        /// Character offset in the name where the match starts.
        let start: Int
        /// Characters from the first matched character to the last.
        let span: Int
        /// Character offsets in the name that matched, for highlighting.
        let matchedOffsets: [Int]
    }

    struct Ranked: Equatable {
        /// Index into the names passed to `rank`.
        let index: Int
        let match: Match
    }

    static func match(query: String, in name: String) -> Match? {
        let needle = folded(query).filter { !$0.allSatisfy(\.isWhitespace) }
        guard !needle.isEmpty else { return nil }
        let haystack = folded(name)
        let rawNeedle = folded(query.trimmingCharacters(in: .whitespaces))
        if let start = firstContiguousOffset(of: rawNeedle, in: haystack) {
            return Match(
                isContinuous: true,
                start: start,
                span: rawNeedle.count,
                matchedOffsets: Array(start..<(start + rawNeedle.count))
            )
        }
        guard let offsets = leftmostSubsequence(needle, in: haystack), let first = offsets.first, let last = offsets.last else {
            return nil
        }
        return Match(isContinuous: false, start: first, span: last - first + 1, matchedOffsets: offsets)
    }

    /// Matching names in listing order.
    static func rank(names: [String], query: String) -> [Ranked] {
        names.enumerated()
            .compactMap { index, name in match(query: query, in: name).map { Ranked(index: index, match: $0) } }
            .sorted { lhs, rhs in isOrderedBefore(lhs, rhs, names: names) }
    }

    private static func isOrderedBefore(_ lhs: Ranked, _ rhs: Ranked, names: [String]) -> Bool {
        let a = lhs.match
        let b = rhs.match
        if a.isContinuous != b.isContinuous { return a.isContinuous }
        if a.start != b.start { return a.start < b.start }
        if a.span != b.span { return a.span < b.span }
        let nameA = names[lhs.index]
        let nameB = names[rhs.index]
        if nameA.count != nameB.count { return nameA.count < nameB.count }
        let order = nameA.localizedStandardCompare(nameB)
        return order == .orderedSame ? lhs.index < rhs.index : order == .orderedAscending
    }

    /// One folded string per character, so offsets stay aligned with the
    /// original name even when folding changes a character's length.
    private static func folded(_ text: String) -> [String] {
        text.map { String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
    }

    private static func firstContiguousOffset(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where needle.indices.allSatisfy({ haystack[start + $0] == needle[$0] }) {
            return start
        }
        return nil
    }

    /// Greedy leftmost: finds a subsequence whenever one exists, starting at
    /// the earliest possible offset and ending as early as possible from there.
    private static func leftmostSubsequence(_ needle: [String], in haystack: [String]) -> [Int]? {
        var offsets: [Int] = []
        var position = 0
        for character in needle {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            offsets.append(found)
            position = found + 1
        }
        return offsets
    }
}
