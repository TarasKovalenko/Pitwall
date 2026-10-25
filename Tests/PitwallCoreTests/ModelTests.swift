import Foundation
import Testing
@testable import PitwallCore
import PitwallTestSupport

@Suite struct ModelTests {
    @Test func repoRefCodableRoundTripAndRejectsJunk() throws {
        let ref = RepoRef(fullName: "octo/app")!
        #expect(ref.description == "octo/app")
        let data = try JSONEncoder().encode([ref])
        #expect(String(decoding: data, as: UTF8.self) == #"["octo\/app"]"#)
        #expect(try JSONDecoder().decode([RepoRef].self, from: data) == [ref])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([RepoRef].self, from: Data(#"["../etc"]"#.utf8)) }
    }

    @Test func progressFraction() {
        #expect(RunProgress(jobs: []).fraction == 0)
        let p = RunProgress(jobs: [makeJob(id: 1, status: "completed", conclusion: "failure"), makeJob(id: 2, status: "queued")])
        #expect(p.fraction == 0.5)
        #expect(p.hasFailure)
    }

    @Test func identifiers() {
        #expect(GitRef(kind: .branch, name: "main").id != GitRef(kind: .tag, name: "main").id)
        #expect(WorkflowInput(key: "env").id == "env")
    }

    @Test func trackerForgetsOldRunsPastItsCap() {
        let repo = RepoRef(fullName: "o/r")!
        var t = RunTransitionTracker()
        _ = t.ingest(repo: repo, runs: (1...2001).map { makeRun(id: $0, status: "in_progress") })
        _ = t.ingest(repo: repo, runs: [])
        // Run 5 was forgotten, so seeing it again counts as a start.
        let events = t.ingest(repo: repo, runs: [makeRun(id: 5, status: "in_progress")])
        #expect(events.count == 1)
    }

    @Test func forgottenRepoSeedsAgain() {
        let repo = RepoRef(fullName: "o/r")!
        var t = RunTransitionTracker()
        _ = t.ingest(repo: repo, runs: [])
        t.forget(repo: repo)
        #expect(t.ingest(repo: repo, runs: [makeRun(id: 1, status: "in_progress")]).isEmpty)
    }

    @Test func inputProblems() {
        let flag = WorkflowInput(key: "flag", kind: .boolean)
        #expect(flag.problem(with: "true") == nil)
        #expect(flag.problem(with: "maybe") == "flag must be true or false.")
        #expect(WorkflowInput(key: "s").problem(with: String(repeating: "x", count: Validation.maxInputValueLength + 1)) == "s is too long.")
        #expect(WorkflowInput(key: "s").problem(with: "") == nil)
        #expect(WorkflowInput(key: "c", defaultValue: "gone", kind: .choice(["a", "b"])).initialValue == "a")
        #expect(WorkflowInput(key: "c", kind: .choice([])).initialValue == "")
        #expect(WorkflowInput(key: "n", defaultValue: "3", kind: .number).initialValue == "3")
    }

    @Test func booleanDefaultsAreNormalised() throws {
        let spec = try DispatchSpec.parse(workflowYAML: """
        on:
          workflow_dispatch:
            inputs:
              a: {type: boolean, default: yes}
              b: {type: boolean, default: "False"}
        """)
        #expect(spec?.inputs.map(\.initialValue) == ["true", "false"])
    }
}

@MainActor
@Suite struct AppSettingsTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "pitwall-settings-\(UUID().uuidString)")! }

    @Test func savesAndReloads() {
        let d = defaults()
        let s = AppSettings(defaults: d)
        s.track(RepoRef(fullName: "o/a")!)
        s.track(RepoRef(fullName: "o/a")!)
        s.activeInterval = 15
        s.notifyOnStart = true
        s.notchAlwaysVisible = true
        let again = AppSettings(defaults: d)
        #expect(again.trackedRepos.map(\.fullName) == ["o/a"])
        #expect(again.activeInterval == 15)
        #expect(again.notificationPreferences == NotificationPreferences(onStart: true, onSuccess: true, onFailure: true))
        #expect(again.notchAlwaysVisible)
        #expect(again.pollPolicy.activeInterval == 15)
    }

    @Test func distrustsWhatIsOnDisk() {
        let d = defaults()
        d.set(["o/a", "o/a", "../x", "not a repo", "o/b"], forKey: "trackedRepos")
        d.set(1.0, forKey: "activeInterval")
        d.set(99_999.0, forKey: "idleInterval")
        let s = AppSettings(defaults: d)
        #expect(s.trackedRepos.map(\.fullName) == ["o/a", "o/b"])
        #expect(s.activeInterval == 3)
        #expect(s.idleInterval == 900)
    }
}
