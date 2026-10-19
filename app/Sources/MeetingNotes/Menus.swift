import AppKit
import MeetingNotesCore

/// Menu item with a closure action.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

private func disabledItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
}

/// Builds the status, Dock and app menus from the current state (on open; nothing is kept live).
@MainActor
enum MenuFactory {
    static func statusLine(_ c: AppController) -> String {
        switch c.pill {
        case .idle(let attention): return attention ? "Permissions need attention" : "Ready"
        case .starting: return "Starting…"
        case .recording: return "Recording \(c.clock.elapsed)"
        case .paused: return "Paused \(c.clock.elapsed)"
        case .stopping: return "Saving…"
        case .processing(let s):
            if let waiting = s.waiting { return waiting }
            return "Writing notes \(s.percent)%" + (Format.eta(s.etaSec).map { " · \($0)" } ?? "")
        case .ready(let info): return info.hasNotes ? "Notes ready: \(Format.clip(info.title, 40))" : "Recording saved"
        case .error(let error): return Format.clip(error.message, 60)
        }
    }

    static func recordingItems(_ c: AppController, hub: UIHub, source: ActionSource) -> [NSMenuItem] {
        let m = c.machine
        let start = ActionMenuItem("Start recording", enabled: m.isEnabled(.start)) { c.startRecording(source: source) }
        start.setHotKey(c.hotkey)
        let pause: ActionMenuItem
        if m.phase == .paused {
            pause = ActionMenuItem("Resume") { c.perform(.resume, source: source) }
        } else {
            pause = ActionMenuItem("Pause", enabled: m.isEnabled(.pause)) { c.perform(.pause, source: source) }
        }
        pause.setHotKey(c.pauseHotkey)
        let stop = ActionMenuItem(Settings.createNotesMode == .manual ? "Stop" : "Stop & create notes", enabled: m.isEnabled(.stop)) {
            c.perform(.stop, source: source)
        }
        let discard = ActionMenuItem("Discard…", enabled: m.isEnabled(.discard)) {
            hub.showControls(expand: true)
            c.perform(.requestDiscard, source: .pill)
        }
        return [start, pause, stop, discard]
    }

    static func fillStatusMenu(_ menu: NSMenu, controller c: AppController, hub: UIHub) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.addItem(disabledItem(statusLine(c)))
        menu.addItem(.separator())
        recordingItems(c, hub: hub, source: .menu).forEach(menu.addItem)
        menu.addItem(ActionMenuItem("Show controls") { hub.showControls(expand: true) })
        menu.addItem(.separator())
        menu.addItem(recentsMenuItem(c, hub: hub))
        menu.addItem(ActionMenuItem("Open last notes") { c.openLastNotes() })
        menu.addItem(ActionMenuItem("Open notes folder") { c.openNotesFolder() })
        menu.addItem(.separator())
        let settings = ActionMenuItem("Settings…") { hub.showSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(ActionMenuItem("Permissions…") { hub.showOnboarding() })
        menu.addItem(ActionMenuItem("Reset pill position") { hub.resetPillPosition() })
        menu.addItem(.separator())
        let quit = ActionMenuItem("Quit Meeting Notes") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    static func dockMenu(controller c: AppController, hub: UIHub) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(disabledItem(statusLine(c)))
        let items = recordingItems(c, hub: hub, source: .dock)
        items.prefix(3).forEach { item in
            item.keyEquivalent = ""
            menu.addItem(item)
        }
        menu.addItem(ActionMenuItem("Show controls") { hub.showControls(expand: true) })
        menu.addItem(ActionMenuItem("Open last notes") { c.openLastNotes() })
        return menu
    }

