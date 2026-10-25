import Foundation

/// A branch or tag a workflow can run on.
public struct GitRef: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case branch, tag }

    public let kind: Kind
    public let name: String
    public var id: String { "\(kind == .branch ? "b" : "t"):\(name)" }

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }
}

/// What the "Run workflow" form can offer for a repository.
public struct DispatchOptions: Sendable, Equatable {
    public let workflows: [Workflow]
    /// Branches first, then tags, each in the order GitHub returned them.
    public let refs: [GitRef]
    /// Pre-selected ref: a conventional default branch if the repo has one.
    public let suggestedRef: GitRef?

    public init(workflows: [Workflow], branches: [String], tags: [String] = []) {
        self.workflows = workflows.filter(\.isActive)
        let branchRefs = branches.map { GitRef(kind: .branch, name: $0) }
        refs = branchRefs + tags.map { GitRef(kind: .tag, name: $0) }
        suggestedRef = ["main", "master", "develop"].lazy
            .compactMap { name in branchRefs.first { $0.name == name } }
            .first ?? branchRefs.first ?? refs.first
    }

    /// Refs whose name contains `query`, ignoring case. Names that start with
    /// it come first; branches before tags within each group.
    public func refs(matching query: String) -> [GitRef] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return refs }
        let hits = refs.filter { $0.name.localizedCaseInsensitiveContains(q) }
        let prefix = hits.filter { $0.name.lowercased().hasPrefix(q.lowercased()) }
        return prefix + hits.filter { !$0.name.lowercased().hasPrefix(q.lowercased()) }
    }
}

/// One `workflow_dispatch` input as declared in the workflow file.
public struct WorkflowInput: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case string, number, boolean, environment
        case choice([String])
    }

    public let key: String
    public let description: String?
    public let required: Bool
    public let defaultValue: String?
    public let kind: Kind
    public var id: String { key }

    public init(key: String, description: String? = nil, required: Bool = false, defaultValue: String? = nil, kind: Kind = .string) {
        self.key = key
        self.description = description
        self.required = required
        self.defaultValue = defaultValue
        self.kind = kind
    }

    /// What the form starts with.
    public var initialValue: String {
        switch kind {
        case .boolean: defaultValue ?? "false"
        case .choice(let options): defaultValue.flatMap { options.contains($0) ? $0 : nil } ?? options.first ?? ""
        default: defaultValue ?? ""
        }
    }

    /// Why `value` can't be sent, or nil if it's fine.
    public func problem(with value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return required ? "\(key) is required." : nil }
        guard value.utf8.count <= Validation.maxInputValueLength else { return "\(key) is too long." }
        switch kind {
        case .number where Double(trimmed) == nil: return "\(key) must be a number."
        case .boolean where trimmed != "true" && trimmed != "false": return "\(key) must be true or false."
        case .choice(let options) where !options.contains(value): return "\(key) must be one of the listed options."
        default: return nil
        }
    }
}

/// The `workflow_dispatch` part of a workflow file.
public struct DispatchSpec: Sendable, Equatable {
    public let inputs: [WorkflowInput]

    public init(inputs: [WorkflowInput]) {
        self.inputs = inputs
    }

    /// Nil when the workflow can't be started by hand (no `workflow_dispatch`).
    /// Throws when the file isn't YAML we can read.
    public static func parse(workflowYAML source: String) throws -> DispatchSpec? {
        let root = try MiniYAML.parse(source)
        guard let on = root["on"] ?? root["true"] else { return nil }
        switch on {
        case .scalar(let event):
            return event == "workflow_dispatch" ? DispatchSpec(inputs: []) : nil
        case .list(let events):
            return events.contains(.scalar("workflow_dispatch")) ? DispatchSpec(inputs: []) : nil
        case .map:
            guard let dispatch = on["workflow_dispatch"] else { return nil }
            return DispatchSpec(inputs: inputs(from: dispatch["inputs"]))
        }
    }

    private static func inputs(from node: YAMLNode?) -> [WorkflowInput] {
        guard case .map(let entries)? = node else { return [] }
        var seen = Set<String>()
        var out: [WorkflowInput] = []
        for entry in entries where Validation.isValidInputKey(entry.key) && seen.insert(entry.key).inserted {
            let spec = entry.value
            let type = spec["type"]?.string?.lowercased() ?? "string"
            let kind: WorkflowInput.Kind
            switch type {
            case "boolean": kind = .boolean
            case "number": kind = .number
            case "environment": kind = .environment
            case "choice":
                guard case .list(let options)? = spec["options"] else { continue }
                kind = .choice(options.compactMap(\.string).filter { !$0.isEmpty })
            default: kind = .string
            }
            var defaultValue = spec["default"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            if kind == .boolean, let d = defaultValue {
                defaultValue = ["true", "yes", "on"].contains(d.lowercased()) ? "true" : "false"
            }
            out.append(WorkflowInput(
                key: entry.key,
                description: spec["description"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(500)) },
                required: spec["required"]?.string?.lowercased() == "true",
                defaultValue: defaultValue,
                kind: kind
            ))
            if out.count == Validation.maxDispatchInputs { break }
        }
        return out
    }

    /// Values to send, checked against the declared inputs. Empty optional
    /// values are left out so GitHub applies the workflow's own defaults.
    public func values(from entered: [String: String]) throws -> [String: String] {
        var out: [String: String] = [:]
        for input in inputs {
            let value = entered[input.key] ?? input.initialValue
            if let problem = input.problem(with: value) { throw GitHubError.invalidInput(problem) }
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out[input.key] = value }
        }
        return out
    }
}
