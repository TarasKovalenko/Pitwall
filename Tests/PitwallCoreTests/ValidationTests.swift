import Foundation
import Testing
@testable import PitwallCore
import PitwallTestSupport

@Suite struct ValidationTests {
    @Test(arguments: ["octocat/hello-world", "my-org/repo.name", "a/b", "Some_Org1/x_y-z.js"])
    func acceptsValidRepos(_ name: String) {
        #expect(RepoRef(fullName: name) != nil)
    }

    @Test(arguments: [
        "", "noslash", "a/b/c", "../etc", "owner/..", "owner/.", "-bad/repo", "bad-/repo",
        "own er/repo", "owner/re po", "owner/repo?x=1", "owner/repo#frag", "owner/%2e%2e",
        "a--b/repo", String(repeating: "a", count: 40) + "/repo",
    ])
    func rejectsInvalidRepos(_ name: String) {
        #expect(RepoRef(fullName: name) == nil)
    }

    @Test(arguments: ["main", "feature/x", "release-1.2", "v1.0.0"])
    func acceptsRefs(_ ref: String) {
        #expect(Validation.isValidRef(ref))
    }

    @Test(arguments: ["", "/main", "main/", "a..b", "a b", "x~1", "x^", "x:y", "a@{1}", "branch.lock", "a\nb"])
    func rejectsRefs(_ ref: String) {
        #expect(!Validation.isValidRef(ref))
    }

    @Test func tokenShape() {
        #expect(Validation.isValidToken("ghp_" + String(repeating: "a", count: 36)))
        #expect(Validation.isValidToken("github_pat_" + String(repeating: "A1_", count: 25)))
        #expect(!Validation.isValidToken("short"))
        #expect(!Validation.isValidToken("ghp_abc def ghi jkl mno pqr"))
        #expect(!Validation.isValidToken("ghp_aaaaaaaaaaaaaaaaaaaa\n"))
    }

    @Test func onlyGitHubWebURLsAreSafe() {
        #expect(Validation.isSafeGitHubWebURL(URL(string: "https://github.com/o/r/actions/runs/1")!))
        #expect(!Validation.isSafeGitHubWebURL(URL(string: "http://github.com/o/r")!))
        #expect(!Validation.isSafeGitHubWebURL(URL(string: "https://github.com.evil.io/o")!))
        #expect(!Validation.isSafeGitHubWebURL(URL(string: "https://user@github.com/o")!))
        #expect(!Validation.isSafeGitHubWebURL(URL(string: "file:///etc/passwd")!))
    }

    @Test func urlSegmentsCannotEscapePath() throws {
        let url = try GitHubClient.makeURL(path: ["repos", "o", "r?x=1#y", "a/b"], query: [])
        #expect(url.host == "api.github.com")
        #expect(url.scheme == "https")
        #expect(url.query == nil)
        #expect(url.fragment == nil)
        #expect(url.absoluteString == "https://api.github.com/repos/o/r%3Fx=1%23y/a%2Fb")
        #expect(throws: GitHubError.self) { try GitHubClient.makeURL(path: ["repos", ".."], query: []) }
        #expect(throws: GitHubError.self) { try GitHubClient.makeURL(path: ["repos", ""], query: []) }
    }

    @Test func dispatchRejectsBadInputBeforeNetwork() async {
        let client = GitHubClient(tokenProvider: { "ghp_" + String(repeating: "a", count: 36) })
        let repo = RepoRef(fullName: "o/r")!
        await #expect(throws: GitHubError.self) {
            try await client.dispatch(repo: repo, workflowID: 1, ref: "a..b", inputs: [:])
        }
        await #expect(throws: GitHubError.self) {
            try await client.dispatch(repo: repo, workflowID: 1, ref: "main", inputs: ["bad key": "x"])
        }
    }

    @Test func missingTokenFailsFast() async {
        let client = GitHubClient(tokenProvider: { nil })
        await #expect(throws: GitHubError.missingToken) { try await client.currentUser() }
    }
}
