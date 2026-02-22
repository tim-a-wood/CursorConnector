import SwiftUI

struct ContentView: View {
    @AppStorage("cursorConnectorHost") private var host = ""
    @AppStorage("cursorConnectorPort") private var port = "9283"
    @State private var selectedProject: ProjectEntry?
    @State private var messages: [ChatMessage] = []
    @State private var showConfig = false
    @State private var isBuilding = false
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
            .alert("Build", isPresented: $showBuildAlert) {
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
        HStack(spacing: 16) {
            if let project = project {
                NavigationLink {
                    FileBrowserView(projectPath: project.path, host: host, port: portInt)
                } label: {
                    Label("Files", systemImage: "folder")
                }
                NavigationLink {
                    GitView(projectPath: project.path, host: host, port: portInt)
                } label: {
                    Label("Git", systemImage: "vault")
                }
            }
            Spacer()
            Button {
                triggerBuild()
            } label: {
                if isBuilding {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Label("Build", systemImage: "hammer")
                }
            }
            .disabled(isBuilding || host.isEmpty)
            Button {
                showConfig = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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
        guard !host.isEmpty, !isBuilding else { return }
        isBuilding = true
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

#Preview {
    ContentView()
}
