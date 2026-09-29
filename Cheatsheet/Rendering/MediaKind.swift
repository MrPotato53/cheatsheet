import Foundation
import UniformTypeIdentifiers

nonisolated enum MediaKind: Equatable {
    case pdf
    case image
    case markdown
    case html
    case text
    /// A `.webloc` pointing at a web page, shown live.
    case webpage
    case unsupported

    static func of(_ url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { return .markdown }
        if ext == WebLocation.fileExtension { return .webpage }
        guard let type = UTType(filenameExtension: ext) else { return .unsupported }
        if type.conforms(to: .html) { return .html }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return .text }
        return .unsupported
    }

    var systemImage: String {
        switch self {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .markdown: "doc.text"
        case .html: "globe"
        case .text: "doc.plaintext"
        case .webpage: "safari"
        case .unsupported: "questionmark.square.dashed"
        }
    }

    /// "a PDF", "a markdown file"… for messages.
    var descriptionWithArticle: String {
        switch self {
        case .pdf: "a PDF"
        case .image: "an image"
        case .markdown: "a markdown file"
        case .html: "an HTML page"
        case .text: "a text file"
        case .webpage: "a web page"
        case .unsupported: "an unsupported file"
        }
    }

    /// Markup formats render formatted by default and can switch to showing
    /// their source text.
    var hasRawView: Bool {
        self == .markdown || self == .html
    }

    /// Overlay search reads the app's copy of a page; a web page's content
    /// lives on the server, so it isn't searched.
    var isSearchable: Bool {
        self != .unsupported && self != .webpage
    }
}
