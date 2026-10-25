import Foundation
import Testing
@testable import PitwallCore
import PitwallTestSupport

private let token = "ghp_" + String(repeating: "a", count: 36)
private let repo = RepoRef(fullName: "octo/app")!

/// Every endpoint: the request it sends and how it reads the reply.
@Suite struct GitHubEndpointTests {
    func client(_ transport: ScriptedTransport, etagCapacity: Int = 300) -> GitHubClient {
        GitHubClient(tokenProvider: { token }, transport: transport, etagCapacity: etagCapacity)
    }

    func json(_ items: Int, _ make: (Int) -> String) -> String { "[" + (0..<items).map(make).joined(separator: ",") + "]" }

    func repoJSON(_ i: Int) -> String {
        #"{"id":\#(i),"name":"r\#(i)","full_name":"o/r\#(i)","owner":{"login":"o"},"private":false,"default_branch":"main","pushed_at":null}"#
    }

    @Test func repositoriesPageUntilAShortPage() async throws {
        let transport = ScriptedTransport([
            ScriptedTransport.respond(200, body: json(100, repoJSON)),
            ScriptedTransport.respond(200, body: json(3, repoJSON)),
        ])
        let repos = try await client(transport).repositories()
        #expect(repos.count == 103)
        #expect(transport.requests.count == 2)
        let query = URLComponents(url: transport.requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(.init(name: "page", value: "2")))
        #expect(query.contains(.init(name: "sort", value: "pushed")))
        #expect(transport.requests[0].url!.path == "/user/repos")
    }

    @Test func repositoriesStopAfterFivePages() async throws {
        let transport = ScriptedTransport((0..<6).map { _ in ScriptedTransport.respond(200, body: json(100, repoJSON)) })
        let repos = try await client(transport).repositories()
        #expect(repos.count == 500)
        #expect(transport.requests.count == 5)
    }

