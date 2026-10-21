import AppKit
import MeetingNotesCore
import MeetingNotesUI

/// UI surfaces the controller drives (implemented by `UIHub`).
@MainActor
protocol UIPresenter: AnyObject {
    func showToast(_ text: String)
    func pillStateChanged()
    func showDetectionCard(_ app: MeetingDetector.App?)
    func showAutoStopCard(_ prompt: AutoStopPrompt?)
    func openNotes(_ folder: URL)
    func notesFolderMoved(from: URL, to: URL)
    func reloadNotes(_ folder: URL)
    func showMainWindow()
    func showSettings()
    func showControls(expand: Bool)
    func hidePill()
    func endTitleEditing()
    func languageChanged()
    func setShowInDock(_ show: Bool)
    func resetPillPosition()
    var isPillExpanded: Bool { get }
    var isEditingTitle: Bool { get }
    /// The main window is on screen (recents are only read while it is).
    var isMainWindowVisible: Bool { get }
}

/// Central app state: recorder, processing queue, meeting detection, hotkeys, state.json.
/// Everything the views show lives in `state`; the views call back through `AppCommands`.
@MainActor
final class AppController {
    let state = AppState()

    // Forwarders keep the controller code close to the state it owns.
    private(set) var pill: PillState {
        get { state.pill }
        set { if state.pill != newValue { state.pill = newValue } }
    }
    private(set) var machine: RecorderMachine {
        get { state.machine }
        set { if state.machine != newValue { state.machine = newValue } }
    }
    var titleDraft: String {
        get { state.titleDraft }
        set { if state.titleDraft != newValue { state.titleDraft = newValue } }
    }
    private(set) var systemAudio: SystemAudioHealth {
        get { state.systemAudio }
        set { if state.systemAudio != newValue { state.systemAudio = newValue } }
    }
    private(set) var micAvailable: Bool {
        get { state.micAvailable }
        set { if state.micAvailable != newValue { state.micAvailable = newValue } }
    }
    private(set) var recordingWarnings: [String] {
        get { state.recordingWarnings }
        set { if state.recordingWarnings != newValue { state.recordingWarnings = newValue } }
    }
    private(set) var detectedApp: MeetingDetector.App? {
        didSet { if state.detectedAppName != detectedApp?.name { state.detectedAppName = detectedApp?.name } }
    }
    private(set) var permissionsNeedAttention = false
    private(set) var lastResult: ReadyInfo? {
        get { state.lastResult }
        set { if state.lastResult != newValue { state.lastResult = newValue } }
    }
    private(set) var hotkey: HotKeySpec? {
        get { state.hotkey }
        set { state.hotkey = newValue }
    }
    private(set) var pauseHotkey: HotKeySpec? {
        get { state.pauseHotkey }
        set { state.pauseHotkey = newValue }
    }
    private(set) var hotkeyError: String? {
        get { state.hotkeyError }
        set { state.hotkeyError = newValue }
    }
    private(set) var notesDir: URL {
        get { state.notesDir }
        set { state.notesDir = newValue }
    }

    var clock: ClockModel { state.clock }
    var levels: LevelModel { state.levels }
    let jobs = JobQueue()
    let detector = MeetingDetector()
    let notifier = Notifier()
    weak var ui: UIPresenter?

    private var session: RecordingSession?
    private var error: PillError?
    private var readyShown: ReadyInfo?
    private var readyTimer: DispatchWorkItem?
    private var ticker: Timer?
    private var silence = SilenceTracker(limit: 0)
    private var systemSilence = SilenceTracker(limit: 10)
    private var autoStop: AutoStopPrompt?
    private var pendingStart: (app: MeetingDetector.App?, source: ActionSource)?
    private var pendingTitles: [String: String] = [:]  // job id -> user title to apply after the job
    private var titleTargetKey: String?
    private var hotKeys: [HotKey] = []
    private var lastHotkeyToggle = Date.distantPast
    private var lastStateKey = ""
    private var lastStateWrite = Date.distantPast
    private let stateQueue = DispatchQueue(label: "meetingnotes.state", qos: .utility)
    private var idlePillTimer: DispatchWorkItem?
    /// The running stop/discard work; awaited on quit so WAV files and meeting.json are finalized.
    private var finishTask: Task<Void, Never>?

