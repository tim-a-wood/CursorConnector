import Foundation

/// Lightweight summary for the conversation list (no messages).
struct ConversationSummary: Identifiable, Equatable {
    var id: UUID
    var projectPath: String
    var title: String
    var updatedAt: Date
}

/// A saved chat session for a project. Can be revisited and continued.
struct Conversation: Identifiable, Equatable {
    var id: UUID
    var projectPath: String
    /// Display title, e.g. first user message or "New chat".
    var title: String
    var messages: [ChatMessage]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), projectPath: String, title: String, messages: [ChatMessage], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.projectPath = projectPath
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Title for display: first line of first user message, or fallback.
    static func titleFromMessages(_ messages: [ChatMessage]) -> String {
        let firstUser = messages.first { $0.role == .user }
        guard let content = firstUser?.content, !content.isEmpty else { return "New chat" }
        let firstLine = content.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? content
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "New chat" : String(trimmed.prefix(60))
    }
}
