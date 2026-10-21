import AppKit
import MeetingNotesCore
import MeetingNotesUI
import SwiftUI

// `swift run MeetingNotesPreviews <dir>`: renders the pill (collapsed + expanded) and the main window in
// every state, light and dark, at 2x, into <dir>. Offscreen only: no window is ever ordered on screen,
// nothing is recorded, and the app is not started (this target does not contain it).
// The renderer process is never active, so AppKit draws prominent (tinted) buttons in their inactive
// grey style, as in a background window.

@MainActor
enum Renderer {
    static func spin(_ seconds: Double = 0.06) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Offscreen window (never ordered front) that gives the view a backing and an appearance.
    /// Installs the view the same way the app does (`hostContentIfNeeded` on a fresh window), so a
    /// preview fails the same way the app would if the hosting view never got attached.
    static func host<Content: View>(_ view: NSHostingView<Content>, size: CGSize, appearance: NSAppearance) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = .clear
        window.isOpaque = false
        view.appearance = appearance
        window.hostContentIfNeeded { view }
        precondition(window.contentView === view, "hosting view not attached")
        view.frame = NSRect(origin: .zero, size: size)
        return window
    }

    static func bitmap(_ view: NSView, scale: CGFloat = 2, transparent: Bool = false) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        if transparent, let layer = view.layer, let context = NSGraphicsContext(bitmapImageRep: rep) {
            // Layer rendering keeps the transparent corners of floating surfaces (cacheDisplay fills them).
            // The rep's size already maps points to pixels; the layer tree is flipped relative to it.
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            layer.render(in: context.cgContext)
        } else {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        return rep
    }

    /// Places a floating-surface bitmap on a wallpaper-like backdrop with the window shadow.
    static func composite(_ rep: NSBitmapImageRep, appearance: Appearance, margin: CGFloat = 36, scale: CGFloat = 2) -> NSBitmapImageRep {
        let size = CGSize(width: rep.size.width + margin * 2, height: rep.size.height + margin * 2)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let bounds = NSRect(origin: .zero, size: size)
        let colors: [NSColor] = appearance == .dark
            ? [NSColor(red: 0.05, green: 0.06, blue: 0.12, alpha: 1), NSColor(red: 0.17, green: 0.10, blue: 0.24, alpha: 1)]
            : [NSColor(red: 0.80, green: 0.86, blue: 0.95, alpha: 1), NSColor(red: 0.96, green: 0.90, blue: 0.84, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: bounds, angle: 35)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.shadowColor = NSColor.black.withAlphaComponent(appearance == .dark ? 0.6 : 0.3)
        shadow.set()
        rep.draw(in: NSRect(x: margin, y: margin, width: rep.size.width, height: rep.size.height), from: .zero,
                 operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    static func write(_ rep: NSBitmapImageRep, _ url: URL) {
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}

@MainActor
func renderPill(_ scenario: Scenario, expanded: Bool, lang: UILanguage, appearance: Appearance, dir: URL) {
    LanguageModel.shared.set(lang)
    let state = Fixtures.state(scenario, lang)
    let ui = PillUIModel()
    ui.expanded = expanded
    var reported = CGSize.zero
    let actions = PillActions(sizeChanged: { reported = $0 }, expand: {}, collapse: {}, dragChanged: {}, dragEnded: {},
                              editingChanged: { _ in })
    let hosting = FittingHostingView(rootView: PillRootView(state: state, ui: ui, commands: NoCommands(), actions: actions))
    // Start from the panel's initial size, then apply exactly what PillWindowController does.
    let window = Renderer.host(hosting, size: CGSize(width: PillLayout.collapsedMinWidth, height: PillLayout.collapsedHeight),
                               appearance: appearance.appearance)
    Renderer.spin()
    let size = hosting.fittedSize
    window.setContentSize(size)
    hosting.frame = NSRect(origin: .zero, size: size)
    Renderer.spin()
    let check = hosting.fittedSize
    if check != size || abs(reported.width - size.width) > 1 || abs(reported.height - size.height) > 1 {
        print("WARNING size mismatch: fitted \(size) recheck \(check) reported \(reported)")
    }
    let name = "pill-\(scenario.rawValue)\(expanded ? "-expanded" : "")-\(lang.rawValue)-\(appearance.rawValue).png"
    Renderer.write(Renderer.composite(Renderer.bitmap(hosting), appearance: appearance), dir.appendingPathComponent(name))
    print("\(name)\t\(Int(size.width))x\(Int(size.height)) pt")
    window.contentView = nil
    window.close()
}

@MainActor
func renderWindow(_ scenario: Scenario, lang: UILanguage, appearance: Appearance, dir: URL, fullHeight: Bool = true) {
    LanguageModel.shared.set(lang)
    let state = Fixtures.state(scenario, lang)
    let width: CGFloat = 520
    let view = MainWindowView(state: state, commands: NoCommands(), editingChanged: { _ in }, scrollable: !fullHeight)
    var height: CGFloat = 640
    if fullHeight {
        let measure = NSHostingController(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        height = ceil(measure.sizeThatFits(in: CGSize(width: width, height: 10_000)).height)
    }
    let hosting = NSHostingView(rootView: view)
    hosting.sizingOptions = []
    let window = Renderer.host(hosting, size: CGSize(width: width, height: height), appearance: appearance.appearance)
    Renderer.spin(0.1)
    let suffix = fullHeight ? "" : "-640"
    let name = "window-\(scenario.rawValue)-\(lang.rawValue)-\(appearance.rawValue)\(suffix).png"
    Renderer.write(Renderer.bitmap(hosting), dir.appendingPathComponent(name))
    print("\(name)\t\(Int(width))x\(Int(height)) pt")
    window.contentView = nil
    window.close()
}

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments.dropFirst()
    guard let path = arguments.first(where: { !$0.hasPrefix("-") }) else {
        fputs("usage: MeetingNotesPreviews <output dir> [--only <name-substring>]\n", stderr)
        exit(64)
    }
    let only = arguments.firstIndex(of: "--only").flatMap { arguments.index(after: $0) < arguments.endIndex ? arguments[arguments.index(after: $0)] : nil }
    let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)  // no Dock icon, never active, no windows on screen
    Settings.registerDefaults()  // registration domain only (in memory)

    func wanted(_ name: String) -> Bool { only.map { name.contains($0) } ?? true }

    for appearance in Appearance.allCases {
        for scenario in Scenario.allCases {
            for expanded in [false, true] where wanted("pill-\(scenario.rawValue)") {
                renderPill(scenario, expanded: expanded, lang: .vi, appearance: appearance, dir: dir)
            }
            if wanted("window-\(scenario.rawValue)") {
                renderWindow(scenario, lang: .vi, appearance: appearance, dir: dir)
            }
        }
        for scenario in [Scenario.idle, .recordingWarning, .recordingLive, .processing] {
            for expanded in [false, true] where wanted("pill-\(scenario.rawValue)") {
                renderPill(scenario, expanded: expanded, lang: .en, appearance: appearance, dir: dir)
            }
            if wanted("window-\(scenario.rawValue)") { renderWindow(scenario, lang: .en, appearance: appearance, dir: dir) }
        }
        if wanted("window-recording-warning") {
            renderWindow(.recordingWarning, lang: .vi, appearance: appearance, dir: dir, fullHeight: false)
        }
    }
    exit(0)
}
