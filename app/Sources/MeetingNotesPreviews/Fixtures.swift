// Preview fixtures: no-op commands, scenarios and the fake AppState for each state (Previews).

import AppKit
import MeetingNotesCore
import MeetingNotesUI
import SwiftUI

/// Commands of the previews: nothing happens.
@MainActor
final class NoCommands: AppCommands {
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
    func chooseNotesFolder() {}
    func resetNotesFolder() {}
    func setShowInDock(_ show: Bool) {}
    func setPillVisibility(whileRecording: Bool, whenIdle: Bool) {}
    func resetPillPosition() {}
}

enum Scenario: String, CaseIterable {
    case idle, firstLaunch = "first-launch", recording, recordingWarning = "recording-warning", paused
    case discardConfirm = "discard-confirm", processing, ready, error
}

enum Appearance: String, CaseIterable {
    case light, dark

    var appearance: NSAppearance { NSAppearance(named: self == .dark ? .darkAqua : .aqua)! }
}

@MainActor
enum Fixtures {
    static let notesDir = URL(fileURLWithPath: "/Users/demo/MeetingNotes", isDirectory: true)

    static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text) ?? Date()
    }

    static func longTitle(_ lang: UILanguage) -> String {
        lang == .vi ? "Họp giao ban tuần – kế hoạch ra mắt sản phẩm quý 4 với đội thiết kế và kỹ thuật"
            : "Weekly sync – Q4 product launch plan with the design and engineering teams"
    }

    static func recents(_ lang: UILanguage, processing: Bool) -> [RecentMeeting] {
        let vi = lang == .vi
        func meeting(_ name: String, _ title: String, _ date: String, _ status: RecentMeeting.Status, _ duration: Double?, notes: Bool) -> RecentMeeting {
            RecentMeeting(url: notesDir.appendingPathComponent(name, isDirectory: true), title: title, date: Self.date(date),
                          status: status, durationSec: duration, hasNotes: notes)
        }
        var list = [
            meeting("2026-10-19 0930 Weekly", vi ? "Họp giao ban tuần – kế hoạch quý 4" : "Weekly sync – Q4 planning", "2026-10-19 09:30",
                    processing ? .processing : .done, 2537, notes: !processing),
            meeting("2026-10-18 1400 Design", vi ? "Duyệt thiết kế màn hình thanh toán" : "Checkout screen design review", "2026-10-18 14:00",
                    .done, 1820, notes: true),
            meeting("2026-10-17 1100 Client", vi ? "Gọi với khách hàng Minh Phát" : "Call with Minh Phat (client)", "2026-10-17 11:00",
                    .failed("Ollama is not reachable"), 3105, notes: false),
            meeting("2026-10-16 1630 1on1", vi ? "1:1 với Lan" : "1:1 with Lan", "2026-10-16 16:30", .notProcessed, 905, notes: false),
            meeting("2026-10-15 1000 Retro", vi ? "Retro sprint 42" : "Sprint 42 retro", "2026-10-15 10:00", .done, 2710, notes: true),
        ]
        if !processing { list.removeFirst() }
        return list
    }

    static func processingSnapshot(_ lang: UILanguage) -> ProcessingSnapshot {
        var snapshot = ProcessingSnapshot(job: "j", folder: notesDir.appendingPathComponent("x").path, title: longTitle(lang))
        for line in [
            #"{"event":"stage","stage":"prepare","status":"done","overall":0.03,"elapsed_sec":1.4,"job":"j"}"#,
            #"{"event":"stage","stage":"diarize","status":"done","overall":0.28,"elapsed_sec":42,"job":"j"}"#,
            #"{"event":"progress","stage":"transcribe","fraction":0.4,"overall":0.42,"eta_sec":130,"message":"Transcribing block 4/10","job":"j"}"#,
            #"{"event":"partial","folder":"/Users/demo/MeetingNotes/x","notes":"/Users/demo/MeetingNotes/x/notes.md","job":"j"}"#,
        ] { if let event = WorkerEvent(line: line) { snapshot.apply(event) } }
        snapshot.queued = 1
        return snapshot
    }

    static func state(_ scenario: Scenario, _ lang: UILanguage) -> AppState {
        let state = AppState(notesDir: notesDir, createNotesMode: .rightAway)
        state.isBundled = true
        state.hotkey = HotKeySpec.parse(HotKeySpec.defaultRecord)
        state.pauseHotkey = HotKeySpec.parse(HotKeySpec.defaultPause)
        state.microphone = .granted
        state.screenCapture = .granted
        state.notifications = .notDetermined
        state.recents = recents(lang, processing: false)
        state.lastResult = ReadyInfo(folder: notesDir.appendingPathComponent("a").path, title: "x", notesPath: "x")
        state.clock.elapsed = "42:17"
        state.levels.me = 0.72
        state.levels.them = 0.48
        switch scenario {
        case .idle:
            state.pill = .idle(attention: false)
        case .firstLaunch:
            state.showGettingStarted = true
            state.screenCapture = .denied
            state.microphone = .notDetermined
            state.recents = []
            state.lastResult = nil
            state.pill = .idle(attention: true)
        case .recording, .recordingWarning, .discardConfirm:
            state.machine = RecorderMachine(phase: .recording)
            state.pill = .recording
            state.titleDraft = longTitle(lang)
            state.recents = [RecentMeeting(url: notesDir.appendingPathComponent("now"), title: longTitle(lang), date: date("2026-10-19 09:30"),
                                           status: .recording)] + recents(lang, processing: false)
            if scenario == .recordingWarning {
                state.systemAudio = .notPermitted
                state.screenCapture = .denied
                state.levels.them = 0
                state.recordingWarnings = [tr(.warnSystemNotRecorded, lang == .vi
                    ? "Người dùng đã từ chối quyền ghi màn hình và âm thanh hệ thống cho ứng dụng"
                    : "The user declined TCCs for application, window, display capture")]
            }
            if scenario == .discardConfirm {
                var machine = RecorderMachine(phase: .recording)
                _ = machine.handle(.requestDiscard)
                state.machine = machine
            }
        case .paused:
            state.machine = RecorderMachine(phase: .paused)
            state.pill = .paused
            state.titleDraft = longTitle(lang)
            state.levels.me = 0
            state.levels.them = 0
        case .processing:
            state.pill = .processing(processingSnapshot(lang))
            state.titleDraft = longTitle(lang)
            state.jobsActive = true
            state.recents = recents(lang, processing: true)
        case .ready:
            let info = ReadyInfo(folder: notesDir.appendingPathComponent("r").path, title: longTitle(lang), notesPath: "notes.md")
            state.pill = .ready(info)
            state.titleDraft = info.title
            state.recents = recents(lang, processing: true).map {
                $0.status == .processing
                    ? RecentMeeting(url: $0.url, title: $0.title, date: $0.date, status: .done, durationSec: $0.durationSec, hasNotes: true) : $0
            }
        case .error:
            let message = tr(.errProcessingFailed, lang == .vi
                ? "Không kết nối được Ollama tại http://127.0.0.1:11434 (Connection refused). Hãy mở Ollama rồi thử lại."
                : "Ollama is not reachable at http://127.0.0.1:11434 (connection refused). Start Ollama and retry.")
            state.pill = .error(PillError(message, action: .retry(folder: notesDir.appendingPathComponent("e").path)))
        }
        return state
    }
}
