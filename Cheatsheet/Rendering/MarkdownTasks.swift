import Foundation

/// Ticking a task-list checkbox in rendered markdown edits its source line.
nonisolated enum MarkdownTasks {
    /// A list item's marker and checkbox, optionally inside block quotes:
    /// "- [ ] a", "  * [x] b", "1. [X] c", "> - [ ] d".
    private static let taskPattern = try! NSRegularExpression(
        pattern: #"^((?:[ \t]*>)*[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+\[)([ xX])(\])"#
    )

    /// The source with the task item starting on `line` (1-based) set to
    /// `checked`. Nil when that line isn't a task item — the file changed
    /// since it was rendered, so the tick is dropped rather than misapplied.
    static func settingTask(atLine line: Int, checked: Bool, in source: String) -> String? {
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(line - 1) else { return nil }
        let text = lines[line - 1]
        let range = NSRange(text.startIndex..., in: text)
        guard
            let match = taskPattern.firstMatch(in: text, range: range),
            let mark = Range(match.range(at: 2), in: text)
        else { return nil }
        lines[line - 1] = text.replacingCharacters(in: mark, with: checked ? "x" : " ")
        return lines.joined(separator: "\n")
    }
}
