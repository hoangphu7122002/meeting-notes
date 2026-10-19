import AppKit
import MeetingNotesCore
import SwiftUI

/// Borderless, non-activating floating panel on all Spaces (incl. full-screen ones).
/// It becomes key only when a text field inside needs it (`becomesKeyOnlyIfNeeded`), so clicking
/// buttons never takes keyboard focus from the frontmost app.
final class FloatingPanel: NSPanel {
    init(size: CGSize = CGSize(width: 120, height: 36)) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view with an always-active hover tracking area and first-click delivery.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}

struct SizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

extension View {
    /// Reports the view's ideal size (used to fit panels to their content).
    func reportSize(_ action: @escaping (CGSize) -> Void) -> some View {
        fixedSize()
            .background(GeometryReader { proxy in Color.clear.preference(key: SizeKey.self, value: proxy.size) })
            .onPreferenceChange(SizeKey.self) { size in action(size) }
    }
}

// MARK: - Pill window

@MainActor
final class PillUIModel: ObservableObject {
    @Published var expanded = false
    @Published var editingTitle = false
}

/// The bottom-center pill: positioning, dragging, hover expand/collapse, visibility, level sampling.
@MainActor
final class PillWindowController {
    let panel = FloatingPanel()
    let ui = PillUIModel()
    private let controller: AppController
    private var hosting: PanelHostingView<PillRootView>!
    private var size = CGSize(width: 120, height: 36)
    private var anchor: CGPoint
    private var hovering = false
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var dragStart: (mouse: CGPoint, anchor: CGPoint)?
    private var levelTimer: Timer?
    /// Shown on launch/reopen even when the idle pill is disabled; cleared on collapse.
    private var forcedVisible = false
    private var occlusionObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    init(controller: AppController) {
        self.controller = controller
        anchor = Self.defaultAnchor()
        if let saved = Settings.pillAnchor, Self.isOnScreen(saved) { anchor = saved }
        let actions = PillActions(
            sizeChanged: { [weak self] size in
                // Resize after SwiftUI's update pass (avoids re-entrant layout of the hosting view).
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.setSize(size) } }
            },
            expand: { [weak self] in self?.expand() },
            collapse: { [weak self] in self?.collapse() },
            dragChanged: { [weak self] in self?.dragChanged() },
            dragEnded: { [weak self] in self?.dragEnded() },
            editingChanged: { [weak self] in self?.editingChanged($0) })
        hosting = PanelHostingView(rootView: PillRootView(app: controller, ui: ui, clock: controller.clock,
                                                          levels: controller.levels, actions: actions))
        hosting.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        panel.contentView = hosting
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateLevelTimer() } }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // Clicking another app ends title editing (commits it).
            MainActor.assumeIsolated { if self?.ui.editingTitle == true { self?.panel.makeFirstResponder(nil) } }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.screensChanged() } }
    }

    /// Called after the panel moved or resized.
    var onFrameChange: ((NSRect) -> Void)?

    var isExpanded: Bool { ui.expanded }
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    /// Applies visibility for the current state.
    func update() {
        let shouldShow = !controller.pill.isIdle || controller.idlePillAllowed || forcedVisible || ui.expanded
        if shouldShow {
            if !panel.isVisible {
                place()
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
            hovering = false
        }
        updateLevelTimer()
    }

    /// Brings the pill to front; `expand` opens it briefly (launch, Dock click, `open -a`).
    func show(expand: Bool) {
        controller.unhidePill()
        forcedVisible = true
        place()
        panel.orderFrontRegardless()
        if expand {
            self.expand()
            scheduleCollapse(after: 4)
        }
        update()
    }

    func resetPosition() {
        Settings.pillAnchor = nil
        anchor = Self.defaultAnchor()
        place()
    }

    // MARK: - Expand / collapse

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        if inside {
            collapseWork?.cancel()
            guard !ui.expanded else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hovering, self.dragStart == nil else { return }
                    self.expand()
                }
            }
            expandWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else {
            expandWork?.cancel()
            scheduleCollapse(after: 1)
        }
    }

    private func expand() {
        collapseWork?.cancel()
        if !ui.expanded { ui.expanded = true }
    }

    func collapse() {
        collapseWork?.cancel()
        if ui.editingTitle { panel.makeFirstResponder(nil) }
        if controller.machine.confirmingDiscard { controller.perform(.cancelDiscard, source: .pill) }
        if ui.expanded { ui.expanded = false }
        forcedVisible = false
        update()
    }

    private func scheduleCollapse(after seconds: Double) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hovering = self.panel.isVisible && self.panel.frame.contains(NSEvent.mouseLocation)
                guard !self.hovering else { return }
                // Keep it open while the user types a title or answers the discard question.
                if self.ui.editingTitle || self.controller.machine.confirmingDiscard {
                    self.scheduleCollapse(after: 2)
                    return
                }
                self.collapse()
            }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func editingChanged(_ editing: Bool) {
        ui.editingTitle = editing
        if editing {
            controller.titleEditingBegan()
            return
        }
        if panel.isKeyWindow {
            // Hand keyboard focus back to the app the user was in (the panel never activates us).
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        if !hovering { scheduleCollapse(after: 1) }
    }

    // MARK: - Geometry

    private func setSize(_ newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0 else { return }
        let rounded = CGSize(width: ceil(newSize.width), height: ceil(newSize.height))
        guard rounded != size else { return }
        size = rounded
        place()
    }

    /// Frame from the bottom-center anchor, kept inside the screen's visible frame.
    private func place() {
        var origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y)
        if let visible = Self.screen(containing: anchor)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 2), visible.maxY - size.height - 2)
        }
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            onFrameChange?(frame)
        }
    }

    private func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (mouse, anchor)
            expandWork?.cancel()
        }
        guard let start = dragStart else { return }
        anchor = CGPoint(x: start.anchor.x + mouse.x - start.mouse.x, y: start.anchor.y + mouse.y - start.mouse.y)
        place()
    }

    private func dragEnded() {
        dragStart = nil
        // Store the clamped position.
        anchor = CGPoint(x: panel.frame.midX, y: panel.frame.minY)
        Settings.pillAnchor = anchor
    }

    private func screensChanged() {
        if !Self.isOnScreen(anchor) { anchor = Self.defaultAnchor() }
        place()
    }

    private static func defaultAnchor() -> CGPoint {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: visible.midX, y: visible.minY + 10)
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) } ?? NSScreen.main
    }

    private static func isOnScreen(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(point) }
    }

    // MARK: - Levels (only while visible and recording)

    private func updateLevelTimer() {
        let needed = controller.machine.phase == .recording && panel.isVisible && panel.occlusionState.contains(.visible)
        if needed, levelTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.sampleLevels() }
            }
            timer.tolerance = 0.03
            RunLoop.main.add(timer, forMode: .common)
            levelTimer = timer
        } else if !needed, let timer = levelTimer {
            timer.invalidate()
            levelTimer = nil
            controller.sampleLevels()  // resets to 0 when not recording
        }
    }
}

