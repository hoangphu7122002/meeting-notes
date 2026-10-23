import AppKit
import MeetingNotesCore
import MeetingNotesUI

/// Central app state: recorder, processing queue, meeting detection, hotkeys, state.json.
/// Everything the views show lives in `state`; the views call back through `AppCommands`.
@MainActor
final class AppController {
    let state = AppState()

    // Forwarders keep the controller code close to the state it owns.
    var pill: PillState {
        get { state.pill }
        set { if state.pill != newValue { state.pill = newValue } }
    }
    var machine: RecorderMachine {
        get { state.machine }
        set { if state.machine != newValue { state.machine = newValue } }
    }
    var titleDraft: String {
        get { state.titleDraft }
        set { if state.titleDraft != newValue { state.titleDraft = newValue } }
    }
    var systemAudio: SystemAudioHealth {
        get { state.systemAudio }
        set { if state.systemAudio != newValue { state.systemAudio = newValue } }
    }
    var micAvailable: Bool {
        get { state.micAvailable }
        set { if state.micAvailable != newValue { state.micAvailable = newValue } }
    }
    var recordingWarnings: [String] {
        get { state.recordingWarnings }
        set { if state.recordingWarnings != newValue { state.recordingWarnings = newValue } }
    }
    var detectedApp: MeetingDetector.App? {
        didSet { if state.detectedAppName != detectedApp?.name { state.detectedAppName = detectedApp?.name } }
    }
    var permissionsNeedAttention = false
    var lastResult: ReadyInfo? {
        get { state.lastResult }
        set { if state.lastResult != newValue { state.lastResult = newValue } }
    }
    var hotkey: HotKeySpec? {
        get { state.hotkey }
        set { state.hotkey = newValue }
    }
    var pauseHotkey: HotKeySpec? {
        get { state.pauseHotkey }
        set { state.pauseHotkey = newValue }
    }
    var hotkeyError: String? {
        get { state.hotkeyError }
        set { state.hotkeyError = newValue }
    }
    var notesDir: URL {
        get { state.notesDir }
        set { state.notesDir = newValue }
    }

    var clock: ClockModel { state.clock }
    var levels: LevelModel { state.levels }
    /// The pipeline worker, shared by processing jobs and the live transcript.
    let worker = WorkerClient()
    let jobs: JobQueue
    let live: LiveTranscriber
    /// Pending delayed start of the live transcript.
    var liveStartWork: DispatchWorkItem?
    let detector = MeetingDetector()
    let notifier = Notifier()
    weak var ui: UIPresenter?

    var session: RecordingSession?
    var error: PillError?
    var readyShown: ReadyInfo?
    var readyTimer: DispatchWorkItem?
    var ticker: Timer?
    var silence = SilenceTracker(limit: 0)
    var systemSilence = SilenceTracker(limit: 10)
    var autoStop: AutoStopPrompt?
    var pendingStart: (app: MeetingDetector.App?, source: ActionSource)?
    var pendingTitles: [String: String] = [:]  // job id -> user title to apply after the job
    var titleTargetKey: String?
    var hotKeys: [HotKey] = []
    var lastHotkeyToggle = Date.distantPast
    var lastStateKey = ""
    var lastStateWrite = Date.distantPast
    let stateQueue = DispatchQueue(label: "meetingnotes.state", qos: .utility)
    var idlePillTimer: DispatchWorkItem?
    /// The running stop/discard work; awaited on quit so WAV files and meeting.json are finalized.
    var finishTask: Task<Void, Never>?
    /// Surfaces currently showing meters ("pill", "window"); levels are sampled only for them.
    var meterConsumers: Set<String> = []
    var levelTimer: Timer?
    var editTarget: TitleTarget?
    /// First-run setup of the packaged app (nil in dev and shared installs).
    var setupRunner: SetupRunner?
    /// Final folders of finished jobs, for titles committed after their job ended.
    var finishedJobs: [String: (folder: URL, hasNotes: Bool)] = [:]

