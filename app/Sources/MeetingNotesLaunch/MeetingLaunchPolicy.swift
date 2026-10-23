// "Open the app when a meeting starts": what the background launcher reacts to and when it opens
// MeetingNotes (Launch). Pure so the rules are unit-tested; the launcher executable only feeds it events.

import Foundation

/// Names shared by the app (registration, launch flag) and the launcher agent.
public enum MeetingLauncher {
    /// Passed by the launcher when it opens the app: start quietly, run detection, offer to record.
    public static let openedForMeetingArgument = "--opened-for-meeting"
    /// launchd label; the agent plist is `Contents/Library/LaunchAgents/<label>.plist` (SMAppService.agent).
    public static let agentLabel = "com.hoangphu.meetingnotes.launcher"
    public static var agentPlistName: String { agentLabel + ".plist" }
    /// The agent executable, next to the app's in `Contents/MacOS`.
    public static let helperName = "MeetingNotesLauncher"

    /// UserDefaults keys (domain `com.hoangphu.meetingnotes`) the launcher reads; same keys as the app's `Settings`.
    public enum Key {
        public static let openForMeetings = "openForMeetings"
        public static let detection = "meetingDetection"
        public static let detectionSnoozeUntil = "detectionSnoozeUntil"
    }

    /// `.../MeetingNotes.app/Contents/MacOS/MeetingNotesLauncher` -> `.../MeetingNotes.app`; nil elsewhere.
    public static func appBundle(forHelperAt path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let macOS = url.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }
}

/// The app's preferences as the launcher sees them. Missing keys read as the app's registered defaults.
public struct LauncherPrefs: Equatable, Sendable {
    public var openForMeetings: Bool
    public var detection: Bool
    public var snoozedUntil: Date?

    public init(openForMeetings: Bool = true, detection: Bool = true, snoozedUntil: Date? = nil) {
        self.openForMeetings = openForMeetings
        self.detection = detection
        self.snoozedUntil = snoozedUntil
    }

    /// From raw preference values (`CFPreferencesCopyAppValue` in the launcher).
    public init(read: (String) -> Any?) {
        func bool(_ key: String) -> Bool { (read(key) as? NSNumber)?.boolValue ?? (read(key) as? Bool) ?? true }
        let snooze = (read(MeetingLauncher.Key.detectionSnoozeUntil) as? NSNumber)?.doubleValue ?? 0
        self.init(openForMeetings: bool(MeetingLauncher.Key.openForMeetings),
                  detection: bool(MeetingLauncher.Key.detection),
                  snoozedUntil: snooze > 0 ? Date(timeIntervalSince1970: snooze) : nil)
    }
}

/// What woke the launcher up.
public enum LaunchTrigger: Equatable, Sendable {
    /// An app finished launching (NSWorkspace).
    case appLaunched(bundleID: String)
    /// The default input device started running; the bundle IDs of processes capturing input now.
    case micStarted(captureBundleIDs: [String])
}

public enum LaunchDecision: Equatable, Sendable {
    case launch(app: String)
    case skip(SkipReason)

    public enum SkipReason: String, Sendable {
        case disabled, detectionOff, snoozed, appRunning, cooldown, recentlyQuit, notAMeeting
    }
}

/// Decides whether a trigger opens MeetingNotes. A meeting starting must bring up the record prompt right away,
/// so the only guards are: never while the app runs, never for its own microphone use, and no duplicate open
/// while a just-requested launch is still starting (`cooldown`, a few seconds). A quit after the last launch ends
/// that cooldown; `quitGrace` (default 0: off) can hold the launcher back after a quit. Time-based skips report
/// when they expire (`retryDate`) so the launcher re-checks a meeting whose microphone stays on (no new rising
/// edge would ever come).
public struct MeetingLaunchPolicy: Sendable {
    public var cooldown: TimeInterval
    public var quitGrace: TimeInterval
    public private(set) var lastLaunch: Date?
    public private(set) var lastAppExit: Date?

    public init(cooldown: TimeInterval = 15, quitGrace: TimeInterval = 0) {
        self.cooldown = cooldown
        self.quitGrace = quitGrace
    }

    /// MeetingNotes terminated (quit by the user, or crashed).
    public mutating func appExited(at now: Date) { lastAppExit = now }

