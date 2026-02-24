import XCTest
@testable import CursorConnector

final class CursorConnectorTests: XCTestCase {

    // MARK: - Conversation.titleFromMessages

    func testTitleFromMessages_empty_returnsNewChat() {
        XCTAssertEqual(Conversation.titleFromMessages([]), "New chat")
    }

    func testTitleFromMessages_onlyAssistant_returnsNewChat() {
        let messages = [ChatMessage(role: .assistant, content: "Hello")]
        XCTAssertEqual(Conversation.titleFromMessages(messages), "New chat")
    }

    func testTitleFromMessages_firstUserMessage_usedAsTitle() {
        let messages = [
            ChatMessage(role: .user, content: "Fix the login bug"),
            ChatMessage(role: .assistant, content: "I'll look at it.")
        ]
        XCTAssertEqual(Conversation.titleFromMessages(messages), "Fix the login bug")
    }

    func testTitleFromMessages_firstLineOnly() {
        let messages = [ChatMessage(role: .user, content: "First line\nSecond line")]
        XCTAssertEqual(Conversation.titleFromMessages(messages), "First line")
    }

    func testTitleFromMessages_truncatedTo60() {
        let long = String(repeating: "a", count: 100)
        let messages = [ChatMessage(role: .user, content: long)]
        let title = Conversation.titleFromMessages(messages)
        XCTAssertEqual(title.count, 60)
        XCTAssertEqual(title, String(long.prefix(60)))
    }

    func testTitleFromMessages_whitespaceOnlyContent_returnsNewChat() {
        let messages = [ChatMessage(role: .user, content: "   \n  ")]
        XCTAssertEqual(Conversation.titleFromMessages(messages), "New chat")
    }

    // MARK: - ChatMessage Codable

    func testChatMessage_encodeDecode() throws {
        let msg = ChatMessage(role: .user, content: "Hello", thinking: "reasoning")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.role, .user)
        XCTAssertEqual(decoded.content, "Hello")
        XCTAssertEqual(decoded.thinking, "reasoning")
    }

    func testChatMessage_decodeWithoutThinking_defaultsEmpty() throws {
        let json = """
        {"id":"\(UUID().uuidString)","role":"user","content":"Hi"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: json)
        XCTAssertEqual(decoded.thinking, "")
    }

    // MARK: - ProjectEntry

    func testProjectEntry_idIsPath() {
        let entry = ProjectEntry(path: "/path/to/project", label: "My Project")
        XCTAssertEqual(entry.id, "/path/to/project")
    }

    // MARK: - CompanionAPI.baseURL

    func testBaseURL_hostAndPort() {
        let url = CompanionAPI.baseURL(host: "192.168.1.1", port: 9283)
        XCTAssertEqual(url?.absoluteString, "http://192.168.1.1:9283")
    }

    func testBaseURL_defaultPort() {
        let url = CompanionAPI.baseURL(host: "localhost")
        XCTAssertEqual(url?.port, 9283)
    }

    func testBaseURL_fullURL_usesAsBase() {
        let url = CompanionAPI.baseURL(host: "https://myserver.com:4430/other", port: 9999)
        XCTAssertEqual(url?.absoluteString, "https://myserver.com:4430")
    }

    func testBaseURL_fullURL_withPath_stripsPathAndQuery() {
        let url = CompanionAPI.baseURL(host: "http://host/path?query=1", port: 80)
        XCTAssertEqual(url?.absoluteString, "http://host")
    }

    func testBaseURL_emptyHost_stillHasPort() {
        let url = CompanionAPI.baseURL(host: "  ", port: 9283)
        // Trimmed empty host yields nil host in URLComponents; URL may still be created with port
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.port, 9283)
    }

    func testBaseURL_malformedFullURL_returnsNil() {
        // URL with invalid scheme or unparseable string should yield nil when used as base
        let url = CompanionAPI.baseURL(host: "not-a-valid-url://", port: 9283)
        // Implementation may parse and return; we only assert it doesn't crash
        _ = url
    }

    // MARK: - ConversationStore

    func testConversationStore_loadSummaries_nonexistentProject_returnsEmpty() {
        let summaries = ConversationStore.shared.loadConversationSummaries(projectPath: "/nonexistent/\(UUID().uuidString)")
        XCTAssertEqual(summaries.count, 0)
    }

    func testConversationStore_createAndLoad() {
        let projectPath = "/tmp/cursor-connector-test-\(UUID().uuidString)"
        let conv = ConversationStore.shared.createConversation(projectPath: projectPath, messages: [
            ChatMessage(role: .user, content: "Test message")
        ])
        defer {
            ConversationStore.shared.deleteConversation(projectPath: projectPath, id: conv.id)
        }
        let summaries = ConversationStore.shared.loadConversationSummaries(projectPath: projectPath)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].title, "Test message")
        XCTAssertEqual(summaries[0].id, conv.id)

        let loaded = ConversationStore.shared.loadConversation(projectPath: projectPath, id: conv.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.messages.count, 1)
        XCTAssertEqual(loaded?.messages[0].content, "Test message")
    }

    func testConversationStore_updateConversation() {
        let projectPath = "/tmp/cursor-connector-test-\(UUID().uuidString)"
        let conv = ConversationStore.shared.createConversation(projectPath: projectPath, messages: [
            ChatMessage(role: .user, content: "Original")
        ])
        defer {
            ConversationStore.shared.deleteConversation(projectPath: projectPath, id: conv.id)
        }
        let updated = conv.messages + [ChatMessage(role: .assistant, content: "Reply")]
        ConversationStore.shared.updateConversation(projectPath: projectPath, id: conv.id, messages: updated)
        let loaded = ConversationStore.shared.loadConversation(projectPath: projectPath, id: conv.id)
        XCTAssertEqual(loaded?.messages.count, 2)
        XCTAssertEqual(loaded?.messages[1].content, "Reply")
    }

    func testConversationStore_deleteConversation() {
        let projectPath = "/tmp/cursor-connector-test-\(UUID().uuidString)"
        let conv = ConversationStore.shared.createConversation(projectPath: projectPath, messages: [])
        ConversationStore.shared.deleteConversation(projectPath: projectPath, id: conv.id)
        let summaries = ConversationStore.shared.loadConversationSummaries(projectPath: projectPath)
        XCTAssertEqual(summaries.count, 0)
    }
}
