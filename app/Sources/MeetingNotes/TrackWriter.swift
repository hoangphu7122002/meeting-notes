import AVFoundation
import CoreMedia

/// Writes one audio track as mono 16-bit PCM WAV on its own serial queue.
///
/// The file is created lazily from the first buffer (native sample rate). Buffers carry the
/// host-clock time of their first sample; gaps larger than `gapTolerance` (device switches,
/// dropped callbacks) are filled with silence so the track stays aligned with the wall clock.
final class TrackWriter {
    struct Stats {
        var firstSampleSeconds: Double?
        var frames: Int64 = 0
        var sampleRate: Double = 0
        var peak: Float = 0
        var error: String?

        var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    }

    static let gapTolerance = 0.2

    let url: URL
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var stats = Stats()
    private var closed = false

    init(url: URL, label: String) {
        self.url = url
        queue = DispatchQueue(label: "meetingnotes.writer.\(label)", qos: .userInitiated)
    }

    /// Thread-safe. Copies (and downmixes) the buffer synchronously, writes asynchronously.
    func append(_ buffer: AVAudioPCMBuffer, hostSeconds: Double) {
        guard let mono = AudioConvert.monoFloat(buffer) else { return }
        queue.async { self.write(mono, hostSeconds: hostSeconds) }
    }

    var currentStats: Stats { queue.sync { stats } }

    /// Flushes pending writes, closes the file and returns the final stats.
    func finish() -> Stats {
        queue.sync {
            closed = true
            file = nil
            converter = nil
            return stats
        }
    }

    private func write(_ input: AVAudioPCMBuffer, hostSeconds: Double) {
        guard !closed, stats.error == nil else { return }
        do {
            if file == nil {
                try open(sampleRate: input.format.sampleRate)
                stats.firstSampleSeconds = hostSeconds
            }
            guard let file, let format, let first = stats.firstSampleSeconds else { return }
            let buffer = input.format.sampleRate == format.sampleRate ? input : try resample(input, to: format)

            let expected = first + Double(stats.frames) / format.sampleRate
            let gap = hostSeconds - expected
            if gap > Self.gapTolerance {
                try writeSilence(seconds: min(gap, 3600), to: file, format: format)
            }
            try file.write(from: buffer)
            stats.frames += Int64(buffer.frameLength)
            if let samples = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) {
                    stats.peak = max(stats.peak, abs(samples[i]))
                }
            }
        } catch {
            stats.error = error.localizedDescription
        }
    }

    private func open(sampleRate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        format = file.processingFormat
        stats.sampleRate = sampleRate
    }

    private func writeSilence(seconds: Double, to file: AVAudioFile, format: AVAudioFormat) throws {
        var remaining = AVAudioFrameCount(seconds * format.sampleRate)
        let chunk = AVAudioFrameCount(format.sampleRate)
        guard remaining > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk),
              let data = silence.floatChannelData?[0] else { return }
        data.update(repeating: 0, count: Int(chunk))
        while remaining > 0 {
            silence.frameLength = min(chunk, remaining)
            try file.write(from: silence)
            stats.frames += Int64(silence.frameLength)
            remaining -= silence.frameLength
        }
    }

    private func resample(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
        }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AppError("Cannot resample \(input.format.sampleRate) Hz to \(format.sampleRate) Hz")
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        return output
    }
}

enum AudioConvert {
    /// Copies any PCM buffer (float32 / int16 / int32, interleaved or not) into a new mono float32 buffer.
    static func monoFloat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = buffer.format
        let frames = Int(buffer.frameLength)
        let channels = Int(source.channelCount)
        guard frames > 0, channels > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData?[0] else { return nil }
        output.frameLength = AVAudioFrameCount(frames)

        let stride = buffer.stride
        let interleaved = source.isInterleaved
        let scale = 1 / Float(channels)

        func mix(_ read: (_ channel: Int, _ frame: Int) -> Float) {
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += read(c, i) }
                destination[i] = sum * scale
            }
        }

        switch source.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            if interleaved { mix { c, i in data[0][i * stride + c] } } else { mix { c, i in data[c][i] } }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            let k: Float = 1 / 32768
            if interleaved { mix { c, i in Float(data[0][i * stride + c]) * k } } else { mix { c, i in Float(data[c][i]) * k } }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return nil }
            let k: Float = 1 / 2_147_483_648
            if interleaved { mix { c, i in Float(data[0][i * stride + c]) * k } } else { mix { c, i in Float(data[c][i]) * k } }
        default:
            return nil
        }
        return output
    }

    /// Copies the PCM payload of a ScreenCaptureKit audio sample buffer.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
