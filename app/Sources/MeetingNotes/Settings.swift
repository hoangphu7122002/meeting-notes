import Foundation
import MeetingNotesCore
import ServiceManagement

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum AppInfo {
    static let bundleID = "com.hoangphu.meetingnotes"

    static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    static var versionString: String {
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    /// True when running from the assembled .app bundle (needed for notifications and login items).
    static var isBundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingNotes", isDirectory: true)
    }

    static var stateFile: URL { supportDir.appendingPathComponent("state.json") }

    static var logsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MeetingNotes", isDirectory: true)
    }
}

/// User preferences in `UserDefaults` (domain `com.hoangphu.meetingnotes`).
enum Settings {
    enum Key {
        static let notesDir = "notesDir"
        static let detection = "meetingDetection"
        static let hotkey = "hotkey"
        static let pauseHotkey = "pauseHotkey"
        static let pipelineDir = "pipelineDir"
        static let uvPath = "uvPath"
        static let showInDock = "showInDock"
        static let showIdlePill = "showIdlePill"
        static let pillHiddenUntil = "pillHiddenUntil"
        static let pillAnchorX = "pillAnchorX"
        static let pillAnchorY = "pillAnchorY"
        static let createNotesMode = "createNotesMode"
        static let summaryModel = "summaryModel"
        static let autoStopSilenceMinutes = "autoStopSilenceMinutes"
        static let autoStopOnCallEnd = "autoStopOnCallEnd"
        static let detectionSnoozeUntil = "detectionSnoozeUntil"
        static let onboardingDone = "onboardingDone"
        static let permissionsWereGranted = "permissionsWereGranted"
        static let lastNotesFolder = "lastNotesFolder"
    }

    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.detection: true,
            Key.showInDock: true,
            Key.showIdlePill: true,
            Key.createNotesMode: CreateNotesMode.rightAway.rawValue,
            Key.summaryModel: SummaryModel.light.rawValue,
            Key.autoStopSilenceMinutes: 15,
            Key.autoStopOnCallEnd: true,
        ])
    }

    static var defaultNotesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MeetingNotes", isDirectory: true)
    }

    static var notesDir: URL {
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

    static var detectionEnabled: Bool {
        get { defaults.bool(forKey: Key.detection) }
        set { defaults.set(newValue, forKey: Key.detection) }
    }

    static var hotkey: String { nonEmpty(defaults.string(forKey: Key.hotkey)) ?? HotKeySpec.defaultRecord }
    static var pauseHotkey: String { nonEmpty(defaults.string(forKey: Key.pauseHotkey)) ?? HotKeySpec.defaultPause }

    static var showInDock: Bool {
        get { defaults.bool(forKey: Key.showInDock) }
        set { defaults.set(newValue, forKey: Key.showInDock) }
    }

    static var showIdlePill: Bool {
        get { defaults.bool(forKey: Key.showIdlePill) }
        set { defaults.set(newValue, forKey: Key.showIdlePill) }
    }

    static var pillHiddenUntil: Date? {
        get {
            let value = defaults.double(forKey: Key.pillHiddenUntil)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.pillHiddenUntil) }
    }

    /// Bottom-center point of the pill in screen coordinates.
    static var pillAnchor: CGPoint? {
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

    static var createNotesMode: CreateNotesMode {
        get { CreateNotesMode(rawValue: defaults.string(forKey: Key.createNotesMode) ?? "") ?? .rightAway }
        set { defaults.set(newValue.rawValue, forKey: Key.createNotesMode) }
    }

    static var summaryModel: SummaryModel {
        get { SummaryModel(rawValue: defaults.string(forKey: Key.summaryModel) ?? "") ?? .light }
        set { defaults.set(newValue.rawValue, forKey: Key.summaryModel) }
    }

    /// 0 = off.
    static var autoStopSilenceMinutes: Int {
        get { max(0, defaults.integer(forKey: Key.autoStopSilenceMinutes)) }
        set { defaults.set(max(0, newValue), forKey: Key.autoStopSilenceMinutes) }
    }

    static var autoStopOnCallEnd: Bool {
        get { defaults.bool(forKey: Key.autoStopOnCallEnd) }
        set { defaults.set(newValue, forKey: Key.autoStopOnCallEnd) }
    }

    static var detectionSnoozeUntil: Date? {
        get {
            let value = defaults.double(forKey: Key.detectionSnoozeUntil)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.detectionSnoozeUntil) }
    }

    static var onboardingDone: Bool {
        get { defaults.bool(forKey: Key.onboardingDone) }
        set { defaults.set(newValue, forKey: Key.onboardingDone) }
    }

    static var permissionsWereGranted: Bool {
        get { defaults.bool(forKey: Key.permissionsWereGranted) }
        set { defaults.set(newValue, forKey: Key.permissionsWereGranted) }
    }

    static var lastNotesFolder: URL? {
        get { nonEmpty(defaults.string(forKey: Key.lastNotesFolder)).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: Key.lastNotesFolder) }
    }

    /// Pipeline project dir: defaults override, then Info.plist `MNPipelineDir`, then `MN_PIPELINE_DIR`.
    static var pipelineDir: String? {
        nonEmpty(defaults.string(forKey: Key.pipelineDir))
            ?? nonEmpty(AppInfo.info["MNPipelineDir"] as? String)
            ?? nonEmpty(ProcessInfo.processInfo.environment["MN_PIPELINE_DIR"])
    }

    /// uv binary: defaults override, then Info.plist `MNUvPath`, then Homebrew.
    static var uvPath: String {
        nonEmpty(defaults.string(forKey: Key.uvPath))
            ?? nonEmpty(AppInfo.info["MNUvPath"] as? String)
            ?? "/opt/homebrew/bin/uv"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}

enum LoginItem {
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Needs approval in System Settings › General › Login Items"
        case .notRegistered: return "Off"
        case .notFound: return "Unavailable (run the installed app from ~/Applications)"
        @unknown default: return "Unknown"
        }
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
