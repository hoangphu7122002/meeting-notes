import Foundation

/// One meeting folder in the "Recent meetings" list.
public struct RecentMeeting: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case done, processing, queued, recording, failed(String?), cancelled, notProcessed

        /// `percent` is shown for the running job.
        public func label(percent: Int? = nil, _ lang: UILanguage = L10n.language) -> String {
            switch self {
            case .done: return tr(.meetingReady, lang: lang)
            case .processing:
                return percent.map { tr(.meetingProcessingPercent, lang: lang, $0) } ?? tr(.meetingProcessing, lang: lang)
            case .queued: return tr(.meetingQueued, lang: lang)
            case .recording: return tr(.meetingRecording, lang: lang)
            case .failed: return tr(.meetingFailed, lang: lang)
            case .cancelled: return tr(.meetingCancelled, lang: lang)
            case .notProcessed: return tr(.meetingNotProcessed, lang: lang)
            }
        }
    }

    public let url: URL
    public let title: String
    public let date: Date
    public let status: Status
    /// Recorded seconds from meeting.json (nil while recording or unknown).
    public let durationSec: Double?
    /// notes.md exists (read when the list is loaded).
    public let hasNotes: Bool

    public init(url: URL, title: String, date: Date, status: Status, durationSec: Double? = nil, hasNotes: Bool = false) {
        self.url = url
        self.title = title
        self.date = date
        self.status = status
        self.durationSec = durationSec
        self.hasNotes = hasNotes
    }

    public var id: String { url.path }
    public var notesURL: URL { url.appendingPathComponent("notes.md") }
    public var logURL: URL { url.appendingPathComponent("pipeline.app.log") }
    public var hasLog: Bool { FileManager.default.fileExists(atPath: logURL.path) }
    public var isBusy: Bool { status == .processing || status == .queued || status == .recording }
}

public enum MeetingFolders {
    /// Creates `<dir>/<yyyy-MM-dd HHmm> Meeting[ N]/`.
    public static func create(in dir: URL, date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let base = "\(formatter.string(from: date)) Meeting"
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    public static func removeIfEmpty(_ url: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["?"]
        if contents.filter({ $0 != ".DS_Store" }).isEmpty { try? FileManager.default.removeItem(at: url) }
    }

    public static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    public static func title(of folder: URL) -> String {
        (readJSON(folder.appendingPathComponent("meeting.json"))?["title"] as? String) ?? folder.lastPathComponent
    }

    public static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

public enum Recents {
    public struct Context: Sendable {
        public var recording: URL?
        public var processing: URL?
        public var processingPercent: Int?
        public var jobActive = false
        public var queued: [URL] = []

        public init(recording: URL? = nil, processing: URL? = nil, processingPercent: Int? = nil, jobActive: Bool = false,
                    queued: [URL] = []) {
            self.recording = recording
            self.processing = processing
            self.processingPercent = processingPercent
            self.jobActive = jobActive
            self.queued = queued
        }
    }

    /// Meeting folders (containing meeting.json or notes.md), newest first by creation date.
    /// Read on demand (menu open), never on a timer.
    public static func load(dir: URL, limit: Int = 10, context: Context) -> [RecentMeeting] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }

        let folders: [(URL, Date)] = entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true else { return nil }
            guard fm.fileExists(atPath: url.appendingPathComponent("meeting.json").path)
                || fm.fileExists(atPath: url.appendingPathComponent("notes.md").path) else { return nil }
            return (url, values.creationDate ?? .distantPast)
        }
        let queued = Set(context.queued.map(MeetingFolders.key))

        return folders.sorted { $0.1 > $1.1 }.prefix(limit).map { url, date in
            let meeting = MeetingFolders.readJSON(url.appendingPathComponent("meeting.json"))
            let title = (meeting?["title"] as? String) ?? url.lastPathComponent
            let hasNotes = fm.fileExists(atPath: url.appendingPathComponent("notes.md").path)
            let key = MeetingFolders.key(url)
            let status: RecentMeeting.Status
            if let recording = context.recording, MeetingFolders.key(recording) == key {
                status = .recording
            } else if let processing = context.processing, MeetingFolders.key(processing) == key {
                status = .processing
            } else if queued.contains(key) {
                status = .queued
            } else {
                let pipeline = MeetingFolders.readJSON(url.appendingPathComponent("status.json"))
                switch pipeline?["state"] as? String {
                case "done" where hasNotes:
                    status = .done
                case "failed":
                    status = .failed(pipeline?["error"] as? String)
                case "cancelled":
                    status = .cancelled
                case "running" where context.jobActive:
                    // The pipeline may have renamed the folder of the active job.
                    status = .processing
                default:
                    status = .notProcessed
                }
            }
            let duration = (meeting?["duration_sec"] as? NSNumber)?.doubleValue
            return RecentMeeting(url: url, title: title, date: date, status: status, durationSec: duration, hasNotes: hasNotes)
        }
    }
}
