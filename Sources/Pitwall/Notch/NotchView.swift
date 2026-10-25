import PitwallCore
import SwiftUI

struct NotchView: View {
    let model: NotchModel
    @Environment(RunStore.self) private var store

    private var g: NotchGeometry { model.geometry }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if model.isExpanded {
                    expanded
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else {
                    collapsed
                        .transition(.opacity)
                }
            }
            .frame(width: model.isExpanded ? NotchGeometry.expandedWidth : g.collapsedSize.width)
            .background(.black)
            .clipShape(UnevenRoundedRectangle(
                bottomLeadingRadius: model.isExpanded ? 22 : 10,
                bottomTrailingRadius: model.isExpanded ? 22 : 10
            ))
            .shadow(color: .black.opacity(model.isExpanded ? 0.35 : 0), radius: 12, y: 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    // MARK: Collapsed: two wings either side of the camera

    private var collapsed: some View {
        HStack(spacing: 0) {
            leftWing
                .frame(width: NotchGeometry.wingWidth, alignment: .leading)
                .padding(.leading, 12)
            Spacer(minLength: g.hasNotch ? g.notchSize.width - 24 : 8)
            rightWing
                .frame(width: NotchGeometry.wingWidth, alignment: .trailing)
                .padding(.trailing, 12)
        }
        .frame(height: g.notchSize.height)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var leftWing: some View {
        if let run = store.activeRuns.first?.run {
            HStack(spacing: 5) {
                run.glyph
                Text(store.activeRuns.first?.repo.name ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
        } else if let done = store.recentlyFinished.first?.run {
            done.glyph
        } else {
            Image(systemName: "bolt.horizontal.fill").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        let active = store.activeRuns
        if active.count > 1 {
            Text("\(active.count) runs").font(.system(size: 11, weight: .semibold).monospacedDigit())
        } else if let run = active.first {
            if let p = store.progress[run.id], p.totalJobs > 0 {
                CompactRing(fraction: p.fraction, failing: p.hasFailure)
            } else {
                Text(run.run.status == .queued ? "queued" : "…").font(.system(size: 10))
            }
        } else if let done = store.recentlyFinished.first?.run {
            Text(done.conclusion == .success ? "passed" : (done.conclusion?.rawValue ?? "done"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(done.conclusion == .success ? .green : .red)
        }
    }

    // MARK: Expanded: live list

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: max(g.notchSize.height - 6, 8))
            let active = store.activeRuns
            let finished = store.recentlyFinished.filter { f in !active.contains { $0.id == f.id } }
            if active.isEmpty && finished.isEmpty {
                Text("Nothing running")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            ForEach(active.prefix(4)) { run in
                NotchRunRow(tracked: run, progress: store.progress[run.id])
            }
            if !finished.isEmpty {
                Divider().overlay(.white.opacity(0.15))
                ForEach(finished.prefix(3)) { run in
                    NotchRunRow(tracked: run, progress: nil)
                }
            }
            if active.count > 4 {
                Text("+\(active.count - 4) more in the menu bar")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
        .background(GeometryReader { proxy in
            Color.clear.onAppear { model.expandedHeight = proxy.size.height }
                .onChange(of: proxy.size.height) { _, h in model.expandedHeight = h }
        })
        .frame(maxHeight: NotchGeometry.maxExpandedHeight, alignment: .top)
    }
}

private struct NotchRunRow: View {
    let tracked: TrackedRun
    let progress: RunProgress?
    @Environment(RunStore.self) private var store
    @State private var hovering = false

    private var run: WorkflowRun { tracked.run }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            run.glyph.padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(tracked.repo.name).font(.system(size: 12, weight: .semibold))
                    Text(run.name ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if run.status.isActive, let started = run.runStartedAt {
                        Text(started, style: .timer)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(run.title).font(.system(size: 11)).lineLimit(1).foregroundStyle(.white.opacity(0.85))
                if run.status.isActive {
                    ProgressView(value: progress?.fraction ?? 0)
                        .progressViewStyle(.linear)
                        .tint(progress?.hasFailure == true ? .red : .orange)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if hovering {
                Button {
                    let store = store, tracked = tracked
                    Task {
                        if tracked.run.status.isActive {
                            try? await store.cancel(tracked)
                        } else {
                            try? await store.rerun(tracked, failedOnly: tracked.run.conclusion?.isFailure == true)
                        }
                    }
                } label: {
                    Image(systemName: run.status.isActive ? "stop.circle" : "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help(run.status.isActive ? "Cancel run" : "Re-run")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { openOnGitHub(run.htmlURL) }
    }

    private var detail: String {
        guard let p = progress else { return run.status == .queued ? "Queued" : "Starting…" }
        let jobs = "\(p.completedJobs)/\(p.totalJobs) jobs"
        let current = [p.currentJob, p.currentStep].compactMap { $0 }.joined(separator: " › ")
        return current.isEmpty ? jobs : "\(jobs) · \(current)"
    }
}

/// Tiny progress ring for the collapsed wing.
private struct CompactRing: View {
    let fraction: Double
    let failing: Bool

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(fraction, 0.04))
                .stroke(failing ? .red : .orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
        }
        .frame(width: 14, height: 14)
    }
}
