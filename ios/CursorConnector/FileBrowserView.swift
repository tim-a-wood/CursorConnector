import SwiftUI

/// Displays a file tree for the connected project. Fetches one level at a time; tapping a folder loads its children.
struct FileBrowserView: View {
    let projectPath: String
    let host: String
    let port: Int

    @State private var entries: [CompanionAPI.FileTreeEntry] = []
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        listView
            .navigationTitle("Project files")
            .task {
                await loadEntries()
            }
            .refreshable {
                await loadEntries()
            }
    }

    private var listView: some View {
        List {
            if loading && entries.isEmpty {
                HStack {
                    ProgressView()
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
            }
            if let err = errorMessage {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink {
                        FileBrowserLevelView(path: entry.path, projectPath: projectPath, host: host, port: port)
                    } label: {
                        Label(entry.name, systemImage: "folder.fill")
                            .font(.body)
                    }
                } else {
                    NavigationLink {
                        FileContentView(filePath: entry.path, host: host, port: port)
                    } label: {
                        Label(entry.name, systemImage: "doc.text")
                            .font(.body)
                    }
                }
            }
        }
    }

    private func loadEntries() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let list = try await CompanionAPI.fetchFileTree(path: projectPath, host: host, port: port)
            await MainActor.run {
                entries = list
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                entries = []
            }
        }
    }
}

/// One level of the file tree (used when navigating into subfolders).
struct FileBrowserLevelView: View {
    let path: String
    let projectPath: String
    let host: String
    let port: Int

    @State private var entries: [CompanionAPI.FileTreeEntry] = []
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if loading && entries.isEmpty {
                HStack {
                    ProgressView()
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
            }
            if let err = errorMessage {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink {
                        FileBrowserLevelView(path: entry.path, projectPath: projectPath, host: host, port: port)
                    } label: {
                        Label(entry.name, systemImage: "folder.fill")
                            .font(.body)
                    }
                } else {
                    NavigationLink {
                        FileContentView(filePath: entry.path, host: host, port: port)
                    } label: {
                        Label(entry.name, systemImage: "doc.text")
                            .font(.body)
                    }
                }
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .task {
            await loadEntries()
        }
        .refreshable {
            await loadEntries()
        }
    }

    private func loadEntries() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let list = try await CompanionAPI.fetchFileTree(path: path, host: host, port: port)
            await MainActor.run {
                entries = list
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                entries = []
            }
        }
    }
}

#Preview {
    NavigationStack {
        FileBrowserView(projectPath: "/tmp", host: "localhost", port: 9283)
    }
}
