import PitwallCore
import SwiftUI

struct MenuContentView: View {
    let store: RunStore
    @State private var expanded: Set<RepoRef> = []
    @State private var dispatchTarget: RepoRef?
    @State private var banner: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let banner {
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.red.opacity(0.85))
                    .onTapGesture { self.banner = nil }
            }
            content
            Divider()
            footer
        }
        .frame(width: 380)
        .frame(maxHeight: 560)
        .environment(store)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Pitwall").font(.headline)
            if let login = store.authState.user?.login {
                Text("@\(login)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
                .keyboardShortcut("r")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if case .signedOut = store.authState {
            EmptyStateView(symbol: "key", title: "Connect GitHub", message: "Add a token or import the one from GitHub CLI.")
        } else if case .tokenProblem(let message) = store.authState {
            EmptyStateView(symbol: "key", title: "Token problem", message: message)
        } else if let repo = dispatchTarget {
            DispatchView(store: store, repo: repo) { dispatchTarget = nil }
        } else if store.repos.isEmpty {
            EmptyStateView(symbol: "tray", title: "No repositories yet", message: "Pick the ones to watch in Settings.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.repos) { repo in
                        RepoSection(
                            state: repo,
                            progress: store.progress,
                            isExpanded: expanded.contains(repo.ref),
                            toggle: { toggle(repo.ref) },
                            onDispatch: { dispatchTarget = repo.ref },
                            perform: perform
                        )
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let rl = store.rateLimit {
                Text("\(rl.remaining.formatted()) / \(rl.limit.formatted()) API calls left")
                    .font(.caption2)
                    .foregroundStyle(rl.remaining < 200 ? .orange : .secondary)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Pitwall")
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toggle(_ ref: RepoRef) {
        if expanded.contains(ref) { expanded.remove(ref) } else { expanded.insert(ref) }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                banner = nil
            } catch {
                banner = error.localizedDescription
            }
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SettingsLink { Text("Open Settings") }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

private struct RepoSection: View {
    let state: RepoState
    let progress: [Int: RunProgress]
    let isExpanded: Bool
    let toggle: () -> Void
    let onDispatch: () -> Void
    let perform: (@escaping () async throws -> Void) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let run = state.latestRun {
                    run.glyph
                } else {
                    RunGlyph(status: .unknown, conclusion: nil)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.ref.name).font(.system(.body, weight: .medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    Button("Run workflow…", action: onDispatch)
                    Button("Open Actions on GitHub") { openOnGitHub(state.ref, path: "/actions") }
                    Button("Open repository") { openOnGitHub(state.ref) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            // Active runs are always visible; the rest only when expanded.
            let runs = isExpanded ? Array(state.runs.prefix(8)) : state.activeRuns
            ForEach(runs) { run in
                RunRow(
                    tracked: TrackedRun(repo: state.ref, run: run),
                    progress: progress[run.id],
                    perform: perform
                )
            }
        }
    }

    private var subtitle: String { RunText.repoSubtitle(state) }
}

struct RunRow: View {
    let tracked: TrackedRun
    let progress: RunProgress?
    let perform: (@escaping () async throws -> Void) -> Void
    @Environment(RunStore.self) private var store
    @State private var hovering: Bool

    init(tracked: TrackedRun, progress: RunProgress?, perform: @escaping (@escaping () async throws -> Void) -> Void,
         hovering: Bool = false) {
        self.tracked = tracked
        self.progress = progress
        self.perform = perform
        _hovering = State(initialValue: hovering)
    }

    private var run: WorkflowRun { tracked.run }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            run.glyph.padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.title).font(.callout).lineLimit(1)
                Text(meta).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if run.status.isActive, let progress {
                    ProgressView(value: progress.fraction)
                        .tint(progress.hasFailure ? .red : .orange)
                    if let activity = progress.currentActivity {
                        Text(activity)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if hovering { actions }
        }
        .padding(.leading, 32)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { openOnGitHub(run.htmlURL) }
        .contextMenu { menuItems }
    }

    private var meta: String { RunText.runMeta(run, progress: progress) }

    @ViewBuilder
    private var actions: some View {
        let action = run.primaryAction
        Button { perform(action) } label: { Image(systemName: action.symbol) }
            .help(action.title)
            .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Open on GitHub") { openOnGitHub(run.htmlURL) }
        Divider()
        ForEach(run.availableActions, id: \.self) { action in
            Button(action.title) { perform(action) }
        }
    }

    private func perform(_ action: RunAction) {
        let store = store, tracked = tracked
        perform { try await store.perform(action, on: tracked) }
    }
}
