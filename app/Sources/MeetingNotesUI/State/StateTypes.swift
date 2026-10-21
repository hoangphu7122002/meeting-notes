// Plain value types carried by AppState (State).

import Foundation

/// Where a user action came from. The pill and the main window show the state themselves;
/// every other source gets a toast.
public enum ActionSource: Sendable {
    case pill, window, menu, hotkey, url, dock, detection, autoStop

    public var showsToast: Bool { self != .pill && self != .window }
}

public enum SystemAudioHealth: Equatable, Sendable {
    case ok, notPermitted, silent
}

public struct AutoStopPrompt: Equatable, Sendable {
    public var reason: String
    public var remaining: Int
    /// Triggered by the meeting app releasing the microphone (vs. silence).
    public var appEnded: Bool

    public init(reason: String, remaining: Int, appEnded: Bool) {
        self.reason = reason
        self.remaining = remaining
        self.appEnded = appEnded
    }
}

/// The 5 s microphone + system audio check of the main window.
public struct AudioTestState: Equatable, Sendable {
    public var running = false
    public var me: Double = 0
    public var them: Double = 0
    public var result: [String] = []

    public init(running: Bool = false, me: Double = 0, them: Double = 0, result: [String] = []) {
        self.running = running
        self.me = me
        self.them = them
        self.result = result
    }
}

/// A warning shown next to the pill: a short line plus the full text as tooltip.
public struct PillWarning: Equatable, Sendable {
    public var short: String
    public var full: String
}
