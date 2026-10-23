import Foundation
import MeetingNotesCaptionKit
import Testing

/// The streaming window policy with a fake decoder (no WhisperKit).
@Suite struct CaptionStreamTests {
    private func voicedTrack(start: Double = 10) -> CaptionTrack {
        var track = CaptionTrack(name: "mic")
        _ = track.append(start: start, samples: Signal.noise(seconds: 2))
        _ = track.append(start: start + 2, samples: Signal.tone(seconds: 2))
        return track
    }

    @Test func decodesOnlyNewVoicedAudio() {
        var track = CaptionTrack(name: "mic")
        _ = track.append(start: 0, samples: Signal.noise(seconds: 2))
        #expect(!track.needsDecode)
        _ = track.append(start: 2, samples: Signal.tone(seconds: 1))
        #expect(track.needsDecode)
        let (audio, start) = track.beginDecode()
        _ = track.apply([CaptionPiece(start: 2, end: 3, text: "xin chào")], start: start, count: audio.count, language: "vi")
        #expect(!track.needsDecode)
    }

    @Test func confirmsAllButTheLastPiece() {
        var track = voicedTrack()
        let (audio, start) = track.beginDecode()
        let events = track.apply([CaptionPiece(start: 2, end: 3, text: "một hai"), CaptionPiece(start: 3, end: 4, text: "ba bốn")],
                                 start: start, count: audio.count, language: "vi")
        #expect(events.count == 2)
        #expect(events[0] == CaptionSegment(track: "mic", seq: 0, start: 12, end: 13, text: "Một hai", isFinal: true, language: "vi"))
        #expect(events[1].isFinal == false && events[1].seq == 1 && events[1].text == "Ba bốn")
        #expect(abs(events[1].start - 13) < 0.01)
        #expect(track.windowStart >= 12.9 && track.windowStart <= 13)  // confirmed audio left the window
        #expect(track.hypothesis?.text == "Ba bốn")
    }

    @Test func silenceConfirmsTheHypothesisWithoutDecoding() {
        var track = voicedTrack()
        let (audio, start) = track.beginDecode()
        _ = track.apply([CaptionPiece(start: 2, end: 4, text: "hello team")], start: start, count: audio.count, language: "en")
        #expect(track.idle().isEmpty)  // no trailing silence yet
        _ = track.append(start: 14, samples: Signal.noise(seconds: 0.8))
        let events = track.idle()
        #expect(events == [CaptionSegment(track: "mic", seq: 0, start: 12, end: 14, text: "Hello team", isFinal: true, language: "en")])
        #expect(track.hypothesis == nil && track.nextSeq == 1 && track.language == nil)
        #expect(track.windowSec <= 0.31)
    }

    @Test func emptyDecodeClearsTheHypothesis() {
        var track = voicedTrack()
        var (audio, start) = track.beginDecode()
        _ = track.apply([CaptionPiece(start: 2, end: 4, text: "hmm")], start: start, count: audio.count, language: "vi")
        _ = track.append(start: 14, samples: Signal.tone(seconds: 1))
        (audio, start) = track.beginDecode()
        let events = track.apply([], start: start, count: audio.count, language: "vi")
        #expect(events.count == 1 && events[0].text.isEmpty && !events[0].isFinal)
        #expect(track.hypothesis == nil)
    }

    @Test func longWindowsAreForcedToConfirm() {
        var track = CaptionTrack(name: "system")
        _ = track.append(start: 0, samples: Signal.tone(seconds: 13))
        let (audio, start) = track.beginDecode()
        let events = track.apply([CaptionPiece(start: 0, end: 12.5, text: "a long monologue")], start: start, count: audio.count,
                                 language: "en")
        #expect(events.map(\.isFinal) == [true])
        #expect(track.hypothesis == nil)
    }

    @Test func audioThatArrivesDuringADecodeIsKept() {
        var track = voicedTrack()
        let (audio, start) = track.beginDecode()
        _ = track.append(start: 14, samples: Signal.tone(seconds: 1))
        _ = track.apply([CaptionPiece(start: 2, end: 3, text: "một"), CaptionPiece(start: 3, end: 4, text: "hai")],
                        start: start, count: audio.count, language: "vi")
        #expect(abs(track.endTime - 15) < 0.01)
        #expect(track.pendingSec >= 0.99)
    }

    @Test func aTimeJumpClosesTheUtterance() {
        var track = voicedTrack()
        let (audio, start) = track.beginDecode()
        _ = track.apply([CaptionPiece(start: 2, end: 4, text: "trước khi tạm dừng")], start: start, count: audio.count, language: "vi")
        let events = track.append(start: 40, samples: Signal.tone(seconds: 0.5))
        #expect(events.map(\.isFinal) == [true])
        #expect(track.windowStart == 40)
    }

    @Test func resetDropsWithoutConfirming() {
        var track = voicedTrack()
        let (audio, start) = track.beginDecode()
        _ = track.apply([CaptionPiece(start: 2, end: 4, text: "nháp")], start: start, count: audio.count, language: "vi")
        let events = track.reset()
        #expect(events.count == 1 && events[0].text.isEmpty && !events[0].isFinal)
        #expect(track.samples.isEmpty && track.hypothesis == nil)
    }
}
