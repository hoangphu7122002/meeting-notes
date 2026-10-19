import Foundation
import MeetingNotesCore
import MeetingNotesUI

/// Processing jobs, one at a time, through `WorkerClient`. Never starts a job while recording.
@MainActor
final class JobQueue {
    struct Job: Equatable {
        let id: String
        var folder: URL
        /// Folder when the job was queued (the pipeline renames it in its last stage).
        let originalFolder: URL
        var title: String
        /// `"render"` for a cheap re-render (title change); nil = from the first missing stage.
        let from: String?
        /// Requested by the user (Retry, Create notes): skips the idle/power gate.
        let explicit: Bool
        var retried = false
    }

    /// Called after the visible state changed (throttled to a few times per second).
    var onChange: (() -> Void)?
    var onPartial: ((Job, String) -> Void)?
    var onFinished: ((Job, JobOutcome) -> Void)?

    private(set) var current: Job?
    private(set) var queued: [Job] = []
    private var snapshot: ProcessingSnapshot?
    private var waitingReason: String?
    private let worker = WorkerClient()
    private var gateTimer: Timer?
    private var publishScheduled = false
    private var doneEvent: WorkerEvent?
    private var lastError: String?
    private var sawJobEvent = false

    /// Set while recording or paused: jobs wait.
    var recordingActive = false {
        didSet { if !recordingActive && oldValue { pump() } }
    }

    init() {
        worker.onEvent = { [weak self] in self?.handle($0) }
        worker.onTerminate = { [weak self] in self?.workerTerminated() }
    }

    /// The job shown in the UI: the running one, or the next one while it waits.
    var displaySnapshot: ProcessingSnapshot? {
        if var snapshot {
            snapshot.queued = queued.count
            return snapshot
        }
        guard let next = queued.first, let waitingReason else { return nil }
        var waiting = ProcessingSnapshot(job: next.id, folder: next.folder.path, title: next.title)
        waiting.waiting = waitingReason
        waiting.queued = queued.count - 1
        return waiting
    }

    var count: Int { queued.count + (current == nil ? 0 : 1) }

    func contains(folder: URL) -> Bool {
        let key = MeetingFolders.key(folder)
        if let current, MeetingFolders.key(current.folder) == key { return true }
        return queued.contains { MeetingFolders.key($0.folder) == key }
    }

    func isCurrent(folder: URL) -> Bool {
        guard let current else { return false }
        return MeetingFolders.key(current.folder) == MeetingFolders.key(folder)
            || snapshot.map { MeetingFolders.key(URL(fileURLWithPath: $0.folder)) == MeetingFolders.key(folder) } == true
    }

    func enqueue(folder: URL, title: String, from: String? = nil, explicit: Bool) {
        if let index = queued.firstIndex(where: { MeetingFolders.key($0.folder) == MeetingFolders.key(folder) }) {
            if explicit { queued[index] = Job(id: queued[index].id, folder: folder, originalFolder: folder, title: title, from: from, explicit: true) }
        } else if !(current.map { MeetingFolders.key($0.folder) == MeetingFolders.key(folder) } ?? false) {
            queued.append(Job(id: UUID().uuidString, folder: folder, originalFolder: folder, title: title, from: from, explicit: explicit))
        }
        pump()
        publishNow()
    }

    /// Cancels the running job (cooperative) or removes the waiting one. The worker ignores a cancel
    /// that arrives before the job is marked busy, so it is re-sent a few times while the job runs.
    func cancelCurrent() {
        if let job = current {
            sendCancel(job: job.id, attempts: 4)
        } else if !queued.isEmpty {
            queued.removeFirst()
            waitingReason = nil
            pump()
            publishNow()
        }
    }

    /// Starts the waiting job now, ignoring the idle/power gate.
    func startWaitingNow() {
        guard current == nil, !queued.isEmpty else { return }
        let job = queued[0]
        queued[0] = Job(id: job.id, folder: job.folder, originalFolder: job.originalFolder, title: job.title, from: job.from, explicit: true)
        pump()
    }