    /// The meeting app a trigger points at, ignoring MeetingNotes's own processes.
    public static func meetingApp(for trigger: LaunchTrigger) -> String? {
        switch trigger {
        case .appLaunched(let bundleID):
            guard !MeetingApps.isOwn(bundleID: bundleID), MeetingApps.isLaunchTrigger(bundleID: bundleID) else { return nil }
            return MeetingApps.name(bundleID: bundleID)
        case .micStarted(let ids):
            return ids.lazy.filter { !MeetingApps.isOwn(bundleID: $0) }.compactMap { MeetingApps.name(bundleID: $0) }.first
        }
    }

    public func decide(_ trigger: LaunchTrigger, appRunning: Bool, prefs: LauncherPrefs, now: Date) -> LaunchDecision {
        guard prefs.openForMeetings else { return .skip(.disabled) }
        guard prefs.detection else { return .skip(.detectionOff) }
        if let until = prefs.snoozedUntil, until > now { return .skip(.snoozed) }
        guard let app = Self.meetingApp(for: trigger) else { return .skip(.notAMeeting) }
        if appRunning { return .skip(.appRunning) }
        if let lastLaunch, now.timeIntervalSince(lastLaunch) < cooldown, !quitSince(lastLaunch) { return .skip(.cooldown) }
        if let lastAppExit, now.timeIntervalSince(lastAppExit) < quitGrace { return .skip(.recentlyQuit) }
        return .launch(app: app)
    }

    /// At launcher start (login, agent restart mid-meeting): the microphone already in use by a meeting app counts
    /// as a `micStarted` trigger, since no rising edge will come. `captureBundleIDs` is read only when running.
    public static func startupTrigger(micRunning: Bool, captureBundleIDs: () -> [String]) -> LaunchTrigger? {
        guard micRunning else { return nil }
        let trigger = LaunchTrigger.micStarted(captureBundleIDs: captureBundleIDs())
        return meetingApp(for: trigger) == nil ? nil : trigger
    }

    /// When a time-based skip (`cooldown`, `recentlyQuit`) expires; nil for every other decision.
    public func retryDate(after decision: LaunchDecision) -> Date? {
        switch decision {
        case .skip(.cooldown): return lastLaunch?.addingTimeInterval(cooldown)
        case .skip(.recentlyQuit): return lastAppExit?.addingTimeInterval(quitGrace)
        default: return nil
        }
    }

    private func quitSince(_ launch: Date) -> Bool {
        guard let lastAppExit else { return false }
        return lastAppExit >= launch
    }

    /// `decide`, remembering a launch for the cooldown.
    public mutating func evaluate(_ trigger: LaunchTrigger, appRunning: Bool, prefs: LauncherPrefs, now: Date) -> LaunchDecision {
        let decision = decide(trigger, appRunning: appRunning, prefs: prefs, now: now)
        if case .launch = decision { lastLaunch = now }
        return decision
    }
}

/// Coalesces a burst of events into one check `delay` seconds after the first (CoreAudio and NSWorkspace fire
/// several notifications per change; a microphone blip shorter than `delay` is gone by the check).
public struct Debounce: Sendable {
    public let delay: TimeInterval
    public private(set) var deadline: Date?

    public init(delay: TimeInterval) { self.delay = delay }

    /// An event arrived. Returns the time to schedule a check at, or nil when one is already pending.
    public mutating func signal(at now: Date) -> Date? {
        guard deadline == nil else { return nil }
        let due = now.addingTimeInterval(delay)
        deadline = due
        return due
    }

    /// The scheduled check runs. True when it is due (it then clears, so the next event schedules again).
    public mutating func fire(at now: Date) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }
}

/// One pending re-check for a meeting skipped by a cooldown while its microphone stays on. A newer schedule
/// replaces the old one (single timer); the microphone stopping cancels it.
public struct CooldownRetry: Sendable {
    public private(set) var deadline: Date?

    public init() {}

    /// Schedule (or move) the re-check. Returns the deadline to arm a timer for, or nil when unchanged.
    public mutating func schedule(at due: Date) -> Date? {
        guard deadline != due else { return nil }
        deadline = due
        return due
    }

    public mutating func cancel() { deadline = nil }

    /// The armed timer fired. True when this is the current deadline (it then clears); a stale or cancelled
    /// timer returns false.
    public mutating func fire(at now: Date) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return true
    }
}
