import SwiftUI

/// Shows the git diff for a single file (read-only).
struct GitDiffView: View {
    let filePath: String
    let diff: String

    var body: some View {
        Group {
            if diff.isEmpty {
                Text("No changes.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Text(diff)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(8)
                }
            }
        }
        .navigationTitle((filePath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Loads the diff for a file from the Companion then shows GitDiffView.
struct GitDiffLoaderView: View {
    let projectPath: String
    let host: String
    let port: Int
    let filePath: String

    @State private var diff: String?
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if loading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading diff…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMessage {
                ContentUnavailableView {
                    Label("Could not load diff", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                }
            } else if let d = diff {
                GitDiffView(filePath: filePath, diff: d)
            }
        }
        .navigationTitle((filePath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDiff()
        }
    }

    private func loadDiff() async {
        loading = true
        errorMessage = nil
        diff = nil
        defer { loading = false }
        do {
            let d = try await CompanionAPI.fetchGitDiff(path: projectPath, file: filePath, host: host, port: port)
            await MainActor.run { diff = d }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }
}

#Preview {
    NavigationStack {
        GitDiffView(
            filePath: "Sources/main.swift",
            diff: "diff --git a/Sources/main.swift b/Sources/main.swift\nindex 123..456 100644\n--- a/Sources/main.swift\n+++ b/Sources/main.swift\n@@ -1,3 +1,4 @@\n+// New line\n import Foundation\n"
        )
    }
}
