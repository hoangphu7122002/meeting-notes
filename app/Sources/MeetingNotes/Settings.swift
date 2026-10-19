import Foundation
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
}

/// User preferences in `UserDefaults` (domain `com.hoangphu.meetingnotes`).
enum Settings {
    enum Key {
        static let notesDir = "notesDir"
        static let detection = "meetingDetection"
        static let hotkey = "hotkey"
        static let pipelineDir = "pipelineDir"
        static let uvPath = "uvPath"
    }

    static let defaultHotkey = "ctrl+opt+cmd+r"
    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [Key.detection: true])
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

    static var hotkey: String { nonEmpty(defaults.string(forKey: Key.hotkey)) ?? defaultHotkey }

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
