import Foundation
import Testing
@testable import MeetingNotesCore

@Suite("Live transcript")
struct LiveTranscriptTests {
    func segment(_ track: String, _ seq: Int, _ start: Double, _ text: String, job: String = "live-1") -> WorkerEvent {
        .liveSegment(job: job, LiveSegment(track: track, speaker: track == "mic" ? "Me" : "Others", seq: seq, start: start,
                                           end: start + 2, language: "vi", text: text))
    }

    @Test func ordersByStartAcrossTracks() {
        var transcript = LiveTranscript(job: "live-1")
        transcript.apply(segment("system", 0, 4, "b"))
        transcript.apply(segment("mic", 0, 1, "a"))
        transcript.apply(segment("mic", 1, 6, "c"))
        #expect(transcript.segments.map(\.text) == ["a", "b", "c"])
        #expect(transcript.segments.first?.isMe == true)
    }

    @Test func dedupesByTrackAndSeq() {
        var transcript = LiveTranscript(job: "live-1")
        check(transcript.apply(segment("mic", 3, 10, "first take")))
        // Worker restart re-emits the same chunk: identical = no change, different text = replaced.
        check(!transcript.apply(segment("mic", 3, 10, "first take")))
        check(transcript.apply(segment("mic", 3, 10, "second take")))
        // Same seq on the other track is a different chunk.
        transcript.apply(segment("system", 3, 11, "other track"))
        #expect(transcript.segments.map(\.text) == ["second take", "other track"])
    }

    @Test func lastLinesSkipsEmpty() {
        var transcript = LiveTranscript(job: "live-1")
        for i in 0..<5 { transcript.apply(segment("mic", i, Double(i), "line \(i)")) }
        transcript.apply(segment("system", 0, 10, "   "))
        #expect(transcript.lastLines(3).map(\.text) == ["line 2", "line 3", "line 4"])
        #expect(transcript.lastLines(10).count == 5)
        #expect(transcript.lastLines(0).isEmpty)
        #expect(LiveTranscript(job: "x").lastLines(3).isEmpty)
    }

    @Test func searchIgnoresCaseAndDiacritics() {
        var transcript = LiveTranscript(job: "live-1")
        transcript.apply(segment("mic", 0, 0, "Chốt ngày ra mắt là thứ Sáu"))
        transcript.apply(segment("system", 0, 2, "Đội kỹ thuật gửi bản kiểm thử"))
        transcript.apply(segment("system", 1, 4, "Budget review"))
        #expect(transcript.search("ra mat").map(\.seq) == [0])
        #expect(transcript.search("DOI KY").map(\.track) == ["system"])
        #expect(transcript.search("đội").count == 1)
        #expect(transcript.search("budget").count == 1)
        #expect(transcript.search("  ").isEmpty)
        #expect(transcript.search("nothing").isEmpty)
    }

    @Test func tracksStatus() {
        var transcript = LiveTranscript(job: "live-1")
        #expect(!transcript.isPaused)
        #expect(transcript.state == nil)
        transcript.apply(.liveStatus(job: "live-1", LiveStatus(state: "deferred", backlogSec: 24, reason: "memory")))
        #expect(transcript.isPaused)
        #expect(transcript.reason == "memory")
        #expect(transcript.backlogSec == 24)
        transcript.apply(.liveStatus(job: "live-1", LiveStatus(state: "throttled", reason: "battery")))
        #expect(transcript.isPaused)
        transcript.apply(.liveStatus(job: "live-1", LiveStatus(state: "running", backlogSec: 0)))
        #expect(!transcript.isPaused)
        #expect(transcript.state == "running")
    }

    @Test func ignoresOtherJobsAndEvents() {
        var transcript = LiveTranscript(job: "live-1")
        check(!transcript.apply(segment("mic", 0, 0, "other job", job: "live-2")))
        check(!transcript.apply(.liveStatus(job: "live-2", LiveStatus(state: "throttled"))))
        check(!transcript.apply(.jobEnd(job: "live-1", exit: 0)))
        check(!transcript.apply(.worker(status: "ready", message: nil, features: ["live"])))
        #expect(transcript == LiveTranscript(job: "live-1"))
    }

    @Test func decodesFromWorkerLines() {
        var transcript = LiveTranscript(job: "live-1")
        for line in [
            #"{"event":"live_segment","job":"live-1","track":"system","speaker":"Others","seq":0,"start":0.5,"end":3.0,"language":"en","text":"Hello"}"#,
            #"{"event":"live_segment","job":"live-1","track":"mic","speaker":"Me","seq":0,"start":0.2,"end":2.0,"language":"en","text":"Hi"}"#,
            #"{"event":"live_status","job":"live-1","state":"running","backlog_sec":1.5,"skipped_sec":0.0,"rtf":0.21,"reason":null}"#,
        ] { if let event = WorkerEvent(line: line) { transcript.apply(event) } }
        #expect(transcript.lastLines(3).map(\.speaker) == ["Me", "Others"])
        #expect(transcript.status?.rtf == 0.21)
    }
}
