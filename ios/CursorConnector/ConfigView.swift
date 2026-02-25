import SwiftUI
import UIKit

/// Known AI model IDs and display names for the Cursor agent.
private let knownModelIds = ["auto", "claude-sonnet-4", "gpt-4o"]
private func displayName(for modelId: String) -> String {
    switch modelId {
    case "auto": return "Auto"
    case "claude-sonnet-4": return "Claude Sonnet 4"
    case "gpt-4o": return "GPT-4o"
    case "custom": return "Custom…"
    default: return modelId
    }
}

/// Server and project configuration. Structured for clear hierarchy: Connection → Project → Updates.
struct ConfigView: View {
    @Binding var host: String
    @Binding var port: String
    @Binding var selectedProject: ProjectEntry?
    @AppStorage("cursorConnectorModel") private var modelId = "auto"
    @AppStorage("testflightInviteURL") private var testflightInviteURL = ""

    @State private var projects: [ProjectEntry] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var restartMessage: String?
    @State private var tailscaleExpanded = false
    @State private var inviteLinkExpanded = false
    @Environment(\.dismiss) private var dismiss

    private var portInt: Int { Int(port) ?? CompanionAPI.defaultPort }

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                modelSection
                projectSection
                updatesSection
            }
            .listSectionSpacing(16)
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

    // MARK: - Connection (Server)

    /// Top section: how to reach the Mac. Primary action = Refresh projects; Restart is secondary. Tailscale hint is collapsed.
    private var connectionSection: some View {
        Section {
            // Host:Port — single row, minimal
            HStack(spacing: 6) {
                TextField("Host or URL", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text(":")
                    .foregroundStyle(.tertiary)
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                    .frame(width: 52)
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))

            // Primary: Refresh projects
            Button {
                Task { await fetchProjects() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh projects")
                    Spacer(minLength: 8)
                    if loading {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
            }
            .disabled(loading || host.isEmpty)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))

            // Secondary: Restart (subtle)
            Button {
                Task { await requestRestart() }
            } label: {
                Label("Restart server", systemImage: "power")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .disabled(host.isEmpty)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 8, trailing: 16))
            }
            if let msg = restartMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 8, trailing: 16))
            }

            DisclosureGroup("Use from anywhere (Tailscale)", isExpanded: $tailscaleExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Install Tailscale on your Mac and iPhone (tailscale.com).")
                    Text("2. On the Mac, open Tailscale and note your Mac’s Tailscale IP (e.g. 100.x.x.x).")
                    Text("3. Set Host above to that IP, Port to 9283, then tap Refresh projects.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("Connection")
        } footer: {
            Text("Same Wi‑Fi: use your Mac’s IP (e.g. 192.168.1.x).")
        }
    }

    // MARK: - AI model

    private var modelSection: some View {
        Section {
            Picker("AI model", selection: Binding(
                get: { knownModelIds.contains(modelId) ? modelId : "custom" },
                set: { if $0 != "custom" { modelId = $0 } }
            )) {
                ForEach(knownModelIds + ["custom"], id: \.self) { id in
                    Text(displayName(for: id)).tag(id)
                }
            }
            if !knownModelIds.contains(modelId) {
                TextField("Model ID", text: $modelId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("AI model")
        } footer: {
            Text("Model used for chat and agent requests. Auto lets Cursor choose.")
        }
    }

    // MARK: - Project

    private var projectSection: some View {
        Section {
            if selectedProject != nil {
                Button(role: .destructive) {
                    selectedProject = nil
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
            if projects.isEmpty && !loading {
                Text("Set host above and tap Refresh projects, or add ~/.cursor-connector-projects.json on your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
            ForEach(projects) { project in
                Button {
                    selectProject(project)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .center)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.label ?? (project.path as NSString).lastPathComponent)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(project.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        if selectedProject?.path == project.path {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.body)
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        } header: {
            Text("Project")
        } footer: {
            Text("Projects are loaded from your Mac. See README to add a custom list.")
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        Section {
            Button {
                openTestFlight()
            } label: {
                Label("Open TestFlight to update", systemImage: "arrow.down.circle")
            }

            DisclosureGroup("Optional: TestFlight invite link", isExpanded: $inviteLinkExpanded) {
                TextField("Paste invite link", text: $testflightInviteURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Text("Opens this link when you tap the button; leave empty to open the TestFlight app.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("When away from your Mac, update the app via TestFlight. Set up once in Xcode (see README).")
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
