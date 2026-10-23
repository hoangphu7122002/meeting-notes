import Foundation
import Testing
@testable import MeetingNotesCore

@Suite("Status icon")
struct StatusIconTests {
    @Test func pillStateMapsToIcon() {
        let cases: [(PillState, StatusIcon)] = [
            (.idle(attention: false), .idle),
            (.idle(attention: true), .attention),
            (.starting, .busy),
            (.stopping, .busy),
            (.recording, .recording),
            (.paused, .paused),
            (.processing(ProcessingSnapshot(job: "j", folder: "/f", title: "t")), .processing),
            (.ready(ReadyInfo(folder: "/f", title: "t", notesPath: nil)), .ready),
            (.error(PillError("boom")), .error),
        ]
        for (pill, icon) in cases {
            #expect(StatusIcon(pill) == icon, "\(pill)")
        }
    }

    @Test func iconKinds() {
        #expect(StatusIcon.idle.kind == .glyph)
        #expect(StatusIcon.recording.kind == .tintedGlyph(.recording))
        #expect(StatusIcon.paused.kind == .tintedGlyph(.paused))
        #expect(StatusIcon.attention.kind == .symbol("exclamationmark.triangle"))
        #expect(StatusIcon.error.kind == .symbol("exclamationmark.triangle"))
        #expect(StatusIcon.busy.kind == .symbol("ellipsis.circle"))
        #expect(StatusIcon.processing.kind == .symbol("arrow.triangle.2.circlepath.circle"))
        #expect(StatusIcon.ready.kind == .symbol("checkmark.circle"))
    }

    @Test func onlyIdleRecordingPausedUseTheBrandGlyph() {
        let glyphs = StatusIcon.allCases.filter {
            if case .symbol = $0.kind { return false }
            return true
        }
        #expect(glyphs == [.idle, .recording, .paused])
    }
}
