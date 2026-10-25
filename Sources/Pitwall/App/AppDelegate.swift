import AppKit
import PitwallCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings: AppSettings
    let store: RunStore
    private let notifier: Notifier
    private(set) var notch: NotchController?
    private var observers: [NSObjectProtocol] = []
    private let notchGeometry: @MainActor () -> NotchGeometry?

    override convenience init() {
        let settings = AppSettings()
        self.init(settings: settings, store: RunStore(settings: settings), notifier: Notifier())
    }

    init(settings: AppSettings, store: RunStore, notifier: Notifier,
         notchGeometry: @escaping @MainActor () -> NotchGeometry? = NotchGeometry.current) {
        self.settings = settings
        self.store = store
        self.notifier = notifier
        self.notchGeometry = notchGeometry
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        notifier.activate()
        store.onEvent = { [weak self] event in
            guard let self else { return }
            guard let content = NotificationPolicy.content(
                for: event, preferences: self.settings.notificationPreferences) else { return }
            self.notifier.post(content)
        }
        notch = NotchController(store: store, settings: settings, geometry: notchGeometry)
        store.start()

        // No point polling while the Mac sleeps; catch up right after wake.
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.stop() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.start() }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}

/// Opens a page in the browser, but only if it's on github.com.
@MainActor
func openOnGitHub(_ url: URL) {
    guard Validation.isSafeGitHubWebURL(url) else { return }
    NSWorkspace.shared.open(url)
}

@MainActor
func openOnGitHub(_ repo: RepoRef, path: String = "") {
    guard let url = gitHubURL(repo, path: path) else { return }
    openOnGitHub(url)
}

/// `https://github.com/owner/repo` plus a fixed suffix like `/actions`.
func gitHubURL(_ repo: RepoRef, path: String = "") -> URL? {
    URL(string: "https://github.com/\(repo.owner)/\(repo.name)\(path)")
}