// MARK: - Toast

@MainActor
final class ToastModel: ObservableObject {
    @Published var text = ""
}

/// Brief HUD message above the pill (~1.5 s, one fade, no loops).
@MainActor
final class ToastPanel {
    private let panel = FloatingPanel()
    private let model = ToastModel()
    private var hideWork: DispatchWorkItem?
    private var size = CGSize(width: 160, height: 30)
    private var anchorFrame: NSRect = .zero

    init() {
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        let view = ToastView(model: model, sizeChanged: { [weak self] size in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sizeChanged(size) } }
        })
        let hosting = PanelHostingView(rootView: view)
        panel.contentView = hosting
    }

    func show(_ text: String, above frame: NSRect) {
        anchorFrame = frame
        model.text = text
        place()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    self.panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated { if self.panel.alphaValue == 0 { self.panel.orderOut(nil) } }
                })
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func sizeChanged(_ newSize: CGSize) {
        size = CGSize(width: ceil(newSize.width), height: ceil(newSize.height))
        place()
    }

    private func place() {
        var origin = CGPoint(x: anchorFrame.midX - size.width / 2, y: anchorFrame.maxY + 8)
        if let visible = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchorFrame.midX, y: anchorFrame.minY)) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(origin.y, visible.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

struct ToastView: View {
    @ObservedObject var model: ToastModel
    let sizeChanged: (CGSize) -> Void

    var body: some View {
        Text(model.text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.85)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
            .padding(2)
            .reportSize(sizeChanged)
    }
}

// MARK: - Cards (meeting detected, auto-stop)

/// Small floating card at the top-right of the screen or above the pill.
@MainActor
final class CardPanel {
    enum Placement {
        case topRight
        case above(NSRect)
    }

    private let panel = FloatingPanel(size: CGSize(width: 320, height: 120))
    private var placement = Placement.topRight
    private var size = CGSize(width: 320, height: 120)

    var isVisible: Bool { panel.isVisible }

    func show<Content: View>(_ content: Content, placement: Placement) {
        self.placement = placement
        let view = content.reportSize { [weak self] size in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sizeChanged(size) } }
        }
        panel.contentView = PanelHostingView(rootView: AnyView(view))
        place()
        panel.orderFrontRegardless()
    }

    func move(to placement: Placement) {
        self.placement = placement
        place()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // Release the content later: hide() usually runs inside one of its own button actions.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.panel.isVisible else { return }
                self.panel.contentView = nil
            }
        }
    }

    private func sizeChanged(_ newSize: CGSize) {
        size = CGSize(width: ceil(newSize.width), height: ceil(newSize.height))
        place()
    }

    private func place() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: CGPoint
        switch placement {
        case .topRight:
            origin = CGPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
        case .above(let frame):
            origin = CGPoint(x: frame.midX - size.width / 2, y: frame.maxY + 10)
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(origin.y, visible.maxY - size.height - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
