import CoreText
import Foundation

/// Narrows OCR boxes to the matched characters. Vision only reports boxes at
/// word granularity (a sub-word range comes back as the whole word), so the
/// match is located inside its enclosing word span by measuring the text's
/// glyph advances — close enough for any proportional UI font.
nonisolated enum ImageMatchGeometry {
    /// The run of non-whitespace text containing `match` (several words when
    /// the match itself spans a space).
    static func enclosingWordRange(of match: NSRange, in text: String) -> NSRange {
        let string = text as NSString
        func isSeparator(_ index: Int) -> Bool {
            guard let scalar = UnicodeScalar(string.character(at: index)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        var start = match.location
        while start > 0, !isSeparator(start - 1) {
            start -= 1
        }
        var end = NSMaxRange(match)
        while end < string.length, !isSeparator(end) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// The part of `wordBox` (which bounds `word` in `text`) covering `match`.
    static func matchRect(_ match: NSRange, word: NSRange, in text: String, wordBox: CGRect) -> CGRect {
        guard word.length > 0, match != word else { return wordBox }
        let string = text as NSString
        let total = advance(of: string.substring(with: word))
        guard total > 0 else { return wordBox }
        let prefix = NSRange(location: word.location, length: match.location - word.location)
        let lead = advance(of: string.substring(with: prefix))
        let width = advance(of: string.substring(with: match))
        return CGRect(
            x: wordBox.minX + wordBox.width * lead / total,
            y: wordBox.minY,
            width: wordBox.width * width / total,
            height: wordBox.height
        )
    }

    private static let measuringFont = CTFontCreateUIFontForLanguage(.system, 12, nil)

    /// Typographic width of `text` in the system font. Only ratios are used,
    /// so the point size doesn't matter.
    private static func advance(of text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        guard let font = measuringFont else { return CGFloat(text.count) }
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}
