import SwiftUI

/// Chat-style conversation with message bubbles and an input bar at the bottom.
struct ChatView: View {
    let project: ProjectEntry
    let host: String
    let port: Int

    @Binding var messages: [ChatMessage]
    @State private var inputText: String = ""
    @State private var sending = false
    @State private var sendError: String?
    @FocusState private var inputFocused: Bool

    private var canSend: Bool {
        !sending && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            messagesList
            inputBar
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(project.label ?? (project.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { msg in
                        ChatBubbleView(message: msg)
                            .id(msg.id)
                    }
                    if sending, messages.last?.role == .assistant, messages.last?.content.isEmpty == true {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.9)
                            Text("Thinking…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            if let err = sendError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Cursor…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .lineLimit(1...6)
                    .focused($inputFocused)

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(canSend ? Color.accentColor : Color.gray)
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        sendError = nil

        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)

        sending = true
        let assistantMsgId = UUID()
        messages.append(ChatMessage(id: assistantMsgId, role: .assistant, content: ""))

        CompanionAPI.sendPromptStream(
            path: project.path,
            prompt: text,
            host: host,
            port: port,
            onChunk: { chunk in
                Task { @MainActor in
                    if let idx = messages.firstIndex(where: { $0.id == assistantMsgId }) {
                        messages[idx].content += chunk
                    }
                }
            },
            onComplete: { error in
                Task { @MainActor in
                    if let idx = messages.firstIndex(where: { $0.id == assistantMsgId }) {
                        var content = messages[idx].content
                        if let r = content.range(of: "\n[exit: ") {
                            content = String(content[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        messages[idx].content = content
                        if let err = error {
                            messages[idx].content += "\n\nError: \(err.localizedDescription)"
                            sendError = err.localizedDescription
                        }
                    }
                    sending = false
                }
            }
        )
    }
}

/// Single message bubble (user = trailing, assistant = leading).
struct ChatBubbleView: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 48) }
            if !isUser {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Group {
                if isUser {
                    Text(message.content)
                        .textSelection(.enabled)
                } else {
                    StructuredAgentOutputView(output: message.content)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isUser ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 520 : .infinity, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 48) }
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(
            project: ProjectEntry(path: "/tmp", label: "Sample"),
            host: "localhost",
            port: 9283,
            messages: .constant([
                ChatMessage(role: .user, content: "Hello"),
                ChatMessage(role: .assistant, content: "Hi! How can I help?")
            ])
        )
    }
}
