import AVFoundation

/// Records the default input device through an `AVAudioEngine` input tap.
final class MicRecorder {
    let writer: TrackWriter
    let deviceName: String?
    var onWarning: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var stopped = false

    init(folder: URL) {
        writer = TrackWriter(url: folder.appendingPathComponent("mic.wav"), label: "mic")
        deviceName = AVCaptureDevice.default(for: .audio)?.localizedName
    }

    /// Returns true when microphone access is granted (prompts on first use).
    static func ensurePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static var permissionDescription: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .notDetermined: return "not determined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    func start() throws {
        try startEngine()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restartAfterConfigurationChange() }
    }

    func stop() {
        stopped = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AppError("No microphone input device available")
        }
        let writer = self.writer
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, time in
            let seconds: Double
            if time.isHostTimeValid {
                seconds = AVAudioTime.seconds(forHostTime: time.hostTime)
            } else {
                seconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                    - Double(buffer.frameLength) / buffer.format.sampleRate
            }
            writer.append(buffer, hostSeconds: seconds)
        }
        engine.prepare()
        try engine.start()
    }

    private func restartAfterConfigurationChange() {
        guard !stopped else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try startEngine()
            onWarning?("Microphone input changed during recording; the gap was filled with silence.")
        } catch {
            onWarning?("Microphone stopped after an input device change: \(error.localizedDescription)")
        }
    }
}
