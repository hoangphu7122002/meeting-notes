import Foundation

/// One stdout line of `meeting-notes worker` (see pipeline/src/meeting_notes/adapters/inbound/worker.py and adapters/outbound/progress_reporter.py).
public enum WorkerEvent: Equatable, Sendable {
    case worker(status: String, message: String?)
    case stage(job: String?, stage: String, status: String, elapsedSec: Double?, etaSec: Double?, overall: Double?, message: String?)
    case progress(job: String?, stage: String?, fraction: Double, overall: Double?, etaSec: Double?, message: String?)
    case warning(job: String?, message: String)
    case error(job: String?, message: String)
    case partial(job: String?, folder: String, notes: String)
    case cancelled(job: String?, folder: String?)
    case done(job: String?, folder: String, notes: String, title: String?, totalSec: Double?)
    case jobEnd(job: String?, exit: Int)
    case pong(busy: Bool)
    case other(String)

    public init?(line: String) {
        self.init(data: Data(line.utf8))
    }

    public init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["event"] as? String else { return nil }
        func string(_ key: String) -> String? { object[key] as? String }
        func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        let job = string("job")
        let message = string("message").flatMap { $0.isEmpty ? nil : $0 }
        switch kind {
        case "worker":
            self = .worker(status: string("status") ?? "", message: message)
        case "stage":
            guard let stage = string("stage") else { return nil }
            self = .stage(job: job, stage: stage, status: string("status") ?? "", elapsedSec: number("elapsed_sec"),
                          etaSec: number("eta_sec"), overall: number("overall"), message: message)
        case "progress":
            self = .progress(job: job, stage: string("stage"), fraction: number("fraction") ?? 0, overall: number("overall"),
                             etaSec: number("eta_sec"), message: message)
        case "warning":
            self = .warning(job: job, message: message ?? "")
        case "error":
            self = .error(job: job, message: message ?? "Unknown error")
        case "partial":
            guard let folder = string("folder"), let notes = string("notes") else { return nil }
            self = .partial(job: job, folder: folder, notes: notes)
        case "cancelled":
            self = .cancelled(job: job, folder: string("folder"))
        case "done":
            guard let folder = string("folder") else { return nil }
            self = .done(job: job, folder: folder, notes: string("notes") ?? folder + "/notes.md", title: string("title"),
                         totalSec: number("total_sec"))
        case "job_end":
            self = .jobEnd(job: job, exit: (object["exit"] as? NSNumber)?.intValue ?? 1)
        case "pong":
            self = .pong(busy: (object["busy"] as? Bool) ?? false)
        default:
            self = .other(kind)
        }
    }

    public var job: String? {
        switch self {
        case .stage(let job, _, _, _, _, _, _), .progress(let job, _, _, _, _, _), .warning(let job, _), .error(let job, _),
             .partial(let job, _, _), .cancelled(let job, _), .done(let job, _, _, _, _), .jobEnd(let job, _):
            return job
        case .worker, .pong, .other:
            return nil
        }
    }

    /// Command lines written to the worker's stdin.
    public enum Command {
        public static func process(job: String, folder: String, from stage: String? = nil) -> String {
            var object: [String: Any] = ["cmd": "process", "job": job, "folder": folder]
            if let stage { object["from"] = stage }
            return line(object)
        }

        public static let cancel = line(["cmd": "cancel"])
        public static let quit = line(["cmd": "quit"])

        private static func line(_ object: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self) + "\n"
        }
    }
}

public enum StageStatus: String, Equatable, Sendable {
    case pending, running, done, skipped, failed
}

public struct StageProgress: Equatable, Sendable {
    public let name: String
    public var status: StageStatus = .pending
    public var elapsedSec: Double?
    public var fraction: Double = 0

    public func title(_ lang: UILanguage = L10n.language) -> String {
        switch name {
        case "prepare": return tr(.stagePrepare, lang: lang)
        case "diarize": return tr(.stageDiarize, lang: lang)
        case "transcribe": return tr(.stageTranscribe, lang: lang)
        case "summarize": return tr(.stageSummarize, lang: lang)
        case "render": return tr(.stageRender, lang: lang)
        case "finalize": return tr(.stageFinalize, lang: lang)
        default: return name.prefix(1).uppercased() + name.dropFirst()
        }
    }
}

