import AppKit
import MeetingNotesCore
import SwiftUI

extension NSColor {
    /// Color that follows the view's light/dark appearance.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// Colors of the floating surfaces (pill, cards, toast). All adapt to light and dark mode and stay
/// readable on any wallpaper: an almost opaque window-colored fill, a 1 pt border and the window shadow.
public enum Palette {
    public static let fill = Color(nsColor: .windowBackgroundColor).opacity(0.96)
    public static let border = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.15)))
    public static let label = Color(nsColor: .labelColor)
    public static let secondary = Color(nsColor: .secondaryLabelColor)
    public static let track = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.1), dark: NSColor(white: 1, alpha: 0.14)))
    public static let control = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.12)))
    public static let recording = Color(nsColor: .systemRed)
    public static let paused = Color(nsColor: .systemOrange)
    public static let warning = Color(nsColor: .systemOrange)
    public static let ok = Color(nsColor: .systemGreen)
    /// Main window section background.
    public static let card = Color(nsColor: .dynamic(light: .controlBackgroundColor, dark: NSColor(white: 1, alpha: 0.05)))
    public static let cardBorder = Color(nsColor: .separatorColor)
    public static let windowBackground = Color(nsColor: .windowBackgroundColor)
}

/// Fill + border of the pill, its cards and the toast.
struct SurfaceBackground<S: InsettableShape>: View {
    let shape: S
    var tint: Color?

    var body: some View {
        ZStack {
            shape.fill(Palette.fill)
            if let tint { shape.fill(tint.opacity(0.16)) }
            shape.strokeBorder(tint.map { $0.opacity(0.55) } ?? Palette.border, lineWidth: 1)
        }
    }
}

/// Buttons of the floating surfaces (the main window uses standard controls).
public struct PillButtonStyle: ButtonStyle {
    public enum Kind { case primary, record, secondary, destructive, plain, icon }
    public enum Size { case regular, small }

    let kind: Kind
    var size: Size = .regular
    @Environment(\.isEnabled) private var isEnabled

    public init(kind: Kind, size: Size = .regular) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 13, weight: kind == .primary || kind == .record ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .icon ? 7 : (size == .small ? 10 : 12))
            .padding(.vertical, size == .small ? 4 : 6)
            .background(RoundedRectangle(cornerRadius: size == .small ? 13 : 8, style: .continuous).fill(background))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Color(nsColor: .windowBackgroundColor)
        case .record, .destructive: return .white
        case .plain: return Palette.recording
        case .icon: return Palette.secondary
        case .secondary: return Palette.label
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Palette.label
        case .record, .destructive: return Palette.recording
        case .plain, .icon: return .clear
        case .secondary: return Palette.control
        }
    }
}
