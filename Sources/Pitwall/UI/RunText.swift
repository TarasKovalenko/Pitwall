import Foundation
import PitwallCore

/// The short strings the menu and notch show for repos and runs.
enum RunText {
    /// Under a repo name: the error, or the latest run and when it changed.
    static func repoSubtitle(_ state: RepoState, now: Date = Date()) -> String {
        if let error = state.error { return error }
        guard let run = state.latestRun else { return state.lastUpdated == nil ? "Loading…" : "No runs yet" }
        return "\(run.title) · \(relative(run.updatedAt, now: now))"
    }

    /// Under a run title in the menu: workflow, branch, number, then jobs or age.
    static func runMeta(_ run: WorkflowRun, progress: RunProgress?, now: Date = Date()) -> String {
        var parts = [run.name ?? "", run.headBranch ?? "", "#\(run.runNumber)"]
        if let progress, run.status.isActive { parts.append(progress.jobsText) }
        else { parts.append(relative(run.updatedAt, now: now)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Under an active run in the notch.
    static func notchDetail(_ run: WorkflowRun, progress: RunProgress?) -> String {
        guard let p = progress else { return run.status == .queued ? "Queued" : "Starting…" }
        return p.currentActivity.map { "\(p.jobsText) · \($0)" } ?? p.jobsText
    }

    /// Right wing of the collapsed notch for a run that just finished.
    static func finishedLabel(_ run: WorkflowRun) -> String {
        run.conclusion == .success ? "passed" : (run.conclusion?.rawValue ?? "done")
    }

    /// Right wing for a single active run without job progress yet.
    static func pendingLabel(_ run: WorkflowRun) -> String {
        run.status == .queued ? "queued" : "…"
    }

    /// "2 minutes ago", "yesterday". Takes `now` so tests can pin it.
    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
