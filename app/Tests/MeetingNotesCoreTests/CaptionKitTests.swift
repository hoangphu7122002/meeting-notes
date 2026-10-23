import Foundation
import MeetingNotesCaptionKit
import Testing

@Suite struct CaptionWireTests {
    @Test func audioCommandRoundTrips() throws {
        let samples: [Int16] = [0, 1, -1, 32767, -32768, 1234]
        let line = String(decoding: CaptionCommand.audio(track: "mic", start: 12.3456, samples: samples).line(), as: UTF8.self)
        #expect(line.hasSuffix("\n"))
        #expect(CaptionCommand.parse(line.trimmingCharacters(in: .newlines)) == .audio(track: "mic", start: 12.346, samples: samples))
    }

    @Test func controlCommands() {
        #expect(CaptionCommand.parse(#"{"cmd":"reset"}"#) == .reset(track: nil))
        #expect(CaptionCommand.parse(#"{"cmd":"reset","track":"system"}"#) == .reset(track: "system"))
        #expect(CaptionCommand.parse(#"{"cmd":"quit"}"#) == .quit)
        #expect(CaptionCommand.parse(#"{"cmd":"audio","track":"mic"}"#) == nil)
        #expect(CaptionCommand.parse("not json") == nil)
    }

    @Test func eventsRoundTrip() {
        let events: [CaptionEvent] = [
            .ready(model: "openai_whisper-small", compute: "ane", loadSec: 1.25),
            .caption(CaptionSegment(track: "mic", seq: 3, start: 1.5, end: 2.75, text: "Xin chào", isFinal: true, language: "vi")),
            .caption(CaptionSegment(track: "system", seq: 0, start: 4, end: 4, text: "", isFinal: false)),
            .status(state: "behind", lagSec: 4.5),
            .error("load failed"),
        ]
        for event in events {
            let line = String(decoding: event.line(), as: UTF8.self)
            #expect(CaptionEvent.parse(line) == event)
        }
        #expect(CaptionEvent.parse(#"{"event":"something_new"}"#) == nil)
        #expect(CaptionEvent.parse("🔴 NO TOKEN **") == nil)
    }

    @Test func progressLines() {
        #expect(CaptionProgress.parse("progress 0.420 downloading") == CaptionProgress(fraction: 0.42, phase: "downloading"))
        #expect(CaptionProgress.parse("progress 1.5") == CaptionProgress(fraction: 1, phase: ""))
        #expect(CaptionProgress.parse("model load failed") == nil)
        #expect(CaptionProgress(fraction: 0.5, phase: "compiling").line == "progress 0.500 compiling")
    }
}

@Suite struct CaptionTextTests {
    @Test func cleansDisplayText() {
        #expect(CaptionText.clean("  xin   chào  mọi người ") == "Xin chào mọi người")
        #expect(CaptionText.clean("<|vi|> hello , world .") == "Hello, world.")
        #expect(CaptionText.clean("[Music]") == "")
        #expect(CaptionText.clean("(upbeat music)") == "")
        #expect(CaptionText.clean("rất rất rất rất tốt") == "Rất rất tốt")
        #expect(CaptionText.clean("deploy lên deploy lên deploy lên server") == "Deploy lên server")
    }

    @Test func dropsSilenceBoilerplate() {
        #expect(CaptionText.clean("Cảm ơn các bạn đã theo dõi!") == "")
        #expect(CaptionText.clean("Thanks for watching.") == "")
        #expect(CaptionText.clean("Hãy subscribe cho kênh Ghiền Mì Gõ để không bỏ lỡ") == "")
        let long = "Cảm ơn các bạn đã theo dõi phần báo cáo doanh thu quý ba của đội mình"
        #expect(CaptionText.clean(long) == long)
    }

    @Test func normalizesToNFC() {
        let decomposed = "hoa\u{0300}"  // "hoà" with a combining grave accent
        #expect(CaptionText.clean(decomposed) == "Hoà".precomposedStringWithCanonicalMapping)
    }
}

@Suite struct EnergyGateTests {
    @Test func separatesSpeechFromRoomTone() {
        var gate = EnergyGate()
        gate.add(Signal.noise(seconds: 3, amplitude: 0.002))
        #expect(gate.voicedSeconds(from: 0) == 0)
        gate.add(Signal.tone(seconds: 1, amplitude: 0.3))
        #expect(gate.voicedSeconds(from: 0) > 0.9)
        #expect(gate.trailingSilenceSec < 0.05)
        gate.add(Signal.noise(seconds: 0.9, amplitude: 0.002))
        #expect(abs(gate.trailingSilenceSec - 0.9) < 0.05)
    }
}

enum Signal {
    static let rate = 16_000

    static func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    static func noise(seconds: Double, amplitude: Float = 0.002) -> [Float] {
        var state: UInt32 = 12345
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 1_103_515_245 &+ 12345
            return amplitude * (Float(state >> 16 & 0x7FFF) / 16384 - 1)
        }
    }
}
