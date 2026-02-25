import Foundation
import IOKit.pwr_mgt
import Swifter

// MARK: - Cursor recent workspaces

let cursorStateDBPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    .path
let fallbackProjectsPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cursor-connector-projects.json")
    .path

struct ProjectEntry: Codable {
    var path: String
    var label: String?
}

func folderPath(fromUri uri: String) -> String? {
    if uri.hasPrefix("file://") {
        return String(uri.dropFirst("file://".count)).removingPercentEncoding
    }
    return uri.removingPercentEncoding
}

func loadProjectsFromCursorDB() -> [ProjectEntry]? {
    guard FileManager.default.fileExists(atPath: cursorStateDBPath) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [cursorStateDBPath, "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList';"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return nil }
        var result: [ProjectEntry] = []
        for entry in entries {
            if let folderUri = entry["folderUri"] as? String, let path = folderPath(fromUri: folderUri) {
                let label = entry["label"] as? String ?? (path as NSString).lastPathComponent
                result.append(ProjectEntry(path: path, label: label))
            }
        }
        return result.isEmpty ? nil : result
    } catch {
        return nil
    }
}

func loadProjectsFromFallbackJSON() -> [ProjectEntry]? {
    guard FileManager.default.fileExists(atPath: fallbackProjectsPath),
          let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackProjectsPath)) else { return nil }
    if let arr = try? JSONSerialization.jsonObject(with: data) as? [String], !arr.isEmpty {
        return arr.map { ProjectEntry(path: $0, label: ($0 as NSString).lastPathComponent) }
    }
    if let decoded = try? JSONDecoder().decode([ProjectEntry].self, from: data), !decoded.isEmpty {
        return decoded
    }
    return nil
}

func loadProjects() -> [ProjectEntry] {
    loadProjectsFromCursorDB() ?? loadProjectsFromFallbackJSON() ?? []
}

func openProject(path: String) -> Bool {
    guard !path.isEmpty, path.hasPrefix("/") else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["cursor", path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

// MARK: - Agent prompt (Phase 2)

struct PromptRequest: Codable {
    var path: String
    var prompt: String
    /// Optional screenshot(s) as base64-encoded image data. Saved under project's .cursor/connector-screenshots/ and paths are prepended to the prompt so the agent can see them.
    var images: [String]?
    /// AI model ID for the Cursor agent (e.g. "auto", "claude-sonnet-4"). Defaults to "auto" when missing.
    var model: String?
}

struct PromptResponse: Codable {
    var output: String
    var exitCode: Int
}

/// If `images` (base64) are provided, writes them under projectPath/.cursor/connector-screenshots/ and returns a prompt that includes the file paths so the agent can view the screenshots. Otherwise returns the original prompt.
private func promptWithSavedScreenshots(projectPath: String, prompt: String, images: [String]?) -> String {
    guard let images = images, !images.isEmpty else { return prompt }
    let screenshotsDir = (projectPath as NSString).appendingPathComponent(".cursor/connector-screenshots")
    var isDir: ObjCBool = false
    if !FileManager.default.fileExists(atPath: screenshotsDir, isDirectory: &isDir) || !isDir.boolValue {
        try? FileManager.default.createDirectory(atPath: screenshotsDir, withIntermediateDirectories: true)
    }
    var paths: [String] = []
    for base64 in images {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { continue }
        let name = "screenshot-\(UUID().uuidString).png"
        let filePath = (screenshotsDir as NSString).appendingPathComponent(name)
        guard (try? data.write(to: URL(fileURLWithPath: filePath))) != nil else { continue }
        paths.append(filePath)
    }
    guard !paths.isEmpty else { return prompt }
    let pathList = paths.map { "- \($0)" }.joined(separator: "\n")
    let header = "The user attached the following screenshot(s). You can view them at:\n\(pathList)\n\n"
    return header + (prompt.isEmpty ? "See the attached screenshot(s) above." : prompt)
}

/// Long agent runs (multi-step tasks, large codebases) can exceed 5 min. Use 20 min so requests don't time out under normal use.
let agentTimeoutSeconds: TimeInterval = 1200
let agentMaxOutputBytes = 1_000_000

/// Prefer full path so we don't rely on PATH (e.g. when Companion is launched by Cursor/background).
private var agentExecutablePath: String? {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/agent")
        .path
    return FileManager.default.fileExists(atPath: path) ? path : nil
}

/// API key for Cursor Agent CLI. Read from ~/.cursor-connector-api-key (first line). Also pass through CURSOR_API_KEY / CURSOR_KEY_API if set.
private func agentEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let keyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor-connector-api-key")
    if let key = try? String(contentsOf: keyFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "\n").first
        .map(String.init),
       !key.isEmpty {
        env["CURSOR_API_KEY"] = key
        env["CURSOR_KEY_API"] = key
    }
    return env
}

/// Force Cursor CLI to use the given model by patching ~/.cursor/cli-config.json before this run (CLI often ignores --model when config is set).
private func patchCLIConfig(model modelId: String) {
    let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cursor/cli-config.json")
    guard let data = try? Data(contentsOf: configURL),
          var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    var model: [String: Any] = (config["model"] as? [String: Any]) ?? [:]
    model["modelId"] = modelId
    model["displayModelId"] = modelId
    model["displayName"] = modelId
    model["displayNameShort"] = modelId
    model["aliases"] = [modelId]
    config["model"] = model
    config["hasChangedDefaultModel"] = true
    guard let out = try? JSONSerialization.data(withJSONObject: config) else { return }
    try? out.write(to: configURL)
}

func runAgentPrompt(path: String, prompt: String, model modelId: String = "auto") -> (output: String, exitCode: Int32)? {
    guard !path.isEmpty, path.hasPrefix("/") else { return nil }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
    guard !prompt.isEmpty else { return nil }

    patchCLIConfig(model: modelId)

    let process = Process()
    if let agentPath = agentExecutablePath {
        process.executableURL = URL(fileURLWithPath: agentPath)
        process.arguments = ["--model", modelId, "-p", "--force", "--trust", prompt]
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["agent", "--model", modelId, "-p", "--force", "--trust", prompt]
    }
    process.currentDirectoryURL = URL(fileURLWithPath: path)
    process.environment = agentEnvironment()

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
        try process.run()
    } catch {
        return ("Error: \(error.localizedDescription)", -1)
    }

    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        process.waitUntilExit()
        group.leave()
    }
    if group.wait(timeout: .now() + agentTimeoutSeconds) == .timedOut {
        process.terminate()
        process.waitUntilExit()
        return ("Error: Agent timed out after \(Int(agentTimeoutSeconds)) seconds.", -1)
    }

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    let outStr = String(data: outData.prefix(agentMaxOutputBytes), encoding: .utf8) ?? "(invalid utf8)"
    let errStr = String(data: errData.prefix(agentMaxOutputBytes), encoding: .utf8) ?? ""
    let combined = errStr.isEmpty ? outStr : "\(outStr)\n--- stderr ---\n\(errStr)"
    return (combined, process.terminationStatus)
}

/// Runs the agent and streams output via `writeChunk` (SSE-formatted data). Blocks until process exits or timeout. Returns exit code.
func runAgentPromptStreamSync(path: String, prompt: String, model modelId: String = "auto", writeChunk: (Data) throws -> Void) -> Int32 {
    guard !path.isEmpty, path.hasPrefix("/") else { return -1 }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return -1 }
    guard !prompt.isEmpty else { return -1 }

    patchCLIConfig(model: modelId)

    let process = Process()
    if let agentPath = agentExecutablePath {
        process.executableURL = URL(fileURLWithPath: agentPath)
        process.arguments = ["--model", modelId, "-p", "--force", "--trust", prompt]
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["agent", "--model", modelId, "-p", "--force", "--trust", prompt]
    }
    process.currentDirectoryURL = URL(fileURLWithPath: path)
    process.environment = agentEnvironment()

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
        try process.run()
    } catch {
        try? writeChunk(sseData("Error: \(error.localizedDescription)"))
        return -1
    }

    let outHandle = outPipe.fileHandleForReading
    var totalBytes = 0
    let deadline = Date().addingTimeInterval(agentTimeoutSeconds)

    while Date() < deadline {
        let d = outHandle.availableData
        if d.isEmpty { break }
        totalBytes += d.count
        if totalBytes > agentMaxOutputBytes { break }
        if let s = String(data: d, encoding: .utf8) {
            try? writeChunk(sseData(s))
        }
    }

    if Date() >= deadline {
        process.terminate()
        process.waitUntilExit()
        try? writeChunk(sseData("Error: Agent timed out after \(Int(agentTimeoutSeconds)) seconds."))
        return -1
    }

    process.waitUntilExit()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    if !errData.isEmpty, let errStr = String(data: errData.prefix(agentMaxOutputBytes), encoding: .utf8) {
        try? writeChunk(sseData("\n--- stderr ---\n" + errStr))
    }
    try? writeChunk(sseData("\n[exit: \(process.terminationStatus)]"))
    return process.terminationStatus
}

