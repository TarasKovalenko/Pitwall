import AppKit
import Foundation
@testable import PitwallCore
import PitwallTestSupport
import SwiftUI
import Testing
@testable import PitwallApp

private let repo = RepoRef(fullName: "octo/app")!
private let token = "ghp_" + String(repeating: "e", count: 36)

/// Puts a view in a real (offscreen) window so `.task` and `.onAppear` run,
/// and lays it out. Catches views that crash or loop in a given state.
@MainActor
final class Rendered<V: View> {
    let window: NSWindow
    let host: NSHostingView<V>

    init(_ view: V, size: CGSize = CGSize(width: 420, height: 640)) {
        _ = NSApplication.shared
        host = NSHostingView(rootView: view)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        layout()
    }

    func layout() {
        host.layoutSubtreeIfNeeded()
        host.display()
    }

    /// Lets tasks run, then lays out again.
    func settle() async {
        for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(5)); layout() }
    }

    var fittingHeight: CGFloat { host.fittingSize.height }

    deinit { MainActor.assumeIsolated { window.orderOut(nil) } }
}

@MainActor
@Suite(.serialized) struct ViewRenderTests {
    let api = FakeGitHub()

    func makeStore(token: String? = token) -> RunStore {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "pitwall-views-\(UUID().uuidString)")!)
        settings.trackedRepos = [repo, RepoRef(fullName: "octo/lib")!]
        return RunStore(settings: settings, tokens: MemoryTokens(token), api: api, sleep: ManualSleeper().sleep)
    }

    /// One repo with a running, a failed and a passed run, plus job progress.
    func busyStore() async -> RunStore {
        let store = makeStore()
        await api.set(runs: [
            makeRun(id: 1, status: "in_progress"),
            makeRun(id: 2, status: "completed", conclusion: "failure"),
            makeRun(id: 3, status: "completed", conclusion: "success"),
        ], for: repo)
        await api.set(runsError: .notFound, for: RepoRef(fullName: "octo/lib")!)
        await api.set(jobs: [makeJob(id: 10, status: "completed", conclusion: "success"), makeJob(id: 11, status: "in_progress")], for: 1)
        await store.refresh()
        return store
    }

    @Test func menuSignedOut() {
        let r = Rendered(MenuContentView(store: makeStore(token: nil)))
        #expect(r.fittingHeight > 0)
    }

    @Test func menuTokenProblem() async {
        let store = makeStore()
        await api.set(runsError: .unauthorized, for: repo)
        await store.refresh()
        let r = Rendered(MenuContentView(store: store))
        #expect(r.fittingHeight > 0)
    }

    @Test func menuWithRuns() async {
        let store = await busyStore()
        let r = Rendered(MenuContentView(store: store))
        await r.settle()
        #expect(r.fittingHeight > 100)
        #expect(store.progress[1] != nil)
    }

    @Test func menuWithNoRepos() async {
        let store = makeStore()
        store.untrack(repo)
        store.untrack(RepoRef(fullName: "octo/lib")!)
        await store.refresh()
        let r = Rendered(MenuContentView(store: store))
        #expect(r.fittingHeight > 0)
    }

    @Test func runRowsInEveryState() async {
        let store = await busyStore()
        for run in store.repos[0].runs {
            let tracked = TrackedRun(repo: repo, run: run)
            let r = Rendered(RunRow(tracked: tracked, progress: store.progress[run.id], perform: { _ in }).environment(store))
            #expect(r.fittingHeight > 0)
        }
    }

    @Test func statusIconForEachState() async {
        let r1 = Rendered(StatusIcon(store: makeStore(token: nil)))
        #expect(r1.fittingHeight > 0)
        let r2 = Rendered(StatusIcon(store: await busyStore()))
        #expect(r2.fittingHeight > 0)
    }

    @Test func settingsSignedOutAndSignedIn() async {
        let r1 = Rendered(SettingsView(store: makeStore(token: nil)))
        await r1.settle()
        #expect(r1.fittingHeight > 0)
        let signedIn = await busyStore()
        let r2 = Rendered(SettingsView(store: signedIn))
        await r2.settle()
        #expect(r2.fittingHeight > 0)
    }

    @Test func settingsTabsRenderOnTheirOwn() async {
        let store = await busyStore()
        let connecting = makeStore()
        await api.set(userError: .transport("offline"))
        await connecting.refresh()
        #expect(connecting.authState == .connecting)
        for view in [AnyView(GeneralSettings(settings: store.settings)), AnyView(SettingsView(store: connecting))] {
            let r = Rendered(view)
            await r.settle()
            #expect(r.fittingHeight > 0)
        }
    }

    @Test func dispatchFormLoadsRefsAndInputs() async {
        let workflow = makeWorkflow(id: 1)
        await api.set(workflows: [workflow], branches: [Branch(name: "main")], tags: [Tag(name: "v1.0")])
        await api.set(file: """
        on:
          workflow_dispatch:
            inputs:
              env: {type: choice, options: [staging, prod], required: true}
              dry_run: {type: boolean, default: true}
              replicas: {type: number, description: How many}
              target: {type: environment}
        """, path: workflow.path, ref: "main")
        let store = makeStore()
        let r = Rendered(DispatchView(store: store, repo: repo, close: {}))
        await r.settle()
        #expect(await api.fileRequests == ["\(workflow.path)@main"])
        #expect(r.fittingHeight > 150)
    }

    @Test func dispatchFormWhenTheFileCantBeRead() async {
        let workflow = makeWorkflow(id: 1)
        await api.set(workflows: [workflow], branches: [Branch(name: "main")])
        let r = Rendered(DispatchView(store: makeStore(), repo: repo, close: {}))
        await r.settle()
        #expect(await api.fileRequests.count == 1)
        #expect(r.fittingHeight > 0)
    }

    @Test func dispatchFormWithoutWorkflows() async {
        let r = Rendered(DispatchView(store: makeStore(), repo: repo, close: {}))
        await r.settle()
        #expect(r.fittingHeight > 0)
    }

    @Test func notchCollapsedAndExpanded() async {
        let store = await busyStore()
        let geometry = NotchGeometry.make(frame: NSRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: .zero,
                                          safeAreaTop: 38, leftArea: NSRect(x: 0, y: 0, width: 660, height: 38),
                                          rightArea: NSRect(x: 0, y: 0, width: 660, height: 38))
        let model = NotchModel(geometry: geometry)
        let r = Rendered(NotchView(model: model).environment(store), size: geometry.panelFrame.size)
        model.isExpanded = true
        await r.settle()
        #expect(model.expandedHeight > 0)
        // Finished-only state: the run completes and shows as "recently finished".
        await api.set(runs: [makeRun(id: 1, status: "completed", conclusion: "success")], for: repo)
        await store.refresh()
        model.isExpanded = false
        await r.settle()
        #expect(!store.recentlyFinished.isEmpty)
    }

    @Test func notchWithManyRunsAndNothing() async {
        let store = makeStore()
        await api.set(runs: (1...6).map { makeRun(id: $0, status: $0 == 1 ? "queued" : "in_progress") }, for: repo)
        await store.refresh()
        let model = NotchModel(geometry: NotchGeometry.make(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                                            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875),
                                                            safeAreaTop: 0, leftArea: nil, rightArea: nil))
        model.isExpanded = true
        let r = Rendered(NotchView(model: model).environment(store), size: model.geometry.panelFrame.size)
        await r.settle()
        let empty = Rendered(NotchView(model: model).environment(makeStore()), size: model.geometry.panelFrame.size)
        await empty.settle()
        #expect(r.fittingHeight > 0 && empty.fittingHeight > 0)
    }

    @Test func emptyStateView() {
        let r = Rendered(EmptyStateView(symbol: "tray", title: "Nothing", message: "Here"))
        #expect(r.fittingHeight > 0)
    }
}

