import Foundation
import Testing
@testable import PitwallCore
import PitwallTestSupport

@Suite struct NotificationPolicyTests {
    let repo = RepoRef(fullName: "o/r")!
    let all = NotificationPreferences(onStart: true, onSuccess: true, onFailure: true)
    let none = NotificationPreferences(onStart: false, onSuccess: false, onFailure: false)

    func finished(_ conclusion: String) -> RunEvent {
        .finished(TrackedRun(repo: repo, run: makeRun(id: 1, status: "completed", conclusion: conclusion)))
    }

    @Test func passFailAndStartFollowPreferences() throws {
        let started = RunEvent.started(TrackedRun(repo: repo, run: makeRun(id: 1, status: "in_progress")))
        #expect(NotificationPolicy.content(for: started, preferences: all)?.title == "r: CI started")
        #expect(NotificationPolicy.content(for: started, preferences: none) == nil)

        let passed = try #require(NotificationPolicy.content(for: finished("success"), preferences: all))
        #expect(passed.title == "r: CI passed")
        #expect(!passed.playsSound)
        #expect(NotificationPolicy.content(for: finished("success"), preferences: none) == nil)

        let failed = try #require(NotificationPolicy.content(for: finished("timed_out"), preferences: all))
        #expect(failed.title == "r: CI failed")
        #expect(failed.playsSound)
        #expect(NotificationPolicy.content(for: finished("failure"), preferences: none) == nil)
    }

    @Test func quietConclusionsNeverNotify() {
        for conclusion in ["cancelled", "skipped", "neutral", "stale"] {
            #expect(NotificationPolicy.content(for: finished(conclusion), preferences: all) == nil, "\(conclusion)")
        }
    }

    @Test func contentCarriesRunDetails() throws {
        let c = try #require(NotificationPolicy.content(for: finished("success"), preferences: all))
        #expect(c.id == "run-1-1-completed")
        #expect(c.body == "Fix thing\nmain · #1")
        #expect(c.threadID == "o/r")
        #expect(c.url.absoluteString == "https://github.com/o/r/actions/runs/1")
        #expect(Validation.isSafeGitHubWebURL(c.url))
    }
}

@Suite struct RunActionTests {
    @Test func primaryActionDependsOnState() {
        #expect(makeRun(id: 1, status: "in_progress").primaryAction == .cancel)
        #expect(makeRun(id: 1, status: "queued").primaryAction == .cancel)
        #expect(makeRun(id: 1, status: "completed", conclusion: "failure").primaryAction == .rerun(failedOnly: true))
        #expect(makeRun(id: 1, status: "completed", conclusion: "success").primaryAction == .rerun(failedOnly: false))
    }

    @Test func failedRunsOfferBothReruns() {
        #expect(makeRun(id: 1, status: "completed", conclusion: "failure").availableActions
            == [.rerun(failedOnly: true), .rerun(failedOnly: false)])
        #expect(makeRun(id: 1, status: "completed", conclusion: "cancelled").availableActions == [.rerun(failedOnly: false)])
        #expect(makeRun(id: 1, status: "in_progress").availableActions == [.cancel])
    }

    @Test func progressText() {
        let p = RunProgress(jobs: [makeJob(id: 1, status: "completed", conclusion: "success"), makeJob(id: 2, status: "in_progress")])
        #expect(p.jobsText == "1/2 jobs")
        #expect(p.currentActivity == "job2")
        #expect(RunProgress(jobs: []).currentActivity == nil)
    }
}

@Suite struct RecentlyFinishedTests {
    let repo = RepoRef(fullName: "o/r")!
    func tracked(_ id: Int) -> TrackedRun { TrackedRun(repo: repo, run: makeRun(id: id, status: "completed", conclusion: "success")) }

    @Test func newestFirstAndCapped() {
        var list = RecentlyFinished(capacity: 3, lifetime: 12)
        let t0 = Date()
        for id in 1...5 { list.add(tracked(id), now: t0) }
        #expect(list.runs.map(\.id) == [5, 4, 3])
        list.add(tracked(4), now: t0)
        #expect(list.runs.map(\.id) == [4, 5, 3])
    }

    @Test func entriesExpireAfterTheirLifetime() {
        var list = RecentlyFinished(capacity: 5, lifetime: 12)
        let t0 = Date()
        list.add(tracked(1), now: t0)
        list.add(tracked(2), now: t0.addingTimeInterval(5))
        #expect(list.nextExpiry == t0.addingTimeInterval(12))
        list.expire(now: t0.addingTimeInterval(11))
        #expect(list.runs.count == 2)
        list.expire(now: t0.addingTimeInterval(12))
        #expect(list.runs.map(\.id) == [2])
        #expect(list.nextExpiry == t0.addingTimeInterval(17))
        list.expire(now: t0.addingTimeInterval(17))
        #expect(list.runs.isEmpty)
        #expect(list.nextExpiry == nil)
    }
}
