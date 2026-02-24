import Foundation

enum CompanionAPI {
    static let defaultPort: Int = 9283
    /// Agent can run up to 20 min on the server; use 25 min so suspend + resume and long runs don't cause spurious timeouts.
    static let promptTimeout: TimeInterval = 1500
    /// Timeout for file and other short requests. Generous so brief app suspend doesn’t cause spurious timeouts.
    static let fileRequestTimeout: TimeInterval = 240

    /// Retries the operation up to twice on timeout or network error (e.g. after app suspend). Use for idempotent requests only.
    private static func withRetry<T>(_ operation: () async throws -> T) async rethrows -> T {
        func isRetryable(_ error: Error) -> Bool {
            let nse = error as NSError
            return nse.domain == NSURLErrorDomain
                && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorCancelled].contains(nse.code)
        }
        do {
            return try await operation()
        } catch {
            guard isRetryable(error) else { throw error }
            do {
                return try await operation()
            } catch {
                guard isRetryable(error) else { throw error }
                return try await operation()
            }
        }
    }

    /// If `host` is a full URL (contains "://"), use it as the base and ignore `port`. Otherwise build http://host:port.
    static func baseURL(host: String, port: Int = defaultPort) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") {
            guard let parsed = URL(string: trimmed),
                  var comp = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else { return nil }
            comp.path = ""
            comp.query = nil
            comp.fragment = nil
            return comp.url
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = trimmed.isEmpty ? nil : trimmed
        components.port = port
        return components.url
    }

    static func fetchProjects(host: String, port: Int = defaultPort) async throws -> [ProjectEntry] {
        try await withRetry {
            guard let base = baseURL(host: host, port: port) else {
                throw URLError(.badURL)
            }
            let url = base.appendingPathComponent("projects")
            var request = URLRequest(url: url)
            request.timeoutInterval = fileRequestTimeout
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return try JSONDecoder().decode([ProjectEntry].self, from: data)
        }
    }

    static func openProject(path: String, host: String, port: Int = defaultPort) async throws {
        try await withRetry {
            guard let base = baseURL(host: host, port: port) else {
                throw URLError(.badURL)
            }
            let url = base.appendingPathComponent("projects/open")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = fileRequestTimeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["path": path])
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
        }
    }

    struct PromptResponse: Codable {
        var output: String
        var exitCode: Int
    }

    static func sendPrompt(path: String, prompt: String, host: String, port: Int = defaultPort) async throws -> PromptResponse {
        try await withRetry {
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
    }

    /// Called by the app delegate when the system delivers background URLSession events. Set and cleared by UIApplicationDelegate.
    static var backgroundSessionCompletionHandler: (() -> Void)?

    /// Streams agent output via Server-Sent Events. Uses a *background* URLSession so the transfer continues when the app is suspended (e.g. user switches apps on another network). Chunks are delivered in real time while in foreground; when returning from background we may receive buffered data and completion.
    /// - Parameter imageBase64: Optional screenshot/image(s) as base64-encoded strings (e.g. PNG). The agent will receive file paths to these images in the project.
    static func sendPromptStream(
        path: String,
        prompt: String,
        host: String,
        port: Int = defaultPort,
        imageBase64: [String]? = nil,
        streamThinking: Bool = true,
        onChunk: @escaping (String) -> Void,
        onThinkingChunk: ((String) -> Void)? = nil,
        onComplete: @escaping (Error?) -> Void
    ) {
        guard let base = baseURL(host: host, port: port) else {
            onComplete(URLError(.badURL))
            return
        }
        var url = base.appendingPathComponent("prompt-stream")
        if streamThinking {
            var comp = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comp.queryItems = [URLQueryItem(name: "stream", value: "json")]
            if let u = comp.url { url = u }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = promptTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            var body: [String: Any] = ["path": path, "prompt": prompt]
            if let images = imageBase64, !images.isEmpty {
                body["images"] = images
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            onComplete(error)
            return
        }
        streamDelegate.setCallbacks(onChunk: onChunk, onThinkingChunk: onThinkingChunk, onComplete: onComplete)
        let task = backgroundURLSession.dataTask(with: request)
        streamDelegate.task = task
        task.resume()
    }

    static let backgroundSessionIdentifier = "com.cursorconnector.prompt-stream"
    private static let streamDelegate = StreamDelegate()
    /// Foreground session so response body is delivered incrementally (continuous feedback). Background sessions buffer until completion.
    /// Timeouts set so agent can think for many minutes and app can suspend without the client timing out (default 60s would fire too soon).
    private static let foregroundURLSession: URLSession = {
        let config = URLSessionConfiguration.default
        let timeout: TimeInterval = 1500  // 25 min between data; survive long suspend or long agent think
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 300  // 30 min total for full response
        return URLSession(configuration: config, delegate: streamDelegate, delegateQueue: nil)
    }()
    private static let backgroundURLSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: backgroundSessionIdentifier)
        config.timeoutIntervalForRequest = 1500   // 25 min between data so suspend doesn't cause timeout
        config.timeoutIntervalForResource = 1800   // 30 min total for full response
        config.waitsForConnectivity = true       // when app resumes, wait for network instead of failing
        config.isDiscretionary = false           // run transfer immediately; don’t defer (e.g. on Wi‑Fi only)
        return URLSession(configuration: config, delegate: streamDelegate, delegateQueue: nil)
    }()

    /// Asks the Companion to exit. Only useful when the Companion is run under a restarter (e.g. while true; do swift run; sleep 2; done).
    static func restartServer(host: String, port: Int = defaultPort) async throws {
        guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
        let url = base.appendingPathComponent("restart")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = fileRequestTimeout
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    static func health(host: String, port: Int = defaultPort) async -> Bool {
        guard let base = baseURL(host: host, port: port) else { return false }
        let url = base.appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.timeoutInterval = fileRequestTimeout
        do {
            let (_, response) = try await withRetry { try await URLSession.shared.data(for: request) }
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
        try await withRetry {
            guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
            var components = URLComponents(url: base.appendingPathComponent("files/tree"), resolvingAgainstBaseURL: false)!
            let normalizedPath = (path as NSString).standardizingPath.trimmingCharacters(in: .whitespacesAndNewlines)
            components.queryItems = [URLQueryItem(name: "path", value: normalizedPath)]
            guard let url = components.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.timeoutInterval = fileRequestTimeout
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else {
                let body = (data.isEmpty ? nil : String(data: data, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
                throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
            }
            let decoded = try JSONDecoder().decode(FileTreeResponse.self, from: data)
            return decoded.entries
        }
    }

    static func fetchFileContent(path: String, host: String, port: Int = defaultPort) async throws -> FileContentResponse {
        try await withRetry {
            guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
            var components = URLComponents(url: base.appendingPathComponent("files/content"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            guard let url = components.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.timeoutInterval = fileRequestTimeout
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else {
                let body = (data.isEmpty ? nil : String(data: data, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
                throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
            }
            return try JSONDecoder().decode(FileContentResponse.self, from: data)
        }
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

    struct GitChangeEntry: Codable, Identifiable, Hashable {
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
        try await withRetry {
            guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
            var components = URLComponents(url: base.appendingPathComponent("git/status"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            guard let url = components.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.timeoutInterval = fileRequestTimeout
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else {
                let body = (data.isEmpty ? nil : String(data: data, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
                throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
            }
            return try JSONDecoder().decode(GitStatusResponse.self, from: data)
        }
    }

    struct GitDiffRequest: Codable {
        var path: String
        var file: String
    }

    struct GitDiffResponse: Codable {
        var diff: String
    }

    static func fetchGitDiff(path: String, file: String, host: String, port: Int = defaultPort) async throws -> String {
        try await withRetry {
            guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
            let url = base.appendingPathComponent("api").appendingPathComponent("git-diff")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = fileRequestTimeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(GitDiffRequest(path: path, file: file))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else {
                let body = (data.isEmpty ? nil : String(data: data, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
                throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
            }
            let decoded = try JSONDecoder().decode(GitDiffResponse.self, from: data)
            return decoded.diff
        }
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

    // MARK: - GitHub Actions

    struct GitHubActionsRun: Codable, Identifiable {
        var id: Int
        var name: String
        var status: String
        var conclusion: String?
        var createdAt: String
        var htmlUrl: String
        var headBranch: String
        enum CodingKeys: String, CodingKey {
            case id, name, status, conclusion
            case createdAt = "created_at"
            case htmlUrl = "html_url"
            case headBranch = "head_branch"
        }
    }

    struct GitHubActionsResponse: Codable {
        var runs: [GitHubActionsRun]
        var error: String?
    }

    static func fetchGitHubActions(path: String, host: String, port: Int = defaultPort) async throws -> GitHubActionsResponse {
        try await withRetry {
            guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
            var components = URLComponents(url: base.appendingPathComponent("github/actions"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "path", value: path)]
            guard let url = components.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.timeoutInterval = fileRequestTimeout
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else {
                let body = (data.isEmpty ? nil : String(data: data, encoding: .utf8)) ?? "HTTP \(http.statusCode)"
                throw NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
            }
            return try JSONDecoder().decode(GitHubActionsResponse.self, from: data)
        }
    }

    // MARK: - Xcode build

    static let buildTimeout: TimeInterval = 330

    struct XcodeBuildResponse: Codable {
        var success: Bool
        var output: String
        var error: String
        var buildNumber: String?
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

    /// Builds an archive on the Mac, exports IPA, and uploads to App Store Connect (TestFlight). No device required. Use when on Tailscale.
    static let buildTestFlightTimeout: TimeInterval = 620

    static func buildAndUploadTestFlight(repoPath: String? = nil, host: String, port: Int = defaultPort) async throws -> XcodeBuildResponse {
        guard let base = baseURL(host: host, port: port) else { throw URLError(.badURL) }
        let url = base.appendingPathComponent("xcode-build-testflight")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = buildTestFlightTimeout
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
    private var onChunk: ((String) -> Void)?
    private var onThinkingChunk: ((String) -> Void)?
    private var onComplete: ((Error?) -> Void)?
    weak var task: URLSessionDataTask?

    func setCallbacks(onChunk: @escaping (String) -> Void, onThinkingChunk: ((String) -> Void)? = nil, onComplete: @escaping (Error?) -> Void) {
        self.onChunk = onChunk
        self.onThinkingChunk = onThinkingChunk
        self.onComplete = onComplete
    }

    private func clearCallbacks() {
        onChunk = nil
        onThinkingChunk = nil
        onComplete = nil
    }

    private func processSSEEvent(_ eventBlock: String) {
        let lines = eventBlock.split(separator: "\n", omittingEmptySubsequences: false)
        var eventType: String?
        var payload = ""
        for line in lines {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("event: ") {
                eventType = String(s.dropFirst(7))
            } else if s.hasPrefix("data: ") {
                payload += (payload.isEmpty ? "" : "\n") + String(s.dropFirst(6))
            }
        }
        guard !payload.isEmpty else { return }
        let block = eventType == "thinking" ? onThinkingChunk : onChunk
        if let block = block {
            DispatchQueue.main.async { block(payload) }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let str = String(data: data, encoding: .utf8) else { return }
        buffer += str
        while let range = buffer.range(of: "\n\n") {
            let eventBlock = String(buffer[..<range.lowerBound])
            buffer = String(buffer[range.upperBound...])
            processSSEEvent(eventBlock)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !buffer.isEmpty {
            let lines = buffer.split(separator: "\n", omittingEmptySubsequences: false)
            var eventType: String?
            var payload = ""
            for line in lines {
                let s = String(line).trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("event: ") {
                    eventType = String(s.dropFirst(7))
                } else if s.hasPrefix("data: ") {
                    payload += (payload.isEmpty ? "" : "\n") + String(s.dropFirst(6))
                }
            }
            if !payload.isEmpty {
                let block = eventType == "thinking" ? onThinkingChunk : onChunk
                if let block = block {
                    DispatchQueue.main.async { block(payload) }
                }
            }
        }
        if let onComplete = onComplete {
            DispatchQueue.main.async { onComplete(error) }
        }
        clearCallbacks()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            if let onComplete = onComplete {
                DispatchQueue.main.async { onComplete(URLError(.badServerResponse)) }
            }
            clearCallbacks()
            return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            if let onComplete = onComplete {
                DispatchQueue.main.async { onComplete(NSError(domain: "CompanionAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])) }
            }
            clearCallbacks()
            return
        }
        completionHandler(.allow)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            CompanionAPI.backgroundSessionCompletionHandler?()
            CompanionAPI.backgroundSessionCompletionHandler = nil
        }
    }
}
