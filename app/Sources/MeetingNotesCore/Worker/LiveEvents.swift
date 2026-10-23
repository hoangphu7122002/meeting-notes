import Foundation

/// One decoded chunk of the live transcript (`{"event":"live_segment",...}`), opt-in while recording.
/// `seq` increases per track; after a worker restart the same (track, seq) may arrive again.
public struct LiveSegment: Equatable, Sendable {
    /// "mic" (the user) or "system" (other participants).
    public let track: String
    /// "Me" or "Others", as sent by the worker.
    public let speaker: String
    public let seq: Int
    /// Seconds of recorded audio (pauses excluded).
    public let start: Double
    public let end: Double
    public let language: String?
    public let text: String

    public init(track: String, speaker: String, seq: Int, start: Double, end: Double, language: String? = nil, text: String) {
        self.track = track
        self.speaker = speaker
        self.seq = seq
        self.start = start
        self.end = end
        self.language = language
        self.text = text
    }

    /// Spoken by the user (mic track).
    public var isMe: Bool { track == "mic" }

    init?(object: [String: Any]) {
        guard let track = object["track"] as? String, let seq = (object["seq"] as? NSNumber)?.intValue else { return nil }
        let start = (object["start"] as? NSNumber)?.doubleValue ?? 0
        self.init(track: track, speaker: (object["speaker"] as? String) ?? (track == "mic" ? "Me" : "Others"), seq: seq,
                  start: start, end: (object["end"] as? NSNumber)?.doubleValue ?? start,
                  language: object["language"] as? String, text: (object["text"] as? String) ?? "")
    }
}

/// Health of the live job (`{"event":"live_status",...}`).
public struct LiveStatus: Equatable, Sendable {
    /// "running", "deferred" (waiting for system load), "throttled" (spans skipped, left to the Stop-time pass)
    /// or "stopped".
    public let state: String
    public let backlogSec: Double?
    public let skippedSec: Double?
    public let rtf: Double?
    /// "memory", "cpu", "thermal", "battery", "backlog" or nil.
    public let reason: String?

    public init(state: String, backlogSec: Double? = nil, skippedSec: Double? = nil, rtf: Double? = nil, reason: String? = nil) {
        self.state = state
        self.backlogSec = backlogSec
        self.skippedSec = skippedSec
        self.rtf = rtf
        self.reason = reason
    }

    /// Live text is not keeping up; the notes are still complete (Stop-time pass).
    public var isPaused: Bool { state == "deferred" || state == "throttled" }
    public var isStopped: Bool { state == "stopped" }

    init?(object: [String: Any]) {
        guard let state = object["state"] as? String else { return nil }
        func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        self.init(state: state, backlogSec: number("backlog_sec"), skippedSec: number("skipped_sec"), rtf: number("rtf"),
                  reason: object["reason"] as? String)
    }
}

/// Display-only polished text of one live paragraph (`{"event":"live_polish",...}`), sent only when the `live`
/// command asked for polish. A later event with the same (track, para) replaces the earlier text; `seqs` are the
/// raw `live_segment` chunks of that track the paragraph covers. Raw segments are always kept.
public struct LivePolish: Equatable, Sendable {
    public let track: String
    public let speaker: String
    public let para: Int
    public let seqs: [Int]
    /// "rules" (Tier 1).
    public let tier: String
    public let text: String

    public init(track: String, speaker: String, para: Int, seqs: [Int], tier: String = "rules", text: String) {
        self.track = track
        self.speaker = speaker
        self.para = para
        self.seqs = seqs
        self.tier = tier
        self.text = text
    }

    public var isMe: Bool { track == "mic" }

    init?(object: [String: Any]) {
        guard let track = object["track"] as? String, let para = (object["para"] as? NSNumber)?.intValue else { return nil }
        let seqs = ((object["seqs"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        self.init(track: track, speaker: (object["speaker"] as? String) ?? (track == "mic" ? "Me" : "Others"), para: para,
                  seqs: seqs, tier: (object["tier"] as? String) ?? "rules", text: (object["text"] as? String) ?? "")
    }
}