    /// App quit: cancels a running job and stops the worker before returning.
    func shutdown() {
        gateTimer?.invalidate()
        gateTimer = nil
        worker.shutdown(cancelRunningJob: current != nil, wait: 1.5)
    }

    func retitleQueued(folder: URL, title: String) {
        guard let index = queued.firstIndex(where: { MeetingFolders.key($0.folder) == MeetingFolders.key(folder) }) else { return }
        queued[index].title = title
    }

    private func sendCancel(job: String, attempts: Int) {
        guard attempts > 0, current?.id == job else { return }
        try? worker.send(WorkerEvent.Command.cancel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.sendCancel(job: job, attempts: attempts - 1) }
        }
    }

    /// Re-checks the gate (settings changed).
    func pump() {
        guard current == nil, !recordingActive, let next = queued.first else {
            if queued.isEmpty { stopGateTimer() }
            return
        }
        let mode = Settings.createNotesMode
        if !next.explicit, !mode.canStart(onACPower: PowerState.onACPower, idleSeconds: PowerState.idleSeconds) {
            if mode == .whenIdle {
                waitingReason = tr(.waitIdlePlugged)
                startGateTimer()
            } else {
                waitingReason = tr(.waitManual)
                stopGateTimer()  // nothing changes by itself; "Create notes now" starts it
            }
            publishNow()
            return
        }
        stopGateTimer()
        waitingReason = nil
        queued.removeFirst()
        start(next, priority: next.explicit ? "low" : mode.priority)
    }

    // MARK: - Private

    private func start(_ job: Job, priority: String) {
        current = job
        snapshot = ProcessingSnapshot(job: job.id, folder: job.folder.path, title: job.title)
        doneEvent = nil
        lastError = nil
        sawJobEvent = false
        do {
            try worker.ensureRunning(priority: priority, model: Settings.summaryModel.model)
            worker.setLogFile(job.folder.appendingPathComponent("pipeline.app.log"),
                              header: "\n=== \(Date()) meeting-notes worker job \(job.id)\(job.from.map { " from \($0)" } ?? "") ===\n")
            try worker.send(WorkerEvent.Command.process(job: job.id, folder: job.folder.path, from: job.from))
        } catch {
            finish(.failed(message: error.localizedDescription))
            return
        }
        publishNow()
    }

    private func handle(_ event: WorkerEvent) {
        if case .worker(let status, _) = event {
            if status == "exit" { worker.markExiting() }
            return
        }
        guard let job = current, event.job == nil || event.job == job.id else { return }
        sawJobEvent = true
        switch event {
        case .jobEnd(_, let exit):
            finish(JobOutcome.from(exit: exit, done: doneEvent, lastError: lastError))
            return
        case .done(_, let folder, _, _, _):
            doneEvent = event
            current?.folder = URL(fileURLWithPath: folder, isDirectory: true)
        case .error(_, let message):
            lastError = message
        case .partial(_, let folder, let notes):
            current?.folder = URL(fileURLWithPath: folder, isDirectory: true)
            if let current { onPartial?(current, notes) }
        default:
            break
        }
        if snapshot?.apply(event) == true { schedulePublish() }
    }

    private func workerTerminated() {
        guard let job = current else {
            pump()
            return
        }
        if !sawJobEvent && !job.retried {
            // The worker was exiting when the job arrived: run it again on a fresh worker.
            var again = job
            again.retried = true
            current = nil
            snapshot = nil
            queued.insert(again, at: 0)
            pump()
        } else {
            finish(.failed(message: lastError ?? tr(.errWorkerStopped)))
        }
    }

    private func finish(_ outcome: JobOutcome) {
        guard let job = current else { return }
        current = nil
        snapshot = nil
        worker.setLogFile(nil)
        onFinished?(job, outcome)
        publishNow()
        pump()
    }

    private func startGateTimer() {
        guard gateTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        gateTimer = timer
    }

    private func stopGateTimer() {
        gateTimer?.invalidate()
        gateTimer = nil
    }

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                self?.publishScheduled = false
                self?.onChange?()
            }
        }
    }

    private func publishNow() { onChange?() }
}
