import AppKit
import MeetingNotesCore
import MeetingNotesUI

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
        case .idle, .starting, .stopping: return c.pill.label()
        case .recording: return tr(.statusRecordingTime, c.clock.elapsed)
        case .paused: return tr(.statusPausedTime, c.clock.elapsed)
        case .processing(let s):
            if let waiting = s.waiting { return waiting }
            return c.pill.label() + (Format.eta(s.etaSec).map { " · \($0)" } ?? "")
        case .ready(let info): return info.hasNotes ? tr(.statusNotesReady, Format.clip(info.title, 40)) : c.pill.label()
        case .error(let error): return Format.clip(error.message, 60)
        }
    }

    static func recordingItems(_ c: AppController, hub: UIHub, source: ActionSource) -> [NSMenuItem] {
        let m = c.machine
        let start = ActionMenuItem(tr(.actionStartRecording), enabled: m.isEnabled(.start)) { c.startRecording(source: source) }
        start.setHotKey(c.hotkey)
        let pause: ActionMenuItem
        if m.phase == .paused {
            pause = ActionMenuItem(tr(.actionResume)) { c.perform(.resume, source: source) }
        } else {
            pause = ActionMenuItem(tr(.actionPause), enabled: m.isEnabled(.pause)) { c.perform(.pause, source: source) }
        }
        pause.setHotKey(c.pauseHotkey)
        let stop = ActionMenuItem(c.state.stopLabel, enabled: m.isEnabled(.stop)) {
            c.perform(.stop, source: source)
        }
        let discard = ActionMenuItem(tr(.actionDiscardEllipsis), enabled: m.isEnabled(.discard)) {
            hub.showMainWindow()
            c.perform(.requestDiscard, source: .window)
        }
        return [start, pause, stop, discard]
    }

    static func fillStatusMenu(_ menu: NSMenu, controller c: AppController, hub: UIHub) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.addItem(disabledItem(statusLine(c)))
        menu.addItem(ActionMenuItem(tr(.actionOpenMain)) { hub.showMainWindow() })
        menu.addItem(.separator())
        recordingItems(c, hub: hub, source: .menu).forEach(menu.addItem)
        menu.addItem(ActionMenuItem(tr(.actionShowControls)) { hub.showControls(expand: true) })
        menu.addItem(.separator())
        menu.addItem(recentsMenuItem(c, hub: hub))
        menu.addItem(ActionMenuItem(tr(.actionOpenLastNotes)) { c.openLastNotes() })
        menu.addItem(ActionMenuItem(tr(.actionOpenNotesFolder)) { c.openNotesFolder() })
        menu.addItem(.separator())
        let settings = ActionMenuItem(tr(.actionSettingsEllipsis)) { hub.showSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(ActionMenuItem(tr(.actionResetPillPosition)) { hub.resetPillPosition() })
        menu.addItem(.separator())
        let quit = ActionMenuItem(tr(.menuQuit)) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    static func dockMenu(controller c: AppController, hub: UIHub) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(disabledItem(statusLine(c)))
        menu.addItem(ActionMenuItem(tr(.actionOpenMain)) { hub.showMainWindow() })
        let items = recordingItems(c, hub: hub, source: .dock)
        items.prefix(3).forEach { item in
            item.keyEquivalent = ""
            menu.addItem(item)
        }
        menu.addItem(ActionMenuItem(tr(.actionShowControls)) { hub.showControls(expand: true) })
        menu.addItem(ActionMenuItem(tr(.actionOpenLastNotes)) { c.openLastNotes() })
        return menu
    }

    static func recentsMenuItem(_ c: AppController, hub: UIHub) -> NSMenuItem {
        let parent = NSMenuItem(title: tr(.menuRecentMeetings), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let recents = c.recents()
        if recents.isEmpty { submenu.addItem(disabledItem(tr(.menuNoMeetings))) }
        let percent = c.processingSnapshot.flatMap { $0.waiting == nil ? $0.percent : nil }
        for meeting in recents {
            let status = meeting.status.label(percent: meeting.status == .processing ? percent : nil)
            let item = NSMenuItem(title: "\(Format.clip(meeting.title, 44)) — \(status)", action: nil, keyEquivalent: "")
            let actions = NSMenu()
            actions.autoenablesItems = false
            actions.addItem(ActionMenuItem(tr(.actionOpenNotes), enabled: meeting.hasNotes) { hub.openNotes(meeting.url) })
            actions.addItem(ActionMenuItem(tr(.actionShowInFinder)) { c.reveal(meeting.url) })
            switch meeting.status {
            case .failed(let error):
                actions.addItem(ActionMenuItem(tr(.actionRetry)) { c.retry(folder: meeting.url) })
                if let error { actions.addItem(disabledItem(Format.clip(error, 70))) }
            case .notProcessed, .cancelled:
                actions.addItem(ActionMenuItem(tr(.actionCreateNotes)) { c.createNotes(folder: meeting.url) })
            case .done:
                actions.addItem(ActionMenuItem(tr(.actionReprocess)) { c.retry(folder: meeting.url) })
            default:
                break
            }
            if meeting.hasLog { actions.addItem(ActionMenuItem(tr(.actionShowLog)) { c.openInDefaultApp(meeting.logURL) }) }
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
        appMenu.addItem(withTitle: tr(.menuAbout), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = ActionMenuItem(tr(.actionSettingsEllipsis)) { hubProvider()?.showSettings() }
        settings.keyEquivalent = ","
        appMenu.addItem(settings)
        let open = ActionMenuItem(tr(.actionOpenMain)) { hubProvider()?.showMainWindow() }
        open.keyEquivalent = "0"
        appMenu.addItem(open)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr(.menuHide), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr(.menuQuit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: tr(.menuEdit))
        edit.addItem(withTitle: tr(.menuUndo), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: tr(.menuRedo), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: tr(.menuCut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr(.menuCopy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr(.menuPaste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr(.menuSelectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let recordingItem = NSMenuItem()
        let recording = NSMenu(title: tr(.menuRecording))
        recording.delegate = recordingDelegate
        recordingItem.submenu = recording
        main.addItem(recordingItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: tr(.menuWindow))
        window.addItem(withTitle: tr(.menuMinimize), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: tr(.menuClose), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
    private var iconKey: StatusIcon?

    init(controller: AppController, hub: UIHub) {
        self.controller = controller
        self.hub = hub
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.toolTip = "Meeting Notes"
    }

    func update(force: Bool = false) {
        item.button?.toolTip = "Meeting Notes – \(controller.pill.label())"
        item.button?.setAccessibilityLabel(item.button?.toolTip)
        let icon = StatusIcon(controller.pill)
        guard force || icon != iconKey else { return }
        iconKey = icon
        item.button?.image = StatusIconImage.make(icon)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuFactory.fillStatusMenu(menu, controller: controller, hub: hub)
    }
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
        menu.addItem(ActionMenuItem(tr(.actionOpenMain)) { hub.showMainWindow() })
        menu.addItem(ActionMenuItem(tr(.actionShowControls)) { hub.showControls(expand: true) })
        menu.addItem(MenuFactory.recentsMenuItem(controller, hub: hub))
        menu.addItem(ActionMenuItem(tr(.actionOpenLastNotes)) { [controller] in controller.openLastNotes() })
    }
}
