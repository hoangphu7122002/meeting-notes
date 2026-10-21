import Foundation
import MeetingNotesCore
import SwiftUI

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

// MARK: - Language
