import Foundation
import Observation

public struct RepoState: Sendable, Identifiable, Equatable {
    public let ref: RepoRef
    public var runs: [WorkflowRun] = []
    public var error: String?
    public var lastUpdated: Date?
    public var id: RepoRef { ref }

    public var latestRun: WorkflowRun? { runs.first }
    public var activeRuns: [WorkflowRun] { runs.filter { $0.status.isActive } }
}

public enum OverallStatus: Sendable, Equatable {
    case signedOut, idle, running(Int), failing, error
}

@MainActor
@Observable
public final class RunStore {
    public private(set) var repos: [RepoState] = []
    public private(set) var progress: [Int: RunProgress] = [:]
    public private(set) var user: GitHubUser?
    public private(set) var authError: String?
    public private(set) var rateLimit: RateLimit?
    public private(set) var isRefreshing = false
    /// Runs that finished in the last few seconds, shown briefly in the notch.
    public private(set) var recentlyFinished: [TrackedRun] = []

    public let settings: AppSettings
    public let tokens: TokenStore
    public let client: GitHubClient

    /// Hook for the app layer (notifications live outside Core).
    @ObservationIgnored public var onEvent: (@MainActor (RunEvent) -> Void)?

    @ObservationIgnored private var tracker = RunTransitionTracker()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    private let maxConcurrentRequests = 4
    private let maxProgressFetches = 6

    public init(settings: AppSettings, tokens: TokenStore = TokenStore()) {
        self.settings = settings
        self.tokens = tokens
        self.client = GitHubClient(tokenProvider: { [tokens] in tokens.token() })
        syncRepoList()
    }

    // MARK: Derived

    public var activeRuns: [TrackedRun] {
        repos.flatMap { state in state.activeRuns.map { TrackedRun(repo: state.ref, run: $0) } }
            .sorted { $0.run.createdAt > $1.run.createdAt }
    }

    public var overallStatus: OverallStatus {
        if tokens.token() == nil || authError != nil { return .signedOut }
        let active = repos.reduce(0) { $0 + $1.activeRuns.count }
        if active > 0 { return .running(active) }
        if repos.contains(where: { $0.latestRun?.conclusion?.isFailure == true }) { return .failing }
        if repos.contains(where: { $0.error != nil }) { return .error }
        return .idle
    }

