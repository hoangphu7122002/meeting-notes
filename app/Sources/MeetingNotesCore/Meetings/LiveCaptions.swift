import Foundation
import MeetingNotesCaptionKit

/// Fast live captions of the recording in progress (design B, `MeetingNotesCaptions` helper). Display only: never
/// written anywhere. Design A's `live_segment` text stays authoritative and replaces captions as it lands.
public struct LiveCaptions: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Downloading / preparing the model (fraction nil = indeterminate).
        case preparing(Double?)
        case starting
        case running
        /// Paused by the live rules ("memory", "battery"); captions resume by themselves.
        case paused(String)
        case failed(String)
    }

    public var phase: Phase
    /// Confirmed captions keyed by "track-seq".
    public private(set) var finals: [String: CaptionSegment] = [:]
    /// The current hypothesis per track.
    public private(set) var hypotheses: [String: CaptionSegment] = [:]
    /// Captions this far behind the newest one are forgotten (A has long covered them).
    public static let keepSec = 300.0
    /// A caption ending at most this long after A's last chunk end on its track counts as covered.
    public static let coverSlackSec = 0.3

    public init(phase: Phase = .starting) {
        self.phase = phase
    }

    public var isEmpty: Bool { finals.isEmpty && hypotheses.isEmpty }

    /// Applies a helper event; returns true when something visible changed.
    @discardableResult
    public mutating func apply(_ event: CaptionEvent) -> Bool {
        let before = self
        switch event {
        case .ready:
            if case .starting = phase { phase = .running }
        case let .caption(segment):
            if case .starting = phase { phase = .running }
            if segment.isFinal {
                hypotheses[segment.track] = nil
                if !segment.text.isEmpty { finals["\(segment.track)-\(segment.seq)"] = segment }
                prune(newest: segment.end)
            } else {
                hypotheses[segment.track] = segment.text.isEmpty ? nil : segment
            }
        case .status, .error:
            break
        }
        return self != before
    }

    /// Applies one helper stdout line (unknown lines are ignored).
    @discardableResult
    public mutating func apply(line: String) -> Bool {
        guard let event = CaptionEvent.parse(line) else { return false }
        return apply(event)
    }

    /// Clears all captions (pause/resume of the recording, new recording).
    public mutating func clear() {
        finals = [:]
        hypotheses = [:]
    }

    /// Captions not yet covered by design A, ordered by start. A caption is covered when an A chunk of the same track
    /// contains its midpoint, or A has already moved past its end on that track (A works through each track in order;
    /// spans it gated as silence or bleed are dropped from display too).
    public func drafts(covering transcript: LiveTranscript?) -> [CaptionSegment] {
        let all = Array(finals.values) + Array(hypotheses.values)
        let segments = transcript?.segments ?? []
        var frontier: [String: Double] = [:]
        for s in segments { frontier[s.track] = max(frontier[s.track] ?? 0, s.end) }
        return all.filter { caption in
            let mid = (caption.start + caption.end) / 2
            if let edge = frontier[caption.track], caption.end <= edge + Self.coverSlackSec { return false }
            return !segments.contains { $0.track == caption.track && $0.start <= mid && mid <= $0.end }
        }
        .sorted { $0.start != $1.start ? $0.start < $1.start : $0.track < $1.track }
    }

    private mutating func prune(newest: Double) {
        finals = finals.filter { $0.value.end >= newest - Self.keepSec }
    }
}

/// What the live area of the pill shows: design A lines (raw or polished) followed by B captions A has not covered
/// yet (drafts, shown gray). Oldest first, at most `count` lines.
public enum LiveDisplay {
    public static func lines(transcript: LiveTranscript?, captions: LiveCaptions?, count: Int, polished: Bool) -> [LiveLine] {
        guard count > 0 else { return [] }
        var lines = transcript?.displayLines(count, polished: polished) ?? []
        if let captions {
            lines += captions.drafts(covering: transcript).map {
                LiveLine(id: "b-\($0.track)-\($0.seq)\($0.isFinal ? "" : "h")", isMe: $0.track == "mic", start: $0.start,
                         text: $0.text, isDraft: true)
            }
        }
        let sorted = lines.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
        return Array(sorted.suffix(count))
    }
}
