import Foundation

struct ProjectEntry: Codable, Identifiable, Equatable {
    var path: String
    var label: String?
    var id: String { path }
}
