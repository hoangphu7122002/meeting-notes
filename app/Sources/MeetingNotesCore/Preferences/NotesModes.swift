// User-selectable notes creation mode and summary model (Preferences).

import Foundation

/// "Create notes" setting.
public enum CreateNotesMode: String, CaseIterable, Sendable {
    case rightAway, whenIdle, manual

    public func title(_ lang: UILanguage = L10n.language) -> String {
        switch self {
        case .rightAway: return tr(.modeRightAway, lang: lang)
        case .whenIdle: return tr(.modeWhenIdle, lang: lang)
        case .manual: return tr(.modeManual, lang: lang)
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

    public func title(_ lang: UILanguage = L10n.language) -> String {
        tr(self == .light ? .modelLight : .modelBetter, lang: lang)
    }
}
