import Foundation

/// Frame energy of a caption window (30 ms frames at 16 kHz) with an adaptive noise floor: decides whether new audio
/// is worth a decode and how long the trailing silence is. Cheap and deterministic (no model).
public struct EnergyGate: Equatable, Sendable {
    public static let frameSize = 480
    /// Voiced = this many dB above the noise floor, clamped to [minThreshold, maxThreshold] dBFS.
    public static let marginDB: Float = 12
    public static let minThreshold: Float = -52
    public static let maxThreshold: Float = -30
    /// Frames of history for the floor estimate (~9 s).
    static let historyFrames = 300

    /// dBFS per complete frame of the window.
    public private(set) var frames: [Float] = []
    /// Adaptive noise floor (dBFS): a low percentile of recent frames, kept across windows.
    public private(set) var floor: Float
    private var history: [Float] = []
    private var partial: [Float] = []

    public init(floor: Float = -60) {
        self.floor = floor
    }

    public var threshold: Float { min(max(floor + Self.marginDB, Self.minThreshold), Self.maxThreshold) }

    public mutating func add(_ samples: [Float]) {
        partial += samples
        var index = 0
        while partial.count - index >= Self.frameSize {
            var sum: Float = 0
            for i in index..<(index + Self.frameSize) { sum += partial[i] * partial[i] }
            let rms = (sum / Float(Self.frameSize)).squareRoot()
            let db = 20 * log10(max(rms, 1e-7))
            frames.append(db)
            history.append(db)
            index += Self.frameSize
        }
        partial.removeFirst(index)
        if history.count > Self.historyFrames { history.removeFirst(history.count - Self.historyFrames) }
        if history.count >= 20 {
            let sorted = history.sorted()
            floor = sorted[sorted.count / 10]
        }
    }

    public func isVoiced(_ frame: Int) -> Bool { frames[frame] > threshold }

    /// Voiced seconds among frames `from...`.
    public func voicedSeconds(from start: Int) -> Double {
        guard start < frames.count else { return 0 }
        let count = frames[max(0, start)...].filter { $0 > threshold }.count
        return Double(count * Self.frameSize) / Double(CaptionWire.sampleRate)
    }

    public var lastVoicedFrame: Int? { frames.lastIndex { $0 > threshold } }

    /// Seconds since the last voiced frame (the whole window when nothing is voiced).
    public var trailingSilenceSec: Double {
        let silent = frames.count - 1 - (lastVoicedFrame ?? -1)
        return Double(silent * Self.frameSize) / Double(CaptionWire.sampleRate)
    }

    public mutating func dropFrames(_ count: Int) {
        frames.removeFirst(min(count, frames.count))
    }
}
