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
