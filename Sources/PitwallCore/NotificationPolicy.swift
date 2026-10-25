import Foundation

/// Which run events the user wants to hear about.
public struct NotificationPreferences: Sendable, Equatable {
    public var onStart: Bool
    public var onSuccess: Bool
    public var onFailure: Bool

    public init(onStart: Bool, onSuccess: Bool, onFailure: Bool) {
        self.onStart = onStart
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }
}

/// A notification ready to deliver. Plain data, no UserNotifications import.
public struct NotificationContent: Sendable, Equatable {
    /// Stable per run attempt and status, so a repeat poll can't post twice.
    public let id: String
    public let title: String
    public let body: String
    public let threadID: String
    public let url: URL
    public let playsSound: Bool
}

/// Decides whether a run event is worth a notification and what it says.
public enum NotificationPolicy {
    public static func content(for event: RunEvent, preferences: NotificationPreferences) -> NotificationContent? {
        let tracked: TrackedRun
        let verb: String
        var sound = false
        switch event {
        case .started(let run):
            guard preferences.onStart else { return nil }
            tracked = run
            verb = "started"
        case .finished(let run):
            tracked = run
            let conclusion = run.run.conclusion ?? .unknown
            if conclusion == .success {
                guard preferences.onSuccess else { return nil }
                verb = "passed"
            } else if conclusion.isFailure {
                guard preferences.onFailure else { return nil }
                verb = "failed"
                sound = true
            } else {
                return nil // cancelled, skipped, neutral: not worth a ping
            }
        }
        let run = tracked.run
        return NotificationContent(
            id: "run-\(run.id)-\(run.runAttempt ?? 1)-\(run.status.rawValue)",
            title: "\(tracked.repo.name): \(run.name ?? "Workflow") \(verb)",
            body: "\(run.title)\n\(run.headBranch ?? "") · #\(run.runNumber)",
            threadID: tracked.repo.fullName,
            url: run.htmlURL,
            playsSound: sound
        )
    }
}
