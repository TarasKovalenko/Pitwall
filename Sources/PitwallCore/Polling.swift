import Foundation

/// Decides how long to wait before the next refresh.
public struct PollPolicy: Sendable, Equatable {
    public var activeInterval: TimeInterval
    public var idleInterval: TimeInterval
    /// Below this many remaining requests we stop polling fast.
    public var lowBudgetThreshold: Int

    public init(activeInterval: TimeInterval = 8, idleInterval: TimeInterval = 60, lowBudgetThreshold: Int = 200) {
        self.activeInterval = activeInterval
        self.idleInterval = idleInterval
        self.lowBudgetThreshold = lowBudgetThreshold
    }

    public func nextDelay(hasActiveRuns: Bool, rateLimit: RateLimit?, now: Date = Date()) -> TimeInterval {
        var delay = hasActiveRuns ? activeInterval : idleInterval
        if let rl = rateLimit {
            let untilReset = max(rl.resetAt.timeIntervalSince(now), 1)
            if rl.remaining == 0 {
                delay = untilReset
            } else if rl.remaining < lowBudgetThreshold {
                // Spread what's left over the remaining window.
                delay = max(delay, untilReset / Double(rl.remaining), idleInterval)
            }
        }
        return min(max(delay, 2), 3600)
    }
}

/// Something worth telling the user about.
public enum RunEvent: Sendable, Equatable {
    case started(TrackedRun)
    case finished(TrackedRun)
}

/// Remembers the last seen status of each run and reports transitions.
/// The first snapshot per repo only seeds state, so launching the app
/// doesn't fire a notification for every old run.
public struct RunTransitionTracker: Sendable {
    private var lastStatus: [Int: RunStatus] = [:]
    private var seededRepos: Set<RepoRef> = []
    private let maxEntries = 2_000

    public init() {}

    public mutating func ingest(repo: RepoRef, runs: [WorkflowRun]) -> [RunEvent] {
        let seeded = seededRepos.contains(repo)
        seededRepos.insert(repo)
        var events: [RunEvent] = []
        for run in runs {
            let previous = lastStatus[run.id]
            lastStatus[run.id] = run.status
            guard seeded else { continue }
            let tracked = TrackedRun(repo: repo, run: run)
            switch (previous, run.status) {
            case (nil, let now) where now.isActive:
                events.append(.started(tracked))
            case (let before?, .completed) where before.isActive:
                events.append(.finished(tracked))
            case (nil, .completed) where Date().timeIntervalSince(run.updatedAt) < 300:
                // Started and finished between two polls.
                events.append(.finished(tracked))
            default:
                break
            }
        }
        if lastStatus.count > maxEntries {
            let keep = Set(runs.map(\.id))
            lastStatus = lastStatus.filter { keep.contains($0.key) }
        }
        return events
    }

    public mutating func forget(repo: RepoRef) {
        seededRepos.remove(repo)
    }
}
