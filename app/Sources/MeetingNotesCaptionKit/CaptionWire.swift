import Foundation

/// Wire protocol between the app and the `MeetingNotesCaptions` helper (live captions, design B): JSON lines.
///
/// stdin (app -> helper):
///   `{"cmd":"audio","track":"mic|system","start":<recorded sec>,"pcm":"<base64 s16le mono 16 kHz>"}`
///   `{"cmd":"reset","track":"mic"}` (track omitted = all; drops buffered audio, e.g. after a pause)
///   `{"cmd":"quit"}` (also EOF)
/// stdout (helper -> app):
///   `{"event":"ready","model","compute","load_sec"}` once the model is loaded
///   `{"event":"caption","track","seq","start","end","text","final","language"}`: `final:false` is the track's current
///   hypothesis (replaces the previous one); `final:true` confirms `seq` (next hypothesis uses a higher seq).
///   `{"event":"status","state":"running|behind","lag_sec"}` and `{"event":"error","message"}`
/// `--prepare` reports `progress <fraction> <phase>` lines on stderr (same format as MeetingNotesDiarize).
public enum CaptionWire {
    public static let sampleRate = 16_000
}

/// One caption line of a track: recorded-time span (pauses excluded, same timeline as `live_segment`).
public struct CaptionSegment: Equatable, Sendable {
    public let track: String
    public let seq: Int
    public let start: Double
    public let end: Double
    public let text: String
    /// Confirmed text (kept until design A covers it); false = hypothesis that may still change.
    public let isFinal: Bool
    public let language: String?

    public init(track: String, seq: Int, start: Double, end: Double, text: String, isFinal: Bool, language: String? = nil) {
        self.track = track
        self.seq = seq
        self.start = start
        self.end = end
        self.text = text
        self.isFinal = isFinal
        self.language = language
    }
}

public enum CaptionCommand: Equatable, Sendable {
    case audio(track: String, start: Double, samples: [Int16])
    case reset(track: String?)
    case quit

    /// One JSON line (with the trailing newline).
    public func line() -> Data {
        var object: [String: Any]
        switch self {
        case let .audio(track, start, samples):
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }  // little-endian on Apple silicon / Intel
            object = ["cmd": "audio", "track": track, "start": (start * 1000).rounded() / 1000, "pcm": data.base64EncodedString()]
        case let .reset(track):
            object = ["cmd": "reset"]
            if let track { object["track"] = track }
        case .quit:
            object = ["cmd": "quit"]
        }
        return CaptionJSON.line(object)
    }

    public static func parse(_ line: String) -> CaptionCommand? {
        guard let object = CaptionJSON.object(line), let cmd = object["cmd"] as? String else { return nil }
        switch cmd {
        case "audio":
            guard let track = object["track"] as? String, let start = (object["start"] as? NSNumber)?.doubleValue,
                  let pcm = object["pcm"] as? String, let data = Data(base64Encoded: pcm) else { return nil }
            let count = data.count / MemoryLayout<Int16>.size
            var samples = [Int16](repeating: 0, count: count)
            _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0, count: count * MemoryLayout<Int16>.size) }
            return .audio(track: track, start: start, samples: samples)
        case "reset":
            return .reset(track: object["track"] as? String)
        case "quit":
            return .quit
        default:
            return nil
        }
    }
}

public enum CaptionEvent: Equatable, Sendable {
    case ready(model: String, compute: String, loadSec: Double)
    case caption(CaptionSegment)
    case status(state: String, lagSec: Double?)
    case error(String)

    public func line() -> Data {
        switch self {
        case let .ready(model, compute, loadSec):
            return CaptionJSON.line(["event": "ready", "model": model, "compute": compute, "load_sec": round3(loadSec)])
        case let .caption(s):
            var object: [String: Any] = ["event": "caption", "track": s.track, "seq": s.seq, "start": round3(s.start),
                                         "end": round3(s.end), "text": s.text, "final": s.isFinal]
            if let language = s.language { object["language"] = language }
            return CaptionJSON.line(object)
        case let .status(state, lag):
            var object: [String: Any] = ["event": "status", "state": state]
            if let lag { object["lag_sec"] = round3(lag) }
            return CaptionJSON.line(object)
        case let .error(message):
            return CaptionJSON.line(["event": "error", "message": message])
        }
    }

    /// Parses one stdout line; unknown or malformed lines are nil (ignored by the app).
    public static func parse(_ line: String) -> CaptionEvent? {
        guard let object = CaptionJSON.object(line), let event = object["event"] as? String else { return nil }
        func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        switch event {
        case "ready":
            return .ready(model: object["model"] as? String ?? "", compute: object["compute"] as? String ?? "",
                          loadSec: number("load_sec") ?? 0)
        case "caption":
            guard let track = object["track"] as? String, let seq = (object["seq"] as? NSNumber)?.intValue else { return nil }
            let start = number("start") ?? 0
            return .caption(CaptionSegment(track: track, seq: seq, start: start, end: number("end") ?? start,
                                           text: object["text"] as? String ?? "", isFinal: object["final"] as? Bool ?? false,
                                           language: object["language"] as? String))
        case "status":
            return .status(state: object["state"] as? String ?? "", lagSec: number("lag_sec"))
        case "error":
            return .error(object["message"] as? String ?? "")
        default:
            return nil
        }
    }

    private func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
}

/// `progress <fraction> <phase>` lines of `--prepare` (stderr).
public struct CaptionProgress: Equatable, Sendable {
    public let fraction: Double
    public let phase: String

    public init(fraction: Double, phase: String) {
        self.fraction = fraction
        self.phase = phase
    }

    public var line: String { "progress \(String(format: "%.3f", fraction)) \(phase)" }

    public static func parse(_ line: String) -> CaptionProgress? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0] == "progress", let fraction = Double(parts[1]) else { return nil }
        return CaptionProgress(fraction: min(max(fraction, 0), 1), phase: parts.count > 2 ? String(parts[2]) : "")
    }
}

enum CaptionJSON {
    static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }
}