    var recordingFolder: URL? { session?.folder }
    var isCapturing: Bool { machine.phase != .idle }

    // MARK: - Lifecycle

    func launch() {
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
    private var screenCaptureVerified: Bool?
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

    // MARK: - Recorder commands

    /// Single entry point for start/stop/pause/resume/discard from every surface.
    func perform(_ command: RecorderCommand, source: ActionSource) {
        if source == .hotkey, command == .toggleRecording {
            guard Date().timeIntervalSince(lastHotkeyToggle) > 0.8 else { return }
            lastHotkeyToggle = Date()
        }
        if command == .stop || command == .toggleRecording, ui?.isEditingTitle == true {
            ui?.endTitleEditing()  // commits the title being typed before the recording ends
        }
        let outcome = machine.handle(command)
        var toast = outcome.toast.map { tr($0) }
        switch outcome.effect {
        case .startCapture:
            toast = nil  // "Recording started" once capture runs
            jobs.recordingActive = true  // no new job may start while the capture starts
            beginRecording(source: source)
        case .stopCapture:
            let manual = Settings.createNotesMode == .manual
            if manual { toast = tr(.toastStoppedSaved) }
            if source == .autoStop { toast = tr(manual ? .toastMeetingEndedSaved : .toastMeetingEndedCreating) }
            finishRecording()
        case .pauseCapture:
            session?.pause()
            dismissAutoStop()
            tick()
        case .resumeCapture:
            session?.resume()
            silence.reset()
            systemSilence.reset()
        case .discardCapture:
            discardRecording()
        case .none:
            break
        }
        if let toast, source.showsToast { ui?.showToast(toast) }
        refresh()
    }

    func startRecording(source: ActionSource) { startRecording(app: nil, source: source) }

    func startRecording(app: MeetingDetector.App?, source: ActionSource) {
        if machine.phase == .idle { pendingStart = (app, source) }
        perform(.start, source: source)
    }

    private func beginRecording(source: ActionSource) {
        let app = pendingStart?.app ?? detectedApp ?? detector.activeApps.first
        pendingStart = nil
        let options = RecordingSession.Options.from(appHint: app?.name)
        let dir = notesDir
        error = nil
        hideReady()
        detectedApp = nil
        ui?.showDetectionCard(nil)
        Task { @MainActor in
            var folder: URL?
            do {
                let created = try MeetingFolders.create(in: dir)
                folder = created
                let session = try await RecordingSession.start(folder: created, options: options)
                self.session = session
                session.onWarningsChanged = { [weak self] warnings in self?.recordingWarnings = warnings }
                recordingWarnings = session.warnings
                machine.apply(.started)
                titleDraft = session.title
                titleTargetKey = MeetingFolders.key(created)
                jobs.recordingActive = true
                systemAudio = session.systemAudioAvailable ? .ok : .notPermitted
                if session.systemAudioAvailable { screenCaptureVerified = true }
                micAvailable = session.micWriter != nil
                silence = SilenceTracker(thresholdDB: -50, limit: Double(Settings.autoStopSilenceMinutes * 60))
                systemSilence = SilenceTracker(thresholdDB: -50, limit: 10)
                detector.watch(Settings.autoStopOnCallEnd ? app : nil)
                clock.elapsed = Format.elapsed(0)
                startTicker()
                if source.showsToast { ui?.showToast(tr(.toastRecordingStarted)) }
            } catch {
                if let folder { MeetingFolders.removeIfEmpty(folder) }
                machine.apply(.startFailed)
                jobs.recordingActive = false
                let micDenied = Permissions.microphone == .denied
                self.error = PillError(tr(.errCouldNotStart, Format.clip(error.localizedDescription, 120)),
                                       action: micDenied ? .openSettings(.microphone) : .none)
                if source.showsToast { ui?.showToast(tr(.toastCouldNotStart)) }
            }
            refreshPermissions()
            refresh()
        }
    }

    private func finishRecording() {
        guard let session else {
            machine.apply(.finished)
            return
        }
        stopTicker()
        dismissAutoStop()
        detector.watch(nil)
        finishTask = Task { @MainActor in
            let result = await session.stop()
            self.session = nil
            machine.apply(.finished)
            resetLevels()
            recordingWarnings = []
            if !result.hasAudio {
                error = PillError(tr(.errNoAudio),
                                  action: permissionsNeedAttention ? .openSettings(Permissions.microphone == .granted ? .screenCapture : .microphone) : .none)
            } else if Settings.createNotesMode == .manual {
                showReady(ReadyInfo(folder: result.folder.path, title: result.title, notesPath: nil))
            } else {
                jobs.enqueue(folder: result.folder, title: result.title, explicit: false)
            }
            jobs.recordingActive = false
            detector.rescan()
            refresh()
        }
    }

    private func discardRecording() {
        guard let session else {
            machine.apply(.finished)
            return
        }
        stopTicker()
        dismissAutoStop()
        detector.watch(nil)
        finishTask = Task { @MainActor in
            do {
                try await session.discard()
                ui?.showToast(tr(.toastDiscarded))
            } catch {
                self.error = PillError(tr(.errCouldNotDelete, error.localizedDescription))
            }
            self.session = nil
            machine.apply(.finished)
            resetLevels()
            recordingWarnings = []
            jobs.recordingActive = false
            detector.rescan()
            refresh()
        }
    }

    // MARK: - Ticks (1 Hz while recording or paused)

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let session else { return }
        let elapsed = Format.elapsed(session.recordedSeconds)
        if clock.elapsed != elapsed { clock.elapsed = elapsed }
        guard machine.phase == .recording else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let micDB = session.micWriter?.meter.takeWindowMaxDB() ?? LevelMeter.floorDB
        let systemDB = session.systemWriter?.meter.takeWindowMaxDB() ?? LevelMeter.floorDB
        var health = SystemAudioHealth.notPermitted
        if session.systemAudioAvailable {
            _ = systemSilence.update(now: now, levelDB: systemDB)
            health = systemSilence.silentDuration(now: now) >= 10 ? .silent : .ok
        }
        if systemAudio != health { systemAudio = health }

        if autoStop == nil, silence.update(now: now, levelDB: max(micDB, systemDB)) {
            promptAutoStop(AutoStopPrompt(reason: tr(.autoStopSilence, Settings.autoStopSilenceMinutes), remaining: 60, appEnded: false))
        } else if var prompt = autoStop {
            prompt.remaining -= 1
            if prompt.remaining <= 0 {
                dismissAutoStop()
                perform(.stop, source: .autoStop)
            } else {
                autoStop = prompt
                ui?.showAutoStopCard(prompt)
            }
        }
    }

