import Foundation
import MeetingNotesCore
import SwiftUI

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

/// Elapsed time, published once per second while recording.
@MainActor
public final class ClockModel: ObservableObject {
    @Published public var elapsed = "00:00"
    public init() {}
}

/// Me/Them meter values (0...1), published only while a meter is visible and recording.
@MainActor
public final class LevelModel: ObservableObject {
    @Published public var me: Double = 0
    @Published public var them: Double = 0
    public init() {}
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

/// Everything the views display. Written by the app controller (or by the preview renderer with
/// fake values); views never mutate it except through `titleDraft` and `AppCommands`.
@MainActor
public final class AppState: ObservableObject {
    @Published public var pill: PillState = .idle(attention: false)
    @Published public var machine = RecorderMachine()
    @Published public var titleDraft = ""
    @Published public var systemAudio: SystemAudioHealth = .ok
    @Published public var micAvailable = true
    @Published public var recordingWarnings: [String] = []
    @Published public var detectedAppName: String?
    @Published public var lastResult: ReadyInfo?
    @Published public var hotkey: HotKeySpec?
    @Published public var pauseHotkey: HotKeySpec?
    @Published public var hotkeyError: String?
    @Published public var notesDir: URL
    @Published public var createNotesMode: CreateNotesMode
    @Published public var microphone: PermissionStatus = .notDetermined
    @Published public var screenCapture: PermissionStatus = .denied
    @Published public var notifications: PermissionStatus = .unavailable
    @Published public var recents: [RecentMeeting] = []
    /// A notes job is running or queued.
    @Published public var jobsActive = false
    @Published public var audioTest = AudioTestState()
    @Published public var showGettingStarted = false
    @Published public var isBundled = AppInfo.isBundled

    public let clock = ClockModel()
    public let levels = LevelModel()

    public init(notesDir: URL = Settings.notesDir, createNotesMode: CreateNotesMode = Settings.createNotesMode) {
        self.notesDir = notesDir
        self.createNotesMode = createNotesMode
    }

    public var isCapturing: Bool { machine.phase != .idle }

    public var processing: ProcessingSnapshot? {
        if case .processing(let snapshot) = pill { return snapshot }
        return nil
    }

    public var canRelaunch: Bool {
        RelaunchPolicy.canRelaunch(phase: machine.phase, jobsActive: jobsActive, isBundled: isBundled)
    }

    /// Other participants are not (or cannot be) recorded: shows the orange banner.
    public var systemAudioMissing: Bool {
        screenCapture != .granted || (machine.phase.isActive && systemAudio == .notPermitted)
    }

    /// Warning shown beside the collapsed pill while recording.
    public var pillWarning: PillWarning? {
        guard machine.phase.isActive else { return nil }
        if !micAvailable { return PillWarning(short: tr(.micNotRecording), full: tr(.micNotRecording)) }
        switch systemAudio {
        case .notPermitted: return PillWarning(short: tr(.systemAudioMissingShort), full: tr(.systemAudioBanner))
        case .silent where machine.phase == .recording: return PillWarning(short: tr(.othersSilent), full: tr(.othersSilent))
        default: return nil
        }
    }

    public var micWarning: String? { micAvailable ? nil : tr(.micNotRecording) }

    public var systemWarning: String? {
        switch systemAudio {
        case .ok: return nil
        case .notPermitted: return tr(.systemAudioMissingShort)
        case .silent: return machine.phase == .paused ? nil : tr(.othersSilent)
        }
    }

    public var stopLabel: String { tr(createNotesMode == .manual ? .actionStopSave : .actionStopCreateNotes) }

    /// "⌃⌥⌘R start/stop · ⌃⌥⌘P pause/resume".
    public var hotkeyHint: String? {
        let parts = [hotkey.map { tr(.hotkeyStartStop, $0.display) }, pauseHotkey.map { tr(.hotkeyPause, $0.display) }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The title field has a meeting to rename.
    public var hasTitleTarget: Bool {
        switch pill {
        case .starting, .recording, .paused, .stopping, .processing, .ready: return true
        default: return false
        }
    }
}

/// Actions the views can trigger (implemented by the app controller, a no-op in previews).
@MainActor
public protocol AppCommands: AnyObject {
    func perform(_ command: RecorderCommand, source: ActionSource)
    func startRecording(source: ActionSource)
    func titleEditingBegan()
    func commitTitle()
    func processWaitingNow()
    func cancelProcessing()
    func performErrorAction()
    func dismissError()
    func openNotes(_ folder: URL)
    func reveal(_ url: URL)
    func openInDefaultApp(_ url: URL)
    func copySummary(folder: URL)
    func createNotes(folder: URL)
    func retry(folder: URL)
    func openLastNotes()
    func openNotesFolder()
    func hidePillForAnHour()
    func showSettings()
    func showMainWindow()
    func fixPermission(_ kind: PermissionKind)
    func openPermissionSettings(_ kind: PermissionKind)
    func runAudioTest()
    func dismissGettingStarted()
    func relaunch()
    func setLanguage(_ language: UILanguage)
    func setDetectionEnabled(_ enabled: Bool)
    func setCreateNotesMode(_ mode: CreateNotesMode)
    func setSummaryModel(_ model: SummaryModel)
    func chooseNotesFolder()
    func resetNotesFolder()
    func setShowInDock(_ show: Bool)
    func setPillVisibility(whileRecording: Bool, whenIdle: Bool)
    func resetPillPosition()
}

// MARK: - Language

/// Publishes the UI language so every window re-renders when it changes (no restart).
@MainActor
public final class LanguageModel: ObservableObject {
    public static let shared = LanguageModel()
    @Published public private(set) var current: UILanguage = L10n.language

    public func set(_ language: UILanguage) {
        L10n.language = language
        if current != language { current = language }
    }
}

/// Root wrapper of every hosted view: rebuilds the tree when the language changes.
public struct Localized<Content: View>: View {
    @ObservedObject private var language = LanguageModel.shared
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .id(language.current)
            .environment(\.locale, language.current.locale)
    }
}
