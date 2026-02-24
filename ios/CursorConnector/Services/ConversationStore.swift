import Foundation

/// Persists conversations to disk so users can revisit and continue chats.
final class ConversationStore {
    static let shared = ConversationStore()

    private let fileManager = FileManager.default
    private var rootDirectory: URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CursorConnector", isDirectory: true)
            .appendingPathComponent("conversations", isDirectory: true)
    }

    private init() {}

    /// Directory for a project: safe path derived from project path.
    private func directory(forProjectPath projectPath: String) -> URL? {
        guard let root = rootDirectory else { return nil }
        let safe = projectPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8)?
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .prefix(120) ?? "default"
        return root.appendingPathComponent(String(safe), isDirectory: true)
    }

    private func indexURL(forProjectPath projectPath: String) -> URL? {
        directory(forProjectPath: projectPath)?.appendingPathComponent("index.json", isDirectory: false)
    }

    private func conversationURL(projectPath: String, conversationId: UUID) -> URL? {
        directory(forProjectPath: projectPath)?.appendingPathComponent("\(conversationId.uuidString).json", isDirectory: false)
    }

    /// Load list of conversations for a project (metadata only), newest first.
    func loadConversationSummaries(projectPath: String) -> [ConversationSummary] {
        guard let dir = directory(forProjectPath: projectPath),
              fileManager.fileExists(atPath: dir.path) else {
            return []
        }
        let contents = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [ConversationSummary] = []
        for url in contents where url.pathExtension == "json" && url.lastPathComponent != "index.json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url),
                  let stored = try? decoder.decode(StoredConversation.self, from: data) else { continue }
            result.append(ConversationSummary(id: stored.id, projectPath: projectPath, title: stored.title, updatedAt: stored.updatedAt))
        }
        result.sort { $0.updatedAt > $1.updatedAt }
        return result
    }

    /// Load a single conversation by id.
    func loadConversation(projectPath: String, id: UUID) -> Conversation? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let url = conversationURL(projectPath: projectPath, conversationId: id),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let stored = try? decoder.decode(StoredConversation.self, from: data) else {
            return nil
        }
        return Conversation(
            id: stored.id,
            projectPath: projectPath,
            title: stored.title,
            messages: stored.messages,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt
        )
    }

    /// Save a conversation (create or update). Updates index.
    func save(_ conversation: Conversation) {
        guard let dir = directory(forProjectPath: conversation.projectPath),
              let convURL = conversationURL(projectPath: conversation.projectPath, conversationId: conversation.id) else {
            return
        }
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let stored = StoredConversation(
            id: conversation.id,
            title: conversation.title,
            messages: conversation.messages,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard (try? encoder.encode(stored).write(to: convURL)) != nil else { return }
        refreshIndex(projectPath: conversation.projectPath)
    }

    /// Update messages and title for an existing conversation and save.
    func updateConversation(projectPath: String, id: UUID, messages: [ChatMessage], title: String? = nil) {
        let now = Date()
        let existing = loadConversation(projectPath: projectPath, id: id)
        let conv = Conversation(
            id: id,
            projectPath: projectPath,
            title: title ?? existing?.title ?? Conversation.titleFromMessages(messages),
            messages: messages,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        save(conv)
    }

    /// Create a new conversation and save.
    @discardableResult
    func createConversation(projectPath: String, messages: [ChatMessage] = []) -> Conversation {
        let title = Conversation.titleFromMessages(messages)
        let conv = Conversation(projectPath: projectPath, title: title, messages: messages)
        save(conv)
        return conv
    }

    /// Remove a conversation from disk.
    func deleteConversation(projectPath: String, id: UUID) {
        if let url = conversationURL(projectPath: projectPath, conversationId: id) {
            try? fileManager.removeItem(at: url)
        }
        refreshIndex(projectPath: projectPath)
    }

    private struct ConversationIndexEntry: Codable {
        let id: UUID
        let title: String
        let updatedAt: Date
    }

    private struct StoredConversation: Codable {
        let id: UUID
        let title: String
        let messages: [ChatMessage]
        let createdAt: Date
        let updatedAt: Date
    }

    private func refreshIndex(projectPath: String) {
        guard let dir = directory(forProjectPath: projectPath),
              let indexURL = indexURL(forProjectPath: projectPath) else { return }
        let contents = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [ConversationIndexEntry] = []
        for url in contents where url.pathExtension == "json" && url.lastPathComponent != "index.json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url),
                  let stored = try? decoder.decode(StoredConversation.self, from: data) else { continue }
            entries.append(ConversationIndexEntry(id: stored.id, title: stored.title, updatedAt: stored.updatedAt))
        }
        entries.sort { $0.updatedAt > $1.updatedAt }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(entries).write(to: indexURL)
    }
}
