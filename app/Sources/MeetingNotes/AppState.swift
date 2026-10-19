import AppKit
import Combine

/// Central app state: recording lifecycle, processing queue, detection, hotkey and settings.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, stopping }

    struct Processing {
        var folder: URL
        var stage: String?
        var message: String?
        var overall: Double?

        var percentText: String { overall.map { "\(Int(($0 * 100).rounded()))%" } ?? "…" }
        var summary: String {
            var parts: [String] = []
            if let stage { parts.append(stage.capitalized) }
            if overall != nil { parts.append(percentText) }
            if let message, !message.isEmpty { parts.append(message) }
            return parts.isEmpty ? "Starting…" : parts.joined(separator: " · ")
        }
    }

    static let stages = ["prepare", "diarize", "transcribe", "summarize", "render", "finalize"]

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsedText = "00:00"
    @Published private(set) var recordingFolder: URL?
    @Published private(set) var recordingWarnings: [String] = []
    @Published private(set) var processing: Processing?
    @Published private(set) var queuedFolders: [URL] = []
    @Published private(set) var recents: [RecentMeeting] = []
    @Published private(set) var detectedApp: MeetingDetector.App?
    @Published var lastError: String?
    @Published private(set) var notesDir = Settings.notesDir
    @Published private(set) var detectionEnabled = true
    @Published private(set) var loginItemEnabled = false
    @Published private(set) var loginItemStatus = ""
    @Published private(set) var loginItemError: String?
    @Published private(set) var hotkey: HotKeySpec?

    private var session: RecordingSession?
    private var clockTimer: Timer?
    private var refreshTimer: Timer?
    private var hotKeyRegistration: HotKey?
    private let detector = MeetingDetector()
    private let notifier = Notifier()
    private var runner: PipelineRunner?
    private var lastToggle = Date.distantPast

    var isRecording: Bool { phase == .recording || phase == .stopping }

    // MARK: - Lifecycle

    func launch() {
        Settings.registerDefaults()
        detectionEnabled = Settings.detectionEnabled
        notifier.onStartRecording = { [weak self] app in
            MainActor.assumeIsolated { self?.startFromDetection(appName: app) }
        }
        notifier.setup()
        detector.onStart = { [weak self] app in MainActor.assumeIsolated { self?.micAppStarted(app) } }
        detector.onStop = { [weak self] app in MainActor.assumeIsolated { self?.micAppStopped(app) } }
        if detectionEnabled { detector.start() }
        registerHotKey()
        refreshLoginItem()
        refreshRecents()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRecents() }
        }
    }

    var needsGracefulShutdown: Bool { phase != .idle }

    /// Finalizes an active recording (without processing it) and stops the pipeline.
    func prepareForQuit() async {
        for _ in 0..<50 where phase == .starting {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if phase == .recording { await stopRecording(process: false) }
        shutdownNow()
    }

    func shutdownNow() {
        runner?.terminate()
        detector.stop()
    }

    // MARK: - Recording

    func toggleRecording() {
        guard Date().timeIntervalSince(lastToggle) > 0.8 else { return }
        lastToggle = Date()
        switch phase {
        case .idle: startRecording(appHint: detectedApp?.name ?? detector.activeApps.first?.name)
        case .recording: Task { await stopRecording(process: true) }
        case .starting, .stopping: break
        }
    }

    func startFromDetection(appName: String?) {
        guard phase == .idle else { return }
        lastToggle = Date()
        startRecording(appHint: appName ?? detectedApp?.name)
    }

    private func startRecording(appHint: String?) {
        phase = .starting
        lastError = nil
        recordingWarnings = []
        let dir = notesDir
        Task {
            var folder: URL?
            do {
                let created = try MeetingFolders.create(in: dir)
                folder = created
                let session = try await RecordingSession.start(folder: created, options: .from(appHint: appHint))
                session.onWarningsChanged = { [weak self] warnings in self?.recordingWarnings = warnings }
                self.session = session
                recordingFolder = created
                recordingWarnings = session.warnings
                phase = .recording
                detectedApp = nil
                notifier.clearMeetingDetected()
                startClock(from: session.startedAt)
                refreshRecents()
            } catch {
                if let folder { MeetingFolders.removeIfEmpty(folder) }
                phase = .idle
                lastError = "Could not start recording: \(error.localizedDescription)"
                notifier.failure(title: "Recording failed", message: error.localizedDescription)
            }
        }
    }

    private func stopRecording(process: Bool) async {
        guard let session, phase == .recording else { return }
        phase = .stopping
        let result = await session.stop()
        self.session = nil
        clockTimer?.invalidate()
        clockTimer = nil
        recordingFolder = nil
        recordingWarnings = result.warnings
        phase = .idle
        if !result.hasAudio {
            lastError = "Recording produced no audio: \(result.folder.lastPathComponent)"
        } else if process {
            enqueue(result.folder)
        }
        refreshRecents()
    }

    private func startClock(from start: Date) {
        elapsedText = Self.formatElapsed(0)
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.elapsedText = Self.formatElapsed(Date().timeIntervalSince(start)) }
        }
    }

    static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Processing

    func enqueue(_ folder: URL) {
        let key = MeetingFolders.key(folder)
        if let processing, MeetingFolders.key(processing.folder) == key { return }
        guard !queuedFolders.contains(where: { MeetingFolders.key($0) == key }) else { return }
        queuedFolders.append(folder)
        runNextJob()
        refreshRecents()
    }

    private func runNextJob() {
        guard runner == nil, !queuedFolders.isEmpty else { return }
        let folder = queuedFolders.removeFirst()
        guard let pipelineDir = Settings.pipelineDir else {
            lastError = "Pipeline folder not configured (Info.plist MNPipelineDir)."
            return
        }
        let runner = PipelineRunner(uvPath: Settings.uvPath, pipelineDir: pipelineDir)
        processing = Processing(folder: folder)
        self.runner = runner
        do {
            try runner.run(
                folder: folder,
                onEvent: { [weak self] event in MainActor.assumeIsolated { self?.handle(event) } },
                completion: { [weak self] result in MainActor.assumeIsolated { self?.finishJob(folder: folder, result: result) } })
        } catch {
            finishJob(folder: folder, result: PipelineRunner.Result(exitCode: -1, done: nil, lastError: error.localizedDescription))
        }
    }

    private func handle(_ event: PipelineRunner.Event) {
        guard var current = processing else { return }
        switch event.kind {
        case "stage":
            current.stage = event.stage ?? current.stage
            current.message = event.message ?? [event.stage, event.status].compactMap { $0 }.joined(separator: " ")
            if let overall = event.overall { current.overall = overall }
        case "progress":
            current.stage = event.stage ?? current.stage
            current.message = event.message ?? current.message
            if let overall = event.overall {
                current.overall = overall
            } else if let stage = event.stage, let index = Self.stages.firstIndex(of: stage) {
                let fraction = min(max(event.fraction ?? 0, 0), 1)
                current.overall = (Double(index) + fraction) / Double(Self.stages.count)
            }
        case "warning", "error":
            current.message = event.message ?? current.message
        default:
            break
        }
        processing = current
    }

    private func finishJob(folder: URL, result: PipelineRunner.Result) {
        runner = nil
        processing = nil
        if result.exitCode == 0 {
            let finalFolder = result.done?.folder.map { URL(fileURLWithPath: $0) } ?? folder
            let notes = result.done?.notes ?? finalFolder.appendingPathComponent("notes.md").path
            notifier.notesReady(title: result.done?.title ?? finalFolder.lastPathComponent, notesPath: notes)
        } else {
            let message = result.lastError ?? "Pipeline exited with code \(result.exitCode); see pipeline.app.log"
            lastError = "Processing failed (\(folder.lastPathComponent)): \(message)"
            notifier.failure(title: "Processing failed: \(folder.lastPathComponent)", message: message)
        }
        refreshRecents()
        runNextJob()
    }

    // MARK: - Recents

    func refreshRecents() {
        let context = Recents.Context(recording: recordingFolder, processing: processing?.folder,
                                      jobActive: runner != nil, queued: queuedFolders)
        recents = Recents.load(dir: notesDir, context: context)
    }

    // MARK: - Meeting detection

    private func micAppStarted(_ app: MeetingDetector.App) {
        guard detectionEnabled, phase == .idle else { return }
        detectedApp = app
        notifier.meetingDetected(appName: app.name)
    }

    private func micAppStopped(_ app: MeetingDetector.App) {
        guard detectedApp?.name == app.name else { return }
        detectedApp = nil
        notifier.clearMeetingDetected()
    }

    func setDetectionEnabled(_ enabled: Bool) {
        detectionEnabled = enabled
        Settings.detectionEnabled = enabled
        if enabled {
            detector.start()
        } else {
            detector.stop()
            detectedApp = nil
            notifier.clearMeetingDetected()
        }
    }

    // MARK: - Settings

    private func registerHotKey() {
        let configured = Settings.hotkey
        var spec = HotKeySpec.parse(configured)
        if spec == nil {
            lastError = "Invalid hotkey \"\(configured)\"; using \(Settings.defaultHotkey)."
            spec = HotKeySpec.parse(Settings.defaultHotkey)
        }
        guard let spec else { return }
        hotkey = spec
        hotKeyRegistration = HotKey(spec: spec) { [weak self] in
            MainActor.assumeIsolated { self?.toggleRecording() }
        }
        if hotKeyRegistration == nil {
            lastError = "Global hotkey \(spec.display) is unavailable (used by another app?)."
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItem()
    }

    func refreshLoginItem() {
        loginItemEnabled = LoginItem.isEnabled
        loginItemStatus = LoginItem.statusText
    }

    func chooseNotesFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = notesDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setNotesDir(url)
    }

    func resetNotesFolder() { setNotesDir(Settings.defaultNotesDir) }

    private func setNotesDir(_ url: URL) {
        Settings.notesDir = url
        notesDir = Settings.notesDir
        refreshRecents()
    }

    // MARK: - Finder actions

    func openNotesFolder() {
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(notesDir)
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
