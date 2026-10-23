import Foundation
import Testing
@testable import MeetingNotesCore

@Suite("Diarize helper discovery")
struct DiarizeHelperTests {
    let executable = URL(fileURLWithPath: "/Users/me/Applications/MeetingNotes.app/Contents/MacOS/MeetingNotes")
    let bundled = "/Users/me/Applications/MeetingNotes.app/Contents/MacOS/MeetingNotesDiarize"

    @Test func findsTheHelperNextToTheAppExecutable() {
        #expect(DiarizeHelper.bundledPath(executableURL: executable, isExecutable: { $0 == bundled }) == bundled)
        #expect(DiarizeHelper.bundledPath(executableURL: executable, isExecutable: { _ in false }) == nil)
        #expect(DiarizeHelper.bundledPath(executableURL: nil, isExecutable: { _ in true }) == nil)
    }

    @Test func workerEnvironmentAddsTheBundledPath() {
        let env = DiarizeHelper.workerEnvironment(["PATH": "/usr/bin"], executableURL: executable) { $0 == bundled }
        #expect(env == ["PATH": "/usr/bin", "MEETING_NOTES_DIARIZE_CLI": bundled])
    }

    @Test func workerEnvironmentKeepsAUserValueAndSkipsAMissingHelper() {
        let user = ["MEETING_NOTES_DIARIZE_CLI": "/opt/custom/MeetingNotesDiarize"]
        #expect(DiarizeHelper.workerEnvironment(user, executableURL: executable) { _ in true } == user)
        #expect(DiarizeHelper.workerEnvironment(["A": "1"], executableURL: executable) { _ in false } == ["A": "1"])
        let empty = DiarizeHelper.workerEnvironment(["MEETING_NOTES_DIARIZE_CLI": ""], executableURL: executable) { _ in true }
        #expect(empty["MEETING_NOTES_DIARIZE_CLI"] == bundled)
    }
}
