import SwiftUI
import UIKit

/// Server and project configuration. Host, port, project list, connect, restart. Host, port, project list, connect, restart.
struct ConfigView: View {
    @Binding var host: String
    @Binding var port: String
    @Binding var selectedProject: ProjectEntry?
    @AppStorage("testflightInviteURL") private var testflightInviteURL = ""

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
                        TextField("Host or URL", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text(":")
                        TextField("Port", text: $port)
                            .keyboardType(.numberPad)
                            .frame(width: 60)
                    }
                    Text("Same network: use your Mac’s IP (e.g. 192.168.1.x).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Group {
                        Text("Use from anywhere (Tailscale):")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text("1. Install Tailscale on your Mac and iPhone (tailscale.com).\n2. On the Mac, open Tailscale and note your Mac’s Tailscale IP (e.g. 100.x.x.x).\n3. Here, set Host to that IP and Port to 9283, then tap Refresh projects.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

                Section("Updates") {
                    Text("When you’re away from your Mac, install or update the app via TestFlight. Set up once in Xcode (see README), then tap below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        openTestFlight()
                    } label: {
                        Label("Open TestFlight to update", systemImage: "arrow.down.circle")
                    }
                    TextField("TestFlight invite link (optional)", text: $testflightInviteURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Paste your TestFlight link once so the button opens it directly. Leave empty to just open the TestFlight app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        Text("Enter host (or tunnel URL) and tap Refresh, or add ~/.cursor-connector-projects.json on your Mac.")
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

    private func openTestFlight() {
        let urlString = testflightInviteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL? = {
            if !urlString.isEmpty, let u = URL(string: urlString), u.scheme != nil {
                return u
            }
            return URL(string: "https://testflight.apple.com")
        }()
        guard let u = url else { return }
        UIApplication.shared.open(u)
    }
}
