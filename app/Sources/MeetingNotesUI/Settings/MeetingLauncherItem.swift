// "Open the app when a meeting starts": registers the MeetingNotesLauncher agent (SMAppService.agent, per user)
// while the setting is on (Settings). Independent of Launch at Login; quitting the app leaves it registered.

import Foundation
import MeetingNotesCore
import MeetingNotesLaunch
import ServiceManagement

public enum MeetingLauncherItem {
    /// `Contents/Library/LaunchAgents/com.hoangphu.meetingnotes.launcher.plist` (written by scripts/build-app.sh).
    private static var service: SMAppService { .agent(plistName: MeetingLauncher.agentPlistName) }

    public static var state: LoginItemState {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .unknown
        }
    }

    /// Stores the setting and registers or unregisters the agent.
    public static func set(_ enabled: Bool) throws {
        Settings.openForMeetings = enabled
        try apply(LauncherSync(enabled: enabled, state: state))
    }

    /// At launch: the agent follows the stored setting (on by default, so each account registers its own).
    public static func sync() throws {
        try apply(LauncherSync(enabled: Settings.openForMeetings, state: state))
    }

    private static func apply(_ action: LauncherSync) throws {
        switch action {
        case .register: try service.register()
        case .unregister: try service.unregister()
        case .none: break
        }
    }
}
