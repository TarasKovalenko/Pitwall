import AppKit
import PitwallCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings: AppSettings
    let store: RunStore
    private let notifier = Notifier()
    private var notch: NotchController?
    private var observers: [NSObjectProtocol] = []

    override init() {
        settings = AppSettings()
        store = RunStore(settings: settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        notifier.activate()
        store.onEvent = { [weak self] event in
            guard let self else { return }
            self.notifier.post(event, settings: self.settings)
        }
        notch = NotchController(store: store, settings: settings)
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
    guard let url = URL(string: "https://github.com/\(repo.owner)/\(repo.name)\(path)") else { return }
    openOnGitHub(url)
}