/// Live state of one processing job, folded from worker events.
public struct ProcessingSnapshot: Equatable, Sendable {
    public static let pipelineStages = ["prepare", "diarize", "transcribe", "summarize", "render", "finalize"]
    /// Stages shown in the UI; render/finalize are folded into "finishing".
    public static let displayStageNames = ["prepare", "diarize", "transcribe", "summarize"]

    public var job: String
    public var folder: String
    public var title: String
    public var stages: [StageProgress] = Self.pipelineStages.map { StageProgress(name: $0) }
    public var currentStage: String?
    public var overall: Double = 0
    public var etaSec: Double?
    public var message: String?
    /// notes.md with the transcript (summary pending), from the `partial` event.
    public var partialNotes: String?
    public var lastError: String?
    public var warnings: [String] = []
    /// Non-nil while the job waits to start (e.g. "Waiting until idle and plugged in").
    public var waiting: String?
    /// Jobs queued behind this one.
    public var queued = 0

    public init(job: String, folder: String, title: String) {
        self.job = job
        self.folder = folder
        self.title = title
    }

    public var percent: Int { Int((min(max(overall, 0), 1) * 100).rounded(.down)) }
    public var isFinishing: Bool { currentStage == "render" || currentStage == "finalize" }

    public var displayStages: [StageProgress] {
        stages.filter { Self.displayStageNames.contains($0.name) }
    }

    /// Applies an event of this job; events of other jobs are ignored. Returns true when something changed.
    @discardableResult
    public mutating func apply(_ event: WorkerEvent) -> Bool {
        if let eventJob = event.job, eventJob != job { return false }
        let before = self
        switch event {
        case let .stage(_, stage, status, elapsed, eta, overall, message):
            waiting = nil
            if let index = stages.firstIndex(where: { $0.name == stage }) {
                switch status {
                case "start":
                    stages[index].status = .running
                    stages[index].fraction = 0
                    currentStage = stage
                case "done":
                    stages[index].status = .done
                    stages[index].fraction = 1
                case "skipped":
                    stages[index].status = .skipped
                    stages[index].fraction = 1
                case "failed":
                    stages[index].status = .failed
                default:
                    break
                }
                if let elapsed { stages[index].elapsedSec = elapsed }
                // Earlier stages are finished once a later one starts.
                for i in stages.indices where i < index && (stages[i].status == .pending || stages[i].status == .running) {
                    stages[i].status = .done
                    stages[i].fraction = 1
                }
            }
            if let overall { self.overall = max(self.overall, overall) }
            etaSec = eta
            if let message { self.message = message }
        case let .progress(_, stage, fraction, overall, eta, message):
            waiting = nil
            if let stage, let index = stages.firstIndex(where: { $0.name == stage }) {
                if stages[index].status == .pending { stages[index].status = .running }
                stages[index].fraction = min(max(fraction, 0), 1)
                currentStage = stage
            }
            if let overall { self.overall = max(self.overall, overall) }
            etaSec = eta
            if let message { self.message = message }
        case let .warning(_, message):
            if !message.isEmpty, !warnings.contains(message) { warnings.append(message) }
        case let .error(_, message):
            lastError = message
        case let .partial(_, folder, notes):
            self.folder = folder
            partialNotes = notes
        case let .done(_, folder, _, title, _):
            self.folder = folder
            if let title, !title.isEmpty { self.title = title }
            overall = 1
            etaSec = 0
            for i in stages.indices where stages[i].status == .pending || stages[i].status == .running {
                stages[i].status = .done
                stages[i].fraction = 1
            }
        case let .cancelled(_, folder):
            if let folder { self.folder = folder }
        case .jobEnd, .worker, .pong, .other:
            break
        }
        return self != before
    }
}

/// How a job ended.
public enum JobOutcome: Equatable, Sendable {
    case done(folder: String, notes: String, title: String?)
    case failed(message: String)
    case cancelled

    /// Maps `job_end.exit` (0 ok, 1 failed, 2 bad request, 3 cancelled) plus the events seen.
    public static func from(exit: Int, done: WorkerEvent?, lastError: String?) -> JobOutcome {
        switch exit {
        case 0:
            if case let .done(_, folder, notes, title, _)? = done { return .done(folder: folder, notes: notes, title: title) }
            return .failed(message: tr(.errNoNotesProduced))
        case 3:
            return .cancelled
        case 2:
            return .failed(message: lastError ?? tr(.errPipelineRejected))
        default:
            return .failed(message: lastError ?? tr(.errPipelineExit, exit))
        }
    }
}
