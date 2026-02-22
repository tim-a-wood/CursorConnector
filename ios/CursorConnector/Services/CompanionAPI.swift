import Foundation

enum CompanionAPI {
    static let defaultPort: Int = 9283

    static func baseURL(host: String, port: Int = defaultPort) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        return components.url
    }

    static func fetchProjects(host: String, port: Int = defaultPort) async throws -> [ProjectEntry] {
        guard let base = baseURL(host: host, port: port) else {
            throw URLError(.badURL)
        }
        let url = base.appendingPathComponent("projects")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([ProjectEntry].self, from: data)
    }

    static func openProject(path: String, host: String, port: Int = defaultPort) async throws {
        guard let base = baseURL(host: host, port: port) else {
            throw URLError(.badURL)
        }
        let url = base.appendingPathComponent("projects/open")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["path": path])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    struct PromptResponse: Codable {
        var output: String
        var exitCode: Int
    }

    static func sendPrompt(path: String, prompt: String, host: String, port: Int = defaultPort) async throws -> PromptResponse {
        guard let base = baseURL(host: host, port: port) else {
            throw URLError(.badURL)
        }
        let url = base.appendingPathComponent("prompt")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["path": path, "prompt": prompt])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            if let body = String(data: data, encoding: .utf8), !body.isEmpty {
                throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
            }
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(PromptResponse.self, from: data)
    }

    /// Asks the Companion to exit. Only useful when the Companion is run under a restarter (e.g. while true; do swift run; sleep 2; done).
    static func restartServer(host: String, port: Int = defaultPort) async throws {
        guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
        let url = base.appendingPathComponent("restart")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    static func health(host: String, port: Int = defaultPort) async -> Bool {
        guard let base = baseURL(host: host, port: port) else { return false }
        let url = base.appendingPathComponent("health")
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Phase 3: File browser

    struct FileTreeEntry: Codable, Identifiable {
        var name: String
        var path: String
        var isDirectory: Bool
        var id: String { path }
    }

    struct FileTreeResponse: Codable {
        var entries: [FileTreeEntry]
    }

    struct FileContentResponse: Codable {
        var content: String?
        var binary: Bool
    }

    static func fetchFileTree(path: String, host: String, port: Int = defaultPort) async throws -> [FileTreeEntry] {
        guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
        var components = URLComponents(url: base.appendingPathComponent("files/tree"), resolvingAgainstBaseURL: false)!
        let normalizedPath = (path as NSString).standardizingPath.trimmingCharacters(in: .whitespacesAndNewlines)
        components.queryItems = [URLQueryItem(name: "path", value: normalizedPath)]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let body = (data.isEmpty ? nil : String(data: data, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
        let decoded = try JSONDecoder().decode(FileTreeResponse.self, from: data)
        return decoded.entries
    }

    static func fetchFileContent(path: String, host: String, port: Int = defaultPort) async throws -> FileContentResponse {
        guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
        var components = URLComponents(url: base.appendingPathComponent("files/content"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let body = (data.isEmpty ? nil : String(data: data, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
        return try JSONDecoder().decode(FileContentResponse.self, from: data)
    }

    static func saveFileContent(path: String, content: String, host: String, port: Int = defaultPort) async throws {
        guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
        let url = base.appendingPathComponent("files/content")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(FileWriteRequest(path: path, content: content))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let body = (data.isEmpty ? nil : String(data: data, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
    }

    struct FileWriteRequest: Codable {
        var path: String
        var content: String
    }
}
