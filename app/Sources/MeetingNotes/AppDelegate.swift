import AppKit
import MeetingNotesCore
import MeetingNotesLaunch
import MeetingNotesUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    private(set) var hub: UIHub?
    private var recordingMenuDelegate: RecordingMenuDelegate?
    private var pendingURLs: [URLCommand] = []
    /// Kept alive while the Dock shows it (its items are their own targets).
    private var dockMenu: NSMenu?

    func applicationWillFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)  // a dead worker must not kill the app when we write to its stdin
        Settings.registerDefaults()
        LanguageModel.shared.set(Settings.uiLanguage)
        NSApp.setActivationPolicy(Settings.showInDock ? .regular : .accessory)
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        recordingMenuDelegate = RecordingMenuDelegate(controller: controller, hub: { [weak self] in self?.hub })
        buildMainMenu()
    }

    private func buildMainMenu() {
        guard let recordingMenuDelegate else { return }
        NSApp.mainMenu = MenuFactory.mainMenu(controller: controller, hubProvider: { [weak self] in self?.hub },
                                              recordingDelegate: recordingMenuDelegate)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hub = UIHub(controller: controller)
        self.hub = hub
        hub.onLanguageChanged = { [weak self] in self?.buildMainMenu() }
        controller.ui = hub
        controller.state.showGettingStarted = !Settings.onboardingDone
        controller.launch()
        hub.start()
        // The main window is the app's home (it also holds the permission checklist on first launch). Opened by the
        // launcher agent for a meeting: stay quiet, the detector's scan at launch shows the usual record prompt.
        if !Self.openedForMeeting || !Settings.onboardingDone { hub.showMainWindow() }
        let pending = pendingURLs
        pendingURLs = []
        pending.forEach(controller.handle)
    }

    /// Launched by MeetingNotesLauncher because a meeting started (`--opened-for-meeting`).
    static let openedForMeeting = CommandLine.arguments.contains(MeetingLauncher.openedForMeetingArgument)

    /// Dock icon click, `open -a MeetingNotes`, Finder/Spotlight while running: show the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        hub?.showMainWindow()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.refreshPermissions()
        controller.setupAppBecameActive()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let hub else { return nil }
        let menu = MenuFactory.dockMenu(controller: controller, hub: hub)
        dockMenu = menu
        return menu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.isCapturing else {
            controller.shutdownNow()
            return .terminateNow
        }
        Task { @MainActor in
            await controller.prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        guard let command = URLCommand(string: text) else {
            hub?.showToast(tr(.toastUnknownCommand, text))
            return
        }
        if hub == nil {
            pendingURLs.append(command)
        } else {
            controller.handle(command)
        }
    }
}

