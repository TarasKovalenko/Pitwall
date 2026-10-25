import Foundation

// MARK: - GitHub API payloads (only the fields we use)

public struct GitHubUser: Codable, Sendable, Equatable {
    public let login: String
    public let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }
}

public struct Repository: Codable, Sendable, Identifiable, Hashable {
    public struct Owner: Codable, Sendable, Hashable {
        public let login: String
    }

    public let id: Int
    public let name: String
    public let fullName: String
    public let owner: Owner
    public let isPrivate: Bool
    public let defaultBranch: String
    public let pushedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, owner
        case fullName = "full_name"
        case isPrivate = "private"
        case defaultBranch = "default_branch"
        case pushedAt = "pushed_at"
    }
}

public struct Workflow: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let name: String
    public let path: String
    public let state: String

    public var isActive: Bool { state == "active" }
}

struct WorkflowList: Codable, Sendable {
    let workflows: [Workflow]
}

public enum RunStatus: String, Codable, Sendable {
    case queued, inProgress = "in_progress", completed, waiting, requested, pending
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RunStatus(rawValue: raw) ?? .unknown
    }

    public var isActive: Bool { self != .completed && self != .unknown }
}

public enum RunConclusion: String, Codable, Sendable {
    case success, failure, cancelled, skipped, neutral, stale
    case timedOut = "timed_out"
    case actionRequired = "action_required"
    case startupFailure = "startup_failure"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RunConclusion(rawValue: raw) ?? .unknown
    }

    public var isFailure: Bool {
        switch self {
        case .failure, .timedOut, .startupFailure, .actionRequired: true
        default: false
        }
    }
}

public struct WorkflowRun: Codable, Sendable, Identifiable, Hashable {
    public struct Actor: Codable, Sendable, Hashable {
        public let login: String
    }

    public let id: Int
    public let name: String?
    public let displayTitle: String?
    public let status: RunStatus
    public let conclusion: RunConclusion?
    public let headBranch: String?
    public let event: String
    public let htmlURL: URL
    public let runNumber: Int
    public let runAttempt: Int?
    public let workflowID: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let runStartedAt: Date?
    public let actor: Actor?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, event, actor
        case displayTitle = "display_title"
        case headBranch = "head_branch"
        case htmlURL = "html_url"
        case runNumber = "run_number"
        case runAttempt = "run_attempt"
        case workflowID = "workflow_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case runStartedAt = "run_started_at"
    }

    public var title: String { displayTitle ?? name ?? "Run #\(runNumber)" }
}

struct WorkflowRunList: Codable, Sendable {
    let workflowRuns: [WorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

public struct Job: Codable, Sendable, Identifiable, Hashable {
    public struct Step: Codable, Sendable, Hashable {
        public let name: String
        public let status: RunStatus
        public let conclusion: RunConclusion?
        public let number: Int
    }

    public let id: Int
    public let name: String
    public let status: RunStatus
    public let conclusion: RunConclusion?
    public let steps: [Step]?
}

struct JobList: Codable, Sendable {
    let totalCount: Int
    let jobs: [Job]

    enum CodingKeys: String, CodingKey {
        case jobs
        case totalCount = "total_count"
    }
}

public struct Branch: Codable, Sendable, Hashable {
    public let name: String
}

public struct RateLimit: Sendable, Equatable {
    public let limit: Int
    public let remaining: Int
    public let resetAt: Date
}

// MARK: - Derived view state

/// Progress of an active run, computed from its jobs.
public struct RunProgress: Sendable, Equatable {
    public let completedJobs: Int
    public let totalJobs: Int
    public let currentJob: String?
    public let currentStep: String?
    public let hasFailure: Bool

    public var fraction: Double {
        totalJobs == 0 ? 0 : Double(completedJobs) / Double(totalJobs)
    }

    /// "3/5 jobs"
    public var jobsText: String { "\(completedJobs)/\(totalJobs) jobs" }

    /// "build › Run tests", or nil when nothing is running yet.
    public var currentActivity: String? {
        guard let currentJob else { return nil }
        return [currentJob, currentStep].compactMap { $0 }.joined(separator: " › ")
    }

    public init(jobs: [Job]) {
        totalJobs = jobs.count
        completedJobs = jobs.filter { $0.status == .completed }.count
        hasFailure = jobs.contains { $0.conclusion?.isFailure == true }
        let running = jobs.first { $0.status == .inProgress }
        currentJob = running?.name
        currentStep = running?.steps?.first { $0.status == .inProgress }?.name
    }
}

/// A run tagged with the repository it belongs to.
public struct TrackedRun: Sendable, Identifiable, Hashable {
    public let repo: RepoRef
    public let run: WorkflowRun
    public var id: Int { run.id }

    public init(repo: RepoRef, run: WorkflowRun) {
        self.repo = repo
        self.run = run
    }
}

/// Something the user can do to a run from the menu or the notch.
public enum RunAction: Sendable, Hashable {
    case cancel
    case rerun(failedOnly: Bool)
}

extension WorkflowRun {
    /// The one-click action: cancel while running, otherwise re-run
    /// (only the failed jobs if something failed).
    public var primaryAction: RunAction {
        status.isActive ? .cancel : .rerun(failedOnly: conclusion?.isFailure == true)
    }

    /// Everything offered in the context menu, primary action first.
    public var availableActions: [RunAction] {
        if status.isActive { return [.cancel] }
        return conclusion?.isFailure == true ? [.rerun(failedOnly: true), .rerun(failedOnly: false)] : [.rerun(failedOnly: false)]
    }
}

/// What the "Run workflow" form can offer for a repository.
public struct DispatchOptions: Sendable, Equatable {
    public let workflows: [Workflow]
    public let branches: [String]
    /// Pre-selected branch: a conventional default if the repo has one.
    public let suggestedBranch: String?

    public init(workflows: [Workflow], branches: [String]) {
        self.workflows = workflows.filter(\.isActive)
        self.branches = branches
        suggestedBranch = ["main", "master", "develop"].first(where: branches.contains) ?? branches.first
    }
}
