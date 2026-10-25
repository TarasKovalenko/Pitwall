import PitwallCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let store: RunStore

    var body: some View {
        TabView {
            AccountSettings(store: store)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            RepositorySettings(store: store)
                .tabItem { Label("Repositories", systemImage: "folder") }
            GeneralSettings(settings: store.settings)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 520, height: 460)
        .onAppear { NSApp.activate() }
    }
}

// MARK: - Account

private struct AccountSettings: View {
    let store: RunStore
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            if let user = store.user, store.authError == nil {
                LabeledContent("Signed in as", value: "@\(user.login)")
                Button("Sign out", role: .destructive) {
                    Task { await store.signOut() }
                }
            } else {
                Section {
                    SecureField("Personal access token", text: $token)
                        .textContentType(.password)
                    HStack {
                        Button("Save token") { submit { token } }
                            .disabled(token.isEmpty || busy)
                        if GitHubCLITokenImporter.cliPath != nil {
                            Button("Use GitHub CLI login") {
                                submit { try await GitHubCLITokenImporter.importToken() }
                            }
                            .disabled(busy)
                        }
                        if busy { ProgressView().controlSize(.small) }
                    }
                } footer: {
                    Text("""
                    Fine-grained token: Actions read & write, Contents read, Metadata read. \
                    Classic token: `repo` and `workflow` scopes. \
                    The token is kept in your login Keychain and only sent to api.github.com.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    private func submit(_ source: @escaping () async throws -> String) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await store.signIn(token: try await source())
                token = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Repositories

private struct RepositorySettings: View {
    let store: RunStore
    @State private var available: [Repository] = []
    @State private var search = ""
    @State private var manual = ""
    @State private var loading = false
    @State private var error: String?

    private var settings: AppSettings { store.settings }

    private var filtered: [Repository] {
        let tracked = Set(settings.trackedRepos.map(\.fullName))
        let base = available.filter { !tracked.contains($0.fullName) }
        guard !search.isEmpty else { return base }
        return base.filter { $0.fullName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Watching").font(.headline)
            if settings.trackedRepos.isEmpty {
                Text("Nothing yet. Pick repositories below.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(settings.trackedRepos, id: \.self) { ref in
                HStack {
                    Text(ref.fullName)
                    Spacer()
                    Button {
                        settings.untrack(ref)
                        store.syncRepoList()
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Divider()

            HStack {
                TextField("owner/repo", text: $manual)
                    .onSubmit(addManual)
                Button("Add", action: addManual).disabled(RepoRef(fullName: manual) == nil)
            }
            TextField("Search your repositories", text: $search)
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            }
            List(filtered) { repo in
                HStack {
                    Image(systemName: repo.isPrivate ? "lock" : "book.closed").foregroundStyle(.secondary)
                    Text(repo.fullName)
                    Spacer()
                    Button("Watch") {
                        guard let ref = RepoRef(fullName: repo.fullName) else { return }
                        settings.track(ref)
                        store.syncRepoList()
                        store.pokeSoon()
                    }
                }
            }
            .listStyle(.bordered)
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding()
        .task { await load() }
    }

    private func addManual() {
        guard let ref = RepoRef(fullName: manual) else { return }
        settings.track(ref)
        store.syncRepoList()
        store.pokeSoon()
        manual = ""
    }

    private func load() async {
        guard store.tokens.token() != nil, available.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            available = try await store.client.repositories()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Refresh") {
                Picker("While runs are active", selection: $settings.activeInterval) {
                    ForEach([5.0, 8, 15, 30], id: \.self) { Text("every \(Int($0))s").tag($0) }
                }
                Picker("When idle", selection: $settings.idleInterval) {
                    ForEach([30.0, 60, 120, 300], id: \.self) { Text(Self.label($0)).tag($0) }
                }
            }
            Section("Notch") {
                Toggle("Show runs around the notch", isOn: $settings.notchEnabled)
                Toggle("Keep it visible when nothing is running", isOn: $settings.notchAlwaysVisible)
                    .disabled(!settings.notchEnabled)
            }
            Section("Notifications") {
                Toggle("Run failed", isOn: $settings.notifyOnFailure)
                Toggle("Run passed", isOn: $settings.notifyOnSuccess)
                Toggle("Run started", isOn: $settings.notifyOnStart)
            }
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
        }
    }

    private static func label(_ seconds: Double) -> String {
        seconds < 60 ? "every \(Int(seconds))s" : "every \(Int(seconds / 60)) min"
    }
}
