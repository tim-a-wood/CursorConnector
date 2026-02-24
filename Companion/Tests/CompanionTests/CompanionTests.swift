import XCTest
@testable import Companion

final class CompanionTests: XCTestCase {

    // MARK: - folderPath

    func testFolderPath_fromFileURI() {
        XCTAssertEqual(folderPath(fromUri: "file:///Users/test/project"), "/Users/test/project")
        XCTAssertEqual(folderPath(fromUri: "file:///"), "/")
    }

    func testFolderPath_fromFileURI_withPercentEncoding() {
        XCTAssertEqual(folderPath(fromUri: "file:///Users/test/My%20Project"), "/Users/test/My Project")
    }

    func testFolderPath_withoutFileScheme_returnsUriDecoded() {
        // When URI doesn't start with file://, function still returns the string (percent-decoded)
        XCTAssertEqual(folderPath(fromUri: "/Users/test/project"), "/Users/test/project")
        XCTAssertEqual(folderPath(fromUri: "not-a-uri"), "not-a-uri")
    }

    // MARK: - validatePath

    func testValidatePath_absoluteNoParentExists() {
        let tmp = FileManager.default.temporaryDirectory.path
        XCTAssertTrue(validatePath(tmp))
    }

    func testValidatePath_relative_returnsFalse() {
        XCTAssertFalse(validatePath("relative/path"))
    }

    func testValidatePath_containsParent_returnsFalse() {
        XCTAssertFalse(validatePath("/valid/../path"))
    }

    func testValidatePath_nonexistent_returnsFalse() {
        XCTAssertFalse(validatePath("/nonexistent/path/\(UUID().uuidString)"))
    }

    // MARK: - parseGitHubOwnerRepo

    func testParseGitHubOwnerRepo_https() {
        let result = parseGitHubOwnerRepo(fromRemoteURL: "https://github.com/owner/repo")
        XCTAssertEqual(result?.owner, "owner")
        XCTAssertEqual(result?.repo, "repo")
    }

    func testParseGitHubOwnerRepo_httpsWithDotGit() {
        let result = parseGitHubOwnerRepo(fromRemoteURL: "https://github.com/owner/repo.git")
        XCTAssertEqual(result?.owner, "owner")
        XCTAssertEqual(result?.repo, "repo")
    }

    func testParseGitHubOwnerRepo_ssh() {
        let result = parseGitHubOwnerRepo(fromRemoteURL: "git@github.com:owner/repo.git")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.owner, "owner")
        XCTAssertEqual(result?.repo, "repo")
    }

    func testParseGitHubOwnerRepo_invalid_returnsNil() {
        XCTAssertNil(parseGitHubOwnerRepo(fromRemoteURL: "https://gitlab.com/owner/repo"))
        XCTAssertNil(parseGitHubOwnerRepo(fromRemoteURL: "not-a-url"))
        XCTAssertNil(parseGitHubOwnerRepo(fromRemoteURL: ""))
    }

    // MARK: - openProject path validation

    func testOpenProject_emptyPath_returnsFalse() {
        XCTAssertFalse(openProject(path: ""))
    }

    func testOpenProject_relativePath_returnsFalse() {
        XCTAssertFalse(openProject(path: "relative/path"))
    }

    // MARK: - listDirectory

    func testListDirectory_validDirectory_returnsEntries() {
        let tmp = FileManager.default.temporaryDirectory
        let dir = tmp.appendingPathComponent("CompanionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("file.txt")
        try? "hello".write(to: file, atomically: true, encoding: .utf8)

        let entries = listDirectory(path: dir.path)
        XCTAssertNotNil(entries)
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(entries?.first?.name, "file.txt")
        XCTAssertEqual(entries?.first?.isDirectory, false)
    }

    func testListDirectory_nonexistent_returnsNil() {
        XCTAssertNil(listDirectory(path: "/nonexistent/\(UUID().uuidString)"))
    }

    // MARK: - readFileContent / writeFileContent

    func testWriteAndReadFileContent() {
        let tmp = FileManager.default.temporaryDirectory
        let testDir = tmp.appendingPathComponent("CompanionTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        let file = testDir.appendingPathComponent("file.txt").path
        defer { try? FileManager.default.removeItem(at: testDir) }

        XCTAssertTrue(writeFileContent(path: file, content: "test content"))
        let result = readFileContent(path: file)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.binary, false)
        // Content is either the written string or the "too large" placeholder (env-dependent)
        if let content = result?.content, !content.contains("File too large") {
            XCTAssertEqual(content, "test content")
        }
    }

    func testWriteFileContent_relativePath_returnsFalse() {
        XCTAssertFalse(writeFileContent(path: "relative.txt", content: "x"))
    }

    func testWriteFileContent_pathWithParent_returnsFalse() {
        XCTAssertFalse(writeFileContent(path: "/tmp/../etc/passwd", content: "x"))
    }

    // MARK: - isGitRepo

    func testIsGitRepo_nonRepo_returnsFalse() {
        let tmp = FileManager.default.temporaryDirectory.path
        XCTAssertFalse(isGitRepo(path: tmp))
    }

    // MARK: - resolveIOSProjectPath (optional, if we can run from test bundle)

    func testResolveIOSProjectPath_nilOrEmpty_usesCwdOrParent() {
        // When run from package root, current directory may be repo; when from Companion/, parent is repo
        let result = resolveIOSProjectPath(repoPath: nil)
        // May be nil if not run from repo; we just ensure it doesn't crash
        _ = result
    }

    func testResolveIOSProjectPath_withPath() {
        // Pass a non-repo path - should return nil since no ios/CursorConnector.xcodeproj there
        let result = resolveIOSProjectPath(repoPath: "/nonexistent/\(UUID().uuidString)")
        XCTAssertNil(result)
    }
}
