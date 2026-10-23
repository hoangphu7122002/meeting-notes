import Foundation
import MeetingNotesCore
import MeetingNotesLaunch

/// User preferences in `UserDefaults` (domain `com.hoangphu.meetingnotes`).
public enum Settings {
    public enum Key {
        public static let notesDir = "notesDir"
        public static let detection = "meetingDetection"
        public static let hotkey = "hotkey"
        public static let pauseHotkey = "pauseHotkey"
        public static let pipelineDir = "pipelineDir"
        public static let uvPath = "uvPath"
        public static let showInDock = "showInDock"
        public static let showIdlePill = "showIdlePill"
        public static let pillHiddenUntil = "pillHiddenUntil"
        public static let pillAnchorX = "pillAnchorX"
        public static let pillAnchorY = "pillAnchorY"
        public static let createNotesMode = "createNotesMode"
        public static let summaryModel = "summaryModel"
        public static let autoStopSilenceMinutes = "autoStopSilenceMinutes"
        public static let autoStopOnCallEnd = "autoStopOnCallEnd"
        public static let detectionSnoozeUntil = "detectionSnoozeUntil"
        public static let onboardingDone = "onboardingDone"
        public static let permissionsWereGranted = "permissionsWereGranted"
        public static let lastNotesFolder = "lastNotesFolder"
        public static let uiLanguage = "uiLanguage"
        public static let showRecordingPill = "showRecordingPill"
        public static let liveTranscription = "liveTranscription"
        public static let livePolish = "livePolish"
        /// Fast captions (design B) on top of the live transcript; see `LiveMode`.
        public static let liveCaptions = "liveCaptions"
        /// Read by the launcher agent too (`MeetingLauncher.Key`).
        public static let openForMeetings = MeetingLauncher.Key.openForMeetings
        /// App build (`CFBundleVersion` + path) the launcher agent was last registered for.
        public static let launcherRegisteredBuild = "launcherRegisteredBuild"
    }

    private static var defaults: UserDefaults { .standard }

    public static func registerDefaults() {
        defaults.register(defaults: [
            Key.detection: true,
            Key.showInDock: true,
            Key.showIdlePill: false,
            Key.showRecordingPill: true,
            Key.uiLanguage: UILanguage.vi.rawValue,
            Key.createNotesMode: CreateNotesMode.rightAway.rawValue,
            Key.summaryModel: SummaryModel.light.rawValue,
            Key.autoStopSilenceMinutes: 15,
            Key.autoStopOnCallEnd: true,
            Key.liveTranscription: false,
            Key.livePolish: false,
            Key.liveCaptions: true,
            Key.openForMeetings: true,
        ])
    }

