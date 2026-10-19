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

/// "Create notes" setting.
public enum CreateNotesMode: String, CaseIterable, Sendable {
    case rightAway, whenIdle, manual

    public var title: String {
        switch self {
        case .rightAway: return "Right away (low priority)"
        case .whenIdle: return "When idle and plugged in"
        case .manual: return "Manually"
        }
    }

    /// `MEETING_NOTES_PRIORITY` for jobs started by this mode.
    public var priority: String { self == .whenIdle ? "normal" : "low" }

    /// Minimum seconds without user input for `whenIdle`.
    public static let idleSeconds: Double = 180

    /// Whether a queued, non-explicit job may start now.
    public func canStart(onACPower: Bool, idleSeconds: Double) -> Bool {
        switch self {
        case .rightAway: return true
        case .whenIdle: return onACPower && idleSeconds >= Self.idleSeconds
        case .manual: return false
        }
    }
}

/// Summary model setting (`MEETING_NOTES_OLLAMA_MODEL`).
public enum SummaryModel: String, CaseIterable, Sendable {
    case light, better

    public var model: String { self == .light ? "qwen3:4b" : "qwen3:8b" }

    public var title: String {
        switch self {
        case .light: return "Light — qwen3:4b (~3.6 GB RAM)"
        case .better: return "Better — qwen3:8b (~6.3 GB RAM)"
        }
    }
}
