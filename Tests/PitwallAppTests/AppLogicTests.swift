import AppKit
import Foundation
@testable import PitwallCore
import PitwallTestSupport
import SwiftUI
import Testing
import UserNotifications
@testable import PitwallApp

private let repo = RepoRef(fullName: "octo/app")!

@Suite struct RunTextTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func repoSubtitle() {
        var state = RepoState(ref: repo)
        #expect(RunText.repoSubtitle(state, now: now) == "Loading…")
        state.lastUpdated = now
        #expect(RunText.repoSubtitle(state, now: now) == "No runs yet")
        state.runs = [makeRun(id: 1, status: "completed", conclusion: "success", updated: now.addingTimeInterval(-120))]
        #expect(RunText.repoSubtitle(state, now: now) == "Fix thing · \(RunText.relative(now.addingTimeInterval(-120), now: now))")
        state.error = "Not found"
        #expect(RunText.repoSubtitle(state, now: now) == "Not found")
    }

    @Test func runMetaShowsJobsWhileActive() {
        let active = makeRun(id: 7, status: "in_progress")
        let progress = RunProgress(jobs: [makeJob(id: 1, status: "completed", conclusion: "success"), makeJob(id: 2, status: "in_progress")])
        #expect(RunText.runMeta(active, progress: progress, now: now) == "CI · main · #7 · 1/2 jobs")
        let done = makeRun(id: 7, status: "completed", conclusion: "success", updated: now)
        #expect(RunText.runMeta(done, progress: progress, now: now) == "CI · main · #7 · \(RunText.relative(now, now: now))")
    }

    @Test func notchTexts() {
        let queued = makeRun(id: 1, status: "queued")
        #expect(RunText.notchDetail(queued, progress: nil) == "Queued")
        #expect(RunText.notchDetail(makeRun(id: 1, status: "in_progress"), progress: nil) == "Starting…")
        let p = RunProgress(jobs: [makeJob(id: 1, status: "in_progress")])
        #expect(RunText.notchDetail(queued, progress: p) == "0/1 jobs · job1")
        #expect(RunText.notchDetail(queued, progress: RunProgress(jobs: [makeJob(id: 1, status: "queued")])) == "0/1 jobs")
        #expect(RunText.pendingLabel(queued) == "queued")
        #expect(RunText.pendingLabel(makeRun(id: 1, status: "in_progress")) == "…")
        #expect(RunText.finishedLabel(makeRun(id: 1, status: "completed", conclusion: "success")) == "passed")
        #expect(RunText.finishedLabel(makeRun(id: 1, status: "completed", conclusion: "failure")) == "failure")
        #expect(RunText.finishedLabel(makeRun(id: 1, status: "completed")) == "done")
    }
}

@Suite struct AppVersionTests {
    @Test func readsTheStampedVersion() {
        #expect(AppVersion.text(["CFBundleShortVersionString": "0.2.2", "CFBundleVersion": "17"]) == "v0.2.2 (17)")
        #expect(AppVersion.text(["CFBundleShortVersionString": "0.2.2", "CFBundleVersion": "0.2.2"]) == "v0.2.2")
        #expect(AppVersion.text(["CFBundleShortVersionString": "0.2.2"]) == "v0.2.2")
        #expect(AppVersion.text(["CFBundleShortVersionString": ""]) == "dev build")
        #expect(AppVersion.text([:]) == "dev build")
        #expect(!AppVersion.current.isEmpty)
    }
}

@MainActor
@Suite struct GlyphAndIconTests {
    @Test func statusIconSymbols() {
        let all: [OverallStatus] = [.signedOut, .idle, .running(2), .failing, .error]
        #expect(Set(all.map(StatusIcon.symbol(for:))).count == all.count)
        #expect(StatusIcon.symbol(for: .running(3)) == "arrow.triangle.2.circlepath")
    }

    @Test func runGlyphs() {
        let cases: [(RunStatus, RunConclusion?, String, Color, String)] = [
            (.inProgress, nil, "circle.dotted.circle", .orange, "in progress"),
            (.queued, nil, "clock", .secondary, "queued"),
            (.completed, .success, "checkmark.circle.fill", .green, "success"),
            (.completed, .cancelled, "slash.circle", .secondary, "cancelled"),
            (.completed, .skipped, "minus.circle", .secondary, "skipped"),
            (.completed, .timedOut, "xmark.circle.fill", .red, "timed_out"),
            (.completed, nil, "questionmark.circle", .secondary, "unknown"),
        ]
        for (status, conclusion, symbol, color, label) in cases {
            let glyph = RunGlyph(status: status, conclusion: conclusion)
            #expect(glyph.symbol == symbol, "\(status) \(String(describing: conclusion))")
            #expect(glyph.color == color, "\(status) \(String(describing: conclusion))")
            #expect(glyph.label == label)
        }
        #expect(makeRun(id: 1, status: "queued").glyph.status == .queued)
    }

