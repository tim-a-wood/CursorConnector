import SwiftUI

struct ContentView: View {
    @AppStorage("cursorConnectorHost") private var host = ""
    @AppStorage("cursorConnectorPort") private var port = "9283"
    @State private var selectedProject: ProjectEntry?
    @State private var messages: [ChatMessage] = []
    @State private var showConfig = false

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
