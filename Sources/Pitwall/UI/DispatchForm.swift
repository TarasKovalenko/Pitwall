import Foundation
import PitwallCore

/// Everything the Run workflow form has chosen or typed, and what follows
/// from it. A value type so the rules are testable without the view.
struct DispatchForm: Equatable {
    /// What we know about the selected workflow's inputs at the selected ref.
    enum SpecState: Equatable {
        case loading
        case ready(DispatchSpec)
        /// No `workflow_dispatch` trigger at this ref.
        case notDispatchable
        /// The file couldn't be fetched or parsed; fall back to free-form inputs.
        case unreadable(String)
    }

    struct InputRow: Identifiable, Equatable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    var workflowID: Int?
    var selectedRef: GitRef?
    var spec: SpecState = .loading
    /// Typed values for declared inputs, by key.
    var values: [String: String] = [:]
    /// Free-form inputs, used only when the file couldn't be read.
    var manualInputs: [InputRow] = []

    /// Pick the defaults once the options arrive.
    mutating func start(with options: DispatchOptions) {
        workflowID = options.workflows.first?.id
        selectedRef = options.suggestedRef
    }

    /// Apply the result of reading the workflow file.
    mutating func apply(_ loaded: DispatchSpec?) {
        guard let loaded else {
            spec = .notDispatchable
            return
        }
        // Keep what the user typed for inputs that still exist.
        let keys = Set(loaded.inputs.map(\.key))
        values = values.filter { keys.contains($0.key) }
        spec = .ready(loaded)
    }

    mutating func apply(failure error: Error) {
        spec = .unreadable(error is YAMLError ? "unsupported YAML" : error.localizedDescription)
    }

    /// Why Run is disabled right now, if it is.
    var blockingProblem: String? {
        guard workflowID != nil else { return "Pick a workflow." }
        guard selectedRef != nil else { return "Pick a branch or tag." }
        switch spec {
        case .loading: return "Reading inputs…"
        case .notDispatchable: return "Can't run this workflow by hand."
        case .ready(let spec):
            do { _ = try spec.values(from: values) } catch { return error.localizedDescription }
            return nil
        case .unreadable: return nil
        }
    }

    /// What to send as `inputs`.
    func inputsToSend() throws -> [String: String] {
        if case .ready(let spec) = spec { return try spec.values(from: values) }
        var manual: [String: String] = [:]
        for row in manualInputs {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { manual[key] = row.value }
        }
        return manual
    }
}
