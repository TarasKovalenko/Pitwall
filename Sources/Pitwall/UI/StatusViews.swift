import PitwallCore
import SwiftUI

/// The menu bar icon next to the clock.
struct StatusIcon: View {
    let store: RunStore

    var body: some View {
        switch store.overallStatus {
        case .signedOut:
            Image(systemName: "bolt.horizontal.circle")
        case .idle:
            Image(systemName: "checkmark.circle")
        case .running(let count):
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("\(count)")
        case .failing:
            Image(systemName: "xmark.circle")
        case .error:
            Image(systemName: "exclamationmark.triangle")
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

    private var symbol: String {
        if status.isActive { return status == .inProgress ? "circle.dotted.circle" : "clock" }
        switch conclusion ?? .unknown {
        case .success: return "checkmark.circle.fill"
        case .cancelled: return "slash.circle"
        case .skipped, .neutral, .stale: return "minus.circle"
        case let c where c.isFailure: return "xmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    private var color: Color {
        if status.isActive { return status == .inProgress ? .orange : .secondary }
        switch conclusion ?? .unknown {
        case .success: return .green
        case let c where c.isFailure: return .red
        default: return .secondary
        }
    }

    private var label: String {
        status.isActive ? status.rawValue.replacingOccurrences(of: "_", with: " ") : (conclusion?.rawValue ?? "unknown")
    }
}

extension WorkflowRun {
    var glyph: RunGlyph { RunGlyph(status: status, conclusion: conclusion) }
}
