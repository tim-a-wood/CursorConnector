import Foundation

enum CompanionAPI {
    static let defaultPort: Int = 9283
    /// Agent can run up to 5 min on the server; wait slightly longer so we get the response.
    static let promptTimeout: TimeInterval = 320
    static let fileRequestTimeout: TimeInterval = 30

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
        request.timeoutInterval = promptTimeout
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

    /// Streams agent output via Server-Sent Events. Calls onChunk with each text payload; onComplete when done (error nil or set).
    static func sendPromptStream(
        path: String,
        prompt: String,
        host: String,
        port: Int = defaultPort,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Error?) -> Void
    ) {
        guard let base = baseURL(host: host, port: port) else {
            onComplete(URLError(.badURL))
            return
        }
        let url = base.appendingPathComponent("prompt-stream")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = promptTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(["path": path, "prompt": prompt])
        } catch {
            onComplete(error)
            return
        }
        let delegate = StreamDelegate(onChunk: onChunk, onComplete: onComplete)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        delegate.task = task
        task.resume()
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
        request.timeoutInterval = fileRequestTimeout
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

    // MARK: - Git

    struct GitChangeEntry: Codable, Identifiable {
        var status: String
        var path: String
        var id: String { path }
    }

    struct GitStatusResponse: Codable {
        var branch: String
        var changes: [GitChangeEntry]
    }

    struct GitGenerateMessageResponse: Codable {
        var message: String
    }

    struct GitCommandResponse: Codable {
        var success: Bool
        var output: String
        var error: String
    }

    static func fetchGitStatus(path: String, host: String, port: Int = defaultPort) async throws -> GitStatusResponse {
        guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
        var components = URLComponents(url: base.appendingPathComponent("git/status"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let body = (data.isEmpty ? nil : String(data: data, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
        return try JSONDecoder().decode(GitStatusResponse.self, from: data)
    }

    static func generateCommitMessage(path: String, host: String, port: Int = defaultPort) async throws -> String {
        guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
        let url = base.appendingPathComponent("git/generate-message")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["path": path])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let body = (data.isEmpty ? nil : String(data: data, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
        let decoded = try JSONDecoder().decode(GitGenerateMessageResponse.self, from: data)
        return decoded.message
    }

    static func gitCommit(path: String, message: String, host: String, port: Int = defaultPort) async throws -> GitCommandResponse {
        guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
        let url = base.appendingPathComponent("git/commit")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["path": path, "message": message])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let body = (data.isEmpty ? nil : String(data: data, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
        return try JSONDecoder().decode(GitCommandResponse.self, from: data)
    }

    static func gitPush(path: String, host: String, port: Int = defaultPort) async throws -> GitCommandResponse {
        guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
        let url = base.appendingPathComponent("git/push")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["path": path])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let body = (data.isEmpty ? nil : String(data: data, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
        return try JSONDecoder().decode(GitCommandResponse.self, from: data)
    }

    // MARK: - Xcode build

    static let buildTimeout: TimeInterval = 330

    struct XcodeBuildResponse: Codable {
        var success: Bool
        var output: String
        var error: String
    }

    /// Triggers a build of the CursorConnector iOS app on the Mac and installs to the first connected device.
    static func buildXcode(repoPath: String? = nil, host: String, port: Int = defaultPort) async throws -> XcodeBuildResponse {
        guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
        let url = base.appendingPathComponent("xcode-build")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = buildTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(XcodeBuildRequest(repoPath: repoPath))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let body = (data.isEmpty ? nil : String(data: data, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }
        return try JSONDecoder().decode(XcodeBuildResponse.self, from: data)
    }
}

private struct XcodeBuildRequest: Codable {
    var repoPath: String?
}

// MARK: - Streaming delegate

private class StreamDelegate: NSObject, URLSessionDataDelegate {
    private var buffer = ""
    private let onChunk: (String) -> Void
    private let onComplete: (Error?) -> Void
    weak var task: URLSessionDataTask?

    init(onChunk: @escaping (String) -> Void, onComplete: @escaping (Error?) -> Void) {
        self.onChunk = onChunk
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let str = String(data: data, encoding: .utf8) else { return }
        buffer += str
        while let range = buffer.range(of: "\n\n") {
            let event = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            let lines = event.split(separator: "\n", omittingEmptySubsequences: false)
            var payload = ""
            for line in lines {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("data: ") {
                    payload += (payload.isEmpty ? "" : "\n") + String(s.dropFirst(6))
                }
            }
            if !payload.isEmpty {
                onChunk(payload)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !buffer.isEmpty {
            let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)
            var payload = ""
            for line in lines {
                let s = String(line).trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("data: ") {
                    payload += (payload.isEmpty ? "" : "\n") + String(s.dropFirst(6))
                }
            }
            if !payload.isEmpty { onChunk(payload) }
        }
        session.finishTasksAndInvalidate()
        onComplete(error)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            onComplete(URLError(.badServerResponse))
            return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            onComplete(NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
            return
        }
        completionHandler(.allow)
    }
}