    /// Surfaces currently showing meters ("pill", "window"); levels are sampled only for them.
    private var meterConsumers: Set<String> = []
    private var levelTimer: Timer?

    /// A meter surface became visible or hidden.
    func setMeterVisible(_ id: String, _ visible: Bool) {
        if visible { meterConsumers.insert(id) } else { meterConsumers.remove(id) }
        updateLevelTimer()
    }

    /// <= 12 fps, only while recording and at least one meter is on screen.
    private func updateLevelTimer() {
        let needed = machine.phase == .recording && !meterConsumers.isEmpty
        if needed, levelTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampleLevels() }
            }
            timer.tolerance = 0.03
            RunLoop.main.add(timer, forMode: .common)
            levelTimer = timer
        } else if !needed, let timer = levelTimer {
            timer.invalidate()
            levelTimer = nil
            sampleLevels()  // resets to 0 when not recording
        }
    }

    private func sampleLevels() {
        guard let session, machine.phase == .recording else {
            resetLevels()
            return
        }
        let me = LevelMeter.displayValue(session.micWriter?.meter.level() ?? 0)
        let them = LevelMeter.displayValue(session.systemWriter?.meter.level() ?? 0)
        if abs(levels.me - me) > 0.01 { levels.me = me }
        if abs(levels.them - them) > 0.01 { levels.them = them }
    }

    private func resetLevels() {
        if levels.me != 0 { levels.me = 0 }
        if levels.them != 0 { levels.them = 0 }
    }

    // MARK: - Auto-stop

    private func promptAutoStop(_ prompt: AutoStopPrompt) {
        autoStop = prompt
        ui?.showAutoStopCard(prompt)
    }

    private func dismissAutoStop() {
        guard autoStop != nil else { return }
        autoStop = nil
        ui?.showAutoStopCard(nil)
    }

    func autoStopNow() {
        dismissAutoStop()
        perform(.stop, source: .autoStop)
    }

    func keepRecording() {
        dismissAutoStop()
        silence.reset()
    }

    private func watchedAppEnded(_ app: MeetingDetector.App) {
        guard machine.phase == .recording, autoStop == nil, Settings.autoStopOnCallEnd else { return }
        promptAutoStop(AutoStopPrompt(reason: tr(.autoStopAppEnded, app.name), remaining: 60, appEnded: true))
    }

    // MARK: - Meeting detection

    private func meetingAppStarted(_ app: MeetingDetector.App) {
        guard Settings.detectionEnabled, machine.phase == .idle else { return }
        if let until = Settings.detectionSnoozeUntil, until > Date() { return }
        detectedApp = app
        ui?.showDetectionCard(app)
    }

    private func meetingAppStopped(_ app: MeetingDetector.App) {
        guard detectedApp == app else { return }
        detectedApp = nil
        ui?.showDetectionCard(nil)
    }

    func detectionStart() {
        let app = detectedApp
        ui?.showDetectionCard(nil)
        startRecording(app: app, source: .detection)
    }

    func detectionDismiss(snooze: Bool) {
        if snooze { Settings.detectionSnoozeUntil = Date().addingTimeInterval(3600) }
        detectedApp = nil
        ui?.showDetectionCard(nil)
    }

    func setDetectionEnabled(_ enabled: Bool) {
        Settings.detectionEnabled = enabled
        if enabled {
            detector.start()
        } else {
            detector.stop()
            detectionDismiss(snooze: false)
        }
    }

    // MARK: - Processing

    func retry(folder: URL) {
        error = nil
        jobs.enqueue(folder: folder, title: MeetingFolders.title(of: folder), explicit: true)
        refresh()
    }

    func createNotes(folder: URL) {
        hideReady()
        jobs.enqueue(folder: folder, title: MeetingFolders.title(of: folder), explicit: true)
        refresh()
    }

    func cancelProcessing() {
        if jobs.current != nil { ui?.showToast(tr(.toastCancelling)) }
        jobs.cancelCurrent()
    }

    func processWaitingNow() { jobs.startWaitingNow() }

    private func jobFinished(_ job: JobQueue.Job, _ outcome: JobOutcome) {
        finishedJobs[job.id] = (job.folder, { if case .done = outcome { return true } else { return false } }())
        if case .done = outcome {} else if let pending = pendingTitles.removeValue(forKey: job.id) {
            applyTitle(pending, folder: job.folder)  // failed or cancelled: keep the user's title for the retry
        }
        switch outcome {
        case let .done(folder, notes, title):
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            var finalTitle = title ?? job.title
            if let pending = pendingTitles.removeValue(forKey: job.id), pending != finalTitle {
                finalTitle = pending
                applyTitle(pending, folder: url)
                jobs.enqueue(folder: url, title: pending, from: "render", explicit: true)
            }
            let info = ReadyInfo(folder: folder, title: finalTitle, notesPath: notes)
            lastResult = info
            Settings.lastNotesFolder = url
            if MeetingFolders.key(job.originalFolder) != MeetingFolders.key(url) {
                ui?.notesFolderMoved(from: job.originalFolder, to: url)
            }
            ui?.reloadNotes(url)
            if job.from == "render" {
                if let shown = readyShown, MeetingFolders.key(URL(fileURLWithPath: shown.folder)) == MeetingFolders.key(job.originalFolder) {
                    readyShown = info
                }
            } else {
                showReady(info)
                notifier.notesReady(title: finalTitle, folder: url)
            }
        case let .failed(message):
            error = PillError(tr(.errProcessingFailed, Format.clip(message, 160)), action: .retry(folder: job.folder.path))
        case .cancelled:
            ui?.showToast(tr(.toastProcessingCancelled))
        }
        refresh()
    }

    private func showReady(_ info: ReadyInfo) {
        readyShown = info
        scheduleReadyCollapse(after: 6)
    }

    private func scheduleReadyCollapse(after seconds: Double) {
        readyTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.readyShown != nil else { return }
                if self.ui?.isPillExpanded == true {
                    self.scheduleReadyCollapse(after: 3)
                } else {
                    self.hideReady()
                    self.refresh()
                }
            }
        }
        readyTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func hideReady() {
        readyTimer?.cancel()
        readyTimer = nil
        readyShown = nil
    }

    func dismissError() {
        error = nil
        refresh()
    }

    func dismissReady() {
        hideReady()
        refresh()
    }

    func performErrorAction() {
        guard case .error(let pillError) = pill else { return }
        switch pillError.action {
        case .retry(let folder): retry(folder: URL(fileURLWithPath: folder, isDirectory: true))
        case .openSettings(let kind):
            Permissions.openSettings(kind)
            ui?.showMainWindow()
            dismissError()
        case .none: dismissError()
        }
    }

    // MARK: - Title

    /// Commits `titleDraft` to the meeting the pill currently shows.
    /// What the title field edits; captured when editing begins so a state change mid-edit
    /// (job finished, next job started) cannot redirect the title to another meeting.
    private enum TitleTarget {
        case session(RecordingSession)
        case job(id: String, folder: URL)
        case ready(ReadyInfo)
    }

    private var editTarget: TitleTarget?
    /// Final folders of finished jobs, for titles committed after their job ended.
    private var finishedJobs: [String: (folder: URL, hasNotes: Bool)] = [:]

    func titleEditingBegan() { editTarget = currentTitleTarget() }

    private func currentTitleTarget() -> TitleTarget? {
        switch pill {
        case .starting, .recording, .paused, .stopping:
            return session.map { .session($0) }
        case .processing(let snapshot):
            return .job(id: snapshot.job, folder: URL(fileURLWithPath: snapshot.folder, isDirectory: true))
        case .ready(let info):
            return .ready(info)
        default:
            return nil
        }
    }

    /// Commits `titleDraft` to the meeting that was shown when editing began.
    func commitTitle() {
        let target = editTarget ?? currentTitleTarget()
        editTarget = nil
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let target else {
            syncTitleDraft(force: true)
            return
        }
        switch target {
        case .session(let recording):
            recording.setTitle(title)
        case let .job(id, folder):
            if jobs.current?.id == id {
                pendingTitles[id] = title  // applied after the job, then re-rendered
            } else if let finished = finishedJobs[id] {
                applyTitle(title, folder: finished.folder)
                if finished.hasNotes { jobs.enqueue(folder: finished.folder, title: title, from: "render", explicit: true) }
            } else {
                applyTitle(title, folder: folder)  // not started yet: the pipeline reads it
                jobs.retitleQueued(folder: folder, title: title)
            }
        case .ready(let info):
            guard title != info.title else { break }
            let folder = URL(fileURLWithPath: info.folder, isDirectory: true)
            applyTitle(title, folder: folder)
            if readyShown?.folder == info.folder { readyShown?.title = title }
            if lastResult?.folder == info.folder { lastResult?.title = title }
            if info.hasNotes {
                jobs.enqueue(folder: folder, title: title, from: "render", explicit: true)
            }
        }
        writeState()
        refresh()
        reloadRecents()
    }

    private func applyTitle(_ title: String, folder: URL) {
        let url = folder.appendingPathComponent("meeting.json")
        do {
            let data = try MeetingRecord.updatingTitle(Data(contentsOf: url), title: title)
            try data.write(to: url, options: .atomic)
        } catch {
            ui?.showToast(tr(.toastCouldNotRename, error.localizedDescription))
        }
    }

    private func titleTarget() -> (key: String, title: String)? {
        switch pill {
        case .starting, .recording, .paused, .stopping:
            guard let session else { return nil }
            return (MeetingFolders.key(session.folder), session.title)
        case .processing(let snapshot):
            return ("job:" + snapshot.job, pendingTitles[snapshot.job] ?? snapshot.title)
        case .ready(let info):
            return (MeetingFolders.key(URL(fileURLWithPath: info.folder)), info.title)
        default:
            return nil
        }
    }

    private func syncTitleDraft(force: Bool = false) {
        guard let target = titleTarget() else {
            titleTargetKey = nil
            return
        }
        if force || (target.key != titleTargetKey && ui?.isEditingTitle != true) {
            titleTargetKey = target.key
            if titleDraft != target.title { titleDraft = target.title }
        }
    }

    // MARK: - Derived state

    /// Recomputes the pill state; cheap, called after every change.
    func refresh() {
        let next = PillState.derive(phase: machine.phase, error: error, processing: jobs.displaySnapshot, ready: readyShown,
                                    permissionsNeedAttention: permissionsNeedAttention)
        let kindChanged = next.name != pill.name || next.isIdle != pill.isIdle
        if next != pill { pill = next }
        let jobsActive = jobs.count > 0
        if state.jobsActive != jobsActive { state.jobsActive = jobsActive }
        syncTitleDraft()
        writeState()
        updateLevelTimer()
        if kindChanged { reloadRecents() }
        ui?.pillStateChanged()
    }

    /// Re-reads the recent meetings list, only while the main window shows it.
    func reloadRecents() {
        guard ui?.isMainWindowVisible == true else { return }
        let list = recents()
        if state.recents != list { state.recents = list }
    }

    var processingSnapshot: ProcessingSnapshot? {
        if case .processing(let snapshot) = pill { return snapshot }
        return jobs.displaySnapshot
    }

    func recents() -> [RecentMeeting] {
        let snapshot = jobs.displaySnapshot
        let context = Recents.Context(
            recording: session?.folder,
            processing: snapshot?.waiting == nil ? snapshot.map { URL(fileURLWithPath: $0.folder) } : nil,
            processingPercent: snapshot?.percent,
            jobActive: jobs.current != nil,
            queued: jobs.queued.map(\.folder))
        return Recents.load(dir: notesDir, context: context)
    }

    // MARK: - state.json

    private func writeState() {
        let snapshot = jobs.displaySnapshot
        var parts: [String] = [pill.name, "\(jobs.queued.count)"]
        parts.append(session?.folder.path ?? "")
        parts.append(session?.title ?? "")
        parts.append(snapshot?.folder ?? "")
        parts.append(snapshot?.currentStage ?? "")
        parts.append(snapshot?.waiting ?? "")
        let key = parts.joined(separator: "|")
        let now = Date()
        if key == lastStateKey {
            // Progress-only change: at most once per 2 s.
            guard snapshot != nil, now.timeIntervalSince(lastStateWrite) >= 2 else { return }
        }
        lastStateKey = key
        lastStateWrite = now
        var title: String?
        var folder: String?
        switch pill {
        case .starting, .recording, .paused, .stopping:
            title = session?.title
            folder = session?.folder.path
        case .processing(let s):
            title = s.title
            folder = s.folder
        case .ready(let info):
            title = info.title
            folder = info.folder
        default:
            break
        }
        let status = AppStatusSnapshot(
            state: pill.name, title: title, folder: folder, startedAt: session?.startedAt,
            elapsedSec: session?.recordedSeconds, paused: machine.phase == .paused,
            processing: snapshot.map { .init(folder: $0.folder, stage: $0.waiting == nil ? $0.currentStage : "waiting",
                                             overall: $0.overall, etaSec: $0.etaSec) },
            queue: jobs.queued.count, updatedAt: now)
        writeStateFile(status)
    }

    private func writeStateFile(_ status: AppStatusSnapshot, sync: Bool = false) {
        guard let data = try? status.jsonData() else { return }
        let url = AppInfo.stateFile
        let write: @Sendable () -> Void = {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if sync { stateQueue.sync(execute: write) } else { stateQueue.async(execute: write) }
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        hotKeys = []
        hotkeyError = nil
        hotkey = register(Settings.hotkey, fallback: HotKeySpec.defaultRecord, command: .toggleRecording)
        pauseHotkey = register(Settings.pauseHotkey, fallback: HotKeySpec.defaultPause, command: .togglePause)
    }

    private func register(_ text: String, fallback: String, command: RecorderCommand) -> HotKeySpec? {
        var spec = HotKeySpec.parse(text)
        if spec == nil {
            hotkeyError = tr(.hotkeyInvalid, text, fallback)
            spec = HotKeySpec.parse(fallback)
        }
        guard let spec else { return nil }
        if let registration = HotKey(spec: spec, handler: { [weak self] in
            MainActor.assumeIsolated { self?.perform(command, source: .hotkey) }
        }) {
            hotKeys.append(registration)
        } else {
            hotkeyError = tr(.hotkeyUnavailable, spec.display)
        }
        return spec
    }

    // MARK: - URL scheme

    func handle(_ command: URLCommand) {
        switch command {
        case .start: startRecording(source: .url)
        case .stop: perform(.stop, source: .url)
        case .pause: perform(.pause, source: .url)
        case .resume: perform(.resume, source: .url)
        case .toggle: perform(.toggleRecording, source: .url)
        case .show: ui?.showMainWindow()
        }
    }

    // MARK: - Pill visibility

    func hidePillForAnHour() {
        Settings.pillHiddenUntil = Date().addingTimeInterval(3600)
        scheduleIdlePillReshow()
        ui?.hidePill()
        ui?.showToast(tr(.toastHiddenHour))
    }

    func unhidePill() {
        Settings.pillHiddenUntil = nil
        idlePillTimer?.cancel()
    }

    private func scheduleIdlePillReshow() {
        idlePillTimer?.cancel()
        guard let until = Settings.pillHiddenUntil, until > Date() else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                Settings.pillHiddenUntil = nil
                self?.ui?.pillStateChanged()
            }
        }
        idlePillTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + until.timeIntervalSinceNow + 1, execute: item)
    }

    // MARK: - Notes and Finder

    func openLastNotes() {
        if let lastResult, FileManager.default.fileExists(atPath: lastResult.folder) {
            ui?.openNotes(URL(fileURLWithPath: lastResult.folder, isDirectory: true))
        } else if let recent = recents().first(where: { $0.hasNotes }) {
            ui?.openNotes(recent.url)
        } else {
            ui?.showToast(tr(.toastNoNotes))
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func openInDefaultApp(_ url: URL) { NSWorkspace.shared.open(url) }

    func copySummary(folder: URL) {
        let summaryURL = folder.appendingPathComponent(".work/summary.json")
        var text: String?
        if let data = try? Data(contentsOf: summaryURL), let summary = try? JSONDecoder().decode(MeetingSummary.self, from: data) {
            text = summary.plainText()
        }
        if text?.isEmpty ?? true {
            text = try? String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8)
        }
        guard let text, !text.isEmpty else {
            ui?.showToast(tr(.toastNoSummary))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ui?.showToast(tr(.toastSummaryCopied))
    }

    func openNotesFolder() {
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(notesDir)
    }

    // MARK: - Settings

    func setCreateNotesMode(_ mode: CreateNotesMode) {
        Settings.createNotesMode = mode
        state.createNotesMode = mode
        jobs.pump()
        refresh()
    }

    func setSummaryModel(_ model: SummaryModel) {
        Settings.summaryModel = model
    }

    func chooseNotesFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr(.actionUseFolder)
        panel.directoryURL = notesDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.notesDir = url
        notesDir = Settings.notesDir
    }

    func resetNotesFolder() {
        Settings.notesDir = Settings.defaultNotesDir
        notesDir = Settings.notesDir
    }
}

