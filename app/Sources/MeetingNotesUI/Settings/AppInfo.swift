// Bundle metadata, support/log directories and the shared error type (Settings).

import Foundation
import MeetingNotesCore

public struct AppError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum AppInfo {
    public static let bundleID = "com.hoangphu.meetingnotes"

    public static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    public static var versionString: String {
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    /// True when running from the assembled .app bundle (needed for notifications and login items).
    public static var isBundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    public static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingNotes", isDirectory: true)
    }

    public static var stateFile: URL { supportDir.appendingPathComponent("state.json") }

    /// Release build (scripts/release.sh, Info.plist `MNPackaged`): the pipeline ships inside the bundle and the
    /// first-run setup builds the per-user runtime. Dev and shared installs bake `MNPipelineDir` instead.
    public static var isPackaged: Bool { info["MNPackaged"] as? Bool ?? false }

    /// The packaged app's per-user runtime (pipeline copy, Python, models).
    public static var runtime: RuntimeLayout { RuntimeLayout(supportDir: supportDir) }

    /// Short version (`CFBundleShortVersionString`) plus build, the key the runtime setup is tied to.
    public static var setupVersion: String {
        "\(info["CFBundleShortVersionString"] as? String ?? "dev")+\(info["CFBundleVersion"] as? String ?? "0")"
    }

    public static var logsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MeetingNotes", isDirectory: true)
    }
}
