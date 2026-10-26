import AppKit
import PitwallCore
import SwiftUI

@MainActor
@Observable
final class NotchModel {
    var isExpanded = false
    /// Showing the wings beside the notch, before the full list opens.
    var isPeeking = false
    var geometry: NotchGeometry
    /// Called when the wings are clicked while peeking.
    var onPeekTap: () -> Void = {}
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
    private var expandWork: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private let geometryProvider: @MainActor () -> NotchGeometry?

    init(store: RunStore, settings: AppSettings, geometry: @escaping @MainActor () -> NotchGeometry? = NotchGeometry.current) {
        self.store = store
        self.settings = settings
        self.geometryProvider = geometry
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
        observe()
        update()
    }

    private var shouldShow: Bool { Self.shouldShow(settings: settings, store: store) }

    /// Visible when enabled, signed in, and there's something to show (or it's pinned).
    static func shouldShow(settings: AppSettings, store: RunStore) -> Bool {
        guard settings.notchEnabled, store.authState.user != nil else { return false }
        return settings.notchAlwaysVisible || hasActivity(store)
    }

    static func hasActivity(_ store: RunStore) -> Bool {
        !store.activeRuns.isEmpty || !store.recentlyFinished.isEmpty
    }

    /// The wings stay out at rest while something is running or just finished,
    /// and always on a pill. Only an idle notch shrinks to the notch itself.
    static func restsWithWings(_ geometry: NotchGeometry, store: RunStore) -> Bool {
        !geometry.hasNotch || hasActivity(store)
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
        guard model?.isExpanded != true, model?.isPeeking != true else { return }
        panel?.orderOut(nil)
        removeMonitors()
    }

    /// For tests: whether the panel is on screen, and expanded.
    var isShowing: Bool { panel?.isVisible == true }
    var isExpanded: Bool { model?.isExpanded == true }
    var isPeeking: Bool { model?.isPeeking == true }
    var geometry: NotchGeometry? { model?.geometry }

    private func makePanel() {
        guard let geometry = geometryProvider() else { return }
        let model = NotchModel(geometry: geometry)
        model.onPeekTap = { [weak self] in self?.setExpanded(true) }
        let panel = NotchPanel(contentRect: geometry.panelFrame)
        let root = NotchView(model: model).environment(store)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: geometry.panelFrame.size)
        panel.contentView = host
        self.model = model
        self.panel = panel
    }

    func relayout() {
        guard let geometry = geometryProvider(), let panel, let model else { return }
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

    func mouseMoved(to point: NSPoint) {
        guard let model, let panel else { return }
        let g = model.geometry
        if model.isExpanded || model.isPeeking {
            let area = model.isExpanded ? g.expandedRect(height: model.expandedHeight) : g.peekRect
            if area.insetBy(dx: -8, dy: -8).contains(point) {
                collapseWork?.cancel()
                collapseWork = nil
                if model.isPeeking, expandWork == nil { startExpandDwell() }
            } else if collapseWork == nil {
                expandWork?.cancel()
                expandWork = nil
                // Small grace period so a slightly sloppy mouse doesn't snap it shut.
                collapseWork = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    self?.setExpanded(false)
                }
            }
        } else if panel.isVisible {
            // Wings already out: open the list. Idle notch: show the wings first,
            // and staying a moment (or clicking) opens the list.
            if Self.restsWithWings(g, store: store) {
                if g.peekRect.contains(point) { setExpanded(true) }
            } else if g.collapsedRect.contains(point) {
                setPeeking()
            }
        }
    }

    private func setPeeking() {
        guard let model, let panel else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            model.isPeeking = true
        }
        panel.ignoresMouseEvents = false
        startExpandDwell()
    }

    private func startExpandDwell() {
        expandWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.setExpanded(true)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        collapseWork = nil
        expandWork?.cancel()
        expandWork = nil
        guard let model, let panel else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            model.isExpanded = expanded
            model.isPeeking = false
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