    @Test func runsWorkflowsAndJobs() async throws {
        let run = #"{"id":1,"name":"CI","display_title":"t","status":"queued","conclusion":null,"head_branch":"main","event":"push","html_url":"https://github.com/o/r/actions/runs/1","run_number":1,"run_attempt":1,"workflow_id":7,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","run_started_at":null,"actor":null}"#
        let transport = ScriptedTransport([
            ScriptedTransport.respond(200, body: #"{"workflow_runs":[\#(run)]}"#),
            ScriptedTransport.respond(200, body: #"{"workflows":[{"id":7,"name":"CI","path":".github/workflows/ci.yml","state":"active"}]}"#),
            ScriptedTransport.respond(200, body: #"{"total_count":1,"jobs":[{"id":3,"name":"build","status":"queued","conclusion":null,"steps":null}]}"#),
        ])
        let c = client(transport)
        #expect(try await c.runs(for: repo).map(\.id) == [1])
        #expect(try await c.workflows(for: repo).map(\.path) == [".github/workflows/ci.yml"])
        #expect(try await c.jobs(for: repo, runID: 1).map(\.name) == ["build"])
        #expect(transport.requests.map { $0.url!.path } == [
            "/repos/octo/app/actions/runs", "/repos/octo/app/actions/workflows", "/repos/octo/app/actions/runs/1/jobs",
        ])
        #expect(transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func branchesAndTagsPage() async throws {
        let names = { (n: Int) in self.json(n) { #"{"name":"n\#($0)"}"# } }
        let transport = ScriptedTransport([
            ScriptedTransport.respond(200, body: names(100)),
            ScriptedTransport.respond(200, body: names(14)),
            ScriptedTransport.respond(200, body: names(2)),
        ])
        let c = client(transport)
        #expect(try await c.branches(for: repo).count == 114)
        #expect(try await c.tags(for: repo).count == 2)
        #expect(transport.requests.map { $0.url!.path } == ["/repos/octo/app/branches", "/repos/octo/app/branches", "/repos/octo/app/tags"])
    }

    @Test func workflowFileIsDecodedFromBase64() async throws {
        let yaml = "on: workflow_dispatch\n"
        // GitHub wraps base64 at 60 columns.
        let encoded = Data(yaml.utf8).base64EncodedString(options: .lineLength64Characters).replacingOccurrences(of: "\r\n", with: "\\n")
        let transport = ScriptedTransport([
            ScriptedTransport.respond(200, body: #"{"type":"file","size":\#(yaml.utf8.count),"encoding":"base64","content":"\#(encoded)"}"#),
        ])
        let text = try await client(transport).workflowFile(repo: repo, path: ".github/workflows/deploy.yml", ref: "v1.0")
        #expect(text == yaml)
        let url = transport.requests[0].url!
        #expect(url.path == "/repos/octo/app/contents/.github/workflows/deploy.yml")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems == [.init(name: "ref", value: "v1.0")])
    }

    @Test func workflowFileRefusesOtherPathsWithoutAsking() async {
        let transport = ScriptedTransport([])
        let c = client(transport)
        for path in ["../secrets.yml", ".github/workflows/../../x.yml", "src/main.yml", ".github/workflows/ci.txt",
                     ".github/workflows/sub/ci.yml", ".github/workflows/"] {
            await #expect(throws: GitHubError.self, "\(path)") {
                try await c.workflowFile(repo: repo, path: path, ref: "main")
            }
        }
        await #expect(throws: GitHubError.invalidInput("Invalid branch or tag name.")) {
            try await c.workflowFile(repo: repo, path: ".github/workflows/ci.yml", ref: "bad ref")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func workflowFileRejectsOddReplies() async {
        let replies = [
            #"{"type":"dir","size":0,"encoding":null,"content":null}"#,
            #"{"type":"file","size":99999999,"encoding":"base64","content":""}"#,
        ]
        for reply in replies {
            let transport = ScriptedTransport([ScriptedTransport.respond(200, body: reply)])
            await #expect(throws: GitHubError.invalidInput("The workflow file is too large to read.")) {
                try await client(transport).workflowFile(repo: repo, path: ".github/workflows/ci.yml", ref: "main")
            }
        }
        let notBase64 = ScriptedTransport([ScriptedTransport.respond(200, body: #"{"type":"file","size":3,"encoding":"none","content":"abc"}"#)])
        await #expect(throws: GitHubError.decoding) {
            try await client(notBase64).workflowFile(repo: repo, path: ".github/workflows/ci.yml", ref: "main")
        }
    }

    @Test func dispatchSendsRefAndInputs() async throws {
        let transport = ScriptedTransport([ScriptedTransport.respond(204, body: "")])
        try await client(transport).dispatch(repo: repo, workflowID: 7, ref: "v1.0", inputs: ["env": "prod"])
        let request = transport.requests[0]
        #expect(request.httpMethod == "POST")
        #expect(request.url!.path == "/repos/octo/app/actions/workflows/7/dispatches")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        #expect(body["ref"] as? String == "v1.0")
        #expect(body["inputs"] as? [String: String] == ["env": "prod"])
    }

    @Test func dispatchChecksInputsBeforeSending() async {
        let transport = ScriptedTransport([])
        let c = client(transport)
        let tooMany = Dictionary(uniqueKeysWithValues: (0...Validation.maxDispatchInputs).map { ("k\($0)", "v") })
        await #expect(throws: GitHubError.invalidInput("Too many inputs (max \(Validation.maxDispatchInputs)).")) {
            try await c.dispatch(repo: repo, workflowID: 1, ref: "main", inputs: tooMany)
        }
        await #expect(throws: GitHubError.invalidInput("Input k is too long.")) {
            try await c.dispatch(repo: repo, workflowID: 1, ref: "main",
                                 inputs: ["k": String(repeating: "x", count: Validation.maxInputValueLength + 1)])
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func rerunAndCancelPaths() async throws {
        let transport = ScriptedTransport((0..<3).map { _ in ScriptedTransport.respond(201, body: "") })
        let c = client(transport)
        try await c.rerun(repo: repo, runID: 5, failedOnly: false)
        try await c.rerun(repo: repo, runID: 5, failedOnly: true)
        try await c.cancel(repo: repo, runID: 5)
        #expect(transport.requests.map { $0.url!.path } == [
            "/repos/octo/app/actions/runs/5/rerun", "/repos/octo/app/actions/runs/5/rerun-failed-jobs",
            "/repos/octo/app/actions/runs/5/cancel",
        ])
        #expect(transport.requests.allSatisfy { $0.httpMethod == "POST" && $0.httpBody == nil })
    }

    @Test func statusCodesMapToErrors() async {
        let cases: [(Int, String, GitHubError)] = [
            (404, "{}", .notFound),
            (409, #"{"message":"conflict here"}"#, .validation("conflict here")),
            (422, "{}", .validation("invalid request")),
            (500, "{}", .http(500)),
        ]
        for (status, body, expected) in cases {
            let transport = ScriptedTransport([ScriptedTransport.respond(status, body: body)])
            await #expect(throws: expected) { try await client(transport).cancel(repo: repo, runID: 1) }
        }
    }

    @Test func apiMessagesAreCappedForTheUI() async {
        let long = String(repeating: "m", count: 500)
        let transport = ScriptedTransport([ScriptedTransport.respond(422, body: #"{"message":"\#(long)"}"#)])
        await #expect(throws: GitHubError.validation(String(repeating: "m", count: 200))) {
            try await client(transport).cancel(repo: repo, runID: 1)
        }
    }

    @Test func oldestETagIsEvictedAtCapacity() async throws {
        let user = #"{"login":"me","avatar_url":null}"#
        let transport = ScriptedTransport([
            ScriptedTransport.respond(200, body: user, headers: ["ETag": "\"u\""]),     // /user
            ScriptedTransport.respond(200, body: "[]", headers: ["ETag": "\"b\""]),     // branches
            ScriptedTransport.respond(200, body: "[]", headers: ["ETag": "\"t\""]),     // tags, evicts /user
            ScriptedTransport.respond(200, body: user),                                 // /user again
        ])
        let c = client(transport, etagCapacity: 2)
        _ = try await c.currentUser()
        _ = try await c.branches(for: repo)
        _ = try await c.tags(for: repo)
        _ = try await c.currentUser()
        #expect(transport.requests[3].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func tokenNeverLeavesTheAPIHost() async {
        let transport = ScriptedTransport([])
        let c = client(transport)
        await #expect(throws: GitHubError.self) { try await c.perform(URLRequest(url: URL(string: "https://evil.example/user")!)) }
        await #expect(throws: GitHubError.self) { try await c.perform(URLRequest(url: URL(string: "http://api.github.com/user")!)) }
        #expect(transport.requests.isEmpty)
    }

    @Test func everyErrorHasAMessage() {
        let all: [GitHubError] = [
            .missingToken, .unauthorized, .forbidden("x"), .notFound, .rateLimited(resetAt: Date()),
            .validation("x"), .http(500), .invalidInput("x"), .transport("x"), .decoding,
        ]
        for error in all { #expect(error.errorDescription?.isEmpty == false, "\(error)") }
        #expect(GitHubError.invalidInput("exact").errorDescription == "exact")
    }
}
