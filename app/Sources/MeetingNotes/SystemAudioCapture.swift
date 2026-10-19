import AVFoundation
import ScreenCaptureKit

/// Captures system audio output (all apps except this one) with ScreenCaptureKit.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: TrackWriter
    var onWarning: ((String) -> Void)?

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "meetingnotes.system-audio", qos: .userInitiated)

    init(folder: URL) {
        writer = TrackWriter(url: folder.appendingPathComponent("system.wav"), label: "system")
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
        // Video is required by SCStream but unused: keep it as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        // A screen output avoids "stream output not found" frame-drop errors; frames are discarded.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = AudioConvert.pcmBuffer(from: sampleBuffer) else { return }
        // ScreenCaptureKit timestamps use the host-time clock.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = pts.isValid ? pts.seconds : AVAudioTime.seconds(forHostTime: mach_absolute_time())
        writer.append(buffer, hostSeconds: seconds)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = "System audio capture stopped: \(error.localizedDescription)"
        DispatchQueue.main.async { self.onWarning?(message) }
    }
}
