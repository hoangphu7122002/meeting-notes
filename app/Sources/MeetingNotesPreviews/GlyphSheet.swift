import AppKit
import MeetingNotesCore
import MeetingNotesUI

/// `menubar-<appearance>@<scale>x.png`: every status item icon on a simulated menu bar strip, at real
/// pixel size (1x and 2x), template images tinted the way the menu bar tints them.
@MainActor
func renderGlyphSheet(appearance: Appearance, scale: CGFloat, dir: URL) {
    let icons = StatusIcon.allCases
    let slot: CGFloat = 28
    let size = CGSize(width: slot * CGFloat(icons.count) + 8, height: 24)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let dark = appearance == .dark
    (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
    NSRect(origin: .zero, size: size).fill()
    let tint = dark ? NSColor.white : NSColor(white: 0, alpha: 0.85)
    for (index, icon) in icons.enumerated() {
        guard let image = StatusIconImage.make(icon) else { continue }
        let fitted = image.size.width > 18 || image.size.height > 18
            ? NSSize(width: 18, height: 18) : image.size
        let rect = NSRect(x: 4 + slot * CGFloat(index) + (slot - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                          width: fitted.width, height: fitted.height)
        draw(image, in: rect, tint: image.isTemplate ? tint : nil)
    }
    NSGraphicsContext.restoreGraphicsState()
    let name = "menubar-\(appearance.rawValue)@\(Int(scale))x.png"
    Renderer.write(rep, dir.appendingPathComponent(name))
    print("\(name)\t\(icons.map(\.rawValue).joined(separator: " "))")
}

private func draw(_ image: NSImage, in rect: NSRect, tint: NSColor?) {
    guard let tint else {
        image.draw(in: rect)
        return
    }
    let tinted = NSImage(size: rect.size, flipped: false) { bounds in
        image.draw(in: bounds)
        tint.setFill()
        bounds.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: rect)
}
