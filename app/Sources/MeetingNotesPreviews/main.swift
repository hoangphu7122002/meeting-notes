import AppKit
import MeetingNotesCore
import MeetingNotesUI
import SwiftUI

// `swift run MeetingNotesPreviews <dir>`: renders the pill (collapsed + expanded) and the main window in
// every state, light and dark, at 2x, into <dir>. Offscreen only: no window is ever ordered on screen,
// nothing is recorded, and the app is not started (this target does not contain it).
// The renderer process is never active, so AppKit draws prominent (tinted) buttons in their inactive
// grey style, as in a background window.

/// Commands of the previews: nothing happens.
@MainActor
final class NoCommands: AppCommands {
    func perform(_ command: RecorderCommand, source: ActionSource) {}
    func startRecording(source: ActionSource) {}
    func titleEditingBegan() {}
    func commitTitle() {}
    func processWaitingNow() {}
    func cancelProcessing() {}
    func performErrorAction() {}
    func dismissError() {}
    func openNotes(_ folder: URL) {}
    func reveal(_ url: URL) {}
    func openInDefaultApp(_ url: URL) {}
    func copySummary(folder: URL) {}
    func createNotes(folder: URL) {}
    func retry(folder: URL) {}
    func openLastNotes() {}
    func openNotesFolder() {}
    func hidePillForAnHour() {}
    func showSettings() {}
    func showMainWindow() {}
    func fixPermission(_ kind: PermissionKind) {}
    func openPermissionSettings(_ kind: PermissionKind) {}
    func runAudioTest() {}
    func dismissGettingStarted() {}
    func relaunch() {}
    func setLanguage(_ language: UILanguage) {}
    func setDetectionEnabled(_ enabled: Bool) {}
    func setCreateNotesMode(_ mode: CreateNotesMode) {}
    func setSummaryModel(_ model: SummaryModel) {}
    func chooseNotesFolder() {}
    func resetNotesFolder() {}
    func setShowInDock(_ show: Bool) {}
    func setPillVisibility(whileRecording: Bool, whenIdle: Bool) {}
    func resetPillPosition() {}
}

enum Scenario: String, CaseIterable {
    case idle, firstLaunch = "first-launch", recording, recordingWarning = "recording-warning", paused
    case discardConfirm = "discard-confirm", processing, ready, error
}

enum Appearance: String, CaseIterable {
    case light, dark

    var appearance: NSAppearance { NSAppearance(named: self == .dark ? .darkAqua : .aqua)! }
}

@MainActor
enum Fixtures {
    static let notesDir = URL(fileURLWithPath: "/Users/demo/MeetingNotes", isDirectory: true)