private func sseData(_ text: String) -> Data {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var out = ""
    for line in lines {
        out += "data: " + line + "\n"
    }
    out += "\n"
    return Data(out.utf8)
}

/// SSE event with optional type (e.g. "thinking") so the client can show thought process separately.
private func sseEvent(event: String?, data: String) -> Data {
    var out = ""
    if let e = event, !e.isEmpty {
        out += "event: " + e + "\n"
    }
    let lines = data.split(separator: "\n", omittingEmptySubsequences: false)
    for line in lines {
        out += "data: " + line + "\n"
    }
    out += "\n"
    return Data(out.utf8)
}

/// Runs the agent with --output-format stream-json --stream-partial-output, parses JSON lines and forwards as SSE (event: thinking vs data).
func runAgentPromptStreamJSONSync(path: String, prompt: String, model modelId: String = "auto", writeChunk: (Data) throws -> Void) -> Int32 {
    guard !path.isEmpty, path.hasPrefix("/") else { return -1 }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return -1 }
    guard !prompt.isEmpty else { return -1 }

    patchCLIConfig(model: modelId)

    let process = Process()
    let streamJSONArgs = ["--model", modelId, "-p", "--force", "--trust", "--output-format", "stream-json", "--stream-partial-output", prompt]
    if let agentPath = agentExecutablePath {
        process.executableURL = URL(fileURLWithPath: agentPath)
        process.arguments = streamJSONArgs
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["agent"] + streamJSONArgs
    }
    process.currentDirectoryURL = URL(fileURLWithPath: path)
    process.environment = agentEnvironment()

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
        try process.run()
    } catch {
        try? writeChunk(sseData("Error: \(error.localizedDescription)"))
        return -1
    }

    // Send an immediate empty thinking event so the client gets real-time feedback (response starts flowing at once).
    try? writeChunk(sseEvent(event: "thinking", data: ""))

    let outHandle = outPipe.fileHandleForReading
    var lineBuffer = ""
    var totalBytes = 0
    let deadline = Date().addingTimeInterval(agentTimeoutSeconds)

    while Date() < deadline {
        let d = outHandle.availableData
        if d.isEmpty { break }
        totalBytes += d.count
        if totalBytes > agentMaxOutputBytes { break }
        guard let s = String(data: d, encoding: .utf8) else { continue }
        lineBuffer += s
        while let newlineIdx = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newlineIdx]).trimmingCharacters(in: .whitespaces)
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIdx)...])
            guard !line.isEmpty else { continue }
            guard let jsonData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                try? writeChunk(sseData(line))
                continue
            }
            let eventType: String? = {
                if let t = obj["type"] as? String {
                    let lower = t.lowercased()
                    if lower.contains("thinking") || lower == "reasoning" || lower.contains("reasoning") { return "thinking" }
                    return nil
                }
                if let k = obj["kind"] as? String, k.lowercased().contains("thinking") { return "thinking" }
                if let sub = obj["subtype"] as? String, sub.lowercased().contains("thinking") { return "thinking" }
                return nil
            }()
            let payload: String = {
                if let delta = obj["delta"] as? String { return delta }
                if let text = obj["text"] as? String { return text }
                if let content = obj["content"] as? String { return content }
                if let data = obj["data"] as? String { return data }
                // Nested: message.content[0].text (stream-json assistant messages)
                if let msg = obj["message"] as? [String: Any],
                   let contentArr = msg["content"] as? [[String: Any]],
                   let first = contentArr.first,
                   let text = first["text"] as? String { return text }
                if let contentArr = obj["content"] as? [[String: Any]],
                   let first = contentArr.first,
                   let text = first["text"] as? String { return text }
                // Don't forward raw JSON metadata (e.g. type "thinking" subtype "completed", type "system") as content
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("{") { return "" }
                return line
            }()
            if !payload.isEmpty {
                try? writeChunk(sseEvent(event: eventType, data: payload))
            }
        }
    }

    if Date() >= deadline {
        process.terminate()
        process.waitUntilExit()
        try? writeChunk(sseData("Error: Agent timed out after \(Int(agentTimeoutSeconds)) seconds."))
        return -1
    }

    process.waitUntilExit()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    if !errData.isEmpty, let errStr = String(data: errData.prefix(agentMaxOutputBytes), encoding: .utf8) {
        try? writeChunk(sseEvent(event: nil, data: "\n--- stderr ---\n" + errStr))
    }
    try? writeChunk(sseData("\n[exit: \(process.terminationStatus)]"))
    return process.terminationStatus
}

// MARK: - File tree and content (Phase 3)

struct FileTreeEntry: Codable {
    var name: String
    var path: String
    var isDirectory: Bool
}

struct FileTreeResponse: Codable {
    var entries: [FileTreeEntry]
}

struct FileContentResponse: Codable {
    var content: String?
    var binary: Bool
}

let fileContentMaxBytes = 512 * 1024

/// Returns true if path is absolute, does not contain "..", and exists.
func validatePath(_ path: String) -> Bool {
    guard path.hasPrefix("/"), !path.contains("..") else { return false }
    return FileManager.default.fileExists(atPath: path)
}

func listDirectory(path: String) -> [FileTreeEntry]? {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
    var entries: [FileTreeEntry] = []
    let fullPath = (path as NSString).standardizingPath
    let sortedNames = names.sorted { a, b in
        let pathA = (fullPath as NSString).appendingPathComponent(a)
        let pathB = (fullPath as NSString).appendingPathComponent(b)
        var aIsDir: ObjCBool = false, bIsDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: pathA, isDirectory: &aIsDir)
        _ = FileManager.default.fileExists(atPath: pathB, isDirectory: &bIsDir)
        if aIsDir.boolValue != bIsDir.boolValue { return aIsDir.boolValue }
        return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }
    for name in sortedNames {
        let entryPath = (fullPath as NSString).appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: entryPath, isDirectory: &isDirectory)
        entries.append(FileTreeEntry(name: name, path: entryPath, isDirectory: isDirectory.boolValue))
    }
    return entries
}

func readFileContent(path: String) -> (content: String?, binary: Bool)? {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    if data.count > fileContentMaxBytes {
        return ("[File too large to display (\(data.count) bytes)]", false)
    }
    if let str = String(data: data, encoding: .utf8) {
        return (str, false)
    }
    return (nil, true)
}

/// Write text content to a file. Path must be absolute, no "..". Creates file if needed; parent directory must exist.
func writeFileContent(path: String, content: String) -> Bool {
    guard path.hasPrefix("/"), !path.contains("..") else { return false }
    let url = URL(fileURLWithPath: path)
    let parent = url.deletingLastPathComponent()
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else { return false }
    guard let data = content.data(using: .utf8) else { return false }
    do {
        try data.write(to: url)
        return true
    } catch {
        return false
    }
}

// MARK: - Connector conversations sync (iOS app → project folder on Mac)

struct SyncConversationMessage: Codable {
    var id: String?
    var role: String
    var content: String
    var thinking: String?
    var imageData: String?  // base64, optional
}

struct SyncConversationPayload: Codable {
    var id: String
    var title: String
    var messages: [SyncConversationMessage]
    var createdAt: String  // ISO8601
    var updatedAt: String
}

struct SyncConversationRequest: Codable {
    var path: String
    var conversation: SyncConversationPayload
}

/// Writes a synced conversation into projectPath/.cursor/connector-conversations/ as JSON and Markdown so it appears when you open the project in Cursor.
func writeSyncedConversation(projectPath: String, payload: SyncConversationPayload) -> Bool {
    guard !projectPath.isEmpty, projectPath.hasPrefix("/"), !projectPath.contains("..") else { return false }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { return false }
    let dir = (projectPath as NSString).appendingPathComponent(".cursor/connector-conversations")
    if !FileManager.default.fileExists(atPath: dir) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let readme = "# Cursor Connector chats\n\nThese chats were synced from the CursorConnector iOS app. Open the `.md` files to read the conversation; `.json` holds the same data.\n"
        _ = writeFileContent(path: (dir as NSString).appendingPathComponent("README.md"), content: readme)
    }
    var isDirCheck: ObjCBool = false
    guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirCheck), isDirCheck.boolValue else { return false }
    let base = (dir as NSString).appendingPathComponent(payload.id)
    let jsonPath = base + ".json"
    let mdPath = base + ".md"
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let jsonData: Data
    do {
        jsonData = try encoder.encode(payload)
    } catch {
        return false
    }
    guard (try? jsonData.write(to: URL(fileURLWithPath: jsonPath))) != nil else { return false }
    var md = "# \(payload.title)\n\n"
    md += "Updated: \(payload.updatedAt)\n\n---\n\n"
    for msg in payload.messages {
        let roleLabel = msg.role == "user" ? "**You**" : "**Assistant**"
        md += "### \(roleLabel)\n\n"
        if !(msg.thinking ?? "").isEmpty {
            md += "_Thinking:_ \(msg.thinking!.replacingOccurrences(of: "\n", with: " "))\n\n"
        }
        md += msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.imageData != nil { md += "\n\n_[Image attached]_" }
        md += "\n\n"
    }
    return writeFileContent(path: mdPath, content: md)
}

