import Foundation

/// `transcript.json` written by the pipeline's transcribe stage.
public struct Transcript: Decodable, Equatable, Sendable {
    public struct Segment: Decodable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var speaker: String
        public var track: String?
        public var language: String?
        public var text: String
    }

    public struct Pause: Decodable, Equatable, Sendable {
        public var atSec: Double
        public var durationSec: Double

        enum CodingKeys: String, CodingKey {
            case atSec = "at_sec"
            case durationSec = "duration_sec"
        }
    }

    public var title: String?
    public var startedAt: String?
    public var durationSec: Double?
    public var speakers: [String]
    public var pauses: [Pause]
    public var segments: [Segment]

    enum CodingKeys: String, CodingKey {
        case title, speakers, pauses, segments
        case startedAt = "started_at"
        case durationSec = "duration_sec"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        durationSec = try c.decodeIfPresent(Double.self, forKey: .durationSec)
        speakers = try c.decodeIfPresent([String].self, forKey: .speakers) ?? []
        pauses = (try? c.decodeIfPresent([Pause].self, forKey: .pauses)) ?? []
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
    }

    /// A run of consecutive segments by one speaker, or a pause marker.
    public enum Block: Equatable, Sendable, Identifiable {
        case paragraph(id: Int, speaker: String, start: Double, text: String)
        case pause(id: Int, at: Double, duration: Double)

        public var id: Int {
            switch self {
            case .paragraph(let id, _, _, _), .pause(let id, _, _): return id
            }
        }
    }

    /// Groups segments into speaker paragraphs and inserts pause markers at their recorded time.
    /// `filter` keeps only segments containing the text (case-insensitive); pauses are dropped when filtering.
    public func blocks(filter: String = "") -> [Block] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        var blocks: [Block] = []
        var pending = pauses.sorted { $0.atSec < $1.atSec }
        var id = 0
        var current: (speaker: String, start: Double, parts: [String])?

        func flush() {
            if let paragraph = current {
                blocks.append(.paragraph(id: id, speaker: paragraph.speaker, start: paragraph.start,
                                         text: paragraph.parts.joined(separator: " ")))
                id += 1
            }
            current = nil
        }

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !query.isEmpty {
                guard text.localizedCaseInsensitiveContains(query) else { continue }
            } else {
                while let pause = pending.first, pause.atSec <= segment.start {
                    flush()
                    blocks.append(.pause(id: id, at: pause.atSec, duration: pause.durationSec))
                    id += 1
                    pending.removeFirst()
                }
            }
            if current?.speaker == segment.speaker {
                current?.parts.append(text)
            } else {
                flush()
                current = (segment.speaker, segment.start, [text])
            }
        }
        flush()
        return blocks
    }
}

/// `.work/summary.json` written by the summarize stage.
public struct MeetingSummary: Decodable, Equatable, Sendable {
    public struct ActionItem: Decodable, Equatable, Sendable {
        public var task: String
        public var owner: String?
        public var due: String?
    }

    public var title: String?
    public var summary: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var openQuestions: [String]

    enum CodingKeys: String, CodingKey {
        case title, summary, decisions
        case actionItems = "action_items"
        case openQuestions = "open_questions"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        if let list = try? c.decodeIfPresent([String].self, forKey: .summary) {
            summary = list
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .summary) {
            summary = [text]
        } else {
            summary = []
        }
        decisions = (try? c.decodeIfPresent([String].self, forKey: .decisions)) ?? []
        actionItems = (try? c.decodeIfPresent([ActionItem].self, forKey: .actionItems)) ?? []
        openQuestions = (try? c.decodeIfPresent([String].self, forKey: .openQuestions)) ?? []
    }

    /// Plain-text summary for the clipboard.
    public var plainText: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if !summary.isEmpty { parts.append("Summary\n" + summary.map { "- \($0)" }.joined(separator: "\n")) }
        if !decisions.isEmpty { parts.append("Key decisions\n" + decisions.map { "- \($0)" }.joined(separator: "\n")) }
        if !actionItems.isEmpty {
            parts.append("Action items\n" + actionItems.map { item in
                var line = "- [ ] \(item.task)"
                var meta: [String] = []
                if let owner = item.owner, !owner.isEmpty { meta.append(owner) }
                if let due = item.due, !due.isEmpty { meta.append("due \(due)") }
                if !meta.isEmpty { line += " (\(meta.joined(separator: ", ")))" }
                return line
            }.joined(separator: "\n"))
        }
        if !openQuestions.isEmpty { parts.append("Open questions\n" + openQuestions.map { "- \($0)" }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }
}