@MainActor
@Suite(.serialized) struct HiddenStateRenderTests {
    let api = FakeGitHub()

    func makeStore() -> RunStore {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "pitwall-hidden-\(UUID().uuidString)")!)
        settings.trackedRepos = [repo]
        return RunStore(settings: settings, tokens: MemoryTokens(token), api: api, sleep: ManualSleeper().sleep)
    }

    @Test func hoverActionsOnRunRows() async {
        let store = makeStore()
        let runs = [
            makeRun(id: 1, status: "in_progress", started: Date().addingTimeInterval(-90)),
            makeRun(id: 2, status: "completed", conclusion: "failure"),
        ]
        for run in runs {
            let tracked = TrackedRun(repo: repo, run: run)
            let row = Rendered(RunRow(tracked: tracked, progress: nil, perform: { _ in }, hovering: true).environment(store))
            let notchRow = Rendered(NotchRunRow(tracked: tracked, progress: nil, hovering: true).environment(store))
            #expect(row.fittingHeight > 0 && notchRow.fittingHeight > 0)
        }
    }

    @Test func repositoriesTab() async throws {
        let mine = try JSONDecoder().decode([Repository].self, from: Data("""
        [{"id":1,"name":"app","full_name":"octo/app","owner":{"login":"octo"},"private":false,"default_branch":"main","pushed_at":null},
         {"id":2,"name":"secret","full_name":"octo/secret","owner":{"login":"octo"},"private":true,"default_branch":"main","pushed_at":null}]
        """.utf8))
        await api.set(repositories: mine)
        let store = makeStore()
        let r = Rendered(RepositorySettings(store: store))
        await r.settle()
        #expect(r.fittingHeight > 0)
        let empty = makeStore()
        empty.untrack(repo)
        let r2 = Rendered(RepositorySettings(store: empty))
        await r2.settle()
        #expect(r2.fittingHeight > 0)
    }

    @Test func accountTabStates() async {
        let signedOut = RunStore(settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                 tokens: MemoryTokens(), api: api, sleep: ManualSleeper().sleep)
        let rejected = makeStore()
        await api.set(runsError: .unauthorized, for: repo)
        await rejected.refresh()
        for store in [signedOut, rejected] {
            let r = Rendered(AccountSettings(store: store))
            await r.settle()
            #expect(r.fittingHeight > 0)
        }
    }

    @Test func menuFooterShowsTheBudget() async {
        await api.set(rateLimit: RateLimit(limit: 5000, remaining: 150, resetAt: Date().addingTimeInterval(600)))
        let store = makeStore()
        await store.refresh()
        #expect(store.rateLimit?.remaining == 150)
        let r = Rendered(MenuContentView(store: store))
        await r.settle()
        #expect(r.fittingHeight > 0)
    }

    @Test func notchWithActiveAndFinishedTogether() async {
        let store = makeStore()
        await api.set(runs: [makeRun(id: 1, status: "in_progress"), makeRun(id: 2, status: "in_progress")], for: repo)
        await store.refresh()
        await api.set(runs: [makeRun(id: 1, status: "in_progress"), makeRun(id: 3, status: "in_progress"),
                             makeRun(id: 2, status: "completed", conclusion: "success")], for: repo)
        await store.refresh()
        #expect(store.activeRuns.count == 2)
        #expect(!store.recentlyFinished.isEmpty)
        let geometry = NotchGeometry.make(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .zero,
                                          safeAreaTop: 0, leftArea: nil, rightArea: nil)
        let model = NotchModel(geometry: geometry)
        let collapsed = Rendered(NotchView(model: model).environment(store), size: geometry.panelFrame.size)
        await collapsed.settle()
        model.isExpanded = true
        await collapsed.settle()
        #expect(model.expandedHeight > 0)
    }
}
