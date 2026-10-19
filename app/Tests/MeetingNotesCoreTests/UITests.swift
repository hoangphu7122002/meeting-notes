import Foundation
import Testing
@testable import MeetingNotesCore

@Suite("Localization")
struct LocalizationTests {
    @Test func everyKeyHasVietnameseAndEnglish() {
        for key in Tr.allCases {
            let entry = key.entry
            #expect(!entry.vi.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) has no Vietnamese string")
            #expect(!entry.en.trimmingCharacters(in: .whitespaces).isEmpty, "\(key) has no English string")
        }
    }

    @Test func placeholdersMatchBetweenLanguages() {
        for key in Tr.allCases {
            let entry = key.entry
            #expect(L10n.placeholders(in: entry.vi) == L10n.placeholders(in: entry.en), "\(key) placeholders differ")
        }
    }

    @Test func vietnameseIsNormalizedUnicode() {
        for key in Tr.allCases {
            let vi = key.entry.vi
            #expect(vi == vi.precomposedStringWithCanonicalMapping, "\(key) is not NFC")
        }
    }

    @Test func argumentsAreSubstituted() {
        #expect(tr(.stateProcessingPercent, lang: .vi, 42) == "Đang tạo ghi chú 42%")
        #expect(tr(.durHoursMinutes, lang: .en, 1, 5) == "1 h 5 min")
        #expect(tr(.warnTrackWriteFailed, lang: .en, "Mic", "mic.wav", "disk full") == "Mic: writing mic.wav failed: disk full")
    }

    @Test func keyPhrases() {
        #expect(tr(.actionStartRecording, lang: .vi) == "Bắt đầu ghi")
        #expect(tr(.actionStopCreateNotes, lang: .vi) == "Dừng & tạo ghi chú")
        #expect(tr(.actionDiscard, lang: .vi) == "Huỷ bản ghi")
        #expect(tr(.me, lang: .vi) == "Tôi")
        #expect(tr(.them, lang: .vi) == "Người khác")
        #expect(UILanguage(rawValue: "vi") == .vi && UILanguage(rawValue: "en") == .en)
    }

    @Test func statusLabels() {
        #expect(RecentMeeting.Status.processing.label(percent: 37, .vi) == "Đang xử lý 37%")
        #expect(RecentMeeting.Status.failed(nil).label(.en) == "Failed")
        #expect(PermissionStatus.granted.label(.vi) == "Đã cho phép")
        #expect(StageProgress(name: "transcribe").title(.vi) == "Chép lời")
    }
}

@Suite("Pill layout")
struct PillLayoutTests {
    let visible = CGRect(x: 0, y: 25, width: 1728, height: 1092)

    @Test func panelSizeNeverClipsContent() {
        #expect(PillLayout.panelSize(fitting: CGSize(width: 280.2, height: 43.6)) == CGSize(width: 281, height: 44))
        #expect(PillLayout.panelSize(fitting: .zero) == CGSize(width: 1, height: 1))
    }

    @Test func bottomCenterStaysFixedWhenGrowing() {
        let anchor = CGPoint(x: 864, y: 35)
        let collapsed = PillLayout.frame(size: CGSize(width: 282, height: 46), anchor: anchor, visible: visible)
        let expanded = PillLayout.frame(size: CGSize(width: 362, height: 300), anchor: anchor, visible: visible)
        #expect(collapsed.midX == expanded.midX)
        #expect(collapsed.minY == expanded.minY)
        #expect(expanded.maxY > collapsed.maxY)
    }

    @Test func clampedInsideVisibleFrame() {
        let left = PillLayout.frame(size: CGSize(width: 362, height: 300), anchor: CGPoint(x: 10, y: 0), visible: visible)
        #expect(left.minX == visible.minX + PillLayout.screenMargin)
        #expect(left.minY >= visible.minY)
        let top = PillLayout.frame(size: CGSize(width: 362, height: 300), anchor: CGPoint(x: 900, y: 1100), visible: visible)
        #expect(top.maxY <= visible.maxY)
        let right = PillLayout.frame(size: CGSize(width: 362, height: 46), anchor: CGPoint(x: 1720, y: 40), visible: visible)
        #expect(right.maxX == visible.maxX - PillLayout.screenMargin)
    }
}

@Suite("Pill visibility and relaunch")
struct UIPolicyTests {
    @Test func visibility() {
        let processing = PillState.processing(ProcessingSnapshot(job: "j", folder: "/f", title: "t"))
        #expect(PillVisibility.shouldShow(.recording, showWhileRecording: true, showWhenIdle: false, idleHidden: false, forced: false))
        #expect(!PillVisibility.shouldShow(.recording, showWhileRecording: false, showWhenIdle: true, idleHidden: false, forced: false))
        #expect(PillVisibility.shouldShow(processing, showWhileRecording: true, showWhenIdle: false, idleHidden: false, forced: false))
        #expect(!PillVisibility.shouldShow(.idle(attention: false), showWhileRecording: true, showWhenIdle: false, idleHidden: false, forced: false))
        #expect(PillVisibility.shouldShow(.idle(attention: false), showWhileRecording: true, showWhenIdle: true, idleHidden: false, forced: false))
        #expect(!PillVisibility.shouldShow(.idle(attention: false), showWhileRecording: true, showWhenIdle: true, idleHidden: true, forced: false))
        #expect(PillVisibility.shouldShow(.idle(attention: false), showWhileRecording: false, showWhenIdle: false, idleHidden: true, forced: true))
    }

    @Test func relaunchOnlyWhenIdleAndNothingProcessing() {
        #expect(RelaunchPolicy.canRelaunch(phase: .idle, jobsActive: false, isBundled: true))
        for phase in [RecorderPhase.starting, .recording, .paused, .stopping] {
            #expect(!RelaunchPolicy.canRelaunch(phase: phase, jobsActive: false, isBundled: true), "relaunch while \(phase)")
        }
        #expect(!RelaunchPolicy.canRelaunch(phase: .idle, jobsActive: true, isBundled: true))
        #expect(!RelaunchPolicy.canRelaunch(phase: .idle, jobsActive: false, isBundled: false))
    }
}

@Suite("Recent meetings")
struct RecentsTests {
    @Test func readsTitleDurationAndStatus() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-recents-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let done = dir.appendingPathComponent("a")
        let failed = dir.appendingPathComponent("b")
        for folder in [done, failed] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data(#"{"title": "Họp giao ban", "duration_sec": 125.5}"#.utf8).write(to: done.appendingPathComponent("meeting.json"))
        try Data("# notes".utf8).write(to: done.appendingPathComponent("notes.md"))
        try Data(#"{"state": "done"}"#.utf8).write(to: done.appendingPathComponent("status.json"))
        try Data(#"{"title": "B"}"#.utf8).write(to: failed.appendingPathComponent("meeting.json"))
        try Data(#"{"state": "failed", "error": "boom"}"#.utf8).write(to: failed.appendingPathComponent("status.json"))
        let list = Recents.load(dir: dir, context: Recents.Context())
        let a = try #require(list.first { $0.title == "Họp giao ban" })
        #expect(a.status == .done && a.hasNotes && a.durationSec == 125.5)
        let b = try #require(list.first { $0.title == "B" })
        #expect(b.status == .failed("boom") && !b.hasNotes)
    }
}
