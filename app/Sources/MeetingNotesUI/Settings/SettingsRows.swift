// Settings window building blocks: the values it starts from and a label with a one-line help (Settings).

import Foundation
import MeetingNotesCore
import SwiftUI

/// The stored preferences the Settings window starts from. The app reads them from `Settings` (UserDefaults);
/// previews and tests pass fakes. Keys and value semantics are those of `Settings`.
public struct SettingsValues: Equatable, Sendable {
    public var login: LoginItemState
    public var detection: Bool
    public var silenceMinutes: Int
    public var stopOnCallEnd: Bool
    public var createNotesMode: CreateNotesMode
    public var summaryModel: SummaryModel
    public var liveTranscription: Bool
    public var livePolish: Bool
    public var showInDock: Bool
    public var pillMode: PillMode
    /// "Open the app when a meeting starts" (stored) and its launcher agent's registration.
    public var openForMeetings: Bool
    public var launcher: LoginItemState

    public init(login: LoginItemState = .off, detection: Bool = true, silenceMinutes: Int = 15, stopOnCallEnd: Bool = true,
                createNotesMode: CreateNotesMode = .rightAway, summaryModel: SummaryModel = .light,
                liveTranscription: Bool = false, livePolish: Bool = false, showInDock: Bool = true,
                pillMode: PillMode = .whileRecording, openForMeetings: Bool = true, launcher: LoginItemState = .off) {
        self.login = login
        self.detection = detection
        self.silenceMinutes = silenceMinutes
        self.stopOnCallEnd = stopOnCallEnd
        self.createNotesMode = createNotesMode
        self.summaryModel = summaryModel
        self.liveTranscription = liveTranscription
        self.livePolish = livePolish
        self.showInDock = showInDock
        self.pillMode = pillMode
        self.openForMeetings = openForMeetings
        self.launcher = launcher
    }

    /// What the app has stored now.
    @MainActor
    public static func current() -> SettingsValues {
        SettingsValues(login: LoginItem.state, detection: Settings.detectionEnabled,
                       silenceMinutes: Settings.autoStopSilenceMinutes, stopOnCallEnd: Settings.autoStopOnCallEnd,
                       createNotesMode: Settings.createNotesMode, summaryModel: Settings.summaryModel,
                       liveTranscription: Settings.liveTranscription, livePolish: Settings.livePolish,
                       showInDock: Settings.showInDock,
                       pillMode: PillMode(whileRecording: Settings.showRecordingPill, whenIdle: Settings.showIdlePill),
                       openForMeetings: Settings.openForMeetings, launcher: MeetingLauncherItem.state)
    }

    public static var physicalMemoryGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }
}

/// A setting's title with its short help line underneath (used as the label of toggles, pickers and rows).
struct SettingLabel: View {
    let title: String
    let help: String?
    var warning = false

    init(_ title: String, help: String?, warning: Bool = false) {
        self.title = title
        self.help = help
        self.warning = warning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(warning ? Palette.warning : Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
