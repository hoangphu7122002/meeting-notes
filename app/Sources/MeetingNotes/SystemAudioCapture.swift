import AVFoundation
import MeetingNotesCore
import ScreenCaptureKit

/// Captures system audio output (all apps except this one) with ScreenCaptureKit into a sink.
/// Pausing stops the stream; resuming starts a new one.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let sink: AudioSink
    var onWarning: ((String) -> Void)?

    private let lock = NSLock()
    private var currentStream: SCStream?
    /// Accessed from async contexts and SCStream callbacks.
    private var stream: SCStream? {
        get { lock.withLock { currentStream } }
        set { lock.withLock { currentStream = newValue } }
    }
    private let sampleQueue = DispatchQueue(label: "meetingnotes.system-audio", qos: .userInitiated)

    init(sink: AudioSink) {
        self.sink = sink
    }

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw AppError("Screen & System Audio Recording permission is required for system audio (\(error.localizedDescription))")
        }
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw AppError("No display available for system audio capture")
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Video is required by SCStream but unused: keep it as cheap as possible (2×2 px, 1 fps).
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        // A screen output avoids "stream output not found" frame-drop errors; frames are discarded.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func pause() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func resume() async throws {
        guard stream == nil else { return }
        try await start()
    }

    func stop() async { await pause() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = AudioConvert.pcmBuffer(from: sampleBuffer) else { return }
        // ScreenCaptureKit timestamps use the host-time clock.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = pts.isValid ? pts.seconds : AVAudioTime.seconds(forHostTime: mach_absolute_time())
        sink.append(buffer, hostSeconds: seconds)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = "System audio capture stopped: \(error.localizedDescription)"
        DispatchQueue.main.async {
            guard self.stream === stream else { return }
            self.onWarning?(message)
        }
    }
}
