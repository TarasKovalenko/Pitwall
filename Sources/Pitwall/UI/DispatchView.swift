import PitwallCore
import SwiftUI

/// Triggers a `workflow_dispatch` run.
struct DispatchView: View {
    let store: RunStore
    let repo: RepoRef
    let close: () -> Void

    @State private var workflows: [Workflow] = []
    @State private var branches: [String] = []
    @State private var workflowID: Int?
    @State private var ref = ""
    @State private var inputs: [InputRow] = []
    @State private var loading = true
    @State private var sending = false
    @State private var message: (text: String, isError: Bool)?

    struct InputRow: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
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
            } else {
                form
            }
            if let message {
                Text(message.text).font(.caption).foregroundStyle(message.isError ? .red : .green)
            }
        }
        .padding(12)
        .task { await load() }
    }

    @ViewBuilder
    private var form: some View {
        Picker("Workflow", selection: $workflowID) {
            ForEach(workflows) { Text($0.name).tag(Optional($0.id)) }
        }
        Picker("Branch", selection: $ref) {
            ForEach(branches, id: \.self) { Text($0).tag($0) }
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Inputs").font(.subheadline)
                Spacer()
                Button {
                    inputs.append(InputRow())
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(inputs.count >= Validation.maxDispatchInputs)
            }
            ForEach($inputs) { $row in
                HStack {
                    TextField("name", text: $row.key).frame(width: 120)
                    TextField("value", text: $row.value)
                    Button {
                        inputs.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            }
        }
        HStack {
            Spacer()
            Button("Cancel", action: close)
            Button {
                Task { await send() }
            } label: {
                if sending { ProgressView().controlSize(.small) } else { Text("Run") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(workflowID == nil || ref.isEmpty || sending)
        }
    }

    private func load() async {
        defer { loading = false }
        do {
            async let wf = store.client.workflows(for: repo)
            async let br = store.client.branches(for: repo)
            workflows = try await wf.filter(\.isActive)
            branches = try await br.map(\.name)
            workflowID = workflows.first?.id
            ref = ["main", "master", "develop"].first(where: branches.contains) ?? branches.first ?? ""
            if workflows.isEmpty { message = ("No active workflows in this repository.", true) }
        } catch {
            message = (error.localizedDescription, true)
        }
    }

    private func send() async {
        guard let workflow = workflows.first(where: { $0.id == workflowID }) else { return }
        var values: [String: String] = [:]
        for row in inputs where !row.key.trimmingCharacters(in: .whitespaces).isEmpty {
            values[row.key.trimmingCharacters(in: .whitespaces)] = row.value
        }
        sending = true
        defer { sending = false }
        do {
            try await store.dispatch(repo: repo, workflow: workflow, ref: ref, inputs: values)
            message = ("Started. It'll show up in a few seconds.", false)
            try? await Task.sleep(for: .seconds(1.5))
            close()
        } catch {
            message = (error.localizedDescription, true)
        }
    }
}
