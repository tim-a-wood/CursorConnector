import SwiftUI

struct ContentView: View {
    @AppStorage("cursorConnectorHost") private var host = ""
    @AppStorage("cursorConnectorPort") private var port = "9283"
    @State private var selectedProject: ProjectEntry?
    @State private var messages: [ChatMessage] = []
    @State private var showConfig = false
    @State private var isBuilding = false
    @State private var isUploadingTestFlight = false
    @State private var buildAlertTitle = "Build"
    @State private var buildAlertMessage: String?
    @State private var showBuildAlert = false
    /// When we have a project, periodically check /health. If unreachable (e.g. Mac slept), show banner and retry until back.
    @State private var serverReachable: Bool = true
    /// Recent projects from server (when no project selected). Shown on open so user can open without going to Settings.
    @State private var recentProjects: [ProjectEntry] = []
    @State private var loadingRecentProjects = false
    @State private var recentProjectsError: String?

    private var portInt: Int { Int(port) ?? CompanionAPI.defaultPort }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if selectedProject != nil, !serverReachable {
                    reconnectingBanner
                }
                toolbarButtonRow(project: selectedProject)
                if let project = selectedProject {
                    ChatView(project: project, host: host, port: portInt, messages: $messages)
                } else {
                    emptyState
                }
            }
            .background(Color(white: 0.18))
            .task(id: "\(host):\(portInt):\(selectedProject?.path ?? "")") {
                await connectionMonitorLoop()
            }
            .task(id: "recent-\(host):\(portInt)-\(selectedProject?.path ?? "none")") {
                guard selectedProject == nil, !host.isEmpty else { return }
                await fetchRecentProjects()
            }
            .onChange(of: selectedProject) { _, newValue in
                if newValue != nil {
                    recentProjects = []
                    recentProjectsError = nil
                }
            }
            .navigationTitle(selectedProject != nil ? (selectedProject!.label ?? (selectedProject!.path as NSString).lastPathComponent) : "Cursor")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showConfig) {
                ConfigView(host: $host, port: $port, selectedProject: $selectedProject)
                    .onDisappear {
                        if selectedProject == nil {
                            messages = []
                        }
                    }
            }
            .alert(buildAlertTitle, isPresented: $showBuildAlert) {
                if buildAlertMessage != nil {
                    Button("Copy") {
                        if let msg = buildAlertMessage {
                            UIPasteboard.general.string = msg
                        }
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                if let msg = buildAlertMessage {
                    Text(msg)
                }
            }
        }
    }

    @ViewBuilder
    private func toolbarButtonRow(project: ProjectEntry?) -> some View {
        HStack(spacing: 0) {
            if let project = project {
                NavigationLink {
                    FileBrowserView(projectPath: project.path, host: host, port: portInt)
                } label: {
                    ToolbarButtonContent(icon: "folder", title: "Files")
                }
                NavigationLink {
                    GitView(projectPath: project.path, host: host, port: portInt)
                } label: {
                    ToolbarButtonContent(icon: "arrow.triangle.branch", title: "Git")
                }
            }
            if project != nil {
                Button {
                    triggerBuild()
                } label: {
                    if isBuilding {
                        VStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.9)
                            Text("Build")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ToolbarButtonContent(icon: "hammer", title: "Build")
                    }
                }
                .disabled(isBuilding || isUploadingTestFlight || host.isEmpty)
                Button {
                    triggerTestFlightUpload()
                } label: {
                    if isUploadingTestFlight {
                        VStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.9)
                            Text("TestFlight")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ToolbarButtonContent(icon: "arrow.up.circle", title: "TestFlight")
                    }
                }
                .disabled(isBuilding || isUploadingTestFlight || host.isEmpty)
            }
            Button {
                showConfig = true
            } label: {
                ToolbarButtonContent(icon: "gearshape", title: "Settings")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
        .tint(.white)
    }

    private var reconnectingBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.9)
            Text("Mac unreachable. Reconnecting…")
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.9))
        .foregroundStyle(.white)
    }

    /// Polls /health. When unreachable, sets serverReachable = false and retries every 5s until reachable again.
    /// Shorter interval when reachable keeps traffic flowing so the Mac’s network is less likely to drop when display sleeps.
    /// Fetches recent projects from server when no project is selected (for empty-state "Recent" list).
    private func fetchRecentProjects() async {
        guard selectedProject == nil, !host.isEmpty else { return }
        await MainActor.run { loadingRecentProjects = true; recentProjectsError = nil }
        defer { Task { @MainActor in loadingRecentProjects = false } }
        do {
            let list = try await CompanionAPI.fetchProjects(host: host, port: portInt)
            await MainActor.run {
                if selectedProject == nil {
                    recentProjects = list
                    recentProjectsError = nil
                }
            }
        } catch {
            await MainActor.run {
                if selectedProject == nil {
                    recentProjects = []
                    recentProjectsError = error.localizedDescription
                }
            }
        }
    }

    /// Opens a recent project: tells server to open in Cursor and selects it in the app.
    private func openRecentProject(_ project: ProjectEntry) {
        selectedProject = project
        messages = []
        Task {
            try? await CompanionAPI.openProject(path: project.path, host: host, port: portInt)
        }
    }

    /// Polls /health. When unreachable, sets serverReachable = false and retries every 5s until reachable again.
    /// Shorter interval when reachable keeps traffic flowing so the Mac's network is less likely to drop when display sleeps.
    private func connectionMonitorLoop() async {
        guard !host.isEmpty else { return }
        let intervalReachable: UInt64 = 12_000_000_000   // 12s when connected (keeps connection active)
        let intervalReconnecting: UInt64 = 5_000_000_000 // 5s when reconnecting
        while !Task.isCancelled {
            let ok = await CompanionAPI.health(host: host, port: portInt)
            await MainActor.run {
                serverReachable = ok
            }
            let interval = ok ? intervalReachable : intervalReconnecting
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    private func triggerBuild() {
        guard !host.isEmpty, !isBuilding, !isUploadingTestFlight else { return }
        isBuilding = true
        buildAlertTitle = "Build"
        Task {
            do {
                let result = try await CompanionAPI.buildXcode(host: host, port: portInt)
                await MainActor.run {
                    isBuilding = false
                    if result.success {
                        buildAlertMessage = "Built and installed on your device."
                    } else {
                        buildAlertMessage = (result.error.isEmpty ? "Build or install failed." : result.error)
                            + (result.output.isEmpty ? "" : "\n\n\(String(result.output.suffix(2000)))")
                    }
                    showBuildAlert = true
                }
            } catch {
                await MainActor.run {
                    isBuilding = false
                    buildAlertMessage = "Could not reach Mac: \(error.localizedDescription)\n\nIn Settings, set Host to your Mac’s IP (e.g. 192.168.1.x). iPhone and Mac must be on the same Wi‑Fi."
                    showBuildAlert = true
                }
            }
        }
    }

    private func triggerTestFlightUpload() {
        guard !host.isEmpty, !isBuilding, !isUploadingTestFlight else { return }
        isUploadingTestFlight = true
        buildAlertTitle = "TestFlight"
        Task {
            do {
                let result = try await CompanionAPI.buildAndUploadTestFlight(host: host, port: portInt)
                await MainActor.run {
                    isUploadingTestFlight = false
                    if result.success {
                        AppDelegate.notifyTestFlightUploadComplete(buildNumber: result.buildNumber)
                        let buildLabel = (result.buildNumber.map { "Build \($0) " } ?? "")
                        buildAlertMessage = "\(buildLabel)uploaded to App Store Connect.\n\nWhere to see it: App Store Connect → Your App → TestFlight. Processing usually takes 5–30 minutes; if it’s not there, check the Activity tab.\n\nStill don't see it? (1) App Store Connect → Apps must have an app with bundle ID com.cursorconnector.app — create it if missing. (2) Use the same Apple ID as in ~/.cursor-connector-testflight on your Mac. (3) Check Activity (bell icon) for processing errors."
                    } else {
                        let main = result.error.isEmpty ? "Archive, export, or upload failed." : result.error
                        let detail = result.output.isEmpty ? "" : String(result.output.suffix(400))
                        let detailTrimmed = detail.contains("\n") ? detail.split(separator: "\n").suffix(6).joined(separator: "\n") : detail
                        buildAlertMessage = main + (detailTrimmed.isEmpty ? "" : "\n\nDetails:\n\(detailTrimmed)")
                    }
                    showBuildAlert = true
                }
            } catch {
                await MainActor.run {
                    isUploadingTestFlight = false
                    buildAlertMessage = "Could not reach Mac: \(error.localizedDescription)\n\nCheck Host in Settings (e.g. Tailscale IP when away from Wi‑Fi).\n\nIf the request timed out: the upload may still have completed on your Mac. Check App Store Connect → your app → TestFlight after 10–30 minutes."
                    showBuildAlert = true
                }
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 24) {
                if !host.isEmpty {
                    recentProjectsSection
                }
                VStack(spacing: 20) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("Connect to your Mac")
                        .font(.title2)
                        .fontWeight(.medium)
                    Text("Open Settings to choose your Mac’s host and a project. Then you can chat with Cursor and browse files.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        showConfig = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 24)
            }
            .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var recentProjectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent")
                .font(.headline)
                .foregroundStyle(.secondary)
            if loadingRecentProjects {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Loading projects…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else if let err = recentProjectsError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if recentProjects.isEmpty {
                Text("No recent projects. Add host in Settings and tap Refresh, or add ~/.cursor-connector-projects.json on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentProjects) { project in
                        Button {
                            openRecentProject(project)
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
                                        .lineLimit(1)
                                    Text(project.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(white: 0.22))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 20)
    }
}

/// Toolbar button with icon above label for consistent sizing.
private struct ToolbarButtonContent: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 22))
            Text(title)
                .font(.caption2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    ContentView()
}
