import Foundation
import Testing
@testable import PitwallCore
import PitwallTestSupport

private let validToken = "ghp_" + String(repeating: "b", count: 36)

/// Uses its own Keychain service, never the app's real token.
@Suite(.serialized) struct TokenStoreTests {
    let service = "dev.pitwall.tests.\(UUID().uuidString)"

    @Test func savesReadsAndDeletes() throws {
        let store = TokenStore(service: service)
        defer { store.delete() }
        #expect(store.token() == nil)
        try store.save("  \(validToken)\n")
        #expect(store.token() == validToken)
        // A fresh instance reads it back from the Keychain, not the cache.
        #expect(TokenStore(service: service).token() == validToken)
        store.delete()
        #expect(store.token() == nil)
        #expect(TokenStore(service: service).token() == nil)
    }

    @Test func refusesThingsThatAreNotTokens() {
        let store = TokenStore(service: service)
        defer { store.delete() }
        for bad in ["", "short", "has spaces in it that are long enough", String(repeating: "a", count: 300)] {
            #expect(throws: GitHubError.self) { try store.save(bad) }
        }
        #expect(store.token() == nil)
    }
}

/// Each test gets its own temp folder, never the app's real token file.
@Suite struct FileTokenStoreTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pitwall-token-\(UUID().uuidString)")
    var url: URL { dir.appending(path: "Pitwall/token") }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        lstat(path, &info)
        return info.st_mode & 0o777
    }

    private func plant(_ text: String, mode: mode_t = 0o600) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        chmod(url.path, mode)
    }

    @Test func savesReadsAndDeletesWithTightPermissions() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileTokenStore(url: url)
        #expect(store.token() == nil)
        try store.save("  \(validToken)\n")
        #expect(store.token() == validToken)
        #expect(FileTokenStore(url: url).token() == validToken)
        #expect(mode(url.path) == 0o600)
        #expect(mode(url.deletingLastPathComponent().path) == 0o700)
        // Nothing but the file itself: the temp file was renamed into place.
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["token"])
        store.delete()
        #expect(store.token() == nil)
        #expect(FileTokenStore(url: url).token() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func overwritesAnEarlierToken() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = "ghp_" + String(repeating: "z", count: 36)
        try FileTokenStore(url: url).save(validToken)
        try FileTokenStore(url: url).save(other)
        #expect(FileTokenStore(url: url).token() == other)
    }

    @Test func refusesThingsThatAreNotTokens() {
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileTokenStore(url: url)
        for bad in ["", "short", "has spaces in it that are long enough"] {
            #expect(throws: GitHubError.self) { try store.save(bad) }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func ignoresFilesOthersCouldReadOrThatHoldGarbage() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try plant(validToken, mode: 0o644)
        #expect(FileTokenStore(url: url).token() == nil)
        try plant("not a token at all")
        #expect(FileTokenStore(url: url).token() == nil)
        try plant(String(repeating: "a", count: FileTokenStore.maxBytes + 10))
        #expect(FileTokenStore(url: url).token() == nil)
        try plant("")
        #expect(FileTokenStore(url: url).token() == nil)
        try plant(validToken)
        #expect(FileTokenStore(url: url).token() == validToken)
    }

    @Test func doesNotFollowASymlink() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(validToken.utf8).write(to: target)
        chmod(target.path, 0o600)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(FileTokenStore(url: url).token() == nil)

        // Saving replaces the link itself and leaves the target alone.
        let other = "ghp_" + String(repeating: "q", count: 36)
        try FileTokenStore(url: url).save(other)
        #expect(try String(contentsOf: target, encoding: .utf8) == validToken)
        let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
        #expect(FileTokenStore(url: url).token() == other)
    }

    @Test func failsCleanlyWhenTheFolderIsNotAFolder() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.deletingLastPathComponent())
        #expect(throws: GitHubError.self) { try FileTokenStore(url: url).save(validToken) }
    }

    @Test func movesATokenLeftInTheKeychainOnce() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = MemoryTokens(validToken)
        let store = FileTokenStore(url: url, legacy: legacy)
        #expect(store.token() == validToken)
        #expect(legacy.token() == nil)
        #expect(FileTokenStore(url: url).token() == validToken)
    }

    @Test func leavesTheKeychainAloneOnceThereIsAFile() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        try plant(validToken, mode: 0o644)  // there, but refused
        let legacy = MemoryTokens("ghp_" + String(repeating: "k", count: 36))
        #expect(FileTokenStore(url: url, legacy: legacy).token() == nil)
        #expect(legacy.token() != nil)
    }

    @Test func ignoresAnUnusableKeychainToken() {
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = MemoryTokens("garbage")
        #expect(FileTokenStore(url: url, legacy: legacy).token() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func signingOutClearsTheKeychainToo() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = MemoryTokens()
        let store = FileTokenStore(url: url, legacy: legacy)
        try store.save(validToken)
        try legacy.save(validToken)
        store.delete()
        #expect(legacy.token() == nil)
        #expect(store.token() == nil)
    }

    @Test func standardStoreLivesInApplicationSupport() {
        #expect(FileTokenStore.standard().url.path.hasSuffix("Library/Application Support/Pitwall/token"))
    }
}

