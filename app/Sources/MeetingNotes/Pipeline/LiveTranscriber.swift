import Foundation
import MeetingNotesCore
import MeetingNotesUI

/// Opt-in live transcript of the recording in progress: one long `live` job on the shared worker.
///
/// The worker is spawned with the same priority/model key the Stop-time process job uses, so that job
/// reuses the warm worker (models loaded). `live` is sent only when the worker's `ready` event lists the
/// "live" feature; an older worker (no feature, or `unknown command`) makes live give up quietly.
/// If the worker dies while live is active it is respawned and `live` resent with the same job id
/// (the worker resumes; repeated chunks are deduplicated by `LiveTranscript`).
@MainActor
final class LiveTranscriber {
    /// The transcript to show; nil = live off or given up (hidden).
    var onChange: ((LiveTranscript?) -> Void)?

    static let jobPrefix = "live-"
    /// Same key `JobQueue` uses for "right away" and explicit jobs.
    static let priority = "low"
    static let maxRestarts = 3
    static let readyTimeout: TimeInterval = 120

    private enum Phase { case idle, waitingReady, running, restarting, stopping }

    private let worker: WorkerClient
    private var phase = Phase.idle
    private var job: String?
    private var folder: URL?
    private var restarts = 0
    private var readyTimer: DispatchWorkItem?
    private(set) var transcript: LiveTranscript? {
        didSet { if transcript != oldValue { onChange?(transcript) } }
    }

    init(worker: WorkerClient) {
        self.worker = worker
    }

    /// Live is requested and not stopped (waiting for the worker, running or restarting).
    var isActive: Bool { phase == .waitingReady || phase == .running || phase == .restarting }

    static func isLiveJob(_ job: String?) -> Bool { job?.hasPrefix(jobPrefix) == true }

    /// Starts live transcription of a recording folder (its provisional meeting.json must exist).
    func start(folder: URL) {
        if isActive { stop(hide: false) }
        let job = Self.jobPrefix + UUID().uuidString
        self.job = job
        self.folder = folder
        restarts = 0
        transcript = LiveTranscript(job: job)
        launch()
    }

    /// Asks the live job to finish (Stop, discard, setting turned off). `hide` also clears the transcript.
    func stop(hide: Bool = false) {
        cancelReadyTimer()
        if phase == .running, let job {
            try? worker.send(WorkerEvent.Command.liveStop(job: job))
            phase = .stopping
        } else if phase != .stopping {
            phase = .idle
        }
        if hide { transcript = nil }
    }

    /// A new recording: forget the previous transcript.
    func clear() {
        if isActive { stop() }
        transcript = nil
    }

    // MARK: - Worker events (routed by the controller)

    func handle(_ event: WorkerEvent) {
        switch event {
        case let .worker(status, message, _):
            switch status {
            case "ready":
                if phase == .waitingReady { sendLive() }
            case "exit":
                worker.markExiting()
            case "error":
                // An older worker rejects the command: `unknown command 'live'`.
                if phase == .running, let message, message.contains("unknown command"), message.contains("live") { giveUp() }
            default:
                break
            }
        case .liveSegment, .liveStatus:
            guard event.job == job, var current = transcript else { return }
            if current.apply(event) { transcript = current }
        case let .jobEnd(eventJob, exit):
            guard eventJob == job else { return }
            cancelReadyTimer()
            let wasStopping = phase == .stopping
            phase = .idle
            if exit != 0 && !wasStopping { giveUp() }
        default:
            break
        }
    }

    /// The worker process ended (crash, idle exit, quit). Resumes live if it was running.
    func workerTerminated() {
        guard phase == .running || phase == .waitingReady else {
            if phase == .stopping { phase = .idle }
            return
        }
        cancelReadyTimer()
        restarts += 1
        guard restarts <= Self.maxRestarts else { return giveUp() }
        phase = .restarting
        let job = self.job
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(restarts)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .restarting, self.job == job else { return }
                self.launch()
            }
        }
    }

    // MARK: - Private

    private func launch() {
        guard let folder, let job else { return }
        phase = .waitingReady
        do {
            try worker.ensureRunning(priority: Self.priority, model: Settings.summaryModel.model)
        } catch {
            return giveUp()
        }
        worker.setLogFile(folder.appendingPathComponent("pipeline.app.log"),
                          header: "\n=== \(Date()) meeting-notes worker live job \(job) ===\n")
        if worker.features != nil {
            sendLive()  // warm worker: its ready event was already seen
        } else {
            startReadyTimer()
        }
    }

    private func sendLive() {
        cancelReadyTimer()
        guard let job, let folder else { return }
        guard worker.features?.contains("live") == true else { return giveUp() }
        do {
            try worker.send(WorkerEvent.Command.live(job: job, folder: folder.path))
            phase = .running
        } catch {
            phase = .running
            workerTerminated()  // treat as a dead worker: respawn with backoff
        }
    }

    /// Live is not available or keeps failing: hide it; the Stop-time notes are unaffected.
    private func giveUp() {
        cancelReadyTimer()
        phase = .idle
        transcript = nil
    }

    private func startReadyTimer() {
        cancelReadyTimer()
        let job = self.job
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .waitingReady, self.job == job else { return }
                self.giveUp()
            }
        }
        readyTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyTimeout, execute: timer)
    }

    private func cancelReadyTimer() {
        readyTimer?.cancel()
        readyTimer = nil
    }
}
