import AppKit
import Foundation
@testable import PitwallCore
import PitwallTestSupport
import Testing
@testable import PitwallApp

private let repo = RepoRef(fullName: "octo/app")!
private let token = "ghp_" + String(repeating: "f", count: 36)
/// Far off any real display, so tests never flash a panel on screen.
@MainActor private let offscreen = NotchGeometry.make(
    frame: NSRect(x: -10_000, y: -10_000, width: 1512, height: 982),
    visibleFrame: NSRect(x: -10_000, y: -10_000, width: 1512, height: 944),
    safeAreaTop: 38, leftArea: NSRect(x: 0, y: 0, width: 660, height: 38), rightArea: NSRect(x: 0, y: 0, width: 660, height: 38))

@MainActor
@Suite(.serialized) struct AppLifecycleTests {
    let api = FakeGitHub()

    func makeStore(token: String? = token) -> (RunStore, AppSettings) {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "pitwall-life-\(UUID().uuidString)")!)
        settings.trackedRepos = [repo]
        return (RunStore(settings: settings, tokens: MemoryTokens(token), api: api, sleep: ManualSleeper().sleep), settings)
    }

    @Test func launchStartsPollingAndSleepPausesIt() async {
        _ = NSApplication.shared
        let (store, settings) = makeStore()
        let delegate = AppDelegate(settings: settings, store: store, notifier: Notifier(center: nil), notchGeometry: { offscreen })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(delegate.notch != nil)
        #expect(store.onEvent != nil)
        let polled = await eventually { store.authState.user != nil }
        #expect(polled)
        let firstCount = await api.runsCalls

        // Events reach the notifier without a notification center.
        await api.set(runs: [makeRun(id: 1, status: "in_progress")], for: repo)
        store.pokeSoon()
        let second = await waitForRuns(above: firstCount)
        #expect(second)

        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        let asleep = await api.runsCalls
        store.pokeSoon()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await api.runsCalls == asleep, "no polling while asleep")

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        let woke = await waitForRuns(above: asleep)
        #expect(woke, "polls right after wake")

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    @Test func finishedRunGoesThroughTheNotificationPolicy() async {
        _ = NSApplication.shared
        let (store, settings) = makeStore()
        let delegate = AppDelegate(settings: settings, store: store, notifier: Notifier(center: nil), notchGeometry: { offscreen })
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        store.stop()
        store.onEvent?(.finished(TrackedRun(repo: repo, run: makeRun(id: 1, status: "completed", conclusion: "failure"))))
        store.onEvent?(.finished(TrackedRun(repo: repo, run: makeRun(id: 2, status: "completed", conclusion: "cancelled"))))
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    @Test func notifierWithoutACenterIsQuiet() {
        let notifier = Notifier(center: nil)
        notifier.activate()
        notifier.post(NotificationContent(id: "x", title: "t", body: "b", threadID: "o/r",
                                          url: URL(string: "https://github.com/o/r")!, playsSound: false))
    }

    func waitForRuns(above count: Int) async -> Bool {
        for _ in 0..<500 {
            if await api.runsCalls > count { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
}

@MainActor
@Suite(.serialized) struct NotchControllerTests {
    let api = FakeGitHub()
    let geometry = offscreen

    func makeStore() -> (RunStore, AppSettings) {
        _ = NSApplication.shared
        let settings = AppSettings(defaults: UserDefaults(suiteName: "pitwall-notch-\(UUID().uuidString)")!)
        settings.trackedRepos = [repo]
        return (RunStore(settings: settings, tokens: MemoryTokens(token), api: api, sleep: ManualSleeper().sleep), settings)
    }

    @Test func appearsWithActiveRunsAndHidesWhenDisabled() async {
        let (store, settings) = makeStore()
        let notch = NotchController(store: store, settings: settings, geometry: { geometry })
        #expect(!notch.isShowing)
        await api.set(runs: [makeRun(id: 1, status: "in_progress")], for: repo)
        await store.refresh()
        let shown = await eventually { notch.isShowing }
        #expect(shown)
        notch.relayout()
        #expect(notch.geometry == geometry)
        settings.notchEnabled = false
        let hidden = await eventually { !notch.isShowing }
        #expect(hidden)
    }

    @Test func hoverExpandsAndLeavingCollapses() async {
        let (store, settings) = makeStore()
        settings.notchAlwaysVisible = true
        let notch = NotchController(store: store, settings: settings, geometry: { geometry })
        await store.refresh()
        let shown = await eventually { notch.isShowing }
        #expect(shown)

        notch.mouseMoved(to: NSPoint(x: geometry.collapsedRect.midX, y: geometry.collapsedRect.midY))
        #expect(notch.isExpanded)
        // Moving around inside keeps it open.
        notch.mouseMoved(to: NSPoint(x: geometry.collapsedRect.midX, y: geometry.screenFrame.maxY - 20))
        #expect(notch.isExpanded)
        // Leaving closes it after a short grace period, and coming back cancels that.
        notch.mouseMoved(to: NSPoint(x: geometry.screenFrame.minX + 5, y: geometry.screenFrame.minY + 5))
        notch.mouseMoved(to: NSPoint(x: geometry.collapsedRect.midX, y: geometry.screenFrame.maxY - 20))
        try? await Task.sleep(for: .milliseconds(350))
        #expect(notch.isExpanded)
        notch.mouseMoved(to: NSPoint(x: geometry.screenFrame.minX + 5, y: geometry.screenFrame.minY + 5))
        let collapsed = await eventually { !notch.isExpanded }
        #expect(collapsed)
        #expect(notch.isShowing, "always-visible keeps it up")
    }

    @Test func noScreenMeansNoPanel() async {
        let (store, settings) = makeStore()
        settings.notchAlwaysVisible = true
        let notch = NotchController(store: store, settings: settings, geometry: { nil })
        await store.refresh()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!notch.isShowing)
        notch.relayout()
        notch.mouseMoved(to: .zero)
    }
}
