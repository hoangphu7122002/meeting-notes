import Foundation
import MeetingNotesCore
import MeetingNotesUI

/// The long-lived `meeting-notes worker` process, spawned on demand.
///
/// stdin/stdout are JSON lines (see pipeline/src/meeting_notes/adapters/inbound/worker.py). stderr goes to the current
/// job's `pipeline.app.log` (or `~/Library/Logs/MeetingNotes/worker.log` between jobs). The worker exits
/// by itself after about a minute idle; the next job respawns it.
///
/// Owned by `AppController` and shared by `JobQueue` (process jobs) and `LiveTranscriber` (live jobs);
/// the controller routes `onEvent` / `onTerminate` to both.
@MainActor
final class WorkerClient {
    var onEvent: ((WorkerEvent) -> Void)?
    /// The process ended (idle exit, crash or quit).
    var onTerminate: (() -> Void)?

    /// Features from the current process's `ready` event (e.g. ["live"]); nil until it is ready.
    private(set) var features: [String]?

    private var process: Process?
    private var stdin: FileHandle?
    private var environmentKey: String?
    private var exiting = false
    private var generation = 0
    private let log = LogSink()

    /// Running and not announced idle exit.
    var isAvailable: Bool { process?.isRunning == true && !exiting }

    /// Spawns the worker unless a reusable one is already running (same priority/model; an explicit job
    /// accepts any priority so warm models survive, see `WorkerReuse`).
    func ensureRunning(priority: String, model: String, explicit: Bool = false) throws {
        let key = WorkerReuse.key(priority: priority, model: model)
        if isAvailable, WorkerReuse.canReuse(runningKey: environmentKey, priority: priority, model: model, explicit: explicit) { return }
        if process != nil { shutdown() }
        try spawn(priority: priority, model: model)
        environmentKey = key
    }

    func send(_ line: String) throws {
        guard let stdin, isAvailable else { throw AppError(tr(.errWorkerNotRunning)) }
        try stdin.write(contentsOf: Data(line.utf8))
    }

    /// The worker announced `{"event":"worker","status":"exit"}`: do not send it new jobs.
    func markExiting() { exiting = true }

    /// Where stderr goes; nil = the shared worker log.
    func setLogFile(_ url: URL?, header: String? = nil) { log.setFile(url, header: header) }

    /// Asks the worker to quit. `wait` > 0 (app quit) blocks up to that many seconds for it to exit,
    /// then terminates it, so no orphaned worker keeps running models.
    func shutdown(cancelRunningJob: Bool = false, wait: Double = 0) {
        guard let process else { return }
        if cancelRunningJob { try? stdin?.write(contentsOf: Data(WorkerEvent.Command.cancel.utf8)) }
        try? stdin?.write(contentsOf: Data(WorkerEvent.Command.quit.utf8))
        try? stdin?.close()
        detach()
        if wait > 0 {
            let deadline = Date().addingTimeInterval(wait)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            if process.isRunning { process.terminate() }
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    // MARK: - Private

    private func spawn(priority: String, model: String) throws {
        let fm = FileManager.default
        guard let location = Settings.pipelineLocation else {
            throw AppError(tr(AppInfo.isPackaged ? .errSetupIncomplete : .errPipelineNotConfigured))
        }
        let uv = location.uvPath, pipelineDir = location.pipelineDir
        guard fm.isExecutableFile(atPath: uv) else { throw AppError(tr(.errUvNotFound, uv)) }
        guard fm.fileExists(atPath: pipelineDir) else { throw AppError(tr(.errPipelineNotFound, pipelineDir)) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uv)
        process.arguments = ["run", "--project", pipelineDir, "meeting-notes", "worker"]
        process.currentDirectoryURL = URL(fileURLWithPath: pipelineDir)
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment["PYTHONUNBUFFERED"] = "1"
        environment["MEETING_NOTES_PRIORITY"] = priority
        environment["MEETING_NOTES_OLLAMA_MODEL"] = model
        environment["MEETING_NOTES_DIR"] = Settings.notesDir.path  // one notes folder for the app and the pipeline
        environment = PipelineLocator.workerEnvironment(environment, location: location)
        environment = DiarizeHelper.workerEnvironment(environment, executableURL: Bundle.main.executableURL) {
            fm.isExecutableFile(atPath: $0)
        }
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        generation += 1
        let generation = self.generation
        let lines = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil  // EOF: stop, or the handler spins
                return
            }
            let events = lines.append(data).compactMap { WorkerEvent(data: $0) }
            guard !events.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    for event in events {
                        if case .worker("ready", _, let features) = event { self.features = features }
                        self.onEvent?(event)
                    }
                }
            }
        }
        let log = self.log
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            log.write(data)
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.detach()
                    self.onTerminate?()
                }
            }
        }
        log.write(Data("\n=== \(Date()) worker start (priority \(priority), model \(model)) ===\n".utf8))
        try process.run()
        self.process = process
        stdin = input.fileHandleForWriting
        exiting = false
        features = nil
    }

    private func detach() {
        generation += 1
        process = nil
        stdin = nil
        environmentKey = nil
        exiting = false
        features = nil
    }
}
