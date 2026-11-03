import AppKit
import SwiftUI
import Combine
import OSLog

/// Geometry is independent of tokens and screen coordinates may be negative on
/// secondary displays. The anchor is the outer panel's top-center point.
enum CallPanelGeometry {
    static let collapsed = NSSize(width: 364, height: 76)
    static let expanded = NSSize(width: 444, height: 336)

    static func frame(size: NSSize, topCenter: NSPoint, visibleFrame: NSRect) -> NSRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let x = min(max(topCenter.x - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(topCenter.y - height, visibleFrame.minY), visibleFrame.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

/// The in-call surface must not take keyboard focus from the meeting or editor.
/// Nonactivating style alone is not the complete policy: key/main eligibility is
/// explicitly denied and presentation never activates NSApplication.
private final class PassiveCallPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class CallPanelController {
    private(set) var panel: NSPanel
    private let surface: CallSurfaceState
    private let presentationEnabled: Bool
    private let hosting: NSHostingView<CompactCallView>
    private var layoutRevision: UInt = 0
    private var subscriptions = Set<AnyCancellable>()
    private static let logger = Logger(subsystem: "com.kiankonrad.Clueless", category: "Controls")

    init(session: InterviewSession, surface: CallSurfaceState, openWorkspace: @escaping () -> Void, openSettings: (() -> Void)? = nil, presentationEnabled: Bool = true) {
        self.surface = surface
        self.presentationEnabled = presentationEnabled
        let visible = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let size = surface.expanded ? CallPanelGeometry.expanded : CallPanelGeometry.collapsed
        let frame = CallPanelGeometry.frame(size: size, topCenter: NSPoint(x: visible.midX, y: visible.maxY - 8), visibleFrame: visible)
        let window = PassiveCallPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Clueless Call Assistant"
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.acceptsMouseMovedEvents = true
        let root = CompactCallView(session: session, surface: surface, openWorkspace: openWorkspace, openSettings: openSettings ?? openWorkspace)
        let hosting = NSHostingView(rootView: root)
        self.hosting = hosting
        // The panel has two deliberate sizes. Streaming text must never cause
        // NSHostingView to resize the native window via intrinsic content size.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        panel = window

        surface.$expanded.removeDuplicates().sink { [weak self] _ in
            // @Published sends from willSet. Resizing here synchronously shrinks
            // AppKit while the hosted SwiftUI root still reads the old state.
            self?.scheduleLayout()
        }.store(in: &subscriptions)
        surface.$hidden.removeDuplicates().dropFirst().sink { [weak self] hidden in
            guard let self else { return }
            if hidden {
                self.layoutRevision &+= 1
                self.panel.orderOut(nil)
                Self.logger.info("Floating surface closed: visible=\(self.panel.isVisible, privacy: .public)")
            } else { self.scheduleLayout(present: true) }
        }.store(in: &subscriptions)
        // A repeated verbatim question can still be a new generation (Answer
        // now, a follow-up, or a retry). This field changes per request, not per
        // streamed token, so do not deduplicate identical question strings.
        session.$question.dropFirst().sink { [weak self] question in
            guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self?.surface.beginQuestion()
        }.store(in: &subscriptions)
        session.$answer.sink { [weak self] answer in
            guard let self else { return }
            let hasText = !answer.paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            self.surface.receiveAnswer(hasText: hasText)
            if hasText, !self.surface.hidden { self.presentIfNeeded() }
        }.store(in: &subscriptions)
        session.$error.removeDuplicates().sink { [weak self] error in
            guard let self, let error, !error.isEmpty, !self.surface.hidden else { return }
            self.surface.beginQuestion()
            self.surface.receiveAnswer(hasText: true)
            self.presentIfNeeded()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleLayout()
            }.store(in: &subscriptions)
    }

    func show() {
        surface.restore()
        layoutRevision &+= 1
        resize(expanded: surface.expanded, force: true)
        presentIfNeeded()
    }

    func hide() {
        surface.hide()
        panel.orderOut(nil)
    }

    func toggleVisibility() {
        if surface.hidden { show() } else { hide() }
    }

    private func presentIfNeeded() {
        guard presentationEnabled, !surface.hidden, !panel.isVisible else { return }
        resize(expanded: surface.expanded, force: true)
        // orderFrontRegardless does not activate the app or make this panel key.
        // Deliberate workspace buttons use the supplied callback; they alone may
        // activate the separate workspace window.
        panel.orderFrontRegardless()
    }

    private func scheduleLayout(present: Bool = false) {
        layoutRevision &+= 1
        let revision = layoutRevision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.layoutRevision == revision, !self.surface.hidden else { return }
            self.resize(expanded: self.surface.expanded, force: true)
            if present { self.presentIfNeeded() }
        }
    }

    private func resize(expanded: Bool, force: Bool = false) {
        let size = expanded ? CallPanelGeometry.expanded : CallPanelGeometry.collapsed
        if !force, panel.frame.size == size { return }
        let current = panel.frame
        let visible = visibleFrame(for: current)
        let target = CallPanelGeometry.frame(size: size, topCenter: NSPoint(x: current.midX, y: current.maxY), visibleFrame: visible)
        // Resize the existing host. Replacing its root tears down the capsule
        // and its material while AppKit is committing the new window size.
        if target != current { panel.setFrame(target, display: false, animate: false) }
        let bounds = NSRect(origin: .zero, size: panel.contentRect(forFrameRect: panel.frame).size)
        hosting.frame = bounds
        hosting.bounds = bounds
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        hosting.needsDisplay = true
        if presentationEnabled, panel.isVisible { panel.displayIfNeeded() }
    }

    private func visibleFrame(for frame: NSRect) -> NSRect {
        if let screen = panel.screen { return screen.visibleFrame }
        if let screen = NSScreen.screens.max(by: {
            let lhs = $0.frame.intersection(frame), rhs = $1.frame.intersection(frame)
            return max(0, lhs.width) * max(0, lhs.height) < max(0, rhs.width) * max(0, rhs.height)
        }) { return screen.visibleFrame }
        return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
    }
}
