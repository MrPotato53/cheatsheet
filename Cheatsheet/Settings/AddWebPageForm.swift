import SwiftUI

/// Asks for a web page's address (and optionally a name) to add as a page.
struct AddWebPageForm: View {
    let title: String
    /// Shown as a Back button when this form is a step in a larger flow.
    var onBack: (() -> Void)?
    let onAdd: (WebLocation.Entry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""

    private var url: URL? {
        WebLocation.normalizedURL(from: address)
    }

    private var entry: WebLocation.Entry? {
        guard let url else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return WebLocation.Entry(url: url, name: trimmedName.isEmpty ? WebLocation.defaultName(for: url) : trimmedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            Form {
                TextField("Address", text: $address, prompt: Text("example.com or localhost:3000"))
                    .accessibilityIdentifier("webPage.address")
                TextField("Name", text: $name, prompt: Text(url.map { WebLocation.defaultName(for: $0) } ?? "Optional"))
                    .accessibilityIdentifier("webPage.name")
            }
            if !address.isEmpty, url == nil {
                Text("Enter a web address, like example.com/docs.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Links to other sites open in your browser. Signing in to a site may work, but isn't supported: some sites, including Google sign-in, block signing in from apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let onBack {
                    Button("Back", action: onBack)
                        .accessibilityIdentifier("webPage.back")
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Add") {
                    guard let entry else { return }
                    onAdd(entry)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entry == nil)
                .accessibilityIdentifier("webPage.add")
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
