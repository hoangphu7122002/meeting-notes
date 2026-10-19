import AVFoundation
import MeetingNotesCore
import MeetingNotesUI

/// One meeting recording: microphone + system audio into a meeting folder, plus `meeting.json`.
/// Both tracks are positioned in recorded time by a shared `RecordingClock`, so pausing
/// excludes the paused period from the files and the tracks stay aligned after resume.
@MainActor
final class RecordingSession {
    struct Options {
        var title = tr(.defaultMeetingTitle)
        var titleSource = "default"
        var appHint: String?

        static func from(appHint: String?) -> Options {
            guard let appHint else { return Options() }
            return Options(title: tr(.appMeetingTitle, appHint), titleSource: "app", appHint: appHint)
        }
    }

    struct Track {
        let file: String
        let startOffset: Double
        let sampleRate: Double
        let device: String?
        let duration: Double
        let peak: Float
    }

    struct Result {
        let folder: URL
        let title: String
        let tracks: [String: Track]
        let warnings: [String]
        let recordedDuration: Double
        let pauses: [MeetingRecord.PauseEntry]
        var hasAudio: Bool { !tracks.isEmpty }
    }

    let folder: URL
    let clock: RecordingClock
    let micWriter: TrackWriter?
    let systemWriter: TrackWriter?
    /// False when system audio could not be started (permission or no display).
    let systemAudioAvailable: Bool
    private(set) var record: MeetingRecord
    private(set) var warnings: [String]
    var onWarningsChanged: (([String]) -> Void)?

    private let mic: MicRecorder?
    private let system: SystemAudioCapture?
    private var pauseDates: [Date] = []
    /// Serializes capture stop/start work of pause/resume/stop.
    private var operation: Task<Void, Never>?
    private var finished = false

    private init(folder: URL, record: MeetingRecord, clock: RecordingClock, mic: MicRecorder?, micWriter: TrackWriter?,
                 system: SystemAudioCapture?, systemWriter: TrackWriter?, warnings: [String]) {
        self.folder = folder
        self.record = record
        self.clock = clock
        self.mic = mic
        self.micWriter = micWriter
        self.system = system
        self.systemWriter = systemWriter
        self.systemAudioAvailable = system != nil
        self.warnings = warnings
    }

