import Foundation
import PitwallCore

public final class MemoryTokens: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    public init(_ value: String? = nil) { self.value = value }

    public func token() -> String? { lock.withLock { value } }
    public func save(_ token: String) throws { lock.withLock { value = token } }
    public func delete() { lock.withLock { value = nil } }
}

/// In-memory GitHub. Records how many `runs` calls overlap.
public actor FakeGitHub: GitHubAPI {
    public init() {}
    public var user = GitHubUser(login: "me", avatarURL: nil)
    public var userError: GitHubError?
    public var runsByRepo: [RepoRef: [WorkflowRun]] = [:]
    public var runsError: [RepoRef: GitHubError] = [:]
    public var jobsByRun: [Int: [Job]] = [:]
    public var workflowList: [Workflow] = []
    public var branchList: [Branch] = []
    public var tagList: [Tag] = []
    public var files: [String: String] = [:]
    public private(set) var fileRequests: [String] = []
    public var rateLimit: RateLimit?
    public func set(rateLimit: RateLimit?) { self.rateLimit = rateLimit }
    /// Runs before each `runs` call returns; lets a test act mid-refresh.
    public var onRuns: (@Sendable () async -> Void)?

    public private(set) var runsCalls = 0
    public private(set) var jobsCalls: [Int] = []
    public private(set) var inFlight = 0
    public private(set) var maxInFlight = 0
    public private(set) var actions: [String] = []
    public private(set) var cacheClears = 0

    public func set(runs: [WorkflowRun], for repo: RepoRef) { runsByRepo[repo] = runs }
    public func set(runsError: GitHubError?, for repo: RepoRef) { self.runsError[repo] = runsError }
    public func set(jobs: [Job], for runID: Int) { jobsByRun[runID] = jobs }
    public func set(userError: GitHubError?) { self.userError = userError }
    public func set(user: GitHubUser) { self.user = user }
    public func set(workflows: [Workflow], branches: [Branch], tags: [Tag] = []) {
        workflowList = workflows; branchList = branches; tagList = tags
    }
    public func set(file: String, path: String, ref: String) { files["\(path)@\(ref)"] = file }
    public func set(onRuns: (@Sendable () async -> Void)?) { self.onRuns = onRuns }

    public func currentUser() async throws -> GitHubUser {
        if let userError { throw userError }
        return user
    }

    public var repositoryList: [Repository] = []
    public func set(repositories: [Repository]) { repositoryList = repositories }
    public func repositories() async throws -> [Repository] { repositoryList }

    public func runs(for repo: RepoRef) async throws -> [WorkflowRun] {
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

    public func jobs(for repo: RepoRef, runID: Int) async throws -> [Job] {
        jobsCalls.append(runID)
        return jobsByRun[runID] ?? []
    }

    public func workflows(for repo: RepoRef) async throws -> [Workflow] { workflowList }
    public func branches(for repo: RepoRef) async throws -> [Branch] { branchList }
    public func tags(for repo: RepoRef) async throws -> [Tag] { tagList }

    public func workflowFile(repo: RepoRef, path: String, ref: String) async throws -> String {
        fileRequests.append("\(path)@\(ref)")
        guard let file = files["\(path)@\(ref)"] else { throw GitHubError.notFound }
        return file
    }

    public func dispatch(repo: RepoRef, workflowID: Int, ref: String, inputs: [String: String]) async throws {
        actions.append("dispatch \(repo.fullName) \(workflowID) \(ref)")
    }

    public func rerun(repo: RepoRef, runID: Int, failedOnly: Bool) async throws {
        actions.append("rerun \(runID) failedOnly=\(failedOnly)")
    }

    public func cancel(repo: RepoRef, runID: Int) async throws {
        actions.append("cancel \(runID)")
    }

    public func clearCache() async { cacheClears += 1 }
}

/// Replays canned responses and records the requests it was given.
public final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let lock = NSLock()
    private var handlers: [Handler]
    private var _requests: [URLRequest] = []

    public init(_ handlers: [Handler]) { self.handlers = handlers }

    public var requests: [URLRequest] { lock.withLock { _requests } }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler: Handler = lock.withLock {
            _requests.append(request)
            return handlers.isEmpty ? Self.unscripted : handlers.removeFirst()
        }
        return try await handler(request)
    }

    private static let unscripted: Handler = { _ in throw GitHubError.transport("no scripted response") }

    public static func respond(_ status: Int, body: String = "{}", headers: [String: String] = [:]) -> Handler {
        { request in
            let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (Data(body.utf8), http)
        }
    }
}

/// Returns at once and records each request.
public final class InstantSleeper: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var _requested: [Duration] = []
    public var requested: [Duration] { lock.withLock { _requested } }

    public var sleep: Sleeper {
        { [self] duration in lock.withLock { _requested.append(duration) } }
    }
}

/// A sleeper that never sleeps for real: records the request, then waits
/// until cancelled or released.
public final class ManualSleeper: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var _requested: [Duration] = []
    public var requested: [Duration] { lock.withLock { _requested } }

    public var sleep: Sleeper {
        { [self] duration in
            lock.withLock { _requested.append(duration) }
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

public func makeJob(id: Int, status: String, conclusion: String? = nil) -> Job {
    let json = """
    {"id": \(id), "name": "job\(id)", "status": "\(status)",
     "conclusion": \(conclusion.map { "\"\($0)\"" } ?? "null"), "steps": []}
    """
    return try! JSONDecoder().decode(Job.self, from: Data(json.utf8))
}

public func makeWorkflow(id: Int, state: String = "active") -> Workflow {
    Workflow(id: id, name: "wf\(id)", path: ".github/workflows/wf\(id).yml", state: state)
}

/// Polls `condition` for up to a second. For state that settles on another task.
@MainActor
public func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

public func makeRun(id: Int, status: String, conclusion: String? = nil, updated: Date = Date(), started: Date? = nil) -> WorkflowRun {
    let iso = ISO8601DateFormatter()
    let json = """
    {"id": \(id), "name": "CI", "display_title": "Fix thing", "status": "\(status)",
     "conclusion": \(conclusion.map { "\"\($0)\"" } ?? "null"), "head_branch": "main",
     "event": "push", "html_url": "https://github.com/o/r/actions/runs/\(id)", "run_number": \(id),
     "run_attempt": 1, "workflow_id": 7, "created_at": "\(iso.string(from: updated))",
     "updated_at": "\(iso.string(from: updated))", "run_started_at": \(started.map { "\"\(iso.string(from: $0))\"" } ?? "null"), "actor": {"login": "me"}}
    """
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return try! d.decode(WorkflowRun.self, from: Data(json.utf8))
}