/// Conversation list item returned by GET /conversations/list (matches iOS ConversationSummary minus projectPath).
struct ConnectorConversationSummary: Codable {
    var id: String
    var title: String
    var updatedAt: String  // ISO8601
}

/// List conversations synced in projectPath/.cursor/connector-conversations/ (from iOS or written by Companion). Newest first.
func listConnectorConversations(projectPath: String) -> [ConnectorConversationSummary] {
    guard !projectPath.isEmpty, projectPath.hasPrefix("/"), !projectPath.contains("..") else { return [] }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { return [] }
    let dir = (projectPath as NSString).appendingPathComponent(".cursor/connector-conversations")
    guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return [] }
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    let decoder = JSONDecoder()
    var result: [ConnectorConversationSummary] = []
    for name in contents where (name as NSString).pathExtension == "json" {
        let base = (name as NSString).deletingPathExtension
        guard UUID(uuidString: base) != nil else { continue }
        let path = (dir as NSString).appendingPathComponent(name)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let payload = try? decoder.decode(SyncConversationPayload.self, from: data) else { continue }
        result.append(ConnectorConversationSummary(id: payload.id, title: payload.title, updatedAt: payload.updatedAt))
    }
    result.sort { (a, b) in
        guard let da = iso8601Date(a.updatedAt), let db = iso8601Date(b.updatedAt) else { return false }
        return da > db
    }
    return result
}

private func iso8601Date(_ s: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var d = formatter.date(from: s)
    if d == nil {
        formatter.formatOptions = [.withInternetDateTime]
        d = formatter.date(from: s)
    }
    return d
}

/// Load a single conversation from projectPath/.cursor/connector-conversations/{id}.json. Returns nil if not found or invalid.
func getConnectorConversation(projectPath: String, id: String) -> SyncConversationPayload? {
    guard !projectPath.isEmpty, projectPath.hasPrefix("/"), !projectPath.contains(".."),
          !id.isEmpty, UUID(uuidString: id) != nil else { return nil }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { return nil }
    let dir = (projectPath as NSString).appendingPathComponent(".cursor/connector-conversations")
    let path = (dir as NSString).appendingPathComponent("\(id).json")
    guard FileManager.default.fileExists(atPath: path),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? JSONDecoder().decode(SyncConversationPayload.self, from: data)
}

// MARK: - Git (run in project directory on Mac)

func isGitRepo(path: String) -> Bool {
    var isDir: ObjCBool = false
    let gitPath = (path as NSString).appendingPathComponent(".git")
    return FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) && isDir.boolValue
}

/// Run a git command in the given directory. Returns (stdout, stderr, exitCode).
func runGit(in path: String, arguments: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        return ("", "Not a directory", -1)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        return (outStr, errStr, process.terminationStatus)
    } catch {
        return ("", error.localizedDescription, -1)
    }
}

struct GitChangeEntry: Codable {
    var status: String  // two-letter porcelain code, e.g. " M", "M ", "??"
    var path: String
}

struct GitStatusResponse: Codable {
    var branch: String
    var changes: [GitChangeEntry]
    var hasChanges: Bool { !changes.isEmpty }
}

func getGitStatus(path: String) -> GitStatusResponse? {
    guard isGitRepo(path: path) else { return nil }
    let (branchOut, _, branchCode) = runGit(in: path, arguments: ["rev-parse", "--abbrev-ref", "HEAD"])
    var branch = branchCode == 0 ? branchOut.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    if branch.isEmpty { branch = "HEAD" }
    // Use newline-separated (no -z) so parsing is straightforward: "XY path" per line
    let (statusOut, _, statusCode) = runGit(in: path, arguments: ["status", "--porcelain"])
    var changes: [GitChangeEntry] = []
    if statusCode == 0, !statusOut.isEmpty {
        let lines = statusOut.split(separator: "\n", omittingEmptySubsequences: false)
        for part in lines {
            let line = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 3 else { continue }
            let status = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
            // Path is everything after the 2-char status and exactly one separator (space or tab)
            let afterStatus = line.dropFirst(2)
            let pathStart = afterStatus.drop(while: { $0 == " " || $0 == "\t" })
            let filePath = String(pathStart).trimmingCharacters(in: .whitespacesAndNewlines)
            if !filePath.isEmpty {
                changes.append(GitChangeEntry(status: status.isEmpty ? "??" : status, path: filePath))
            }
        }
    }
    return GitStatusResponse(branch: branch, changes: changes)
}

/// Returns the diff for a single file. repoPath is the repo root; filePath is relative to it.
/// For tracked files uses `git diff HEAD -- <file>`. For untracked, uses `git diff --no-index /dev/null <absPath>`.
func getGitFileDiff(repoPath: String, filePath: String) -> String? {
    guard isGitRepo(path: repoPath) else { return nil }
    let normalizedRepo = (repoPath as NSString).standardizingPath
    let trimmed = filePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains(".."), !trimmed.hasPrefix("/") else { return nil }
    let fullPath = (normalizedRepo as NSString).appendingPathComponent(trimmed)
    let resolvedFull = (fullPath as NSString).standardizingPath
    guard resolvedFull.hasPrefix(normalizedRepo) else { return nil }

    // Tracked file: diff vs HEAD (staged + unstaged)
    let (out, _, code) = runGit(in: normalizedRepo, arguments: ["diff", "HEAD", "--", trimmed])
    if code == 0 {
        if !out.isEmpty { return out }
        // Empty diff: if tracked, return empty; if untracked, fall through to show new file
        let (_, _, lsExit) = runGit(in: normalizedRepo, arguments: ["ls-files", "--error-unmatch", "--", trimmed])
        if lsExit == 0 { return "" }  // tracked, no changes
    }

    // Untracked: show as new file via diff --no-index
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolvedFull, isDirectory: &isDir), !isDir.boolValue else {
        return nil
    }
    let (untrackedOut, _, untrackedCode) = runGit(in: normalizedRepo, arguments: ["diff", "--no-index", "/dev/null", resolvedFull])
    if untrackedCode == 0, !untrackedOut.isEmpty { return untrackedOut }

    // Fallback for new files when git diff --no-index fails or is empty: show full file as added lines
    guard let result = readFileContent(path: resolvedFull), let content = result.content, !result.binary else {
        return nil
    }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    let diffLines = lines.map { "+ " + $0 }
    return "--- /dev/null\n+++ b/\(trimmed)\n" + diffLines.joined(separator: "\n")
}

struct GitGenerateMessageResponse: Codable {
    var message: String
}

func generateGitCommitMessage(path: String) -> String? {
    guard isGitRepo(path: path) else { return nil }
    let (statusOut, _, _) = runGit(in: path, arguments: ["status", "--short"])
    let (diffOut, _, _) = runGit(in: path, arguments: ["diff", "--stat"])
    let (diffStagedOut, _, _) = runGit(in: path, arguments: ["diff", "--cached", "--stat"])
    let context = """
    Git status:
    \(statusOut)
    Staged diff stat:
    \(diffStagedOut)
    Unstaged diff stat:
    \(diffOut)
    """
    let prompt = "Generate a single-line git commit message for these changes. Reply with only the message, no quotes or explanation."
    guard let result = runAgentPrompt(path: path, prompt: prompt + "\n\n" + context) else { return nil }
    let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
    return firstLine.isEmpty ? nil : String(firstLine.prefix(500))
}

func gitCommit(path: String, message: String) -> (success: Bool, output: String, error: String) {
    guard isGitRepo(path: path), !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return (false, "", "Not a git repo or empty message")
    }
    let (_, _, addCode) = runGit(in: path, arguments: ["add", "-A"])
    guard addCode == 0 else {
        let (_, err, _) = runGit(in: path, arguments: ["add", "-A"])
        return (false, "", err)
    }
    let (out, err, code) = runGit(in: path, arguments: ["commit", "-m", message])
    return (code == 0, out, err)
}

