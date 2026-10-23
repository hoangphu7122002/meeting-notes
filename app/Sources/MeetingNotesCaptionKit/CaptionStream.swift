import Foundation

/// Streaming window policy of one track (pure, unit-tested; the helper runs the decoder).
///
/// Audio of the current utterance accumulates in a window (recorded time). Whenever >= `minStepSec` of new voiced
/// audio arrived, the helper decodes the whole window; all segments but the last are confirmed (`final`), the last
/// one is the hypothesis. After `finalizeSilenceSec` of trailing silence the hypothesis is confirmed without another
/// decode and the window restarts; a window longer than `maxWindowSec` confirms everything but its last segment.
public struct CaptionPolicy: Equatable, Sendable {
    public var minStepSec = 0.6
    public var maxWindowSec = 12.0
    public var finalizeSilenceSec = 0.6
    public var preRollSec = 0.3
    public var minVoicedSec = 0.25
    /// Never hand Whisper more than its 30 s input window.
    public var hardLimitSec = 26.0
    /// Voiced seconds after which the detected language sticks for the rest of the utterance.
    public var languageLockSec = 1.5

    public init() {}
}

/// One decoded piece of a window, times relative to the window start.
public struct CaptionPiece: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct CaptionTrack: Sendable {
    public let name: String
    public let policy: CaptionPolicy
    public private(set) var samples: [Float] = []
    /// Recorded seconds of `samples[0]`.
    public private(set) var windowStart: Double = 0
    public private(set) var nextSeq = 0
    public private(set) var hypothesis: CaptionSegment?
    /// Language of the current utterance (vi/en), chosen by the helper on the first decode; reset per utterance.
    public var language: String?
    public private(set) var gate = EnergyGate()
    /// Window samples the last decode covered.
    public private(set) var decodedCount = 0
    private static let rate = Double(CaptionWire.sampleRate)

    public init(name: String, policy: CaptionPolicy = CaptionPolicy()) {
        self.name = name
        self.policy = policy
    }

    public var windowSec: Double { Double(samples.count) / Self.rate }
    /// Recorded time just after the last buffered sample.
    public var endTime: Double { windowStart + windowSec }
    public var pendingSec: Double { Double(samples.count - decodedCount) / Self.rate }

    /// Adds audio at recorded time `start`. Small gaps are filled with silence; a jump (pause/resume, dropped audio)
    /// closes the current utterance first. Returns the caption events to send.
    public mutating func append(start: Double, samples new: [Float]) -> [CaptionSegment] {
        guard !new.isEmpty else { return [] }
        var events: [CaptionSegment] = []
        if samples.isEmpty {
            windowStart = start
        } else {
            let gap = start - endTime
            if gap > 2 || gap < -0.5 {
                events += closeUtterance()
                samples = []
                gate = EnergyGate(floor: gate.floor)
                decodedCount = 0
                windowStart = start
            } else if gap > 0.02 {
                let fill = [Float](repeating: 0, count: Int((gap * Self.rate).rounded()))
                samples += fill
                gate.add(fill)
            }
        }
        samples += new
        gate.add(new)
        if windowSec > policy.hardLimitSec { drop(seconds: windowSec - policy.hardLimitSec) }
        return events
    }

    /// The window has new voiced audio worth a decode.
    public var needsDecode: Bool {
        pendingSec >= policy.minStepSec && gate.voicedSeconds(from: framesIndex(decodedCount)) >= policy.minVoicedSec
    }

    /// Housekeeping without a decode: after trailing silence (and nothing voiced left undecoded) the hypothesis is
    /// confirmed and the window shrinks to a short pre-roll; silent audio never piles up.
    public mutating func idle() -> [CaptionSegment] {
        let allDecoded = gate.lastVoicedFrame.map { $0 <= framesIndex(decodedCount) } ?? true
        guard allDecoded, gate.trailingSilenceSec >= policy.finalizeSilenceSec,
              hypothesis != nil || windowSec > policy.preRollSec + policy.minStepSec else { return [] }
        return closeUtterance()
    }

