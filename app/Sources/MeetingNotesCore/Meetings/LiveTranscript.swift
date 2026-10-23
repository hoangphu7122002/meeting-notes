import Foundation

/// The live transcript of one recording, folded from `live_segment` / `live_status` events of its job.
/// Segments are keyed by (track, seq): a repeated chunk (worker restart) replaces the earlier one.
public struct LiveTranscript: Equatable, Sendable {
    public let job: String
    /// Ordered by start time (then track, seq).
    public private(set) var segments: [LiveSegment] = []
    public private(set) var status: LiveStatus?
    /// Display-only polished paragraphs keyed by "track-para" (only when polish was requested). Raw segments stay.
    public private(set) var polished: [String: LivePolish] = [:]

    public init(job: String) {
        self.job = job
    }

    /// Live text is behind (system load, battery, backlog); the notes are still complete.
    public var isPaused: Bool { status?.isPaused ?? false }
    public var state: String? { status?.state }
    public var reason: String? { status?.reason }
    public var backlogSec: Double? { status?.backlogSec }

    /// Non-empty segments only.
    public var lines: [LiveSegment] { segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    /// The last `count` non-empty segments, oldest first.
    public func lastLines(_ count: Int) -> [LiveSegment] {
        guard count > 0 else { return [] }
        return Array(lines.suffix(count))
    }

    /// At least one polished paragraph arrived (the pill then offers a raw/polished toggle).
    public var hasPolish: Bool { !polished.isEmpty }

    /// The last `count` non-empty lines to show. `polished`: polished paragraphs replace the raw chunks they cover;
    /// chunks no paragraph covers yet are shown raw. Oldest first, ordered by start time.
    public func displayLines(_ count: Int, polished usePolish: Bool) -> [LiveLine] {
        guard count > 0 else { return [] }
        guard usePolish, hasPolish else {
            return lastLines(count).map { LiveLine(id: "\($0.track)-\($0.seq)", isMe: $0.isMe, start: $0.start, text: $0.text) }
        }
        var covered = Set<String>()
        var result: [LiveLine] = []
        for paragraph in polished.values {
            let keys = paragraph.seqs.map { "\(paragraph.track)-\($0)" }
            covered.formUnion(keys)
            let starts = segments.filter { $0.track == paragraph.track && paragraph.seqs.contains($0.seq) }.map(\.start)
            result.append(LiveLine(id: "p-\(paragraph.track)-\(paragraph.para)", isMe: paragraph.isMe,
                                   start: starts.min() ?? 0, text: paragraph.text))
        }
        for segment in segments where !covered.contains("\(segment.track)-\(segment.seq)") {
            result.append(LiveLine(id: "\(segment.track)-\(segment.seq)", isMe: segment.isMe, start: segment.start, text: segment.text))
        }
        let visible = result.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
        return Array(visible.suffix(count))
    }

    /// Segments whose text contains `query`, ignoring case and diacritics (also đ/d). Empty query = none.
    public func search(_ query: String) -> [LiveSegment] {
        let needle = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        return segments.filter { Self.fold($0.text).contains(needle) }
    }

    /// Adds or replaces a segment (same track and seq).
    public mutating func insert(_ segment: LiveSegment) {
        if let index = segments.firstIndex(where: { $0.track == segment.track && $0.seq == segment.seq }) {
            if segments[index] == segment { return }
            segments.remove(at: index)
        }
        let index = segments.firstIndex { Self.precedes(segment, $0) } ?? segments.endIndex
        segments.insert(segment, at: index)
    }

    /// Applies an event of this job; other jobs and event kinds are ignored. Returns true when something changed.
    @discardableResult
    public mutating func apply(_ event: WorkerEvent) -> Bool {
        guard event.job == job else { return false }
        let before = self
        switch event {
        case let .liveSegment(_, segment):
            insert(segment)
        case let .liveStatus(_, status):
            self.status = status
        case let .livePolish(_, paragraph):
            polished["\(paragraph.track)-\(paragraph.para)"] = paragraph
        default:
            break
        }
        return self != before
    }

    private static func precedes(_ a: LiveSegment, _ b: LiveSegment) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.track != b.track { return a.track < b.track }
        return a.seq < b.seq
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
    }
}

/// One line of the live view: a raw chunk, a polished paragraph or a fast caption (`isDraft`, design B).
public struct LiveLine: Equatable, Sendable, Identifiable {
    public let id: String
    public let isMe: Bool
    public let start: Double
    public let text: String
    /// A fast caption not yet replaced by design A's text (shown gray).
    public let isDraft: Bool

    public init(id: String, isMe: Bool, start: Double, text: String, isDraft: Bool = false) {
        self.id = id
        self.isMe = isMe
        self.start = start
        self.text = text
        self.isDraft = isDraft
    }
}
