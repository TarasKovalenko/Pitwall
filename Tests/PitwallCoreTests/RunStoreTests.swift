import Foundation
import Testing
@testable import PitwallCore

@MainActor
@Suite struct RunStoreTests {
    let api = FakeGitHub()
    let tokens = MemoryTokens("ghp_" + String(repeating: "a", count: 36))
    let sleeper = ManualSleeper()

    func makeStore(repos: [String]) -> RunStore {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "pitwall-tests-\(UUID().uuidString)")!)
        settings.trackedRepos = repos.compactMap(RepoRef.init(fullName:))
        return RunStore(settings: settings, tokens: tokens, api: api, sleep: sleeper.sleep)
    }

    func ref(_ name: String) -> RepoRef { RepoRef(fullName: name)! }

    @Test func fetchesEveryRepoWithAtMostFourInFlight() async {
        let names = (1...7).map { "o/r\($0)" }
        for (i, name) in names.enumerated() {
            await api.set(runs: [makeRun(id: i + 1, status: "completed", conclusion: "success")], for: ref(name))
        }
        let store = makeStore(repos: names)
        await store.refresh()
        #expect(await api.runsCalls == 7)
        #expect(await api.maxInFlight <= 4)
        #expect(store.repos.allSatisfy { $0.runs.count == 1 })
        #expect(store.authState == .signedIn(GitHubUser(login: "me", avatarURL: nil)))
    }

    @Test func oneFailingRepoLeavesTheOthersAlone() async {
        await api.set(runsError: .notFound, for: ref("o/broken"))
        await api.set(runs: [makeRun(id: 1, status: "completed", conclusion: "success")], for: ref("o/fine"))
        let store = makeStore(repos: ["o/broken", "o/fine"])
        await store.refresh()
        #expect(store.repos[0].error != nil)
        #expect(store.repos[1].error == nil)
        #expect(store.repos[1].runs.count == 1)
        #expect(store.authState.user != nil)
    }

    @Test func rejectedTokenIsATokenProblem() async {
        await api.set(runsError: .unauthorized, for: ref("o/r"))
        let store = makeStore(repos: ["o/r"])
        await store.refresh()
        guard case .tokenProblem = store.authState else { Issue.record("got \(store.authState)"); return }
        #expect(store.overallStatus == .signedOut)
    }

    @Test func noTokenMeansNoRequests() async {
        tokens.delete()
        let store = makeStore(repos: ["o/r"])
        await store.refresh()
        #expect(store.authState == .signedOut)
        #expect(await api.runsCalls == 0)
    }

    @Test func offlineWithTokenIsConnecting() async {
        await api.set(userError: .transport("offline"))
        let store = makeStore(repos: ["o/r"])
        await store.refresh()
        #expect(store.authState == .connecting)
        #expect(store.authState.hasUsableToken)
    }

    @Test func progressIsFetchedForAtMostSixRunsAndPruned() async {
        let runs = (1...8).map { makeRun(id: $0, status: "in_progress", updated: Date().addingTimeInterval(Double($0))) }
        await api.set(runs: runs, for: ref("o/r"))
        for run in runs { await api.set(jobs: [makeJob(id: run.id, status: "in_progress")], for: run.id) }
        let store = makeStore(repos: ["o/r"])
        await store.refresh()
        #expect(await api.jobsCalls.count == 6)
        #expect(store.progress.count == 6)

        await api.set(runs: runs.map { makeRun(id: $0.id, status: "completed", conclusion: "success") }, for: ref("o/r"))
        await store.refresh()
        #expect(store.progress.isEmpty)
    }

    @Test func finishedRunIsReportedAndShownBriefly() async {
        await api.set(runs: [makeRun(id: 1, status: "in_progress")], for: ref("o/r"))
        let store = makeStore(repos: ["o/r"])
        var events: [RunEvent] = []
        store.onEvent = { events.append($0) }
        await store.refresh() // seeds
        await api.set(runs: [makeRun(id: 1, status: "completed", conclusion: "failure")], for: ref("o/r"))
        await store.refresh()

        #expect(events.count == 1)
        guard case .finished(let run) = events.first else { Issue.record("expected finish"); return }
        #expect(run.id == 1)
        #expect(store.recentlyFinished.map(\.id) == [1])
        // One expiry timer, armed for the 12 s lifetime.
        let armed = await eventually { sleeper.requested.contains { $0 > .seconds(11) && $0 <= .seconds(12) } }
        #expect(armed)
    }

    @Test func signOutResetsEverything() async {
        await api.set(runs: [makeRun(id: 1, status: "in_progress")], for: ref("o/r"))
        let store = makeStore(repos: ["o/r"])
        await store.refresh()
        await store.signOut()
        #expect(store.authState == .signedOut)
        #expect(store.repos.map(\.runs) == [[]])
        #expect(store.progress.isEmpty)
        #expect(tokens.token() == nil)
        #expect(await api.cacheClears == 1)
    }

    @Test func responsesFromBeforeSignOutAreDropped() async {
        await api.set(runs: [makeRun(id: 1, status: "in_progress")], for: ref("o/r"))
        let store = makeStore(repos: ["o/r"])
        await api.set(onRuns: { await store.signOut() })
        await store.refresh()
        #expect(store.repos.map(\.runs) == [[]])
        #expect(store.authState == .signedOut)
    }

    @Test func trackingAddsTheRepoAndPollsSoon() async {
        let store = makeStore(repos: [])
        store.track(ref("o/new"))
        #expect(store.repos.map(\.ref) == [ref("o/new")])
        #expect(store.settings.trackedRepos == [ref("o/new")])
        await store.sleep(seconds: 3600)
        #expect(sleeper.requested.isEmpty, "the poke should skip the wait")

        store.untrack(ref("o/new"))
        #expect(store.repos.isEmpty)
        #expect(store.settings.trackedRepos.isEmpty)
    }

    @Test func pokeDuringRefreshShortensTheNextWait() async {
        let store = makeStore(repos: ["o/r"])
        await api.set(onRuns: { await store.pokeSoon() })
        await store.refresh()
        await store.waitForNextCycle()
        #expect(sleeper.requested.isEmpty)
        // The poke is used up: the following wait sleeps normally.
        let wait = Task { await store.waitForNextCycle() }
        let slept = await eventually { sleeper.requested.count == 1 }
        #expect(slept)
        store.stop()
        await wait.value
    }

    @Test func actionsGoToGitHub() async throws {
        let store = makeStore(repos: ["o/r"])
        let failed = TrackedRun(repo: ref("o/r"), run: makeRun(id: 5, status: "completed", conclusion: "failure"))
        try await store.perform(failed.run.primaryAction, on: failed)
        let running = TrackedRun(repo: ref("o/r"), run: makeRun(id: 6, status: "in_progress"))
        try await store.perform(running.run.primaryAction, on: running)
        #expect(await api.actions == ["rerun 5 failedOnly=true", "cancel 6"])
    }

    @Test func dispatchOptionsSkipDisabledWorkflowsAndSuggestMain() async throws {
        await api.set(workflows: [makeWorkflow(id: 1), makeWorkflow(id: 2, state: "disabled_manually")],
                      branches: [Branch(name: "feature"), Branch(name: "main")])
        let store = makeStore(repos: ["o/r"])
        let options = try await store.dispatchOptions(for: ref("o/r"))
        #expect(options.workflows.map(\.id) == [1])
        #expect(options.suggestedBranch == "main")
    }
}
