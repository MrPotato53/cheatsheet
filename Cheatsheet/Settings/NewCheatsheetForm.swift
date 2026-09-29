import SwiftUI

/// The one way to create a cheatsheet: start from files or from a web
/// page. More of either can be added to it afterwards.
struct NewCheatsheetForm: View {
    /// Files chosen: the caller opens the file picker once this closes.
    let onChooseFiles: () -> Void
    let onAddWebPage: (WebLocation.Entry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isEnteringWebPage = false

    var body: some View {
        if isEnteringWebPage {
            AddWebPageForm(
                title: "New Cheatsheet from a Web Page",
                onBack: { isEnteringWebPage = false },
                onAdd: onAddWebPage
            )
        } else {
            chooser
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Cheatsheet")
                .font(.headline)
            Text("Start from files or a web page. You can add more of either later.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                choice(
                    "Files",
                    systemImage: "doc.on.doc",
                    detail: "PDFs, images, Markdown, HTML or text",
                    id: "newSheet.files"
                ) {
                    onChooseFiles()
                    dismiss()
                }
                choice(
                    "Web Page",
                    systemImage: "safari",
                    detail: "A website or a local server",
                    id: "newSheet.webPage"
                ) {
                    isEnteringWebPage = true
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .opensUnfocused()
    }

    private func choice(
        _ title: String,
        systemImage: String,
        detail: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier(id)
    }
}
