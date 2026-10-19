import AVFoundation
import MeetingNotesCore
import MeetingNotesUI

/// Captures the default input device through an `AVAudioEngine` input tap into a sink.
/// Pausing stops the engine, so the system microphone indicator turns off.
final class MicRecorder {
    let sink: AudioSink
    let deviceName: String?
    var onWarning: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var running = false

    init(sink: AudioSink) {
        self.sink = sink
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

    func pause() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func resume() throws {
        guard !running else { return }
        try startEngine()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pause()
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AppError(tr(.errNoMicDevice))
        }
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, time in
            let seconds: Double
            if time.isHostTimeValid {
                seconds = AVAudioTime.seconds(forHostTime: time.hostTime)
            } else {
                seconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())
                    - Double(buffer.frameLength) / buffer.format.sampleRate
            }
            sink.append(buffer, hostSeconds: seconds)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    private func restartAfterConfigurationChange() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try startEngine()
            onWarning?(tr(.warnMicDeviceChanged))
        } catch {
            onWarning?(tr(.warnMicStoppedAfterChange, error.localizedDescription))
        }
    }
}