    @Test func runActionPresentation() {
        #expect(RunAction.cancel.title == "Cancel run")
        #expect(RunAction.rerun(failedOnly: true).title == "Re-run failed jobs")
        #expect(RunAction.rerun(failedOnly: false).title == "Re-run all jobs")
        #expect(RunAction.cancel.symbol == "stop.circle")
        #expect(RunAction.rerun(failedOnly: true).symbol == "arrow.counterclockwise")
    }

    @Test func refreshLabels() {
        #expect(GeneralSettings.label(30) == "every 30s")
        #expect(GeneralSettings.label(120) == "every 2 min")
    }
}

@Suite struct NotchGeometryTests {
    let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func notchSitsBetweenTheAuxiliaryAreas() {
        let g = NotchGeometry.make(frame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 944), safeAreaTop: 38,
                                   leftArea: NSRect(x: 0, y: 944, width: 660, height: 38),
                                   rightArea: NSRect(x: 852, y: 944, width: 660, height: 38))
        #expect(g.hasNotch)
        #expect(g.notchSize == CGSize(width: 192, height: 38))
        #expect(g.collapsedSize == g.notchSize)
        #expect(g.collapsedRect.midX == frame.midX)
        #expect(g.collapsedRect.maxY == frame.maxY)
        #expect(g.panelFrame.width == NotchGeometry.expandedWidth + 40)
        #expect(g.panelFrame.maxY == frame.maxY)
        let expanded = g.expandedRect(height: 200)
        #expect(expanded.width == NotchGeometry.expandedWidth)
        #expect(expanded.minY == frame.maxY - 200)
    }

    @Test func noNotchGivesAPillAsTallAsTheMenuBar() {
        let g = NotchGeometry.make(frame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 957), safeAreaTop: 0,
                                   leftArea: nil, rightArea: nil)
        #expect(!g.hasNotch)
        #expect(g.notchSize == CGSize(width: 120, height: 25))
        #expect(g.collapsedSize == CGSize(width: 120 + 2 * NotchGeometry.wingWidth, height: 25))
        let tiny = NotchGeometry.make(frame: frame, visibleFrame: frame, safeAreaTop: 0, leftArea: nil, rightArea: nil)
        #expect(tiny.notchSize.height == 24)
    }

    @MainActor @Test func currentScreenGivesSomething() {
        _ = NSApplication.shared
        if !NSScreen.screens.isEmpty { #expect(NotchGeometry.current() != nil) }
    }
}

@Suite struct NotificationDeliveryTests {
    let content = NotificationContent(id: "run-1-1-completed", title: "app: CI failed", body: "Fix\nmain · #1",
                                      threadID: "octo/app", url: URL(string: "https://github.com/octo/app/actions/runs/1")!,
                                      playsSound: true)

    @MainActor @Test func requestCarriesTheContent() {
        let request = Notifier.request(for: content)
        #expect(request.identifier == "run-1-1-completed")
        #expect(request.content.title == "app: CI failed")
        #expect(request.content.body == "Fix\nmain · #1")
        #expect(request.content.threadIdentifier == "octo/app")
        #expect(request.content.sound != nil)
        #expect(request.trigger == nil)
        let quiet = NotificationContent(id: "x", title: "t", body: "b", threadID: "o/r", url: content.url, playsSound: false)
        #expect(Notifier.request(for: quiet).content.sound == nil)
    }

    @Test func clickedNotificationsOnlyOpenGitHub() {
        #expect(Notifier.url(from: ["url": "https://github.com/octo/app/actions/runs/1"])?.host == "github.com")
        #expect(Notifier.url(from: ["url": "https://evil.example/"]) == nil)
        #expect(Notifier.url(from: ["url": "file:///etc/passwd"]) == nil)
        #expect(Notifier.url(from: ["url": 42]) == nil)
        #expect(Notifier.url(from: [:]) == nil)
    }

