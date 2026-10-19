import AVFoundation

/// One meeting recording: microphone + system audio into a meeting folder, plus `meeting.json`.
@MainActor
final class RecordingSession {
    struct Options {
        var title = "Meeting"
        var titleSource = "default"
        var appHint: String?

        static func from(appHint: String?) -> Options {
            guard let appHint else { return Options() }
            return Options(title: "\(appHint) meeting", titleSource: "app", appHint: appHint)
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
        let tracks: [String: Track]
        let warnings: [String]
        var hasAudio: Bool { !tracks.isEmpty }
    }

    let folder: URL
    let options: Options
    let startedAt: Date
    private let startHostSeconds: Double
    private let mic: MicRecorder?
    private let system: SystemAudioCapture?
    private(set) var warnings: [String]
    var onWarningsChanged: (([String]) -> Void)?

    private init(folder: URL, options: Options, startedAt: Date, startHostSeconds: Double,
                 mic: MicRecorder?, system: SystemAudioCapture?, warnings: [String]) {
        self.folder = folder
        self.options = options
        self.startedAt = startedAt
        self.startHostSeconds = startHostSeconds
        self.mic = mic
        self.system = system
        self.warnings = warnings
    }

    /// Starts whatever sources are available; throws only when neither can record.
    static func start(folder: URL, options: Options) async throws -> RecordingSession {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var warnings: [String] = []
        let micAllowed = await MicRecorder.ensurePermission()

        let startedAt = Date()
        let startHostSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())

        var mic: MicRecorder?
        if micAllowed {
            let recorder = MicRecorder(folder: folder)
            do {
                try recorder.start()
                mic = recorder
            } catch {
                warnings.append("Microphone unavailable: \(error.localizedDescription)")
            }
        } else {
            warnings.append("Microphone access denied (System Settings › Privacy & Security › Microphone); recording system audio only.")
        }

        var system: SystemAudioCapture?
        let capture = SystemAudioCapture(folder: folder)
        do {
            try await capture.start()
            system = capture
        } catch {
            warnings.append("System audio not recorded: \(error.localizedDescription)")
        }

        guard mic != nil || system != nil else {
            throw AppError("No audio source could be started. " + warnings.joined(separator: " "))
        }

        let session = RecordingSession(folder: folder, options: options, startedAt: startedAt,
                                       startHostSeconds: startHostSeconds, mic: mic, system: system, warnings: warnings)
        mic?.onWarning = { [weak session] in session?.addWarning($0) }
        system?.onWarning = { [weak session] in session?.addWarning($0) }
        session.writeMeetingJSON(ended: nil, tracks: [:])
        // Rewrite once the first samples arrived so a crash still leaves usable track offsets.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak session] in
            MainActor.assumeIsolated { session?.writeProvisionalMeetingJSON() }
        }
        return session
    }

    func stop() async -> Result {
        mic?.stop()
        await system?.stop()
        let ended = Date()

        var tracks: [String: Track] = [:]
        if let mic {
            let stats = mic.writer.finish()
            check(stats, name: "Microphone", file: "mic.wav", silentWarning: true)
            tracks["mic"] = track(stats, file: "mic.wav", device: mic.deviceName)
        }
        if let system {
            let stats = system.writer.finish()
            check(stats, name: "System audio", file: "system.wav", silentWarning: false)
            tracks["system"] = track(stats, file: "system.wav", device: nil)
        }
        writeMeetingJSON(ended: ended, tracks: tracks)
        return Result(folder: folder, tracks: tracks, warnings: warnings)
    }

    // MARK: - Private

    private func addWarning(_ warning: String) {
        guard !warnings.contains(warning) else { return }
        warnings.append(warning)
        onWarningsChanged?(warnings)
    }

    private func check(_ stats: TrackWriter.Stats, name: String, file: String, silentWarning: Bool) {
        if let error = stats.error {
            addWarning("\(name): writing \(file) failed: \(error)")
        }
        if stats.frames == 0 {
            addWarning("\(name) produced no audio; track omitted.")
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        } else if silentWarning && stats.peak == 0 {
            addWarning("\(name) track is completely silent (check permission or input device).")
        }
    }

    private func track(_ stats: TrackWriter.Stats, file: String, device: String?) -> Track? {
        guard stats.frames > 0, let first = stats.firstSampleSeconds else { return nil }
        return Track(file: file, startOffset: max(0, first - startHostSeconds), sampleRate: stats.sampleRate,
                     device: device, duration: stats.duration, peak: stats.peak)
    }

    private func writeProvisionalMeetingJSON() {
        var tracks: [String: Track] = [:]
        if let mic { tracks["mic"] = track(mic.writer.currentStats, file: "mic.wav", device: mic.deviceName) }
        if let system { tracks["system"] = track(system.writer.currentStats, file: "system.wav", device: nil) }
        writeMeetingJSON(ended: nil, tracks: tracks)
    }

    private func writeMeetingJSON(ended: Date?, tracks: [String: Track]) {
        var trackObjects: [String: Any] = [:]
        for (key, track) in tracks {
            var object: [String: Any] = [
                "file": track.file,
                "start_offset_sec": Self.decimal(track.startOffset, places: 3),
                "sample_rate": Int(track.sampleRate),
            ]
            if let device = track.device { object["device"] = device }
            trackObjects[key] = object
        }
        let json: [String: Any] = [
            "version": 1,
            "title": options.title,
            "title_source": options.titleSource,
            "app_hint": options.appHint ?? NSNull(),
            "started_at": Self.iso.string(from: startedAt),
            "ended_at": ended.map { Self.iso.string(from: $0) } ?? NSNull(),
            "duration_sec": ended.map { Self.decimal($0.timeIntervalSince(startedAt), places: 2) } ?? NSNull(),
            "tracks": trackObjects,
            "warnings": warnings,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
        } catch {
            addWarning("Could not write meeting.json: \(error.localizedDescription)")
        }
    }

    /// Rounded number that serializes without binary floating-point noise (0.386, not 0.38600000000000001).
    private static func decimal(_ value: Double, places: Int) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.\(places)f", value), locale: Locale(identifier: "en_US_POSIX"))
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()
}