func gitPush(path: String) -> (success: Bool, output: String, error: String) {
    guard isGitRepo(path: path) else { return (false, "", "Not a git repo") }
    let (out, err, code) = runGit(in: path, arguments: ["push"])
    return (code == 0, out, err)
}

// MARK: - Sleep prevention (release on exit)
// Prevent system idle sleep only (display can sleep to save battery). If the connection still drops when the
// screen is off, the user can enable "Prevent automatic sleeping when the display is off" in System Settings.

private var g_sleepAssertionID: IOPMAssertionID = 0

private func releaseSleepAssertion() {
    if g_sleepAssertionID != 0 {
        IOPMAssertionRelease(g_sleepAssertionID)
        g_sleepAssertionID = 0
    }
}

// MARK: - Server

let port: UInt16 = 9283
let server = HttpServer()

/// Returns a short string of IPs the user can use as Host (Tailscale first if present, then LAN).
private func localIPHints() -> String {
    var out: [String] = []
    let tailscale = Process()
    tailscale.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    tailscale.arguments = ["tailscale", "ip", "-4"]
    tailscale.standardOutput = Pipe()
    tailscale.standardError = FileHandle.nullDevice
    if (try? tailscale.run()) != nil {
        tailscale.waitUntilExit()
        if tailscale.terminationStatus == 0,
           let data = (tailscale.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile(),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            out.append("Tailscale: \(s)")
        }
    }
    let ifconfig = Process()
    ifconfig.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
    ifconfig.arguments = ["getifaddr", "en0"]
    ifconfig.standardOutput = Pipe()
    ifconfig.standardError = FileHandle.nullDevice
    if (try? ifconfig.run()) != nil {
        ifconfig.waitUntilExit()
        if ifconfig.terminationStatus == 0,
           let data = (ifconfig.standardOutput as? Pipe)?.fileHandleForReading.readDataToEndOfFile(),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            out.append("Wi‑Fi (en0): \(s)")
        }
    }
    if out.isEmpty { return " (run Tailscale or use your Mac’s IP from System Settings → Network)" }
    return "\n  Use as Host in the app: " + out.joined(separator: " or ")
}

server.GET["/health"] = { _ in .ok(.text("OK")) }

server.POST["/restart"] = { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    return .ok(.text("OK"))
}

server.GET["/projects"] = { _ in
    let projects = loadProjects()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(projects) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}

server.POST["/projects/open"] = { request in
    let body = request.body
    guard !body.isEmpty,
          let json = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
          let path = json["path"] as? String else {
        return .badRequest(.text("Missing or invalid JSON body with 'path'"))
    }
    return openProject(path: path) ? .ok(.text("OK")) : .internalServerError
}

server.GET["/files/tree"] = { request in
    guard let pathParam = request.queryParams.first(where: { $0.0 == "path" })?.1,
          let decoded = pathParam.removingPercentEncoding else {
        return .badRequest(.text("Missing 'path' query parameter"))
    }
    let path = (decoded as NSString).standardizingPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty, path.hasPrefix("/"), !path.contains("..") else {
        return .badRequest(.text("Path must be absolute and not contain '..'"))
    }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
        return .badRequest(.text("Path does not exist or is not a directory on the Mac"))
    }
    guard let entries = listDirectory(path: path) else {
        return .badRequest(.text("Could not list directory"))
    }
    let response = FileTreeResponse(entries: entries)
    guard let data = try? JSONEncoder().encode(response) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}

server.GET["/files/content"] = { request in
    guard let pathParam = request.queryParams.first(where: { $0.0 == "path" })?.1,
          let path = pathParam.removingPercentEncoding, validatePath(path),
          let result = readFileContent(path: path) else {
        return .badRequest(.text("Invalid or missing 'path' query parameter, or path is not a readable file"))
    }
    let response = FileContentResponse(content: result.content, binary: result.binary)
    guard let data = try? JSONEncoder().encode(response) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}

struct FileWriteRequest: Codable {
    var path: String
    var content: String
}

server.POST["/files/content"] = { request in
    let body = request.body
    guard !body.isEmpty,
          let decoded = try? JSONDecoder().decode(FileWriteRequest.self, from: Data(body)) else {
        return .badRequest(.text("Missing or invalid JSON body with 'path' and 'content'"))
    }
    guard writeFileContent(path: decoded.path, content: decoded.content) else {
        return .badRequest(.text("Invalid path or could not write file"))
    }
    return .ok(.text("OK"))
}

server.POST["/conversations/sync"] = { request in
    let body = request.body
    guard !body.isEmpty,
          let decoded = try? JSONDecoder().decode(SyncConversationRequest.self, from: Data(body)) else {
        return .badRequest(.text("Missing or invalid JSON body with 'path' and 'conversation'"))
    }
    guard writeSyncedConversation(projectPath: decoded.path, payload: decoded.conversation) else {
        return .badRequest(.text("Invalid project path or could not write conversation"))
    }
    return .ok(.text("OK"))
}

server.GET["/conversations/list"] = { request in
    guard let pathParam = request.queryParams.first(where: { $0.0 == "path" })?.1,
          let path = pathParam.removingPercentEncoding,
          !path.isEmpty, path.hasPrefix("/"), !path.contains("..") else {
        return .badRequest(.text("Missing or invalid 'path' query parameter"))
    }
    let list = listConnectorConversations(projectPath: path)
    guard let data = try? JSONEncoder().encode(list) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}

server.GET["/conversations/get"] = { request in
    guard let pathParam = request.queryParams.first(where: { $0.0 == "path" })?.1,
          let path = pathParam.removingPercentEncoding,
          !path.isEmpty, path.hasPrefix("/"), !path.contains("..") else {
        return .badRequest(.text("Missing or invalid 'path' query parameter"))
    }
    guard let idParam = request.queryParams.first(where: { $0.0 == "id" })?.1,
          let id = idParam.removingPercentEncoding, !id.isEmpty else {
        return .badRequest(.text("Missing or invalid 'id' query parameter"))
    }
    guard let payload = getConnectorConversation(projectPath: path, id: id) else {
        return .notFound
    }
    guard let data = try? JSONEncoder().encode(payload) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}

server.POST["/prompt"] = { request in
    let body = request.body
    guard !body.isEmpty,
          let decoded = try? JSONDecoder().decode(PromptRequest.self, from: Data(body)) else {
        return .badRequest(.text("Missing or invalid JSON body with 'path' and 'prompt'"))
    }
    let prompt = promptWithSavedScreenshots(projectPath: decoded.path, prompt: decoded.prompt, images: decoded.images)
    let modelId = decoded.model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? decoded.model! : "auto"
    guard let result = runAgentPrompt(path: decoded.path, prompt: prompt, model: modelId) else {
        return .badRequest(.text("Invalid path or empty prompt"))
    }
    var output = result.output
    if result.exitCode == 127 {
        output = "The 'agent' command was not found (exit code 127). Install the Cursor Agent CLI on your Mac:\n\n  curl https://cursor.com/install -fsSL | bash\n\nThen restart the Companion and try again.\n\n---\n\n" + output
    }
    let response = PromptResponse(output: output, exitCode: Int(result.exitCode))
    guard let data = try? JSONEncoder().encode(response) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}

server.POST["/prompt-stream"] = { request in
    let body = request.body
    guard !body.isEmpty,
          let decoded = try? JSONDecoder().decode(PromptRequest.self, from: Data(body)) else {
        return .badRequest(.text("Missing or invalid JSON body with 'path' and 'prompt'"))
    }
    let path = decoded.path
    let prompt = promptWithSavedScreenshots(projectPath: decoded.path, prompt: decoded.prompt, images: decoded.images)
    let modelId = decoded.model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? decoded.model! : "auto"
    let streamJSON = request.queryParams.first(where: { $0.0 == "stream" })?.1 == "json"
    let headers: [String: String] = [
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
        "X-Accel-Buffering": "no"
    ]
    return .raw(200, "OK", headers) { writer in
        if prompt.isEmpty || path.isEmpty {
            try writer.write(sseData("Error: Invalid path or empty prompt"))
            return
        }
        let exitCode: Int32
        if streamJSON {
            exitCode = runAgentPromptStreamJSONSync(path: path, prompt: prompt, model: modelId) { chunk in
                try writer.write(chunk)
            }
        } else {
            exitCode = runAgentPromptStreamSync(path: path, prompt: prompt, model: modelId) { chunk in
                try writer.write(chunk)
            }
        }
        if exitCode == 127 {
            try? writer.write(sseData("The 'agent' command was not found (exit code 127). Install the Cursor Agent CLI on your Mac:\n\n  curl https://cursor.com/install -fsSL | bash\n\nThen restart the Companion and try again."))
        }
    }
}