    @Test func repoLinks() {
        #expect(gitHubURL(repo)?.absoluteString == "https://github.com/octo/app")
        #expect(gitHubURL(repo, path: "/actions")?.absoluteString == "https://github.com/octo/app/actions")
    }
}

@MainActor
@Suite struct NotchVisibilityTests {
    let api = FakeGitHub()

    func store(token: String? = "ghp_" + String(repeating: "d", count: 36)) -> (RunStore, AppSettings) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "pitwall-app-\(UUID().uuidString)")!)
        settings.trackedRepos = [repo]
        return (RunStore(settings: settings, tokens: MemoryTokens(token), api: api, sleep: ManualSleeper().sleep), settings)
    }

    @Test func showsOnlyWhenSignedInAndSomethingIsGoingOn() async {
        let (s, settings) = store()
        #expect(!NotchController.shouldShow(settings: settings, store: s), "not signed in yet")
        await s.refresh()
        #expect(!NotchController.shouldShow(settings: settings, store: s), "nothing running")
        settings.notchAlwaysVisible = true
        #expect(NotchController.shouldShow(settings: settings, store: s))
        settings.notchAlwaysVisible = false
        await api.set(runs: [makeRun(id: 1, status: "in_progress")], for: repo)
        await s.refresh()
        #expect(NotchController.shouldShow(settings: settings, store: s))
        settings.notchEnabled = false
        #expect(!NotchController.shouldShow(settings: settings, store: s))
    }

    @Test func finishedRunsKeepItUpBriefly() async {
        let (s, settings) = store()
        await api.set(runs: [makeRun(id: 1, status: "in_progress")], for: repo)
        await s.refresh()
        await api.set(runs: [makeRun(id: 1, status: "completed", conclusion: "success")], for: repo)
        await s.refresh()
        #expect(s.activeRuns.isEmpty)
        #expect(NotchController.shouldShow(settings: settings, store: s))
    }
}

@Suite struct DispatchFormTests {
    let spec = DispatchSpec(inputs: [
        WorkflowInput(key: "env", required: true, kind: .choice(["staging", "prod"])),
        WorkflowInput(key: "note"),
    ])

    func ready() -> DispatchForm {
        var form = DispatchForm()
        form.start(with: DispatchOptions(workflows: [makeWorkflow(id: 1)], branches: ["main"]))
        return form
    }

    @Test func startPicksDefaults() {
        let form = ready()
        #expect(form.workflowID == 1)
        #expect(form.selectedRef == GitRef(kind: .branch, name: "main"))
        #expect(form.spec == .loading)
        #expect(form.blockingProblem == "Reading inputs…")
    }

    @Test func blockingProblems() {
        var form = DispatchForm()
        #expect(form.blockingProblem == "Pick a workflow.")
        form.workflowID = 1
        #expect(form.blockingProblem == "Pick a branch or tag.")
        form.selectedRef = GitRef(kind: .tag, name: "v1")
        form.apply(nil)
        #expect(form.spec == .notDispatchable)
        #expect(form.blockingProblem == "Can't run this workflow by hand.")
        form.apply(DispatchSpec(inputs: [WorkflowInput(key: "name", required: true)]))
        #expect(form.blockingProblem == "name is required.")
        form.values["name"] = "x"
        #expect(form.blockingProblem == nil)
        form.apply(failure: GitHubError.notFound)
        #expect(form.blockingProblem == nil, "free-form inputs can always be sent")
    }

    @Test func reloadKeepsValuesForInputsThatStillExist() throws {
        var form = ready()
        form.values = ["env": "prod", "gone": "x"]
        form.apply(spec)
        #expect(form.values == ["env": "prod"])
        #expect(try form.inputsToSend() == ["env": "prod"])
    }

    @Test func unreadableFileFallsBackToManualInputs() throws {
        var form = ready()
        form.apply(failure: YAMLError.tooDeep)
        #expect(form.spec == .unreadable("unsupported YAML"))
        form.apply(failure: GitHubError.notFound)
        #expect(form.spec == .unreadable(GitHubError.notFound.localizedDescription))
        form.manualInputs = [.init(key: " a ", value: "1"), .init(key: "  ", value: "ignored"), .init(key: "b", value: "")]
        #expect(try form.inputsToSend() == ["a": "1", "b": ""])
    }

    @Test func invalidValuesAreNotSent() {
        var form = ready()
        form.apply(spec)
        form.values["env"] = "moon"
        #expect(throws: GitHubError.self) { try form.inputsToSend() }
    }
}
