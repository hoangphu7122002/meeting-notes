import AppKit
import MeetingNotesCore
import SwiftUI

/// Borderless, non-activating floating panel on all Spaces (incl. full-screen ones).
/// It becomes key only when a text field inside needs it (`becomesKeyOnlyIfNeeded`), so clicking
/// buttons never takes keyboard focus from the frontmost app.
public final class FloatingPanel: NSPanel {
    public init(size: CGSize = CGSize(width: 280, height: 44)) {
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

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }
}

/// Hosting view of floating panels. Its frame is set by the owner from `fittedSize` (the SwiftUI
/// content's ideal size); the content reports changes through `onFittingSizeChange`.
/// Also: an always-active hover tracking area and first-click delivery.
public final class FittingHostingView<Content: View>: NSHostingView<Content> {
    public var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    public required init(rootView: Content) {
        super.init(rootView: rootView)
        // Lets `fittingSize` report the ideal size without letting the content resize the window itself.
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whole-point size the panel must have so nothing is clipped.
    public var fittedSize: CGSize {
        layoutSubtreeIfNeeded()
        return PillLayout.panelSize(fitting: fittingSize)
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override public func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override public func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override public var needsPanelToBecomeKey: Bool { false }
}

public extension View {
    /// Lays the view out at its ideal size and reports every size change (state, text, language).
    /// The owner then resizes its panel from the hosting view's `fittedSize`.
    func onFittingSizeChange(_ action: @escaping (CGSize) -> Void) -> some View {
        // 1 pt margin so antialiased outer edges of the rounded surfaces are not cut flat by the panel.
        padding(1)
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }, action: action)
    }
}

public extension NSWindow {
    /// Installs a SwiftUI hosting view built by `make` unless the window already hosts `Content`.
    /// A fresh `NSWindow` always has a plain `NSView` content view, so `contentView == nil` is not a
    /// usable "not built yet" check: it left the main window blank on first launch.
    /// Returns true when a new hosting view was installed.
    @discardableResult
    func hostContentIfNeeded<Content: View>(_ make: () -> NSHostingView<Content>) -> Bool {
        if contentView is NSHostingView<Content> { return false }
        contentView = make()
        return true
    }
}
