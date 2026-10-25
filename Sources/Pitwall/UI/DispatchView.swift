import PitwallCore
import SwiftUI

/// Triggers a `workflow_dispatch` run.
struct DispatchView: View {
    let store: RunStore
    let repo: RepoRef
    let close: () -> Void

    @State private var options: DispatchOptions?
    @State private var form = DispatchForm()
    @State private var refQuery = ""
    @State private var loading = true
    @State private var sending = false
    @State private var message: (text: String, isError: Bool)?

    private let maxListedRefs = 50

    private struct SpecKey: Hashable {
        let workflowID: Int?
        let ref: GitRef?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: close) { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text("Run workflow").font(.headline)
                Text(repo.fullName).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let options {
                form(options)
            }
            if let message {
                Text(message.text).font(.caption).foregroundStyle(message.isError ? .red : .green)
            }
        }
        .padding(12)
        .task { await load() }
        .task(id: SpecKey(workflowID: form.workflowID, ref: form.selectedRef)) { await loadSpec() }
    }

    /// Fields scroll; the Run / Cancel row stays put at the bottom.
    @ViewBuilder
    private func form(_ options: DispatchOptions) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Workflow", selection: $form.workflowID) {
                    ForEach(options.workflows) { Text($0.name).tag(Optional($0.id)) }
                }
                refPicker(options)
                inputsSection
            }
            .padding(.trailing, 12)
        }
        .scrollIndicators(.visible)
        .scrollBounceBehavior(.basedOnSize)
        HStack {
            if let blocking = form.blockingProblem {
                Text(blocking).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Cancel", action: close)
            Button {
                Task { await send() }
            } label: {
                if sending { ProgressView().controlSize(.small) } else { Text("Run") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(form.blockingProblem != nil || sending)
        }
    }

    // MARK: Branch or tag

    private func refPicker(_ options: DispatchOptions) -> some View {
        let matches = options.refs(matching: refQuery)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Run on").font(.subheadline)
                if let selectedRef = form.selectedRef {
                    RefLabel(ref: selectedRef).font(.subheadline.weight(.medium))
                }
                Spacer()
            }
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search branches and tags", text: $refQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { if let first = matches.first { form.selectedRef = first } }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches.prefix(maxListedRefs)) { ref in
                        Button {
                            form.selectedRef = ref
                        } label: {
                            HStack {
                                RefLabel(ref: ref)
                                Spacer()
                                if ref == form.selectedRef { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 3)
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)
                        .background(ref == form.selectedRef ? Color.accentColor.opacity(0.12) : .clear)
                    }
                    if matches.isEmpty {
                        Text("No branch or tag matches “\(refQuery)”.").font(.caption).foregroundStyle(.secondary).padding(4)
                    } else if matches.count > maxListedRefs {
                        Text("\(matches.count - maxListedRefs) more. Keep typing to narrow it down.")
                            .font(.caption2).foregroundStyle(.secondary).padding(4)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .font(.callout)
    }

    // MARK: Inputs

    @ViewBuilder
    private var inputsSection: some View {
        switch form.spec {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading workflow inputs…").font(.caption).foregroundStyle(.secondary)
            }
        case .notDispatchable:
            Label("This workflow has no workflow_dispatch trigger on \(form.selectedRef?.name ?? "this ref").",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        case .ready(let spec):
            if spec.inputs.isEmpty {
                Text("No inputs.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(spec.inputs) { input in InputField(input: input, value: binding(for: input)) }
                }
            }
        case .unreadable(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't read inputs from the workflow file (\(reason)). Add them by hand.")
                    .font(.caption).foregroundStyle(.secondary)
                manualInputsEditor
            }
        }
    }

    private var manualInputsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Inputs").font(.subheadline)
                Spacer()
                Button {
                    form.manualInputs.append(DispatchForm.InputRow())
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(form.manualInputs.count >= Validation.maxDispatchInputs)
            }
            ForEach($form.manualInputs) { $row in
                HStack {
                    TextField("name", text: $row.key).frame(width: 120)
                    TextField("value", text: $row.value)
                    Button {
                        form.manualInputs.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            }
        }
    }

    private func binding(for input: WorkflowInput) -> Binding<String> {
        Binding(
            get: { form.values[input.key] ?? input.initialValue },
            set: { form.values[input.key] = $0 }
        )
    }

    // MARK: Loading and sending

    private func load() async {
        defer { loading = false }
        do {
            let options = try await store.dispatchOptions(for: repo)
            self.options = options
            form.start(with: options)
            if options.workflows.isEmpty { message = ("No active workflows in this repository.", true) }
        } catch {
            message = (error.localizedDescription, true)
        }
    }

    private func loadSpec() async {
        guard let workflow = selectedWorkflow, let ref = form.selectedRef else { return }
        form.spec = .loading
        do {
            let loaded = try await store.dispatchSpec(repo: repo, workflow: workflow, ref: ref)
            guard !Task.isCancelled else { return }
            form.apply(loaded)
        } catch {
            guard !Task.isCancelled else { return }
            form.apply(failure: error)
        }
    }

    private var selectedWorkflow: Workflow? {
        options?.workflows.first { $0.id == form.workflowID }
    }

    private func send() async {
        guard let workflow = selectedWorkflow, let ref = form.selectedRef else { return }
        sending = true
        defer { sending = false }
        do {
            let inputs = try form.inputsToSend()
            try await store.dispatch(repo: repo, workflow: workflow, ref: ref.name, inputs: inputs)
            message = ("Started on \(ref.name). It'll show up in a few seconds.", false)
            try? await Task.sleep(for: .seconds(1.5))
            close()
        } catch {
            message = (error.localizedDescription, true)
        }
    }
}

private struct RefLabel: View {
    let ref: GitRef

    var body: some View {
        Label(ref.name, systemImage: ref.kind == .branch ? "arrow.triangle.branch" : "tag")
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// One declared input, with the control its type calls for.
private struct InputField: View {
    let input: WorkflowInput
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch input.kind {
            case .boolean:
                Toggle(isOn: Binding(get: { value == "true" }, set: { value = $0 ? "true" : "false" })) { title }
            case .choice(let options):
                Picker(selection: $value) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                } label: {
                    title
                }
            case .string, .number, .environment:
                title
                TextField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
            }
            if let description = input.description {
                Text(description).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .font(.callout)
    }

    private var title: some View {
        HStack(spacing: 2) {
            Text(input.key).font(.callout.weight(.medium))
            if input.required { Text("*").foregroundStyle(.red) }
        }
    }

    private var placeholder: String {
        switch input.kind {
        case .number: "number"
        case .environment: "environment name"
        default: input.required ? "required" : "optional"
        }
    }
}
