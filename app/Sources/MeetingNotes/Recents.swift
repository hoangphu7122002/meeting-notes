import Foundation

struct RecentMeeting: Identifiable {
    enum Status: Equatable {
        case done, processing, queued, recording, failed(String?), notProcessed

        var label: String {
            switch self {
            case .done: return "done"
            case .processing: return "processing"
            case .queued: return "queued"
            case .recording: return "recording"
            case .failed: return "failed"
            case .notProcessed: return "not processed"
            }
        }
    }

    let url: URL
    let title: String
    let date: Date
    let status: Status
    var id: String { url.path }
    var notesURL: URL { url.appendingPathComponent("notes.md") }
    var logURL: URL { url.appendingPathComponent("pipeline.app.log") }
    var hasNotes: Bool { FileManager.default.fileExists(atPath: notesURL.path) }
    var hasLog: Bool { FileManager.default.fileExists(atPath: logURL.path) }
    var isBusy: Bool { status == .processing || status == .queued || status == .recording }
}

enum MeetingFolders {
    /// Creates `<dir>/<yyyy-MM-dd HHmm> Meeting[ N]/`.
    static func create(in dir: URL, date: Date = Date()) throws -> URL {
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

    static func removeIfEmpty(_ url: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["?"]
        if contents.filter({ $0 != ".DS_Store" }).isEmpty { try? FileManager.default.removeItem(at: url) }
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }
}

enum Recents {
    struct Context {
        var recording: URL?
        var processing: URL?
        var jobActive = false
        var queued: [URL] = []
    }

    /// Meeting folders (containing meeting.json or notes.md), newest first by creation date.
    static func load(dir: URL, limit: Int = 8, context: Context) -> [RecentMeeting] {
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
            let meeting = readJSON(url.appendingPathComponent("meeting.json"))
            let title = (meeting?["title"] as? String) ?? url.lastPathComponent
            let key = MeetingFolders.key(url)
            let status: RecentMeeting.Status
            if let recording = context.recording, MeetingFolders.key(recording) == key {
                status = .recording
            } else if let processing = context.processing, MeetingFolders.key(processing) == key {
                status = .processing
            } else if queued.contains(key) {
                status = .queued
            } else {
                let pipeline = readJSON(url.appendingPathComponent("status.json"))
                switch pipeline?["state"] as? String {
                case "done" where fm.fileExists(atPath: url.appendingPathComponent("notes.md").path):
                    status = .done
                case "failed":
                    status = .failed(pipeline?["error"] as? String)
                case "running" where context.jobActive:
                    // The pipeline may have renamed the folder of the active job.
                    status = .processing
                default:
                    status = .notProcessed
                }
            }
            return RecentMeeting(url: url, title: title, date: date, status: status)
        }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
