import Accelerate
import AVFoundation

/// Receives captured audio buffers stamped with the host-clock time of their first sample.
public protocol AudioSink: AnyObject {
    /// Called on capture threads; must be cheap and thread-safe.
    func append(_ buffer: AVAudioPCMBuffer, hostSeconds: Double)
}

/// Cached audio level, written from the capture thread and read by UI timers.
public final class LevelMeter: @unchecked Sendable {
    public static let floorDB: Float = -100
    /// Levels older than this read as silence (capture stopped or no buffers).
    public static let staleAfter: Double = 0.6

    private let lock = NSLock()
    private var rms: Float = 0
    private var updatedAt: Double = -.infinity
    private var windowMax: Float = 0
    private var windowHadData = false

    public init() {}

    /// RMS of a mono float buffer (vDSP).
    public static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var value: Float = 0
        vDSP_rmsqv(data, 1, &value, vDSP_Length(buffer.frameLength))
        return value
    }

    public static func db(_ rms: Float) -> Float {
        rms > 0 ? max(floorDB, 20 * log10(rms)) : floorDB
    }

    public func update(_ mono: AVAudioPCMBuffer, now: Double = ProcessInfo.processInfo.systemUptime) {
        update(rms: Self.rms(of: mono), now: now)
    }

    public func update(rms value: Float, now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            rms = value
            updatedAt = now
            windowMax = max(windowMax, value)
            windowHadData = true
        }
    }

    /// Current linear RMS (0 when stale).
    public func level(now: Double = ProcessInfo.processInfo.systemUptime) -> Float {
        lock.withLock { now - updatedAt > Self.staleAfter ? 0 : rms }
    }

    /// Maximum level since the previous call, in dBFS (floor when no audio arrived).
    public func takeWindowMaxDB() -> Float {
        lock.withLock {
            defer { windowMax = 0; windowHadData = false }
            return windowHadData ? Self.db(windowMax) : Self.floorDB
        }
    }

    public func reset() {
        lock.withLock {
            rms = 0
            updatedAt = -.infinity
            windowMax = 0
            windowHadData = false
        }
    }

    /// 0...1 display value for meters (-60 dBFS ... 0 dBFS).
    public static func displayValue(_ rms: Float) -> Double {
        let db = Double(Self.db(rms))
        return min(1, max(0, (db + 60) / 60))
    }
}

/// Sink that only measures levels (permission test; nothing is written to disk).
public final class MeterSink: AudioSink, @unchecked Sendable {
    public let meter = LevelMeter()
    private let lock = NSLock()
    private var peakValue: Float = 0

    public init() {}

    public var peakDB: Float { lock.withLock { LevelMeter.db(peakValue) } }

    public func append(_ buffer: AVAudioPCMBuffer, hostSeconds: Double) {
        guard let mono = AudioConvert.monoFloat(buffer) else { return }
        let rms = LevelMeter.rms(of: mono)
        meter.update(rms: rms)
        lock.withLock { peakValue = max(peakValue, rms) }
    }
}
