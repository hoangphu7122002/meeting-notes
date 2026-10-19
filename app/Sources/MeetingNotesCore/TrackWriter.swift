import Accelerate
import AVFoundation
import CoreMedia

/// Writes one audio track as mono 16-bit PCM WAV on its own serial queue, positioned in recorded time.
///
/// Buffers carry the host-clock time of their first sample; `RecordingClock` maps it to recorded time
/// (paused time excluded). Buffers captured while paused or after stop are dropped. The first written
/// sample's recorded time becomes the track's start offset; later gaps larger than `gapTolerance`
/// (pause/resume restarts, device switches) are filled with silence and overlaps are trimmed, so all
/// tracks of a recording stay aligned and contain recorded time only.
public final class TrackWriter: AudioSink, @unchecked Sendable {
    public struct Stats: Sendable {
        /// Recorded time of the first sample (the track's `start_offset_sec`).
        public var startOffset: Double?
        public var frames: Int64 = 0
        public var sampleRate: Double = 0
        public var peak: Float = 0
        public var droppedBuffers = 0
        public var error: String?

        public var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
        /// Recorded time just after the last written sample.
        public var endTime: Double? { startOffset.map { $0 + duration } }
    }

    public static let gapTolerance = 0.2

    public let url: URL
    public let clock: RecordingClock
    public let meter = LevelMeter()
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var stats = Stats()
    private var closed = false
    private let dropLock = NSLock()
    private var dropped = 0

    public init(url: URL, label: String, clock: RecordingClock) {
        self.url = url
        self.clock = clock
        queue = DispatchQueue(label: "meetingnotes.writer.\(label)", qos: .userInitiated)
    }

    /// Thread-safe. Copies (and downmixes) the buffer synchronously, writes asynchronously.
    public func append(_ buffer: AVAudioPCMBuffer, hostSeconds: Double) {
        guard let segment = clock.segment(atHost: hostSeconds) else {
            dropLock.withLock { dropped += 1 }
            return
        }
        guard let mono = AudioConvert.monoFloat(buffer) else { return }
        meter.update(mono)
        queue.async { self.write(mono, at: segment.time, limit: segment.limit) }
    }

    public var currentStats: Stats {
        var result = queue.sync { stats }
        result.droppedBuffers = dropLock.withLock { dropped }
        return result
    }

    /// Flushes pending writes, pads with silence up to `endTime` (recorded seconds) when given,
    /// closes the file and returns the final stats.
    public func finish(endTime: Double?) -> Stats {
        var result = queue.sync { () -> Stats in
            if !closed, stats.error == nil, let end = endTime, let file, let format, let current = stats.endTime {
                let remaining = end - current
                if remaining > 0.5 / format.sampleRate {
                    do { try writeSilence(seconds: min(remaining, 12 * 3600), to: file, format: format) } catch {
                        stats.error = error.localizedDescription
                    }
                }
            }
            closed = true
            file = nil
            converter = nil
            return stats
        }
        result.droppedBuffers = dropLock.withLock { dropped }
        return result
    }

    private func write(_ input: AVAudioPCMBuffer, at time: Double, limit: Double?) {
        guard !closed, stats.error == nil else { return }
        do {
            if file == nil {
                try open(sampleRate: input.format.sampleRate)
                stats.startOffset = max(0, time)
            }
            guard let file, let format, let start = stats.startOffset else { return }
            var buffer = input.format.sampleRate == format.sampleRate ? input : try resample(input, to: format)
            let rate = format.sampleRate

            let expected = start + Double(stats.frames) / rate
            let gap = time - expected
            if gap > Self.gapTolerance {
                try writeSilence(seconds: min(gap, 12 * 3600), to: file, format: format)
            } else if gap < -Self.gapTolerance {
                // Overlaps the audio already written (e.g. a buffer starting before the clock): trim its head.
                let skip = AVAudioFrameCount(min(Double(buffer.frameLength), (-gap * rate).rounded()))
                guard skip < buffer.frameLength, let rest = Self.slice(buffer, from: skip) else { return }
                buffer = rest
            }
            if let limit {
                // Never write past the segment end (pause or stop): keeps tracks equal in recorded time.
                let position = start + Double(stats.frames) / rate
                let allowed = ((limit - position) * rate).rounded()
                guard allowed > 0 else { return }
                if Double(buffer.frameLength) > allowed { buffer.frameLength = AVAudioFrameCount(allowed) }
            }
            try file.write(from: buffer)
            stats.frames += Int64(buffer.frameLength)
            if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var peak: Float = 0
                vDSP_maxmgv(samples, 1, &peak, vDSP_Length(buffer.frameLength))
                stats.peak = max(stats.peak, peak)
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
        var remaining = AVAudioFrameCount((seconds * format.sampleRate).rounded())
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

    private static func slice(_ buffer: AVAudioPCMBuffer, from offset: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        let count = buffer.frameLength - offset
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let src = buffer.floatChannelData?[0], let dst = out.floatChannelData?[0] else { return nil }
        dst.update(from: src.advanced(by: Int(offset)), count: Int(count))
        out.frameLength = count
        return out
    }

    private func resample(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
        }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw CoreError("Cannot resample \(input.format.sampleRate) Hz to \(format.sampleRate) Hz")
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

public struct CoreError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum AudioConvert {
    /// Copies any PCM buffer (float32 / int16 / int32, interleaved or not) into a new mono float32 buffer.
    public static func monoFloat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = buffer.format
        let frames = Int(buffer.frameLength)
        let channels = Int(source.channelCount)
        guard frames > 0, channels > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData?[0] else { return nil }
        output.frameLength = AVAudioFrameCount(frames)

        // Fast path: mono float32, deinterleaved.
        if source.commonFormat == .pcmFormatFloat32, channels == 1, let data = buffer.floatChannelData {
            destination.update(from: data[0], count: frames)
            return output
        }

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
    public static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
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
