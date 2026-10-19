import Foundation

/// `meeting.json`: the recording's metadata, read by the pipeline.
public struct MeetingRecord: Equatable, Sendable {
    public struct Track: Equatable, Sendable {
        public var file: String
        public var startOffsetSec: Double
        public var sampleRate: Int
        public var device: String?

        public init(file: String, startOffsetSec: Double, sampleRate: Int, device: String? = nil) {
            self.file = file
            self.startOffsetSec = startOffsetSec
            self.sampleRate = sampleRate
            self.device = device
        }
    }

    public struct PauseEntry: Equatable, Sendable {
        /// Recorded time when the pause began.
        public var atSec: Double
        /// Wall seconds paused.
        public var durationSec: Double
        public var startedAt: Date

        public init(atSec: Double, durationSec: Double, startedAt: Date) {
            self.atSec = atSec
            self.durationSec = durationSec
            self.startedAt = startedAt
        }
    }

    public var title: String
    public var titleSource: String
    public var appHint: String?
    public var startedAt: Date
    public var endedAt: Date?
    /// Recorded duration (pauses excluded).
    public var durationSec: Double?
    public var wallDurationSec: Double?
    public var tracks: [String: Track] = [:]
    public var warnings: [String] = []
    public var pauses: [PauseEntry] = []

    public init(title: String, titleSource: String, appHint: String?, startedAt: Date) {
        self.title = title
        self.titleSource = titleSource
        self.appHint = appHint
        self.startedAt = startedAt
    }

    public func jsonObject() -> [String: Any] {
        var trackObjects: [String: Any] = [:]
        for (key, track) in tracks {
            var object: [String: Any] = [
                "file": track.file,
                "start_offset_sec": Self.decimal(track.startOffsetSec, places: 3),
                "sample_rate": track.sampleRate,
            ]
            if let device = track.device { object["device"] = device }
            trackObjects[key] = object
        }
        return [
            "version": 1,
            "title": title,
            "title_source": titleSource,
            "app_hint": appHint ?? NSNull(),
            "started_at": Self.iso(startedAt),
            "ended_at": endedAt.map(Self.iso) ?? NSNull(),
            "duration_sec": durationSec.map { Self.decimal($0, places: 2) } ?? NSNull(),
            "wall_duration_sec": wallDurationSec.map { Self.decimal($0, places: 2) } ?? NSNull(),
            "tracks": trackObjects,
            "warnings": warnings,
            "pauses": pauses.map {
                [
                    "at_sec": Self.decimal($0.atSec, places: 2),
                    "duration_sec": Self.decimal($0.durationSec, places: 2),
                    "started_at": Self.iso($0.startedAt),
                ] as [String: Any]
            },
        ]
    }

    public func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject(), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Sets a user title in an existing meeting.json, keeping every other field (the pipeline may have changed them).
    public static func updatingTitle(_ data: Data, title: String) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoreError("meeting.json is not an object")
        }
        object["title"] = title
        object["title_source"] = "user"
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Rounded number that serializes without binary floating-point noise (0.386, not 0.38600000000000001).
    public static func decimal(_ value: Double, places: Int) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(places)f", value), locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

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
