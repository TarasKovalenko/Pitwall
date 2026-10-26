import AppKit
import Foundation
@testable import PitwallCore
import PitwallTestSupport
import SwiftUI
import Testing
@testable import PitwallApp

/// Renders the README screenshots from sample data. Off by default:
/// `PITWALL_SCREENSHOTS=docs/screenshots swift test --filter Screenshots`
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PITWALL_SCREENSHOTS"] != nil))
struct Screenshots {
    let api = FakeGitHub()
    let web = RepoRef(fullName: "acme/web")!
    let api_ = RepoRef(fullName: "acme/api")!
    let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PITWALL_SCREENSHOTS"] ?? ".")

    /// A notch like a 14" MacBook Pro's.
    let geometry = NotchGeometry.make(
        frame: NSRect(x: -10_000, y: -10_000, width: 1512, height: 982),
        visibleFrame: NSRect(x: -10_000, y: -10_000, width: 1512, height: 944),
        safeAreaTop: 38, leftArea: NSRect(x: 0, y: 0, width: 660, height: 38),
        rightArea: NSRect(x: 0, y: 0, width: 660, height: 38))

    func sampleStore() async -> RunStore {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "pitwall-shots-\(UUID().uuidString)")!)
        settings.trackedRepos = [web, api_]
        let store = RunStore(settings: settings, tokens: MemoryTokens("ghp_" + String(repeating: "e", count: 36)),
                             api: api, sleep: ManualSleeper().sleep)
        await api.set(user: GitHubUser(login: "octocat", avatarURL: nil))
        let now = Date()
        await api.set(runs: [
            run(1, "Deploy", "Ship the new checkout page", "in_progress", started: now.addingTimeInterval(-134)),
            run(2, "CI", "Add dark mode to settings", "completed", "success", started: now.addingTimeInterval(-900)),
            run(3, "CI", "Bump dependencies", "completed", "failure", started: now.addingTimeInterval(-3600)),
        ], for: web)
        await api.set(runs: [
            run(4, "Tests", "Cache user lookups", "in_progress", started: now.addingTimeInterval(-48)),
            run(5, "Tests", "Retry webhook delivery", "completed", "success", started: now.addingTimeInterval(-7200)),
        ], for: api_)
        await api.set(jobs: [
            job(10, "build", "completed", "success"), job(11, "test", "completed", "success"),
            job(12, "deploy", "in_progress", steps: [("Set up job", "completed"), ("Upload assets", "in_progress")]),
        ], for: 1)
        await api.set(jobs: [
            job(20, "unit", "completed", "success"),
            job(21, "integration", "in_progress", steps: [("Start Postgres", "completed"), ("Run tests", "in_progress")]),
            job(22, "lint", "queued"),
        ], for: 4)
        await store.refresh()
        return store
    }

    @Test func notch() async throws {
        let store = await sampleStore()
        let model = NotchModel(geometry: geometry)
        let size = geometry.panelFrame.size
        let shot = Shot(Backdrop { NotchView(model: model).environment(store) }, size: size)
        await shot.settle()
        try save(shot.host, crop: CGSize(width: size.width, height: 64), as: "notch-wings.png")

        model.isExpanded = true
        await shot.settle()
        try save(shot.host, crop: size, as: "notch-expanded.png")
    }

    @Test func menu() async throws {
        let store = await sampleStore()
        let shot = Shot(MenuContentView(store: store).background(.windowBackground), size: CGSize(width: 380, height: 640))
        await shot.settle()
        try save(shot.host, crop: CGSize(width: 380, height: shot.fittingHeight), as: "menu.png")
    }

    // MARK: Helpers

    private func save(_ view: NSView, crop: CGSize, as name: String) throws {
        view.layoutSubtreeIfNeeded()
        let rect = NSRect(x: 0, y: 0, width: crop.width, height: min(crop.height, view.bounds.height))
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try png.write(to: out.appendingPathComponent(name))
    }

    private func run(_ id: Int, _ name: String, _ title: String, _ status: String, _ conclusion: String? = nil,
                     started: Date) -> WorkflowRun {
        let iso = ISO8601DateFormatter()
        let json = """
        {"id": \(id), "name": "\(name)", "display_title": "\(title)", "status": "\(status)",
         "conclusion": \(conclusion.map { "\"\($0)\"" } ?? "null"), "head_branch": "main",
         "event": "push", "html_url": "https://github.com/acme/web/actions/runs/\(id)", "run_number": \(100 + id),
         "run_attempt": 1, "workflow_id": \(id), "created_at": "\(iso.string(from: started))",
         "updated_at": "\(iso.string(from: started))", "run_started_at": "\(iso.string(from: started))",
         "actor": {"login": "octocat"}}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try! d.decode(WorkflowRun.self, from: Data(json.utf8))
    }

    private func job(_ id: Int, _ name: String, _ status: String, _ conclusion: String? = nil,
                     steps: [(String, String)] = []) -> Job {
        let stepsJSON = steps.enumerated().map { i, s in
            #"{"name": "\#(s.0)", "status": "\#(s.1)", "conclusion": \#(s.1 == "completed" ? #""success""# : "null"), "number": \#(i + 1)}"#
        }.joined(separator: ",")
        let json = """
        {"id": \(id), "name": "\(name)", "status": "\(status)",
         "conclusion": \(conclusion.map { "\"\($0)\"" } ?? "null"), "steps": [\(stepsJSON)]}
        """
        return try! JSONDecoder().decode(Job.self, from: Data(json.utf8))
    }
}

/// Like `Rendered`, but in a key window of an active app, so controls draw
/// in their active colours (an inactive window greys out the progress tint).
@MainActor
private final class Shot<V: View> {
    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    let window: KeyWindow
    let host: NSHostingView<V>

    init(_ view: V, size: CGSize) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        host = NSHostingView(rootView: view)
        window = KeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
    }

    func settle() async {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(5))
            host.layoutSubtreeIfNeeded()
            host.display()
        }
    }

    var fittingHeight: CGFloat { host.fittingSize.height }

    deinit { MainActor.assumeIsolated { window.orderOut(nil) } }
}

/// A wallpaper-ish gradient with a menu bar strip, so the black notch has something to sit on.
private struct Backdrop<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.42, green: 0.27, blue: 0.52)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Color.white.opacity(0.12).frame(height: 38)
            content
        }
    }
}
