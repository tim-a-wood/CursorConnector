import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var role: ChatRole
    var content: String
    /// Streamed "thought process" when using stream-json (like Cursor’s thinking/reasoning).
    var thinking: String = ""
    /// Optional image attached by the user (e.g. screenshot) so the agent can see what's on screen.
    var imageData: Data? = nil

    enum CodingKeys: String, CodingKey {
        case id, role, content, thinking, imageData
    }

    init(id: UUID = UUID(), role: ChatRole, content: String, thinking: String = "", imageData: Data? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.imageData = imageData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(ChatRole.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking) ?? ""
        if let b64 = try c.decodeIfPresent(String.self, forKey: .imageData), !b64.isEmpty, let data = Data(base64Encoded: b64) {
            imageData = data
        } else {
            imageData = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encode(thinking, forKey: .thinking)
        try c.encode(imageData?.base64EncodedString(), forKey: .imageData)
    }
}