// MARK: - Git endpoints

server.GET["/git/status"] = { request in
    guard let pathParam = request.queryParams.first(where: { $0.0 == "path" })?.1,
          let path = pathParam.removingPercentEncoding,
          !path.isEmpty, path.hasPrefix("/"), !path.contains("..") else {
        return .badRequest(.text("Missing or invalid 'path' query parameter"))
    }
    guard let status = getGitStatus(path: path) else {
        return .badRequest(.text("Not a git repository"))
    }
    guard let data = try? JSONEncoder().encode(status) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}

struct GitDiffResponse: Codable {
    var diff: String
}

let gitDiffHandler: (HttpRequest) -> HttpResponse = { request in
    guard let pathParam = request.queryParams.first(where: { $0.0 == "path" })?.1,
          let pathDecoded = pathParam.removingPercentEncoding,
          !pathDecoded.isEmpty, !pathDecoded.contains("..") else {
        return .badRequest(.text("Missing or invalid 'path' query parameter"))
    }
    // Repo path must be absolute; allow with or without leading slash
    let path = pathDecoded.hasPrefix("/") ? pathDecoded : "/" + pathDecoded
    guard let fileParam = request.queryParams.first(where: { $0.0 == "file" })?.1,
          let file = fileParam.removingPercentEncoding, !file.isEmpty else {
        return .badRequest(.text("Missing or invalid 'file' query parameter"))
    }
    // File must be relative to repo root (no leading slash)
    let filePath = file.hasPrefix("/") ? String(file.dropFirst()) : file
    guard let diff = getGitFileDiff(repoPath: path, filePath: filePath) else {
        return .badRequest(.text("No diff available for that file"))
    }
    let response = GitDiffResponse(diff: diff)
    guard let data = try? JSONEncoder().encode(response) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}
server.GET["/git/diff"] = gitDiffHandler

struct GitDiffRequest: Codable {
    var path: String
    var file: String
}

let gitDiffPostHandler: (HttpRequest) -> HttpResponse = { request in
    guard !request.body.isEmpty,
          let decoded = try? JSONDecoder().decode(GitDiffRequest.self, from: Data(request.body)) else {
        return .badRequest(.text("Missing or invalid JSON body with 'path' and 'file'"))
    }
    var path = decoded.path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty, !path.contains("..") else {
        return .badRequest(.text("Invalid 'path'"))
    }
    if !path.hasPrefix("/") { path = "/" + path }
    var filePath = decoded.file.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !filePath.isEmpty else {
        return .badRequest(.text("Invalid 'file'"))
    }
    if filePath.hasPrefix("/") { filePath = String(filePath.dropFirst()) }
    guard let diff = getGitFileDiff(repoPath: path, filePath: filePath) else {
        return .badRequest(.text("No diff available for that file"))
    }
    let response = GitDiffResponse(diff: diff)
    guard let data = try? JSONEncoder().encode(response) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}
server.POST["/git/diff"] = gitDiffPostHandler
server.POST["/api/git-diff"] = gitDiffPostHandler

struct GitPathRequest: Codable {
    var path: String
}

server.POST["/git/generate-message"] = { request in
    let body = request.body
    guard !body.isEmpty,
          let decoded = try? JSONDecoder().decode(GitPathRequest.self, from: Data(body)) else {
        return .badRequest(.text("Missing or invalid JSON body with 'path'"))
    }
    guard let message = generateGitCommitMessage(path: decoded.path) else {
        return .badRequest(.text("Not a git repo or could not generate message"))
    }
    let response = GitGenerateMessageResponse(message: message)
    guard let data = try? JSONEncoder().encode(response) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}

struct GitCommitRequest: Codable {
    var path: String
    var message: String
}

server.POST["/git/commit"] = { request in
    let body = request.body
    guard !body.isEmpty,
          let decoded = try? JSONDecoder().decode(GitCommitRequest.self, from: Data(body)) else {
        return .badRequest(.text("Missing or invalid JSON body with 'path' and 'message'"))
    }
    let result = gitCommit(path: decoded.path, message: decoded.message)
    let bodyDict: [String: Any] = ["success": result.success, "output": result.output, "error": result.error]
    guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}

server.POST["/git/push"] = { request in
    let body = request.body
    guard !body.isEmpty,
          let decoded = try? JSONDecoder().decode(GitPathRequest.self, from: Data(body)) else {
        return .badRequest(.text("Missing or invalid JSON body with 'path'"))
    }
    let result = gitPush(path: decoded.path)
    let bodyDict: [String: Any] = ["success": result.success, "output": result.output, "error": result.error]
    guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}

// MARK: - GitHub Actions (CI status)

/// Parse owner and repo from git remote URL (https or ssh).
func parseGitHubOwnerRepo(fromRemoteURL url: String) -> (owner: String, repo: String)? {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    // https://github.com/owner/repo or https://github.com/owner/repo.git
    if trimmed.contains("github.com") {
        guard let start = trimmed.range(of: "github.com/") ?? trimmed.range(of: "github.com:") else { return nil }
        let after = String(trimmed[start.upperBound...])
        let path = after.split(separator: "#").first.map(String.init) ?? after
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        var repo = parts[parts.count - 1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        return (parts[parts.count - 2], repo)
    }
    return nil
}

struct GitHubActionsRun: Codable {
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

func fetchGitHubActionsRuns(projectPath: String) -> GitHubActionsResponse {
    guard isGitRepo(path: projectPath) else {
        return GitHubActionsResponse(runs: [], error: "Not a git repository")
    }
    let (remoteOut, _, code) = runGit(in: projectPath, arguments: ["remote", "get-url", "origin"])
    guard code == 0, let ownerRepo = parseGitHubOwnerRepo(fromRemoteURL: remoteOut) else {
        return GitHubActionsResponse(runs: [], error: "No GitHub remote (origin) found")
    }
    let urlString = "https://api.github.com/repos/\(ownerRepo.owner)/\(ownerRepo.repo)/actions/runs?per_page=10"
    guard let url = URL(string: urlString) else {
        return GitHubActionsResponse(runs: [], error: "Invalid GitHub API URL")
    }
    var request = URLRequest(url: url)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("Swift-Companion", forHTTPHeaderField: "User-Agent")
    let sem = DispatchSemaphore(value: 0)
    var resultData: Data?
    var resultError: Error?
    URLSession.shared.dataTask(with: request) { data, response, error in
        resultData = data
        resultError = error
        if let http = response as? HTTPURLResponse, http.statusCode != 200, let data = data {
            resultData = nil
            resultError = NSError(domain: "GitHubAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"])
        }
        sem.signal()
    }.resume()
    sem.wait()
    if let err = resultError {
        return GitHubActionsResponse(runs: [], error: err.localizedDescription)
    }
    guard let data = resultData,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let runsArray = json["workflow_runs"] as? [[String: Any]] else {
        return GitHubActionsResponse(runs: [], error: "Invalid response from GitHub")
    }
    let runs: [GitHubActionsRun] = runsArray.compactMap { run in
        guard let id = run["id"] as? Int,
              let name = run["name"] as? String,
              let status = run["status"] as? String,
              let createdAt = run["created_at"] as? String,
              let htmlUrl = run["html_url"] as? String,
              let headBranch = run["head_branch"] as? String else { return nil }
        return GitHubActionsRun(
            id: id,
            name: name,
            status: status,
            conclusion: run["conclusion"] as? String,
            createdAt: createdAt,
            htmlUrl: htmlUrl,
            headBranch: headBranch
        )
    }
    return GitHubActionsResponse(runs: runs, error: nil)
}

server.GET["/github/actions"] = { request in
    guard let pathParam = request.queryParams.first(where: { $0.0 == "path" })?.1,
          let path = pathParam.removingPercentEncoding,
          !path.isEmpty, path.hasPrefix("/"), !path.contains("..") else {
        return .badRequest(.text("Missing or invalid 'path' query parameter"))
    }
    let response = fetchGitHubActionsRuns(projectPath: path)
    guard let data = try? JSONEncoder().encode(response) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}

// MARK: - Xcode build and install to device

let xcodeBuildTimeoutSeconds: TimeInterval = 300
let xcodeSchemeName = "CursorConnector"
let xcodeProjectName = "CursorConnector.xcodeproj"
let xcodeProductName = "CursorConnector.app"
let xcodeBundleId = "com.cursorconnector.app"

/// Resolve path to the iOS Xcode project directory (ios/). Uses optional repoPath from request, else current directory or its parent (so running from Companion/ works).
func resolveIOSProjectPath(repoPath: String?) -> String? {
    let candidates: [String]
    if let r = repoPath?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
        candidates = [(r as NSString).standardizingPath]
    } else {
        let cwd = FileManager.default.currentDirectoryPath
        let parent = (cwd as NSString).deletingLastPathComponent
        candidates = [cwd, parent]
    }
    for base in candidates {
        let iosDir = (base as NSString).appendingPathComponent("ios")
        let projectPath = (iosDir as NSString).appendingPathComponent(xcodeProjectName)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue {
            return iosDir
        }
    }
    return nil
}

