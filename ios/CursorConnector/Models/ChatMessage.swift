import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Equatable {
    var id: UUID = UUID()
    var role: ChatRole
    var content: String
    /// Streamed "thought process" when using stream-json (like Cursor’s thinking/reasoning).
    var thinking: String = ""
}
