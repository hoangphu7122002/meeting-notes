import Foundation
import MeetingNotesCore
import MeetingNotesUI

/// The long-lived `meeting-notes worker` process, spawned on demand.
///
/// stdin/stdout are JSON lines (see pipeline/src/meeting_notes/adapters/inbound/worker.py). stderr goes to the current
/// job's `pipeline.app.log` (or `~/Library/Logs/MeetingNotes/worker.log` between jobs). The worker exits
/// by itself after about a minute idle; the next job respawns it.
@MainActor
final class WorkerClient {
    var onEvent: ((WorkerEvent) -> Void)?
    /// The process ended (idle exit, crash or quit).
    var onTerminate: (() -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var environmentKey: String?
    private var exiting = false
    private var generation = 0
    private let log = LogSink()

    /// Running and not announced idle exit.
    var isAvailable: Bool { process?.isRunning == true && !exiting }

    /// Spawns the worker unless one with the same priority/model is already running.
    func ensureRunning(priority: String, model: String) throws {
        let key = "\(priority)|\(model)"
        if isAvailable, environmentKey == key { return }
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
        let uv = Settings.uvPath
        guard fm.isExecutableFile(atPath: uv) else { throw AppError(tr(.errUvNotFound, uv)) }
        guard let pipelineDir = Settings.pipelineDir else { throw AppError(tr(.errPipelineNotConfigured)) }
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
                    events.forEach { self.onEvent?($0) }
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
    }

    private func detach() {
        generation += 1
        process = nil
        stdin = nil
        environmentKey = nil
        exiting = false
    }
}
