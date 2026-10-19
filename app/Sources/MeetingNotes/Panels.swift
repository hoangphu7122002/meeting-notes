import AppKit
import MeetingNotesCore
import MeetingNotesUI
import SwiftUI

// MARK: - Pill window

/// The bottom-center pill: sizing, positioning, dragging, hover expand/collapse, visibility, meters.
///
/// Sizing: the panel always takes the hosting view's `fittedSize` (the SwiftUI content's ideal size).
/// The content reports every size change (state, warnings, title, language) through
/// `onFittingSizeChange`; the panel is then re-anchored so its bottom-center stays fixed.
@MainActor
final class PillWindowController {
    let panel = FloatingPanel()
    let ui = PillUIModel()
    private let controller: AppController
    private var hosting: FittingHostingView<PillRootView>!
    private var size = CGSize(width: PillLayout.collapsedMinWidth, height: PillLayout.collapsedHeight)
    private var anchor: CGPoint
    private var hovering = false
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var resizeScheduled = false
    private var dragStart: (mouse: CGPoint, anchor: CGPoint)?
    /// Shown from the menu even when the settings hide it; cleared on collapse.
    private var forcedVisible = false
    private var observers: [NSObjectProtocol] = []

    init(controller: AppController) {
        self.controller = controller
        anchor = Self.defaultAnchor()
        if let saved = Settings.pillAnchor, Self.isOnScreen(saved) { anchor = saved }
        let actions = PillActions(
            sizeChanged: { [weak self] _ in self?.scheduleResize() },
            expand: { [weak self] in self?.expand() },
            collapse: { [weak self] in self?.collapse() },
            dragChanged: { [weak self] in self?.dragChanged() },
            dragEnded: { [weak self] in self?.dragEnded() },
            editingChanged: { [weak self] in self?.editingChanged($0) })
        hosting = FittingHostingView(rootView: PillRootView(state: controller.state, ui: ui, commands: controller, actions: actions))
        hosting.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        panel.contentView = hosting
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMeters() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // Clicking another app ends title editing (commits it).
            MainActor.assumeIsolated { if self?.ui.editingTitle == true { self?.panel.makeFirstResponder(nil) } }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
    }

    /// Called after the panel moved or resized.
    var onFrameChange: ((NSRect) -> Void)?

    var isExpanded: Bool { ui.expanded }
    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    /// Where the collapsed pill is (or would be when shown): toasts and cards are placed above it.
    var restingFrame: NSRect {
        if panel.isVisible { return panel.frame }
        let collapsed = CGSize(width: PillLayout.collapsedMinWidth, height: PillLayout.collapsedHeight)
        return PillLayout.frame(size: collapsed, anchor: anchor, visible: Self.screen(containing: anchor)?.visibleFrame)
    }

    /// Applies visibility for the current state and settings.
    func update() {
        let idleHidden = Settings.pillHiddenUntil.map { $0 > Date() } ?? false
        let shouldShow = PillVisibility.shouldShow(controller.pill, showWhileRecording: Settings.showRecordingPill,
                                                   showWhenIdle: Settings.showIdlePill, idleHidden: idleHidden,
                                                   forced: forcedVisible || ui.expanded)
        if shouldShow {
            if !panel.isVisible {
                resizeToFit()
                place()
                panel.orderFrontRegardless()
            }
        } else if panel.isVisible {
            panel.orderOut(nil)
            hovering = false
        }
        updateMeters()
    }

    /// Brings the pill to front (menu "Show floating control"); `expand` opens it briefly.
    func show(expand: Bool) {
        controller.unhidePill()
        forcedVisible = true
        update()
        if expand {
            self.expand()
            scheduleCollapse(after: 4)
        }
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

    /// Coalesces size reports of one SwiftUI update pass into one resize after it.
    private func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.resizeScheduled = false
                self?.resizeToFit()
            }
        }
    }

    private func resizeToFit() {
        let fitted = hosting.fittedSize
        guard fitted != size else { return }
        size = fitted
        place()
    }

    /// Frame from the bottom-center anchor, kept inside the screen's visible frame.
    private func place() {
        let frame = PillLayout.frame(size: size, anchor: anchor, visible: Self.screen(containing: anchor)?.visibleFrame)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
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

    // MARK: - Meters (only while visible)

    private func updateMeters() {
        controller.setMeterVisible("pill", panel.isVisible && panel.occlusionState.contains(.visible))
    }
}

// MARK: - Toast

/// Brief message above the pill (~1.5 s, one fade, no loops).
@MainActor
final class ToastPanel {
    private let panel = FloatingPanel()
    private let model = ToastModel()
    private var hosting: FittingHostingView<ToastView>!
    private var hideWork: DispatchWorkItem?
    private var anchorFrame: NSRect = .zero

    init() {
        panel.ignoresMouseEvents = true
        hosting = FittingHostingView(rootView: ToastView(model: model, sizeChanged: { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.place() } }
        }))
        panel.contentView = hosting
    }

    func show(_ text: String, above frame: NSRect) {
        anchorFrame = frame
        model.text = text
        place()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // The new text is laid out in the next update pass; re-fit after it.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.place() } }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private func place() {
        let size = hosting.fittedSize
        let anchor = CGPoint(x: anchorFrame.midX, y: anchorFrame.maxY + 8)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchorFrame.midX, y: anchorFrame.minY)) } ?? NSScreen.main
        let frame = PillLayout.frame(size: size, anchor: anchor, visible: screen?.visibleFrame)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
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

    private let panel = FloatingPanel(size: CGSize(width: 340, height: 120))
    private var placement = Placement.topRight
    private var fittedSize: () -> CGSize = { CGSize(width: 340, height: 120) }

    var isVisible: Bool { panel.isVisible }

    /// `make` builds the card with the size callback to wire into its `onFittingSizeChange`.
    func show<Content: View>(_ make: (@escaping (CGSize) -> Void) -> Content, placement: Placement) {
        self.placement = placement
        let content = make { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.place() } }
        }
        let hosting = FittingHostingView(rootView: content)
        fittedSize = { [weak hosting] in hosting?.fittedSize ?? CGSize(width: 340, height: 120) }
        panel.contentView = hosting
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
                self.fittedSize = { CGSize(width: 340, height: 120) }
            }
        }
    }

    private func place() {
        let size = fittedSize()
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame: CGRect
        switch placement {
        case .topRight:
            frame = CGRect(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16, width: size.width, height: size.height)
        case .above(let pill):
            frame = PillLayout.frame(size: size, anchor: CGPoint(x: pill.midX, y: pill.maxY + 10), visible: visible)
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }
}
