import Foundation

/// Tracks how long a level has stayed below a threshold. Fed about once per second with the
/// loudest level of the last window (so short sounds between samples still count).
public struct SilenceTracker: Equatable, Sendable {
    public var thresholdDB: Float
    /// Seconds of continuous silence before `update` fires; <= 0 disables firing.
    public var limit: Double
    private var silentSince: Double?
    private var fired = false

    public init(thresholdDB: Float = -50, limit: Double) {
        self.thresholdDB = thresholdDB
        self.limit = limit
    }

    /// Returns true exactly once per silent stretch when it reaches `limit` seconds.
    public mutating func update(now: Double, levelDB: Float) -> Bool {
        guard levelDB < thresholdDB else {
            silentSince = nil
            fired = false
            return false
        }
        if silentSince == nil { silentSince = now }
        guard limit > 0, !fired, let since = silentSince, now - since >= limit else { return false }
        fired = true
        return true
    }

    public func silentDuration(now: Double) -> Double {
        silentSince.map { max(0, now - $0) } ?? 0
    }

    /// Starts counting from scratch (after resume or "Keep recording").
    public mutating func reset() {
        silentSince = nil
        fired = false
    }
}
