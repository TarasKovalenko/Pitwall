import Foundation
@testable import PitwallCore

final class MemoryTokens: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) { self.value = value }

    func token() -> String? { lock.withLock { value } }
    func save(_ token: String) throws { lock.withLock { value = token } }
    func delete() { lock.withLock { value = nil } }
}

/// In-memory GitHub. Records how many `runs` calls overlap.
actor FakeGitHub: GitHubAPI {
    var user = GitHubUser(login: "me", avatarURL: nil)
    var userError: GitHubError?
    var runsByRepo: [RepoRef: [WorkflowRun]] = [:]
    var runsError: [RepoRef: GitHubError] = [:]
    var jobsByRun: [Int: [Job]] = [:]
    var workflowList: [Workflow] = []
    var branchList: [Branch] = []
    var rateLimit: RateLimit?
    /// Runs before each `runs` call returns; lets a test act mid-refresh.
    var onRuns: (@Sendable () async -> Void)?

    private(set) var runsCalls = 0
    private(set) var jobsCalls: [Int] = []
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var actions: [String] = []
    private(set) var cacheClears = 0

    func set(runs: [WorkflowRun], for repo: RepoRef) { runsByRepo[repo] = runs }
    func set(runsError: GitHubError?, for repo: RepoRef) { self.runsError[repo] = runsError }
    func set(jobs: [Job], for runID: Int) { jobsByRun[runID] = jobs }
    func set(userError: GitHubError?) { self.userError = userError }
    func set(user: GitHubUser) { self.user = user }
    func set(workflows: [Workflow], branches: [Branch]) { workflowList = workflows; branchList = branches }
    func set(onRuns: (@Sendable () async -> Void)?) { self.onRuns = onRuns }

    func currentUser() async throws -> GitHubUser {
        if let userError { throw userError }
        return user
    }

    func repositories() async throws -> [Repository] { [] }

    func runs(for repo: RepoRef) async throws -> [WorkflowRun] {
        runsCalls += 1
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        // Let other fetches start so overlap is observable.
        for _ in 0..<5 { await Task.yield() }
        if let onRuns { await onRuns() }
        if let error = runsError[repo] { throw error }
        return runsByRepo[repo] ?? []
    }

    func jobs(for repo: RepoRef, runID: Int) async throws -> [Job] {
        jobsCalls.append(runID)
        return jobsByRun[runID] ?? []
    }

    func workflows(for repo: RepoRef) async throws -> [Workflow] { workflowList }
    func branches(for repo: RepoRef) async throws -> [Branch] { branchList }

    func dispatch(repo: RepoRef, workflowID: Int, ref: String, inputs: [String: String]) async throws {
        actions.append("dispatch \(repo.fullName) \(workflowID) \(ref)")
    }

    func rerun(repo: RepoRef, runID: Int, failedOnly: Bool) async throws {
        actions.append("rerun \(runID) failedOnly=\(failedOnly)")
    }

    func cancel(repo: RepoRef, runID: Int) async throws {
        actions.append("cancel \(runID)")
    }

    func clearCache() async { cacheClears += 1 }
}

/// Replays canned responses and records the requests it was given.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let lock = NSLock()
    private var handlers: [Handler]
    private var _requests: [URLRequest] = []

    init(_ handlers: [Handler]) { self.handlers = handlers }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler: Handler = lock.withLock {
            _requests.append(request)
            return handlers.isEmpty ? Self.unscripted : handlers.removeFirst()
        }
        return try await handler(request)
    }

    private static let unscripted: Handler = { _ in throw GitHubError.transport("no scripted response") }

    static func respond(_ status: Int, body: String = "{}", headers: [String: String] = [:]) -> Handler {
        { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(body.utf8), http)
        }
    }
}

/// A sleeper that never sleeps for real: records the request, then waits
/// until cancelled or released.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var _requested: [Duration] = []
    var requested: [Duration] { lock.withLock { _requested } }

    var sleep: Sleeper {
        { [self] duration in
            lock.withLock { _requested.append(duration) }
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

func makeJob(id: Int, status: String, conclusion: String? = nil) -> Job {
    let json = """
    {"id": \(id), "name": "job\(id)", "status": "\(status)",
     "conclusion": \(conclusion.map { "\"\($0)\"" } ?? "null"), "steps": []}
    """
    return try! JSONDecoder().decode(Job.self, from: Data(json.utf8))
}

func makeWorkflow(id: Int, state: String = "active") -> Workflow {
    Workflow(id: id, name: "wf\(id)", path: ".github/workflows/wf\(id).yml", state: state)
}

/// Polls `condition` for up to a second. For state that settles on another task.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}