    /// Starts whatever sources are available; throws only when neither can record.
    static func start(folder: URL, options: Options) async throws -> RecordingSession {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var warnings: [String] = []
        let micAllowed = await MicRecorder.ensurePermission()

        let startedAt = Date()
        let clock = RecordingClock(startHost: HostClock.now())

        var mic: MicRecorder?
        var micWriter: TrackWriter?
        if micAllowed {
            let writer = TrackWriter(url: folder.appendingPathComponent("mic.wav"), label: "mic", clock: clock)
            let recorder = MicRecorder(sink: writer)
            do {
                try recorder.start()
                mic = recorder
                micWriter = writer
            } catch {
                warnings.append(tr(.warnMicUnavailable, error.localizedDescription))
            }
        } else {
            warnings.append(tr(.warnMicDenied))
        }

        var system: SystemAudioCapture?
        var systemWriter: TrackWriter?
        let writer = TrackWriter(url: folder.appendingPathComponent("system.wav"), label: "system", clock: clock)
        let capture = SystemAudioCapture(sink: writer)
        do {
            try await capture.start()
            system = capture
            systemWriter = writer
        } catch {
            warnings.append(tr(.warnSystemNotRecorded, error.localizedDescription))
        }

        guard mic != nil || system != nil else {
            throw AppError(tr(.errNoAudioSource, warnings.joined(separator: " ")))
        }

        var record = MeetingRecord(title: options.title, titleSource: options.titleSource, appHint: options.appHint, startedAt: startedAt)
        record.warnings = warnings
        let session = RecordingSession(folder: folder, record: record, clock: clock, mic: mic, micWriter: micWriter,
                                       system: system, systemWriter: systemWriter, warnings: warnings)
        mic?.onWarning = { [weak session] in session?.addWarning($0) }
        system?.onWarning = { [weak session] in session?.addWarning($0) }
        session.writeMeetingJSON()
        // Rewrite once the first samples arrived so a crash still leaves usable track offsets.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak session] in
            MainActor.assumeIsolated { session?.writeProvisionalMeetingJSON() }
        }
        return session
    }

    var startedAt: Date { record.startedAt }
    var title: String { record.title }
    var isPaused: Bool { clock.isPaused }
    /// Recorded seconds so far (paused time excluded).
    var recordedSeconds: Double { clock.recordedDuration(atHost: HostClock.now()) }

    func setTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != record.title else { return }
        record.title = trimmed
        record.titleSource = "user"
        writeMeetingJSON()
    }

    /// Stops both captures (mic indicator off); buffers already in flight are dropped by the clock.
    func pause() {
        guard !finished, clock.pause(atHost: HostClock.now()) else { return }
        pauseDates.append(Date())
        let mic = self.mic, system = self.system
        enqueue {
            mic?.pause()
            await system?.pause()
        }
        writeMeetingJSON()
    }

    func resume() {
        guard !finished, clock.resume(atHost: HostClock.now()) else { return }
        let mic = self.mic, system = self.system
        enqueue { [weak self] in
            do { try mic?.resume() } catch { self?.addWarning(tr(.warnMicResume, error.localizedDescription)) }
            do { try await system?.resume() } catch {
                self?.addWarning(tr(.warnSystemResume, error.localizedDescription))
            }
        }
        writeMeetingJSON()
    }

    func stop() async -> Result {
        let stopHost = HostClock.now()
        clock.stop(atHost: stopHost)
        finished = true
        await operation?.value
        mic?.stop()
        await system?.stop()
        let ended = Date()
        let end = clock.recordedDuration(atHost: stopHost)

        var tracks: [String: Track] = [:]
        if let mic, let micWriter {
            let stats = micWriter.finish(endTime: end)
            check(stats, name: tr(.microphone), file: "mic.wav", silentWarning: true)
            tracks["mic"] = track(stats, file: "mic.wav", device: mic.deviceName)
        }
        if let systemWriter {
            let stats = systemWriter.finish(endTime: end)
            check(stats, name: tr(.systemAudio), file: "system.wav", silentWarning: false)
            tracks["system"] = track(stats, file: "system.wav", device: nil)
        }
        record.endedAt = ended
        record.durationSec = end
        record.wallDurationSec = ended.timeIntervalSince(record.startedAt)
        writeMeetingJSON(tracks: tracks, nowHost: stopHost)
        return Result(folder: folder, title: record.title, tracks: tracks, warnings: warnings, recordedDuration: end,
                      pauses: record.pauses)
    }

    /// Stops capture and deletes this recording's folder.
    func discard() async throws {
        clock.stop(atHost: HostClock.now())
        finished = true
        await operation?.value
        mic?.stop()
        await system?.stop()
        _ = micWriter?.finish(endTime: nil)
        _ = systemWriter?.finish(endTime: nil)
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: - Private

    private func writeProvisionalMeetingJSON() {
        guard !finished else { return }
        writeMeetingJSON()
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = operation
        operation = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func addWarning(_ warning: String) {
        guard !warnings.contains(warning) else { return }
        warnings.append(warning)
        onWarningsChanged?(warnings)
    }

    private func check(_ stats: TrackWriter.Stats, name: String, file: String, silentWarning: Bool) {
        if let error = stats.error {
            addWarning(tr(.warnTrackWriteFailed, name, file, "\(error)"))
        }
        if stats.frames == 0 {
            addWarning(tr(.warnTrackNoAudio, name))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        } else if silentWarning && stats.peak == 0 {
            addWarning(tr(.warnTrackSilent, name))
        }
    }

    private func track(_ stats: TrackWriter.Stats, file: String, device: String?) -> Track? {
        guard stats.frames > 0, let offset = stats.startOffset else { return nil }
        return Track(file: file, startOffset: offset, sampleRate: stats.sampleRate, device: device,
                     duration: stats.duration, peak: stats.peak)
    }

    private func currentTracks() -> [String: Track] {
        var tracks: [String: Track] = [:]
        if let micWriter { tracks["mic"] = track(micWriter.currentStats, file: "mic.wav", device: mic?.deviceName) }
        if let systemWriter { tracks["system"] = track(systemWriter.currentStats, file: "system.wav", device: nil) }
        return tracks
    }

    private func writeMeetingJSON(tracks: [String: Track]? = nil, nowHost: Double = HostClock.now()) {
        let tracks = tracks ?? currentTracks()
        record.tracks = tracks.mapValues {
            MeetingRecord.Track(file: $0.file, startOffsetSec: $0.startOffset, sampleRate: Int($0.sampleRate), device: $0.device)
        }
        record.pauses = zip(clock.pauseList, pauseDates).map { pause, date in
            MeetingRecord.PauseEntry(atSec: pause.atRecorded, durationSec: pause.wallDuration(nowHost: nowHost), startedAt: date)
        }
        record.warnings = warnings
        do {
            try record.jsonData().write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
        } catch {
            addWarning(tr(.warnMeetingJSON, error.localizedDescription))
        }
    }
}
