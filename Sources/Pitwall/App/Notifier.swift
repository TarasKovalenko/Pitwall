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

    /// Delivers what `NotificationPolicy` decided to show.
    func post(_ notification: NotificationContent) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = notification.threadID
        content.userInfo = ["url": notification.url.absoluteString]
        if notification.playsSound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
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