let deviceListTimeoutSeconds: TimeInterval = 90

/// Run xcodebuild -showdestinations and return the first connected iOS device id.
/// Parses output like: { platform:iOS, arch:arm64, id:00008140-..., name:iPhone }
func getFirstConnectedDeviceID(projectPath: String) -> String? {
    let projectFile = (projectPath as NSString).appendingPathComponent(xcodeProjectName)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["xcodebuild", "-project", projectFile, "-scheme", xcodeSchemeName, "-showdestinations"]
    process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            group.leave()
        }
        guard group.wait(timeout: .now() + deviceListTimeoutSeconds) == .success else {
            process.terminate()
            process.waitUntilExit()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        for line in out.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            // Match physical device: "platform:iOS," (not "platform:iOS Simulator")
            guard s.contains("platform:iOS,"), !s.contains("platform:iOS Simulator") else { continue }
            guard !s.contains("placeholder") else { continue }
            // Extract id:UUID (id is hex digits and hyphens)
            if let idRange = s.range(of: "id:") {
                let afterPrefix = s[idRange.upperBound...]
                if let endIdx = afterPrefix.firstIndex(where: { $0 == "," || $0 == " " || $0 == "}" }) {
                    let id = String(afterPrefix[..<endIdx]).trimmingCharacters(in: .whitespaces)
                    if !id.isEmpty, id.contains("-") {
                        return id
                    }
                }
            }
        }
        return nil
    } catch {
        return nil
    }
}

/// Build the app and install to the given device. Returns (combinedOutput, exitCode). exitCode 0 = success.
func runXcodeBuildAndInstall(projectPath: String, deviceId: String) -> (output: String, exitCode: Int32) {
    let projectFile = (projectPath as NSString).appendingPathComponent(xcodeProjectName)
    let derivedDataPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("CursorConnector-Build-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(atPath: derivedDataPath) }

    let buildProcess = Process()
    buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    buildProcess.arguments = [
        "xcodebuild",
        "-project", projectFile,
        "-scheme", xcodeSchemeName,
        "-destination", "id=\(deviceId)",
        "-configuration", "Debug",
        "-derivedDataPath", derivedDataPath,
        "-allowProvisioningUpdates",
        "build"
    ]
    buildProcess.currentDirectoryURL = URL(fileURLWithPath: projectPath)
    let outPipe = Pipe()
    let errPipe = Pipe()
    buildProcess.standardOutput = outPipe
    buildProcess.standardError = errPipe
    do {
        try buildProcess.run()
    } catch {
        return ("Error: \(error.localizedDescription)", -1)
    }
    // Drain pipes in background so xcodebuild doesn't block when buffers fill
    var outData = Data()
    var errData = Data()
    let drainQueue = DispatchQueue(label: "xcodebuild-drain")
    let outHandle = outPipe.fileHandleForReading
    let errHandle = errPipe.fileHandleForReading
    outHandle.readabilityHandler = { h in
        let d = h.availableData
        if !d.isEmpty { drainQueue.sync { outData.append(d) } }
    }
    errHandle.readabilityHandler = { h in
        let d = h.availableData
        if !d.isEmpty { drainQueue.sync { errData.append(d) } }
    }
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        buildProcess.waitUntilExit()
        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil
        group.leave()
    }
    if group.wait(timeout: .now() + xcodeBuildTimeoutSeconds) == .timedOut {
        buildProcess.terminate()
        buildProcess.waitUntilExit()
        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil
        try? outHandle.close()
        try? errHandle.close()
        return ("Error: Build timed out after \(Int(xcodeBuildTimeoutSeconds)) seconds.", -1)
    }
    // Read any remaining data before closing (availableData throws if handle already closed)
    drainQueue.sync {
        let remainingOut = outHandle.availableData
        let remainingErr = errHandle.availableData
        if !remainingOut.isEmpty { outData.append(remainingOut) }
        if !remainingErr.isEmpty { errData.append(remainingErr) }
    }
    try? outHandle.close()
    try? errHandle.close()
    let outStr = String(data: outData, encoding: .utf8) ?? ""
    let errStr = String(data: errData, encoding: .utf8) ?? ""
    let buildOutput = errStr.isEmpty ? outStr : "\(outStr)\n\(errStr)"
    guard buildProcess.terminationStatus == 0 else {
        return (buildOutput, buildProcess.terminationStatus)
    }

    let appPath = (derivedDataPath as NSString).appendingPathComponent("Build/Products/Debug-iphoneos/\(xcodeProductName)")
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: appPath, isDirectory: &isDir), isDir.boolValue else {
        return (buildOutput + "\nError: Built app not found at \(appPath)", -1)
    }

    let installProcess = Process()
    installProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    installProcess.arguments = ["devicectl", "device", "install", "app", "--device", deviceId, appPath]
    installProcess.currentDirectoryURL = URL(fileURLWithPath: projectPath)
    let installOut = Pipe()
    let installErr = Pipe()
    installProcess.standardOutput = installOut
    installProcess.standardError = installErr
    do {
        try installProcess.run()
        installProcess.waitUntilExit()
    } catch {
        return (buildOutput + "\nInstall error: \(error.localizedDescription)", -1)
    }
    let installOutStr = String(data: installOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let installErrStr = String(data: installErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let installLog = installErrStr.isEmpty ? installOutStr : "\(installOutStr)\n\(installErrStr)"
    if installProcess.terminationStatus != 0 {
        return (buildOutput + "\n--- Install failed ---\n" + installLog, installProcess.terminationStatus)
    }

    // Launch the app on the device so it reopens after install (user may have had it open; install replaces it).
    let launchProcess = Process()
    launchProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    launchProcess.arguments = ["devicectl", "device", "process", "launch", "--device", deviceId, xcodeBundleId]
    let launchOut = Pipe()
    let launchErr = Pipe()
    launchProcess.standardOutput = launchOut
    launchProcess.standardError = launchErr
    var launchNote = "--- Installed on device ---"
    do {
        try launchProcess.run()
        launchProcess.waitUntilExit()
        let outStr = String(data: launchOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errStr = String(data: launchErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if launchProcess.terminationStatus == 0 {
            launchNote += "\n--- App launched on device ---"
        } else {
            launchNote += "\n--- Install OK; launch failed: \(errStr.isEmpty ? outStr : errStr) ---"
        }
    } catch {
        launchNote += "\n--- Install OK; launch failed: \(error.localizedDescription) ---"
    }
    return (buildOutput + "\n" + launchNote + "\n" + installLog, 0)
}

struct XcodeBuildRequest: Codable {
    var repoPath: String?
}

struct XcodeBuildResponse: Codable {
    var success: Bool
    var output: String
    var error: String
}

// MARK: - Build and upload to TestFlight (no device required)

let testflightCredentialsPath = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".cursor-connector-testflight")
let testflightBuildTimeoutSeconds: TimeInterval = 600

/// Path to the iOS app's Info.plist (projectPath is the ios/ directory).
private func infoPlistPath(projectPath: String) -> String {
    (projectPath as NSString).appendingPathComponent("CursorConnector/Info.plist")
}

private func pbxprojPath(projectPath: String) -> String {
    (projectPath as NSString).appendingPathComponent("\(xcodeProjectName)/project.pbxproj")
}

/// Increment build number in both project.pbxproj (CURRENT_PROJECT_VERSION) and Info.plist (CFBundleVersion). Xcode uses the project setting for the built app. Returns new build number or nil on failure.
func incrementBuildNumber(projectPath: String) -> String? {
    let pbxPath = pbxprojPath(projectPath: projectPath)
    guard FileManager.default.fileExists(atPath: pbxPath),
          var content = try? String(contentsOfFile: pbxPath, encoding: .utf8) else { return nil }
    // Find current CURRENT_PROJECT_VERSION value (e.g. "CURRENT_PROJECT_VERSION = 1;")
    let pattern = "CURRENT_PROJECT_VERSION = ([0-9]+);"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let firstMatch = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
          let range = Range(firstMatch.range(at: 1), in: content),
          let num = Int(content[range]) else { return nil }
    let next = num + 1
    let nextStr = "\(next)"
    content = regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "CURRENT_PROJECT_VERSION = \(nextStr);")
    do {
        try content.write(toFile: pbxPath, atomically: true, encoding: .utf8)
    } catch {
        return nil
    }
    // Keep Info.plist in sync
    let plistPath = infoPlistPath(projectPath: projectPath)
    if FileManager.default.fileExists(atPath: plistPath),
       let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
       var plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
        plist["CFBundleVersion"] = nextStr
        if let outData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? outData.write(to: URL(fileURLWithPath: plistPath))
        }
    }
    return nextStr
}

