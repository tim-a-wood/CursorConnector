import Foundation

struct ProjectEntry: Codable, Identifiable {
    var path: String
    var label: String?
    var id: String { path }
}
