// Runs the packaged app's first-run setup step by step (Setup). The order and every decision live in
// `SetupMachine` (Core, tested); this file only starts processes, probes and files.

import AppKit
import MeetingNotesCore
import MeetingNotesUI

@MainActor
final class SetupRunner {
    /// Called on every change of `machine` (the controller publishes it to the main window).
    var onChange: ((SetupMachine) -> Void)?
    /// Called once when the last step finishes.
    var onComplete: (() -> Void)?
    private(set) var machine: SetupMachine
    private let layout: RuntimeLayout
    private let appVersion: String
    private var record: SetupRecord
    private var process: SetupProcess?
    private var poll: Timer?
    private var probe: Task<Void, Never>?

    init(layout: RuntimeLayout = AppInfo.runtime, appVersion: String = AppInfo.setupVersion) {
        self.layout = layout
        self.appVersion = appVersion
        let fm = FileManager.default
        record = SetupRecord.parse(fm.contents(atPath: layout.stateURL.path))
        let runtimeReady = fm.fileExists(atPath: layout.markerURL.path) && fm.isExecutableFile(atPath: layout.cli.path)
        // After an update only the runtime step is new: it runs by itself, as the user already agreed once.
        machine = SetupMachine(done: record.doneSteps(appVersion: appVersion, runtimeReady: runtimeReady),
                               started: record.completedOnce)
    }

    var isComplete: Bool { machine.phase == .complete }

    func start() {
        machine.start()
        changed()
    }

    func cancel() {
        stopWork()
        machine.cancel()
        changed()
    }

    /// One heavy job at a time: a recording or a notes job pauses setup; it resumes when both are over.
    func setBusy(_ reason: SetupWaitReason?) {
        let before = machine
        machine.setBusy(reason)
        guard machine != before else { return }
        if case .waiting = machine.phase { stopWork() }
        changed()
    }

