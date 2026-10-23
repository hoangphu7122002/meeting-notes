import AppKit
import MeetingNotesCore
import MeetingNotesLaunch
@testable import MeetingNotesUI
import SwiftUI
import Testing

@Suite("Settings view")
@MainActor
struct SettingsViewTests {
    /// The window's starting values equal the registered defaults: no stored key changed meaning.
    @Test func defaultValuesMatchRegisteredDefaults() {
        Settings.registerDefaults()
        var current = SettingsValues.current()
        current.login = .off
        current.launcher = .off  // the agent's registration depends on the machine, not on defaults
        #expect(current == SettingsValues())
        #expect(Settings.Key.openForMeetings == "openForMeetings" && Settings.Key.detection == MeetingLauncher.Key.detection)
        #expect(Settings.Key.detectionSnoozeUntil == MeetingLauncher.Key.detectionSnoozeUntil)
        // "Open the app when a meeting starts" is on by default (registered, not just the struct default).
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        #expect(registered[Settings.Key.openForMeetings] as? Bool == true)
        #expect(Settings.Key.showRecordingPill == "showRecordingPill" && Settings.Key.showIdlePill == "showIdlePill")
        #expect(Settings.Key.autoStopOnCallEnd == "autoStopOnCallEnd" && Settings.Key.notesDir == "notesDir")
    }

    @Test func rendersEveryStateInBothLanguages() {
        for lang in UILanguage.allCases {
            LanguageModel.shared.set(lang)
            for open in [false, true] {
                let state = AppState(notesDir: URL(fileURLWithPath: "/tmp/notes"), createNotesMode: .whenIdle)
                state.microphone = .denied
                let values = SettingsValues(login: .requiresApproval, detection: false, silenceMinutes: 20, pillMode: .never,
                                            openForMeetings: open, launcher: .requiresApproval)
                let view = SettingsView(state: state, commands: NoopCommands(), detectionSupported: true, values: values,
                                        memoryGB: 8, version: "test", advancedOpen: open, height: nil)
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(x: 0, y: 0, width: 540, height: 900)
                hosting.layoutSubtreeIfNeeded()
                #expect(hosting.fittingSize.width > 0)
            }
        }
        LanguageModel.shared.set(.vi)
    }
}

@MainActor
private final class NoopCommands: AppCommands {
    func perform(_ command: RecorderCommand, source: ActionSource) {}
    func startRecording(source: ActionSource) {}
    func titleEditingBegan() {}
    func commitTitle() {}
    func processWaitingNow() {}
    func cancelProcessing() {}
    func performErrorAction() {}
    func dismissError() {}
    func openNotes(_ folder: URL) {}
    func reveal(_ url: URL) {}
    func openInDefaultApp(_ url: URL) {}
    func copySummary(folder: URL) {}
    func createNotes(folder: URL) {}
    func retry(folder: URL) {}
    func openLastNotes() {}
    func openNotesFolder() {}
    func hidePillForAnHour() {}
    func showSettings() {}
    func showMainWindow() {}
    func fixPermission(_ kind: PermissionKind) {}
    func openPermissionSettings(_ kind: PermissionKind) {}
    func runAudioTest() {}
    func dismissGettingStarted() {}
    func relaunch() {}
    func setLanguage(_ language: UILanguage) {}
    func setDetectionEnabled(_ enabled: Bool) {}
    func setCreateNotesMode(_ mode: CreateNotesMode) {}
    func setSummaryModel(_ model: SummaryModel) {}
    func setLiveTranscription(_ enabled: Bool) {}
    func chooseNotesFolder() {}
    func resetNotesFolder() {}
    func setShowInDock(_ show: Bool) {}
    func setPillVisibility(whileRecording: Bool, whenIdle: Bool) {}
    func resetPillPosition() {}
}
