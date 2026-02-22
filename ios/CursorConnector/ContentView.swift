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

    private var portInt: Int { Int(port) ?? CompanionAPI.defaultPort }

    var body: some View {
        NavigationStack {
            Group {
                if let project = selectedProject {
                    ChatView(project: project, host: host, port: portInt, messages: $messages)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                NavigationLink {
                                    FileBrowserView(projectPath: project.path, host: host, port: portInt)
                                } label: {
                                    Label("Files", systemImage: "folder")
                                }
                            }
                            ToolbarItem(placement: .topBarLeading) {
                                NavigationLink {
                                    GitView(projectPath: project.path, host: host, port: portInt)
                                } label: {
                                    Label("Git", systemImage: "vault")
                                }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
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
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    showConfig = true
                                } label: {
                                    Label("Settings", systemImage: "gearshape")
                                }
                            }
                        }
                } else {
                    emptyState
                }
            }
            .navigationTitle(selectedProject != nil ? (selectedProject!.label ?? (selectedProject!.path as NSString).lastPathComponent) : "Cursor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if selectedProject == nil {
                    ToolbarItem(placement: .topBarTrailing) {
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
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showConfig = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
            }
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
                    buildAlertMessage = error.localizedDescription
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
