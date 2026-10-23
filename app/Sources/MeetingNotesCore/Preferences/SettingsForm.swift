// Settings window rules: grouping, which rows are enabled or shown, and the help line under each (Preferences).
// Pure so the window's states are unit-tested; the SwiftUI view only renders what this decides.

import Foundation

/// Floating control visibility: one picker over the two stored flags `showRecordingPill` + `showIdlePill`.
public enum PillMode: String, CaseIterable, Sendable {
    case whileRecording, always, never

    /// Stored flags -> mode. The legacy "idle only" combination (no picker ever offered it) reads as `always`.
    public init(whileRecording: Bool, whenIdle: Bool) {
        switch (whileRecording, whenIdle) {
        case (true, false): self = .whileRecording
        case (false, false): self = .never
        default: self = .always
        }
    }

    /// `showRecordingPill`.
    public var whileRecording: Bool { self != .never }
    /// `showIdlePill`.
    public var whenIdle: Bool { self == .always }

    public func title(_ lang: UILanguage = L10n.language) -> String {
        switch self {
        case .whileRecording: return tr(.pillWhileRecording, lang: lang)
        case .always: return tr(.pillAlways, lang: lang)
        case .never: return tr(.pillNever, lang: lang)
        }
    }
}

/// Launch-at-login state (`SMAppService.mainApp.status`, mapped by the UI layer).
public enum LoginItemState: Sendable, Equatable {
    case enabled, requiresApproval, off, unavailable, unknown

    /// What the toggle shows: registered, even if macOS still waits for approval.
    public var isOn: Bool { self == .enabled || self == .requiresApproval }

    /// A note under the toggle only when it needs the user (the toggle already shows on/off).
    public var note: Tr? {
        switch self {
        case .requiresApproval: return .loginNeedsApproval
        case .unavailable: return .loginUnavailable
        default: return nil
        }
    }

    public var canToggle: Bool { self != .unavailable }
}

/// The groups of the Settings window, in order. `advanced` is collapsed by default.
public enum SettingsGroup: CaseIterable, Sendable {
    case basics, duringMeeting, afterMeeting, advanced

    public var title: Tr {
        switch self {
        case .basics: return .groupBasics
        case .duringMeeting: return .groupDuringMeeting
        case .afterMeeting: return .groupAfterMeeting
        case .advanced: return .groupAdvanced
        }
    }
}

/// Machine facts the rules depend on (faked by previews and tests).
public struct SettingsEnvironment: Equatable, Sendable {
    public var detectionSupported: Bool
    public var physicalMemoryGB: Double
    public var microphone: PermissionStatus
    public var screenCapture: PermissionStatus

    public init(detectionSupported: Bool, physicalMemoryGB: Double, microphone: PermissionStatus, screenCapture: PermissionStatus) {
        self.detectionSupported = detectionSupported
        self.physicalMemoryGB = physicalMemoryGB
        self.microphone = microphone
        self.screenCapture = screenCapture
    }
}

/// What each control decides, given the current values. Stored keys and values are unchanged; only the
/// presentation (labels, grouping, enabled state, help lines) lives here.
public enum SettingsRules {
    /// Silence auto-stop choices in minutes (0 = off). A value set outside the picker (e.g. via `defaults`) is kept.
    public static func silenceChoices(current: Int) -> [Int] {
        let base = [0, 5, 10, 15, 30, 60]
        return base.contains(current) || current < 0 ? base : (base + [current]).sorted()
    }

    public static func silenceTitle(_ minutes: Int, lang: UILanguage = L10n.language) -> String {
        minutes == 0 ? tr(.silenceNever, lang: lang) : tr(.durMinutes, lang: lang, minutes)
    }

    public static func detectionHelp(_ env: SettingsEnvironment) -> Tr {
        env.detectionSupported ? .helpDetection : .detectionRequires
    }

    /// Stop-on-call-end listens to the meeting detector: it only works while detection runs.
    public static func stopOnCallEndEnabled(detection: Bool, _ env: SettingsEnvironment) -> Bool {
        env.detectionSupported && detection
    }

    public static func stopOnCallEndHelp(detection: Bool, _ env: SettingsEnvironment) -> Tr {
        if !env.detectionSupported { return .detectionRequires }
        return detection ? .helpCountdown : .helpStopOnCallEndNeedsDetection
    }

    public static func silenceHelp(minutes: Int) -> Tr { minutes == 0 ? .helpSilenceOff : .helpSilence }

    public static func createNotesHelp(_ mode: CreateNotesMode) -> Tr {
        switch mode {
        case .rightAway: return .helpRightAway
        case .whenIdle: return .helpWhenIdle
        case .manual: return .helpManual
        }
    }

    /// RAM below which the bigger summary model gets a warning.
    public static let betterModelMinMemoryGB: Double = 16

    public static func summaryHelp(_ model: SummaryModel, _ env: SettingsEnvironment) -> Tr {
        model == .better && env.physicalMemoryGB < betterModelMinMemoryGB ? .helpSummaryLowMemory : .helpSummary
    }

    /// Permissions the recorder needs that are not granted yet (notifications are optional).
    public static func missingPermissions(_ env: SettingsEnvironment) -> [PermissionKind] {
        var missing: [PermissionKind] = []
        if env.microphone == .denied || env.microphone == .notDetermined { missing.append(.microphone) }
        if env.screenCapture == .denied || env.screenCapture == .notDetermined { missing.append(.screenCapture) }
        return missing
    }

    public static func polishEnabled(live: Bool) -> Bool { live }

    /// "Reset position" shows the pill; pointless (and surprising) when the user hid it for good.
    public static func resetPillPositionEnabled(_ mode: PillMode) -> Bool { mode != .never }

    public static func pillHelp(_ mode: PillMode) -> Tr {
        mode == .never ? .helpPillNever : .helpPill
    }

    /// The first-run setup of the packaged app is unfinished: Settings links to its card in the main window.
    public static func showsSetupLink(_ setup: SetupMachine?) -> Bool {
        guard let setup else { return false }
        return !setup.isAllDone
    }
}
