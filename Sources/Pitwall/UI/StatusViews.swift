import PitwallCore
import SwiftUI

/// The menu bar icon next to the clock.
struct StatusIcon: View {
    let store: RunStore

    var body: some View {
        let status = store.overallStatus
        Image(systemName: Self.symbol(for: status))
        if case .running(let count) = status { Text("\(count)") }
    }

    static func symbol(for status: OverallStatus) -> String {
        switch status {
        case .signedOut: "bolt.horizontal.circle"
        case .idle: "checkmark.circle"
        case .running: "arrow.triangle.2.circlepath"
        case .failing: "xmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }
}

/// Status symbol for a single run.
struct RunGlyph: View {
    let status: RunStatus
    let conclusion: RunConclusion?
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: status == .inProgress)
            .accessibilityLabel(label)
    }

    var symbol: String {
        if status.isActive { return status == .inProgress ? "circle.dotted.circle" : "clock" }
        switch conclusion ?? .unknown {
        case .success: return "checkmark.circle.fill"
        case .cancelled: return "slash.circle"
        case .skipped, .neutral, .stale: return "minus.circle"
        case let c where c.isFailure: return "xmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    var color: Color {
        if status.isActive { return status == .inProgress ? .orange : .secondary }
        switch conclusion ?? .unknown {
        case .success: return .green
        case let c where c.isFailure: return .red
        default: return .secondary
        }
    }

    var label: String {
        status.isActive ? status.rawValue.replacingOccurrences(of: "_", with: " ") : (conclusion?.rawValue ?? "unknown")
    }
}

extension WorkflowRun {
    var glyph: RunGlyph { RunGlyph(status: status, conclusion: conclusion) }
}

extension RunAction {
    var title: String {
        switch self {
        case .cancel: "Cancel run"
        case .rerun(failedOnly: true): "Re-run failed jobs"
        case .rerun(failedOnly: false): "Re-run all jobs"
        }
    }

    var symbol: String {
        switch self {
        case .cancel: "stop.circle"
        case .rerun: "arrow.counterclockwise"
        }
    }
}
