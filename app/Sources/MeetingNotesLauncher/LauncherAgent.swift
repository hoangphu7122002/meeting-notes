// Opens MeetingNotes when a meeting starts while it is not running (Launcher). Rules: `MeetingLaunchPolicy`.

import AppKit
import MeetingNotesLaunch
import os

final class LauncherAgent {
    private let appURL: URL
    private let dryRun: Bool
    private let mic = MicMonitor()
    private let log = Logger(subsystem: MeetingApps.ownBundleID, category: "launcher")
    private var policy = MeetingLaunchPolicy()
    private var debounce = Debounce(delay: 2)
    private var pendingLaunches: [String] = []
    private var micPending = false
    private var observers: [NSObjectProtocol] = []

    init(appURL: URL, dryRun: Bool) {
        self.appURL = appURL
        self.dryRun = dryRun
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                            queue: .main) { [weak self] note in
            guard let id = Self.bundleID(note), MeetingApps.isLaunchTrigger(bundleID: id) else { return }
            self?.pendingLaunches.append(id)
            self?.schedule()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                            queue: .main) { [weak self] note in
            guard Self.bundleID(note) == MeetingApps.ownBundleID else { return }
            self?.policy.appExited(at: Date())
        })
        mic.onStarted = { [weak self] in
            self?.micPending = true
            self?.schedule()
        }
        mic.start()
        log.info("watching for meetings (app \(self.appURL.path, privacy: .public), dry run \(self.dryRun))")
    }

    // MARK: - Private

    private func schedule() {
        guard let due = debounce.signal(at: Date()) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due.timeIntervalSinceNow) + 0.05) { [weak self] in
            self?.check()
        }
    }

    private func check() {
        guard debounce.fire(at: Date()) else { return }
        var triggers = pendingLaunches.map { LaunchTrigger.appLaunched(bundleID: $0) }
        pendingLaunches = []
        if micPending, mic.isRunning {  // still running after the debounce: not a blip
            triggers.append(.micStarted(captureBundleIDs: MicMonitor.captureBundleIDs()))
        }
        micPending = false
        guard !triggers.isEmpty else { return }
        let prefs = Self.readPrefs()
        let running = appIsRunning
        for trigger in triggers {
            let decision = policy.evaluate(trigger, appRunning: running, prefs: prefs, now: Date())
            switch decision {
            case .launch(let app):
                log.info("\(app, privacy: .public) started a meeting: opening MeetingNotes")
                open()
                return
            case .skip(let reason):
                log.debug("\(String(describing: trigger), privacy: .public): skip (\(reason.rawValue, privacy: .public))")
            }
        }
    }

    private var appIsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: MeetingApps.ownBundleID).contains {
            $0.processIdentifier != getpid() && !$0.isTerminated
        }
    }

    private func open() {
        guard !dryRun else {
            print("would open \(appURL.path) \(MeetingLauncher.openedForMeetingArgument)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        config.arguments = [MeetingLauncher.openedForMeetingArgument]
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [log] _, error in
            if let error { log.error("could not open MeetingNotes: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private static func bundleID(_ note: Notification) -> String? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    /// The app's preferences (its UserDefaults domain), re-read on every check so Settings changes apply at once.
    private static func readPrefs() -> LauncherPrefs {
        let domain = MeetingApps.ownBundleID as CFString
        CFPreferencesAppSynchronize(domain)
        return LauncherPrefs { CFPreferencesCopyAppValue($0 as CFString, domain) }
    }
}