/// Read Apple ID and app-specific password from ~/.cursor-connector-testflight (line 1: Apple ID, line 2: app-specific password, optional line 3: team ID).
func readTestFlightCredentials() -> (appleId: String, appSpecificPassword: String, teamID: String?)? {
    guard let content = try? String(contentsOfFile: testflightCredentialsPath, encoding: .utf8) else { return nil }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard lines.count >= 2 else { return nil }
    let teamID = lines.count >= 3 && lines[2].count >= 10 ? lines[2] : nil
    return (lines[0], lines[1], teamID)
}

/// Run xcodebuild archive. Returns (archivePath, combinedOutput, exitCode).
func runXcodeArchive(projectPath: String) -> (archivePath: String?, output: String, exitCode: Int32) {
    let projectFile = (projectPath as NSString).appendingPathComponent(xcodeProjectName)
    let archiveDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("CursorConnector-Archive-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(atPath: archiveDir, withIntermediateDirectories: true)
    let archivePath = (archiveDir as NSString).appendingPathComponent("CursorConnector.xcarchive")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "xcodebuild",
        "-project", projectFile,
        "-scheme", xcodeSchemeName,
        "-configuration", "Release",
        "-destination", "generic/platform=iOS",
        "-archivePath", archivePath,
        "-allowProvisioningUpdates",
        "archive"
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
    } catch {
        return (nil, "Error: \(error.localizedDescription)", -1)
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let outStr = String(data: outData, encoding: .utf8) ?? ""
    let errStr = String(data: errData, encoding: .utf8) ?? ""
    let combined = errStr.isEmpty ? outStr : "\(outStr)\n\(errStr)"
    guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: archivePath) else {
        return (nil, combined, process.terminationStatus)
    }
    return (archivePath, combined, 0)
}

/// Export .xcarchive to .ipa for App Store. Returns (ipaPath, output, exitCode).
func runExportArchive(archivePath: String, exportDir: String, teamID: String?) -> (ipaPath: String?, output: String, exitCode: Int32) {
    let plistPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ExportOptions-\(UUID().uuidString.prefix(8)).plist")
    defer { try? FileManager.default.removeItem(atPath: plistPath) }
    var plistDict: [String: Any] = ["method": "app-store-connect", "signingStyle": "automatic"]
    if let tid = teamID, !tid.isEmpty {
        plistDict["teamID"] = tid
    }
    guard let plistData = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0),
          (try? plistData.write(to: URL(fileURLWithPath: plistPath))) != nil else {
        return (nil, "Error: could not write ExportOptions.plist", -1)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "xcodebuild", "-exportArchive",
        "-archivePath", archivePath,
        "-exportOptionsPlist", plistPath,
        "-exportPath", exportDir
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: (archivePath as NSString).deletingLastPathComponent)
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
    } catch {
        return (nil, "Error: \(error.localizedDescription)", -1)
    }
    process.waitUntilExit()
    let outStr = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let combined = errStr.isEmpty ? outStr : "\(outStr)\n\(errStr)"
    let ipaPath = (exportDir as NSString).appendingPathComponent("\(xcodeSchemeName).ipa")
    guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: ipaPath) else {
        return (nil, combined, process.terminationStatus)
    }
    return (ipaPath, combined, 0)
}

/// Upload .ipa to App Store Connect via altool. Streams output to the terminal so the user sees progress (upload can take 5–15+ min). Returns (output, exitCode).
func runAltoolUpload(ipaPath: String, appleId: String, appSpecificPassword: String) -> (output: String, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "altool", "--upload-app",
        "-f", ipaPath,
        "-t", "ios",
        "-u", appleId,
        "-p", appSpecificPassword,
        "--verbose"
    ]
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    let outputLock = NSLock()
    var combinedOutput = ""

    func readAndPrint(_ fileHandle: FileHandle) {
        let data = fileHandle.readDataToEndOfFile()
        if let str = String(data: data, encoding: .utf8), !str.isEmpty {
            outputLock.lock()
            combinedOutput += str
            outputLock.unlock()
            for line in str.split(separator: "\n", omittingEmptySubsequences: false) {
                print("  [altool] \(line)")
            }
        }
    }

    outPipe.fileHandleForReading.readabilityHandler = { h in
        let data = h.availableData
        guard !data.isEmpty else { return }
        if let str = String(data: data, encoding: .utf8) {
            outputLock.lock()
            combinedOutput += str
            outputLock.unlock()
            for line in str.split(separator: "\n", omittingEmptySubsequences: false) {
                print("  [altool] \(line)")
            }
        }
    }
    errPipe.fileHandleForReading.readabilityHandler = { h in
        let data = h.availableData
        guard !data.isEmpty else { return }
        if let str = String(data: data, encoding: .utf8) {
            outputLock.lock()
            combinedOutput += str
            outputLock.unlock()
            for line in str.split(separator: "\n", omittingEmptySubsequences: false) {
                print("  [altool] \(line)")
            }
        }
    }

    do {
        try process.run()
    } catch {
        return ("Error: \(error.localizedDescription)", -1)
    }
    process.waitUntilExit()

    outPipe.fileHandleForReading.readabilityHandler = nil
    errPipe.fileHandleForReading.readabilityHandler = nil
    readAndPrint(outPipe.fileHandleForReading)
    readAndPrint(errPipe.fileHandleForReading)

    outputLock.lock()
    let result = combinedOutput
    outputLock.unlock()
    return (result, process.terminationStatus)
}

// If the client disconnects before the build finishes (e.g. timeout), Swifter may log "Failed to send response: writeFailed(\"Broken pipe\")". The build can still have succeeded.
server.POST["/xcode-build"] = { request in
    var repoPath: String?
    if !request.body.isEmpty,
       let decoded = try? JSONDecoder().decode(XcodeBuildRequest.self, from: Data(request.body)) {
        repoPath = decoded.repoPath
    }
    print("[xcode-build] Resolving project path...")
    guard let projectPath = resolveIOSProjectPath(repoPath: repoPath) else {
        let bodyDict: [String: Any] = ["success": false, "output": "", "error": "iOS project not found. Run Companion from the CursorConnector repo root, or send repoPath in the request body."]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return .internalServerError }
        return .ok(.data(data, contentType: "application/json"))
    }
    print("[xcode-build] Project: \(projectPath)")
    print("[xcode-build] Finding device (xcodebuild -showdestinations, may take 20–30s)...")
    guard let deviceId = getFirstConnectedDeviceID(projectPath: projectPath) else {
        let bodyDict: [String: Any] = ["success": false, "output": "", "error": "No iOS device visible to Xcode. Build & install only work when the iPhone is connected to this Mac by USB, or on the same Wi‑Fi with wireless debugging. (Tailscale does not make the device visible to Xcode.) Connect via cable or same Wi‑Fi, then try again."]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return .internalServerError }
        return .ok(.data(data, contentType: "application/json"))
    }
    print("[xcode-build] Device: \(deviceId)")
    print("[xcode-build] Running xcodebuild + install (command line, not in Xcode app)...")
    let (output, exitCode) = runXcodeBuildAndInstall(projectPath: projectPath, deviceId: deviceId)
    print("[xcode-build] Done, exit code \(exitCode)")
    let bodyDict: [String: Any] = [
        "success": exitCode == 0,
        "output": output,
        "error": exitCode == 0 ? "" : (output.split(separator: "\n").last.map(String.init) ?? "Build or install failed")
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}