    // MARK: Lifecycle

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let delay = self.settings.pollPolicy.nextDelay(
                    hasActiveRuns: !self.activeRuns.isEmpty, rateLimit: self.rateLimit)
                await self.sleep(seconds: delay)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        wakeUp()
    }

    /// Cut the current wait short, e.g. after the user dispatches a run.
    public func pokeSoon() {
        wakeUp()
    }

    private func sleep(seconds: TimeInterval) async {
        let sleeper = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(seconds)) }
        self.sleeper = sleeper
        await sleeper.value
        self.sleeper = nil
    }

    private func wakeUp() {
        sleeper?.cancel()
    }

    // MARK: Auth

    public func signIn(token: String) async throws {
        try tokens.save(token)
        await client.clearCache()
        authError = nil
        try await loadUser()
        pokeSoon()
    }

    public func signOut() async {
        tokens.delete()
        await client.clearCache()
        user = nil
        authError = nil
        progress = [:]
        repos = repos.map { RepoState(ref: $0.ref) }
    }

    private func loadUser() async throws {
        do {
            user = try await client.currentUser()
        } catch {
            if case GitHubError.unauthorized = error { authError = error.localizedDescription }
            throw error
        }
    }

    // MARK: Repos

    /// Call after `settings.trackedRepos` changes.
    public func syncRepoList() {
        let wanted = settings.trackedRepos
        let existing = Dictionary(uniqueKeysWithValues: repos.map { ($0.ref, $0) })
        for gone in existing.keys where !wanted.contains(gone) { tracker.forget(repo: gone) }
        repos = wanted.map { existing[$0] ?? RepoState(ref: $0) }
    }

    // MARK: Refresh

    public func refresh() async {
        guard !isRefreshing, tokens.token() != nil else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if user == nil {
            do { try await loadUser() } catch { return }
        }

        let refs = repos.map(\.ref)
        let results = await fetchRuns(refs)
        var events: [RunEvent] = []
        let now = Date()
        for (ref, result) in results {
            guard let index = repos.firstIndex(where: { $0.ref == ref }) else { continue }
            switch result {
            case .success(let runs):
                events += tracker.ingest(repo: ref, runs: runs)
                if repos[index].runs != runs { repos[index].runs = runs }
                repos[index].error = nil
                repos[index].lastUpdated = now
            case .failure(let error):
                repos[index].error = error.localizedDescription
                if case GitHubError.unauthorized = error { authError = error.localizedDescription }
            }
        }

        await refreshProgress()
        rateLimit = await client.rateLimit
        handle(events)
    }

    private func fetchRuns(_ refs: [RepoRef]) async -> [(RepoRef, Result<[WorkflowRun], Error>)] {
        let client = self.client
        let limit = maxConcurrentRequests
        @Sendable func fetch(_ ref: RepoRef) async -> (RepoRef, Result<[WorkflowRun], Error>) {
            do { return (ref, .success(try await client.runs(for: ref))) }
            catch { return (ref, .failure(error)) }
        }
        // Sliding window: start `limit` fetches, then one more each time one
        // finishes. Keep `group` out of nested functions: the earlier version
        // added tasks from a nested func capturing the group, and release
        // builds aborted in the concurrency runtime as soon as more than
        // `limit` repos were watched (debug builds were fine).
        return await withTaskGroup(of: (RepoRef, Result<[WorkflowRun], Error>).self) { group in
            var results: [(RepoRef, Result<[WorkflowRun], Error>)] = []
            var pending = refs[...]
            for ref in pending.prefix(limit) {
                group.addTask { await fetch(ref) }
            }
            pending = pending.dropFirst(limit)
            while let result = await group.next() {
                results.append(result)
                if let ref = pending.popFirst() {
                    group.addTask { await fetch(ref) }
                }
            }
            return results
        }
    }

    /// Jobs are only fetched for runs that are still going, newest first.
    private func refreshProgress() async {
        let active = Array(activeRuns.prefix(maxProgressFetches))
        let client = self.client
        let fetched = await withTaskGroup(of: (Int, RunProgress?).self) { group in
            for item in active {
                group.addTask {
                    let jobs = try? await client.jobs(for: item.repo, runID: item.run.id)
                    return (item.run.id, jobs.map(RunProgress.init(jobs:)))
                }
            }
            var out: [Int: RunProgress] = [:]
            for await (id, p) in group { if let p { out[id] = p } }
            return out
        }
        let keep = Set(active.map(\.run.id))
        var next = progress.filter { keep.contains($0.key) }
        next.merge(fetched) { _, new in new }
        if next != progress { progress = next }
    }

    private func handle(_ events: [RunEvent]) {
        for event in events {
            if case .finished(let run) = event {
                recentlyFinished.insert(run, at: 0)
                recentlyFinished = Array(recentlyFinished.prefix(5))
                let id = run.id
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    self?.recentlyFinished.removeAll { $0.id == id }
                }
            }
            onEvent?(event)
        }
    }

    // MARK: Actions

    public func rerun(_ run: TrackedRun, failedOnly: Bool) async throws {
        try await client.rerun(repo: run.repo, runID: run.run.id, failedOnly: failedOnly)
        pokeSoon()
    }

    public func cancel(_ run: TrackedRun) async throws {
        try await client.cancel(repo: run.repo, runID: run.run.id)
        pokeSoon()
    }

    public func dispatch(repo: RepoRef, workflow: Workflow, ref: String, inputs: [String: String]) async throws {
        try await client.dispatch(repo: repo, workflowID: workflow.id, ref: ref, inputs: inputs)
        // The new run shows up in the API a moment later.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.pokeSoon()
        }
    }
}
