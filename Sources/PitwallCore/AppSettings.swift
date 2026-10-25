import Foundation
import Observation

/// Non-secret preferences. The token lives in `TokenStore`, never here.
@MainActor
@Observable
public final class AppSettings {
    private let defaults: UserDefaults

    public var trackedRepos: [RepoRef] {
        didSet { save(trackedRepos.map(\.fullName), "trackedRepos") }
    }
    public var idleInterval: TimeInterval {
        didSet { save(idleInterval, "idleInterval") }
    }
    public var activeInterval: TimeInterval {
        didSet { save(activeInterval, "activeInterval") }
    }
    public var notchEnabled: Bool {
        didSet { save(notchEnabled, "notchEnabled") }
    }
    /// Keep the notch wings visible even when nothing is running.
    public var notchAlwaysVisible: Bool {
        didSet { save(notchAlwaysVisible, "notchAlwaysVisible") }
    }
    public var notifyOnSuccess: Bool {
        didSet { save(notifyOnSuccess, "notifyOnSuccess") }
    }
    public var notifyOnFailure: Bool {
        didSet { save(notifyOnFailure, "notifyOnFailure") }
    }
    public var notifyOnStart: Bool {
        didSet { save(notifyOnStart, "notifyOnStart") }
    }

    public var pollPolicy: PollPolicy {
        PollPolicy(activeInterval: activeInterval, idleInterval: idleInterval)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let names = defaults.stringArray(forKey: "trackedRepos") ?? []
        // Re-validate on load: defaults can be edited by anything running as the user.
        trackedRepos = Self.dedupe(names.compactMap(RepoRef.init(fullName:)))
        idleInterval = Self.clamp(defaults.object(forKey: "idleInterval") as? Double ?? 60, 15, 900)
        activeInterval = Self.clamp(defaults.object(forKey: "activeInterval") as? Double ?? 8, 3, 120)
        notchEnabled = defaults.object(forKey: "notchEnabled") as? Bool ?? true
        notchAlwaysVisible = defaults.object(forKey: "notchAlwaysVisible") as? Bool ?? false
        notifyOnSuccess = defaults.object(forKey: "notifyOnSuccess") as? Bool ?? true
        notifyOnFailure = defaults.object(forKey: "notifyOnFailure") as? Bool ?? true
        notifyOnStart = defaults.object(forKey: "notifyOnStart") as? Bool ?? false
    }

    public func track(_ ref: RepoRef) {
        guard !trackedRepos.contains(ref) else { return }
        trackedRepos.append(ref)
    }

    public func untrack(_ ref: RepoRef) {
        trackedRepos.removeAll { $0 == ref }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }

    private static func dedupe(_ refs: [RepoRef]) -> [RepoRef] {
        var seen = Set<RepoRef>()
        return refs.filter { seen.insert($0).inserted }
    }
}