// MARK: - AppCommands

extension AppController: AppCommands {
    func openNotes(_ folder: URL) { ui?.openNotes(folder) }
    func showSettings() { ui?.showSettings() }
    func showMainWindow() { ui?.showMainWindow() }
    func resetPillPosition() { ui?.resetPillPosition() }
    func setShowInDock(_ show: Bool) { ui?.setShowInDock(show) }

    func setPillVisibility(whileRecording: Bool, whenIdle: Bool) {
        Settings.showRecordingPill = whileRecording
        Settings.showIdlePill = whenIdle
        if whenIdle { unhidePill() }
        ui?.pillStateChanged()
    }

    func setLanguage(_ language: UILanguage) {
        guard language != L10n.language else { return }
        Settings.uiLanguage = language
        LanguageModel.shared.set(language)
        refresh()
        ui?.languageChanged()
    }

    func dismissGettingStarted() {
        Settings.onboardingDone = true
        state.showGettingStarted = false
    }

    /// Requests a permission that was never asked, otherwise opens its System Settings pane.
    func fixPermission(_ kind: PermissionKind) {
        switch kind {
        case .microphone:
            guard Permissions.microphone == .notDetermined else { return Permissions.openSettings(.microphone) }
            Task { @MainActor in
                _ = await Permissions.requestMicrophone()
                refreshPermissions()
            }
        case .screenCapture:
            // Shows the system prompt once; afterwards only System Settings can change it.
            if !Permissions.requestScreenCapture() { Permissions.openSettings(.screenCapture) }
            refreshPermissions()
        case .notifications:
            guard state.notifications == .notDetermined else { return Permissions.openSettings(.notifications) }
            notifier.requestAuthorization { [weak self] _ in self?.refreshPermissions() }
        }
    }

