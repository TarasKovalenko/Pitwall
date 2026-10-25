import Foundation
import Testing
@testable import PitwallCore

func makeRun(id: Int, status: String, conclusion: String? = nil, updated: Date = Date()) -> WorkflowRun {
    let iso = ISO8601DateFormatter()
    let json = """
    {"id": \(id), "name": "CI", "display_title": "Fix thing", "status": "\(status)",
     "conclusion": \(conclusion.map { "\"\($0)\"" } ?? "null"), "head_branch": "main",
     "event": "push", "html_url": "https://github.com/o/r/actions/runs/\(id)", "run_number": \(id),
     "run_attempt": 1, "workflow_id": 7, "created_at": "\(iso.string(from: updated))",
     "updated_at": "\(iso.string(from: updated))", "run_started_at": null, "actor": {"login": "me"}}
    """
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return try! d.decode(WorkflowRun.self, from: Data(json.utf8))
}

@Suite struct PollingTests {
    let repo = RepoRef(fullName: "o/r")!

    @Test func activeRunsPollFaster() {
        let p = PollPolicy(activeInterval: 8, idleInterval: 60)
        #expect(p.nextDelay(hasActiveRuns: true, rateLimit: nil) == 8)
        #expect(p.nextDelay(hasActiveRuns: false, rateLimit: nil) == 60)
    }

    @Test func backsOffWhenBudgetIsLow() {
        let now = Date()
        let p = PollPolicy(activeInterval: 8, idleInterval: 60, lowBudgetThreshold: 200)
        let empty = RateLimit(limit: 5000, remaining: 0, resetAt: now.addingTimeInterval(900))
        #expect(p.nextDelay(hasActiveRuns: true, rateLimit: empty, now: now) == 900)
        let low = RateLimit(limit: 5000, remaining: 10, resetAt: now.addingTimeInterval(1200))
        #expect(p.nextDelay(hasActiveRuns: true, rateLimit: low, now: now) == 120)
        let fine = RateLimit(limit: 5000, remaining: 4000, resetAt: now.addingTimeInterval(1200))
        #expect(p.nextDelay(hasActiveRuns: true, rateLimit: fine, now: now) == 8)
    }

    @Test func firstSnapshotOnlySeeds() {
        var t = RunTransitionTracker()
        let events = t.ingest(repo: repo, runs: [makeRun(id: 1, status: "in_progress"), makeRun(id: 2, status: "completed", conclusion: "success")])
        #expect(events.isEmpty)
    }

    @Test func reportsStartAndFinish() {
        var t = RunTransitionTracker()
        _ = t.ingest(repo: repo, runs: [makeRun(id: 1, status: "in_progress")])
        let started = t.ingest(repo: repo, runs: [makeRun(id: 2, status: "queued"), makeRun(id: 1, status: "in_progress")])
        #expect(started.count == 1)
        guard case .started(let s) = started.first else { Issue.record("expected start"); return }
        #expect(s.run.id == 2)

        let finished = t.ingest(repo: repo, runs: [makeRun(id: 2, status: "in_progress"), makeRun(id: 1, status: "completed", conclusion: "failure")])
        #expect(finished.count == 1)
        guard case .finished(let f) = finished.first else { Issue.record("expected finish"); return }
        #expect(f.run.id == 1)
        #expect(f.run.conclusion?.isFailure == true)

        // Same state again: nothing new.
        #expect(t.ingest(repo: repo, runs: [makeRun(id: 2, status: "in_progress"), makeRun(id: 1, status: "completed", conclusion: "failure")]).isEmpty)
    }

    @Test func fastRunBetweenPollsStillNotifies() {
        var t = RunTransitionTracker()
        _ = t.ingest(repo: repo, runs: [])
        let events = t.ingest(repo: repo, runs: [makeRun(id: 9, status: "completed", conclusion: "success")])
        #expect(events.count == 1)
        let old = t.ingest(repo: repo, runs: [makeRun(id: 10, status: "completed", conclusion: "success", updated: Date().addingTimeInterval(-3600))])
        #expect(old.isEmpty)
    }

    @Test func unknownStatusDecodesSafely() {
        let run = makeRun(id: 3, status: "some_future_status", conclusion: "brand_new")
        #expect(run.status == .unknown)
        #expect(run.conclusion == .unknown)
        #expect(!run.status.isActive)
    }

    @Test func progressFromJobs() throws {
        let json = """
        [{"id":1,"name":"build","status":"completed","conclusion":"success","steps":[]},
         {"id":2,"name":"test","status":"in_progress","conclusion":null,
          "steps":[{"name":"checkout","status":"completed","conclusion":"success","number":1},
                   {"name":"run tests","status":"in_progress","conclusion":null,"number":2}]},
         {"id":3,"name":"deploy","status":"queued","conclusion":null,"steps":null}]
        """
        let jobs = try JSONDecoder().decode([Job].self, from: Data(json.utf8))
        let p = RunProgress(jobs: jobs)
        #expect(p.completedJobs == 1)
        #expect(p.totalJobs == 3)
        #expect(p.currentJob == "test")
        #expect(p.currentStep == "run tests")
        #expect(!p.hasFailure)
    }
}