@Suite struct GitHubCLITokenImporterTests {
    let dir: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pitwall-gh-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Writes a fake `gh` and returns its path.
    func fakeGH(_ script: String, mode: Int = 0o755) throws -> String {
        let url = dir.appendingPathComponent("gh-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url.path
    }

    @Test func readsTheTokenWithFixedArgumentsAndAStrippedEnvironment() async throws {
        // Only prints the token if called exactly as expected.
        let gh = try fakeGH("""
        [ "$*" = "auth token --hostname github.com" ] || exit 2
        [ "$PATH" = "/usr/bin:/bin" ] || exit 3
        [ -z "$GH_HOST$GH_TOKEN$DYLD_INSERT_LIBRARIES" ] || exit 4
        echo "\(validToken)"
        """)
        setenv("GH_HOST", "evil.example", 1)
        defer { unsetenv("GH_HOST") }
        let token = try await GitHubCLITokenImporter.importToken(timeout: 5, candidates: [gh])
        #expect(token == validToken)
    }

    @Test func skipsMissingAndWorldWritableBinaries() throws {
        let writable = try fakeGH("echo \(validToken)", mode: 0o777)
        let fine = try fakeGH("echo \(validToken)")
        #expect(GitHubCLITokenImporter.cliPath(in: ["/nonexistent/gh", writable]) == nil)
        #expect(GitHubCLITokenImporter.cliPath(in: ["/nonexistent/gh", writable, fine]) == fine)
    }

    @Test func failuresAreReported() async throws {
        await #expect(throws: GitHubError.self) {
            try await GitHubCLITokenImporter.importToken(timeout: 5, candidates: ["/nonexistent/gh"])
        }
        for script in ["exit 1", "echo not-a-token", "echo \(validToken); exit 1"] {
            let gh = try fakeGH(script)
            await #expect(throws: GitHubError.invalidInput("GitHub CLI isn't logged in. Run `gh auth login` first."), "\(script)") {
                try await GitHubCLITokenImporter.importToken(timeout: 5, candidates: [gh])
            }
        }
    }

    @Test func hangingCLIIsCutOff() async throws {
        let gh = try fakeGH("sleep 10")
        let start = Date()
        await #expect(throws: GitHubError.invalidInput("`gh auth token` timed out.")) {
            try await GitHubCLITokenImporter.importToken(timeout: 0.3, candidates: [gh])
        }
        #expect(Date().timeIntervalSince(start) < 3)
    }
}

@Suite struct GitHubCLIPathTests {
    @Test func onlyLooksInTheFixedLocations() {
        if let path = GitHubCLITokenImporter.cliPath {
            #expect(GitHubCLITokenImporter.candidatePaths.contains(path))
        }
        #expect(GitHubCLITokenImporter.candidatePaths == ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"])
    }
}
