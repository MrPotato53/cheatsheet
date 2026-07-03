import Foundation
import UniformTypeIdentifiers

nonisolated enum MediaKind: Equatable {
    case pdf
    case image
    case markdown
    case text
    case unsupported

    static func of(_ url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { return .markdown }
        guard let type = UTType(filenameExtension: ext) else { return .unsupported }
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
        case .text: "doc.plaintext"
        case .unsupported: "questionmark.square.dashed"
        }
    }
}
