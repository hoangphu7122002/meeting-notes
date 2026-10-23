// "Open the app when a meeting starts": registers the MeetingNotesLauncher agent (SMAppService.agent, per user)
// while the setting is on (Settings). Independent of Launch at Login; quitting the app leaves it registered.

import Foundation
import MeetingNotesCore
import MeetingNotesLaunch
import os
import ServiceManagement

public enum MeetingLauncherItem {
    /// `Contents/Library/LaunchAgents/com.hoangphu.meetingnotes.launcher.plist` (written by scripts/build-app.sh).
    private static var service: SMAppService { .agent(plistName: MeetingLauncher.agentPlistName) }
    private static let log = Logger(subsystem: "com.hoangphu.meetingnotes", category: "launcher")

    /// The last register/unregister failure (shown under the Settings toggle); nil after a success.
    public private(set) static var lastError: String?

    private static var plistInBundle: Bool {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents")
            .appendingPathComponent(MeetingLauncher.agentPlistName)
        return FileManager.default.fileExists(atPath: plist.path)
    }

    private static var status: AppServiceStatus {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    public static var state: LoginItemState { LoginItemState(agent: status, plistInBundle: plistInBundle) }

    /// Stores the setting and registers or unregisters the agent.
    public static func set(_ enabled: Bool) throws {
        Settings.openForMeetings = enabled
        try apply(enabled: enabled)
    }

    /// At launch: the agent follows the stored setting (on by default, so each account registers its own).
    public static func sync() throws {
        try apply(enabled: Settings.openForMeetings)
    }

    private static func apply(enabled: Bool) throws {
        let before = status
        let action = LauncherSync(enabled: enabled, state: LoginItemState(agent: before, plistInBundle: plistInBundle))
        log.info("launcher agent: setting \(enabled, privacy: .public), status \(String(describing: before), privacy: .public), plist in bundle \(plistInBundle, privacy: .public), action \(String(describing: action), privacy: .public)")
        do {
            switch action {
            case .register: try service.register()
            case .unregister: try service.unregister()
            case .none: return
            }
            lastError = nil
            log.info("launcher agent: \(String(describing: action), privacy: .public) ok, status now \(String(describing: status), privacy: .public)")
        } catch where status == .requiresApproval {
            lastError = nil  // registered, waiting for the user in Login Items: the row shows that note
            log.notice("launcher agent: needs approval in Login Items (\(String(describing: error), privacy: .public))")
        } catch {
            lastError = error.localizedDescription
            log.error("launcher agent: \(String(describing: action), privacy: .public) failed: \(String(describing: error), privacy: .public), status \(String(describing: status), privacy: .public)")
            throw error
        }
    }
}
