import Foundation

/// The version shown in the menu and Settings. Release builds get it from the
/// git tag (see scripts/build-app.sh), so it never needs editing by hand.
enum AppVersion {
    static var current: String { text(Bundle.main.infoDictionary ?? [:]) }

    /// "v0.2.1 (42)", or "v0.2.1" when the build number adds nothing.
    static func text(_ info: [String: Any]) -> String {
        let short = (info["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let short else { return "dev build" }
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty, build != short else { return "v\(short)" }
        return "v\(short) (\(build))"
    }
}
