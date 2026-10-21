// state.json snapshot read by 'meeting-notes ctl status' (Meetings).

import Foundation

/// `~/Library/Application Support/MeetingNotes/state.json`, read by `meeting-notes ctl status`.
public struct AppStatusSnapshot: Equatable, Sendable {
    public struct Processing: Equatable, Sendable {
        public var folder: String
        public var stage: String?
        public var overall: Double
        public var etaSec: Double?

        public init(folder: String, stage: String?, overall: Double, etaSec: Double?) {
            self.folder = folder
            self.stage = stage
            self.overall = overall
            self.etaSec = etaSec
        }
    }

    public var state: String
    public var title: String?
    public var folder: String?
    public var startedAt: Date?
    public var elapsedSec: Double?
    public var paused: Bool
    public var processing: Processing?
    public var queue: Int
    public var updatedAt: Date

    public init(state: String, title: String? = nil, folder: String? = nil, startedAt: Date? = nil, elapsedSec: Double? = nil,
                paused: Bool = false, processing: Processing? = nil, queue: Int = 0, updatedAt: Date = Date()) {
        self.state = state
        self.title = title
        self.folder = folder
        self.startedAt = startedAt
        self.elapsedSec = elapsedSec
        self.paused = paused
        self.processing = processing
        self.queue = queue
        self.updatedAt = updatedAt
    }

    public func jsonData() throws -> Data {
        let processingObject: Any = processing.map {
            [
                "folder": $0.folder,
                "stage": $0.stage ?? NSNull(),
                "overall": MeetingRecord.decimal($0.overall, places: 3),
                "eta_sec": $0.etaSec.map { MeetingRecord.decimal($0, places: 0) } ?? NSNull(),
            ] as [String: Any]
        } ?? NSNull()
        let object: [String: Any] = [
            "state": state,
            "title": title ?? NSNull(),
            "folder": folder ?? NSNull(),
            "started_at": startedAt.map(MeetingRecord.iso) ?? NSNull(),
            "elapsed_sec": elapsedSec.map { MeetingRecord.decimal($0, places: 1) } ?? NSNull(),
            "paused": paused,
            "processing": processingObject,
            "queue": queue,
            "updated_at": MeetingRecord.iso(updatedAt),
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