    func openPermissionSettings(_ kind: PermissionKind) { Permissions.openSettings(kind) }

    /// Restarts the app so macOS applies a newly granted Screen & System Audio Recording permission.
    /// Only while idle with no notes job (see `RelaunchPolicy`).
    func relaunch() {
        guard state.canRelaunch else {
            ui?.showToast(tr(.relaunchBlocked))
            return
        }
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        // Waits (max ~10 s) for this process to exit, then opens a fresh instance.
        let script = "for i in $(seq 1 50); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done; sleep 0.3; /usr/bin/open -n -a \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, path]
        do {
            try process.run()
        } catch {
            ui?.showToast(error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }

    /// Captures mic + system audio for 5 s and plays a system sound from a separate process
    /// (captured despite `excludesCurrentProcessAudio`). Nothing is written to disk.
    func runAudioTest() {
        guard !state.audioTest.running else { return }
        guard machine.phase == .idle else {
            state.audioTest = AudioTestState(result: [tr(.testStopFirst)])
            return
        }
        state.audioTest = AudioTestState(running: true)
        let micSink = MeterSink()
        let systemSink = MeterSink()
        let mic = MicRecorder(sink: micSink)
        let system = SystemAudioCapture(sink: systemSink)
        Task { @MainActor in
            var micError: String?
            var systemFailed = false
            if await MicRecorder.ensurePermission() {
                do { try mic.start() } catch { micError = error.localizedDescription }
            } else {
                micError = tr(.micAccessDenied)
            }
            do {
                try await system.start()
                screenCaptureVerified = true
            } catch {
                systemFailed = true
                if Permissions.isPermissionError(error) { screenCaptureVerified = false }
            }
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.state.audioTest.me = LevelMeter.displayValue(micSink.meter.level())
                    self?.state.audioTest.them = LevelMeter.displayValue(systemSink.meter.level())
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["/System/Library/Sounds/Glass.aiff"]
            try? player.run()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            timer.invalidate()
            mic.stop()
            await system.stop()
            let me = micError.map { tr(.testMeError, $0) }
                ?? (micSink.peakDB > -60 ? tr(.testMeOK, Int(micSink.peakDB)) : tr(.testMeSilent))
            let them = systemFailed ? tr(.testThemNotPermitted)
                : (systemSink.peakDB > -60 ? tr(.testThemOK) : tr(.testThemSilent))
            state.audioTest = AudioTestState(result: [me, them])
            refreshPermissions()
        }
    }
}
