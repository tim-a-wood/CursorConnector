import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// Chat-style conversation with message bubbles and an input bar at the bottom.
struct ChatView: View {
    let project: ProjectEntry
    let host: String
    let port: Int

    @Binding var messages: [ChatMessage]
    @Binding var conversationId: UUID?
    @Binding var conversationSummaries: [ConversationSummary]
    @State private var inputText: String = ""
    @State private var sending = false
    @State private var sendError: String?
    @FocusState private var inputFocused: Bool
    /// Bumped on each stream chunk so we keep scrolling to bottom while responding.
    @StateObject private var streamChunkNotifier = StreamChunkNotifier()
    @State private var attachedImage: Data? = nil
    @State private var selectedPhotoItem: PhotosPickerItem? = nil

    private var canSend: Bool {
        let hasText = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !sending && (hasText || attachedImage != nil)
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
                            Text("Working on it…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .id("bottomThinking")
                    }
                    if !sending, let last = messages.last, last.role == .assistant, !last.content.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Request complete")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .id("bottomComplete")
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
            .onChange(of: streamChunkNotifier.tick) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if sending {
                proxy.scrollTo("bottomThinking", anchor: .bottom)
            } else if let last = messages.last, last.role == .assistant, !last.content.isEmpty {
                proxy.scrollTo("bottomComplete", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1.0 / UIScreen.main.scale)

            if let err = sendError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
            if let imageData = attachedImage, let uiImage = UIImage(data: imageData) {
                HStack(spacing: 10) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("Image attached")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        attachedImage = nil
                        selectedPhotoItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Remove attachment")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }

            // Left: utility buttons. Right: one compose bubble (text + send) for clear hierarchy.
            HStack(alignment: .bottom, spacing: 10) {
                inputBarUtilityButtons
                composeBubble
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(.systemGroupedBackground))
    }

    /// Attach and keyboard toggle — grouped on the left so the compose bubble is the main focus.
    private var inputBarUtilityButtons: some View {
        HStack(spacing: 4) {
            PhotosPicker(
                selection: $selectedPhotoItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                Task {
                    guard let newItem = newItem else {
                        attachedImage = nil
                        return
                    }
                    if let loaded = try? await newItem.loadTransferable(type: ImageDataTransfer.self) {
                        attachedImage = loaded.data
                    }
                }
            }
            .accessibilityLabel("Attach photo or screenshot")

            Button {
                inputFocused.toggle()
            } label: {
                Image(systemName: inputFocused ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(inputFocused ? "Hide keyboard" : "Show keyboard")
        }
    }

    /// Single bubble: text field + send. Primary action is clearly one unit.
    private var composeBubble: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Message Cursor…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .padding(.vertical, 10)
                .lineLimit(1...6)
                .focused($inputFocused)
                .frame(minHeight: 44)
                .layoutPriority(1)

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(canSend ? Color.accentColor : Color(.tertiaryLabel))
            }
            .frame(width: 36, height: 36)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageToSend = attachedImage
        guard !text.isEmpty || imageToSend != nil else { return }
        inputText = ""
        attachedImage = nil
        selectedPhotoItem = nil
        sendError = nil
        inputFocused = false

        // Create a new conversation if this is the first message in an unsaved chat.
        if conversationId == nil {
            let conv = ConversationStore.shared.createConversation(projectPath: project.path, messages: [])
            conversationId = conv.id
            conversationSummaries = ConversationStore.shared.loadConversationSummaries(projectPath: project.path)
        }

        let displayContent = text.isEmpty ? "Screenshot" : text
        let userMsg = ChatMessage(role: .user, content: displayContent, imageData: imageToSend)
        messages.append(userMsg)

        sending = true
        let assistantMsgId = UUID()
        messages.append(ChatMessage(id: assistantMsgId, role: .assistant, content: ""))
        var currentAssistantMsgId = assistantMsgId

        let backgroundTask = BackgroundTaskHolder()
        backgroundTask.begin()

        // Include prior messages so the agent has context when continuing a chat.
        let history = messages.dropLast(2)
        let newUserContent = text.isEmpty ? "See the attached screenshot(s) above." : text
        let promptForAgent: String
        if history.isEmpty {
            promptForAgent = newUserContent
        } else {
            let historyBlock = history.map { msg in
                let label = msg.role == .user ? "User" : "Assistant"
                return "\(label): \(msg.content)"
            }.joined(separator: "\n\n")
            promptForAgent = "Previous conversation:\n\n\(historyBlock)\n\nUser: \(newUserContent)"
        }
        let imageBase64: [String]? = imageToSend.map { [$0.base64EncodedString()] }

        // Use streaming so we get live thinking and response text; background URLSession upload task continues when app is suspended.
        CompanionAPI.sendPromptStream(
            path: project.path,
            prompt: promptForAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "See the attached screenshot(s) above." : promptForAgent,
            host: host,
            port: port,
            imageBase64: imageBase64,
            streamThinking: true,
            onChunk: { [messages, streamChunkNotifier] chunk in
                Task { @MainActor in
                    if let idx = messages.firstIndex(where: { $0.id == currentAssistantMsgId }) {
                        self.messages[idx].content += chunk
                    }
                    streamChunkNotifier.bump()
                }
            },
            onThinkingChunk: { [messages, streamChunkNotifier] chunk in
                Task { @MainActor in
                    if let idx = messages.firstIndex(where: { $0.id == currentAssistantMsgId }) {
                        self.messages[idx].thinking += chunk
                    }
                    streamChunkNotifier.bump()
                }
            },
            onComplete: { error in
                backgroundTask.end()
                Task { @MainActor in
                    if let idx = messages.firstIndex(where: { $0.id == currentAssistantMsgId }) {
                        if let err = error {
                            let isCancelled = AppDelegate.isCancelledError(err)
                            if !isCancelled {
                                messages[idx].content += "\n\nError: \(err.localizedDescription)"
                                sendError = err.localizedDescription
                            }
                        } else {
                            var content = messages[idx].content
                            if let r = content.range(of: "\n[exit: ") {
                                content = String(content[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            for suffix in ["\nreturn 0", "return 0"] {
                                if content.hasSuffix(suffix) {
                                    content = String(content.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                                    break
                                }
                            }
                            messages[idx].content = content
                        }
                    }
                    sending = false
                    if let cid = conversationId {
                        let title = Conversation.titleFromMessages(messages)
                        ConversationStore.shared.updateConversation(projectPath: project.path, id: cid, messages: messages, title: title)
                        conversationSummaries = ConversationStore.shared.loadConversationSummaries(projectPath: project.path)
                    }
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
                    VStack(alignment: .trailing, spacing: 8) {
                        if let imageData = message.imageData,
                           let uiImage = UIImage(data: imageData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220, maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        if !message.content.isEmpty {
                            Text(message.content)
                                .textSelection(.enabled)
                        }
                    }
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
                                        Text("Working on it…")
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

/// Wrapper so we can load image data from PhotosPickerItem.
private struct ImageDataTransfer: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            ImageDataTransfer(data: data)
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
            ]),
            conversationId: .constant(nil),
            conversationSummaries: .constant([])
        )
    }
}
