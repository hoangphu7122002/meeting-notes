// Monochrome brand glyph (waveform bars over note lines, the app icon's motif without the squircle)
// for the menu bar and the pill's idle slot. Drawn in code on an 18-unit grid so it stays crisp at 1x/2x.

import AppKit
import MeetingNotesCore
import SwiftUI

/// The glyph as a SwiftUI shape (fills its frame, keeping the 18x18 aspect).
public struct BrandGlyph: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / BrandGlyph.grid
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        var path = Path()
        for r in BrandGlyph.rects {
            let scaled = CGRect(x: origin.x + r.minX * scale, y: origin.y + r.minY * scale,
                                width: r.width * scale, height: r.height * scale)
            path.addRoundedRect(in: scaled, cornerSize: CGSize(width: scaled.width / 2, height: scaled.width / 2))
        }
        return path
    }

    /// Design grid (points at 18 pt), y down.
    static let grid: CGFloat = 18
    /// Four bars, width 2, gap 2, on whole points (crisp at 1x and 2x); heights echo the app icon's wave.
    static let bars: [(x: CGFloat, height: CGFloat)] = [(2, 3), (6, 9), (10, 5), (14, 7)]
    static let barCenterY: CGFloat = 5.5
    static let barWidth: CGFloat = 2
    /// Note lines: full width, then a short one (room for a state badge at the bottom right).
    static let lines: [CGRect] = [CGRect(x: 2, y: 12, width: 14, height: 2), CGRect(x: 2, y: 15, width: 8, height: 2)]

    static var rects: [CGRect] {
        bars.map { CGRect(x: $0.x, y: barCenterY - $0.height / 2, width: barWidth, height: $0.height) }
            + lines.map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
    }
}

/// NSImages for the menu bar status item, one per `StatusIcon`.
@MainActor
public enum StatusIconImage {
    public static let size = NSSize(width: 18, height: 18)

    public static func make(_ icon: StatusIcon) -> NSImage? {
        let image: NSImage?
        switch icon.kind {
        case .glyph:
            image = glyph(color: .black, badge: nil)
            image?.isTemplate = true
        case .tintedGlyph(let tint):
            image = glyph(color: tint == .recording ? .systemRed : .systemOrange, badge: tint)
            image?.isTemplate = false
        case .symbol(let name):
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            image?.isTemplate = true
        }
        image?.accessibilityDescription = accessibilityDescription(icon)
        return image
    }

    static func accessibilityDescription(_ icon: StatusIcon) -> String {
        switch icon {
        case .recording: return "Meeting Notes – Recording"
        case .paused: return "Meeting Notes – Paused"
        default: return "Meeting Notes"
        }
    }

    private static func glyph(color: NSColor, badge: StatusIcon.Tint?) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let path = BrandGlyph().path(in: rect).cgPath
            ctx.addPath(path)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
            guard let badge else { return true }
            // Badge in the empty bottom-right corner, cut out of the glyph so it reads as separate.
            let center = CGPoint(x: 14, y: 14)
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
            ctx.setBlendMode(.normal)
            ctx.setFillColor(color.cgColor)
            switch badge {
            case .recording:
                ctx.fillEllipse(in: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
            case .paused:
                ctx.fill(CGRect(x: center.x - 3, y: center.y - 3, width: 2, height: 6))
                ctx.fill(CGRect(x: center.x + 1, y: center.y - 3, width: 2, height: 6))
            }
            return true
        }
    }
}

/// The glyph as an inline icon in the pill (replaces the old microphone symbol in idle states).
public struct BrandGlyphIcon: View {
    let size: CGFloat
    let color: Color

    public init(size: CGFloat = 16, color: Color = Palette.secondary) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        BrandGlyph().fill(color).frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(Text("Meeting Notes"))
            .accessibilityAddTraits(.isImage)
    }
}