    public static var defaultNotesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MeetingNotes", isDirectory: true)
    }

    public static var notesDir: URL {
        get {
            guard let path = nonEmpty(defaults.string(forKey: Key.notesDir)) else { return defaultNotesDir }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        set {
            if newValue.standardizedFileURL == defaultNotesDir.standardizedFileURL {
                defaults.removeObject(forKey: Key.notesDir)
            } else {
                defaults.set(newValue.path, forKey: Key.notesDir)
            }
        }
    }

    public static var detectionEnabled: Bool {
        get { defaults.bool(forKey: Key.detection) }
        set { defaults.set(newValue, forKey: Key.detection) }
    }

    public static var hotkey: String { nonEmpty(defaults.string(forKey: Key.hotkey)) ?? HotKeySpec.defaultRecord }
    public static var pauseHotkey: String { nonEmpty(defaults.string(forKey: Key.pauseHotkey)) ?? HotKeySpec.defaultPause }

    public static var showInDock: Bool {
        get { defaults.bool(forKey: Key.showInDock) }
        set { defaults.set(newValue, forKey: Key.showInDock) }
    }

    /// UI language; Vietnamese unless the user picked English.
    public static var uiLanguage: UILanguage {
        get { UILanguage(rawValue: defaults.string(forKey: Key.uiLanguage) ?? "") ?? .vi }
        set { defaults.set(newValue.rawValue, forKey: Key.uiLanguage) }
    }

    /// "Show floating control while recording" (also while saving and writing notes).
    public static var showRecordingPill: Bool {
        get { defaults.bool(forKey: Key.showRecordingPill) }
        set { defaults.set(newValue, forKey: Key.showRecordingPill) }
    }

    /// "Show floating control when idle".
    public static var showIdlePill: Bool {
        get { defaults.bool(forKey: Key.showIdlePill) }
        set { defaults.set(newValue, forKey: Key.showIdlePill) }
    }

    public static var pillHiddenUntil: Date? {
        get {
            let value = defaults.double(forKey: Key.pillHiddenUntil)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.pillHiddenUntil) }
    }

    /// Bottom-center point of the pill in screen coordinates.
    public static var pillAnchor: CGPoint? {
        get {
            guard defaults.object(forKey: Key.pillAnchorX) != nil else { return nil }
            return CGPoint(x: defaults.double(forKey: Key.pillAnchorX), y: defaults.double(forKey: Key.pillAnchorY))
        }
        set {
            if let newValue {
                defaults.set(Double(newValue.x), forKey: Key.pillAnchorX)
                defaults.set(Double(newValue.y), forKey: Key.pillAnchorY)
            } else {
                defaults.removeObject(forKey: Key.pillAnchorX)
                defaults.removeObject(forKey: Key.pillAnchorY)
            }
        }
    }

    public static var createNotesMode: CreateNotesMode {
        get { CreateNotesMode(rawValue: defaults.string(forKey: Key.createNotesMode) ?? "") ?? .rightAway }
        set { defaults.set(newValue.rawValue, forKey: Key.createNotesMode) }
    }

    public static var summaryModel: SummaryModel {
        get { SummaryModel(rawValue: defaults.string(forKey: Key.summaryModel) ?? "") ?? .light }
        set { defaults.set(newValue.rawValue, forKey: Key.summaryModel) }
    }

    /// 0 = off.
    public static var autoStopSilenceMinutes: Int {
        get { max(0, defaults.integer(forKey: Key.autoStopSilenceMinutes)) }
        set { defaults.set(max(0, newValue), forKey: Key.autoStopSilenceMinutes) }
    }

    public static var autoStopOnCallEnd: Bool {
        get { defaults.bool(forKey: Key.autoStopOnCallEnd) }
        set { defaults.set(newValue, forKey: Key.autoStopOnCallEnd) }
    }

    /// Opt-in live transcript while recording (more memory/GPU while recording; notes stay complete).
    public static var liveTranscription: Bool {
        get { defaults.bool(forKey: Key.liveTranscription) }
        set { defaults.set(newValue, forKey: Key.liveTranscription) }
    }

    /// Settings › Live transcript: fast captions (default once live is on), accurate (design A only) or off.
    public static var liveMode: LiveMode {
        get { LiveMode(live: liveTranscription, captions: defaults.bool(forKey: Key.liveCaptions)) }
        set {
            defaults.set(newValue.captionsKey(previous: defaults.bool(forKey: Key.liveCaptions)), forKey: Key.liveCaptions)
            liveTranscription = newValue.live
        }
    }

    /// Opt-in display-only polish of the live transcript (sent as `"polish":"rules"` when the worker supports it).
    public static var livePolish: Bool {
        get { defaults.bool(forKey: Key.livePolish) }
        set { defaults.set(newValue, forKey: Key.livePolish) }
    }

    /// "Open the app when a meeting starts": the launcher agent is registered while this is on (see
    /// `MeetingLauncherItem`); it also reads this key, so turning it off stops it at once.
    public static var openForMeetings: Bool {
        get { defaults.bool(forKey: Key.openForMeetings) }
        set { defaults.set(newValue, forKey: Key.openForMeetings) }
    }

    public static var launcherRegisteredBuild: String? {
        get { defaults.string(forKey: Key.launcherRegisteredBuild) }
        set { defaults.set(newValue, forKey: Key.launcherRegisteredBuild) }
    }

    public static var detectionSnoozeUntil: Date? {
        get {
            let value = defaults.double(forKey: Key.detectionSnoozeUntil)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.detectionSnoozeUntil) }
    }

    public static var onboardingDone: Bool {
        get { defaults.bool(forKey: Key.onboardingDone) }
        set { defaults.set(newValue, forKey: Key.onboardingDone) }
    }

    public static var permissionsWereGranted: Bool {
        get { defaults.bool(forKey: Key.permissionsWereGranted) }
        set { defaults.set(newValue, forKey: Key.permissionsWereGranted) }
    }

    public static var lastNotesFolder: URL? {
        get { nonEmpty(defaults.string(forKey: Key.lastNotesFolder)).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: Key.lastNotesFolder) }
    }

    /// Pipeline project dir + uv: defaults overrides, Info.plist `MNPipelineDir`/`MNUvPath`, `MN_PIPELINE_DIR`, the
    /// packaged app's runtime (after its first-run setup), then a shared install
    /// (/Users/Shared/MeetingNotes/shared-install.json); see `PipelineLocator`.
    public static var pipelineLocation: PipelineLocation? {
        PipelineLocator.resolve(
            pipelineOverride: defaults.string(forKey: Key.pipelineDir),
            pipelineInfo: AppInfo.info["MNPipelineDir"] as? String,
            pipelineEnv: ProcessInfo.processInfo.environment["MN_PIPELINE_DIR"],
            uvOverride: defaults.string(forKey: Key.uvPath),
            uvInfo: AppInfo.info["MNUvPath"] as? String,
            packagedRoot: AppInfo.isPackaged ? AppInfo.runtime.root.path : nil,
            readFile: { FileManager.default.contents(atPath: $0) })
    }

    public static var pipelineDir: String? { pipelineLocation?.pipelineDir }

    /// uv binary (see `pipelineLocation`); Homebrew's when nothing is configured.
    public static var uvPath: String { pipelineLocation?.uvPath ?? PipelineLocator.defaultUvPath }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}
