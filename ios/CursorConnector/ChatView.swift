import SwiftUI
import UIKit

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
    /// Incremented on each stream chunk so we keep scrolling to bottom while responding.
    @State private var scrollTrigger: Int = 0

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
                        ChatBubbleView(
                            message: msg,
                            isStreaming: sending && messages.last?.id == msg.id && msg.role == .assistant
                        )
                            .id(msg.id)
                    }
                    if sending {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.9)
                            Text("Thinking…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .id("bottomThinking")
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: sending) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: scrollTrigger) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if sending {
                proxy.scrollTo("bottomThinking", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
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
            HStack(alignment: .center, spacing: 10) {
                TextField("Message Cursor…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .lineLimit(1...6)
                    .focused($inputFocused)

                Button {
                    inputFocused.toggle()
                } label: {
                    Image(systemName: inputFocused ? "keyboard.chevron.compact.down" : "keyboard")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(inputFocused ? "Hide keyboard" : "Show keyboard")

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
        inputFocused = false

        let userMsg = ChatMessage(role: .user, content: text)
        messages.append(userMsg)

        sending = true
        let assistantMsgId = UUID()
        messages.append(ChatMessage(id: assistantMsgId, role: .assistant, content: ""))
        var currentAssistantMsgId = assistantMsgId

        let backgroundTask = BackgroundTaskHolder()
        backgroundTask.begin()

        var hasStrippedPrompt = false
        var lastContentChunk = ""
        let trimmedPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines)

        CompanionAPI.sendPromptStream(
            path: project.path,
            prompt: text,
            host: host,
            port: port,
            streamThinking: true,
            onChunk: { chunk in
                Task { @MainActor in
                    if let idx = messages.firstIndex(where: { $0.id == currentAssistantMsgId }) {
                        if chunk == lastContentChunk { return }
                        lastContentChunk = chunk
                        let content = messages[idx].content
                        if !content.isEmpty && !content.hasSuffix(" ") && !content.hasSuffix("\n"),
                           !chunk.isEmpty && !chunk.hasPrefix(" ") && !chunk.hasPrefix("\n") {
                            messages[idx].content += " "
                        }
                        messages[idx].content += chunk
                        if !hasStrippedPrompt, !trimmedPrompt.isEmpty {
                            let trimmedContent = messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmedContent.hasPrefix(trimmedPrompt) {
                                let after = String(trimmedContent.dropFirst(trimmedPrompt.count))
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                messages[idx].content = after
                                hasStrippedPrompt = true
                            }
                        }
                        scrollTrigger += 1
                    }
                }
            },
            onThinkingChunk: { chunk in
                Task { @MainActor in
                    if let idx = messages.firstIndex(where: { $0.id == currentAssistantMsgId }) {
                        if !messages[idx].content.isEmpty {
                            // Agent switched back to thinking after already providing output; start a new bubble.
                            let newMsg = ChatMessage(id: UUID(), role: .assistant, content: "", thinking: chunk)
                            messages.append(newMsg)
                            currentAssistantMsgId = newMsg.id
                        } else {
                            messages[idx].thinking += chunk
                        }
                        scrollTrigger += 1
                    }
                }
            },
            onComplete: { error in
                backgroundTask.end()
                Task { @MainActor in
                    if let idx = messages.firstIndex(where: { $0.id == currentAssistantMsgId }) {
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

/// Holds a UIApplication background task so the request can finish when the app is suspended.
private final class BackgroundTaskHolder {
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        taskID = UIApplication.shared.beginBackgroundTask(withName: "Cursor prompt stream") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}

/// Single message bubble (user = trailing, assistant = leading).
struct ChatBubbleView: View {
    let message: ChatMessage
    /// True when this is the assistant message currently being streamed (so we show thought process area even before first chunk).
    var isStreaming: Bool = false

    private var isUser: Bool { message.role == .user }

    /// Show the thought process block when we have content or when we're streaming and waiting for it (real-time feedback).
    private var showThinkingSection: Bool {
        !message.thinking.isEmpty || (isStreaming && !isUser)
    }

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
                    VStack(alignment: .leading, spacing: 12) {
                        if showThinkingSection {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Thought process", systemImage: "brain.head.profile")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                if message.thinking.isEmpty {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                        Text("Thinking…")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    ParagraphFormattedText(
                                        text: message.thinking,
                                        font: .caption,
                                        color: .secondary,
                                        paragraphSpacing: 12,
                                        lineSpacing: 4
                                    )
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        StructuredAgentOutputView(
                            output: message.content,
                            paragraphSpacing: 14,
                            lineSpacing: 6
                        )
                    }
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

/// Renders plain text with paragraph breaks (double newline) and configurable spacing for readability.
private struct ParagraphFormattedText: View {
    let text: String
    var font: Font = .body
    var color: Color = .primary
    var paragraphSpacing: CGFloat = 12
    var lineSpacing: CGFloat = 4

    var body: some View {
        let paragraphs = text.split(separator: "\n\n", omittingEmptySubsequences: true)
        return VStack(alignment: .leading, spacing: paragraphSpacing) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, raw in
                Text(String(raw))
                    .font(font)
                    .foregroundStyle(color)
                    .lineSpacing(lineSpacing)
            }
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
