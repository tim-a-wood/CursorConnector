import SwiftUI

/// Server and project configuration. Host, port, project list, connect, restart.
struct ConfigView: View {
    @Binding var host: String
    @Binding var port: String
    @Binding var selectedProject: ProjectEntry?

    @State private var projects: [ProjectEntry] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var restartMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var portInt: Int { Int(port) ?? CompanionAPI.defaultPort }

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    HStack {
                        TextField("Host (IP or name)", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text(":")
                        TextField("Port", text: $port)
                            .keyboardType(.numberPad)
                            .frame(width: 60)
                    }
                    HStack {
                        Button(loading ? "Loading…" : "Refresh projects") {
                            Task { await fetchProjects() }
                        }
                        .disabled(loading || host.isEmpty)
                        Button("Restart server") {
                            Task { await requestRestart() }
                        }
                        .disabled(host.isEmpty)
                    }
                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let msg = restartMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Project") {
                    if selectedProject != nil {
                        Button(role: .destructive) {
                            selectedProject = nil
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle")
                        }
                    }
                    if projects.isEmpty && !loading {
                        Text("Enter host and tap Refresh, or add ~/.cursor-connector-projects.json on your Mac.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(projects) { project in
                        Button {
                            selectProject(project)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.label ?? (project.path as NSString).lastPathComponent)
                                        .font(.body)
                                    Text(project.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                if selectedProject?.path == project.path {
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                if !host.isEmpty { await fetchProjects() }
            }
        }
    }

    private func fetchProjects() async {
        loading = true
        errorMessage = nil
        restartMessage = nil
        defer { loading = false }
        do {
            projects = try await CompanionAPI.fetchProjects(host: host, port: portInt)
        } catch {
            errorMessage = error.localizedDescription
            projects = []
        }
    }

    private func requestRestart() async {
        restartMessage = nil
        errorMessage = nil
        do {
            try await CompanionAPI.restartServer(host: host, port: portInt)
            await MainActor.run {
                restartMessage = "Restart sent. If the Companion runs under a restarter script, it will come back in a few seconds."
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func selectProject(_ project: ProjectEntry) {
        selectedProject = project
    }
}
