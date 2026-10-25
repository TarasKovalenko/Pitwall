import Foundation
import Testing
@testable import PitwallCore
import PitwallTestSupport

private let validToken = "ghp_" + String(repeating: "c", count: 36)

@MainActor
@Suite struct RunStoreLifecycleTests {
    let api = FakeGitHub()

    func makeStore(tokens: MemoryTokens = MemoryTokens(validToken), repos: [String] = ["o/r"], sleep: @escaping Sleeper) -> RunStore {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "pitwall-tests-\(UUID().uuidString)")!)
        settings.trackedRepos = repos.compactMap(RepoRef.init(fullName:))
        return RunStore(settings: settings, tokens: tokens, api: api, sleep: sleep)
    }

    func ref(_ name: String) -> RepoRef { RepoRef(fullName: name)! }

    @Test func overallStatusPicksTheMostUrgent() async {
        let store = makeStore(repos: ["o/a", "o/b"], sleep: ManualSleeper().sleep)
        await api.set(runs: [makeRun(id: 1, status: "completed", conclusion: "success")], for: ref("o/a"))
        await store.refresh()
        #expect(store.overallStatus == .idle)

        await api.set(runsError: .notFound, for: ref("o/b"))
        await store.refresh()
        #expect(store.overallStatus == .error)

        await api.set(runs: [makeRun(id: 2, status: "completed", conclusion: "failure")], for: ref("o/a"))
        await store.refresh()
        #expect(store.overallStatus == .failing)
        #expect(store.repos[0].latestRun?.id == 2)
        #expect(store.repos[0].id == ref("o/a"))

        await api.set(runs: [makeRun(id: 3, status: "in_progress"), makeRun(id: 4, status: "queued")], for: ref("o/a"))
        await store.refresh()
        #expect(store.overallStatus == .running(2))
    }

    @Test func loopRefreshesThenWaitsUntilStopped() async {
        let sleeper = ManualSleeper()
        let store = makeStore(sleep: sleeper.sleep)
        store.start()
        store.start() // second call is a no-op
        let waiting = await eventually { sleeper.requested.count == 1 }
        #expect(waiting)
        #expect(await api.runsCalls == 1)
        // Nothing running, so it waits the idle interval.
        #expect(sleeper.requested == [.seconds(store.settings.idleInterval)])

        store.pokeSoon()
        let polledAgain = await eventually { sleeper.requested.count == 2 }
        #expect(polledAgain)
        #expect(await api.runsCalls == 2)
        store.stop()
    }

    @Test func signInSavesTheTokenAndLoadsTheUser() async throws {
        let tokens = MemoryTokens()
        let store = makeStore(tokens: tokens, sleep: ManualSleeper().sleep)
        #expect(store.authState == .signedOut)
        try await store.signIn(token: validToken)
        #expect(tokens.token() == validToken)
        #expect(store.authState == .signedIn(GitHubUser(login: "me", avatarURL: nil)))
        #expect(await api.cacheClears == 1)
    }

    @Test func signInWithARejectedTokenIsATokenProblem() async {
        let store = makeStore(tokens: MemoryTokens(), sleep: ManualSleeper().sleep)
        await api.set(userError: .unauthorized)
        await #expect(throws: GitHubError.unauthorized) { try await store.signIn(token: validToken) }
        guard case .tokenProblem = store.authState else { Issue.record("got \(store.authState)"); return }
    }

    @Test func switchingAccountsStartsClean() async throws {
        await api.set(runs: [makeRun(id: 1, status: "in_progress")], for: ref("o/r"))
        let store = makeStore(sleep: ManualSleeper().sleep)
        var events: [RunEvent] = []
        store.onEvent = { events.append($0) }
        await store.refresh()
        await api.set(user: GitHubUser(login: "other", avatarURL: nil))
        try await store.signIn(token: validToken)
        #expect(store.repos.map(\.runs) == [[]])
        #expect(store.authState.user?.login == "other")
        // The new account seeds fresh: its first poll reports nothing.
        await api.set(runs: [makeRun(id: 9, status: "in_progress")], for: ref("o/r"))
        await store.refresh()
        #expect(events.isEmpty)
    }

    @Test func availableRepositoriesComeFromGitHub() async throws {
        let repo = try JSONDecoder().decode(Repository.self, from: Data(
            #"{"id":1,"name":"r","full_name":"o/r","owner":{"login":"o"},"private":true,"default_branch":"main","pushed_at":null}"#.utf8))
        await api.set(repositories: [repo])
        let store = makeStore(sleep: ManualSleeper().sleep)
        #expect(try await store.availableRepositories() == [repo])
    }

    @Test func dispatchPollsAgainShortlyAfter() async throws {
        let sleeper = InstantSleeper()
        let store = makeStore(sleep: sleeper.sleep)
        try await store.dispatch(repo: ref("o/r"), workflow: makeWorkflow(id: 7), ref: "main", inputs: ["a": "b"])
        #expect(await api.actions == ["dispatch o/r 7 main"])
        let poked = await eventually { sleeper.requested.contains(.seconds(3)) && store.hasPendingPoke }
        #expect(poked)
        // The poke is pending, so the next wait is skipped.
        await store.sleep(seconds: 99)
        #expect(!sleeper.requested.contains(.seconds(99)))
    }

    @Test func liveStoreUsesTheGivenKeychainServiceAndRealSleep() async {
        let store = RunStore(settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                             keychainService: "dev.pitwall.tests.\(UUID().uuidString)")
        #expect(store.authState == .signedOut)
        let start = ContinuousClock.now
        await store.sleep(seconds: 0.02)
        #expect(ContinuousClock.now - start >= .milliseconds(15))
    }

    @Test func authStateHelpers() {
        #expect(AuthState.connecting.user == nil)
        #expect(!AuthState.signedOut.hasUsableToken)
        #expect(!AuthState.tokenProblem("x").hasUsableToken)
    }
}
