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
    /// Optional image attached by the user (e.g. screenshot) so the agent can see what's on screen.
    var imageData: Data? = nil
}
