import PitwallCore
import SwiftUI

@main
struct PitwallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: appDelegate.store)
        } label: {
            StatusIcon(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: appDelegate.store)
        }
    }
}
