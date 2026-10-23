import Foundation
import Testing
@testable import MeetingNotesCore

@Suite("Settings window rules")
struct SettingsFormTests {
    private func env(detection: Bool = true, memory: Double = 16, mic: PermissionStatus = .granted,
                     screen: PermissionStatus = .granted) -> SettingsEnvironment {
        SettingsEnvironment(detectionSupported: detection, physicalMemoryGB: memory, microphone: mic, screenCapture: screen)
    }

    @Test func pillModeMapsTheTwoStoredFlags() {
        #expect(PillMode(whileRecording: true, whenIdle: false) == .whileRecording)  // the registered defaults
        #expect(PillMode(whileRecording: true, whenIdle: true) == .always)
        #expect(PillMode(whileRecording: false, whenIdle: false) == .never)
        #expect(PillMode(whileRecording: false, whenIdle: true) == .always)  // legacy combination, shown not lost
        for mode in PillMode.allCases {
            #expect(PillMode(whileRecording: mode.whileRecording, whenIdle: mode.whenIdle) == mode)
        }
    }

    @Test func resetPositionIsDisabledWhenThePillIsNeverShown() {
        #expect(!SettingsRules.resetPillPositionEnabled(.never))
        #expect(SettingsRules.resetPillPositionEnabled(.whileRecording))
        #expect(SettingsRules.pillHelp(.never) == .helpPillNever)
    }

    @Test func stopOnCallEndDependsOnDetection() {
        #expect(SettingsRules.stopOnCallEndEnabled(detection: true, env()))
        #expect(!SettingsRules.stopOnCallEndEnabled(detection: false, env()))
        #expect(!SettingsRules.stopOnCallEndEnabled(detection: true, env(detection: false)))
        #expect(SettingsRules.stopOnCallEndHelp(detection: false, env()) == .helpStopOnCallEndNeedsDetection)
        #expect(SettingsRules.stopOnCallEndHelp(detection: true, env()) == .helpCountdown)
        #expect(SettingsRules.stopOnCallEndHelp(detection: true, env(detection: false)) == .detectionRequires)
        #expect(SettingsRules.detectionHelp(env(detection: false)) == .detectionRequires)
    }

    @Test func autoStopWordingSaysItStops() {
        // Both auto-stops really stop after a countdown: no "offer" wording.
        #expect(tr(.stopOnCallEnd, lang: .vi) == "Tự dừng khi cuộc gọi kết thúc")
        #expect(tr(.helpCountdown, lang: .vi).contains("60 giây"))
        #expect(tr(.helpCountdown, lang: .vi).contains(tr(.actionKeepRecording, lang: .vi)))
        #expect(tr(.helpCountdown, lang: .en).contains(tr(.actionKeepRecording, lang: .en)))
    }

    @Test func silenceChoicesKeepACustomValue() {
        #expect(SettingsRules.silenceChoices(current: 15) == [0, 5, 10, 15, 30, 60])
        #expect(SettingsRules.silenceChoices(current: 20) == [0, 5, 10, 15, 20, 30, 60])
        #expect(SettingsRules.silenceTitle(0, lang: .vi) == "Không tự dừng")
        #expect(SettingsRules.silenceTitle(15, lang: .en) == "15 min")
        #expect(SettingsRules.silenceHelp(minutes: 0) == .helpSilenceOff)
    }

    @Test func createNotesHelpExplainsEachMode() {
        #expect(SettingsRules.createNotesHelp(.whenIdle) == .helpWhenIdle)
        // The idle mode names its two conditions and the manual way out.
        let help = tr(.helpWhenIdle, lang: .vi)
        #expect(help.contains("cắm sạc") && help.contains("3 phút") && help.contains(tr(.actionCreateNotesNow, lang: .vi)))
        #expect(Int(CreateNotesMode.idleSeconds) == 180)
        #expect(!tr(.modeRightAway, lang: .vi).contains("ưu tiên"))
    }

    @Test func betterSummaryModelWarnsOnSmallMacs() {
        #expect(SettingsRules.summaryHelp(.better, env(memory: 8)) == .helpSummaryLowMemory)
        #expect(SettingsRules.summaryHelp(.better, env(memory: 16)) == .helpSummary)
        #expect(SettingsRules.summaryHelp(.light, env(memory: 8)) == .helpSummary)
        #expect(tr(.helpSummaryLowMemory, lang: .en, 8).contains("8 GB"))
    }

    @Test func permissionsRowOnlyWhenSomethingIsMissing() {
        #expect(SettingsRules.missingPermissions(env()).isEmpty)
        #expect(SettingsRules.missingPermissions(env(mic: .denied, screen: .notDetermined)) == [.microphone, .screenCapture])
        #expect(SettingsRules.missingPermissions(env(screen: .unavailable)).isEmpty)
    }

    @Test func loginItemNoteOnlyWhenItNeedsTheUser() {
        #expect(LoginItemState.enabled.note == nil)
        #expect(LoginItemState.off.note == nil)
        #expect(LoginItemState.requiresApproval.note == .loginNeedsApproval)
        #expect(LoginItemState.requiresApproval.isOn)
        #expect(!LoginItemState.unavailable.canToggle)
    }

    @Test func polishNeedsLiveTranscript() {
        #expect(!SettingsRules.polishEnabled(live: false))
        #expect(SettingsRules.polishEnabled(live: true))
    }

    @Test func setupLinkOnlyWhileSetupIsUnfinished() {
        #expect(!SettingsRules.showsSetupLink(nil))
        #expect(SettingsRules.showsSetupLink(SetupMachine(done: [.runtime])))
        #expect(!SettingsRules.showsSetupLink(SetupMachine(done: Set(SetupStep.allCases))))
    }

    @Test func groupsAndLabels() {
        #expect(SettingsGroup.allCases.map { tr($0.title, lang: .vi) } == ["Cơ bản", "Khi họp", "Sau khi họp", "Nâng cao"])
        #expect(SettingsGroup.allCases.map { tr($0.title, lang: .en) } == ["Basics", "During meetings", "After meetings", "Advanced"])
        #expect(CreateNotesMode.allCases.map { $0.title(.vi) } == ["Ngay sau buổi họp", "Khi máy rảnh và cắm sạc", "Khi tôi bấm"])
        #expect(SummaryModel.allCases.map { $0.title(.vi) } == ["Nhanh (máy 8 GB)", "Kỹ hơn (cần 16 GB)"])
        #expect(PillMode.allCases.map { $0.title(.vi) } == ["Khi đang ghi", "Luôn hiện", "Không hiện"])
        // The hotkey `defaults write` hint is gone from the UI (README troubleshooting keeps it).
        #expect(!Tr.allCases.contains { $0.entry.vi.contains("defaults write") })
    }
}