    static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text) ?? Date()
    }

    static func longTitle(_ lang: UILanguage) -> String {
        lang == .vi ? "Họp giao ban tuần – kế hoạch ra mắt sản phẩm quý 4 với đội thiết kế và kỹ thuật"
            : "Weekly sync – Q4 product launch plan with the design and engineering teams"
    }

    static func recents(_ lang: UILanguage, processing: Bool) -> [RecentMeeting] {
        let vi = lang == .vi
        func meeting(_ name: String, _ title: String, _ date: String, _ status: RecentMeeting.Status, _ duration: Double?, notes: Bool) -> RecentMeeting {
            RecentMeeting(url: notesDir.appendingPathComponent(name, isDirectory: true), title: title, date: Self.date(date),
                          status: status, durationSec: duration, hasNotes: notes)
        }
        var list = [
            meeting("2026-10-19 0930 Weekly", vi ? "Họp giao ban tuần – kế hoạch quý 4" : "Weekly sync – Q4 planning", "2026-10-19 09:30",
                    processing ? .processing : .done, 2537, notes: !processing),
            meeting("2026-10-18 1400 Design", vi ? "Duyệt thiết kế màn hình thanh toán" : "Checkout screen design review", "2026-10-18 14:00",
                    .done, 1820, notes: true),
            meeting("2026-10-17 1100 Client", vi ? "Gọi với khách hàng Minh Phát" : "Call with Minh Phat (client)", "2026-10-17 11:00",
                    .failed("Ollama is not reachable"), 3105, notes: false),
            meeting("2026-10-16 1630 1on1", vi ? "1:1 với Lan" : "1:1 with Lan", "2026-10-16 16:30", .notProcessed, 905, notes: false),
            meeting("2026-10-15 1000 Retro", vi ? "Retro sprint 42" : "Sprint 42 retro", "2026-10-15 10:00", .done, 2710, notes: true),
        ]
        if !processing { list.removeFirst() }
        return list
    }

    static func processingSnapshot(_ lang: UILanguage) -> ProcessingSnapshot {
        var snapshot = ProcessingSnapshot(job: "j", folder: notesDir.appendingPathComponent("x").path, title: longTitle(lang))
        for line in [
            #"{"event":"stage","stage":"prepare","status":"done","overall":0.03,"elapsed_sec":1.4,"job":"j"}"#,
            #"{"event":"stage","stage":"diarize","status":"done","overall":0.28,"elapsed_sec":42,"job":"j"}"#,
            #"{"event":"progress","stage":"transcribe","fraction":0.4,"overall":0.42,"eta_sec":130,"message":"Transcribing block 4/10","job":"j"}"#,
            #"{"event":"partial","folder":"/Users/demo/MeetingNotes/x","notes":"/Users/demo/MeetingNotes/x/notes.md","job":"j"}"#,
        ] { if let event = WorkerEvent(line: line) { snapshot.apply(event) } }
        snapshot.queued = 1
        return snapshot
    }

    static func state(_ scenario: Scenario, _ lang: UILanguage) -> AppState {
        let state = AppState(notesDir: notesDir, createNotesMode: .rightAway)
        state.isBundled = true
        state.hotkey = HotKeySpec.parse(HotKeySpec.defaultRecord)
        state.pauseHotkey = HotKeySpec.parse(HotKeySpec.defaultPause)
        state.microphone = .granted
        state.screenCapture = .granted
        state.notifications = .notDetermined
        state.recents = recents(lang, processing: false)
        state.lastResult = ReadyInfo(folder: notesDir.appendingPathComponent("a").path, title: "x", notesPath: "x")
        state.clock.elapsed = "42:17"
        state.levels.me = 0.72
        state.levels.them = 0.48
        switch scenario {
        case .idle:
            state.pill = .idle(attention: false)
        case .firstLaunch:
            state.showGettingStarted = true
            state.screenCapture = .denied
            state.microphone = .notDetermined
            state.recents = []
            state.lastResult = nil
            state.pill = .idle(attention: true)
        case .recording, .recordingWarning, .discardConfirm:
            state.machine = RecorderMachine(phase: .recording)
            state.pill = .recording
            state.titleDraft = longTitle(lang)
            state.recents = [RecentMeeting(url: notesDir.appendingPathComponent("now"), title: longTitle(lang), date: date("2026-10-19 09:30"),
                                           status: .recording)] + recents(lang, processing: false)
            if scenario == .recordingWarning {
                state.systemAudio = .notPermitted
                state.screenCapture = .denied
                state.levels.them = 0
                state.recordingWarnings = [tr(.warnSystemNotRecorded, lang == .vi
                    ? "Người dùng đã từ chối quyền ghi màn hình và âm thanh hệ thống cho ứng dụng"
                    : "The user declined TCCs for application, window, display capture")]
            }
            if scenario == .discardConfirm {
                var machine = RecorderMachine(phase: .recording)
                _ = machine.handle(.requestDiscard)
                state.machine = machine
            }
        case .paused:
            state.machine = RecorderMachine(phase: .paused)
            state.pill = .paused
            state.titleDraft = longTitle(lang)
            state.levels.me = 0
            state.levels.them = 0
        case .processing:
            state.pill = .processing(processingSnapshot(lang))
            state.titleDraft = longTitle(lang)
            state.jobsActive = true
            state.recents = recents(lang, processing: true)
        case .ready:
            let info = ReadyInfo(folder: notesDir.appendingPathComponent("r").path, title: longTitle(lang), notesPath: "notes.md")
            state.pill = .ready(info)
            state.titleDraft = info.title
            state.recents = recents(lang, processing: true).map {
                $0.status == .processing
                    ? RecentMeeting(url: $0.url, title: $0.title, date: $0.date, status: .done, durationSec: $0.durationSec, hasNotes: true) : $0
            }
        case .error:
            let message = tr(.errProcessingFailed, lang == .vi
                ? "Không kết nối được Ollama tại http://127.0.0.1:11434 (Connection refused). Hãy mở Ollama rồi thử lại."
                : "Ollama is not reachable at http://127.0.0.1:11434 (connection refused). Start Ollama and retry.")
            state.pill = .error(PillError(message, action: .retry(folder: notesDir.appendingPathComponent("e").path)))
        }
        return state
    }
}

@MainActor
enum Renderer {
    static func spin(_ seconds: Double = 0.06) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Offscreen window (never ordered front) that gives the view a backing and an appearance.
    static func host(_ view: NSView, size: CGSize, appearance: NSAppearance) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = .clear
        window.isOpaque = false
        view.appearance = appearance
        window.contentView = view
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
        for scenario in [Scenario.idle, .recordingWarning, .processing] {
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