    static func recentsMenuItem(_ c: AppController, hub: UIHub) -> NSMenuItem {
        let parent = NSMenuItem(title: "Recent meetings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let recents = c.recents()
        if recents.isEmpty { submenu.addItem(disabledItem("No meetings yet")) }
        let percent = c.processingSnapshot.flatMap { $0.waiting == nil ? $0.percent : nil }
        for meeting in recents {
            var status = meeting.status.label
            if meeting.status == .processing, let percent { status = "processing \(percent)%" }
            let item = NSMenuItem(title: "\(Format.clip(meeting.title, 44)) — \(status)", action: nil, keyEquivalent: "")
            let actions = NSMenu()
            actions.autoenablesItems = false
            actions.addItem(ActionMenuItem("Open notes", enabled: meeting.hasNotes) { hub.openNotes(meeting.url) })
            actions.addItem(ActionMenuItem("Show in Finder") { c.reveal(meeting.url) })
            switch meeting.status {
            case .failed(let error):
                actions.addItem(ActionMenuItem("Retry") { c.retry(folder: meeting.url) })
                if let error { actions.addItem(disabledItem(Format.clip(error, 70))) }
            case .notProcessed, .cancelled:
                actions.addItem(ActionMenuItem("Create notes") { c.createNotes(folder: meeting.url) })
            case .done:
                actions.addItem(ActionMenuItem("Reprocess") { c.retry(folder: meeting.url) })
            default:
                break
            }
            if meeting.hasLog { actions.addItem(ActionMenuItem("Show pipeline log") { c.openInDefaultApp(meeting.logURL) }) }
            item.submenu = actions
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    /// Main menu bar (visible when the app is active in Dock mode).
    static func mainMenu(controller c: AppController, hubProvider: @escaping () -> UIHub?, recordingDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Meeting Notes", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = ActionMenuItem("Settings…") { hubProvider()?.showSettings() }
        settings.keyEquivalent = ","
        appMenu.addItem(settings)
        appMenu.addItem(ActionMenuItem("Permissions…") { hubProvider()?.showOnboarding() })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Meeting Notes", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Meeting Notes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let recordingItem = NSMenuItem()
        let recording = NSMenu(title: "Recording")
        recording.delegate = recordingDelegate
        recordingItem.submenu = recording
        main.addItem(recordingItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        return main
    }
}

/// Compact icon-only menu bar item (secondary entry point; the app never depends on it).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: AppController
    private unowned let hub: UIHub
    private var iconKey = ""

    init(controller: AppController, hub: UIHub) {
        self.controller = controller
        self.hub = hub
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.toolTip = "Meeting Notes"
    }

    func update() {
        let key: String
        switch controller.pill {
        case .idle(let attention): key = attention ? "attention" : "idle"
        case .starting, .stopping: key = "busy"
        case .recording: key = "recording"
        case .paused: key = "paused"
        case .processing: key = "processing"
        case .ready: key = "ready"
        case .error: key = "error"
        }
        guard key != iconKey else { return }
        iconKey = key
        item.button?.image = Self.icon(key)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuFactory.fillStatusMenu(menu, controller: controller, hub: hub)
    }

    private static func icon(_ key: String) -> NSImage? {
        if key == "recording" { return redDot }
        let name: String
        switch key {
        case "attention", "error": name = "exclamationmark.triangle"
        case "busy": name = "ellipsis.circle"
        case "paused": name = "pause.circle"
        case "processing": name = "arrow.triangle.2.circlepath.circle"
        case "ready": name = "checkmark.circle"
        default: name = "mic"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Meeting Notes")
        image?.isTemplate = true
        return image
    }

    private static let redDot: NSImage = {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Recording"
        return image
    }()
}

/// Rebuilds the main menu's Recording menu when it opens.
@MainActor
final class RecordingMenuDelegate: NSObject, NSMenuDelegate {
    let controller: AppController
    var hub: () -> UIHub?

    init(controller: AppController, hub: @escaping () -> UIHub?) {
        self.controller = controller
        self.hub = hub
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        guard let hub = hub() else { return }
        MenuFactory.recordingItems(controller, hub: hub, source: .menu).forEach { item in
            item.keyEquivalent = ""  // global hotkeys handle these
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Show controls") { hub.showControls(expand: true) })
        menu.addItem(MenuFactory.recentsMenuItem(controller, hub: hub))
        menu.addItem(ActionMenuItem("Open last notes") { [controller] in controller.openLastNotes() })
    }
}
