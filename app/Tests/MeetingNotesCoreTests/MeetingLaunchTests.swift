import Foundation
import Testing
@testable import MeetingNotesCore
@testable import MeetingNotesLaunch

@Suite("Open the app when a meeting starts")
struct MeetingLaunchTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let zoomLaunch = LaunchTrigger.appLaunched(bundleID: "us.zoom.xos")
    private let chromeMic = LaunchTrigger.micStarted(captureBundleIDs: ["com.google.Chrome.helper"])

    @Test func bundleIDMatching() {
        #expect(MeetingApps.name(bundleID: "us.zoom.xos") == "Zoom")
        #expect(MeetingApps.name(bundleID: "com.google.Chrome.helper") == "Chrome")
        #expect(MeetingApps.name(bundleID: "com.microsoft.teams2") == "Teams")
        #expect(MeetingApps.name(bundleID: "us.zoom.xosx") == nil)  // prefix must end at a dot
        #expect(MeetingApps.name(bundleID: "com.apple.Music") == nil)
        #expect(MeetingApps.isLaunchTrigger(bundleID: "us.zoom.xos"))
        #expect(MeetingApps.isLaunchTrigger(bundleID: "com.apple.FaceTime"))
        #expect(MeetingApps.isLaunchTrigger(bundleID: "Cisco-Systems.Spark"))
        // Open all day: only their microphone use counts.
        #expect(!MeetingApps.isLaunchTrigger(bundleID: "com.google.Chrome"))
        #expect(!MeetingApps.isLaunchTrigger(bundleID: "com.tinyspeck.slackmacgap"))
        // Every launch trigger is a known meeting app (it gets a name for the log and the prompt).
        for id in MeetingApps.launchTriggers { #expect(MeetingApps.name(bundleID: id) != nil) }
    }

    @Test func ownProcessesNeverTrigger() {
        #expect(MeetingApps.isOwn(bundleID: "com.hoangphu.meetingnotes"))
        #expect(MeetingApps.isOwn(bundleID: "com.hoangphu.meetingnotes.launcher"))
        #expect(!MeetingApps.isOwn(bundleID: "com.hoangphu.meetingnotesx"))
        let own = LaunchTrigger.micStarted(captureBundleIDs: ["com.hoangphu.meetingnotes", "com.hoangphu.meetingnotes.diarize"])
        #expect(MeetingLaunchPolicy.meetingApp(for: own) == nil)
        #expect(MeetingLaunchPolicy().decide(own, appRunning: false, prefs: LauncherPrefs(), now: t0) == .skip(.notAMeeting))
        // Our own capture next to a real meeting app: the meeting app counts.
        let mixed = LaunchTrigger.micStarted(captureBundleIDs: ["com.hoangphu.meetingnotes", "us.zoom.xos"])
        #expect(MeetingLaunchPolicy.meetingApp(for: mixed) == "Zoom")
        #expect(MeetingLaunchPolicy.meetingApp(for: .micStarted(captureBundleIDs: ["com.apple.VoiceMemos"])) == nil)
        #expect(MeetingLaunchPolicy.meetingApp(for: .appLaunched(bundleID: "com.google.Chrome")) == nil)
    }

    @Test func launchesOnlyWhenTheAppIsNotRunning() {
        var policy = MeetingLaunchPolicy()
        let running = policy.evaluate(zoomLaunch, appRunning: true, prefs: LauncherPrefs(), now: t0)
        #expect(running == .skip(.appRunning))
        #expect(policy.lastLaunch == nil)
        let quit = policy.evaluate(chromeMic, appRunning: false, prefs: LauncherPrefs(), now: t0)
        #expect(quit == .launch(app: "Chrome"))
        #expect(policy.lastLaunch == t0)
    }

    @Test func cooldownAfterALaunch() {
        var policy = MeetingLaunchPolicy(cooldown: 600, quitGrace: 0)
        let first = policy.evaluate(zoomLaunch, appRunning: false, prefs: LauncherPrefs(), now: t0)
        let soon = policy.evaluate(chromeMic, appRunning: false, prefs: LauncherPrefs(), now: t0.addingTimeInterval(599))
        #expect(first == .launch(app: "Zoom"))
        #expect(soon == .skip(.cooldown))
        #expect(policy.lastLaunch == t0)  // a skipped trigger does not extend the cooldown
        let later = policy.evaluate(chromeMic, appRunning: false, prefs: LauncherPrefs(), now: t0.addingTimeInterval(600))
        #expect(later == .launch(app: "Chrome"))
    }

    @Test func quitRespectedForAGracePeriodNotForever() {
        var policy = MeetingLaunchPolicy(cooldown: 0, quitGrace: 300)
        policy.appExited(at: t0)
        #expect(policy.decide(chromeMic, appRunning: false, prefs: LauncherPrefs(), now: t0.addingTimeInterval(10)) == .skip(.recentlyQuit))
        #expect(policy.decide(chromeMic, appRunning: false, prefs: LauncherPrefs(), now: t0.addingTimeInterval(300)) == .launch(app: "Chrome"))
    }

    @Test func defaultsOpenForANewMeetingRightAway() {
        var policy = MeetingLaunchPolicy()
        #expect(policy.cooldown == 15 && policy.quitGrace == 0)
        // Quit, then join a meeting moments later: no post-quit hold.
        policy.appExited(at: t0)
        #expect(policy.evaluate(chromeMic, appRunning: false, prefs: LauncherPrefs(), now: t0.addingTimeInterval(1)) == .launch(app: "Chrome"))
        // A duplicate trigger while that launch is still starting is suppressed, briefly.
        #expect(policy.decide(zoomLaunch, appRunning: false, prefs: LauncherPrefs(), now: t0.addingTimeInterval(5)) == .skip(.cooldown))
        // Opened, then quit by the user mid-meeting: the launch cooldown no longer applies.
        policy.appExited(at: t0.addingTimeInterval(6))
        #expect(policy.decide(chromeMic, appRunning: false, prefs: LauncherPrefs(), now: t0.addingTimeInterval(7)) == .launch(app: "Chrome"))
    }

    @Test func timeBasedSkipsReportWhenToRetry() {
        var policy = MeetingLaunchPolicy(cooldown: 600, quitGrace: 30)
        _ = policy.evaluate(zoomLaunch, appRunning: false, prefs: LauncherPrefs(), now: t0)
        let cooled = policy.decide(chromeMic, appRunning: false, prefs: LauncherPrefs(), now: t0.addingTimeInterval(60))
        #expect(cooled == .skip(.cooldown))
        #expect(policy.retryDate(after: cooled) == t0.addingTimeInterval(600))
        policy.appExited(at: t0.addingTimeInterval(100))
        let quit = policy.decide(chromeMic, appRunning: false, prefs: LauncherPrefs(), now: t0.addingTimeInterval(110))
        #expect(quit == .skip(.recentlyQuit))
        #expect(policy.retryDate(after: quit) == t0.addingTimeInterval(130))
        #expect(policy.decide(chromeMic, appRunning: false, prefs: LauncherPrefs(), now: t0.addingTimeInterval(130)) == .launch(app: "Chrome"))
        // Not time-based: nothing to retry.
        #expect(policy.retryDate(after: .skip(.appRunning)) == nil)
        #expect(policy.retryDate(after: .skip(.notAMeeting)) == nil)
        #expect(policy.retryDate(after: .launch(app: "Zoom")) == nil)
    }

    @Test func cooldownRetryKeepsOneTimer() {
        var retry = CooldownRetry()
        let first = retry.schedule(at: t0.addingTimeInterval(30))
        let same = retry.schedule(at: t0.addingTimeInterval(30))
        let moved = retry.schedule(at: t0.addingTimeInterval(40))
        #expect(first == t0.addingTimeInterval(30))
        #expect(same == nil)  // same deadline: no second timer
        #expect(moved == t0.addingTimeInterval(40))
        let stale = retry.fire(at: t0.addingTimeInterval(30))
        let due = retry.fire(at: t0.addingTimeInterval(40))
        let again = retry.fire(at: t0.addingTimeInterval(41))
        #expect(!stale)  // the stale timer does nothing
        #expect(due)
        #expect(!again)  // fired once
        _ = retry.schedule(at: t0.addingTimeInterval(50))
        retry.cancel()  // microphone stopped
        let cancelled = retry.fire(at: t0.addingTimeInterval(50))
        #expect(!cancelled)
    }

    @Test func micAlreadyOnAtStartCountsOnce() {
        var read = false
        let idle = MeetingLaunchPolicy.startupTrigger(micRunning: false, captureBundleIDs: { read = true; return ["us.zoom.xos"] })
        #expect(idle == nil)
        #expect(!read)  // idle microphone: no process scan
        #expect(MeetingLaunchPolicy.startupTrigger(micRunning: true, captureBundleIDs: { ["com.google.Chrome.helper"] }) == chromeMic)
        #expect(MeetingLaunchPolicy.startupTrigger(micRunning: true, captureBundleIDs: { ["com.apple.VoiceMemos"] }) == nil)
        #expect(MeetingLaunchPolicy.startupTrigger(micRunning: true, captureBundleIDs: { ["com.hoangphu.meetingnotes"] }) == nil)
    }

    @Test func settingsGateTheLauncher() {
        let policy = MeetingLaunchPolicy()
        #expect(policy.decide(zoomLaunch, appRunning: false, prefs: LauncherPrefs(openForMeetings: false), now: t0) == .skip(.disabled))
        #expect(policy.decide(zoomLaunch, appRunning: false, prefs: LauncherPrefs(detection: false), now: t0) == .skip(.detectionOff))
        let snoozed = LauncherPrefs(snoozedUntil: t0.addingTimeInterval(60))
        #expect(policy.decide(zoomLaunch, appRunning: false, prefs: snoozed, now: t0) == .skip(.snoozed))
        #expect(policy.decide(zoomLaunch, appRunning: false, prefs: snoozed, now: t0.addingTimeInterval(61)) == .launch(app: "Zoom"))
    }

    @Test func prefsReadLikeTheAppsDefaults() {
        #expect(LauncherPrefs { _ in nil } == LauncherPrefs())  // nothing stored: registered defaults (on, on)
        let stored: [String: Any] = ["openForMeetings": NSNumber(value: false), "meetingDetection": true,
                                     "detectionSnoozeUntil": NSNumber(value: 1_800_000_060.0)]
        let prefs = LauncherPrefs { stored[$0] }
        #expect(!prefs.openForMeetings && prefs.detection)
        #expect(prefs.snoozedUntil == Date(timeIntervalSince1970: 1_800_000_060))
        #expect(LauncherPrefs { $0 == "detectionSnoozeUntil" ? NSNumber(value: 0) : nil }.snoozedUntil == nil)
    }

    @Test func debounceCoalescesABurst() {
        var debounce = Debounce(delay: 2)
        let first = debounce.signal(at: t0)
        let second = debounce.signal(at: t0.addingTimeInterval(0.5))
        #expect(first == t0.addingTimeInterval(2))
        #expect(second == nil)  // already scheduled
        let early = debounce.fire(at: t0.addingTimeInterval(1.9))
        let due = debounce.fire(at: t0.addingTimeInterval(2))
        let again = debounce.fire(at: t0.addingTimeInterval(2.1))
        #expect(!early)  // early wake-up: not due
        #expect(due)
        #expect(!again)  // fired once
        let next = debounce.signal(at: t0.addingTimeInterval(3))
        #expect(next == t0.addingTimeInterval(5))  // the next burst schedules again
    }

    @Test func appBundleFromTheHelperPath() {
        let app = MeetingLauncher.appBundle(forHelperAt: "/Applications/MeetingNotes.app/Contents/MacOS/MeetingNotesLauncher")
        #expect(app?.path == "/Applications/MeetingNotes.app")
        #expect(MeetingLauncher.appBundle(forHelperAt: "/Users/a/Applications/MeetingNotes.app/Contents/MacOS/../MacOS/MeetingNotesLauncher")?
            .path == "/Users/a/Applications/MeetingNotes.app")
        #expect(MeetingLauncher.appBundle(forHelperAt: "/repo/app/.build/debug/MeetingNotesLauncher") == nil)
        #expect(MeetingLauncher.agentPlistName == "com.hoangphu.meetingnotes.launcher.plist")
    }

    @Test func registrationFollowsTheSetting() {
        #expect(LauncherSync(enabled: true, state: .off) == .register)
        #expect(LauncherSync(enabled: true, state: .enabled) == .none)
        #expect(LauncherSync(enabled: true, state: .requiresApproval) == .none)  // the user decides in Login Items
        #expect(LauncherSync(enabled: true, state: .unavailable) == .none)  // dev build: no agent plist
        #expect(LauncherSync(enabled: false, state: .enabled) == .unregister)
        #expect(LauncherSync(enabled: false, state: .requiresApproval) == .unregister)
        #expect(LauncherSync(enabled: false, state: .off) == .none)
        // Rebuilt or reinstalled app: an enabled agent is registered again (stale launch constraint).
        #expect(LauncherSync(enabled: true, state: .enabled, bundleChanged: true) == .reregister)
        #expect(LauncherSync(enabled: true, state: .off, bundleChanged: true) == .register)
        #expect(LauncherSync(enabled: false, state: .enabled, bundleChanged: true) == .unregister)
        #expect(LauncherSync(enabled: true, state: .requiresApproval, bundleChanged: true) == .none)
    }

    /// A never-registered agent reports `.notFound` (no Background Task Management record yet): it must still
    /// register when the plist ships in the bundle; only a dev build without the plist is unavailable.
    @Test func neverRegisteredAgentStillRegisters() {
        #expect(LoginItemState(agent: .notFound, plistInBundle: true) == .off)
        #expect(LoginItemState(agent: .notFound, plistInBundle: false) == .unavailable)
        #expect(LoginItemState(agent: .notRegistered, plistInBundle: true) == .off)
        #expect(LoginItemState(agent: .enabled, plistInBundle: true) == .enabled)
        #expect(LoginItemState(agent: .requiresApproval, plistInBundle: true) == .requiresApproval)
        #expect(LoginItemState(agent: .unknown, plistInBundle: true) == .unknown)
        #expect(LauncherSync(enabled: true, state: LoginItemState(agent: .notFound, plistInBundle: true)) == .register)
        #expect(LauncherSync(enabled: true, state: LoginItemState(agent: .notFound, plistInBundle: false)) == .none)
        #expect(LauncherSync(enabled: false, state: LoginItemState(agent: .notFound, plistInBundle: true)) == .none)
    }

    @Test func settingsRowNeedsDetection() {
        let env = SettingsEnvironment(detectionSupported: true, physicalMemoryGB: 16, microphone: .granted, screenCapture: .granted)
        var old = env
        old.detectionSupported = false
        #expect(SettingsRules.openForMeetingsEnabled(detection: true, env))
        #expect(!SettingsRules.openForMeetingsEnabled(detection: false, env))
        #expect(!SettingsRules.openForMeetingsEnabled(detection: true, old))
        #expect(SettingsRules.openForMeetingsHelp(on: true, state: .enabled, detection: true, env) == .helpOpenForMeetings)
        #expect(SettingsRules.openForMeetingsHelp(on: true, state: .requiresApproval, detection: true, env) == .loginNeedsApproval)
        #expect(SettingsRules.openForMeetingsWarning(on: true, state: .requiresApproval, detection: true, env))
        #expect(SettingsRules.openForMeetingsHelp(on: false, state: .requiresApproval, detection: true, env) == .helpOpenForMeetings)
        #expect(!SettingsRules.openForMeetingsWarning(on: false, state: .unavailable, detection: true, env))
        #expect(SettingsRules.openForMeetingsHelp(on: true, state: .enabled, detection: false, env) == .helpStopOnCallEndNeedsDetection)
        #expect(SettingsRules.openForMeetingsHelp(on: true, state: .enabled, detection: true, old) == .detectionRequires)
        // The help line says Quit does not stop it and where to turn it off.
        #expect(tr(.helpOpenForMeetings, lang: .vi).contains("Thoát"))
        #expect(tr(.helpOpenForMeetings, lang: .en).contains("Quit"))
    }
}
