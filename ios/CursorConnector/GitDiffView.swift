import SwiftUI

/// Shows the git diff for a single file (read-only), with added/removed line coloring.
struct GitDiffView: View {
    let filePath: String
    let diff: String

    private struct DiffLine: Identifiable {
        let id: Int
        let text: String
        let kind: LineKind
    }

    private enum LineKind {
        case header, added, removed, context
    }

    private var diffLines: [DiffLine] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            let s = String(line)
            let kind: LineKind
            if s.hasPrefix("+++") || s.hasPrefix("---") || s.hasPrefix("@@") {
                kind = .header
            } else if s.hasPrefix("+") {
                kind = .added
            } else if s.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .context
            }
            return DiffLine(id: index, text: s, kind: kind)
        }
    }

    var body: some View {
        Group {
            if diff.isEmpty {
                Text("No changes.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    ScrollView(.vertical, showsIndicators: true) {
                        ScrollView(.horizontal, showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(diffLines) { line in
                                    Text(line.text)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(lineBackground(for: line.kind))
                                }
                            }
                            .frame(minWidth: geometry.size.width)
                            .padding(8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle((filePath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func lineBackground(for kind: LineKind) -> Color {
        switch kind {
        case .header: return Color.clear
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .context: return Color.clear
        }
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
            // Server expects file path relative to repo root (no leading slash).
            let relativePath = filePath.hasPrefix("/") ? String(filePath.dropFirst()) : filePath
            let d = try await CompanionAPI.fetchGitDiff(path: projectPath, file: relativePath, host: host, port: port)
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
