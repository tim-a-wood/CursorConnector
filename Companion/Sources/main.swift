import Foundation
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
}

struct PromptResponse: Codable {
    var output: String
    var exitCode: Int
}

let agentTimeoutSeconds: TimeInterval = 300
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

/// Force Cursor CLI to use Auto model by patching ~/.cursor/cli-config.json before this run (CLI often ignores --model when config is set).
private func patchCLIConfigToAuto() {
    let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cursor/cli-config.json")
    guard let data = try? Data(contentsOf: configURL),
          var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    var model: [String: Any] = (config["model"] as? [String: Any]) ?? [:]
    model["modelId"] = "auto"
    model["displayModelId"] = "auto"
    model["displayName"] = "Auto"
    model["displayNameShort"] = "Auto"
    model["aliases"] = ["auto"]
    config["model"] = model
    config["hasChangedDefaultModel"] = true
    guard let out = try? JSONSerialization.data(withJSONObject: config),
          let _ = try? String(data: out, encoding: .utf8) else { return }
    try? out.write(to: configURL)
}

func runAgentPrompt(path: String, prompt: String) -> (output: String, exitCode: Int32)? {
    guard !path.isEmpty, path.hasPrefix("/") else { return nil }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
    guard !prompt.isEmpty else { return nil }

    patchCLIConfigToAuto()

    // Use headless print mode (-p --force), --trust for workspace, --model auto.
    let process = Process()
    if let agentPath = agentExecutablePath {
        process.executableURL = URL(fileURLWithPath: agentPath)
        process.arguments = ["--model", "auto", "-p", "--force", "--trust", prompt]
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["agent", "--model", "auto", "-p", "--force", "--trust", prompt]
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

// MARK: - Server

let port: UInt16 = 9283
let server = HttpServer()

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

server.POST["/prompt"] = { request in
    let body = request.body
    guard !body.isEmpty,
          let decoded = try? JSONDecoder().decode(PromptRequest.self, from: Data(body)) else {
        return .badRequest(.text("Missing or invalid JSON body with 'path' and 'prompt'"))
    }
    guard let result = runAgentPrompt(path: decoded.path, prompt: decoded.prompt) else {
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

do {
    try server.start(port)
    print("CursorConnector Companion running on http://localhost:\(port)")
    print("  GET  /health        - health check")
    print("  GET  /projects      - list recent Cursor projects")
    print("  GET  /files/tree    - list directory (query: path=...)")
    print("  GET  /files/content - file content (query: path=...)")
    print("  POST /files/content - write file (body: {\"path\": \"...\", \"content\": \"...\"})")
    print("  POST /projects/open - open project (body: {\"path\": \"/absolute/path\"})")
    print("  POST /prompt        - run agent (body: {\"path\": \"/project/path\", \"prompt\": \"...\"})")
    print("  POST /restart        - exit process (use with a restarter script to restart)")
    RunLoop.main.run()
} catch {
    print("Failed to start server: \(error)")
    exit(1)
}