    var recordingFolder: URL? { session?.folder }
    var isCapturing: Bool { machine.phase != .idle }

    init() {
        jobs = JobQueue(worker: worker)
        live = LiveTranscriber(worker: worker)
    }

    // MARK: - Lifecycle

    func launch() {
        setupWorkerRouting()
        notifier.setup()
        notifier.onOpenNotes = { [weak self] folder in self?.ui?.openNotes(folder) }
        jobs.onChange = { [weak self] in self?.refresh() }
        jobs.onPartial = { [weak self] job, _ in self?.ui?.reloadNotes(job.folder) }
        jobs.onFinished = { [weak self] job, outcome in self?.jobFinished(job, outcome) }
        detector.onStart = { [weak self] app in MainActor.assumeIsolated { self?.meetingAppStarted(app) } }
        detector.onStop = { [weak self] app in MainActor.assumeIsolated { self?.meetingAppStopped(app) } }
        detector.onWatchedAppEnded = { [weak self] app in MainActor.assumeIsolated { self?.watchedAppEnded(app) } }
        if Settings.detectionEnabled { detector.start() }
        registerHotKeys()
        _ = refreshPermissions()
        if let folder = Settings.lastNotesFolder, FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.md").path) {
            lastResult = ReadyInfo(folder: folder.path, title: MeetingFolders.title(of: folder),
                                   notesPath: folder.appendingPathComponent("notes.md").path)
        }
        scheduleIdlePillReshow()
        launchSetup()
        refresh()
    }

    /// Finalizes an active recording (kept, not processed) and stops the worker.
    func prepareForQuit() async {
        for _ in 0..<50 where machine.phase == .starting {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if let session, machine.phase.isActive {
            stopTicker()
            _ = await session.stop()
            self.session = nil
            machine.apply(.finished)
        }
        await finishTask?.value
        shutdownNow()
    }

    func shutdownNow() {
        jobs.shutdown()
        detector.stop()
        writeStateFile(AppStatusSnapshot(state: "not_running"), sync: true)
    }

    /// Re-reads permission state (app activation, main window key, "Kiểm tra"; never polled).
    /// When the CoreGraphics preflight says no, ScreenCaptureKit is asked in the background and the
    /// state is updated from its answer (the preflight can stay false on macOS 15 while capture works).
    /// Returns true when a previously complete setup regressed.
    @discardableResult
    func refreshPermissions() -> Bool {
        let regressed = applyPermissions()
        if !Permissions.screenCapturePreflight { verifyScreenCapture() }
        return regressed
    }

    /// Last ScreenCaptureKit answer: true = capture works, false = TCC declined, nil = not known.
    var screenCaptureVerified: Bool?
    private var screenCaptureProbe: Task<Void, Never>?

    private func verifyScreenCapture() {
        guard screenCaptureProbe == nil else { return }
        screenCaptureProbe = Task { @MainActor [weak self] in
            let probe = await Permissions.probeScreenCapture()
            guard let self else { return }
            self.screenCaptureProbe = nil
            if probe.shareableOK {
                self.screenCaptureVerified = true
            } else if probe.declined {
                self.screenCaptureVerified = false
            }
            self.applyPermissions()
        }
    }

    @discardableResult
    private func applyPermissions() -> Bool {
        let microphone = Permissions.microphone
        let screenGranted = Permissions.screenCapturePreflight || screenCaptureVerified == true
        let screen: PermissionStatus = screenGranted ? .granted : .denied
        if state.microphone != microphone { state.microphone = microphone }
        if state.screenCapture != screen { state.screenCapture = screen }
        notifier.status { [weak self] status in
            guard let self, self.state.notifications != status else { return }
            self.state.notifications = status
        }
        let granted = microphone == .granted && screen == .granted
        let regressed = !granted && Settings.permissionsWereGranted
        if granted { Settings.permissionsWereGranted = true }
        if permissionsNeedAttention != !granted {
            permissionsNeedAttention = !granted
            refresh()
        }
        return regressed
    }
}
