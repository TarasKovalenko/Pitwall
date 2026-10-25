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

/// Where the account stands. The one place that decides "signed in".
public enum AuthState: Sendable, Equatable {
    /// No token saved.
    case signedOut
    /// GitHub rejected the token.
    case tokenProblem(String)
    /// Token saved, user not loaded yet (first launch, or offline).
    case connecting
    case signedIn(GitHubUser)

    /// A token is saved and GitHub hasn't rejected it.
    public var hasUsableToken: Bool {
        switch self {
        case .connecting, .signedIn: true
        case .signedOut, .tokenProblem: false
        }
    }

    public var user: GitHubUser? {
        if case .signedIn(let user) = self { return user }
        return nil
    }
}

/// Waits for a duration. Injected so tests don't sleep for real.
public typealias Sleeper = @Sendable (Duration) async throws -> Void

/// Polls GitHub for the tracked repositories and is the only thing the UI
/// talks to: auth, repo tracking, run actions and dispatch all go through here.
@MainActor
@Observable
public final class RunStore {
    public private(set) var repos: [RepoState] = []
    public private(set) var progress: [Int: RunProgress] = [:]
    public private(set) var rateLimit: RateLimit?
    public private(set) var isRefreshing = false

    public let settings: AppSettings

    /// Hook for the app layer (notifications live outside Core).
    @ObservationIgnored public var onEvent: (@MainActor (RunEvent) -> Void)?

    private var user: GitHubUser?
    private var authError: String?
    /// Mirrors whether the token store has a token, so views observe changes.
    private var hasToken: Bool
    private var finished = RecentlyFinished()

    @ObservationIgnored private let tokens: any TokenStoring
    @ObservationIgnored private let api: any GitHubAPI
    @ObservationIgnored private let sleepFor: Sleeper
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var tracker = RunTransitionTracker()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// Set by `pokeSoon`, cleared when a wait is skipped or cut short. Sticky,
    /// so a poke that arrives mid-refresh still shortens the next wait.
    @ObservationIgnored private var wakeRequested = false
    /// Bumped on sign-in and sign-out. Responses from an older epoch belong
    /// to the previous account and are dropped.
    @ObservationIgnored private var authEpoch = 0
    private let maxConcurrentRequests = 4
    private let maxProgressFetches = 6

    public init(
        settings: AppSettings,
        tokens: any TokenStoring,
        api: any GitHubAPI,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.tokens = tokens
        self.api = api
        self.sleepFor = sleep
        self.now = now
        hasToken = tokens.token() != nil
        syncRepoList()
    }

    /// The real thing: Keychain token, live GitHub API.
    public convenience init(settings: AppSettings, keychainService: String = TokenStore.defaultService) {
        let tokens = TokenStore(service: keychainService)
        self.init(settings: settings, tokens: tokens, api: GitHubClient(tokenProvider: { [tokens] in tokens.token() }))
    }

    // MARK: Derived

    public var authState: AuthState {
        if !hasToken { return .signedOut }
        if let authError { return .tokenProblem(authError) }
        if let user { return .signedIn(user) }
        return .connecting
    }

    /// Runs that finished in the last few seconds, shown briefly in the notch.
    public var recentlyFinished: [TrackedRun] { finished.runs }

    public var activeRuns: [TrackedRun] {
        repos.flatMap { state in state.activeRuns.map { TrackedRun(repo: state.ref, run: $0) } }
            .sorted { $0.run.createdAt > $1.run.createdAt }
    }

    public var overallStatus: OverallStatus {
        guard authState.hasUsableToken else { return .signedOut }
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
                await self.waitForNextCycle()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
    }

    /// Cut the current (or next) wait short, e.g. after the user dispatches a run.
    public func pokeSoon() {
        wakeRequested = true
        sleeper?.cancel()
    }

    /// For tests: a poke is waiting to skip the next sleep.
    var hasPendingPoke: Bool { wakeRequested }

    func waitForNextCycle() async {
        let delay = settings.pollPolicy.nextDelay(hasActiveRuns: !activeRuns.isEmpty, rateLimit: rateLimit, now: now())
        await sleep(seconds: delay)
    }

    func sleep(seconds: TimeInterval) async {
        if wakeRequested {
            wakeRequested = false
            return
        }
        let sleepFor = self.sleepFor
        let sleeper = Task<Void, Never> { _ = try? await sleepFor(.seconds(seconds)) }
        self.sleeper = sleeper
        await sleeper.value
        self.sleeper = nil
        wakeRequested = false
    }

    // MARK: Auth

    public func signIn(token: String) async throws {
        try tokens.save(token)
        resetAccountState()
        hasToken = true
        await api.clearCache()
        try await loadUser()
        pokeSoon()
    }

    public func signOut() async {
        tokens.delete()
        resetAccountState()
        hasToken = false
        await api.clearCache()
    }

    private func resetAccountState() {
        authEpoch += 1
        user = nil
        authError = nil
        rateLimit = nil
        progress = [:]
        repos = repos.map { RepoState(ref: $0.ref) }
        finished.removeAll()
        // A new account seeds fresh, so it doesn't notify about old runs.
        tracker = RunTransitionTracker()
    }

    private func loadUser() async throws {
        let epoch = authEpoch
        do {
            let loaded = try await api.currentUser()
            guard epoch == authEpoch else { return }
            user = loaded
        } catch {
            if epoch == authEpoch, case GitHubError.unauthorized = error { authError = error.localizedDescription }
            throw error
        }
    }

    // MARK: Repos

