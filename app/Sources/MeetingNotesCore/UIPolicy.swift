import Foundation

/// Geometry of the floating pill. The panel always takes the SwiftUI content's fitting size and keeps
/// its bottom-center point fixed, so it grows upward and symmetrically sideways.
public enum PillLayout {
    public static let collapsedHeight: CGFloat = 44
    public static let collapsedMinWidth: CGFloat = 280
    public static let collapsedMaxWidth: CGFloat = 380
    public static let expandedWidth: CGFloat = 360
    public static let badgeMaxWidth: CGFloat = 340
    public static let cornerRadius: CGFloat = 22
    public static let spacing: CGFloat = 6
    /// Distance kept from the screen's visible frame.
    public static let screenMargin: CGFloat = 4

    /// Whole-point panel size for a fitting size (never smaller than the content, never zero).
    public static func panelSize(fitting: CGSize) -> CGSize {
        CGSize(width: max(1, ceil(fitting.width)), height: max(1, ceil(fitting.height)))
    }

    /// Panel frame for content of `size` whose bottom-center sits at `anchor`, kept inside `visible`.
    public static func frame(size: CGSize, anchor: CGPoint, visible: CGRect?) -> CGRect {
        var origin = CGPoint(x: (anchor.x - size.width / 2).rounded(), y: anchor.y.rounded())
        if let visible {
            let minX = visible.minX + screenMargin
            let maxX = visible.maxX - size.width - screenMargin
            origin.x = maxX < minX ? minX : min(max(origin.x, minX), maxX)
            let minY = visible.minY + 2
            let maxY = visible.maxY - size.height - 2
            origin.y = maxY < minY ? minY : min(max(origin.y, minY), maxY)
        }
        return CGRect(origin: origin, size: size)
    }
}

/// When the floating pill is on screen.
public enum PillVisibility {
    /// - Parameters:
    ///   - showWhileRecording: setting "Show floating control while recording" (also covers saving,
    ///     writing notes, done and error, which follow a recording).
    ///   - showWhenIdle: setting "Show floating control when idle".
    ///   - idleHidden: "Hide for 1 hour" is active.
    ///   - forced: the user asked for it (menu "Show floating control") or it is expanded.
    public static func shouldShow(_ state: PillState, showWhileRecording: Bool, showWhenIdle: Bool, idleHidden: Bool,
                                  forced: Bool) -> Bool {
        if forced { return true }
        if state.isIdle { return showWhenIdle && !idleHidden }
        return showWhileRecording
    }
}

/// Relaunch (to apply a new Screen & System Audio Recording permission) is only safe when nothing
/// would be lost: no recording in any phase and no notes job running or queued.
public enum RelaunchPolicy {
    public static func canRelaunch(phase: RecorderPhase, jobsActive: Bool, isBundled: Bool) -> Bool {
        phase == .idle && !jobsActive && isBundled
    }
}