server.POST["/xcode-build-testflight"] = { request in
    var repoPath: String?
    if !request.body.isEmpty,
       let decoded = try? JSONDecoder().decode(XcodeBuildRequest.self, from: Data(request.body)) {
        repoPath = decoded.repoPath
    }
    print("[xcode-build-testflight] Resolving project path...")
    guard let projectPath = resolveIOSProjectPath(repoPath: repoPath) else {
        let bodyDict: [String: Any] = ["success": false, "output": "", "error": "iOS project not found. Run Companion from the CursorConnector repo root, or send repoPath in the request body."]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return .internalServerError }
        return .ok(.data(data, contentType: "application/json"))
    }
    guard let creds = readTestFlightCredentials() else {
        let msg = "TestFlight credentials not found. Create ~/.cursor-connector-testflight with:\n  Line 1: your Apple ID (email)\n  Line 2: app-specific password (from appleid.apple.com → Sign-In and Security → App-Specific Passwords)\n  Line 3 (optional): Team ID (10 chars, from developer.apple.com/account)"
        let bodyDict: [String: Any] = ["success": false, "output": "", "error": msg]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return .internalServerError }
        return .ok(.data(data, contentType: "application/json"))
    }
    print("[xcode-build-testflight] Project: \(projectPath)")
    let newBuild = incrementBuildNumber(projectPath: projectPath)
    if let newBuild = newBuild {
        print("[xcode-build-testflight] Bumped build number to \(newBuild)")
    } else {
        print("[xcode-build-testflight] Warning: could not bump build number in project")
    }
    var fullOutput = ""

    print("[xcode-build-testflight] Archiving...")
    let (archivePathOpt, archiveOutput, archiveCode) = runXcodeArchive(projectPath: projectPath)
    fullOutput += archiveOutput
    guard let archivePath = archivePathOpt, archiveCode == 0 else {
        let bodyDict: [String: Any] = ["success": false, "output": fullOutput, "error": "Archive failed. Check signing & capabilities in Xcode."]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return .internalServerError }
        return .ok(.data(data, contentType: "application/json"))
    }
    let archiveDir = (archivePath as NSString).deletingLastPathComponent

    let exportDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("CursorConnector-Export-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(atPath: exportDir)
        try? FileManager.default.removeItem(atPath: archiveDir)
    }

    print("[xcode-build-testflight] Exporting IPA...")
    var (ipaPathOpt, exportOutput, exportCode) = runExportArchive(archivePath: archivePath, exportDir: exportDir, teamID: creds.teamID)
    fullOutput += "\n" + exportOutput
    if ipaPathOpt == nil, exportCode != 0, exportOutput.contains("No profiles for"), creds.teamID != nil {
        print("[xcode-build-testflight] Retrying export without Team ID (in case line 3 of credentials is wrong)...")
        let (retryPath, retryOutput, retryCode) = runExportArchive(archivePath: archivePath, exportDir: exportDir, teamID: nil)
        fullOutput += "\n[retry without teamID]\n" + retryOutput
        if retryPath != nil, retryCode == 0 {
            ipaPathOpt = retryPath
            exportCode = 0
        }
    }
    guard let ipaPath = ipaPathOpt, exportCode == 0 else {
        print("[xcode-build-testflight] Export failed (exit code \(exportCode)). xcodebuild output:")
        print(exportOutput)
        let errorMessage: String
        if exportOutput.contains("No profiles for") {
            errorMessage = "No App Store provisioning profile. Do all of: (1) App Store Connect → create an app with bundle ID com.cursorconnector.app. (2) Xcode → open ios/CursorConnector.xcodeproj → CursorConnector target → Signing & Capabilities → set Team, turn on Automatically manage signing. (3) Xcode → Product → Archive and wait for it to finish. (4) If it still fails, remove line 3 (Team ID) from ~/.cursor-connector-testflight and try again."
        } else if exportOutput.contains("doesn't include signing certificate") {
            errorMessage = "Provisioning profile and distribution certificate are out of sync. In Xcode: open the project → Signing & Capabilities → turn Off \"Automatically manage signing\", then turn it back On (same Team). Then Product → Archive once. That refreshes the profile to match your certificate. Try TestFlight again after that."
        } else if exportOutput.contains("No signing certificate") || exportOutput.contains("iOS Distribution") {
            errorMessage = "No iOS Distribution certificate found. In Xcode: Xcode → Settings → Accounts → [your Apple ID] → Manage Certificates. Click + → Apple Distribution (or iOS Distribution). If one exists but export still fails, run the Companion from a Terminal window where you’re logged in (so the keychain is unlocked), then try TestFlight again."
        } else {
            errorMessage = "Export failed. Ensure your Team ID is correct (line 3 of credentials file) and the app is set up for App Store distribution in Xcode."
        }
        let bodyDict: [String: Any] = ["success": false, "output": fullOutput, "error": errorMessage]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return .internalServerError }
        return .ok(.data(data, contentType: "application/json"))
    }

    print("[xcode-build-testflight] Uploading to App Store Connect... (can take 5–15 min, output below)")
    let (uploadOutput, uploadCode) = runAltoolUpload(ipaPath: ipaPath, appleId: creds.appleId, appSpecificPassword: creds.appSpecificPassword)
    fullOutput += "\n" + uploadOutput
    if uploadCode != 0 {
        print("[xcode-build-testflight] Upload failed (exit code \(uploadCode)). altool output:")
        print(uploadOutput)
        let hint = "Upload failed. The Companion reads credentials from ~/.cursor-connector-testflight (your home directory), not from the project folder. Check Apple ID (line 1) and app-specific password (line 2); regenerate the password at appleid.apple.com if needed."
        let errDetail = uploadOutput.split(separator: "\n").last.map(String.init).map { " Apple said: \($0)" } ?? ""
        let bodyDict: [String: Any] = ["success": false, "output": fullOutput, "error": hint + errDetail, "buildNumber": newBuild ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return .internalServerError }
        return .ok(.data(data, contentType: "application/json"))
    }

    print("[xcode-build-testflight] Upload succeeded. altool output:")
    print(uploadOutput)
    print("[xcode-build-testflight] Done. Build \(newBuild ?? "?") should appear in App Store Connect → your app → TestFlight in 5–30 minutes.")
    let outputTrimmed = fullOutput.count > 2000 ? String(fullOutput.suffix(2000)) : fullOutput
    let bodyDict: [String: Any] = [
        "success": true,
        "output": outputTrimmed,
        "error": "",
        "buildNumber": newBuild ?? ""
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: bodyDict) else { return .internalServerError }
    return .ok(.data(data, contentType: "application/json"))
}

server.notFoundHandler = { request in
    print("[Companion] 404 \(request.method) \(request.path)")
    return .notFound
}

do {
    // Listen on all interfaces (0.0.0.0) so the iOS app can connect when not on the same network (e.g. via Tailscale).
    server.listenAddressIPv4 = "0.0.0.0"
    try server.start(port, forceIPv4: true)

    // Prevent system idle sleep only (display may sleep to save battery). Keeps Mac reachable for the iOS app.
    let reason = "Cursor Connector Companion server" as CFString
    if IOPMAssertionCreateWithName(
        kIOPMAssertPreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        reason,
        &g_sleepAssertionID
    ) == kIOReturnSuccess {
        atexit(releaseSleepAssertion)
        print("Sleep prevention active (system will not idle-sleep; display may sleep to save battery).")
    }

    print("CursorConnector Companion running on http://localhost:\(port) (listening on all interfaces)")
    print(localIPHints())
    print("  If the app can’t connect from another network: System Settings → Network → Firewall → allow Companion (or turn firewall off to test).")
    print("  GET  /health        - health check")
    print("  GET  /projects      - list recent Cursor projects")
    print("  GET  /files/tree    - list directory (query: path=...)")
    print("  GET  /files/content - file content (query: path=...)")
    print("  POST /files/content - write file (body: {\"path\": \"...\", \"content\": \"...\"})")
    print("  GET  /conversations/list - list chats for project (query: path=...); shared with iOS")
    print("  GET  /conversations/get  - get one chat (query: path=..., id=...)")
    print("  POST /conversations/sync - sync iOS chat to project (body: {\"path\": \"...\", \"conversation\": {...}})")
    print("  POST /projects/open - open project (body: {\"path\": \"/absolute/path\"})")
    print("  POST /prompt        - run agent (body: {\"path\": \"/project/path\", \"prompt\": \"...\"})")
    print("  POST /prompt-stream - run agent with SSE streaming output")
    print("  GET  /git/status    - git status (query: path=...)")
    print("  GET  /git/diff - file diff (query: path=..., file=...)")
    print("  POST /api/git-diff - file diff (body: {\"path\": \"...\", \"file\": \"...\"}) [used by iOS app]")
    print("  POST /git/generate-message - generate commit message (body: {\"path\": \"...\"})")
    print("  POST /git/commit    - git add -A && commit (body: {\"path\": \"...\", \"message\": \"...\"})")
    print("  POST /git/push     - git push (body: {\"path\": \"...\"})")
    print("  GET  /github/actions - GitHub Actions workflow runs (query: path=...)")
    print("  POST /xcode-build  - build iOS app and install to connected device (body: optional {\"repoPath\": \"/path\"})")
    print("  POST /xcode-build-testflight - archive, export IPA, upload to TestFlight (body: optional {\"repoPath\": \"/path\"}); needs ~/.cursor-connector-testflight")
    print("  POST /restart       - exit process (use with a restarter script to restart)")
    RunLoop.main.run()
} catch {
    print("Failed to start server: \(error)")
    exit(1)
}
