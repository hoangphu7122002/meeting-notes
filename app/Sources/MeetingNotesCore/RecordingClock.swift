import Foundation

/// Maps capture timestamps (host-clock seconds) to recorded time: wall time since the start
/// minus all paused time. Thread-safe; read from audio callbacks, mutated from the main actor.
public final class RecordingClock: @unchecked Sendable {
    public struct Pause: Equatable, Sendable {
        /// Recorded time at which the pause began.
        public let atRecorded: Double
        public let startHost: Double
        public var endHost: Double?

        public func wallDuration(nowHost: Double) -> Double { max(0, (endHost ?? nowHost) - startHost) }
    }

    /// Position of a timestamp in recorded time, plus where its segment ends (next pause or stop), if known.
    public struct Segment: Equatable, Sendable {
        public let time: Double
        public let limit: Double?
    }

    public let startHost: Double
    private let lock = NSLock()
    private var pauses: [Pause] = []
    private var stopHost: Double?

    public init(startHost: Double) {
        self.startHost = startHost
    }

    public var isPaused: Bool { lock.withLock { pauses.last.map { $0.endHost == nil } ?? false } }
    public var isStopped: Bool { lock.withLock { stopHost != nil } }
    public var pauseList: [Pause] { lock.withLock { pauses } }

    /// Starts a pause; returns false when already paused or stopped.
    @discardableResult
    public func pause(atHost host: Double) -> Bool {
        lock.withLock {
            guard stopHost == nil, pauses.last?.endHost != nil || pauses.isEmpty else { return false }
            let at = max(host, pauses.last?.endHost ?? startHost)
            pauses.append(Pause(atRecorded: recordedDurationLocked(atHost: at), startHost: at, endHost: nil))
            return true
        }
    }

    /// Ends the current pause; returns false when not paused.
    @discardableResult
    public func resume(atHost host: Double) -> Bool {
        lock.withLock {
            guard stopHost == nil, let last = pauses.indices.last, pauses[last].endHost == nil else { return false }
            pauses[last].endHost = max(host, pauses[last].startHost)
            return true
        }
    }

    /// Ends recording: later timestamps map to nil. Stopping while paused ends at the pause point.
    public func stop(atHost host: Double) {
        lock.withLock {
            guard stopHost == nil else { return }
            let stop = max(host, pauses.last?.endHost ?? pauses.last?.startHost ?? startHost)
            if let last = pauses.indices.last, pauses[last].endHost == nil {
                pauses[last].endHost = stop  // an open pause ends with the recording
            }
            stopHost = stop
        }
    }

    /// Recorded time of a capture timestamp; nil while paused or after stop.
    public func recordedTime(atHost host: Double) -> Double? { segment(atHost: host)?.time }

    public func segment(atHost host: Double) -> Segment? {
        lock.withLock {
            var paused = 0.0
            for pause in pauses {
                if host < pause.startHost {
                    return Segment(time: host - startHost - paused, limit: pause.atRecorded)
                }
                guard let end = pause.endHost, host >= end else { return nil }
                paused += end - pause.startHost
            }
            let time = host - startHost - paused
            if let stopHost {
                guard host < stopHost else { return nil }
                return Segment(time: time, limit: stopHost - startHost - paused)
            }
            return Segment(time: time, limit: nil)
        }
    }

    /// Recorded (unpaused) duration from the start until `host` (or until stop).
    public func recordedDuration(atHost host: Double) -> Double {
        lock.withLock { recordedDurationLocked(atHost: host) }
    }

    /// Wall seconds spent paused until `host`.
    public func pausedDuration(atHost host: Double) -> Double {
        lock.withLock { pauses.reduce(0) { $0 + $1.wallDuration(nowHost: min(host, stopHost ?? host)) } }
    }

    private func recordedDurationLocked(atHost host: Double) -> Double {
        let end = min(host, stopHost ?? host)
        var paused = 0.0
        for pause in pauses where pause.startHost < end {
            paused += min(pause.endHost ?? end, end) - pause.startHost
        }
        return max(0, end - startHost - paused)
    }
}