    /// The user opened Ollama: check again a few seconds later, when it answers.
    func recheckSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.machine.phase == .blocked, case .needsUser = self.machine.state(.ollama) else { return }
            self.start()
        }
    }

    // MARK: - Steps

    private func changed() {
        onChange?(machine)
        if machine.phase == .complete, !record.completedOnce {
            record.completedOnce = true
            saveRecord()
            onComplete?()
        }
        advance()
    }

    private func advance() {
        guard let step = machine.nextStep else { return }
        machine.stepStarted(step)
        onChange?(machine)
        switch step {
        case .runtime: runRuntime()
        case .ollama: runOllamaProbe()
        case .speech, .diarization, .summary: runPipeline(step)
        }
    }

    private func finish(_ step: SetupStep, error: String? = nil) {
        stopPolling()
        process = nil
        if let error {
            machine.failed(step, message: error)
        } else {
            record.markDone(step, appVersion: appVersion)
            saveRecord()
            machine.finished(step)
        }
        changed()
    }

    private func runRuntime() {
        guard let pipeline = Bundle.main.resourceURL?.appendingPathComponent("pipeline", isDirectory: true),
              let uv = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("uv") else {
            return finish(.runtime, error: "bundle incomplete")
        }
        let layout = self.layout
        Task { @MainActor in
            do {
                try await Task.detached(priority: .utility) { try Self.prepareRuntime(layout, pipeline: pipeline, uv: uv) }.value
            } catch {
                return self.finish(.runtime, error: error.localizedDescription)
            }
            guard case .running = self.machine.state(.runtime) else { return }  // cancelled meanwhile
            self.launch(.runtime, executable: layout.uvPath, arguments: layout.syncArguments,
                        environment: layout.syncEnvironment(Self.baseEnvironment()),
                        pollDirs: [layout.uvCacheDir, layout.pythonDir]) { [weak self] status in
                guard let self else { return }
                if status == 0 {
                    try? layout.marker(appPath: Bundle.main.bundlePath, appVersion: self.appVersion)
                        .write(to: layout.markerURL, options: .atomic)
                    self.finish(.runtime)
                } else {
                    self.finish(.runtime, error: self.process?.lastErrorLine ?? "uv sync exit \(status)")
                }
            }
        }
    }

    private func runPipeline(_ step: SetupStep) {
        guard let name = step.pipelineStep else { return }
        let pollDirs = step == .speech ? [layout.hubCacheDir] : []
        launch(step, executable: layout.cli, arguments: ["setup", "--only", name, "--json"],
               environment: pipelineEnvironment(), pollDirs: pollDirs,
               onLine: { [weak self] data in
                   guard let self, let line = SetupLine(data: data), line.step == name else { return }
                   switch line.status {
                   case "progress": self.machine.progress(step, fraction: line.fraction, detail: line.message.map(SetupProcess.clean))
                   case "error": self.lastError = line.message
                   default: return
                   }
                   self.onChange?(self.machine)
               }) { [weak self] status in
            guard let self else { return }
            let error = status == 0 ? nil : (self.lastError ?? self.process?.lastErrorLine ?? "exit \(status)")
            self.lastError = nil
            self.finish(step, error: error)
        }
    }

    private var lastError: String?

    private func runOllamaProbe() {
        probe = Task { @MainActor [weak self] in
            let availability = await SetupProbe.ollama()
            guard let self, !Task.isCancelled else { return }
            self.probe = nil
            self.machine.ollama(availability)
            self.changed()
        }
    }

    private func launch(_ step: SetupStep, executable: URL, arguments: [String], environment: [String: String],
                        pollDirs: [URL], onLine: @escaping @MainActor (Data) -> Void = { _ in },
                        completion: @escaping @MainActor (Int32) -> Void) {
        do {
            process = try SetupProcess(executable: executable, arguments: arguments, environment: environment,
                                       onLine: onLine, completion: completion)
        } catch {
            return finish(step, error: error.localizedDescription)
        }
        guard !pollDirs.isEmpty else { return }
        let expected = Double(step == .runtime ? Self.runtimeCacheBytes : step.downloadBytes)
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                let size = Double(SetupProbe.size(of: pollDirs))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, case .running = self.machine.state(step) else { return }
                        self.machine.progress(step, fraction: min(size / expected, 0.97),
                                              detail: step == .runtime ? self.process?.lastErrorLine : nil)
                        self.onChange?(self.machine)
                    }
                }
            }
        }
    }

    private func stopWork() {
        stopPolling()
        process?.stop()
        process = nil
        probe?.cancel()
        probe = nil
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    private func saveRecord() {
        try? FileManager.default.createDirectory(at: layout.root, withIntermediateDirectories: true)
        try? record.encoded().write(to: layout.stateURL, options: .atomic)
    }

    // MARK: - Files and environment

    /// uv's unpacked wheel cache + managed Python after a full sync (measured, for the progress bar).
    static let runtimeCacheBytes: Int64 = 1_600_000_000

    /// Copies the bundled pipeline source and uv into the runtime (the existing .venv is kept, so an update syncs
    /// only what changed) and removes the marker until the new environment is synced.
    nonisolated static func prepareRuntime(_ layout: RuntimeLayout, pipeline: URL, uv: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.pipelineDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: layout.markerURL)
        for entry in RuntimeLayout.pipelineEntries {
            let source = pipeline.appendingPathComponent(entry)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = layout.pipelineDir.appendingPathComponent(entry)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
        }
        try fm.createDirectory(at: layout.uvPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: layout.uvPath.path) { try fm.removeItem(at: layout.uvPath) }
        try fm.copyItem(at: uv, to: layout.uvPath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.uvPath.path)
        // The user approved this app once (Open Anyway); its copied tool must not ask Gatekeeper again.
        removexattr(layout.uvPath.path, "com.apple.quarantine", 0)
    }

    nonisolated static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    private func pipelineEnvironment() -> [String: String] {
        var env = Self.baseEnvironment()
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        env["MEETING_NOTES_OLLAMA_MODEL"] = Settings.summaryModel.model
        return DiarizeHelper.workerEnvironment(env, executableURL: Bundle.main.executableURL) {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}
