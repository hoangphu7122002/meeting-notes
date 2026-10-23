// "Live transcript" setting: fast captions (design B on top of A), accurate only (A) or off (Preferences).

import Foundation

/// Stored as two UserDefaults keys: `liveTranscription` (A on/off, public API since design A) and `liveCaptions`
/// (B on top of A, default true). So turning live on gives fast captions by default, and an older build that only
/// knows `liveTranscription` keeps working.
public enum LiveMode: String, CaseIterable, Sendable {
    case fast, accurate, off

    public init(live: Bool, captions: Bool) {
        self = !live ? .off : (captions ? .fast : .accurate)
    }

    /// Design A (worker `live` job) runs.
    public var live: Bool { self != .off }
    /// Design B (caption helper) runs on top of A.
    public var captions: Bool { self == .fast }

    /// The value for the `liveCaptions` key; `.off` keeps the previous choice for the next time live is turned on.
    public func captionsKey(previous: Bool) -> Bool { self == .off ? previous : captions }

    public func title(_ lang: UILanguage = L10n.language) -> String {
        switch self {
        case .fast: return tr(.liveModeFast, lang: lang)
        case .accurate: return tr(.liveModeAccurate, lang: lang)
        case .off: return tr(.liveModeOff, lang: lang)
        }
    }

    public var help: Tr {
        switch self {
        case .fast: return .helpLiveFast
        case .accurate: return .helpLiveAccurate
        case .off: return .helpLiveOff
        }
    }
}
