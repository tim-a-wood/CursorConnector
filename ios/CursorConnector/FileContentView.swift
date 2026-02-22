import SwiftUI

/// Displays the contents of a single file with view/edit. Shows "Binary file" for non-text files.
struct FileContentView: View {
    let filePath: String
    let host: String
    let port: Int

    @State private var content: String = ""
    @State private var editedContent: String = ""
    @State private var binary: Bool = false
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var saveError: String?
    @State private var hasUnsavedChanges = false

    private var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    private var canEdit: Bool { !binary && !loading && errorMessage == nil }

    var body: some View {
        Group {
            if loading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMessage {
                ContentUnavailableView {
                    Label("Could not load file", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                }
            } else if binary {
                ContentUnavailableView {
                    Label("Binary file", systemImage: "doc.fill")
                } description: {
                    Text("This file is not displayed as text.")
                }
            } else {
                VStack(spacing: 0) {
                    if let err = saveError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal)
                    }
                    TextEditor(text: $editedContent)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .onChange(of: editedContent) { _, _ in
                            hasUnsavedChanges = (editedContent != content)
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(saving || !hasUnsavedChanges)
                }
            }
        }
        .task {
            await loadContent()
        }
    }

    private func loadContent() async {
        loading = true
        errorMessage = nil
        saveError = nil
        defer { loading = false }
        do {
            let response = try await CompanionAPI.fetchFileContent(path: filePath, host: host, port: port)
            await MainActor.run {
                binary = response.binary
                content = response.content ?? ""
                editedContent = content
                hasUnsavedChanges = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() async {
        saving = true
        saveError = nil
        defer { saving = false }
        do {
            try await CompanionAPI.saveFileContent(path: filePath, content: editedContent, host: host, port: port)
            await MainActor.run {
                content = editedContent
                hasUnsavedChanges = false
            }
        } catch {
            await MainActor.run {
                saveError = error.localizedDescription
            }
        }
    }
}

#Preview {
    NavigationStack {
        FileContentView(filePath: "/tmp/README.md", host: "localhost", port: 9283)
    }
}