    public func track(_ ref: RepoRef) {
        settings.track(ref)
        syncRepoList()
        pokeSoon()
    }

    public func untrack(_ ref: RepoRef) {
        settings.untrack(ref)
        syncRepoList()
    }

    /// Repositories the signed-in user can pick from.
    public func availableRepositories() async throws -> [Repository] {
        try await api.repositories()
    }

    private func syncRepoList() {
        let wanted = settings.trackedRepos
        let existing = Dictionary(uniqueKeysWithValues: repos.map { ($0.ref, $0) })
        for gone in existing.keys where !wanted.contains(gone) { tracker.forget(repo: gone) }
        let next = wanted.map { existing[$0] ?? RepoState(ref: $0) }
        if next != repos { repos = next }
    }

    // MARK: Refresh

    public func refresh() async {
        guard !isRefreshing, hasToken else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let epoch = authEpoch

        // Picks up any change to `settings.trackedRepos` made elsewhere.
        syncRepoList()
        if user == nil {
            do { try await loadUser() } catch { return }
        }

        let results = await fetchRuns(repos.map(\.ref))
        guard epoch == authEpoch else { return }
        var events: [RunEvent] = []
        let now = now()
        for (ref, result) in results {
            guard let index = repos.firstIndex(where: { $0.ref == ref }) else { continue }
            switch result {
            case .success(let runs):
                events += tracker.ingest(repo: ref, runs: runs, now: now)
                if repos[index].runs != runs { repos[index].runs = runs }
                repos[index].error = nil
                repos[index].lastUpdated = now
            case .failure(let error):
                repos[index].error = error.localizedDescription
                if case GitHubError.unauthorized = error { authError = error.localizedDescription }
            }
        }

        let active = Array(activeRuns.prefix(maxProgressFetches))
        let fetched = await fetchProgress(active)
        let limit = await api.rateLimit
        guard epoch == authEpoch else { return }
        let keep = Set(active.map(\.run.id))
        var next = progress.filter { keep.contains($0.key) }
        next.merge(fetched) { _, new in new }
        if next != progress { progress = next }
        if limit != rateLimit { rateLimit = limit }
        handle(events)
    }

    private func fetchRuns(_ refs: [RepoRef]) async -> [(RepoRef, Result<[WorkflowRun], Error>)] {
        let api = self.api
        let limit = maxConcurrentRequests
        @Sendable func fetch(_ ref: RepoRef) async -> (RepoRef, Result<[WorkflowRun], Error>) {
            do { return (ref, .success(try await api.runs(for: ref))) }
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
    private func fetchProgress(_ active: [TrackedRun]) async -> [Int: RunProgress] {
        let api = self.api
        return await withTaskGroup(of: (Int, RunProgress?).self) { group in
            for item in active {
                group.addTask {
                    let jobs = try? await api.jobs(for: item.repo, runID: item.run.id)
                    return (item.run.id, jobs.map(RunProgress.init(jobs:)))
                }
            }
            var out: [Int: RunProgress] = [:]
            for await (id, p) in group { if let p { out[id] = p } }
            return out
        }
    }

    private func handle(_ events: [RunEvent]) {
        var added = false
        for event in events {
            if case .finished(let run) = event {
                finished.add(run, now: now())
                added = true
            }
            onEvent?(event)
        }
        if added { scheduleExpiry() }
    }

    /// One timer for the oldest finished run, re-armed after each expiry.
    private func scheduleExpiry() {
        expiry?.cancel()
        guard let due = finished.nextExpiry else { return }
        let delay = max(due.timeIntervalSince(now()), 0)
        let sleepFor = self.sleepFor
        expiry = Task { [weak self] in
            do { try await sleepFor(.seconds(delay)) } catch { return }
            guard let self else { return }
            // We slept until `due`, so treat it as reached even if the clock lags.
            self.finished.expire(now: max(self.now(), due))
            self.scheduleExpiry()
        }
    }

    // MARK: Actions

    public func perform(_ action: RunAction, on run: TrackedRun) async throws {
        switch action {
        case .cancel:
            try await api.cancel(repo: run.repo, runID: run.run.id)
        case .rerun(let failedOnly):
            try await api.rerun(repo: run.repo, runID: run.run.id, failedOnly: failedOnly)
        }
        pokeSoon()
    }

    public func dispatchOptions(for repo: RepoRef) async throws -> DispatchOptions {
        let api = self.api
        async let workflows = api.workflows(for: repo)
        async let branches = api.branches(for: repo)
        async let tags = api.tags(for: repo)
        return try await DispatchOptions(workflows: workflows, branches: branches.map(\.name), tags: tags.map(\.name))
    }

    /// The inputs `workflow` declares at `ref`. Nil if it has no
    /// `workflow_dispatch` trigger there; throws if the file can't be read.
    public func dispatchSpec(repo: RepoRef, workflow: Workflow, ref: GitRef) async throws -> DispatchSpec? {
        let source = try await api.workflowFile(repo: repo, path: workflow.path, ref: ref.name)
        return try DispatchSpec.parse(workflowYAML: source)
    }

    public func dispatch(repo: RepoRef, workflow: Workflow, ref: String, inputs: [String: String]) async throws {
        try await api.dispatch(repo: repo, workflowID: workflow.id, ref: ref, inputs: inputs)
        // The new run shows up in the API a moment later.
        let sleepFor = self.sleepFor
        Task { [weak self] in
            try? await sleepFor(.seconds(3))
            self?.pokeSoon()
        }
    }
}
