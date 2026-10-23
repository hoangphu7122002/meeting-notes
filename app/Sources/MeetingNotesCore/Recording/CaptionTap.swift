import AVFoundation

/// Sends one capture stream to several sinks (the WAV writer and the caption tap). The writer always goes first.
public final class TeeSink: AudioSink, @unchecked Sendable {
    public let sinks: [AudioSink]

    public init(_ sinks: [AudioSink]) {
        self.sinks = sinks
    }

    public func append(_ buffer: AVAudioPCMBuffer, hostSeconds: Double) {
        for sink in sinks { sink.append(buffer, hostSeconds: hostSeconds) }
    }
}

/// Live captions (design B) read the recorder's own buffers here: no second capture. While disabled it returns at
/// once; while enabled it positions each buffer in recorded time (the WAV/`live_segment` timeline), downmixes on the
/// capture thread, and resamples to 16 kHz Int16 on its own utility queue before calling `onAudio`.
/// Display-only: a slow consumer only loses captions (the queue is bounded), never recorded audio.
public final class CaptionTap: AudioSink, @unchecked Sendable {
    public let track: String
    public let clock: RecordingClock
    public typealias Handler = @Sendable (String, Double, [Int16]) -> Void
    /// Called on the tap's queue with (track, recorded start seconds, 16 kHz mono samples).
    public var onAudio: Handler? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }
    private var handler: Handler?
    /// Buffers waiting for conversion beyond this are dropped (about 3 s of audio).
    public static let maxPending = 32

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var enabled = false
    private var pending = 0
    private var dropped = 0
    private var converter: AVAudioConverter?
    private let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public init(track: String, clock: RecordingClock) {
        self.track = track
        self.clock = clock
        queue = DispatchQueue(label: "meetingnotes.captions.\(track)", qos: .utility)
    }

    public var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    /// Buffers dropped because the consumer was behind.
    public var droppedBuffers: Int { lock.withLock { dropped } }

    public func append(_ buffer: AVAudioPCMBuffer, hostSeconds: Double) {
        let accept = lock.withLock { () -> Bool in
            guard enabled else { return false }
            guard pending < Self.maxPending else {
                dropped += 1
                return false
            }
            pending += 1
            return true
        }
        guard accept else { return }
        guard let segment = clock.segment(atHost: hostSeconds), let mono = AudioConvert.monoFloat(buffer) else {
            lock.withLock { pending -= 1 }
            return
        }
        queue.async {
            defer { self.lock.withLock { self.pending -= 1 } }
            guard let samples = self.resample(mono), !samples.isEmpty else { return }
            self.onAudio?(self.track, segment.time, samples)
        }
    }

    /// 16 kHz Int16 samples of a mono float buffer (any input rate).
    func resample(_ input: AVAudioPCMBuffer) -> [Int16]? {
        let floats: AVAudioPCMBuffer
        if input.format.sampleRate == output.sampleRate {
            floats = input
        } else {
            if converter == nil || converter?.inputFormat != input.format {
                converter = AVAudioConverter(from: input.format, to: output)
            }
            let capacity = AVAudioFrameCount(Double(input.frameLength) * output.sampleRate / input.format.sampleRate) + 64
            guard let converter, let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return input
            }
            if error != nil { return nil }
            floats = out
        }
        guard let data = floats.floatChannelData?[0] else { return nil }
        let count = Int(floats.frameLength)
        return (0..<count).map { Int16(max(-1, min(1, data[$0])) * 32767) }
    }
}
