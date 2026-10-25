import AppKit
import PitwallCore
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter?

    /// UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`),
    /// so there's no center then. Tests pass nil too.
    init(center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier != nil ? .current() : nil) {
        self.center = center
        super.init()
    }

    func activate() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Delivers what `NotificationPolicy` decided to show.
    func post(_ notification: NotificationContent) {
        center?.add(Self.request(for: notification))
    }

    static func request(for notification: NotificationContent) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = notification.threadID
        content.userInfo = ["url": notification.url.absoluteString]
        if notification.playsSound { content.sound = .default }
        return UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)
    }

    /// The page a clicked notification should open, if it's a safe one.
    nonisolated static func url(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo["url"] as? String, let url = URL(string: raw), Validation.isSafeGitHubWebURL(url) else { return nil }
        return url
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
        guard let url = Self.url(from: response.notification.request.content.userInfo) else { return }
        await MainActor.run { openOnGitHub(url) }
    }
}