    /// The window audio to decode now and where it starts (pass both back to `apply`).
    public func beginDecode() -> (audio: [Float], start: Double) {
        (samples, windowStart)
    }

    /// Applies a decode of `count` samples that started at recorded time `start` (piece times are relative to it;
    /// more audio may have arrived meanwhile).
    public mutating func apply(_ pieces: [CaptionPiece], start: Double, count: Int, language: String?) -> [CaptionSegment] {
        let decodedEnd = start + Double(count) / Self.rate
        decodedCount = min(samples.count, max(0, Int(((decodedEnd - windowStart) * Self.rate).rounded())))
        let kept = pieces.map { CaptionPiece(start: start + $0.start, end: start + $0.end, text: CaptionText.clean($0.text)) }
            .filter { !$0.text.isEmpty }
        let long = decodedEnd - windowStart >= policy.maxWindowSec
        let confirm = kept.count > 1 ? kept.count - 1 : (long ? kept.count : 0)
        if kept.isEmpty, long {  // a long stretch of noise or music: never re-decode it
            drop(seconds: max(0, decodedEnd - windowStart - policy.preRollSec))
        }
        var events: [CaptionSegment] = []
        for piece in kept.prefix(confirm) {
            events.append(CaptionSegment(track: name, seq: nextSeq, start: piece.start, end: piece.end, text: piece.text,
                                         isFinal: true, language: language))
            nextSeq += 1
        }
        if let cut = kept.prefix(confirm).last?.end {
            drop(seconds: min(max(0, cut - windowStart), decodedEnd - windowStart))
        }
        let rest = Array(kept.dropFirst(confirm))
        if let first = rest.first, let last = rest.last {
            let hyp = CaptionSegment(track: name, seq: nextSeq, start: max(first.start, windowStart), end: last.end,
                                     text: CaptionText.join(rest.map(\.text)), isFinal: false, language: language)
            if hyp != hypothesis { events.append(hyp) }
            hypothesis = hyp
        } else if hypothesis != nil {
            events.append(clearEvent())
            hypothesis = nil
        }
        // Language detection on a short window is unreliable: keep re-detecting until the utterance is long enough.
        if gate.voicedSeconds(from: 0) >= policy.languageLockSec { self.language = language }
        return events
    }

    /// Ends the utterance: the hypothesis becomes final, the window keeps only a short pre-roll.
    public mutating func closeUtterance() -> [CaptionSegment] {
        var events: [CaptionSegment] = []
        if let hyp = hypothesis {
            events.append(CaptionSegment(track: name, seq: hyp.seq, start: hyp.start, end: hyp.end, text: hyp.text,
                                         isFinal: true, language: hyp.language))
            nextSeq = hyp.seq + 1
            hypothesis = nil
        }
        drop(seconds: max(0, windowSec - policy.preRollSec))
        decodedCount = samples.count
        language = nil
        return events
    }

    /// Drops buffered audio (pause, reset command); the hypothesis is cleared, not confirmed.
    public mutating func reset() -> [CaptionSegment] {
        let events = hypothesis == nil ? [] : [clearEvent()]
        hypothesis = nil
        samples = []
        decodedCount = 0
        gate = EnergyGate(floor: gate.floor)
        language = nil
        return events
    }

    // MARK: - Private

    private func clearEvent() -> CaptionSegment {
        CaptionSegment(track: name, seq: nextSeq, start: endTime, end: endTime, text: "", isFinal: false, language: nil)
    }

    private func framesIndex(_ sample: Int) -> Int { sample / EnergyGate.frameSize }

    private mutating func drop(seconds: Double) {
        let frames = Int(seconds * Self.rate) / EnergyGate.frameSize
        let count = min(frames * EnergyGate.frameSize, samples.count)
        guard count > 0 else { return }
        samples.removeFirst(count)
        gate.dropFrames(count / EnergyGate.frameSize)
        let sec = Double(count) / Self.rate
        windowStart += sec
        decodedCount = max(0, decodedCount - count)
    }
}
