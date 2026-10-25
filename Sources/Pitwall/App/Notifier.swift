import AppKit
import PitwallCore
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    // UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier != nil ? .current() : nil

    func activate() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ event: RunEvent, settings: AppSettings) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        let tracked: TrackedRun
        switch event {
        case .started(let run):
            guard settings.notifyOnStart else { return }
            tracked = run
            content.title = "\(run.repo.name): \(run.run.name ?? "Workflow") started"
        case .finished(let run):
            tracked = run
            let conclusion = run.run.conclusion ?? .unknown
            if conclusion == .success {
                guard settings.notifyOnSuccess else { return }
                content.title = "\(run.repo.name): \(run.run.name ?? "Workflow") passed"
            } else if conclusion.isFailure {
                guard settings.notifyOnFailure else { return }
                content.title = "\(run.repo.name): \(run.run.name ?? "Workflow") failed"
                content.sound = .default
            } else {
                return // cancelled, skipped, neutral: not worth a ping
            }
        }
        let run = tracked.run
        content.body = "\(run.title)\n\(run.headBranch ?? "") · #\(run.runNumber)"
        content.threadIdentifier = tracked.repo.fullName
        content.userInfo = ["url": run.htmlURL.absoluteString]
        let id = "run-\(run.id)-\(run.runAttempt ?? 1)-\(run.status.rawValue)"
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let raw = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: raw)
        else { return }
        await MainActor.run { openOnGitHub(url) }
    }
}
