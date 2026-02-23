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
            .task(id: "\(host):\(portInt):\(selectedProject?.path ?? "")") {
                await connectionMonitorLoop()
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
                        buildAlertMessage = "Build uploaded to App Store Connect. In a few minutes it will appear in TestFlight — open TestFlight and tap Update, or use Settings → Open TestFlight to update."
                    } else {
                        buildAlertMessage = (result.error.isEmpty ? "Archive, export, or upload failed." : result.error)
                            + (result.output.isEmpty ? "" : "\n\n\(String(result.output.suffix(2000)))")
                    }
                    showBuildAlert = true
                }
            } catch {
                await MainActor.run {
                    isUploadingTestFlight = false
                    buildAlertMessage = "Could not reach Mac: \(error.localizedDescription)\n\nCheck Host in Settings (e.g. Tailscale IP when away from Wi‑Fi)."
                    showBuildAlert = true
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
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
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
