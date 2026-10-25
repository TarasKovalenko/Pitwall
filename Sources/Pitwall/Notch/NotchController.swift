import AppKit
import PitwallCore
import SwiftUI

@MainActor
@Observable
final class NotchModel {
    var isExpanded = false
    var geometry: NotchGeometry
    /// Measured height of the expanded content, for hover hit-testing.
    var expandedHeight: CGFloat = 120

    init(geometry: NotchGeometry) { self.geometry = geometry }
}

/// Borderless panel sitting over the notch. It ignores the mouse while
/// collapsed so the menu bar under its transparent area keeps working;
/// a cheap mouse-moved monitor decides when to expand.
@MainActor
final class NotchController {
    private let store: RunStore
    private let settings: AppSettings
    private var panel: NotchPanel?
    private var model: NotchModel?
    private var monitors: [Any] = []
    private var collapseWork: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    init(store: RunStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
        observe()
        update()
    }

    private var shouldShow: Bool {
        guard settings.notchEnabled, store.user != nil else { return false }
        return settings.notchAlwaysVisible || !store.activeRuns.isEmpty || !store.recentlyFinished.isEmpty
    }

    /// Re-runs `update` whenever anything `shouldShow` reads changes.
    private func observe() {
        withObservationTracking {
            _ = shouldShow
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        if shouldShow { show() } else { hide() }
    }

    private func show() {
        if panel == nil { makePanel() }
        guard let panel else { return }
        if !panel.isVisible {
            panel.orderFrontRegardless()
            installMonitors()
        }
    }

    private func hide() {
        // Don't yank it away while the user is reading it.
        guard model?.isExpanded != true else { return }
        panel?.orderOut(nil)
        removeMonitors()
    }

    private func makePanel() {
        guard let geometry = NotchGeometry.current() else { return }
        let model = NotchModel(geometry: geometry)
        let panel = NotchPanel(contentRect: geometry.panelFrame)
        let root = NotchView(model: model).environment(store)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: geometry.panelFrame.size)
        panel.contentView = host
        self.model = model
        self.panel = panel
    }

    private func relayout() {
        guard let geometry = NotchGeometry.current(), let panel, let model else { return }
        model.geometry = geometry
        panel.setFrame(geometry.panelFrame, display: true)
    }

    // MARK: Hover

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved(to: NSEvent.mouseLocation) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func mouseMoved(to point: NSPoint) {
        guard let model, let panel else { return }
        let g = model.geometry
        if model.isExpanded {
            let inside = g.expandedRect(height: model.expandedHeight).insetBy(dx: -8, dy: -8).contains(point)
            if inside {
                collapseWork?.cancel()
                collapseWork = nil
            } else if collapseWork == nil {
                // Small grace period so a slightly sloppy mouse doesn't snap it shut.
                collapseWork = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    self?.setExpanded(false)
                }
            }
        } else if g.collapsedRect.contains(point), panel.isVisible {
            setExpanded(true)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        collapseWork = nil
        guard let model, let panel else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            model.isExpanded = expanded
        }
        panel.ignoresMouseEvents = !expanded
        if !expanded { update() }
    }
}

final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
