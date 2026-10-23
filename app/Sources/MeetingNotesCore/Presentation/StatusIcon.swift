import Foundation

/// Which icon the menu bar item and the pill's state slot show for a `PillState`.
/// Idle, recording and paused use the brand glyph (waveform bars over note lines, the app icon's motif);
/// the other states keep an SF Symbol so their meaning stays obvious.
public enum StatusIcon: String, CaseIterable, Equatable, Sendable {
    case idle, attention, busy, recording, paused, processing, ready, error

    public init(_ pill: PillState) {
        switch pill {
        case .idle(let attention): self = attention ? .attention : .idle
        case .starting, .stopping: self = .busy
        case .recording: self = .recording
        case .paused: self = .paused
        case .processing: self = .processing
        case .ready: self = .ready
        case .error: self = .error
        }
    }

    /// How the menu bar draws this state.
    public enum Kind: Equatable, Sendable {
        /// The brand glyph as a template image (follows the menu bar's light/dark tint).
        case glyph
        /// The brand glyph tinted with a state color (not a template), e.g. red while recording.
        case tintedGlyph(Tint)
        /// An SF Symbol template image.
        case symbol(String)
    }

    public enum Tint: String, Equatable, Sendable { case recording, paused }

    public var kind: Kind {
        switch self {
        case .idle: return .glyph
        case .recording: return .tintedGlyph(.recording)
        case .paused: return .tintedGlyph(.paused)
        case .attention, .error: return .symbol("exclamationmark.triangle")
        case .busy: return .symbol("ellipsis.circle")
        case .processing: return .symbol("arrow.triangle.2.circlepath.circle")
        case .ready: return .symbol("checkmark.circle")
        }
    }
}
